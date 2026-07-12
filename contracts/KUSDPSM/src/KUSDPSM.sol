// SPDX-License-Identifier: MIT
// Updated: 2026-03-20 - Gas optimization: Migrated all require() strings to custom errors
// Created: 2026-01-10
// Updated: 2026-02-10 - Security Hardening: Overflow protection, oracle staleness, flash loan bounds
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";

/**
 * @title KUSDPSM
 * @author Kerne Protocol
 * @notice Peg Stability Module for kUSD.
 * Allows 1:1 swaps between kUSD and other major stables to maintain the peg.
 * Hardened with flash loans, tiered institutional fees, and Oracle-guarded circuit breakers.
 */
contract KUSDPSM is AccessControl, ReentrancyGuard, Pausable, IERC3156FlashLender {
    // ========================= CUSTOM ERRORS =========================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.
    // Migrated as part of Batch 3 custom error migration (Phase 12).
    /// @dev Replaces: require(..., "Overflow: amount too large")
    error AmountOverflow();
    /// @dev Replaces: require(..., "BPS too high")
    error BpsTooHigh();
    /// @dev Replaces: require(..., "Fee too high")
    error FeeTooHigh();
    /// @dev Replaces: require(..., "Flash loan callback failed")
    error FlashLoanCallbackFailed();
    /// @dev Replaces: require(..., "Flash loan exceeds available balance")
    error FlashLoanExceedsBalance();
    /// @dev Replaces: require(..., "Insufficient stable reserves (Peg Defense Failed)")
    error InsufficientStableReserves();
    /// @dev Replaces: require(..., "Invalid oracle price")
    error InvalidOraclePrice();
    /// @dev KRN-26-PSM-DEPEG-FAIL-OPEN: a swap was attempted for a stable that has no depeg
    ///      oracle configured while the depeg gate is enabled. The gate now FAILS CLOSED on an
    ///      unset oracle (mirroring the KRN-26-PSM-SOLVENCY-FAIL-OPEN solvency-gate hardening)
    ///      so an unconfigured stable can never be minted/redeemed without depeg protection.
    ///      To run a stable without an oracle on purpose, the Safe must call
    ///      setDepegCheckDisabled(true) — an explicit, event-logged opt-out.
    error DepegOracleNotConfigured();
    /// @dev KRN-26-PSM-ORACLE-HEARTBEAT: setMaxOracleDelay rejects a window above
    ///      MAX_ORACLE_DELAY_BOUND, so the staleness guard can never be stretched into a
    ///      de-facto disable. Disabling the depeg gate outright is the separate, admin-gated
    ///      setDepegCheckDisabled.
    error OracleDelayTooHigh();
    /// @dev KRN-26-PSM-FEE-SKIM: setTreasury rejects the zero address.
    error InvalidTreasury();
    /// @dev Replaces: require(..., "kUSD minting failed")
    error KusdMintFailed();
    /// @dev Replaces: require(..., "Oracle price stale")
    error OraclePriceStale();
    /// @dev Replaces: require(..., "Protocol insolvency: PSM operations halted")
    error ProtocolInsolvency();
    /// @dev KRN-26-PSM-FEE-SKIM: skim request exceeds the strictly-bounded skimmable surplus.
    error SkimExceedsSurplus();
    /// @dev Replaces: require(..., "Stable cap exceeded")
    error StableCapExceeded();
    /// @dev Replaces: require(..., "Stable depegged: Circuit breaker triggered")
    error StableDepegged();
    /// @dev Replaces: require(..., "Stable not supported")
    error StableNotSupported();
    /// @dev Replaces: require(..., "Too many fee tiers")
    error TooManyFeeTiers();
    /// @dev KRN-26-PSM-FEE-SKIM: skimSurplus called before a treasury destination is configured.
    error TreasuryNotSet();
    /// @dev Replaces: require(..., "Unsupported token")
    error UnsupportedToken();
    /// @dev Replaces: require(..., "Flash loan amount must be > 0")
    error ZeroFlashLoanAmount();
    /// @dev KRN-26-PSM-FEE-SKIM: zero-amount skims are rejected loudly (no no-op PoR events).
    error ZeroSkimAmount();

    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ARBITRAGEUR_ROLE = keccak256("ARBITRAGEUR_ROLE");

    IERC20 public immutable kUSD;
    address public vault;

    mapping(address => uint256) public swapFees;
    mapping(address => bool) public supportedStables;
    mapping(address => address) public oracles;
    mapping(address => uint256) public maxDepegBps;

    /// @notice Per-stable staleness window (seconds) for the depeg oracle. 0 = use
    ///         DEFAULT_MAX_ORACLE_DELAY.
    /// @dev SECURITY (KRN-26-PSM-ORACLE-HEARTBEAT, 2026-06-11, see the addendum in
    ///      docs/security/PSM_DEPEG_GATE_FAIL_OPEN_2026-06-10.md): the staleness bound was a
    ///      hardcoded 1 hour, but Chainlink stablecoin feeds update on deviation OR heartbeat —
    ///      USDC/USD on Base (0x7e860098...) runs a 24h heartbeat and only deviates ~0.3%, so its
    ///      price is routinely many hours old (measured 2026-06-11: ten consecutive ~24.00h
    ///      gaps). With the depeg gate armed (fail-closed + setOracle wired), the 1h bound would
    ///      revert OraclePriceStale for ~96% of every day — a bricked PSM. The window is now
    ///      per-stable, MANAGER-set, bounded, and event-logged; unset keeps the original 1h.
    mapping(address => uint256) public maxOracleDelay;

    uint256 public constant DEFAULT_MAX_DEPEG_BPS = 200; // 2%
    /// @notice Staleness window used when maxOracleDelay[stable] is unset (the pre-existing 1h).
    uint256 public constant DEFAULT_MAX_ORACLE_DELAY = 1 hours;
    /// @notice Hard ceiling for setMaxOracleDelay — covers a 24h-heartbeat feed with margin while
    ///         keeping the staleness guard meaningful (KRN-26-PSM-ORACLE-HEARTBEAT).
    uint256 public constant MAX_ORACLE_DELAY_BOUND = 48 hours;
    uint256 public minSolvencyThreshold = 10100; // 101%

    struct TieredFee {
        uint256 threshold;
        uint256 feeBps;
    }

    mapping(address => TieredFee[]) public tieredFees;

    bool public virtualPegEnabled;
    uint256 public virtualPegFeeBps;
    uint256 public flashFeeBps;

    /// @notice Explicit opt-out for the vault-side solvency gate.
    /// @dev SECURITY (audit 2026-05-23, see docs/security/PSM_SOLVENCY_FAIL_OPEN_2026-05-23.md):
    ///      Prior to this flag the only way to neutralize `_checkSolvency` was to set `vault =
    ///      address(0)` or `minSolvencyThreshold = 0` — both sentinel values that look like
    ///      misconfiguration. With this flag the disable is an explicit admin action with an
    ///      event trail, and every error branch of the staticcall now fails closed.
    bool public solvencyCheckDisabled;

    /// @notice Explicit opt-out for the stable-side depeg gate.
    /// @dev SECURITY (KRN-26-PSM-DEPEG-FAIL-OPEN, 2026-06-10, see
    ///      docs/security/PSM_DEPEG_GATE_FAIL_OPEN_2026-06-10.md): historically `_checkDepeg`
    ///      silently no-op'd when `oracles[stable] == address(0)` — a fail-OPEN that left the
    ///      PSM minting/redeeming a stable with ZERO depeg protection whenever its oracle was
    ///      unset (the live default: the deploy scripts call addStable but never setOracle). A
    ///      depeg of that stable would then let an arbitrageur mint kUSD against under-$1
    ///      collateral and drain backing. This is the same fail-open class the solvency gate
    ///      closed (`solvencyCheckDisabled`); the depeg gate now matches: it FAILS CLOSED on an
    ///      unset oracle unless this flag is explicitly set true by the Safe.
    bool public depegCheckDisabled;

    /// @notice Circuit breaker for total exposure per stable
    mapping(address => uint256) public stableCaps;
    mapping(address => uint256) public currentExposure;

    /// @notice Destination for skimmed protocol fee revenue (KerneTreasury). Set by the Safe.
    /// @dev FEATURE (KRN-26-PSM-FEE-SKIM, 2026-06-09 — designed into PSM v3, see
    ///      docs/security/PSM_FEE_SKIM_SURPLUS_2026-06-09.md): before v3 the PSM had NO exit
    ///      path for accrued swap fees — the only ways value left the contract were user
    ///      redemptions and flash loans, so every basis point of mint/redeem fee was
    ///      permanently locked in the contract and the protocol "fee switch" was decorative.
    address public treasury;

    /// @notice Un-skimmed protocol fee revenue per stable, in the stable's NATIVE units.
    /// @dev KRN-26-PSM-FEE-SKIM ledger. Incremented by the mint fee (already
    ///      stable-denominated), the redeem fee (normalized DOWN from kUSD units, flooring —
    ///      under-counting is the safe direction), and stable-side flash-loan fees.
    ///      Decremented only by `skimSurplus`. Reserve top-ups / peg-defense liquidity /
    ///      donations never enter this ledger, so they can never be skimmed.
    mapping(address => uint256) public accruedFees;

    event StableAdded(address indexed stable, uint256 fee, uint256 cap);
    event Swap(address indexed user, address indexed fromToken, address indexed toToken, uint256 amount, uint256 fee);
    event TieredFeeAdded(address indexed stable, uint256 threshold, uint256 feeBps);
    event ExposureUpdated(address indexed stable, uint256 newExposure);
    /// @notice Emitted when the explicit `solvencyCheckDisabled` flag toggles.
    /// @dev SECURITY (audit 2026-05-23): on-chain audit trail of every solvency-gate enable/disable
    ///      action, so the gate state can be reconstructed from event logs without relying on the
    ///      ambiguous sentinel values `vault == address(0)` or `minSolvencyThreshold == 0`.
    event SolvencyCheckDisabledUpdated(bool disabled);
    /// @notice Emitted when the explicit `depegCheckDisabled` flag toggles (KRN-26-PSM-DEPEG-FAIL-OPEN).
    /// @dev On-chain audit trail of every depeg-gate enable/disable, symmetric with
    ///      SolvencyCheckDisabledUpdated, so the gate state is reconstructable from logs.
    event DepegCheckDisabledUpdated(bool disabled);
    /// @notice Emitted when a stable's oracle-staleness window changes
    ///         (KRN-26-PSM-ORACLE-HEARTBEAT). 0 means "back to DEFAULT_MAX_ORACLE_DELAY".
    event MaxOracleDelayUpdated(address indexed stable, uint256 delaySeconds);
    /// @notice Emitted when the Safe re-points the fee-skim destination (KRN-26-PSM-FEE-SKIM).
    event TreasuryUpdated(address indexed treasury);
    /// @notice Emitted on every fee skim — consumed by the PoR pipeline so protocol revenue is
    ///         reconstructable from event logs alone (KRN-26-PSM-FEE-SKIM).
    event SurplusSkimmed(address indexed stable, address indexed treasury, uint256 amount);

    constructor(
        address _kUSD,
        address _admin
    ) {
        kUSD = IERC20(_kUSD);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    function _checkDepeg(
        address stable
    ) internal view {
        // SECURITY FIX (KRN-26-PSM-DEPEG-FAIL-OPEN, 2026-06-10,
        // docs/security/PSM_DEPEG_GATE_FAIL_OPEN_2026-06-10.md): FAIL CLOSED on a missing oracle.
        // The prior `if (oracle == address(0)) return;` silently skipped depeg protection for any
        // stable whose oracle was unset — which is the live default (addStable never wires an
        // oracle, and no deploy/setup script calls setOracle), so the production PSM ran with NO
        // depeg gate at all. A depeg of that stable then lets an arbitrageur mint kUSD against
        // sub-$1 collateral (or redeem reserves at >$1) and drain backing. This is the same
        // fail-open class the solvency gate already closed (PSM_SOLVENCY_FAIL_OPEN); the depeg
        // gate now matches: an unset oracle reverts unless the Safe has explicitly opted out via
        // setDepegCheckDisabled(true), which is event-logged rather than an invisible sentinel.
        if (depegCheckDisabled) return;
        address oracle = oracles[stable];
        if (oracle == address(0)) revert DepegOracleNotConfigured();

        (, int256 price,, uint256 updatedAt,) = IAggregatorV3(oracle).latestRoundData();
        if (!(price > 0)) revert InvalidOraclePrice();
        // SECURITY FIX: Reduced staleness threshold from 24h to 1h to prevent stale price exploitation
        // KRN-26-PSM-ORACLE-HEARTBEAT (2026-06-11): the 1h default is right for high-frequency
        // feeds but stricter than the heartbeat of Chainlink's stablecoin feeds (USDC/USD on Base
        // updates on ~0.3% deviation or a 24h heartbeat, so its price is routinely hours old).
        // With the gate fail-closed and an oracle wired, a hardcoded 1h would revert nearly every
        // swap. The window is per-stable via setMaxOracleDelay (bounded, MANAGER-gated,
        // event-logged); unset keeps the original 1h posture.
        uint256 maxDelay = maxOracleDelay[stable] == 0 ? DEFAULT_MAX_ORACLE_DELAY : maxOracleDelay[stable];
        if (!(block.timestamp <= updatedAt + maxDelay)) revert OraclePriceStale();

        uint8 decimals = IAggregatorV3(oracle).decimals();
        // SECURITY FIX: Prevent underflow if oracle decimals > 18
        uint256 normalizedPrice;
        if (decimals <= 18) {
            normalizedPrice = uint256(price) * (10 ** (18 - decimals));
        } else {
            normalizedPrice = uint256(price) / (10 ** (decimals - 18));
        }
        uint256 targetPrice = 1e18; // 1.0 USD in 18 decimals

        uint256 threshold = maxDepegBps[stable] == 0 ? DEFAULT_MAX_DEPEG_BPS : maxDepegBps[stable];

        uint256 deviation =
            normalizedPrice > targetPrice ? normalizedPrice - targetPrice : targetPrice - normalizedPrice;
        if (!((deviation * 10000) / targetPrice <= threshold)) revert StableDepegged();
    }

    /// @dev SECURITY (audit 2026-05-23, PSM_SOLVENCY_FAIL_OPEN_2026-05-23.md):
    ///      The previous implementation no-op'd silently on three independent paths —
    ///      `vault == address(0)`, staticcall `success == false`, and `data.length != 32`.
    ///      Each made the supposedly load-bearing solvency gate disappear without a revert.
    ///      The patched version requires an explicit `solvencyCheckDisabled` toggle to skip
    ///      the check, and fails closed on every error branch so a broken oracle or a wrong
    ///      vault selector cannot silently open the PSM during a stress event. The `ratio <
    ///      minSolvencyThreshold` revert is retained for the happy path; setting
    ///      `minSolvencyThreshold` to zero remains a config-level disable but is now visible
    ///      as "the threshold is zero," not as "the gate has vanished."
    function _checkSolvency() internal view {
        if (solvencyCheckDisabled) return;
        if (vault == address(0)) revert ProtocolInsolvency();
        (bool success, bytes memory data) = vault.staticcall(abi.encodeWithSignature("getSolvencyRatio()"));
        if (!success || data.length != 32) revert ProtocolInsolvency();
        uint256 ratio = abi.decode(data, (uint256));
        if (!(ratio >= minSolvencyThreshold)) revert ProtocolInsolvency();
    }

    /// @dev Selects the fee bps for `stable` given a swap size ALREADY expressed in the
    ///      stable's native units. SECURITY (KRN-26-PSM-TIER-UNIT): tieredFees[stable]
    ///      thresholds are denominated in the stable's native decimals (e.g. 6dp for USDC)
    ///      by setTieredFees callers, the unit/stress tests, and the frontend. Both swap
    ///      directions MUST pass a stable-unit size here — the stable->kUSD mint path's
    ///      `amount` is already stable-denominated, while the kUSD->stable redeem path
    ///      normalizes its 18dp kUSD `amount` down first (see _swapKUSDForStableInner).
    ///      Passing a raw 18dp kUSD amount would be 10^(kusd-stable) too large and always
    ///      match the lowest-fee (highest-threshold) tier, under-charging every redemption.
    function _selectFeeBps(
        address stable,
        uint256 stableUnitSize
    ) internal view returns (uint256) {
        if (virtualPegEnabled) {
            return virtualPegFeeBps;
        }

        uint256 feeBps = swapFees[stable];
        TieredFee[] storage tiers = tieredFees[stable];

        for (uint256 i = 0; i < tiers.length; i++) {
            if (stableUnitSize >= tiers[i].threshold) {
                feeBps = tiers[i].feeBps;
                break;
            }
        }
        return feeBps;
    }

    /// @notice Returns the swap fee for `amount` of `stable`.
    /// @dev `amount` is interpreted in the stable's native units, which is the canonical
    ///      unit for tieredFees thresholds. The stable->kUSD mint path and external display
    ///      callers (frontend) pass stable-denominated amounts directly. The kUSD->stable
    ///      redeem path does NOT call this with a raw kUSD amount — it normalizes to stable
    ///      units and calls _selectFeeBps (KRN-26-PSM-TIER-UNIT).
    function getFee(
        address stable,
        uint256 amount
    ) public view returns (uint256) {
        return (amount * _selectFeeBps(stable, amount)) / 10000;
    }

    bool public mintingEnabled;

    function setMintingEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintingEnabled = enabled;
    }

    /// @notice Swaps stable -> kUSD, sending the kUSD to msg.sender. Backwards-compat
    ///         wrapper around `swapStableForKUSDTo`.
    function swapStableForKUSD(
        address stable,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        _swapStableForKUSDInner(stable, amount, msg.sender);
    }

    /// @notice Swaps stable -> kUSD with an explicit recipient.
    /// @dev SECURITY (audit 2026-05-11): allows the caller to receive kUSD at a
    ///      different address than msg.sender. Use case 1: smart-wallet users
    ///      (Safe accounts) want to send the output to a separate EOA. Use case
    ///      2: USDC-blacklisted users with kUSD redemption rights can avoid the
    ///      stable-side `IERC20.safeTransfer` revert by specifying a non-
    ///      blacklisted recipient. The pull side still uses msg.sender — only
    ///      the output destination is configurable.
    function swapStableForKUSDTo(
        address stable,
        uint256 amount,
        address recipient
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert StableNotSupported();
        _swapStableForKUSDInner(stable, amount, recipient);
    }

    function _swapStableForKUSDInner(
        address stable,
        uint256 amount,
        address recipient
    ) internal {
        // Check support FIRST so an unsupported stable reverts StableNotSupported, not the
        // depeg/solvency gates (KRN-26-PSM-DEPEG-FAIL-OPEN made _checkDepeg fail closed, which
        // would otherwise pre-empt the support check for an unsupported, oracle-less stable).
        // The safety gates only apply to a stable the PSM actually transacts.
        if (!(supportedStables[stable])) revert StableNotSupported();
        _checkDepeg(stable);
        _checkSolvency();

        // SECURITY FIX (KRN-26-PSM-EXPOSURE-FLOOR-RESET, 2026-06-07): bind the concentration cap on
        // the GREATER of the tracked net exposure and the PSM's ACTUAL stable balance.
        // `currentExposure[stable]` is a net (gross-mint-in minus net-redeem-out, saturating-at-zero)
        // counter. The 2026-05-23 unit-mismatch fix made the redeem decrement unit-correct but left
        // the saturating floor — which is the right value FOR a net counter. The residual flaw is
        // that gating mints on that counter alone is gameable: kUSD is a bearer asset, so ANY holder
        // can redeem against the PSM's own stable reserves, and a redemption whose stable payout
        // exceeds the tracked exposure (only reachable when the PSM holds stable beyond what the mint
        // path counted — Safe reserve top-ups / donations) floors `currentExposure` to 0 while the
        // PSM STILL HOLDS that stable. A counter-only gate would then re-open the full `stableCaps`
        // headroom, letting a depositor mint a fresh cap of new kUSD liability ON TOP of the still-held
        // reserves and push real single-stable concentration past the cap while the counter reads 0.
        // `balanceOf` reflects the PSM's true holdings and cannot be lowered by a third party below
        // what actually remains, so max(counter, balance) makes the cap bind on real concentration.
        // See docs/security/PSM_EXPOSURE_FLOOR_RESET_2026-06-07.md.
        uint256 effectiveExposure = currentExposure[stable];
        uint256 heldBalance = IERC20(stable).balanceOf(address(this));
        if (heldBalance > effectiveExposure) effectiveExposure = heldBalance;
        if (!(effectiveExposure + amount <= stableCaps[stable])) revert StableCapExceeded();

        uint256 fee = getFee(stable, amount);
        uint256 amountAfterFee = amount - fee;

        // SECURITY FIX: Normalize decimals between stable and kUSD
        // If stable is 6 decimals (USDC/USDT) and kUSD is 18 decimals, we must scale up
        uint8 stableDecimals = IERC20Metadata(stable).decimals();
        uint8 kusdDecimals = IERC20Metadata(address(kUSD)).decimals();
        uint256 normalizedAmountAfterFee;
        if (stableDecimals <= kusdDecimals) {
            // SECURITY FIX: Overflow protection for decimal normalization
            uint256 multiplier = 10 ** (kusdDecimals - stableDecimals);
            if (!(amountAfterFee <= type(uint256).max / multiplier)) revert AmountOverflow();
            normalizedAmountAfterFee = amountAfterFee * multiplier;
        } else {
            normalizedAmountAfterFee = amountAfterFee / (10 ** (stableDecimals - kusdDecimals));
        }

        currentExposure[stable] += amount;
        // FEATURE (KRN-26-PSM-FEE-SKIM): the mint fee is the slice of the gross stable deposit
        // not matched by minted kUSD — protocol revenue, recorded so skimSurplus can extract it.
        // Note the exposure counter above is GROSS of this fee; skimmableSurplus strips the
        // un-skimmed ledger back out before treating the counter as untouchable backing.
        accruedFees[stable] += fee;
        IERC20(stable).safeTransferFrom(msg.sender, address(this), amount);

        if (mintingEnabled) {
            // Attempt to mint kUSD if enabled (use normalized amount)
            (bool success,) = address(kUSD)
                .call(abi.encodeWithSignature("mint(address,uint256)", recipient, normalizedAmountAfterFee));
            if (!(success)) revert KusdMintFailed();
        } else {
            kUSD.safeTransfer(recipient, normalizedAmountAfterFee);
        }

        emit Swap(msg.sender, stable, address(kUSD), amount, fee);
        emit ExposureUpdated(stable, currentExposure[stable]);
    }

    /**
     * @notice Swaps kUSD for a supported stablecoin.
     * @dev Peg Defense: redemptions are funded solely by the PSM's own stable reserves. If those
     *      reserves fall short the swap reverts `InsufficientStableReserves` and the Safe tops up the
     *      PSM's reserves. SECURITY (KRN-26-PSM-INS-CROSSASSET, 2026-06-03): the prior "draw from the
     *      Insurance Fund on a shortfall" branch was removed — the live fund's immutable asset is WETH
     *      (18dp) while the draw requested the stable's native units (USDC, 6dp), so it could never
     *      restore the stable reserve and the low-level call's success was swallowed. See
     *      docs/security/PSM_INSURANCE_CROSSASSET_DRAW_2026-06-03.md.
     */
    /// @notice Swaps kUSD -> stable, sending the stable to msg.sender. Backwards-compat
    ///         wrapper around `swapKUSDForStableTo`.
    function swapKUSDForStable(
        address stable,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        _swapKUSDForStableInner(stable, amount, msg.sender);
    }

    /// @notice Swaps kUSD -> stable with an explicit recipient.
    /// @dev SECURITY (audit 2026-05-11): allows the caller to direct the stable
    ///      output to a different address. The most important use case: a user
    ///      whose msg.sender address has been blacklisted by the stable's
    ///      issuer (USDC's Centre.blacklister, USDT's blacklist) can still
    ///      redeem their kUSD by routing to a clean recipient. Without this,
    ///      a blacklisted holder of kUSD has no on-chain way to exit, since
    ///      `IERC20(stable).safeTransfer(blacklistedSender)` reverts and
    ///      drags the entire swap with it.
    function swapKUSDForStableTo(
        address stable,
        uint256 amount,
        address recipient
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert StableNotSupported();
        _swapKUSDForStableInner(stable, amount, recipient);
    }

    function _swapKUSDForStableInner(
        address stable,
        uint256 amount,
        address recipient
    ) internal {
        // Check support FIRST so an unsupported stable reverts StableNotSupported, not the
        // depeg/solvency gates (KRN-26-PSM-DEPEG-FAIL-OPEN made _checkDepeg fail closed, which
        // would otherwise pre-empt the support check for an unsupported, oracle-less stable).
        // The safety gates only apply to a stable the PSM actually transacts.
        if (!(supportedStables[stable])) revert StableNotSupported();
        _checkDepeg(stable);
        _checkSolvency();

        // SECURITY FIX: Normalize decimals from kUSD to stable
        // If kUSD is 18 decimals and stable is 6 decimals (USDC/USDT), we must scale down
        uint8 stableDecimals = IERC20Metadata(stable).decimals();
        uint8 kusdDecimals = IERC20Metadata(address(kUSD)).decimals();

        // SECURITY FIX (KRN-26-PSM-TIER-UNIT): select the tiered fee using the swap size
        // expressed in the stable's NATIVE units. `amount` here is kUSD (18dp), but
        // tieredFees[stable] thresholds are stable-denominated (6dp for USDC) per setTieredFees,
        // the unit/stress tests, and the frontend. Normalize the size DOWN before the tier lookup;
        // otherwise the raw 18dp value is 10^(kusd-stable) too large and every redemption matches
        // the lowest-fee (institutional) tier, systematically under-charging the redemption fee.
        // The fee bps is still applied to the raw kUSD `amount`, so `amountAfterFee` stays in kUSD.
        uint256 sizeInStableUnits;
        if (kusdDecimals >= stableDecimals) {
            sizeInStableUnits = amount / (10 ** (kusdDecimals - stableDecimals));
        } else {
            uint256 sizeMultiplier = 10 ** (stableDecimals - kusdDecimals);
            if (!(amount <= type(uint256).max / sizeMultiplier)) revert AmountOverflow();
            sizeInStableUnits = amount * sizeMultiplier;
        }
        uint256 fee = (amount * _selectFeeBps(stable, sizeInStableUnits)) / 10000;
        uint256 amountAfterFee = amount - fee;

        uint256 normalizedAmountAfterFee;
        if (kusdDecimals >= stableDecimals) {
            normalizedAmountAfterFee = amountAfterFee / (10 ** (kusdDecimals - stableDecimals));
        } else {
            // SECURITY FIX: Overflow protection for decimal normalization
            uint256 multiplier = 10 ** (stableDecimals - kusdDecimals);
            if (!(amountAfterFee <= type(uint256).max / multiplier)) revert AmountOverflow();
            normalizedAmountAfterFee = amountAfterFee * multiplier;
        }

        uint256 psmBalance = IERC20(stable).balanceOf(address(this));

        // SECURITY (KRN-26-PSM-INS-CROSSASSET, 2026-06-03): redemptions are funded solely by the
        // PSM's own stable reserves. The former "draw from the Insurance Fund on a shortfall" branch
        // was removed — the live KerneInsuranceFund's immutable asset is WETH (18dp) while this path
        // requested the stable's native units (USDC, 6dp) via `claim(address,uint256)`, so a draw
        // could never restore the stable reserve the check below requires, and the call's success
        // flag was swallowed. A short reserve now reverts explicitly; the Safe tops up PSM reserves.
        // See docs/security/PSM_INSURANCE_CROSSASSET_DRAW_2026-06-03.md.
        if (!(psmBalance >= normalizedAmountAfterFee)) revert InsufficientStableReserves();

        // SECURITY FIX (KRN-24-008): CEI pattern — update state BEFORE external token transfers
        // SECURITY FIX (audit 2026-05-23, PSM_EXPOSURE_UNIT_MISMATCH_2026-05-23.md):
        //   decrement by normalizedAmountAfterFee (stable units) rather than `amount`
        //   (kUSD units). The mint path stores currentExposure in stable units; subtracting
        //   `amount` (kUSD, 18dp) from a USDC-denominated balance (6dp) made any redemption
        //   >= ~1e-12 kUSD overflow the if-check and zero the exposure — fully bypassing
        //   stableCaps[stable]. normalizedAmountAfterFee is the actual stable-unit amount
        //   leaving the PSM, which is exactly the right value to subtract.
        if (currentExposure[stable] >= normalizedAmountAfterFee) {
            currentExposure[stable] -= normalizedAmountAfterFee;
        } else {
            currentExposure[stable] = 0;
        }

        // FEATURE (KRN-26-PSM-FEE-SKIM): the redeem fee is charged in kUSD units but RETAINED
        // as stable (the PSM receives the full kUSD `amount` and pays out only the after-fee
        // stable), so it accrues to the ledger normalized DOWN to the stable's native units —
        // the same normalization the payout uses (KRN-26-PSM-TIER-UNIT). Flooring under-counts
        // by at most 1 stable-wei per redeem, which is the safe direction (never over-skim).
        uint256 feeInStableUnits;
        if (kusdDecimals >= stableDecimals) {
            feeInStableUnits = fee / (10 ** (kusdDecimals - stableDecimals));
        } else {
            uint256 feeMultiplier = 10 ** (stableDecimals - kusdDecimals);
            if (!(fee <= type(uint256).max / feeMultiplier)) revert AmountOverflow();
            feeInStableUnits = fee * feeMultiplier;
        }
        accruedFees[stable] += feeInStableUnits;

        kUSD.safeTransferFrom(msg.sender, address(this), amount);
        IERC20(stable).safeTransfer(recipient, normalizedAmountAfterFee);

        emit Swap(msg.sender, address(kUSD), stable, amount, fee);
        emit ExposureUpdated(stable, currentExposure[stable]);
    }

    // --- Admin Functions ---

    function addStable(
        address stable,
        uint256 feeBps,
        uint256 cap
    ) external onlyRole(MANAGER_ROLE) {
        if (!(feeBps <= 500)) revert FeeTooHigh();
        supportedStables[stable] = true;
        swapFees[stable] = feeBps;
        stableCaps[stable] = cap;
        emit StableAdded(stable, feeBps, cap);
    }

    function setStableCap(
        address stable,
        uint256 cap
    ) external onlyRole(MANAGER_ROLE) {
        stableCaps[stable] = cap;
    }

    /// @dev SECURITY FIX (KRN-24-012): Bounded loop to prevent gas griefing.
    /// @dev SECURITY FIX (audit 2026-05-11): require strictly descending
    ///      thresholds so the `getFee` first-match-wins lookup picks the
    ///      correct (lowest-fee) tier for the largest qualifying threshold.
    ///      Without this, an admin who lists tiers in ascending order would
    ///      silently break fee collection — small swappers would match the
    ///      first low-threshold tier and pay whatever fee happened to be
    ///      configured there.
    function setTieredFees(
        address stable,
        TieredFee[] calldata fees
    ) external onlyRole(MANAGER_ROLE) {
        if (!(fees.length <= 20)) revert TooManyFeeTiers();
        delete tieredFees[stable];
        for (uint256 i = 0; i < fees.length; i++) {
            if (!(fees[i].feeBps <= 500)) revert FeeTooHigh();
            if (i > 0 && fees[i].threshold >= fees[i - 1].threshold) {
                revert("KUSDPSM: tiers must be strictly descending by threshold");
            }
            tieredFees[stable].push(fees[i]);
            emit TieredFeeAdded(stable, fees[i].threshold, fees[i].feeBps);
        }
    }

    function setFlashFee(
        uint256 bps
    ) external onlyRole(MANAGER_ROLE) {
        if (!(bps <= 100)) revert FeeTooHigh();
        flashFeeBps = bps;
    }

    function setVault(
        address _vault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vault = _vault;
    }

    function setOracle(
        address stable,
        address oracle
    ) external onlyRole(MANAGER_ROLE) {
        oracles[stable] = oracle;
    }

    function setMaxDepegBps(
        address stable,
        uint256 bps
    ) external onlyRole(MANAGER_ROLE) {
        if (!(bps <= 1000)) revert BpsTooHigh();
        maxDepegBps[stable] = bps;
    }

    /// @notice Set the per-stable staleness window for the depeg oracle.
    /// @dev SECURITY (KRN-26-PSM-ORACLE-HEARTBEAT): match the window to the wired feed's
    ///      heartbeat plus margin (USDC/USD on Base: 24h heartbeat -> 26h window), otherwise the
    ///      fail-closed depeg gate reverts healthy swaps between feed updates. Bounded by
    ///      MAX_ORACLE_DELAY_BOUND so the window can never become a de-facto disable of the
    ///      staleness guard; 0 resets to DEFAULT_MAX_ORACLE_DELAY (1h).
    /// @param stable The stable whose oracle window is being set.
    /// @param delaySeconds Staleness window in seconds; 0 resets to the default.
    function setMaxOracleDelay(
        address stable,
        uint256 delaySeconds
    ) external onlyRole(MANAGER_ROLE) {
        if (!(delaySeconds <= MAX_ORACLE_DELAY_BOUND)) revert OracleDelayTooHigh();
        maxOracleDelay[stable] = delaySeconds;
        emit MaxOracleDelayUpdated(stable, delaySeconds);
    }

    function setMinSolvencyThreshold(
        uint256 threshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minSolvencyThreshold = threshold;
    }

    /// @notice Explicit on/off for the vault solvency gate.
    /// @dev SECURITY (audit 2026-05-23): the disable is intentionally a separate admin action
    ///      from the `vault` / `minSolvencyThreshold` slots, so the gate's state can be
    ///      determined from a single boolean rather than inferred from sentinel values that
    ///      look like misconfiguration. Use during deliberate emergency windows (e.g. while
    ///      `KerneVault` is being remediated) and flip back to `false` once the underlying
    ///      `getSolvencyRatio()` returns a meaningful number again.
    /// @param disabled True to bypass `_checkSolvency` entirely; false to enforce.
    function setSolvencyCheckDisabled(
        bool disabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        solvencyCheckDisabled = disabled;
        emit SolvencyCheckDisabledUpdated(disabled);
    }

    /// @notice Explicit on/off for the stable-side depeg gate.
    /// @dev SECURITY (KRN-26-PSM-DEPEG-FAIL-OPEN): `_checkDepeg` FAILS CLOSED on a stable with no
    ///      oracle configured. Setting this true is the deliberate, event-logged opt-out for a
    ///      stable intentionally run without an oracle (e.g. an emergency window, or a stable the
    ///      operator monitors off-chain). Prefer wiring a real oracle via `setOracle` over
    ///      disabling the gate; flip back to false once the oracle is configured. Symmetric with
    ///      `setSolvencyCheckDisabled` so both PSM safety gates share one fail-closed posture.
    /// @param disabled True to bypass `_checkDepeg` entirely; false to enforce it.
    function setDepegCheckDisabled(
        bool disabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depegCheckDisabled = disabled;
        emit DepegCheckDisabledUpdated(disabled);
    }

    function pause() external onlyRole(MANAGER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --- Fee Skim (KRN-26-PSM-FEE-SKIM) ---

    /// @notice Points the fee-skim spigot at a treasury (KerneTreasury v2 in production).
    /// @dev DEFAULT_ADMIN (the Safe) only — the destination of protocol revenue is a more
    ///      sensitive lever than the MANAGER-gated skim itself. Zero address is rejected so a
    ///      skim can never burn fees; an unset treasury simply means skims revert TreasuryNotSet.
    function setTreasury(
        address _treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidTreasury();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @notice The amount of `stable` that can be skimmed to the treasury RIGHT NOW without
    ///         touching redemption backing. Consumed by the Safe before proposing a skim and by
    ///         the PoR pipeline as the on-chain "claimable protocol revenue" figure.
    /// @dev Strict bound: `min(accruedFees, balance - max(currentExposure - accruedFees, 0))`.
    ///      `currentExposure` is GROSS of fees (the mint path increments it by the full deposit,
    ///      fee included — see _swapStableForKUSDInner), so the un-skimmed fee ledger is stripped
    ///      out of the counter before treating it as untouchable backing; bounding on the raw
    ///      counter instead would leave every fee permanently trapped (balance == exposure after
    ///      any pure mint flow), recreating the pre-v3 locked-fee failure mode at the design
    ///      level. The outer `min` against the ledger means reserve top-ups / donations are never
    ///      skimmable, and the balance-side saturation means a PSM whose reserves were drawn down
    ///      by redemptions below cumulative fees can only skim what is actually still there.
    function skimmableSurplus(
        address stable
    ) public view returns (uint256) {
        uint256 fees = accruedFees[stable];
        if (fees == 0) return 0;
        uint256 held = IERC20(stable).balanceOf(address(this));
        uint256 exposure = currentExposure[stable];
        uint256 netBacking = exposure > fees ? exposure - fees : 0;
        uint256 headroom = held > netBacking ? held - netBacking : 0;
        return fees < headroom ? fees : headroom;
    }

    /// @notice Skims `amount` of accrued `stable` fee revenue to the configured treasury.
    /// @dev The PSM v3 fee spigot — the first extractable protocol revenue path in Kerne's
    ///      history (pre-v3, fees accrued with no exit short of another migration). Invariants,
    ///      each enforced here and pinned in test/security/KUSDPSMFeeSkim.t.sol:
    ///        1. BACKING IS NEVER PULLED — `amount` is strictly bounded by skimmableSurplus,
    ///           which itself is bounded by the fee ledger AND the balance over net backing.
    ///        2. MANAGER (the Safe) ONLY, and only while not paused — a paused PSM moves no
    ///           value, skims included.
    ///        3. The destination is the configured `treasury`, never a caller-supplied address,
    ///           and every skim emits SurplusSkimmed for the PoR pipeline.
    ///      The exposure counter falls with the skim (a skim IS stable leaving the PSM, exactly
    ///      like the redeem decrement), which keeps this function and the
    ///      KRN-26-PSM-EXPOSURE-FLOOR-RESET mint gate `max(counter, balance)` from fighting:
    ///      a skim can neither re-open cap headroom that real holdings say is closed (the gate
    ///      still sees the post-skim balance) nor brick subsequent mints (counter and balance
    ///      fall together, so headroom reflects real holdings).
    function skimSurplus(
        address stable,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) nonReentrant whenNotPaused {
        if (treasury == address(0)) revert TreasuryNotSet();
        if (!(supportedStables[stable])) revert StableNotSupported();
        if (!(amount > 0)) revert ZeroSkimAmount();
        if (!(amount <= skimmableSurplus(stable))) revert SkimExceedsSurplus();

        // CEI: ledger + counter before the external transfer.
        accruedFees[stable] -= amount; // safe: amount <= skimmableSurplus <= accruedFees
        uint256 exposure = currentExposure[stable];
        if (exposure >= amount) {
            currentExposure[stable] = exposure - amount;
        } else {
            currentExposure[stable] = 0;
        }

        IERC20(stable).safeTransfer(treasury, amount);

        emit SurplusSkimmed(stable, treasury, amount);
        emit ExposureUpdated(stable, currentExposure[stable]);
    }

    // --- IERC3156FlashLender Implementation ---

    function maxFlashLoan(
        address token
    ) external view override returns (uint256) {
        if (token != address(kUSD) && !supportedStables[token]) return 0;
        return IERC20(token).balanceOf(address(this));
    }

    function flashFee(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        if (!(token == address(kUSD) || supportedStables[token])) revert UnsupportedToken();
        // 0% fee for authorized arbitrageurs
        if (hasRole(ARBITRAGEUR_ROLE, msg.sender)) return 0;
        return (amount * flashFeeBps) / 10000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant whenNotPaused returns (bool) {
        if (!(token == address(kUSD) || supportedStables[token])) revert UnsupportedToken();
        // SECURITY: Validate flash loan amount bounds
        if (!(amount > 0)) revert ZeroFlashLoanAmount();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (!(amount <= balance)) revert FlashLoanExceedsBalance();
        uint256 fee = flashFee(token, amount);

        IERC20(token).safeTransfer(address(receiver), amount);

        if (!(receiver.onFlashLoan(msg.sender, token, amount, fee, data)
                    == keccak256("ERC3156FlashBorrower.onFlashLoan"))) revert FlashLoanCallbackFailed();

        IERC20(token).safeTransferFrom(address(receiver), address(this), amount + fee);

        // FEATURE (KRN-26-PSM-FEE-SKIM): stable-side flash fees are protocol revenue and enter
        // the skim ledger. kUSD-side fees stay out of the stable ledger (the token was validated
        // above as either kUSD or a supported stable, so this branch is a supported stable).
        if (token != address(kUSD)) accruedFees[token] += fee;

        return true;
    }
}
