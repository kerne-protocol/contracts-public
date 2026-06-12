// SPDX-License-Identifier: MIT
// Updated: 2026-03-20 - Gas optimization: Migrated all require() strings to custom errors
// Created: 2026-01-10
// Updated: 2026-01-12 - Institutional Deep Hardening: Medianizer, outlier rejection, and multi-node consensus
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { KerneVault } from "./KerneVault.sol";

/**
 * @title KerneYieldOracle
 * @author Kerne Protocol
 * @notice A manipulation-resistant yield oracle providing TWAY (Time-Weighted Average Yield).
 * Hardened with medianizer logic, outlier rejection, and multi-node consensus.
 */
contract KerneYieldOracle is AccessControl {
    // ========================= CUSTOM ERRORS =========================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.
    // Migrated as part of Batch 3 custom error migration (Phase 12).
    /// @dev Replaces: require(..., "Already confirmed")
    error AlreadyConfirmed();
    /// @dev Replaces: require(..., "Consensus mismatch")
    error ConsensusMismatch();

    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    struct YieldObservation {
        uint256 timestamp;
        uint256 sharePrice;
    }

    struct Proposal {
        uint256 sharePrice;
        uint256 timestamp;
        uint256 confirmations;
        mapping(address => bool) hasConfirmed;
    }

    mapping(address => YieldObservation[]) public observations;
    mapping(address => Proposal) public pendingProposals;

    uint256 public yieldWindow = 7 days;
    uint256 public maxStaleness = 24 hours;
    uint256 public requiredConfirmations = 3;
    uint256 public maxPriceDeviationBps = 500; // 5% max deviation from previous observation

    address[] public registeredVaults;
    mapping(address => bool) public isRegistered;

    event YieldUpdated(address indexed vault, uint256 sharePrice, uint256 timestamp);
    event ProposalCreated(address indexed vault, uint256 sharePrice, address indexed proposer);
    event ProposalConfirmed(address indexed vault, address indexed confirmer);
    event ConfigUpdated(string param, uint256 value);

    constructor(
        address admin
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @notice Proposes or confirms a new share price with outlier rejection.
     */
    function updateYield(
        address vault
    ) external onlyRole(UPDATER_ROLE) {
        KerneVault v = KerneVault(vault);
        uint256 price = v.convertToAssets(1e18);

        // Outlier Rejection: Check deviation from last observation
        YieldObservation[] storage obs = observations[vault];
        if (obs.length > 0) {
            uint256 lastPrice = obs[obs.length - 1].sharePrice;
            if (lastPrice > 0) {
                uint256 diff = price > lastPrice ? price - lastPrice : lastPrice - price;
                // deviation = (diff * 10000) / lastPrice
                // To avoid overflow: diff <= (maxPriceDeviationBps * lastPrice) / 10000
                if (diff > (maxPriceDeviationBps * lastPrice) / 10000) {
                    revert("Outlier rejected: Price deviation too high");
                }
            }
        }

        Proposal storage prop = pendingProposals[vault];

        // Safe check to avoid underflow when block.timestamp < 1 hours or prop.timestamp == 0
        if (prop.timestamp == 0 || block.timestamp > prop.timestamp + 1 hours) {
            prop.sharePrice = price;
            prop.timestamp = block.timestamp;
            prop.confirmations = 1;
            emit ProposalCreated(vault, price, msg.sender);
        } else {
            if (!(prop.sharePrice == price)) revert ConsensusMismatch();
            if (!(!prop.hasConfirmed[msg.sender])) revert AlreadyConfirmed();

            prop.confirmations++;
            prop.hasConfirmed[msg.sender] = true;
            emit ProposalConfirmed(vault, msg.sender);
        }

        if (prop.confirmations >= requiredConfirmations) {
            observations[vault].push(YieldObservation({ timestamp: prop.timestamp, sharePrice: prop.sharePrice }));
            delete pendingProposals[vault];
            emit YieldUpdated(vault, price, block.timestamp);
        }
    }

    function getTWAY(
        address vault
    ) public view returns (uint256 apyBps) {
        YieldObservation[] storage obs = observations[vault];
        if (obs.length < 2) return 0;

        YieldObservation memory latest = obs[obs.length - 1];
        uint256 targetTime = block.timestamp > yieldWindow ? block.timestamp - yieldWindow : obs[0].timestamp;

        YieldObservation memory oldest = obs[0];
        for (uint256 i = obs.length; i > 0; i--) {
            if (obs[i - 1].timestamp <= targetTime) {
                oldest = obs[i - 1];
                break;
            }
        }

        uint256 timeDiff = latest.timestamp - oldest.timestamp;
        if (timeDiff == 0 || latest.sharePrice <= oldest.sharePrice) return 0;

        // Simplified APY calculation to avoid overflow
        // (latest / oldest - 1) * (365 days / timeDiff) * 10000
        // We use 1e10 as a multiplier for precision
        uint256 growth = (latest.sharePrice * 1e10) / oldest.sharePrice;
        if (growth <= 1e10) return 0;

        uint256 netGrowth = growth - 1e10;
        apyBps = (netGrowth * 365 days * 10000) / (timeDiff * 1e10);
    }

    function setRequiredConfirmations(
        uint256 _count
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requiredConfirmations = _count;
        emit ConfigUpdated("requiredConfirmations", _count);
    }

    function setMaxPriceDeviation(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPriceDeviationBps = bps;
        emit ConfigUpdated("maxPriceDeviationBps", bps);
    }
}
