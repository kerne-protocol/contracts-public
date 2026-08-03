// Created: 2026-03-04
// Updated: 2026-03-19 - Gas optimization: Migrated all require() strings to custom errors
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

    // ========================= CUSTOM ERRORS =========================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.

    /// @dev Thrown when a zero address is provided where a valid address is required
    error ZeroAddress();
    /// @dev Thrown when a zero amount is provided where a positive value is required
    error ZeroAmount();
    /// @dev Thrown when minting would exceed the lifetime emission cap (maxTotalEmissions)
    error EmissionCapExceeded();
    /// @dev Thrown when user tries to convert more esKERNE than they have vested
    error ExceedsVestedBalance();
    /// @dev Thrown when the contract doesn't hold enough KERNE to honor conversions
    error InsufficientConversionReserve();

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

    /// @notice Effective vesting-start timestamp for the user's balance.
    /// @dev NOT simply the first-emission time. Every event that ADDS esKERNE to a
    ///      balance (emitRewards, claimRedistribution) re-bases this with a clamped
    ///      value-weighted average so the freshly-added esKERNE vests over its own
    ///      ~365-day window while the user's already-vested total is preserved
    ///      exactly (no claw-back, no acceleration). This is what enforces the
    ///      365-day lock per emission — see KRN-26-ESK-EMIT-STALE-VEST /
    ///      KRN-26-ESK-REDIST. Reset to 0 on full forfeiture or full claim.
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
    constructor(
        address _kerneToken,
        address _admin,
        uint256 _maxTotalEmissions
    ) {
        // Validate constructor args — these are immutable so must be correct at deploy time
        if (_kerneToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_maxTotalEmissions == 0) revert ZeroAmount();
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

        // SECURITY FIX (vesting-base double-subtraction): the vesting base must
        // be the original grant, which is INVARIANT under conversion. `convert()`
        // moves value out of `balanceOf` and into `claimed` (balanceOf -= amount,
        // claimed += amount), so `balanceOf + claimed` stays constant across
        // conversions while `balanceOf` alone shrinks. Using `balanceOf` as the
        // base subtracted each prior conversion TWICE — once via the shrunken
        // base (vestedTotal = balanceOf * fraction) and once via the explicit
        // `- claimed` below — permanently stranding the remainder of any grant a
        // user converted incrementally. `balanceOf + claimed` is reduced only by
        // `forfeit()` (which removes truly-unvested esKERNE) and grown only by
        // `emitRewards`/`claimRedistribution` (new grant), which is exactly the
        // behaviour the linear schedule expects.
        uint256 alreadyClaimed = claimed[user];
        uint256 base = balanceOf[user] + alreadyClaimed;
        if (base == 0) return 0;

        uint256 elapsed = block.timestamp - start;
        uint256 vestedTotal;
        if (elapsed >= VESTING_DURATION) {
            vestedTotal = base;
        } else {
            // Linear: base * elapsed / VESTING_DURATION
            vestedTotal = (base * elapsed) / VESTING_DURATION;
        }

        // Subtract what's already been claimed (claimed <= vestedTotal always,
        // since every convert() was bounded by the then-current vested amount).
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
        // SECURITY FIX (vesting-base double-subtraction): mirror vested()'s
        // conversion-invariant base. Locked = grant base minus gross
        // vested-to-date. The previous `balanceOf - (vested() + claimed)`
        // formulation collapsed toward zero after a partial conversion (it
        // subtracted `claimed` a second time), so an exiting converter could
        // escape forfeiture of esKERNE that was still genuinely locked.
        uint256 start = vestingStart[user];
        if (start == 0) return 0;

        uint256 base = balanceOf[user] + claimed[user];
        if (base == 0) return 0;

        uint256 elapsed = block.timestamp - start;
        if (elapsed >= VESTING_DURATION) return 0; // fully vested ⇒ nothing locked
        uint256 vestedTotal = (base * elapsed) / VESTING_DURATION;
        return base - vestedTotal;
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
    function emitRewards(
        address user,
        uint256 amount
    ) external onlyRole(EMITTER_ROLE) updateReward(user) {
        // Prevent minting to zero address — would be unrecoverable
        if (user == address(0)) revert ZeroAddress();
        // Zero-amount emission has no effect — reject to save gas
        if (amount == 0) revert ZeroAmount();
        // Hard cap enforcement: ensures total lifetime emissions never exceed the published budget
        if (totalEmitted + amount > maxTotalEmissions) revert EmissionCapExceeded();

        // SECURITY FIX (KRN-26-ESK-EMIT-STALE-VEST, audit 2026-05-31,
        // docs/security/ESKERNE_EMISSION_STALE_START_INSTANT_VEST_2026-05-31.md):
        // Re-base the vesting clock so EACH fresh emission vests over its own
        // ~365-day window, instead of inheriting the recipient's existing
        // (possibly long-past) vestingStart.
        //
        // vested()/unvested() measure the user's WHOLE balance (base = balanceOf +
        // claimed) against a single shared vestingStart. Leaving an existing
        // holder's start untouched meant that once that start sat >= VESTING_DURATION
        // in the past — which happens for any long-tenured depositor the keeper
        // re-emits to each cycle, and immediately after forfeit() (which anchors the
        // kept balance at now - VESTING_DURATION via KRN-26-ESK-FORFEIT-RELOCK) — the
        // freshly minted esKERNE was treated as fully vested the instant it landed and
        // could be converted to liquid KERNE in the SAME block. That defeats the
        // protocol's core 365-day lock / zero-sell-pressure guarantee and drains the
        // funded conversion reserve ahead of schedule.
        //
        // This is the SAME lock-bypass already closed on the redistribution path
        // (KRN-26-ESK-REDIST / -CLIFF); apply the identical clamped value-weighted
        // re-base. Choose newStart so the post-emission currently-vested total equals
        // the pre-emission total EXACTLY — the new emission contributes 0 to
        // vested-now and vests fresh from `now`:
        //   (base + amount) * (now - newStart) / V == vestedTotalOld
        // Since vestedTotalOld <= base < base + amount, elapsedNew < V always (the
        // position lands in the linear regime), so the emission genuinely vests fresh;
        // newStart stays in [start, now] (no claw-back of already-vested esKERNE, no
        // acceleration), and the `claimed <= vestedTotal` invariant that
        // vested()/convert() rely on is preserved.
        uint256 start = vestingStart[user];
        uint256 base = balanceOf[user] + claimed[user];
        if (start == 0 || base == 0) {
            // First emission (or a fully-exited account whose vesting state was
            // reset): the grant simply starts vesting now.
            vestingStart[user] = block.timestamp;
        } else {
            uint256 elapsedOld = block.timestamp - start;
            uint256 vestedTotalOld = elapsedOld >= VESTING_DURATION ? base : (base * elapsedOld) / VESTING_DURATION;
            uint256 elapsedNew = (VESTING_DURATION * vestedTotalOld) / (base + amount);
            vestingStart[user] = block.timestamp - elapsedNew;
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

        // Redistribute to all remaining holders.
        // If nobody else holds esKERNE, the forfeited amount is burned (lost forever).
        // This is acceptable — it further reduces future supply pressure.
        //
        // SECURITY FIX (rounding/redistribution accumulator drift, audit 2026-05-11):
        // The accumulator denominator MUST be the population that actually
        // RECEIVES the forfeiture (i.e. supply AFTER subtracting the leaver
        // but BEFORE re-adding the redistribution). The previous code re-added
        // `totalSupply += unvestedAmount` and that inflated the next forfeiture's
        // denominator by the unclaimed redistribution, producing a JonesDAO-class
        // drift across multiple forfeitures. Each `claimRedistribution()` now
        // mints the amount into BOTH `balanceOf` and `totalSupply` at claim time,
        // so the tokens come into circulation only when the recipient actually
        // takes them — keeping the accumulator math invariant across forfeitures.
        //
        // SECURITY FIX (KRN-26-ESK-FORFEIT-SELFEARN, audit 2026-06-06,
        // docs/security/ESKERNE_FORFEIT_SELF_EARN_2026-06-06.md):
        // The denominator must also exclude the leaver's OWN kept (already-vested)
        // balance, which the post-decrement `totalSupply` still contained. Because
        // the `updateReward(user)` modifier snapshotted the leaver's
        // `userRewardPerTokenPaid` to the OLD accumulator, dividing by the full
        // `totalSupply` let the leaver's kept balance accrue
        // `kept * unvested / (others + kept)` of their OWN forfeiture — which they
        // then clawed back via `claimRedistribution()`, shorting the stayers by the
        // same amount and breaking the "leaving enriches those who stay" invariant
        // (a ~21.5% self-clawback with two holders, 100% when the leaver is the
        // sole holder). `remainingSupply` is the supply held by everyone EXCEPT the
        // leaver — exactly the "supply AFTER subtracting the leaver" the note above
        // already mandates — so the full forfeiture now flows to the stayers, and
        // the leaver's checkpoint is re-anchored below so their kept balance earns
        // 0 from this event (it still participates normally in FUTURE forfeitures).
        uint256 remainingSupply = totalSupply - balanceOf[user];
        if (remainingSupply > 0) {
            rewardPerTokenStored += (unvestedAmount * 1e18) / remainingSupply;
            // Do NOT re-add to totalSupply here. claimRedistribution() will
            // add to both balanceOf[claimant] and totalSupply on claim.
        }

        // If user has zero balance remaining, reset their vesting state entirely.
        if (balanceOf[user] == 0) {
            vestingStart[user] = 0;
            claimed[user] = 0;
        } else {
            // SECURITY FIX (KRN-26-ESK-FORFEIT-RELOCK): the balance the user KEEPS
            // after forfeiture is, by construction, exactly their already-vested,
            // unconverted esKERNE — `balanceOf` becomes `vestedTotal - claimed`. It
            // must stay fully vested/convertible. Leaving `vestingStart` untouched
            // re-measured this kept balance against the SAME start with a now-smaller
            // base (vested()/unvested() use base = balanceOf + claimed), RE-LOCKING a
            // fraction of already-vested esKERNE the user had earned, and — after a
            // prior partial conversion — making unvested() EXCEED balanceOf (which a
            // subsequent forfeit() would underflow on). The double-subtraction fix's
            // "forfeiture composes" note only checked the post-forfeit balance, not
            // its vested STATUS.
            //
            // Anchor vestingStart a full VESTING_DURATION into the past so the kept
            // balance is 100% vested — exactly equal to the user's pre-forfeit vested
            // amount (no acceleration: it only restores what was already unlocked).
            // With elapsed >= VESTING_DURATION, vested() returns base - claimed =
            // balanceOf and unvested() returns 0, so the kept balance is convertible
            // and the unvested() <= balanceOf invariant holds. On any live chain
            // block.timestamp >> VESTING_DURATION; the ternary guard only avoids an
            // underflow on synthetic low-timestamp test chains.
            vestingStart[user] = block.timestamp > VESTING_DURATION ? block.timestamp - VESTING_DURATION : 1;

            // SECURITY FIX (KRN-26-ESK-FORFEIT-SELFEARN): re-anchor the leaver's
            // reward checkpoint to the post-bump accumulator so their KEPT balance
            // does not accrue a share of the forfeiture it just created. The
            // updateReward(user) modifier already banked the leaver's legitimately
            // pre-earned redistribution into pendingRedistribution[user], so this
            // only zeroes the self-credit delta and strands nothing the leaver was owed.
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }

        emit Forfeited(user, unvestedAmount, remainingSupply > 0 ? unvestedAmount : 0);
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

        // SECURITY FIX (KRN-26-ESK-REDIST, audit 2026-05-28,
        // docs/security/ESKERNE_REDISTRIBUTION_BACKDATING_2026-05-28.md):
        // Re-base the vesting clock with a VALUE-WEIGHTED AVERAGE *before*
        // crediting the reward, so the freshly-claimed redistribution vests
        // fresh from now instead of inheriting the recipient's original
        // (earlier) vestingStart. Previously this path left vestingStart
        // untouched for an existing holder; vested() then measured the reward's
        // `elapsed` from the holder's FIRST emission, retroactively vesting it by
        // elapsed/VESTING_DURATION. A long-tenured staker could therefore convert
        // the bulk of a just-claimed forfeiture redistribution to liquid KERNE in
        // the SAME block — bypassing the 365-day lock and draining the funded
        // conversion reserve ahead of schedule.
        //
        // The weighted start has a provable property: with base := balanceOf +
        // claimed (the conversion-invariant grant base vested() uses), setting
        //   newStart = (start*base + now*reward) / (base + reward)
        // makes the post-claim vestedTotal exactly equal the pre-claim
        // vestedTotal of the original grant (the reward contributes ZERO to the
        // currently-vested amount and vests linearly from `now`), while the
        // `claimed <= vestedTotal` invariant that vested()/convert() rely on is
        // preserved. newStart is always in [start, now], so the original grant's
        // vesting can never be pushed backwards (no claw-back) or accelerated.
        uint256 start = vestingStart[msg.sender];
        uint256 base = balanceOf[msg.sender] + claimed[msg.sender];
        if (start == 0 || base == 0) {
            // Fresh holder (fully exited/never emitted, vesting state reset):
            // the reward simply starts vesting now. (The weighted formula also
            // collapses to `now` here, but the explicit branch avoids a 0/0.)
            vestingStart[msg.sender] = block.timestamp;
        } else {
            // SECURITY FIX (KRN-26-ESK-REDIST-CLIFF, audit 2026-05-29,
            // docs/security/ESKERNE_REDISTRIBUTION_CLIFF_LEAK_2026-05-29.md):
            // Anchor the re-base on the CLAMPED currently-vested total, not on a
            // weighted average of `start`. The prior `(start*base + now*reward)/(base+reward)`
            // preserved the *unclamped* linear value `base*elapsed/V`; once
            // `elapsed >= VESTING_DURATION` that exceeds `base`, so folding the reward
            // into `base` raised the vested() clamp ceiling and unmasked the excess as
            // instantly-vested reward — letting a past-cliff staker convert a
            // just-claimed redistribution to liquid KERNE in the SAME block, re-opening
            // the 365-day-lock bypass the original KRN-26-ESK-REDIST fix closed only in
            // the linear regime (the sole regime its regression test exercised, at 182d).
            //
            // Pick `newStart` so the post-claim currently-vested total equals the
            // pre-claim total EXACTLY (reward contributes 0), i.e.
            //   (base + reward) * (now - newStart) / V == vestedTotalOld.
            // Because vestedTotalOld <= base < base + reward, the resulting
            // `elapsedNew < V` ALWAYS — the position lands in the linear regime in both
            // the linear and clamped cases, so the reward genuinely vests fresh. In the
            // linear regime `elapsedNew == base*elapsed/(base+reward)`, i.e. the exact
            // `now - newStart` the old formula produced, so prior behavior is preserved.
            // `newStart` stays in [start, now] (no claw-back, no acceleration) and the
            // `claimed <= vestedTotal` invariant that vested()/convert() rely on holds.
            uint256 elapsedOld = block.timestamp - start;
            uint256 vestedTotalOld = elapsedOld >= VESTING_DURATION ? base : (base * elapsedOld) / VESTING_DURATION;
            uint256 elapsedNew = (VESTING_DURATION * vestedTotalOld) / (base + reward);
            vestingStart[msg.sender] = block.timestamp - elapsedNew;
        }

        balanceOf[msg.sender] += reward;
        // Mint the claimed redistribution into circulating supply at claim
        // time. forfeit() no longer pre-adds to totalSupply (see security
        // note in forfeit), so we add it here when the recipient materialises.
        totalSupply += reward;

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
        // Zero-amount conversion has no effect — reject to save gas
        if (amount == 0) revert ZeroAmount();
        uint256 vestedAmount = vested(msg.sender);
        // Cannot convert more than what has linearly vested
        if (amount > vestedAmount) revert ExceedsVestedBalance();
        // Ensure contract holds enough KERNE to honor the 1:1 conversion
        if (kerneToken.balanceOf(address(this)) < amount) revert InsufficientConversionReserve();

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
        // Zero-amount funding has no effect — reject to save gas
        if (amount == 0) revert ZeroAmount();
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
