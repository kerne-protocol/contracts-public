// SPDX-License-Identifier: MIT
// Created: 2025-12-28
// Updated: 2026-02-10 - Security Hardening: Off-chain asset bounds, amount validation
// Updated: 2026-03-19 - Gas optimization: Migrated all require() strings to custom errors (~50-100 gas savings per revert)
// Updated: 2026-02-26 - Size reduction: Removed flash loan + price oracle (not needed pre-$10k TVL)
// Updated: 2026-03-08 - Fee correction: MATURITY_PHASE_FEE_BPS simplified to 1000 (10% protocol revenue only).
//                       Depositors at Maturity net ~21.64% (24.048% gross × 0.90).
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
import { IComplianceHook } from "./interfaces/IComplianceHook.sol";

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
    //   Genesis  ($0 – $100k TVL):    0% fee  → ~24.05% net APY
    //   Growth   ($100k – $1M TVL):   5% fee  → ~22.84% net APY
    //   Maturity ($1M+ TVL):         10% fee  → ~21.64% net APY
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

    /// @notice Hedging Reserve for institutional obfuscation
    uint256 public hedgingReserve;

    /// @notice SECURITY (KRN-24-006): Internal tracked on-chain balance.
    uint256 private _trackedOnChainAssets;

    /// @notice SECURITY FIX (KRN-24-011): Entry fee in basis points (default 5 bps = 0.05%).
    uint256 public depositFeeBps = 5;
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

    /// @notice The address of the trust anchor for solvency verification
    address public trustAnchor;

    /// @notice The treasury address for fee collection
    address public treasury;

    /// @notice The address that receives the non-founder reward reserve extracted from gross yield.
    /// @dev This recipient is intentionally separate from the founder / treasury revenue path.
    ///      Kerne's public reward promise depends on users believing the 24% Yield Strip is not
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
    uint256 public withdrawalCooldown = 7 days;

    /// @notice SECURITY: Maximum percentage change allowed for off-chain asset updates (in bps)
    uint256 public maxOffChainChangeRateBps = 2000;

    /// @notice SECURITY: Cooldown between off-chain asset updates
    uint256 public offChainUpdateCooldown = 10 minutes;

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
    uint256 public crCircuitBreakerCooldown = 4 hours;

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
    event VerificationNodeUpdated(address indexed oldNode, address indexed newNode);
    event FounderWealthCaptured(uint256 amount, address indexed recipient);
    event RewardReserveRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event RewardReserveCaptured(uint256 amount, address indexed recipient);
    event InsuranceFundContribution(uint256 amount);
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
        _initialize(name_, symbol_, admin_, strategist_, address(0), 0, 1000, false, address(0), 0);
    }

    /// @notice The factory address authorized to initialize clones
    address public factory;

    // ============================================================
    //                CUSTOM ERRORS
    // ============================================================
    // Gas optimization: Custom errors save ~50-100 gas per revert compared to
    // require(condition, "string") because they avoid ABI-encoding the string.
    // This is the Solidity 0.8.24 best practice per .clinerules §9.
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

    /// @dev Thrown when an off-chain asset update is attempted before the cooldown expires.
    error UpdateCooldownNotMet();

    /// @dev Thrown when the off-chain asset change exceeds the max allowed rate.
    error OffChainChangeExceedsMaxRate();

    /// @dev Thrown when there is no valid sweep destination configured.
    error NoSweepDestination();

    /// @dev Thrown when the founder address has not been set.
    error FounderNotSet();

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

    /// @dev Thrown when a depositor fails whitelist and compliance checks.
    error NotWhitelistedOrCompliant();

    /// @dev Thrown when a depositor fails the compliance hook check.
    error ComplianceCheckFailed();

    /// @dev Thrown when a deposit would exceed the vault's maximum total assets cap.
    error DepositCapExceeded();

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
        address,
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

    function _initialize(
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
    /// @param amount The new total off-chain asset balance in asset decimals.
    function updateOffChainAssets(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (block.timestamp < lastReportedTimestamp + offChainUpdateCooldown) revert UpdateCooldownNotMet();
        uint256 oldAmount = offChainAssets;
        if (oldAmount > 0 && maxOffChainChangeRateBps > 0) {
            uint256 maxChange = (oldAmount * maxOffChainChangeRateBps) / 10000;
            uint256 change = amount > oldAmount ? amount - oldAmount : oldAmount - amount;
            if (change > maxChange) revert OffChainChangeExceedsMaxRate();
        }
        offChainAssets = amount;
        lastReportedTimestamp = block.timestamp;
        emit OffChainAssetsUpdated(oldAmount, amount, block.timestamp);
        _checkCRCircuitBreaker();
    }

    /// @notice Updates the vault's hedging reserve balance reported by the strategist.
    /// @dev Only callable by STRATEGIST_ROLE. The hedging reserve counts toward totalAssets().
    ///      Used for institutional obfuscation of the exact position breakdown on CEX.
    /// @param amount The new total hedging reserve balance in asset decimals.
    function updateHedgingReserve(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        uint256 oldAmount = hedgingReserve;
        hedgingReserve = amount;
        lastReportedTimestamp = block.timestamp;
        emit HedgingReserveUpdated(oldAmount, amount, block.timestamp);
    }

    /// @notice Updates the vault's L1 (Hyperliquid Sovereign Vault) asset balance.
    /// @dev Only callable by STRATEGIST_ROLE. L1 assets count toward totalAssets().
    ///      This mirrors the balance bridged to and held on the Hyperliquid L1 sovereign vault.
    /// @param amount The new total L1 asset balance in asset decimals.
    function updateL1Assets(
        uint256 amount
    ) external onlyRole(STRATEGIST_ROLE) {
        uint256 oldAmount = l1Assets;
        l1Assets = amount;
        lastReportedTimestamp = block.timestamp;
        emit L1AssetsUpdated(oldAmount, amount, block.timestamp);
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
    function setPrimeAccount(address account, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function setWhitelisted(address account, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    function captureFounderWealth(
        uint256 grossYieldAmount
    ) external onlyRole(STRATEGIST_ROLE) {
        if (founder == address(0)) revert FounderNotSet();
        uint256 effectiveFeeBps = getEffectivePerformanceFee();
        if (effectiveFeeBps == 0) return;

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
        uint256 shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroAmount();
        _transfer(msg.sender, address(this), shares);

        uint256 requestId = withdrawalRequests[msg.sender].length;
        uint256 unlockTimestamp = block.timestamp + withdrawalCooldown;
        withdrawalRequests[msg.sender].push(
            WithdrawalRequest({ assets: assets, shares: shares, unlockTimestamp: unlockTimestamp, claimed: false })
        );
        emit WithdrawalRequested(msg.sender, requestId, assets, shares, unlockTimestamp);
        return requestId;
    }

    /// @notice Claims a matured withdrawal request and receives the underlying assets.
    /// @dev Requires the cooldown period to have elapsed and sufficient on-chain liquidity.
    ///      Burns the locked shares and transfers the assets directly to the caller.
    ///      Each request can only be claimed once — `req.claimed` prevents double-claims.
    /// @param requestId The index of the withdrawal request to claim (returned by `requestWithdrawal()`).
    function claimWithdrawal(
        uint256 requestId
    ) external nonReentrant whenNotPaused {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender][requestId];
        if (req.claimed) revert AlreadyClaimed();
        if (block.timestamp < req.unlockTimestamp) revert WithdrawalCooldownNotMet();
        if (IERC20(asset()).balanceOf(address(this)) < req.assets) revert InsufficientLiquidBuffer();
        req.claimed = true;
        _burn(address(this), req.shares);
        _trackedOnChainAssets -= req.assets;
        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, req.assets);
        emit WithdrawalClaimed(msg.sender, requestId, req.assets);
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
        bool active; ///< Whether this address is an active prime account.
        uint256 allocatedAssets; ///< Vault assets currently allocated to this prime account.
    }

    /// @notice Registered prime accounts and their allocation tracking.
    mapping(address => PrimeInfo) public primeAccounts;

    /// @notice Transfers on-chain vault assets to a registered prime account for off-chain deployment.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. The transferred amount is subtracted from
    ///      `_trackedOnChainAssets` and added to the prime account's `allocatedAssets` tracking.
    ///      Prime accounts are expected to return assets (with yield) via `returnFromPrime()`.
    /// @param prime The prime account address (must be active via `setPrimeAccount()`).
    /// @param amount The amount of vault assets to transfer to the prime account.
    function transferToPrime(address prime, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
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
    function returnFromPrime(address prime, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
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
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance > 0) {
            _trackedOnChainAssets = 0;
            SafeERC20.safeTransfer(IERC20(asset()), recipient, balance);
        }
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

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
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

    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert UseRequestWithdrawal();
    }

    // --- Tiered Yield Strip ---

    /// @notice Returns the current performance fee in basis points.
    /// @dev Phase schedule:
    ///      Genesis  (0 → $100k TVL):    0 bps  — 0% fee, ~24.05% net APY
    ///      Growth   ($100k → $1M TVL):  500 bps — 5% fee, ~22.84% net APY
    ///      Maturity (≥ $1M TVL):       1000 bps — 10% fee, ~21.64% net APY
    ///      All fee revenue goes to founders/treasury.
    /// @return bps The fee applied to this period's gross yield.
    function getEffectivePerformanceFee() public view returns (uint256) {
        if (genesisPhaseActive) return 0;
        uint256 tvl = totalAssets();
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
    function _trackGenesisDeposit(address user, uint256 assets) internal {
        if (!genesisPhaseActive) return;
        genesisPhaseDeposits += assets;
        emit GenesisPhaseDeposit(user, assets, genesisPhaseDeposits);
        if (totalAssets() >= GENESIS_TVL_THRESHOLD) {
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
