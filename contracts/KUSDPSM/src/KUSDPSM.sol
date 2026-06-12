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
    /// @dev Replaces: require(..., "Cooldown too short")
    error CooldownTooShort();
    /// @dev Replaces: require(..., "Fee too high")
    error FeeTooHigh();
    /// @dev Replaces: require(..., "Flash loan callback failed")
    error FlashLoanCallbackFailed();
    /// @dev Replaces: require(..., "Flash loan exceeds available balance")
    error FlashLoanExceedsBalance();
    /// @dev Replaces: require(..., "Insufficient stable reserves (Peg Defense Failed)")
    error InsufficientStableReserves();
    /// @dev Replaces: require(..., "Insurance draw limit exceeded for this period")
    error InsuranceDrawLimitExceededForThisPeriod();
    /// @dev Replaces: require(..., "Invalid oracle price")
    error InvalidOraclePrice();
    /// @dev Replaces: require(..., "kUSD minting failed")
    error KusdMintFailed();
    /// @dev Replaces: require(..., "Oracle price stale")
    error OraclePriceStale();
    /// @dev Replaces: require(..., "Protocol insolvency: PSM operations halted")
    error ProtocolInsolvency();
    /// @dev Replaces: require(..., "Stable cap exceeded")
    error StableCapExceeded();
    /// @dev Replaces: require(..., "Stable depegged: Circuit breaker triggered")
    error StableDepegged();
    /// @dev Replaces: require(..., "Stable not supported")
    error StableNotSupported();
    /// @dev Replaces: require(..., "Too many fee tiers")
    error TooManyFeeTiers();
    /// @dev Replaces: require(..., "Unsupported token")
    error UnsupportedToken();
    /// @dev Replaces: require(..., "Flash loan amount must be > 0")
    error ZeroFlashLoanAmount();

    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ARBITRAGEUR_ROLE = keccak256("ARBITRAGEUR_ROLE");

    IERC20 public immutable kUSD;
    address public insuranceFund;
    address public vault;

    mapping(address => uint256) public swapFees;
    mapping(address => bool) public supportedStables;
    mapping(address => address) public oracles;
    mapping(address => uint256) public maxDepegBps;

    uint256 public constant DEFAULT_MAX_DEPEG_BPS = 200; // 2%
    uint256 public minSolvencyThreshold = 10100; // 101%

    struct TieredFee {
        uint256 threshold;
        uint256 feeBps;
    }

    mapping(address => TieredFee[]) public tieredFees;

    bool public virtualPegEnabled;
    uint256 public virtualPegFeeBps;
    uint256 public flashFeeBps;

    /// @notice Circuit breaker for total exposure per stable
    mapping(address => uint256) public stableCaps;
    mapping(address => uint256) public currentExposure;

    /// @notice SECURITY: Rate limiting for insurance fund draws (prevents drain attacks)
    uint256 public insuranceDrawCooldown = 1 hours;
    uint256 public maxInsuranceDrawPerPeriod;
    uint256 public lastInsuranceDrawTimestamp;
    uint256 public insuranceDrawnThisPeriod;

    event StableAdded(address indexed stable, uint256 fee, uint256 cap);
    event Swap(address indexed user, address indexed fromToken, address indexed toToken, uint256 amount, uint256 fee);
    event TieredFeeAdded(address indexed stable, uint256 threshold, uint256 feeBps);
    event ExposureUpdated(address indexed stable, uint256 newExposure);

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
        address oracle = oracles[stable];
        if (oracle == address(0)) return;

        (, int256 price,, uint256 updatedAt,) = IAggregatorV3(oracle).latestRoundData();
        if (!(price > 0)) revert InvalidOraclePrice();
        // SECURITY FIX: Reduced staleness threshold from 24h to 1h to prevent stale price exploitation
        if (!(block.timestamp <= updatedAt + 1 hours)) revert OraclePriceStale();

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

    function _checkSolvency() internal view {
        if (vault == address(0)) return;
        (bool success, bytes memory data) = vault.staticcall(abi.encodeWithSignature("getSolvencyRatio()"));
        if (success && data.length == 32) {
            uint256 ratio = abi.decode(data, (uint256));
            if (!(ratio >= minSolvencyThreshold)) revert ProtocolInsolvency();
        }
    }

    function getFee(
        address stable,
        uint256 amount
    ) public view returns (uint256) {
        if (virtualPegEnabled) {
            return (amount * virtualPegFeeBps) / 10000;
        }

        uint256 feeBps = swapFees[stable];
        TieredFee[] storage tiers = tieredFees[stable];

        for (uint256 i = 0; i < tiers.length; i++) {
            if (amount >= tiers[i].threshold) {
                feeBps = tiers[i].feeBps;
                break;
            }
        }
        return (amount * feeBps) / 10000;
    }

    bool public mintingEnabled;

    function setMintingEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintingEnabled = enabled;
    }

    function swapStableForKUSD(
        address stable,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        _checkDepeg(stable);
        _checkSolvency();
        if (!(supportedStables[stable])) revert StableNotSupported();
        if (!(currentExposure[stable] + amount <= stableCaps[stable])) revert StableCapExceeded();

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
        IERC20(stable).safeTransferFrom(msg.sender, address(this), amount);

        if (mintingEnabled) {
            // Attempt to mint kUSD if enabled (use normalized amount)
            (bool success,) = address(kUSD)
                .call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, normalizedAmountAfterFee));
            if (!(success)) revert KusdMintFailed();
        } else {
            kUSD.safeTransfer(msg.sender, normalizedAmountAfterFee);
        }

        emit Swap(msg.sender, stable, address(kUSD), amount, fee);
        emit ExposureUpdated(stable, currentExposure[stable]);
    }

    /**
     * @notice Swaps kUSD for a supported stablecoin.
     * @dev Peg Defense: If PSM reserves are insufficient, it attempts to draw from the Insurance Fund.
     */
    function swapKUSDForStable(
        address stable,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        _checkDepeg(stable);
        _checkSolvency();
        if (!(supportedStables[stable])) revert StableNotSupported();

        uint256 fee = getFee(stable, amount);
        uint256 amountAfterFee = amount - fee;

        // SECURITY FIX: Normalize decimals from kUSD to stable
        // If kUSD is 18 decimals and stable is 6 decimals (USDC/USDT), we must scale down
        uint8 stableDecimals = IERC20Metadata(stable).decimals();
        uint8 kusdDecimals = IERC20Metadata(address(kUSD)).decimals();
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

        if (psmBalance < normalizedAmountAfterFee && insuranceFund != address(0)) {
            uint256 deficit = normalizedAmountAfterFee - psmBalance;

            // SECURITY: Rate limit insurance fund draws to prevent drain attacks
            if (block.timestamp >= lastInsuranceDrawTimestamp + insuranceDrawCooldown) {
                // Reset the period
                insuranceDrawnThisPeriod = 0;
                lastInsuranceDrawTimestamp = block.timestamp;
            }

            // Enforce per-period draw limit (if configured)
            if (maxInsuranceDrawPerPeriod > 0) {
                if (!(insuranceDrawnThisPeriod + deficit <= maxInsuranceDrawPerPeriod)) {
                    revert InsuranceDrawLimitExceededForThisPeriod();
                }
            }

            (bool success,) =
                insuranceFund.call(abi.encodeWithSignature("claim(address,uint256)", address(this), deficit));
            if (success) {
                insuranceDrawnThisPeriod += deficit;
                psmBalance = IERC20(stable).balanceOf(address(this));
            }
        }

        if (!(psmBalance >= normalizedAmountAfterFee)) revert InsufficientStableReserves();

        // SECURITY FIX (KRN-24-008): CEI pattern — update state BEFORE external token transfers
        if (currentExposure[stable] >= amount) {
            currentExposure[stable] -= amount;
        } else {
            currentExposure[stable] = 0;
        }

        kUSD.safeTransferFrom(msg.sender, address(this), amount);
        IERC20(stable).safeTransfer(msg.sender, normalizedAmountAfterFee);

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
    function setTieredFees(
        address stable,
        TieredFee[] calldata fees
    ) external onlyRole(MANAGER_ROLE) {
        if (!(fees.length <= 20)) revert TooManyFeeTiers();
        delete tieredFees[stable];
        for (uint256 i = 0; i < fees.length; i++) {
            if (!(fees[i].feeBps <= 500)) revert FeeTooHigh();
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

    function setInsuranceFund(
        address _insuranceFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        insuranceFund = _insuranceFund;
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

    function setMinSolvencyThreshold(
        uint256 threshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minSolvencyThreshold = threshold;
    }

    /**
     * @notice Sets the rate limit for insurance fund draws.
     * @dev SECURITY FIX: Prevents attackers from draining the insurance fund via repeated PSM swaps.
     * @param _maxPerPeriod Maximum amount drawable per cooldown period (0 = unlimited)
     * @param _cooldown Cooldown period in seconds before the draw counter resets
     */
    function setInsuranceDrawLimits(
        uint256 _maxPerPeriod,
        uint256 _cooldown
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(_cooldown >= 10 minutes)) revert CooldownTooShort();
        maxInsuranceDrawPerPeriod = _maxPerPeriod;
        insuranceDrawCooldown = _cooldown;
    }

    function pause() external onlyRole(MANAGER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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

        return true;
    }
}
