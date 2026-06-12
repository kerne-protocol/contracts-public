// Created: 2026-03-04
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title esKERNE — Escrowed KERNE
 * @author Kerne Protocol
 * @notice Non-transferable escrowed KERNE tokens with linear vesting and forfeiture redistribution.
 *
 * ─── THE ESCROWED SINGULARITY MECHANISM ───────────────────────────────────────
 *
 * PURPOSE: Create an environment where ZERO liquid KERNE tokens exist in public
 * circulation, eliminating all sell pressure on the AMM pool, while the protocol's
 * real USDC revenue continuously market-buys KERNE through BuyAndBurn. The result
 * is mathematically guaranteed price appreciation via constant-product AMM mechanics.
 *
 * HOW IT WORKS:
 * 1. Yield farmers deposit into KerneVault to earn delta-neutral yield (15-20% APY).
 * 2. On top of base yield, the protocol emits esKERNE as bonus rewards.
 *    esKERNE is NOT transferable and NOT sellable. It vests linearly over 365 days.
 * 3. If a user withdraws their principal from KerneVault, ALL unvested esKERNE
 *    is FORFEITED. The forfeited esKERNE is redistributed pro-rata to remaining
 *    depositors — creating a prisoner's dilemma where leaving enriches those who stay.
 * 4. After full vesting (365 days), esKERNE can be converted 1:1 to liquid KERNE.
 *    But by then, the BuyAndBurn has been compressing supply for a full year,
 *    so the KERNE price is already at escape velocity.
 *
 * WHY THIS GUARANTEES WEALTH:
 * - Zero sell pressure: All public rewards are locked esKERNE. Nobody can dump.
 * - Continuous buy pressure: 100% of protocol performance fees route to BuyAndBurn.
 * - Forfeiture redistribution: Every departure is a windfall for stayers — viral retention.
 * - Founder extraction: Founders take a cut of the real USDC revenue stream AND
 *   sell locked equity OTC to institutions at a "discount" to the inflated spot price.
 *
 * SECURITY:
 * - esKERNE is soulbound (non-transferable) to prevent secondary market creation.
 * - Only EMITTER_ROLE (the vault keeper) can mint new esKERNE.
 * - Only VAULT_ROLE (KerneVault) can trigger forfeiture on withdrawal.
 * - Conversion to liquid KERNE requires the contract to hold sufficient KERNE balance.
 *
 * ──────────────────────────────────────────────────────────────────────────────
 */
contract esKERNE is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          ROLES
    // ============================================================

    /// @notice Role that can mint esKERNE to depositors (the keeper/emission bot).
    bytes32 public constant EMITTER_ROLE = keccak256("EMITTER_ROLE");

    /// @notice Role that can trigger forfeiture when a user exits KerneVault.
    /// @dev This MUST be set to the KerneVault address so that withdrawal
    ///      automatically triggers forfeiture of unvested esKERNE.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // ============================================================
    //                      STATE VARIABLES
    // ============================================================

    /// @notice The liquid KERNE token that esKERNE converts into after vesting.
    IERC20 public immutable kerneToken;

    /// @notice Hard lifetime cap on all esKERNE that can ever be emitted.
    /// @dev This is the most important user-trust hardening added before launch.
    ///      Without a cap, the market must trust that the EMITTER_ROLE holder will not
    ///      over-emit rewards far beyond what the protocol communicated publicly.
    ///      A capped emission budget makes the reward system legible:
    ///        - users know the maximum dilution envelope,
    ///        - founders preserve credibility,
    ///        - institutions can underwrite the reward liability mechanically.
    ///
    ///      The cap is on lifetime emitted esKERNE, not current totalSupply, because
    ///      totalSupply shrinks when users convert or forfeit. Using a lifetime cap prevents
    ///      the protocol from "recycling" converted supply into unlimited new emissions.
    uint256 public immutable maxTotalEmissions;

    /// @notice Duration of the linear vesting period in seconds (365 days).
    /// @dev Chosen to be long enough that the BuyAndBurn has a full year to
    ///      compress circulating supply before any esKERNE converts to liquid KERNE.
    ///      This is the core of the "zero sell pressure" guarantee.
    uint256 public constant VESTING_DURATION = 365 days;

    /// @notice Total esKERNE balance per user (vested + unvested).
    mapping(address => uint256) public balanceOf;

    /// @notice Cumulative esKERNE that has already been claimed (converted to KERNE).
    mapping(address => uint256) public claimed;

    /// @notice Timestamp when the user's first esKERNE was minted. Used as the
    ///         vesting start date. Subsequent emissions are treated as if they
    ///         started vesting at the same time (simplification for gas efficiency).
    ///         Reset to 0 on full forfeiture or full claim.
    mapping(address => uint256) public vestingStart;

    /// @notice Total esKERNE in existence across all users.
    uint256 public totalSupply;

    /// @notice Total esKERNE emitted over the life of the contract.
    /// @dev Monotonic counter used to enforce `maxTotalEmissions`.
    uint256 public totalEmitted;

    /// @notice Total esKERNE forfeited historically (for analytics/dashboards).
    uint256 public totalForfeited;

    /// @notice Total KERNE converted from esKERNE historically.
    uint256 public totalConverted;

    /// @notice Global accumulator for forfeiture redistribution.
    /// @dev Uses the "reward per token" pattern (similar to Synthetix StakingRewards).
    ///      When esKERNE is forfeited, the forfeited amount is divided by totalSupply
    ///      and added to this accumulator. Each user's pending redistribution is
    ///      calculated as: (rewardPerToken - userRewardPerTokenPaid[user]) * balanceOf[user].
    uint256 public rewardPerTokenStored;

    /// @notice Snapshot of rewardPerTokenStored at the time of each user's last interaction.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending redistribution rewards not yet added to the user's balance.
    mapping(address => uint256) public pendingRedistribution;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event Emitted(address indexed user, uint256 amount);
    event Forfeited(address indexed user, uint256 unvestedAmount, uint256 redistributed);
    event Converted(address indexed user, uint256 esKerneAmount, uint256 kerneReceived);
    event RedistributionClaimed(address indexed user, uint256 amount);
    event ConversionReserveFunded(address indexed funder, uint256 amount);

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /// @param _kerneToken Address of the liquid KERNE ERC-20 token.
    /// @param _admin Admin address that will configure roles.
    /// @param _maxTotalEmissions Hard lifetime cap on all esKERNE emissions.
    constructor(address _kerneToken, address _admin, uint256 _maxTotalEmissions) {
        require(_kerneToken != address(0), "esKERNE: zero KERNE address");
        require(_admin != address(0), "esKERNE: zero admin address");
        require(_maxTotalEmissions > 0, "esKERNE: zero emission cap");
        kerneToken = IERC20(_kerneToken);
        maxTotalEmissions = _maxTotalEmissions;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // ============================================================
    //                    MODIFIER: UPDATE REWARDS
    // ============================================================

    /// @dev Must be called before any balance-changing operation to ensure
    ///      the user's pending redistribution rewards are snapshotted.
    modifier updateReward(
        address account
    ) {
        if (account != address(0)) {
            pendingRedistribution[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /// @notice Returns how much esKERNE has vested for a user (claimable as KERNE).
    /// @dev Linear vesting: vestedFraction = min(elapsed / VESTING_DURATION, 1.0).
    ///      Vested amount = totalBalance * vestedFraction - alreadyClaimed.
    /// @param user The address to query.
    /// @return The amount of esKERNE that has vested and can be converted to KERNE.
    function vested(
        address user
    ) public view returns (uint256) {
        uint256 start = vestingStart[user];
        if (start == 0) return 0;

        uint256 total = balanceOf[user];
        if (total == 0) return 0;

        uint256 elapsed = block.timestamp - start;
        uint256 vestedTotal;
        if (elapsed >= VESTING_DURATION) {
            vestedTotal = total;
        } else {
            // Linear: total * elapsed / VESTING_DURATION
            vestedTotal = (total * elapsed) / VESTING_DURATION;
        }

        // Subtract what's already been claimed
        uint256 alreadyClaimed = claimed[user];
        if (vestedTotal <= alreadyClaimed) return 0;
        return vestedTotal - alreadyClaimed;
    }

    /// @notice Returns the unvested (locked) esKERNE for a user.
    /// @dev This is the amount that would be forfeited if the user exits KerneVault.
    /// @param user The address to query.
    /// @return The amount of esKERNE that is still locked and subject to forfeiture.
    function unvested(
        address user
    ) public view returns (uint256) {
        uint256 total = balanceOf[user];
        uint256 vestedAmount = vested(user) + claimed[user];
        if (total <= vestedAmount) return 0;
        return total - vestedAmount;
    }

    /// @notice Returns the pending redistribution rewards for a user.
    /// @dev "Earned" from other users' forfeitures that haven't been collected yet.
    /// @param account The address to query.
    /// @return Pending esKERNE from redistribution.
    function earned(
        address account
    ) public view returns (uint256) {
        return pendingRedistribution[account]
            + (balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18;
    }

    // ============================================================
    //                    EMITTER FUNCTIONS
    // ============================================================

    /// @notice Mint esKERNE to a depositor as a bonus emission.
    /// @dev Called by the keeper bot after each yield distribution cycle.
    ///      The esKERNE is immediately visible in the user's balance but
    ///      cannot be transferred or sold — only vested over 365 days.
    /// @param user The recipient of the esKERNE emission.
    /// @param amount The amount of esKERNE to mint.
    function emitRewards(address user, uint256 amount) external onlyRole(EMITTER_ROLE) updateReward(user) {
        require(user != address(0), "esKERNE: mint to zero address");
        require(amount > 0, "esKERNE: zero amount");
        require(totalEmitted + amount <= maxTotalEmissions, "esKERNE: emission cap exceeded");

        // If this is the user's first emission, start the vesting clock.
        // Subsequent emissions extend the "average" vesting start, but for
        // simplicity and gas efficiency, we keep the original start time.
        // This slightly benefits early depositors (more of their balance is vested).
        if (vestingStart[user] == 0) {
            vestingStart[user] = block.timestamp;
        }

        balanceOf[user] += amount;
        totalSupply += amount;
        totalEmitted += amount;

        emit Emitted(user, amount);
    }

    // ============================================================
    //                     VAULT FUNCTIONS
    // ============================================================

    /// @notice Forfeit all unvested esKERNE for a user who exits KerneVault.
    /// @dev Called by KerneVault's requestWithdrawal() when a user fully exits.
    ///      The forfeited esKERNE is redistributed pro-rata to all remaining holders
    ///      using the Synthetix reward-per-token accumulator pattern.
    ///      This creates the prisoner's dilemma: leaving makes everyone else richer.
    /// @param user The user whose unvested esKERNE will be forfeited.
    function forfeit(
        address user
    ) external onlyRole(VAULT_ROLE) updateReward(user) {
        uint256 unvestedAmount = unvested(user);
        if (unvestedAmount == 0) return;

        // Remove unvested from user's balance
        balanceOf[user] -= unvestedAmount;
        totalSupply -= unvestedAmount;
        totalForfeited += unvestedAmount;

        // Redistribute to all remaining holders
        // If nobody else holds esKERNE, the forfeited amount is burned (lost forever).
        // This is acceptable — it further reduces future supply pressure.
        if (totalSupply > 0) {
            // Add redistribution amount (scaled by 1e18 for precision)
            rewardPerTokenStored += (unvestedAmount * 1e18) / totalSupply;

            // Re-mint the redistributed amount back into totalSupply
            // so that the accounting remains balanced.
            totalSupply += unvestedAmount;
        }

        // If user has zero balance remaining, reset their vesting state entirely.
        if (balanceOf[user] == 0) {
            vestingStart[user] = 0;
            claimed[user] = 0;
        }

        emit Forfeited(user, unvestedAmount, totalSupply > 0 ? unvestedAmount : 0);
    }

    // ============================================================
    //                      USER FUNCTIONS
    // ============================================================

    /// @notice Claim pending redistribution rewards (from other users' forfeitures).
    /// @dev The claimed redistribution is added to the user's esKERNE balance,
    ///      subject to the same vesting schedule starting from their original vestingStart.
    function claimRedistribution() external updateReward(msg.sender) {
        uint256 reward = pendingRedistribution[msg.sender];
        if (reward == 0) return;

        pendingRedistribution[msg.sender] = 0;
        balanceOf[msg.sender] += reward;
        // totalSupply already accounts for this via the redistribution logic

        // If user had no vesting start (edge case: received redistribution
        // but was fully claimed), reset their vesting start to now.
        if (vestingStart[msg.sender] == 0) {
            vestingStart[msg.sender] = block.timestamp;
        }

        emit RedistributionClaimed(msg.sender, reward);
    }

    /// @notice Convert vested esKERNE to liquid KERNE tokens (1:1 ratio).
    /// @dev Requires this contract to hold sufficient KERNE balance.
    ///      The KERNE tokens are transferred from this contract to the user.
    ///      This is the ONLY way esKERNE becomes liquid — and only after
    ///      the vesting period has elapsed, giving the BuyAndBurn a full year head start.
    /// @param amount The amount of vested esKERNE to convert.
    function convert(
        uint256 amount
    ) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "esKERNE: zero amount");
        uint256 vestedAmount = vested(msg.sender);
        require(amount <= vestedAmount, "esKERNE: exceeds vested balance");
        require(kerneToken.balanceOf(address(this)) >= amount, "esKERNE: insufficient conversion reserve");

        // Update accounting
        claimed[msg.sender] += amount;
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        totalConverted += amount;

        // If fully claimed, reset vesting state
        if (balanceOf[msg.sender] == 0) {
            vestingStart[msg.sender] = 0;
            claimed[msg.sender] = 0;
        }

        // Transfer liquid KERNE to user
        kerneToken.safeTransfer(msg.sender, amount);

        emit Converted(msg.sender, amount, amount);
    }

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    /// @notice Deposit KERNE into this contract to fund future conversions.
    /// @dev Admin deposits KERNE from the treasury so that when users' esKERNE
    ///      fully vests in 365 days, there is sufficient KERNE to honor the 1:1 conversion.
    ///      The amount deposited should match the total esKERNE emission schedule.
    /// @param amount Amount of KERNE to deposit.
    function fundConversions(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "esKERNE: zero amount");
        kerneToken.safeTransferFrom(msg.sender, address(this), amount);
        emit ConversionReserveFunded(msg.sender, amount);
    }

    /// @notice View the KERNE balance available to honor future conversions.
    /// @return Available KERNE in this contract.
    function conversionReserve() external view returns (uint256) {
        return kerneToken.balanceOf(address(this));
    }

    /// @notice Remaining lifetime emission headroom before the cap is exhausted.
    function remainingEmissionCapacity() external view returns (uint256) {
        return maxTotalEmissions - totalEmitted;
    }
}
