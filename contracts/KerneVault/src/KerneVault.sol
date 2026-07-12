// SPDX-License-Identifier: MIT
// Created: 2025-12-28
// Updated: 2026-02-10 - Security Hardening: Off-chain asset bounds, amount validation
// Updated: 2026-03-19 - Gas optimization: Migrated all require() strings to custom errors (~50-100 gas savings per revert)
// Updated: 2026-02-26 - Size reduction: Removed flash loan + price oracle (not needed pre-$10k TVL)
// Updated: 2026-03-08 - Fee correction: MATURITY_PHASE_FEE_BPS simplified to 1000 (10% protocol revenue only).
//                       Depositors at Maturity net ~23.62% (33.29% gross × 0.90). (LONGBACKTEST canonical)
// Updated: 2026-03-10 - Loyalty tier system permanently removed.
pragma solidity 0.8.24;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IComplianceHook } from "./interfaces/IComplianceHook.sol";
import { IKerneOracleRouter } from "./interfaces/IKerneOracleRouter.sol";

/// @notice Minimal hook into the escrowed-reward token (esKERNE) so a full vault
///         exit slashes the leaver's still-unvested esKERNE.
/// @dev SECURITY (KRN-26-ESK-FORFEIT-UNWIRED): esKERNE.forfeit() is gated to
///      `VAULT_ROLE`, and DeployEsKERNE grants that role to THIS vault precisely so
///      "the vault can call esKERNE.forfeit() when a depositor withdraws" (see
///      script/DeployEsKERNE.s.sol:77-78, 146-149 and esKERNE.sol:42-44). The vault
///      held the role but never exposed the call, so the entire forfeiture /
///      redistribution mechanism — the marketed core of esKERNE's design — was inert
///      on-chain. `requestWithdrawal` now drives it on a full exit (see escrowToken).
interface IEscrowForfeiter {
    function forfeit(
        address user
    ) external;
}

/**
 * @title KerneVault
 * @author Kerne Protocol
 * @notice A yield-bearing vault implementing ERC-4626 with hybrid on-chain/off-chain accounting.
 * @dev Security hardened against off-chain asset manipulation and various economic attack vectors.
 */
contract KerneVault is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Assets currently held off-chain (e.g., on CEX for hedging)
    uint256 public offChainAssets;

    /// @notice Assets currently held on Hyperliquid L1 (Sovereign Vault)
    uint256 public l1Assets;

    /// @notice The address of the Hyperliquid L1 bridge
    address public l1DepositAddress;

    /// @notice The address where funds are swept for CEX deposit
    address public immutable exchangeDepositAddress;

    /// @notice The address of the founder for wealth capture
    address public founder;

    /// @notice SECURITY FIX: Dedicated initialization guard.
    /// @dev Using a dedicated bool instead of checking `founder == address(0)` because the
    ///      constructor passes address(0) as the founder, making the old guard always pass --
    ///      an attacker could call initialize() on the implementation contract and seize admin.
    ///      This flag is set to true in _initialize() and is never reset, ensuring one-time init.
    bool private _initialized;

    /// @notice Default performance fee in basis points used as fallback before tiered logic applies.
    /// @dev In practice the tiered getEffectivePerformanceFee() always overrides this value
    ///      once the vault is past Genesis phase. Kept for backward-compatible initialize() signature.
    uint256 public grossPerformanceFeeBps = 1000;

    // ============================================================
    //                FEE STRUCTURE
    // ============================================================
    // Single performance fee taken from gross yield, scaling with TVL:
    //   Genesis  ($0 – $100k TVL):    0% fee  → ~26.25% net APY  (LONGBACKTEST canonical)
    //   Growth   ($100k – $1M TVL):   5% fee  → ~24.94% net APY  (LONGBACKTEST canonical)
    //   Maturity ($1M+ TVL):         10% fee  → ~23.62% net APY  (LONGBACKTEST canonical)
    //
    // All fee revenue goes to protocol/founders (treasury).
    // ============================================================

    /// @notice Genesis Phase TVL threshold in USD (100,000 USD with 18 decimals)
    uint256 public constant GENESIS_TVL_THRESHOLD = 100_000 * 1e18;

    /// @notice Growth Phase TVL threshold in USD (1,000,000 USD with 18 decimals)
    uint256 public constant GROWTH_TVL_THRESHOLD = 1_000_000 * 1e18;

    /// @notice Performance fee during Growth Phase (5% = 500 basis points).
    uint256 public constant GROWTH_PHASE_FEE_BPS = 500;

    /// @notice Performance fee during Maturity Phase (10% = 1000 basis points).
    /// @dev All revenue goes to founders/treasury. No reward reserve strip.
    uint256 public constant MATURITY_PHASE_FEE_BPS = 1000;

    /// @notice Whether Genesis Phase is active (0% performance fee)
    bool public genesisPhaseActive = true;

    /// @notice Timestamp when Genesis Phase ended
    uint256 public genesisPhaseEndedAt;

    /// @notice Total USD value deposited during Genesis Phase (for tracking)
    uint256 public genesisPhaseDeposits;

    /// @notice The fee taken by the Kerne founder from white-label instances
    uint256 public founderFeeBps;

    /// @notice The insurance fund balance
    uint256 public insuranceFundBalance;

    /// @notice The insurance fund contract address
    address public insuranceFund;

    /// @notice The insurance fund contribution in basis points
    uint256 public insuranceFundBps = 1000;

    /// @notice The escrowed-reward token (esKERNE). When set, a FULL vault exit via
    ///         `requestWithdrawal` forfeits the leaver's still-unvested esKERNE to the
    ///         remaining holders. Zero (the default) disables the hook entirely, so the
    ///         vault's behaviour is unchanged until an admin explicitly wires it.
    /// @dev SECURITY (KRN-26-ESK-FORFEIT-UNWIRED): see `IEscrowForfeiter` and
    ///      `requestWithdrawal`. The vault must hold `VAULT_ROLE` on this token
    ///      (granted by DeployEsKERNE) for the forfeit call to succeed; if it does not,
    ///      the try/catch in `requestWithdrawal` swallows the revert so withdrawals
    ///      are never blocked.
    address public escrowToken;

    /// @notice Hedging Reserve for institutional obfuscation
    uint256 public hedgingReserve;

    /// @notice SECURITY (KRN-24-006): Internal tracked on-chain balance.
    uint256 private _trackedOnChainAssets;

    /// @notice SECURITY FIX (KRN-24-011): Entry fee in basis points (default 5 bps = 0.05%).
    /// @dev CLONE-INIT (2026-06-05): re-applied in _initialize() so EIP-1167 clones — which never
    ///      run this inline initializer — are also born with the fee.
    uint256 internal constant DEFAULT_DEPOSIT_FEE_BPS = 5;
    uint256 public depositFeeBps = DEFAULT_DEPOSIT_FEE_BPS;

    /// @notice Audit-bundle (2026-05-14): the pre-committed recipient address that
    ///         `emergencyExit` is allowed to drain to. Must be set via
    ///         `setEmergencyRecipient` while the vault is unpaused; cannot be modified
    ///         under pause so an attacker who has captured admin cannot redirect the
    ///         drain to themselves. A zero value blocks `emergencyExit` entirely.
    address public emergencyRecipient;
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 100; // Hard cap at 1%

    /// @notice The address of the verification node for Proof of Reserve
    address public verificationNode;

    /// @notice The last time the strategist reported off-chain assets or reserve
    uint256 public lastReportedTimestamp;

    /// @notice Whether whitelisting is enabled for this vault
    bool public whitelistEnabled;

    /// @notice Mapping of whitelisted addresses
    mapping(address => bool) public whitelisted;

    /// @notice External compliance hook for automated KYC/AML
    IComplianceHook public complianceHook;

    /// @notice The maximum amount of assets the vault can hold (0 = unlimited)
    uint256 public maxTotalAssets;

    /// @notice The projected annual percentage yield (in basis points, e.g., 1500 = 15%)
    uint256 public projectedAPY;

    /// @notice The address of the yield oracle for TWAY reporting
    address public yieldOracle;

    /// @notice Optional USD price oracle (a KerneOracleRouter) used to denominate the
    ///         fee-phase TVL thresholds in USD.
    /// @dev SECURITY (KRN-26-VAULT-PHASE-USD): GENESIS_TVL_THRESHOLD / GROWTH_TVL_THRESHOLD
    ///      are USD-denominated (see PROTOCOL_CONSTANTS.md: "$100,000" / "$1,000,000"), but
    ///      totalAssets() is in the vault asset's NATIVE units. The 2026-02-26 "size
    ///      reduction" removed the price oracle that bridged the two, leaving the phase
    ///      comparison testing USD thresholds against raw asset units — so for a 6-dp USDC
    ///      vault Genesis only ended at ~$100T and for an 18-dp LST vault (~$3k) at ~$300M,
    ///      and captureFounderWealth() stayed a no-op (0% fee) at every realistic TVL. When
    ///      set, totalAssets() is converted to 18-dp USD via getValueUSD() before the
    ///      threshold comparison; address(0) keeps a decimals-normalized $1-peg estimate
    ///      (exact for a USD-stablecoin vault, conservative otherwise). See _tvlInUsd18().
    address public priceOracle;

    /// @notice The address of the trust anchor for solvency verification
    address public trustAnchor;

    /// @notice The treasury address for fee collection
    address public treasury;

    /// @notice The address that receives the non-founder reward reserve extracted from gross yield.
    /// @dev This recipient is intentionally separate from the founder / treasury revenue path.
    ///      Kerne's public reward promise depends on users believing the ~26% Yield Strip (LONGBACKTEST canonical) is not
    ///      just disguised founder extraction. By routing the strip to a dedicated reward reserve
    ///      recipient, we create a clean on-chain accounting boundary between:
    ///        (a) protocol revenue for founders / treasury, and
    ///        (b) user-owned future rewards that will later be converted / distributed.
    ///
    ///      IMPORTANT: for the current Base vault the underlying asset is WETH, while
    ///      `KerneYieldDistributor` pays users in USDC. So this reserve recipient should usually
    ///      be the treasury or an operations wallet that later swaps the stripped WETH into USDC
    ///      and funds the Merkle distributor. We deliberately do NOT hardwire a swap here because
    ///      forcing WETH→USDC routing inside the vault would add unnecessary DEX and slippage risk
    ///      to the core vault primitive.
    address public rewardReserveRecipient;

    /// @notice Circuit breaker: Maximum deposit allowed in a single transaction
    uint256 public maxDepositLimit;

    /// @notice Circuit breaker: Maximum withdrawal allowed in a single transaction
    uint256 public maxWithdrawLimit;

    /// @notice Circuit breaker: Minimum solvency ratio required for operations
    uint256 public minSolvencyThreshold;

    /// @notice The timestamp when the vault first became insolvent
    uint256 public insolventSince;

    /// @notice The grace period before automatic pausing (default 4 hours)
    uint256 public constant GRACE_PERIOD = 4 hours;

    /// @notice The cooldown period for withdrawals (default 7 days)
    uint256 internal constant DEFAULT_WITHDRAWAL_COOLDOWN = 7 days;
    uint256 public withdrawalCooldown = DEFAULT_WITHDRAWAL_COOLDOWN;

    /// @notice SECURITY: Maximum percentage change allowed for off-chain asset updates (in bps)
    uint256 internal constant DEFAULT_MAX_OFFCHAIN_CHANGE_RATE_BPS = 2000;
    uint256 public maxOffChainChangeRateBps = DEFAULT_MAX_OFFCHAIN_CHANGE_RATE_BPS;

    /// @notice SECURITY: Cooldown between off-chain asset updates
    uint256 internal constant DEFAULT_OFFCHAIN_UPDATE_COOLDOWN = 10 minutes;
    uint256 public offChainUpdateCooldown = DEFAULT_OFFCHAIN_UPDATE_COOLDOWN;

    /// @notice SECURITY (KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED): the maximum fee a single
    ///         captureFounderWealth() call may extract, expressed in bps of the tracked on-chain
    ///         asset buffer (_trackedOnChainAssets). captureFounderWealth is the ONLY STRATEGIST
    ///         function that moves REAL assets OUT of the vault, yet pre-fix it carried none of the
    ///         cooldown + rate-limit hardening the three balance-reporting buckets received in
    ///         AUDIT 2026-04-29 HIGH 1.2. Because `grossYieldAmount` is caller-supplied and
    ///         unvalidated, a compromised or buggy STRATEGIST key could set the fee arbitrarily high
    ///         and drain up to 100% of on-chain principal to treasury/founder in ONE transaction —
    ///         the only prior ceiling being the `_trackedOnChainAssets -=` underflow. This per-call
    ///         cap plus the shared `offChainUpdateCooldown` bound the per-call and per-window
    ///         extraction, exactly mirroring the bucket-setter regime. Default 5%; the live
    ///         per-cycle performance fee is orders of magnitude smaller than the on-chain buffer, so
    ///         legitimate capture never binds. Admin-tunable via setMaxFounderCaptureBps().
    ///         CLONE-INIT: re-applied in _initialize() so EIP-1167 clones are born with the cap
    ///         (a clone left at 0 would otherwise revert every capture — fail-safe, not fail-open).
    uint256 internal constant DEFAULT_MAX_FOUNDER_CAPTURE_BPS = 500; // 5%
    uint256 public maxFounderCaptureBps = DEFAULT_MAX_FOUNDER_CAPTURE_BPS;

    /// @notice Block timestamp of the last fee-extracting captureFounderWealth() call.
    /// @dev Anchors the per-call cooldown (shared `offChainUpdateCooldown`). Zero until the first
    ///      non-genesis capture, so the first capture is never rate-limited against a prior one.
    uint256 public lastFounderCaptureTimestamp;

    /// @notice SECURITY (AUDIT 2026-04-29 HIGH 1.2): Bootstrap flags for the three
    ///         strategist-written balance buckets. The rate-limit check originally
    ///         skipped when oldAmount==0, which let a compromised STRATEGIST drain
    ///         perceived TVL by zeroing then re-bootstrapping to any value.
    ///         These flags flip true on the first non-zero write and are never
    ///         cleared, so subsequent zeroing still requires re-bootstrap via
    ///         DEFAULT_ADMIN_ROLE (resetBucketBootstrap) before another large
    ///         write becomes possible.
    bool private _offChainAssetsBootstrapped;
    bool private _hedgingReserveBootstrapped;
    bool private _l1AssetsBootstrapped;

    /// @notice SECURITY (AUDIT 2026-04-29 HIGH 1.2): Per-bucket last-reported
    ///         timestamps so the cooldown gate is independent across the three
    ///         strategist-written buckets. Sharing a single timestamp let one
    ///         bucket's update silently consume another bucket's cooldown
    ///         budget, which the bot's tight rebalance loop would have surfaced
    ///         as missed updates rather than as the intended denial-of-service
    ///         on rapid back-to-back writes.
    uint256 public lastOffChainAssetsTimestamp;
    uint256 public lastHedgingReserveTimestamp;
    uint256 public lastL1AssetsTimestamp;

    // ============================================================
    //                LIQUIDATION CASCADE PREVENTION
    // ============================================================

    /// @notice Whether the collateral ratio circuit breaker is active (Red Halt)
    bool public crCircuitBreakerActive;

    /// @notice Whether the collateral ratio soft alert is active (Yellow Alert)
    bool public crSoftAlertActive;

    /// @notice Critical collateral ratio threshold (0.99x = 99%) - Triggers Red Halt
    uint256 public constant CRITICAL_CR_THRESHOLD = 9900;

    /// @notice Warning collateral ratio threshold (1.00x = 100%) - Triggers Yellow Alert
    uint256 public constant WARNING_CR_THRESHOLD = 10000;

    /// @notice Safe collateral ratio for recovery (1.01x = 101%)
    uint256 public constant SAFE_CR_THRESHOLD = 10100;

    /// @notice Timestamp when circuit breaker was triggered
    uint256 public crCircuitBreakerTriggeredAt;

    /// @notice Minimum time before circuit breaker can recover (4 hours)
    uint256 internal constant DEFAULT_CR_CIRCUIT_BREAKER_COOLDOWN = 4 hours;
    uint256 public crCircuitBreakerCooldown = DEFAULT_CR_CIRCUIT_BREAKER_COOLDOWN;

    /// @notice Dynamic collateral buffer during stress (in basis points)
    uint256 public dynamicCRBuffer;

    /// @notice Maximum liquidation per hour as percentage of TVL (500 = 5%)
    uint256 public maxLiquidationPerHourBps = 500;

    /// @notice Track liquidations per hour
    mapping(uint256 => uint256) public hourlyLiquidationAmounts;

    struct WithdrawalRequest {
        uint256 assets;
        uint256 shares;
        uint256 unlockTimestamp;
        bool claimed;
    }

    /// @notice Mapping of user address to their withdrawal requests
    mapping(address => WithdrawalRequest[]) public withdrawalRequests;

    // --- Events ---
    event OffChainAssetsUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
    event FundsSwept(uint256 amount, address destination);
    event HedgingReserveUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
    event ProjectedAPYUpdated(uint256 oldAPY, uint256 newAPY, uint256 timestamp);
    event CircuitBreakersUpdated(uint256 maxDeposit, uint256 maxWithdraw, uint256 minSolvency);
    event ComplianceHookUpdated(address indexed oldHook, address indexed newHook);
    event YieldOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event VerificationNodeUpdated(address indexed oldNode, address indexed newNode);
    event FounderWealthCaptured(uint256 amount, address indexed recipient);
    event RewardReserveRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event RewardReserveCaptured(uint256 amount, address indexed recipient);
    event InsuranceFundContribution(uint256 amount);
    /// @notice Emitted when the configured insurance fund credits a capital injection
    ///         into the vault's tracked NAV (KRN-26-INS-INJECT-UNTRACKED).
    event InsuranceInjectionReceived(address indexed insuranceFund, uint256 amount);
    /// @notice Emitted when the escrowed-reward (esKERNE) forfeiture hook is (re)configured.
    /// @dev SECURITY (KRN-26-ESK-FORFEIT-UNWIRED).
    event EscrowTokenUpdated(address indexed oldToken, address indexed newToken);
    /// @notice Emitted when a full vault exit successfully triggered esKERNE forfeiture
    ///         for the leaver. Absence of this event after a full exit (while escrowToken
    ///         is set) means the escrow call reverted and was swallowed by the try/catch.
    event EscrowForfeitTriggered(address indexed user);
    event WithdrawalRequested(
        address indexed user, uint256 requestId, uint256 assets, uint256 shares, uint256 unlockTimestamp
    );
    event WithdrawalClaimed(address indexed user, uint256 requestId, uint256 assets);
    event WithdrawalCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event L1AssetsUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
    event L1DepositRequested(uint256 amount, address bridge);
    event TrustAnchorUpdated(address indexed oldAnchor, address indexed newAnchor);
    event OffChainUpdateParamsChanged(uint256 maxChangeRateBps, uint256 cooldown);

    // --- Liquidation Cascade Prevention Events ---
    event CRCircuitBreakerTriggered(uint256 cr, uint256 timestamp);
    event CRSoftAlertTriggered(uint256 cr, uint256 timestamp);
    event CRCircuitBreakerRecovered(uint256 cr, uint256 timestamp);
    event CRSoftAlertRecovered(uint256 cr, uint256 timestamp);
    event DynamicBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event LiquidationRateLimited(uint256 attempted, uint256 allowed, uint256 hour);
    event DepositFeeUpdated(uint256 newFeeBps);
    /// @notice Audit-bundle (2026-05-14): emitted when the emergency-exit recipient is rotated.
    event EmergencyRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // --- Genesis Phase Events ---
    event GenesisPhaseEnded(uint256 tvlAtEnd, uint256 timestamp);
    event GenesisPhaseDeposit(address indexed user, uint256 assets, uint256 totalGenesisDeposits);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice SECURITY FIX KRN-26-002: Constructor sets _initialized = true via _initialize(),
    ///         permanently locking the implementation contract against re-initialization attacks.
    /// @dev When this contract is used directly (not as a clone), calling the constructor
    ///      immediately invokes _initialize(), which sets `_initialized = true`. This prevents
    ///      any attacker from calling initialize() on the implementation contract.
    ///
    ///      When used as a Clones pattern (minimal proxy), the clone starts with fresh storage
    ///      (_initialized = false), so the factory can call initialize() exactly once on the clone.
    ///
    ///      This is the standard OpenZeppelin "disable initializers on implementation" pattern.
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address strategist_,
        address exchangeDepositAddress_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        exchangeDepositAddress = exchangeDepositAddress_;
        // SECURITY FIX KRN-26-002: _initialize() sets _initialized = true as its very first
        // operation, permanently locking this implementation against re-initialization attacks.
        _initialize(address(asset_), name_, symbol_, admin_, strategist_, address(0), 0, 1000, false, address(0), 0);
    }

    /// @notice The factory address authorized to initialize clones
    address public factory;

    // ============================================================
    //                CUSTOM ERRORS
    // ============================================================
    // Gas optimization: Custom errors save ~50-100 gas per revert compared to
    // require(condition, "string") because they avoid ABI-encoding the string.
    // This is the Solidity 0.8.24 best practice per AGENT_RULES.md §9.
    // ============================================================

    /// @notice SECURITY FIX KRN-26-002: Custom error for unauthorized initialization attempts.
    /// @dev Reverts when a non-factory caller tries to initialize a clone, or when factory is unset.
    error UnauthorizedInitializer(address caller, address expectedFactory);

    /// @notice SECURITY FIX KRN-26-002: Custom error for factory address already being set.
    error FactoryAlreadySet(address currentFactory);

    /// @notice SECURITY FIX KRN-26-002: Custom error for zero factory address.
    error FactoryCannotBeZero();

    /// @notice SECURITY FIX KRN-26-002: Custom error when vault is already initialized.
    error VaultAlreadyInitialized();

    /// @dev Thrown when a zero address is provided where a valid address is required.
    error ZeroAddress();

    /// @dev Thrown when an amount is zero but must be positive.
    error ZeroAmount();

    /// @dev Thrown when a fee or BPS value exceeds the allowed maximum.
    /// @param provided The value that was provided.
    /// @param maximum The maximum allowed value.
    error FeeTooHigh(uint256 provided, uint256 maximum);

    /// @dev Thrown when the vault's solvency check fails.
    error VaultInsolvent();

    /// @dev Thrown when `injectFromInsurance` is called by anyone other than the
    ///      configured `insuranceFund` (KRN-26-INS-INJECT-UNTRACKED).
    error NotInsuranceFund();

    /// @dev Thrown when an off-chain asset update is attempted before the cooldown expires.
    error UpdateCooldownNotMet();

    /// @dev Thrown when the off-chain asset change exceeds the max allowed rate.
    error OffChainChangeExceedsMaxRate();

    /// @dev Thrown when there is no valid sweep destination configured.
    error NoSweepDestination();

    /// @dev Thrown when the founder address has not been set.
    error FounderNotSet();

    /// @dev SECURITY (KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED): thrown when a single
    ///      captureFounderWealth() extraction would exceed maxFounderCaptureBps of the
    ///      tracked on-chain asset buffer. Bounds a compromised/buggy STRATEGIST key.
    error FounderCaptureExceedsLimit(uint256 requested, uint256 maxAllowed);

    /// @dev Thrown when the solvency threshold is set below the safe minimum (90%).
    error SolvencyThresholdTooLow();

    /// @dev Thrown when the max off-chain change rate exceeds the hard cap.
    error MaxChangeRateTooHigh();

    /// @dev Thrown when a cooldown period is shorter than the minimum allowed.
    error CooldownTooShort();

    /// @dev Thrown when a cooldown period exceeds the maximum allowed.
    error CooldownTooLong();

    /// @dev Thrown when the L1 bridge address has not been configured.
    error L1BridgeNotSet();

    /// @dev Thrown when a withdrawal has already been claimed.
    error AlreadyClaimed();

    /// @dev Thrown when the withdrawal cooldown has not elapsed yet.
    error WithdrawalCooldownNotMet();

    /// @dev Thrown when the vault lacks sufficient liquid assets for a withdrawal.
    error InsufficientLiquidBuffer();

    /// @dev Thrown when a prime account operation targets a non-prime address.
    error NotPrimeAccount();

    /// @dev Thrown when an emergency exit is attempted on an unpaused vault.
    error MustBePaused();

    /// @dev Audit-bundle (2026-05-14): `emergencyExit` was called before any
    ///      `setEmergencyRecipient` had been made, leaving the recipient slot at zero.
    error EmergencyRecipientNotSet();

    /// @dev Audit-bundle (2026-05-14): the `recipient` argument to `emergencyExit`
    ///      did not match the pre-committed `emergencyRecipient` address.
    error EmergencyRecipientMismatch(address provided, address expected);

    /// @dev Audit-bundle (2026-05-14): `setEmergencyRecipient` may only be called while the
    ///      vault is operating normally so admin cannot redirect the recipient under
    ///      emergency conditions.
    error EmergencyRecipientLockedWhilePaused();

    /// @dev Thrown when a depositor fails whitelist and compliance checks.
    error NotWhitelistedOrCompliant();

    /// @dev Thrown when a depositor fails the compliance hook check.
    error ComplianceCheckFailed();

    /// @dev Thrown when a deposit would exceed the vault's maximum total assets cap.
    error DepositCapExceeded();

    /// @dev Thrown when a single-transaction withdrawal request exceeds the configured
    ///      `maxWithdrawLimit` circuit breaker (0 = unlimited). SECURITY (KRN-26-VAULT-WITHDRAW-BREAKER-DEAD):
    ///      the withdrawal-side breaker was declared and settable via `setCircuitBreakers` but never
    ///      enforced — the symmetric counterpart of the enforced deposit-side `maxDepositLimit` cap.
    error WithdrawLimitExceeded(uint256 requested, uint256 limit);

    /// @dev Thrown when direct withdraw/redeem is called (must use requestWithdrawal queue).
    error UseRequestWithdrawal();

    /// @dev Thrown when Genesis phase has already ended and cannot be ended again.
    error GenesisAlreadyEnded();

    /// @dev Thrown when the CR circuit breaker is not active but recovery is attempted.
    error CircuitBreakerNotActive();

    /// @dev Thrown when the collateral ratio is still below the safe threshold.
    error CRStillLow();

    /// @notice Set the factory address that is authorized to call initialize().
    /// @dev SECURITY FIX KRN-26-002: This function can ONLY be called ONCE, and ONLY when:
    ///      1. factory == address(0) — factory has not been set yet
    ///      2. !_initialized — the vault has not been initialized yet
    ///
    ///      Called by KerneVaultFactory.deployVault() immediately after Clones.clone(),
    ///      BEFORE calling initialize(). Because clone + setFactory + initialize all execute
    ///      within a single transaction in deployVault(), there is zero front-running window.
    ///
    ///      No access control modifier (no onlyRole) because on a fresh clone, no admin roles
    ///      exist yet. The `!_initialized && factory == address(0)` preconditions ensure this
    ///      can only ever be called once on a fresh, un-initialized clone.
    ///
    ///      Attack vector eliminated: Even if an attacker front-runs setFactory() on a predicted
    ///      clone address, the factory's subsequent setFactory() call reverts (factory already set),
    ///      causing the entire deployVault() to revert — the clone is bricked, not hijacked.
    function setFactory(
        address _factory
    ) external {
        // SECURITY FIX KRN-26-002: Only callable on un-initialized clones with no factory set.
        if (_initialized) revert VaultAlreadyInitialized();
        if (factory != address(0)) revert FactoryAlreadySet(factory);
        if (_factory == address(0)) revert FactoryCannotBeZero();
        factory = _factory;
    }

    /// @notice Initializes a freshly-cloned vault with all operating parameters.
    /// @dev SECURITY (KRN-26-002): Only callable by the factory address set via `setFactory()`.
    ///      Both `factory` must be non-zero AND `msg.sender` must equal `factory` — this eliminates
    ///      the single-call hijack window that existed before the two-step clone+setFactory+initialize pattern.
    ///      The `_initialized` flag is set as the FIRST operation of `_initialize()`,
    ///      so any re-entry or retry path is rejected immediately.
    /// @param name_ The human-readable name for the vault share token.
    /// @param symbol_ The ticker symbol for the vault share token.
    /// @param admin_ The address that receives DEFAULT_ADMIN_ROLE, STRATEGIST_ROLE, and PAUSER_ROLE.
    /// @param strategist_ The address that receives STRATEGIST_ROLE (and PAUSER_ROLE).
    /// @param founder_ The protocol founder address for fee capture; may be address(0) for white-label vaults.
    /// @param founderFeeBps_ The founder's performance fee in basis points (max 2000).
    /// @param performanceFeeBps_ The vault gross performance fee in basis points (max 2000).
    /// @param whitelistEnabled_ Whether deposit whitelist is active at initialization.
    /// @param complianceHook_ Optional compliance hook contract (address(0) to skip).
    /// @param maxTotalAssets_ Maximum total asset cap for the vault (0 = unlimited).
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address strategist_,
        address founder_,
        uint256 founderFeeBps_,
        uint256 performanceFeeBps_,
        bool whitelistEnabled_,
        address complianceHook_,
        uint256 maxTotalAssets_
    ) external {
        // SECURITY FIX KRN-26-002: Use dedicated _initialized flag to prevent double-init.
        if (_initialized) revert VaultAlreadyInitialized();

        // SECURITY FIX KRN-26-002: STRICT factory guard — both conditions must be true.
        // OLD (VULNERABLE): require(factory == address(0) || msg.sender == factory)
        //   ↑ This allowed ANY caller when factory was unset (address(0)), enabling clone hijack.
        // NEW (SECURE): factory MUST be set (non-zero) AND caller MUST be that factory.
        //   This eliminates the initialization race window because:
        //   1. setFactory() must be called first to set a non-zero factory address
        //   2. Only that exact factory address can then call initialize()
        //   3. Both calls happen atomically within KerneVaultFactory.deployVault()
        if (factory == address(0) || msg.sender != factory) {
            revert UnauthorizedInitializer(msg.sender, factory);
        }

        _initialize(
            asset_,
            name_,
            symbol_,
            admin_,
            strategist_,
            founder_,
            founderFeeBps_,
            performanceFeeBps_,
            whitelistEnabled_,
            complianceHook_,
            maxTotalAssets_
        );
    }

    string private _name;
    string private _symbol;

    /// @notice Clone-local underlying asset and its decimals.
    /// @dev SECURITY (asset-immutable-in-clone, 2026-05-28): OpenZeppelin's non-upgradeable
    ///      ERC4626 stores the underlying asset and its decimals as `immutable`
    ///      (`_asset`, `_underlyingDecimals`). Immutables are written into the
    ///      implementation contract's runtime bytecode at construction; EIP-1167 minimal
    ///      proxies (used by KerneVaultFactory) `delegatecall` the implementation, so every
    ///      clone reads the IMPLEMENTATION's immutables, never its own storage. The result
    ///      was that the `asset` argument passed to `initialize()` was silently discarded and
    ///      all factory-deployed vaults transacted the implementation's asset/decimals. We
    ///      bind the real asset per-clone here and override `asset()`/`decimals()` to read it,
    ///      mirroring the existing `_name`/`_symbol` clone-locality overrides.
    address private _assetClone;
    uint8 private _assetDecimalsClone;

    /// @notice Returns the vault share token name, using the clone-local storage override if set.
    /// @dev Overrides ERC20.name() to support per-clone naming on minimal proxy deployments.
    ///      The parent ERC20 constructor sets its own name, but clone initialization overwrites _name
    ///      in storage — this getter reads _name first and falls back to the parent only if empty.
    /// @return The vault share token name (e.g., "Kerne WETH Vault").
    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return bytes(_name).length > 0 ? _name : super.name();
    }

    /// @notice Returns the vault share token symbol, using the clone-local storage override if set.
    /// @dev Same override rationale as `name()` — supports per-clone symbols on minimal proxies.
    /// @return The vault share token symbol (e.g., "kWETH").
    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return bytes(_symbol).length > 0 ? _symbol : super.symbol();
    }

    /// @notice Returns the vault's underlying ERC-4626 asset, clone-safe.
    /// @dev Overrides ERC4626.asset() (which returns an `immutable` baked into the
    ///      implementation bytecode and therefore identical across all EIP-1167 clones)
    ///      to return the per-clone asset bound in `_initialize`. Falls back to the
    ///      ERC4626 immutable for the implementation contract / standalone deployments,
    ///      where `_assetClone` equals the constructor asset anyway.
    function asset() public view override returns (address) {
        address a = _assetClone;
        return a != address(0) ? a : super.asset();
    }

    /// @notice Returns the vault share token decimals, clone-safe.
    /// @dev Same rationale as the asset() override: ERC4626 derives decimals from an
    ///      `immutable _underlyingDecimals` that is not clone-local. We use the per-clone
    ///      asset's decimals (resolved in `_initialize`) plus this vault's `_decimalsOffset()`.
    function decimals() public view override(ERC4626) returns (uint8) {
        if (_assetClone == address(0)) return super.decimals();
        return _assetDecimalsClone + _decimalsOffset();
    }

    /// @dev Best-effort fetch of an ERC-20's decimals with the same fallback-to-18
    ///      semantics as OZ ERC4626._tryGetAssetDecimals (which is private and cannot be
    ///      reused). Called once per (re)initialization to cache the clone-local value.
    /// @dev Uses a LOW-LEVEL staticcall on purpose: a high-level
    ///      `try IERC20Metadata(asset_).decimals()` reverts uncaught when `asset_` has no
    ///      code (Solidity's extcodesize guard fires before the call), which would brick
    ///      construction for placeholder / not-yet-deployed asset addresses. A raw
    ///      staticcall instead returns ok=true with empty returndata for a code-less
    ///      address, so we fall through to the 18-decimal default exactly like OZ does.
    function _resolveAssetDecimals(
        address asset_
    ) private view returns (uint8) {
        if (asset_ == address(0)) return 18;
        (bool ok, bytes memory data) = asset_.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) {
            uint256 d = abi.decode(data, (uint256));
            if (d <= type(uint8).max) return uint8(d);
        }
        return 18;
    }

    function _initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address strategist_,
        address founder_,
        uint256 founderFeeBps_,
        uint256 performanceFeeBps_,
        bool whitelistEnabled_,
        address complianceHook_,
        uint256 maxTotalAssets_
    ) internal {
        // Mark as initialized immediately to prevent any re-entrancy or double-init path.
        // This must be the very first state mutation so that even if a downstream call reverts
        // and is retried, the guard holds.
        _initialized = true;
        // Custom error: admin must be non-zero because it receives DEFAULT_ADMIN_ROLE.
        // A zero-address admin would make the vault permanently ungovernable.
        if (admin_ == address(0)) revert ZeroAddress();
        // Clone-local asset binding (see `_assetClone` NatSpec). For the implementation
        // contract this duplicates the ERC4626 constructor asset; for factory clones it is
        // the ONLY place the real asset is recorded, since the ERC4626 immutable is not
        // clone-local.
        _assetClone = asset_;
        _assetDecimalsClone = _resolveAssetDecimals(asset_);
        _name = name_;
        _symbol = symbol_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(STRATEGIST_ROLE, strategist_);
        _grantRole(PAUSER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, strategist_);
        founder = founder_;
        founderFeeBps = founderFeeBps_;
        // Default the reward reserve recipient immediately so the reward path can never be
        // accidentally bricked by a missing post-deploy config transaction. We still expose
        // setRewardReserveRecipient() so launch ops can later separate user reward custody from
        // founder / treasury custody, but the vault must remain operational even if that role
        // handoff is delayed.
        rewardReserveRecipient = founder_ != address(0) ? founder_ : admin_;
        if (performanceFeeBps_ > 0 && performanceFeeBps_ <= 2000) {
            grossPerformanceFeeBps = performanceFeeBps_;
        }
        whitelistEnabled = whitelistEnabled_;
        if (complianceHook_ != address(0)) {
            complianceHook = IComplianceHook(complianceHook_);
        }
        maxTotalAssets = maxTotalAssets_;

        // SECURITY FIX (CLONE-INIT, 2026-06-05): EIP-1167 clones (KerneVaultFactory) never run the
        // constructor, so the inline initializers for these operating defaults DO NOT execute — a
        // cloned vault starts with them all at 0/false. Most critically maxOffChainChangeRateBps == 0
        // disables the strategist off-chain-asset rate-limit, re-opening the zero-then-restore drain
        // primitive closed by AUDIT 2026-04-29 HIGH 1.2; offChainUpdateCooldown == 0 removes its
        // companion throttle; depositFeeBps == 0 drops protocol revenue and the previewMint fee
        // symmetry; withdrawalCooldown == 0 removes the queue delay; genesisPhaseActive == false skips
        // the Genesis 0% fee phase and genesis-deposit tracking; crCircuitBreakerCooldown == 0 lets the
        // Red-Halt breaker auto-recover instantly. Re-apply the canonical defaults here so a clone is
        // born identical to a constructor-deployed vault. Each stays admin-tunable via its setter
        // (setOffChainUpdateParams / setDepositFee / setWithdrawalCooldown / endGenesisPhase).
        depositFeeBps = DEFAULT_DEPOSIT_FEE_BPS;
        maxOffChainChangeRateBps = DEFAULT_MAX_OFFCHAIN_CHANGE_RATE_BPS;
        offChainUpdateCooldown = DEFAULT_OFFCHAIN_UPDATE_COOLDOWN;
        withdrawalCooldown = DEFAULT_WITHDRAWAL_COOLDOWN;
        crCircuitBreakerCooldown = DEFAULT_CR_CIRCUIT_BREAKER_COOLDOWN;
        genesisPhaseActive = true;
        // KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED: a clone left at 0 would revert every capture
        // (fail-safe), but re-applying the canonical 5% cap keeps a clone identical to a
        // constructor-deployed vault so legitimate fee capture works out of the box.
        maxFounderCaptureBps = DEFAULT_MAX_FOUNDER_CAPTURE_BPS;
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3;
    }

    /// @notice Returns the immutable exchange deposit address used for CEX sweeps.
    /// @dev Set at construction and immutable — cannot be changed after deployment.
    ///      This is the address where `sweepToExchange()` deposits funds for the hedging bot to pick up.
    /// @return The CEX deposit address configured at vault construction.
    function getExchangeDepositAddress() public view returns (address) {
        return exchangeDepositAddress;
    }

    // --- Accounting Overrides ---

    /**
     * @notice Returns the total amount of assets managed by the vault, including off-chain and L1 positions.
     * @dev Uses _trackedOnChainAssets (not raw ERC20 balance) to prevent donation-attack inflation (KRN-24-006).
     *      If a verificationNode is set, it is called via staticcall to incorporate verified off-chain balances.
     *      Falls back to: on-chain tracked + offChainAssets + l1Assets + hedgingReserve if no node is set.
     * @return Total assets under management across all accounting buckets.
     */
    function totalAssets() public view virtual override returns (uint256) {
        address node = verificationNode;
        if (node != address(0)) {
            (bool success, bytes memory data) =
                node.staticcall(abi.encodeWithSignature("getVerifiedAssets(address)", address(this)));
            if (success && data.length == 32) {
                return _trackedOnChainAssets + abi.decode(data, (uint256));
            }
            return _trackedOnChainAssets;
        }
        return _trackedOnChainAssets + offChainAssets + l1Assets + hedgingReserve;
    }

    /// @notice Returns the current collateral ratio of the vault in basis points (10000 = 100%).
    /// @dev Computes assets / (share supply normalized to asset decimals). Returns 20000 (200%) when
    ///      there are no liabilities (new or empty vault) to indicate unlimited solvency.
    ///      Used by the circuit breaker, trust anchor, and external monitoring tools.
    ///      A ratio below CRITICAL_CR_THRESHOLD (9900) triggers the Red Halt circuit breaker.
    /// @return Collateral ratio in basis points (e.g., 10500 = 105%, 9900 = 99%).
    function getSolvencyRatio() public view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 liabilities = totalSupply() / (10 ** _decimalsOffset());
        if (liabilities == 0) return 20000;
        return (assets * 10000) / liabilities;
    }

    /// @notice Triggers a solvency check and pauses the vault if insolvency is detected past the grace period.
    /// @dev Only callable by PAUSER_ROLE. Does NOT revert on insolvency — it pauses instead.
    ///      Useful for the off-chain monitoring bot to trigger a safe pause without the strict revert path.
    function checkAndPause() external onlyRole(PAUSER_ROLE) {
        _updateSolvency(false);
    }

    function _checkSolvency(
        bool strict
    ) internal {
        _updateSolvency(strict);
    }

    function _updateSolvency(
        bool strict
    ) internal {
        bool currentlySolvent = true;
        if (minSolvencyThreshold > 0 && totalSupply() > 1000) {
            uint256 ratio = getSolvencyRatio();
            if (ratio < minSolvencyThreshold) currentlySolvent = false;
        }
        if (currentlySolvent && trustAnchor != address(0) && totalSupply() > 1000) {
            (bool success, bytes memory data) =
                trustAnchor.staticcall(abi.encodeWithSignature("isSolvent(address)", address(this)));
            if (success && data.length == 32) {
                currentlySolvent = abi.decode(data, (bool));
            } else {
                currentlySolvent = false;
            }
        }
        if (!currentlySolvent) {
            if (insolventSince == 0) {
                insolventSince = block.timestamp;
            } else if (block.timestamp - insolventSince > GRACE_PERIOD) {
                if (!paused()) _pause();
            }
            if (strict) revert VaultInsolvent();
        } else {
            insolventSince = 0;
        }
    }

    /// @notice Sets the external trust anchor contract used for cross-chain solvency verification.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The trust anchor is queried via staticcall for
    ///      `isSolvent(address vault)` — a false response triggers the insolvency grace period.
    ///      Set to address(0) to disable external solvency checks (relies on internal ratio only).
    /// @param _anchor The trust anchor contract address (or address(0) to disable).
    function setTrustAnchor(
        address _anchor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAnchor = trustAnchor;
        trustAnchor = _anchor;
        emit TrustAnchorUpdated(oldAnchor, _anchor);
    }

    // --- Strategist Functions ---

    /// @notice Updates the vault's off-chain asset balance reported by the hedging bot.
    /// @dev Only callable by STRATEGIST_ROLE. Enforces a minimum cooldown between updates and a
    ///      maximum change rate to prevent a compromised key from draining perceived TVL instantaneously.
    ///      Triggers the CR circuit breaker check to detect sudden solvency deterioration.
    ///
    ///      AUDIT FIX (2026-04-29 HIGH 1.2): The previous version skipped the rate-limit check
    ///      entirely when oldAmount==0, letting a compromised strategist drain perceived TVL by
    ///      zeroing then re-bootstrapping. The fix uses _offChainAssetsBootstrapped which only
    ///      flips true on the first non-zero write and is never cleared — once tripped, every
    ///      subsequent write (including ones that re-zero) is rate-limited. To re-bootstrap
    ///      legitimately after a deliberate zeroing, DEFAULT_ADMIN_ROLE must call
    ///      resetBucketBootstrap, which is a deliberate multisig-controlled override.
    /// @param amount The new total off-chain asset balance in asset decimals.
    function updateOffChainAssets(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (block.timestamp < lastOffChainAssetsTimestamp + offChainUpdateCooldown) revert UpdateCooldownNotMet();
        uint256 oldAmount = offChainAssets;
        if (_offChainAssetsBootstrapped && maxOffChainChangeRateBps > 0) {
            // Once bootstrapped, oldAmount==0 still applies the rate-limit math
            // by treating the change against a small floor (1 wei). This is what
            // closes the original bypass: a zeroed-then-rewritten path now fails
            // the rate-limit check the same way any other write would.
            uint256 baseline = oldAmount > 0 ? oldAmount : 1;
            uint256 maxChange = (baseline * maxOffChainChangeRateBps) / 10000;
            uint256 change = amount > oldAmount ? amount - oldAmount : oldAmount - amount;
            if (change > maxChange) revert OffChainChangeExceedsMaxRate();
        }
        offChainAssets = amount;
        if (amount > 0) _offChainAssetsBootstrapped = true;
        lastOffChainAssetsTimestamp = block.timestamp;
        lastReportedTimestamp = block.timestamp;
        emit OffChainAssetsUpdated(oldAmount, amount, block.timestamp);
        _checkCRCircuitBreaker();
    }

    /// @notice Updates the vault's hedging reserve balance reported by the strategist.
    /// @dev Only callable by STRATEGIST_ROLE. The hedging reserve is the on-chain hedge buffer
    ///      and counts toward totalAssets() per the four-bucket disclosure in docs/SEED_TVL_POLICY.md.
    ///
    ///      AUDIT FIX (2026-04-29 HIGH 1.2): Previous version had NO rate limit and NO cooldown.
    ///      A compromised strategist could write any value any number of times with no friction.
    ///      Now uses the same shared maxOffChainChangeRateBps + offChainUpdateCooldown gates as
    ///      updateOffChainAssets, plus the same bootstrap-flag protection against zero-then-restore
    ///      bypass. Per-bucket cooldown timestamp prevents one bucket's writes from consuming
    ///      another bucket's cooldown budget.
    ///
    ///      SECURITY FIX (KRN-26-VAULT-CR-BUCKET-BYPASS, 2026-06-07,
    ///      docs/security/KERNEVAULT_CR_BREAKER_BUCKET_BYPASS_2026-06-07.md): the hedging
    ///      reserve counts toward totalAssets()/getSolvencyRatio() exactly like offChainAssets,
    ///      so a loss reported here lowers the collateral ratio. This now triggers the same CR
    ///      circuit-breaker check as updateOffChainAssets — previously the Red Halt only armed on
    ///      the off-chain bucket, so a Hyperliquid hedge loss (reported through this bucket) could
    ///      drive the vault below the 99% Red-Halt threshold without ever pausing it.
    /// @param amount The new total hedging reserve balance in asset decimals.
    function updateHedgingReserve(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (block.timestamp < lastHedgingReserveTimestamp + offChainUpdateCooldown) revert UpdateCooldownNotMet();
        uint256 oldAmount = hedgingReserve;
        if (_hedgingReserveBootstrapped && maxOffChainChangeRateBps > 0) {
            uint256 baseline = oldAmount > 0 ? oldAmount : 1;
            uint256 maxChange = (baseline * maxOffChainChangeRateBps) / 10000;
            uint256 change = amount > oldAmount ? amount - oldAmount : oldAmount - amount;
            if (change > maxChange) revert OffChainChangeExceedsMaxRate();
        }
        hedgingReserve = amount;
        if (amount > 0) _hedgingReserveBootstrapped = true;
        lastHedgingReserveTimestamp = block.timestamp;
        lastReportedTimestamp = block.timestamp;
        emit HedgingReserveUpdated(oldAmount, amount, block.timestamp);
        _checkCRCircuitBreaker();
    }

    /// @notice Updates the vault's L1 (Hyperliquid Sovereign Vault) asset balance.
    /// @dev Only callable by STRATEGIST_ROLE. L1 assets count toward totalAssets().
    ///      This mirrors the balance bridged to and held on the Hyperliquid L1 sovereign vault.
    ///
    ///      AUDIT FIX (2026-04-29 HIGH 1.2): Previous version had NO rate limit and NO cooldown.
    ///      Same playbook as updateHedgingReserve — apply the shared rate-limit + cooldown gates,
    ///      plus the bootstrap-flag protection against zero-then-restore bypass. Per-bucket
    ///      cooldown timestamp.
    ///
    ///      SECURITY FIX (KRN-26-VAULT-CR-BUCKET-BYPASS, 2026-06-07,
    ///      docs/security/KERNEVAULT_CR_BREAKER_BUCKET_BYPASS_2026-06-07.md): L1 assets count
    ///      toward totalAssets()/getSolvencyRatio(), so a loss reported here lowers the collateral
    ///      ratio. This now triggers the same CR circuit-breaker check as updateOffChainAssets —
    ///      previously the Red Halt only armed on the off-chain bucket, so an L1/Sovereign-Vault
    ///      drawdown could push the vault below the 99% Red-Halt threshold without pausing it.
    /// @param amount The new total L1 asset balance in asset decimals.
    function updateL1Assets(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (block.timestamp < lastL1AssetsTimestamp + offChainUpdateCooldown) revert UpdateCooldownNotMet();
        uint256 oldAmount = l1Assets;
        if (_l1AssetsBootstrapped && maxOffChainChangeRateBps > 0) {
            uint256 baseline = oldAmount > 0 ? oldAmount : 1;
            uint256 maxChange = (baseline * maxOffChainChangeRateBps) / 10000;
            uint256 change = amount > oldAmount ? amount - oldAmount : oldAmount - amount;
            if (change > maxChange) revert OffChainChangeExceedsMaxRate();
        }
        l1Assets = amount;
        if (amount > 0) _l1AssetsBootstrapped = true;
        lastL1AssetsTimestamp = block.timestamp;
        lastReportedTimestamp = block.timestamp;
        emit L1AssetsUpdated(oldAmount, amount, block.timestamp);
        _checkCRCircuitBreaker();
    }

    /// @notice Resets the bootstrap flag for one of the three strategist-written buckets.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE (Safe). Used after a deliberate zeroing
    ///      to allow the next strategist write to take an unconstrained value (subject
    ///      to the cooldown). Intentionally an admin action — the rate-limit bypass
    ///      this re-enables is exactly the surface the audit closed, so re-opening it
    ///      requires multisig approval.
    /// @param bucketId 0=offChainAssets, 1=hedgingReserve, 2=l1Assets
    function resetBucketBootstrap(
        uint8 bucketId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bucketId == 0) {
            _offChainAssetsBootstrapped = false;
        } else if (bucketId == 1) {
            _hedgingReserveBootstrapped = false;
        } else if (bucketId == 2) {
            _l1AssetsBootstrapped = false;
        } else {
            revert("KerneVault: invalid bucketId");
        }
    }

    /// @notice Updates the projected APY displayed to users and returned by `getProjectedAPY()`.
    /// @dev Only callable by STRATEGIST_ROLE. This is an informational field only — it does not
    ///      affect yield calculations or share pricing. Update after each periodic performance review.
    /// @param _projectedAPY The new projected APY in basis points (e.g., 2625 = 26.25%).
    function updateProjectedAPY(
        uint256 _projectedAPY
    ) external onlyRole(STRATEGIST_ROLE) {
        uint256 oldAPY = projectedAPY;
        projectedAPY = _projectedAPY;
        emit ProjectedAPYUpdated(oldAPY, _projectedAPY, block.timestamp);
    }

    // --- Admin Functions ---

    /// @notice Sweeps on-chain assets to the exchange deposit address (or treasury/founder fallback).
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Uses the CEX deposit address if configured, otherwise
    ///      falls back to treasury, then founder. Reduces `_trackedOnChainAssets` to keep accounting clean.
    ///      The hedging bot picks up the funds from the exchange deposit address for position management.
    /// @param amount The amount of vault assets to sweep to the exchange deposit address.
    function sweepToExchange(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        address dest = exchangeDepositAddress != address(0)
            ? exchangeDepositAddress
            : (treasury != address(0) ? treasury : founder);
        if (dest == address(0)) revert NoSweepDestination();
        _trackedOnChainAssets -= amount;
        SafeERC20.safeTransfer(IERC20(asset()), dest, amount);
        emit FundsSwept(amount, dest);
    }

    /// @notice Pauses all user-facing vault operations (deposits, withdrawals, claims).
    /// @dev Only callable by PAUSER_ROLE (admin or strategist). Use in emergencies.
    ///      The circuit breaker may also call `_pause()` automatically when CR drops below threshold.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the vault and restores normal operations.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE — intentionally stricter than pause to prevent
    ///      a compromised strategist key from unpausing a vault they just halted.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Sets the protocol founder address for fee capture routing.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Used to update the founder wallet after key rotation.
    ///      The founder address is the ultimate fallback for fee capture when treasury is not set.
    /// @param _founder The new founder address (must be non-zero).
    function setFounder(
        address _founder
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_founder == address(0)) revert ZeroAddress();
        founder = _founder;
    }

    /// @notice Sets the founder's per-vault performance fee in basis points.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Capped at 2000 bps (20%).
    ///      This is the white-label tier fee — the factory sets this at deployment time.
    /// @param bps The new founder fee in basis points (max 2000).
    function setFounderFee(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 2000) revert FeeTooHigh(bps, 2000);
        founderFeeBps = bps;
    }

    // SECURITY FIX KRN-26-002: The old setFactory() with onlyRole(DEFAULT_ADMIN_ROLE) has been
    // replaced by the pre-initialization version above (line ~319) that requires !_initialized
    // && factory == address(0). This ensures factory can only be set once on a fresh clone,
    // eliminating the initialization race window. The admin-gated version was removed because:
    // 1. It allowed re-setting factory post-initialization, which could break the init guard
    // 2. Fresh clones have no admin, making onlyRole(DEFAULT_ADMIN_ROLE) unusable for the
    //    initial factory assignment that must happen BEFORE initialize() grants admin roles

    /// @notice Activates or deactivates a prime account for institutional capital management.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Prime accounts receive direct asset transfers
    ///      via `transferToPrime()` for off-chain yield strategies managed by trusted institutions.
    /// @param account The address to configure as a prime account.
    /// @param active True to activate, false to deactivate.
    function setPrimeAccount(
        address account,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primeAccounts[account].active = active;
    }

    /// @notice Sets the protocol treasury address for fee routing.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Fees (performance + deposit) are routed here.
    ///      Should be set to the Kerne multisig or DAO treasury immediately after deployment.
    /// @param _treasury The new treasury address (must be non-zero).
    function setTreasury(
        address _treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    /// @notice Sets the recipient that accumulates the user-facing reward reserve.
    /// @dev This can be a treasury-controlled wallet or dedicated rewards ops wallet.
    ///      It is deliberately configurable because the reward reserve may need to be routed
    ///      through different custody / swap / payout flows over time, while the founder
    ///      revenue path remains stable.
    function setRewardReserveRecipient(
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldRecipient = rewardReserveRecipient;
        rewardReserveRecipient = _recipient;
        emit RewardReserveRecipientUpdated(oldRecipient, _recipient);
    }

    /// @notice Enables or disables the deposit whitelist enforcement.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. When enabled, only addresses in `whitelisted[]`
    ///      or approved by the compliance hook can deposit. Safe to toggle without interrupting existing holders.
    /// @param enabled True to enable whitelist, false to allow all deposits.
    function setWhitelistEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistEnabled = enabled;
    }

    /// @notice Adds or removes an address from the deposit whitelist.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Used for KYC'd depositor management when
    ///      whitelist is enabled. No event emitted — the admin transaction provides the audit trail.
    /// @param account The address to whitelist or remove.
    /// @param status True to whitelist, false to remove.
    function setWhitelisted(
        address account,
        bool status
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelisted[account] = status;
    }

    /// @notice Sets the external compliance hook contract for automated KYC/AML checks.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The hook is called via `isCompliant(vault, user)`
    ///      during deposit. Setting to address(0) disables compliance checks.
    /// @param _hook The compliance hook contract address (or address(0) to disable).
    function setComplianceHook(
        address _hook
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldHook = address(complianceHook);
        complianceHook = IComplianceHook(_hook);
        emit ComplianceHookUpdated(oldHook, _hook);
    }

    /// @notice Sets the base gross performance fee in basis points (overrides the tiered schedule as fallback).
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Max 2000 bps (20%). The live fee schedule uses
    ///      `getEffectivePerformanceFee()` which applies phase-based overrides; this sets the stored default.
    /// @param bps The new performance fee in basis points (max 2000).
    function setPerformanceFee(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 2000) revert FeeTooHigh(bps, 2000);
        grossPerformanceFeeBps = bps;
    }

    /// @notice Sets the insurance fund contract address.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The insurance fund receives `insuranceFundBps`
    ///      contribution from yield capture. Provides a backstop against collateral shortfalls.
    /// @param _insuranceFund The insurance fund contract address (must be non-zero).
    function setInsuranceFund(
        address _insuranceFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_insuranceFund == address(0)) revert ZeroAddress();
        insuranceFund = _insuranceFund;
    }

    /// @notice Wires (or clears) the escrowed-reward token (esKERNE) whose unvested balance is
    ///         forfeited on a full vault exit.
    /// @dev SECURITY FIX (KRN-26-ESK-FORFEIT-UNWIRED): esKERNE.forfeit() is `onlyRole(VAULT_ROLE)`
    ///      and DeployEsKERNE grants that role to this vault so withdrawals can trigger forfeiture,
    ///      but no code path here ever called it — the forfeiture / redistribution mechanism was
    ///      dead on-chain and a leaver kept all unvested esKERNE (later converting it 1:1 to liquid
    ///      KERNE, draining the funded conversion reserve and breaking the "zero sell pressure /
    ///      leaving enriches stayers" guarantee). Setting this address activates the hook in
    ///      `requestWithdrawal`. Pass address(0) to disable (the default), preserving the
    ///      pre-fix behaviour for vaults that have no escrow token.
    /// @param _escrowToken The esKERNE contract (or address(0) to disable the forfeiture hook).
    function setEscrowToken(
        address _escrowToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = escrowToken;
        escrowToken = _escrowToken;
        emit EscrowTokenUpdated(old, _escrowToken);
    }

    function captureFounderWealth(
        uint256 grossYieldAmount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (founder == address(0)) revert FounderNotSet();
        uint256 effectiveFeeBps = getEffectivePerformanceFee();
        if (effectiveFeeBps == 0) return;

        // SECURITY FIX (KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED): captureFounderWealth is the ONLY
        // STRATEGIST function that transfers REAL assets out of the vault. Bring it under the same
        // cooldown the three balance-reporting buckets enforce (AUDIT 2026-04-29 HIGH 1.2) so a
        // compromised/buggy strategist key cannot machine-gun back-to-back extractions in one block.
        // Skipped on the first-ever capture (timestamp 0) — there is no prior capture to rate-limit
        // against — and Genesis no-ops (effectiveFeeBps == 0, returned above) never consume the window.
        if (lastFounderCaptureTimestamp != 0 && block.timestamp < lastFounderCaptureTimestamp + offChainUpdateCooldown) revert UpdateCooldownNotMet();

        // We split the extracted gross yield into two different economic buckets:
        //   1. Founder / protocol revenue (the portion that actually belongs to the owners), and
        //   2. Reward reserve (the portion publicly promised to users via Hard Yield / referrals).
        // This separation is critical for launch trust. Without it, the docs can say
        // "yield strip funds user rewards" while the contract silently routes the full performance fee
        // to treasury — which would be a narrative and trust mismatch.
        // Current fee: MATURITY_PHASE_FEE_BPS = 1000 (10% performance fee — no yield strip bundled).
        uint256 totalFee = (grossYieldAmount * effectiveFeeBps) / 10000;
        uint256 rewardReserveBps = getCurrentRewardReserveBps();
        uint256 rewardReserveAmount = (grossYieldAmount * rewardReserveBps) / 10000;

        // Defensive clamp: in case a future admin misconfigures the fee schedule so that the
        // reward bucket exceeds the total effective fee, we cap the reward amount at totalFee
        // instead of underflowing founder revenue.
        if (rewardReserveAmount > totalFee) {
            rewardReserveAmount = totalFee;
        }

        uint256 founderRevenueAmount = totalFee - rewardReserveAmount;

        // SECURITY FIX (KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED): per-call cap. The assets that
        // actually leave the vault this call (rewardReserveAmount + founderRevenueAmount, which
        // equals totalFee after the reward clamp above) may not exceed maxFounderCaptureBps of the
        // tracked on-chain buffer. `grossYieldAmount` is caller-supplied and unvalidated, so without
        // this bound a single call could set totalFee arbitrarily high and strip on-chain principal
        // (the only prior ceiling was the `_trackedOnChainAssets -=` underflow, i.e. up to 100%).
        // The live per-cycle fee is a tiny fraction of the buffer, so the 5% default never binds
        // legitimate capture; a larger one-off (e.g. catch-up after downtime) is split across the
        // cooldown windows or temporarily widened by the admin via setMaxFounderCaptureBps().
        uint256 extracted = rewardReserveAmount + founderRevenueAmount;
        uint256 maxExtractable = (_trackedOnChainAssets * maxFounderCaptureBps) / 10000;
        if (extracted > maxExtractable) revert FounderCaptureExceedsLimit(extracted, maxExtractable);
        // CEI: anchor the cooldown before the external token transfers below.
        lastFounderCaptureTimestamp = block.timestamp;

        if (rewardReserveAmount > 0) {
            // Fallback path: if launch ops have not explicitly separated the reward reserve yet,
            // we still keep the system live by routing to treasury/founder. This preserves
            // operational continuity while making the separation opt-in rather than a fatal
            // precondition that could brick fee capture after users arrive.
            address rewardRecipient = rewardReserveRecipient != address(0)
                ? rewardReserveRecipient
                : (treasury != address(0) ? treasury : founder);
            _trackedOnChainAssets -= rewardReserveAmount;
            SafeERC20.safeTransfer(IERC20(asset()), rewardRecipient, rewardReserveAmount);
            emit RewardReserveCaptured(rewardReserveAmount, rewardRecipient);
        }

        if (founderRevenueAmount > 0) {
            address recipient = treasury != address(0) ? treasury : founder;
            _trackedOnChainAssets -= founderRevenueAmount;
            SafeERC20.safeTransfer(IERC20(asset()), recipient, founderRevenueAmount);
            emit FounderWealthCaptured(founderRevenueAmount, recipient);
        }
    }

    /// @notice Sets the per-call cap on captureFounderWealth() extraction, in bps of on-chain assets.
    /// @dev SECURITY (KRN-26-VAULT-FOUNDER-CAPTURE-UNBOUNDED). Only callable by DEFAULT_ADMIN_ROLE
    ///      (the Safe), so a compromised STRATEGIST key cannot widen its own extraction limit. Hard
    ///      capped at 10000 (100%); the 5% default is generous for legitimate per-cycle capture while
    ///      throttling a malicious one. Lower it to tighten the drain bound during heightened risk.
    /// @param bps The new per-call cap in basis points (max 10000).
    function setMaxFounderCaptureBps(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10000) revert FeeTooHigh(bps, 10000);
        maxFounderCaptureBps = bps;
    }

    /// @notice Sets the insurance fund contribution rate from gross yield in basis points.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Max 3000 bps (30%) of gross yield goes to insurance.
    ///      Higher values improve protection but reduce founder/user returns.
    /// @param bps The insurance fund contribution rate (max 3000).
    function setInsuranceFundBps(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 3000) revert FeeTooHigh(bps, 3000);
        insuranceFundBps = bps;
    }

    /// @notice Sets the off-chain verification node for Proof of Reserve attestation.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The node is queried via staticcall during totalAssets().
    ///      Setting to address(0) disables verification-node-based asset accounting.
    /// @param _node The verification node contract address (or address(0) to disable).
    function setVerificationNode(
        address _node
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldNode = verificationNode;
        verificationNode = _node;
        emit VerificationNodeUpdated(oldNode, _node);
    }

    /// @notice Sets the yield oracle address for TWAY (Time-Weighted Average Yield) reporting.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The oracle is an informational address only —
    ///      it does not affect vault accounting or share prices directly.
    /// @param _oracle The yield oracle contract address (or address(0) to unset).
    function setYieldOracle(
        address _oracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldOracle = yieldOracle;
        yieldOracle = _oracle;
        emit YieldOracleUpdated(oldOracle, _oracle);
    }

    /// @notice Sets the USD price oracle (KerneOracleRouter) used to denominate the
    ///         fee-phase TVL thresholds in USD.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. MUST be wired (to a router with a
    ///      configured feed for this vault's asset) for any non-$1-pegged collateral
    ///      (cbETH/wstETH/WETH); without it the phase thresholds fall back to a
    ///      decimals-normalized $1-peg estimate, which is exact only for a USD-stablecoin
    ///      vault. The conversion fails safe (see _tvlInUsd18), so an oracle that later
    ///      reverts cannot brick deposits or fee capture. SECURITY (KRN-26-VAULT-PHASE-USD).
    /// @param _oracle The KerneOracleRouter address (or address(0) to use the $1-peg fallback).
    function setPriceOracle(
        address _oracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldOracle = priceOracle;
        priceOracle = _oracle;
        emit PriceOracleUpdated(oldOracle, _oracle);
    }

    /// @notice Sets the maximum total assets cap for the vault (TVL cap).
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Setting to 0 removes the cap (unlimited TVL).
    ///      Deposits are rejected when totalAssets() >= maxTotalAssets to enforce the cap.
    /// @param _maxTotalAssets The new maximum total assets in asset decimals (0 = unlimited).
    function setMaxTotalAssets(
        uint256 _maxTotalAssets
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTotalAssets = _maxTotalAssets;
    }

    /// @notice Configures deposit/withdrawal circuit breakers and the minimum solvency threshold.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. All parameters can be set independently.
    ///      minSolvencyThreshold must be >= 9000 (90%) if non-zero — values below that would allow
    ///      insolvent operations and are rejected as configuration errors.
    /// @param _maxDepositLimit Maximum single-transaction deposit in asset units (0 = unlimited).
    /// @param _maxWithdrawLimit Maximum single-transaction withdrawal in asset units (0 = unlimited).
    /// @param _minSolvencyThreshold Minimum collateral ratio in bps (e.g., 9500 = 95%, 0 = disabled).
    function setCircuitBreakers(
        uint256 _maxDepositLimit,
        uint256 _maxWithdrawLimit,
        uint256 _minSolvencyThreshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minSolvencyThreshold != 0 && _minSolvencyThreshold < 9000) revert SolvencyThresholdTooLow();
        maxDepositLimit = _maxDepositLimit;
        maxWithdrawLimit = _maxWithdrawLimit;
        minSolvencyThreshold = _minSolvencyThreshold;
        emit CircuitBreakersUpdated(_maxDepositLimit, _maxWithdrawLimit, _minSolvencyThreshold);
    }

    /// @notice Configures the rate-limiting parameters for off-chain asset updates.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The max change rate prevents a compromised
    ///      strategist from setting off-chain assets to 0 in a single call, which would crash the
    ///      CR ratio and trigger the circuit breaker. Min cooldown of 5 minutes prevents rapid-fire updates.
    /// @param _maxChangeRateBps Maximum allowed change per update as a % of previous value (max 5000 = 50%).
    /// @param _cooldown Minimum seconds between off-chain asset updates (min 5 minutes).
    function setOffChainUpdateParams(
        uint256 _maxChangeRateBps,
        uint256 _cooldown
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_maxChangeRateBps > 5000) revert MaxChangeRateTooHigh();
        if (_cooldown < 5 minutes) revert CooldownTooShort();
        maxOffChainChangeRateBps = _maxChangeRateBps;
        offChainUpdateCooldown = _cooldown;
        emit OffChainUpdateParamsChanged(_maxChangeRateBps, _cooldown);
    }

    /// @notice Sets the withdrawal cooldown period between requesting and claiming a withdrawal.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Max 30 days to protect users from indefinite lockups.
    ///      During this period, the vault retains the locked shares and the assets must remain available.
    /// @param _cooldown The new withdrawal cooldown in seconds (max 30 days).
    function setWithdrawalCooldown(
        uint256 _cooldown
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_cooldown > 30 days) revert CooldownTooLong();
        uint256 old = withdrawalCooldown;
        withdrawalCooldown = _cooldown;
        emit WithdrawalCooldownUpdated(old, _cooldown);
    }

    /// @notice Initiates a bridge transfer of vault assets to the Hyperliquid L1 Sovereign Vault.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Transfers `amount` of the underlying asset to
    ///      `l1DepositAddress` (the Hyperliquid bridge). Updates `_trackedOnChainAssets` to reflect
    ///      the transfer — the strategist should later call `updateL1Assets()` to record the L1 balance.
    /// @param amount The amount of vault assets to bridge to L1 (must be non-zero).
    function requestL1Deposit(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (l1DepositAddress == address(0)) revert L1BridgeNotSet();
        _trackedOnChainAssets -= amount;
        SafeERC20.safeTransfer(IERC20(asset()), l1DepositAddress, amount);
        emit L1DepositRequested(amount, l1DepositAddress);
    }

    /// @notice Sets the Hyperliquid L1 bridge address used by `requestL1Deposit()`.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Setting to address(0) disables L1 deposits.
    /// @param _addr The L1 bridge/deposit address.
    function setL1DepositAddress(
        address _addr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        l1DepositAddress = _addr;
    }

    // --- Withdrawal Queue Implementation ---

    /// @notice Queues a withdrawal request for a given asset amount.
    /// @dev Locks the caller's corresponding shares in the vault contract until `claimWithdrawal()` is called.
    ///      The unlock timestamp is set to `block.timestamp + withdrawalCooldown`.
    ///      Direct ERC-4626 `withdraw()` and `redeem()` are disabled — this queue is the only withdrawal path.
    ///      Returns the requestId which must be saved by the caller to claim the withdrawal later.
    /// @param assets The amount of underlying assets to withdraw (in asset decimals).
    /// @return requestId The index of the withdrawal request in the caller's queue.
    function requestWithdrawal(
        uint256 assets
    ) external nonReentrant whenNotPaused returns (uint256) {
        // SECURITY FIX (KRN-26-VAULT-WITHDRAW-BREAKER-DEAD): enforce the withdrawal-side
        // circuit breaker. `maxWithdrawLimit` was declared, documented (0 = unlimited), and
        // settable via `setCircuitBreakers`, but no code path ever read it — the symmetric
        // counterpart of the enforced deposit-side `maxDepositLimit` (see `maxDeposit()`).
        // A `requestWithdrawal` is the sole withdrawal entry point (direct ERC-4626
        // withdraw/redeem revert with `UseRequestWithdrawal`), so gating it here makes the
        // documented per-transaction throttle actually bind. Default 0 leaves the breaker
        // disabled, preserving existing unlimited-withdrawal behavior.
        if (maxWithdrawLimit > 0 && assets > maxWithdrawLimit) {
            revert WithdrawLimitExceeded(assets, maxWithdrawLimit);
        }
        uint256 shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroAmount();
        _transfer(msg.sender, address(this), shares);

        uint256 requestId = withdrawalRequests[msg.sender].length;
        uint256 unlockTimestamp = block.timestamp + withdrawalCooldown;
        withdrawalRequests[msg.sender].push(
            WithdrawalRequest({ assets: assets, shares: shares, unlockTimestamp: unlockTimestamp, claimed: false })
        );
        emit WithdrawalRequested(msg.sender, requestId, assets, shares, unlockTimestamp);

        // SECURITY FIX (KRN-26-ESK-FORFEIT-UNWIRED): trigger esKERNE forfeiture on a FULL exit.
        // esKERNE.forfeit() is `onlyRole(VAULT_ROLE)` and DeployEsKERNE grants that role to this
        // vault expressly so that "the vault can call esKERNE.forfeit() when a depositor withdraws"
        // (script/DeployEsKERNE.s.sol:77-78), yet no code path ever invoked it — leaving the entire
        // forfeiture / redistribution mechanism inert and letting a leaver keep (then convert) all
        // unvested esKERNE, draining the funded conversion reserve. We fire it here, on the request
        // that empties the caller's vault position, mirroring esKERNE's "leaving forfeits unvested
        // esKERNE" rule (a request is an irreversible commitment to exit — there is no cancel path).
        //
        // Full-exit detection uses a dust threshold of `10 ** _decimalsOffset()` shares rather than
        // an exact `== 0`. A real "withdraw all" goes through `maxWithdraw` (assets, floored), and
        // `previewWithdraw` of that (shares, ceiled) can leave up to `10**_decimalsOffset() - 1`
        // residual virtual-offset shares — strictly less than ONE wei of the underlying asset, i.e.
        // economically nothing. Treating that sub-wei remainder as a full exit makes forfeiture fire
        // on genuine exits instead of being silently defeated by share-rounding dust.
        //
        // Constraints that keep this safe and preserve "everything still works":
        //   - Gated on `escrowToken != address(0)`: the hook is OFF by default, so vaults with no
        //     escrow token (and every existing test) are byte-for-byte unaffected.
        //   - `try/catch`: a revert in esKERNE (e.g. this vault lacks VAULT_ROLE, or there is
        //     nothing to forfeit) can NEVER block or revert a withdrawal — forfeiture is best-effort.
        //   - esKERNE.forfeit() makes no call back into this vault, and this whole function is
        //     `nonReentrant`, so the external call adds no reentrancy surface.
        address esc = escrowToken;
        if (esc != address(0) && balanceOf(msg.sender) < 10 ** _decimalsOffset()) {
            try IEscrowForfeiter(esc).forfeit(msg.sender) {
                emit EscrowForfeitTriggered(msg.sender);
            } catch {
                // Best-effort: never let a forfeiture failure brick a withdrawal.
            }
        }
        return requestId;
    }

    /// @notice Claims a matured withdrawal request and receives the underlying assets.
    /// @dev Requires the cooldown period to have elapsed and sufficient on-chain liquidity.
    ///      Burns the locked shares and transfers the assets directly to the caller.
    ///      Each request can only be claimed once — `req.claimed` prevents double-claims.
    /// @param requestId The index of the withdrawal request to claim (returned by `requestWithdrawal()`).
    /// @dev SECURITY FIX (audit 2026-05-08 §1.4, docs/security/KERNEVAULT_WITHDRAWAL_QUEUE_STALE_ASSETS_2026-05-23.md):
    ///      Compute the payout from the locked shares at CLAIM time, not from the
    ///      `req.assets` snapshot recorded at REQUEST time. The previous implementation
    ///      paid `req.assets` literally, which created two symmetric failures:
    ///        (a) **Loss event during cooldown** — share price drops, but claimer is paid
    ///            the request-time asset value. The vault transfers more than the locked
    ///            shares are now worth, and the residual loss is socialised across
    ///            non-queueing holders. Effectively a free put for anyone who queues a
    ///            withdrawal before an expected drawdown.
    ///        (b) **Yield event during cooldown** — share price rises, but claimer is
    ///            still paid the smaller request-time amount. The yield-accrued
    ///            difference is donated back to remaining holders and the queueing user
    ///            silently loses their pro-rata yield. Late claimants can also be DoS'd
    ///            if early claimants drain the buffer at stale (over-)pricing.
    ///      `req.assets` is retained in storage as informational metadata (the user's
    ///      request-time hint, used by the off-chain UI for queue-position display), but
    ///      it is no longer load-bearing: the buffer check, tracked-assets decrement,
    ///      transfer amount, and emitted event all derive from `convertToAssets(req.shares)`
    ///      at claim time. Remaining holders' pro-rata claim on the vault is preserved.
    function claimWithdrawal(
        uint256 requestId
    ) external nonReentrant whenNotPaused {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender][requestId];
        if (req.claimed) revert AlreadyClaimed();
        if (block.timestamp < req.unlockTimestamp) revert WithdrawalCooldownNotMet();
        uint256 assetsOut = convertToAssets(req.shares);
        // SECURITY FIX (KRN-26-VAULT-CLAIM-UNDERFLOW): gate the liquidity check on
        // `_trackedOnChainAssets`, the SAME ledger decremented two lines below — not the
        // raw token balance. `assetsOut` is `convertToAssets(req.shares)`, scaled against
        // the full four-bucket `totalAssets()` (on-chain + offChain + l1 + hedgingReserve).
        // Checking raw `balanceOf` while decrementing the on-chain-only ledger compared two
        // different units of account: whenever untracked WETH is physically present
        // (an insurance-fund injection via raw transfer, or a CEX hedge return before the
        // strategist re-syncs) AND most value is reported off-chain, the raw-balance check
        // passed but `_trackedOnChainAssets -= assetsOut` underflowed (panic 0x11),
        // permanently bricking a matured, valid withdrawal. Untracked balance is
        // deliberately excluded from `totalAssets()` (KRN-24-006 donation defense), so a
        // withdrawal is only serviceable from TRACKED on-chain liquidity; gating here keeps
        // the check and the decrement consistent (the subtraction can no longer underflow)
        // and the physical `safeTransfer` below is safe because `_trackedOnChainAssets`
        // never exceeds the real token balance. The matured request claims normally as soon
        // as the strategist restores tracked on-chain liquidity (the queue's whole purpose).
        if (_trackedOnChainAssets < assetsOut) revert InsufficientLiquidBuffer();
        req.claimed = true;
        _burn(address(this), req.shares);
        _trackedOnChainAssets -= assetsOut;
        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, assetsOut);
        emit WithdrawalClaimed(msg.sender, requestId, assetsOut);
    }

    /// @notice Returns the total number of withdrawal requests submitted by a user.
    /// @dev Use as the upper bound for iterating over `withdrawalRequests[user][]`.
    /// @param user The address to query.
    /// @return The number of withdrawal requests (including both pending and claimed).
    function getWithdrawalRequestCount(
        address user
    ) external view returns (uint256) {
        return withdrawalRequests[user].length;
    }

    // --- Prime Account Support ---

    /// @notice Metadata for a registered prime account (institutional capital manager).
    struct PrimeInfo {
        bool active;
        ///< Whether this address is an active prime account.
        uint256 allocatedAssets;
    }
    ///< Vault assets currently allocated to this prime account.

    /// @notice Registered prime accounts and their allocation tracking.
    mapping(address => PrimeInfo) public primeAccounts;

    /// @notice Transfers on-chain vault assets to a registered prime account for off-chain deployment.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The transferred amount is subtracted from
    ///      `_trackedOnChainAssets` and added to the prime account's `allocatedAssets` tracking.
    ///      Prime accounts are expected to return assets (with yield) via `returnFromPrime()`.
    /// @param prime The prime account address (must be active via `setPrimeAccount()`).
    /// @param amount The amount of vault assets to transfer to the prime account.
    function transferToPrime(
        address prime,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!primeAccounts[prime].active) revert NotPrimeAccount();
        _trackedOnChainAssets -= amount;
        primeAccounts[prime].allocatedAssets += amount;
        SafeERC20.safeTransfer(IERC20(asset()), prime, amount);
    }

    /// @notice Returns assets from a prime account back to the vault's on-chain balance.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The prime account transfers assets directly to the vault
    ///      via `safeTransferFrom` — `_trackedOnChainAssets` is incremented by the actual amount received
    ///      (measured by balance delta) rather than the declared amount, to prevent manipulation.
    ///      `allocatedAssets` is decremented safely with underflow protection in case profits were returned
    ///      without a prior `transferToPrime()` call.
    /// @param prime The prime account address returning assets.
    /// @param amount The amount of assets being returned (in asset decimals).
    function returnFromPrime(
        address prime,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (!primeAccounts[prime].active) revert NotPrimeAccount();
        // Safe subtraction: allocatedAssets may be 0 if funds were returned without a prior
        // transferToPrime call (e.g. CEX profit returned directly). Clamp to 0 to prevent underflow.
        if (primeAccounts[prime].allocatedAssets >= amount) {
            primeAccounts[prime].allocatedAssets -= amount;
        } else {
            primeAccounts[prime].allocatedAssets = 0;
        }
        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(asset()), prime, address(this), amount);
        _trackedOnChainAssets += IERC20(asset()).balanceOf(address(this)) - balBefore;
    }

    /// @notice Credits a capital injection pushed by the configured insurance fund into
    ///         the vault's tracked on-chain assets, so the injection actually raises the
    ///         collateral ratio.
    /// @dev SECURITY FIX (KRN-26-INS-INJECT-UNTRACKED, 2026-06-07,
    ///      docs/security/INSURANCE_INJECTION_UNTRACKED_CR_2026-06-07.md):
    ///      KerneInsuranceFund.checkAndInject()/socializeLoss() size an injection to lift
    ///      getSolvencyRatio() back above the 1.30x critical threshold, but deliver the
    ///      capital with a bare `IERC20.safeTransfer`. totalAssets() sources from
    ///      `_trackedOnChainAssets`, NOT the raw token balance (donation defense KRN-24-006),
    ///      so a raw transfer lands as UNTRACKED balance and never moves the CR. The
    ///      injection condition (`cr < criticalThreshold`) therefore stays true forever and
    ///      the fund bleeds into the vault one cooldown window at a time WITHOUT ever
    ///      repairing solvency — the per-vault cooldown added in the 2026-05-23 audit only
    ///      rate-limits the bleed, it does not make the "self-correcting" injection math
    ///      trip. This hook lets the fund credit the just-pushed capital into the tracked
    ///      ledger so the CR rises and the injection self-terminates.
    ///
    ///      It does NOT reopen KRN-24-006: the credit is gated to the configured
    ///      `insuranceFund` address AND bounded by the genuine surplus of real balance over
    ///      tracked assets, capped at the declared `amount`. An attacker's raw donation can
    ///      never be credited (wrong caller), and the insurance fund can never credit more
    ///      than it actually delivered (surplus + amount caps). Mirrors the balance-delta
    ///      credit pattern of `returnFromPrime`. No `whenNotPaused` guard: an injection that
    ///      restores solvency must remain possible while the vault is paused.
    /// @param amount The amount the insurance fund just transferred in and wishes to credit.
    function injectFromInsurance(
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != insuranceFund) revert NotInsuranceFund();
        // Credit at most the genuine untracked surplus (balance - tracked), capped at the
        // declared injection. Invariant: balanceOf >= _trackedOnChainAssets, so no underflow.
        uint256 surplus = IERC20(asset()).balanceOf(address(this)) - _trackedOnChainAssets;
        uint256 credit = amount < surplus ? amount : surplus;
        if (credit > 0) {
            _trackedOnChainAssets += credit;
            emit InsuranceInjectionReceived(msg.sender, credit);
        }
    }

    // --- Emergency Exit ---

    /// @notice Emergency drain of all on-chain vault assets to a recipient address.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE and ONLY when the vault is paused.
    ///      This is a last-resort mechanism for situations where normal operations cannot resume
    ///      (e.g., critical exploit, irrecoverable insolvency). Drain is irreversible.
    ///      After calling, the vault's `_trackedOnChainAssets` is reset to 0.
    /// @param recipient The address to receive all drained assets (must be the Kerne multisig or a recovery wallet).
    function emergencyExit(
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!paused()) revert MustBePaused();

        // Audit-bundle (2026-05-14): pin the recipient to the pre-committed
        // `emergencyRecipient` so a compromised DEFAULT_ADMIN_ROLE cannot drain assets to
        // an attacker-controlled address mid-emergency. The recipient is selected ahead of
        // time via `setEmergencyRecipient` (admin-only, only while unpaused), which both
        // forces deliberation and prevents an attacker who has captured admin from
        // re-routing under pause.
        address pinnedRecipient = emergencyRecipient;
        if (pinnedRecipient == address(0)) revert EmergencyRecipientNotSet();
        if (recipient != pinnedRecipient) revert EmergencyRecipientMismatch(recipient, pinnedRecipient);

        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance > 0) {
            _trackedOnChainAssets = 0;
            SafeERC20.safeTransfer(IERC20(asset()), pinnedRecipient, balance);
        }
    }

    /// @notice Audit-bundle (2026-05-14): pre-commit the recipient address that
    ///         `emergencyExit` is allowed to drain to. Only callable by DEFAULT_ADMIN_ROLE
    ///         and only while the vault is unpaused; an admin captured by an attacker who
    ///         then pauses the vault cannot rotate the recipient to themselves under stress.
    /// @param newRecipient The address (typically the Kerne multisig treasury or a
    ///         dedicated recovery wallet) that any future `emergencyExit` call must use.
    function setEmergencyRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (paused()) revert EmergencyRecipientLockedWhilePaused();
        if (newRecipient == address(0)) revert ZeroAddress();
        address oldRecipient = emergencyRecipient;
        emergencyRecipient = newRecipient;
        emit EmergencyRecipientUpdated(oldRecipient, newRecipient);
    }

    // --- Deposit Fee ---

    /// @notice Sets the deposit fee charged on each deposit in basis points.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Hard capped at MAX_DEPOSIT_FEE_BPS (100 bps = 1%).
    ///      The fee is deducted from the deposited amount before shares are calculated,
    ///      and routed to the treasury (or founder if treasury is not set).
    ///      This creates a sustainable protocol revenue source without impacting APY calculations.
    /// @param bps The new deposit fee in basis points (max 100 = 1%).
    function setDepositFee(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_DEPOSIT_FEE_BPS) revert FeeTooHigh(bps, MAX_DEPOSIT_FEE_BPS);
        depositFeeBps = bps;
        emit DepositFeeUpdated(bps);
    }

    // --- ERC4626 Overrides ---

    /// @notice Returns the maximum amount a given receiver can deposit in a single transaction.
    /// @dev Override of ERC-4626 standard. Returns 0 if vault is paused, receiver is not whitelisted/compliant,
    ///      or the vault has hit its `maxTotalAssets` cap. Returns `maxDepositLimit` if a circuit breaker cap
    ///      is set, otherwise returns `type(uint256).max` (unlimited).
    /// @param receiver The address that would receive shares for the deposit.
    /// @return The maximum depositable amount in underlying asset units.
    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        if (paused()) return 0;
        if (whitelistEnabled) {
            // Allow deposit if explicitly whitelisted OR if compliance hook approves them.
            // This ensures globally-compliant users (e.g. KYC'd via hook) can deposit
            // without needing a separate whitelist entry per vault.
            bool isWhitelisted = whitelisted[receiver];
            bool isCompliant =
                address(complianceHook) != address(0) && complianceHook.isCompliant(address(this), receiver);
            if (!isWhitelisted && !isCompliant) return 0;
        }
        if (maxTotalAssets > 0 && totalAssets() >= maxTotalAssets) return 0;
        if (maxDepositLimit > 0) return maxDepositLimit;
        return type(uint256).max;
    }

    /// @notice Returns the maximum number of shares that can be minted for a given receiver.
    /// @dev Derived from `maxDeposit()` — delegates access control and cap logic there.
    ///      Returns 0 if maxDeposit returns 0, `type(uint256).max` if unlimited.
    /// @param receiver The address that would receive the minted shares.
    /// @return Maximum shares mintable in a single transaction.
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        uint256 maxDep = maxDeposit(receiver);
        if (maxDep == 0) return 0;
        if (maxDep == type(uint256).max) return type(uint256).max;
        return previewDeposit(maxDep);
    }

    /// @notice Returns the number of shares that would be minted for a given deposit amount.
    /// @dev Override of ERC-4626 standard. Subtracts the deposit fee before computing shares
    ///      via the parent `previewDeposit()`. This ensures callers see the net shares they receive
    ///      (after fee) when simulating a deposit off-chain (e.g., from the frontend or SDK).
    /// @param assets The gross amount of assets before the deposit fee is deducted.
    /// @return The number of vault shares the depositor would receive.
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        uint256 fee = (assets * depositFeeBps) / 10000;
        return super.previewDeposit(assets - fee);
    }

    /// @notice Returns the gross asset amount a caller must supply to mint exactly `shares`.
    /// @dev SECURITY (audit 2026-05-23, docs/security/KERNEVAULT_MINT_BYPASSES_DEPOSIT_FEE_2026-05-23.md):
    ///      Mirror `previewDeposit`'s fee adjustment so `mint(N)` and `deposit(previewMint(N))`
    ///      land the depositor on the same per-share cost. Without this override, OZ's default
    ///      `previewMint(N)` returned the un-adjusted `N · totalAssets / totalSupply`, and the
    ///      shared `_deposit` hook then deducted the fee — minting `N` full shares against a
    ///      vault that only grew by `N · A / S − fee`. The shortfall was paid by every existing
    ///      kLP holder via share-price dilution, letting any depositor shift the entire deposit
    ///      fee off themselves and onto the existing holder set by choosing `mint()` over
    ///      `deposit()`. The override grosses the assets up by `10000 / (10000 − depositFeeBps)`
    ///      with ceil rounding so `_deposit`'s post-fee credit equals the share-implied amount
    ///      exactly, preserving the share price across `mint`.
    /// @param shares The number of shares the depositor wants to mint.
    /// @return The gross asset amount (inclusive of the deposit fee) the depositor must supply.
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        uint256 grossAssetsExFee = super.previewMint(shares);
        if (depositFeeBps == 0) return grossAssetsExFee;
        return Math.mulDiv(grossAssetsExFee, 10000, 10000 - depositFeeBps, Math.Rounding.Ceil);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (whitelistEnabled) {
            // Mirror maxDeposit logic: allow if whitelisted OR compliance hook approves.
            bool isWhitelisted = whitelisted[receiver];
            bool isCompliant =
                address(complianceHook) != address(0) && complianceHook.isCompliant(address(this), receiver);
            if (!isWhitelisted && !isCompliant) revert NotWhitelistedOrCompliant();
        } else if (address(complianceHook) != address(0)) {
            if (!complianceHook.isCompliant(address(this), receiver)) revert ComplianceCheckFailed();
        }
        if (maxTotalAssets > 0 && totalAssets() + assets > maxTotalAssets) revert DepositCapExceeded();
        uint256 fee = (assets * depositFeeBps) / 10000;
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);

        // BUG-06 FIX: When treasury == address(0) and fee > 0, the original code silently kept the
        // fee inside the vault but still excluded it from _trackedOnChainAssets. This created a
        // permanent accounting gap: the fee amount was physically in the contract but invisible to
        // totalAssets(), inflating the share price for all existing holders and eventually drifting
        // the vault into an inconsistent state. The fix routes the fee to the founder address as a
        // safe fallback (founder is always set in _initialize). If neither treasury nor founder is
        // set (genesis-phase vault before any config), the fee is simply absorbed into tracked assets
        // to keep accounting clean rather than silently discarding it.
        if (fee > 0) {
            address feeRecipient = treasury != address(0) ? treasury : (founder != address(0) ? founder : address(0));
            if (feeRecipient != address(0)) {
                SafeERC20.safeTransfer(IERC20(asset()), feeRecipient, fee);
                // Do NOT add fee to _trackedOnChainAssets — it left the vault.
            } else {
                // No recipient configured: absorb fee into tracked assets so accounting remains clean.
                // This is a no-op in practice because assets - fee + fee == assets,
                // but it makes the accounting intent explicit and avoids any rounding edge cases.
                fee = 0;
            }
        }
        _trackedOnChainAssets += assets - fee;
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);

        _trackGenesisDeposit(receiver, assets);
    }

    function _withdraw(
        address,
        address,
        address,
        uint256,
        uint256
    ) internal pure override {
        revert UseRequestWithdrawal();
    }

    // --- Tiered Yield Strip ---

    /// @notice The vault's TVL expressed in 18-decimal USD — the unit the fee-phase
    ///         thresholds (GENESIS_TVL_THRESHOLD / GROWTH_TVL_THRESHOLD) are denominated in.
    /// @dev SECURITY FIX (KRN-26-VAULT-PHASE-USD): `totalAssets()` is in the asset's NATIVE
    ///      units, but the phase thresholds are USD (PROTOCOL_CONSTANTS.md). Comparing them
    ///      directly — the behavior left behind when the price oracle was removed on
    ///      2026-02-26 — meant a 6-dp USDC vault only left Genesis at ~$100T and an 18-dp LST
    ///      vault (cbETH/wstETH ~ $3k) at ~$300M, so `getEffectivePerformanceFee()` returned
    ///      0 and `captureFounderWealth()` was a permanent no-op at every realistic TVL: the
    ///      protocol collected ZERO performance fee, indefinitely.
    ///
    ///      - priceOracle set: getValueUSD() converts native units -> 18-dp USD, handling
    ///        BOTH non-18 decimals AND non-$1 price. REQUIRED for non-$1-pegged collateral.
    ///      - priceOracle unset: scale totalAssets() to 18 decimals and treat the asset as
    ///        $1-pegged. Exact for a USD-stablecoin vault (the primary deployment), a strict
    ///        no-op for an 18-dp asset. Asset decimals are derived in-contract as
    ///        `decimals() - _decimalsOffset()`, so the fallback adds no external call.
    ///      Fails safe: an oracle revert (stale feed / circuit breaker / sequencer down)
    ///      falls back to the $1-peg estimate, so a transient oracle fault can never brick
    ///      deposits (_trackGenesisDeposit) or fee reads.
    function _tvlInUsd18() internal view returns (uint256) {
        uint256 tvl = totalAssets();
        if (tvl == 0) return 0;

        address oracle = priceOracle;
        if (oracle != address(0)) {
            try IKerneOracleRouter(oracle).getValueUSD(asset(), tvl) returns (uint256 usd) {
                return usd;
            } catch {
                // fall through to the $1-peg estimate on any oracle failure
            }
        }

        uint8 dec = decimals() - _decimalsOffset(); // the asset's native decimals
        if (dec < 18) return tvl * (10 ** (18 - dec));
        if (dec > 18) return tvl / (10 ** (dec - 18));
        return tvl;
    }

    /// @notice Returns the current performance fee in basis points.
    /// @dev Phase schedule (LONGBACKTEST canonical — 33.29% gross APY):
    ///      Genesis  (0 → $100k TVL):    0 bps  — 0% fee, ~26.25% net APY
    ///      Growth   ($100k → $1M TVL):  500 bps — 5% fee, ~24.94% net APY
    ///      Maturity (≥ $1M TVL):       1000 bps — 10% fee, ~23.62% net APY
    ///      All fee revenue goes to founders/treasury. TVL is measured in USD via
    ///      _tvlInUsd18() so the dollar thresholds are honored regardless of the vault
    ///      asset's decimals or price (KRN-26-VAULT-PHASE-USD).
    /// @return bps The fee applied to this period's gross yield.
    function getEffectivePerformanceFee() public view returns (uint256) {
        if (genesisPhaseActive) return 0;
        // KRN-26-VAULT-PHASE-USD: compare USD TVL against the USD-denominated thresholds.
        uint256 tvl = _tvlInUsd18();
        if (tvl < GROWTH_TVL_THRESHOLD) return GROWTH_PHASE_FEE_BPS;
        // Maturity Phase: 10% protocol revenue, all to founders/treasury
        return MATURITY_PHASE_FEE_BPS;
    }

    /// @notice Returns the reward reserve portion of the fee schedule.
    /// @dev Always returns 0 — reward reserve strip removed. All fee goes to founders/treasury.
    function getCurrentRewardReserveBps() public view returns (uint256) {
        return 0;
    }

    /// @notice Returns the current founder / treasury revenue take in basis points.
    /// @dev This is the economically extractable portion after subtracting the user reward reserve.
    function getCurrentFounderRevenueBps() public view returns (uint256) {
        uint256 effectiveFeeBps = getEffectivePerformanceFee();
        uint256 rewardReserveBps = getCurrentRewardReserveBps();
        if (effectiveFeeBps <= rewardReserveBps) return 0;
        return effectiveFeeBps - rewardReserveBps;
    }

    /// @notice Returns the vault's current projected annual percentage yield in basis points.
    /// @dev This is an informational read-only value set by the strategist via `updateProjectedAPY()`.
    ///      It does NOT affect share pricing or yield calculations — purely for frontend display.
    /// @return The projected APY in basis points (e.g., 2625 = 26.25%).
    function getProjectedAPY() external view returns (uint256) {
        return projectedAPY;
    }

    // --- Genesis Phase ---
    function _trackGenesisDeposit(
        address user,
        uint256 assets
    ) internal {
        if (!genesisPhaseActive) return;
        genesisPhaseDeposits += assets;
        emit GenesisPhaseDeposit(user, assets, genesisPhaseDeposits);
        // KRN-26-VAULT-PHASE-USD: end Genesis when USD TVL crosses the USD threshold, not
        // when raw asset units do (which never happens at a realistic dollar TVL).
        if (_tvlInUsd18() >= GENESIS_TVL_THRESHOLD) {
            genesisPhaseActive = false;
            genesisPhaseEndedAt = block.timestamp;
            emit GenesisPhaseEnded(totalAssets(), block.timestamp);
        }
    }

    /// @notice Manually ends the Genesis Phase and activates the Growth Phase fee schedule.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Normally Genesis ends automatically when
    ///      TVL crosses `GENESIS_TVL_THRESHOLD` (100k USD). Call this to end it early if needed
    ///      (e.g., for time-based launch control or if the threshold isn't reached naturally).
    ///      Reverts if Genesis Phase has already ended.
    function endGenesisPhase() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!genesisPhaseActive) revert GenesisAlreadyEnded();
        genesisPhaseActive = false;
        genesisPhaseEndedAt = block.timestamp;
        emit GenesisPhaseEnded(totalAssets(), block.timestamp);
    }

    // --- CR Circuit Breaker ---
    function _checkCRCircuitBreaker() internal {
        uint256 cr = getSolvencyRatio();
        if (cr < CRITICAL_CR_THRESHOLD) {
            if (!crCircuitBreakerActive) {
                crCircuitBreakerActive = true;
                crCircuitBreakerTriggeredAt = block.timestamp;
                emit CRCircuitBreakerTriggered(cr, block.timestamp);
                if (!paused()) _pause();
            }
        } else if (cr < WARNING_CR_THRESHOLD) {
            if (!crSoftAlertActive) {
                crSoftAlertActive = true;
                emit CRSoftAlertTriggered(cr, block.timestamp);
            }
        } else if (cr >= SAFE_CR_THRESHOLD) {
            if (crCircuitBreakerActive && block.timestamp >= crCircuitBreakerTriggeredAt + crCircuitBreakerCooldown) {
                crCircuitBreakerActive = false;
                emit CRCircuitBreakerRecovered(cr, block.timestamp);
            }
            if (crSoftAlertActive) {
                crSoftAlertActive = false;
                emit CRSoftAlertRecovered(cr, block.timestamp);
            }
        }
    }

    /// @notice Manually recovers from the CR circuit breaker (Red Halt) after solvency is restored.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Requires:
    ///      1. Circuit breaker is currently active.
    ///      2. The `crCircuitBreakerCooldown` period has elapsed since the breaker was triggered.
    ///      3. Current CR is >= SAFE_CR_THRESHOLD (101%).
    ///      After recovery, the vault remains paused — the admin must separately call `unpause()`.
    function recoverCRCircuitBreaker() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!crCircuitBreakerActive) revert CircuitBreakerNotActive();
        if (block.timestamp < crCircuitBreakerTriggeredAt + crCircuitBreakerCooldown) revert UpdateCooldownNotMet();
        uint256 cr = getSolvencyRatio();
        if (cr < SAFE_CR_THRESHOLD) revert CRStillLow();
        crCircuitBreakerActive = false;
        emit CRCircuitBreakerRecovered(cr, block.timestamp);
    }

    /// @notice Sets the dynamic collateral ratio buffer used during market stress periods.
    /// @dev Only callable by STRATEGIST_ROLE. The buffer is added on top of baseline CR thresholds
    ///      during stressed market conditions to provide additional liquidation runway.
    ///      Used by the off-chain monitoring bot to dynamically tighten risk parameters.
    /// @param bufferBps The dynamic CR buffer in basis points (e.g., 500 = 5% extra cushion).
    function setDynamicBuffer(
        uint256 bufferBps
    ) external onlyRole(STRATEGIST_ROLE) {
        uint256 old = dynamicCRBuffer;
        dynamicCRBuffer = bufferBps;
        emit DynamicBufferUpdated(old, bufferBps);
    }
}
