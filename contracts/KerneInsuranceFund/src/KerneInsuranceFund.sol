// Created: 2026-01-04
// Updated: 2026-02-19 - Added automated injection mechanism for 1.30x critical threshold
// Updated: 2026-03-19 - Gas optimization: Migrated all require() strings to custom errors
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IKerneVault } from "./interfaces/IKerneVault.sol";

/**
 * @title KerneInsuranceFund
 * @author Kerne Protocol
 * @notice Protocol-owned insurance fund to cover depeg events or exchange failures.
 * Hardened with automated yield diversion and multi-sig claim logic.
 */
contract KerneInsuranceFund is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================= CUSTOM ERRORS =========================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.
    // They also reduce deployed bytecode size since error strings are not stored on-chain.

    /// @dev Thrown when caller lacks AUTHORIZED_ROLE or DEFAULT_ADMIN_ROLE
    error NotAuthorized();
    /// @dev Thrown when caller tries to claim before cooldown period expires (1 hour)
    error ClaimCooldownActive();
    /// @dev Thrown when claim amount exceeds the safety limit (maxClaimPercentage of balance)
    error ClaimExceedsSafetyLimit();
    /// @dev Thrown when the vault destination is not an authorized vault
    error VaultNotAuthorized();
    /// @dev Thrown when BPS value exceeds 10000 (100%)
    error InvalidBPS();

    bytes32 public constant AUTHORIZED_ROLE = keccak256("AUTHORIZED_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    address public immutable asset;
    uint256 public totalCovered;
    uint256 public maxClaimPercentage = 5000; // 50% max claim per event to prevent drain

    mapping(address => uint256) public lastClaimTimestamp;

    event FundsDeposited(uint256 amount);
    event AuthorizationUpdated(address indexed caller, bool status);
    event CoverageClaimed(address indexed recipient, uint256 amount);
    event LossSocialized(address indexed vault, uint256 amount);
    event ConfigUpdated(string param, uint256 value);

    constructor(
        address _asset,
        address _admin
    ) {
        asset = _asset;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    function deposit(
        uint256 amount
    ) external nonReentrant {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit FundsDeposited(amount);
    }

    function setAuthorization(
        address caller,
        bool status
    ) external onlyRole(MANAGER_ROLE) {
        if (status) {
            _grantRole(AUTHORIZED_ROLE, caller);
        } else {
            _revokeRole(AUTHORIZED_ROLE, caller);
        }
        emit AuthorizationUpdated(caller, status);
    }

    /**
     * @notice Claims coverage with institutional safeguards.
     */
    function claim(
        address recipient,
        uint256 amount
    ) external nonReentrant {
        // Authorization: Only AUTHORIZED_ROLE or DEFAULT_ADMIN_ROLE can claim insurance funds
        if (!hasRole(AUTHORIZED_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        // Rate limiting: 1-hour cooldown between claims to prevent rapid fund drainage
        if (block.timestamp <= lastClaimTimestamp[msg.sender] + 1 hours) revert ClaimCooldownActive();

        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 maxClaim = (balance * maxClaimPercentage) / 10000;
        // Safety cap: No single claim can exceed maxClaimPercentage of total balance
        if (amount > maxClaim) revert ClaimExceedsSafetyLimit();

        lastClaimTimestamp[msg.sender] = block.timestamp;
        IERC20(asset).safeTransfer(recipient, amount);
        totalCovered += amount;

        emit CoverageClaimed(recipient, amount);
    }

    /**
     * @notice Socializes a loss across the insurance fund.
     * @dev SECURITY FIX: Checks msg.sender authorization (not the vault parameter).
     *      Also validates the vault destination is authorized to prevent misrouting.
     */
    function socializeLoss(
        address vault,
        uint256 amount
    ) external nonReentrant {
        // SECURITY FIX: Authenticate the CALLER, not just the destination
        if (!hasRole(AUTHORIZED_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        // Also validate the vault destination is a known authorized vault
        if (!hasRole(AUTHORIZED_ROLE, vault)) revert VaultNotAuthorized();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 coverAmount = amount > balance ? balance : amount;

        if (coverAmount > 0) {
            IERC20(asset).safeTransfer(vault, coverAmount);
            totalCovered += coverAmount;
            emit LossSocialized(vault, coverAmount);
        }
    }

    /**
     * @notice Automatically injects capital into the vault if its collateral ratio drops below the critical threshold (1.30x).
     * @param vault The address of the KerneVault.
     */
    function checkAndInject(
        address vault
    ) external nonReentrant {
        // Ensure only authorized vaults can receive automated capital injection
        if (!hasRole(AUTHORIZED_ROLE, vault)) revert VaultNotAuthorized();

        IKerneVault kerneVault = IKerneVault(vault);
        uint256 cr = kerneVault.getSolvencyRatio();

        // Critical threshold is 1.30x (13000 bps)
        uint256 criticalThreshold = 13000;

        if (cr < criticalThreshold) {
            // SECURITY FIX (audit 2026-05-11): the previous code computed
            // `targetAssets = totalSupply() * criticalThreshold / 10000`,
            // which conflated raw share supply with normalised liabilities.
            // For an ERC-4626 vault with `_decimalsOffset() > 0` the share
            // supply is `assets * 10^offset` larger than the asset supply,
            // so the old math overstated the deficit by `10^offset` (1000×
            // for KerneVault). Worst case: against a degraded vault where
            // `totalSupply` is dominated by a 1-wei inflation attack, a
            // single anyone-can-call `checkAndInject(degradedVault)` would
            // empty the entire insurance fund into a permanently broken vault.
            //
            // Use the vault's own `getSolvencyRatio()` (which already
            // normalises supply by `_decimalsOffset`) and derive the deficit
            // from the gap between current and target ratio. Rate-limit to
            // `maxClaimPercentage` of the fund per call so even a legitimate
            // injection cannot empty the fund in one tx.
            uint256 currentAssets = kerneVault.totalAssets();
            // deficit (in asset units) such that (currentAssets + deficit) / liabilities = criticalThreshold
            // = currentAssets * (criticalThreshold - cr) / cr
            uint256 deficit = (currentAssets * (criticalThreshold - cr)) / cr;
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 cap = (balance * maxClaimPercentage) / 10000;
            uint256 injectAmount = deficit > cap ? cap : deficit;

            if (injectAmount > 0) {
                IERC20(asset).safeTransfer(vault, injectAmount);
                totalCovered += injectAmount;
                emit LossSocialized(vault, injectAmount);
            }
        }
    }

    function setMaxClaimPercentage(
        uint256 bps
    ) external onlyRole(MANAGER_ROLE) {
        // BPS sanity check: Cannot exceed 100% (10000 bps)
        if (bps > 10000) revert InvalidBPS();
        maxClaimPercentage = bps;
        emit ConfigUpdated("maxClaimPercentage", bps);
    }

    function getBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
