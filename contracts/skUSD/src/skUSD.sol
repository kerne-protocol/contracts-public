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
        _trackedAssets += amount;
        // The totalAssets() increases, raising the share price for all skUSD holders.
    }

    /**
     * @dev Overrides totalAssets to use the internal ledger so a direct
     *      ERC-20 donation cannot inflate the share price.
     */
    function totalAssets() public view override returns (uint256) {
        return _trackedAssets;
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
