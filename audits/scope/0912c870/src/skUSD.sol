// Created: 2026-02-03
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title skUSD (Staked kUSD)
 * @author Kerne Protocol
 * @notice skUSD is an ERC-4626 vault that earns the basis yield from Kerne's delta-neutral strategy.
 *         It replicates Ethena's sUSDe model but for the Kerne ecosystem.
 */
contract skUSD is ERC4626, AccessControl {
    using SafeERC20 for ERC20;

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    /// @dev Internal accounting for assets under management. We do NOT use
    ///      `IERC20(asset).balanceOf(address(this))` for `totalAssets()`
    ///      because that pattern is the textbook ERC-4626 inflation /
    ///      donation primitive (Resupply 2025-06, Hundred Finance 2023, etc.):
    ///      an attacker deposits 1 wei, donates a large amount directly via
    ///      `transfer`, and either steals the next depositor's principal or
    ///      forces them to mint zero shares. Tracking via ledger means
    ///      donations land as untracked balance the strategist can sweep
    ///      back to the bot, and the share price moves only when
    ///      `distributeYield()` (an authenticated path) is called.
    uint256 private _trackedAssets;

    // ── Yield streaming (just-in-time / flash-deposit defense) ───────────────
    /// @dev Distributed yield does NOT hit the share price atomically. It vests
    ///      linearly over `yieldVestingPeriod`, and until it vests it is
    ///      excluded from `totalAssets()`. So a depositor who brackets a
    ///      `distributeYield()` call within a single block (deposit -> yield ->
    ///      redeem) captures none of it: at redeem time zero seconds have
    ///      elapsed, the whole distribution is still locked, and their shares
    ///      are worth exactly what they paid. To earn the yield an account must
    ///      actually remain staked while it vests. This is the Yearn/sFRAX
    ///      "locked profit" pattern; it neutralizes the flash-deposit yield
    ///      theft that an instant share-price jump enables, without imposing a
    ///      withdrawal cooldown on honest stakers.
    uint256 public lastYieldAmount; // total amount currently vesting
    uint256 public lastYieldTime; // timestamp the current vest started
    uint256 public yieldVestingPeriod; // duration over which yield vests

    uint256 public constant MIN_VESTING_PERIOD = 1 hours;
    uint256 public constant MAX_VESTING_PERIOD = 30 days;
    uint256 public constant DEFAULT_VESTING_PERIOD = 24 hours;

    event YieldDistributed(address indexed strategist, uint256 amount, uint256 totalVesting, uint256 vestStart);
    event YieldVestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    error InvalidVestingPeriod();

    /**
     * @notice Constructor for skUSD.
     * @param _asset The kUSD token address.
     * @param _admin The default admin address.
     */
    constructor(
        ERC20 _asset,
        address _admin
    ) ERC4626(_asset) ERC20("Staked Kerne Synthetic Dollar", "skUSD") {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGIST_ROLE, _admin);
        yieldVestingPeriod = DEFAULT_VESTING_PERIOD;
    }

    /**
     * @notice Distributes yield to skUSD holders.
     * @dev This function is called by the bot/strategist to push captured basis yield into the vault.
     * @param amount The amount of kUSD to distribute as yield.
     */
    function distributeYield(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        ERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Fold any still-unvested portion of the previous distribution into the
        // new stream (so nothing is skipped) and restart the vest clock. The
        // freshly distributed `amount` is now fully locked and vests linearly
        // over `yieldVestingPeriod`; it is excluded from totalAssets() until it
        // vests, which is what defeats single-block flash-deposit yield theft.
        uint256 stillLocked = lockedYield();
        lastYieldAmount = stillLocked + amount;
        lastYieldTime = block.timestamp;

        _trackedAssets += amount;
        emit YieldDistributed(msg.sender, amount, lastYieldAmount, block.timestamp);
    }

    /**
     * @dev Overrides totalAssets to use the internal ledger so a direct
     *      ERC-20 donation cannot inflate the share price, minus any yield that
     *      has not finished vesting. The invariant
     *      `_trackedAssets >= lockedYield()` holds at all times — locked tokens
     *      are physically present and tracked, and a withdrawal can only ever
     *      remove from the already-vested portion (`assets <= totalAssets()`),
     *      so this subtraction never underflows.
     */
    function totalAssets() public view override returns (uint256) {
        return _trackedAssets - lockedYield();
    }

    /// @notice The portion of the most recent distribution that has not yet
    ///         vested into the share price. Decreases linearly to zero over
    ///         `yieldVestingPeriod` measured from `lastYieldTime`.
    function lockedYield() public view returns (uint256) {
        uint256 amount = lastYieldAmount;
        if (amount == 0) return 0;
        uint256 period = yieldVestingPeriod;
        uint256 elapsed = block.timestamp - lastYieldTime;
        if (elapsed >= period) return 0;
        return amount * (period - elapsed) / period;
    }

    /// @notice Admin (Safe) tunes how long distributed yield takes to vest.
    /// @dev Re-bases the in-flight stream so changing the period does not cause
    ///      an instantaneous jump in the share price: the currently-locked
    ///      amount simply re-vests over the new period starting now.
    function setYieldVestingPeriod(
        uint256 newPeriod
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPeriod < MIN_VESTING_PERIOD || newPeriod > MAX_VESTING_PERIOD) {
            revert InvalidVestingPeriod();
        }
        uint256 stillLocked = lockedYield();
        lastYieldAmount = stillLocked;
        lastYieldTime = block.timestamp;
        uint256 oldPeriod = yieldVestingPeriod;
        yieldVestingPeriod = newPeriod;
        emit YieldVestingPeriodUpdated(oldPeriod, newPeriod);
    }

    /// @dev OZ ERC-4626 calls these internal hooks for every deposit/mint
    ///      and withdraw/redeem. We mirror the asset movement into the
    ///      `_trackedAssets` ledger so it stays in lockstep with the
    ///      vault's share supply.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
        _trackedAssets += assets;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // Decrement first so a reentrant view sees the post-withdrawal balance.
        _trackedAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);

        // SECURITY FIX (KRN-26-SKUSD-ORPHAN, audit 2026-05-29,
        // docs/security/SKUSD_EMPTY_VAULT_YIELD_ORPHAN_2026-05-29.md):
        // If this was the LAST exit (super._withdraw just burned the final
        // shares), any still-vesting yield is now ownerless — no share position
        // can ever redeem it, because there are no shares left. Left as-is, that
        // remainder stays counted in `_trackedAssets`, which makes it
        // simultaneously un-owned AND un-recoverable: `sweepDonations()` treats
        // it as tracked principal and refuses to release it, so the
        // strategist-distributed kUSD is permanently stranded in the contract.
        //
        // Collapse the vest and drop the residual from the tracked ledger so the
        // physically-present kUSD becomes a recoverable donation the strategist
        // can sweep and re-distribute once stakers return. At this point
        // `_trackedAssets` can only be the unvested remainder plus sub-wei
        // rounding dust (all of it ownerless), so zeroing it strands nothing that
        // belonged to a holder — the exiting holder was already paid `assets`
        // above. The vault returns to a clean genesis state (0 shares, 0 tracked
        // assets, nothing vesting), so a later first depositor is priced
        // correctly rather than against a phantom share price. No external call
        // is added, so the reentrancy surface is unchanged.
        if (totalSupply() == 0) {
            _trackedAssets = 0;
            lastYieldAmount = 0;
            lastYieldTime = 0;
        }
    }

    /// @notice Sweeps any donated kUSD (kUSD held by the contract that is
    ///         NOT in the tracked ledger) back to the strategist for
    ///         redirection. Donations land in `IERC20.balanceOf(this)`
    ///         without being credited to share holders; this releases them.
    function sweepDonations(
        address to
    ) external onlyRole(STRATEGIST_ROLE) {
        if (to == address(0)) revert("zero recipient");
        uint256 raw = ERC20(asset()).balanceOf(address(this));
        if (raw <= _trackedAssets) return; // nothing to sweep
        uint256 dust = raw - _trackedAssets;
        ERC20(asset()).safeTransfer(to, dust);
    }

    /**
     * @dev Mitigates the ERC-4626 inflation ("first-depositor") attack.
     *      Without this override OZ defaults to 0, meaning an attacker can
     *      deposit 1 wei, directly transfer a large asset donation to the
     *      vault, and cause subsequent depositors to round down to 0 shares
     *      — effectively stealing their deposit. Returning 6 adds 10**6
     *      virtual shares/assets so the donation required to push the
     *      rounding boundary becomes prohibitively expensive.
     */
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 6;
    }
}
