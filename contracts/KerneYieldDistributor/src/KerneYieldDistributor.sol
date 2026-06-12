// SPDX-License-Identifier: MIT
// Updated: 2026-03-20 - Gas optimization: Migrated all require() strings to custom errors
// Created: 2026-03-03
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title KerneYieldDistributor
 * @author Kerne Protocol
 * @notice Distributes Loyalty Tier bonuses and Referral Kickbacks via Merkle Roots.
 *
 * ─── ARCHITECTURE ─────────────────────────────────────────────────────────────
 * Because KerneVault is a standard ERC-4626 where all shares strictly maintain
 * identical yield mathematically, we cannot award Tier boosts or Referral bonuses
 * directly inside the vault without breaking the standard.
 *
 * Instead, Kerne employs a "Yield Strip" model:
 * 1. The Vault applies a 10% Performance Fee on gross yield (MATURITY_PHASE_FEE_BPS = 1000 bps).
 *    The 24% Yield Strip architecture previously modeled as additional fee reduction has been deprecated.
 *    Current fee schedule: Genesis 0%, Growth 5%, Maturity 10% (1000 bps performance fee only).
 * 2. The off-chain snapshot service computes exact Tier bonuses and Referral kickbacks
 *    owed to each user out of that 24% strip.
 * 3. The protocol deposits the exact USDC owed into this Distributor contract.
 * 4. A weekly Merkle Root is published here, allowing users to claim their real yield.
 */
contract KerneYieldDistributor is AccessControl, ReentrancyGuard {
    // ========================= CUSTOM ERRORS =========================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.
    // Migrated as part of Batch 3 custom error migration (Phase 12).
    /// @dev Replaces: require(..., "Invalid proof")
    error InvalidProof();
    /// @dev Replaces: require(..., "Nothing to claim")
    error NothingToClaim();
    /// @dev Replaces: require(..., "Root not set")
    error RootNotSet();
    /// @dev Replaces: require(..., "Admin cannot be zero")
    error ZeroAdmin();
    /// @dev Replaces: require(..., "Updater cannot be zero")
    error ZeroUpdater();
    /// @dev Replaces: require(..., "USDC cannot be zero")
    error ZeroUsdc();

    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    IERC20 public immutable usdc;

    /// @notice The latest valid Merkle Root for claims
    bytes32 public currentMerkleRoot;

    /// @notice Tracks total lifetime USDC claimed by each user to prevent double claiming
    /// @dev Users can only claim `amount - claimed[user]` for any given new root.
    mapping(address => uint256) public claimed;

    event MerkleRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);
    event YieldClaimed(address indexed user, uint256 amount);
    event FundsRecovered(address indexed to, uint256 amount);

    constructor(address _admin, address _rootUpdater, address _usdc) {
        if (!(_admin != address(0))) revert ZeroAdmin();
        if (!(_rootUpdater != address(0))) revert ZeroUpdater();
        if (!(_usdc != address(0))) revert ZeroUsdc();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ROOT_UPDATER_ROLE, _rootUpdater);

        usdc = IERC20(_usdc);
    }

    /**
     * @notice Updates the Merkle Root for the current epoch's yield claims.
     * @dev The root must represent the user's CUMULATIVE lifetime yield.
     */
    function updateMerkleRoot(
        bytes32 newRoot
    ) external onlyRole(ROOT_UPDATER_ROLE) {
        bytes32 oldRoot = currentMerkleRoot;
        currentMerkleRoot = newRoot;
        emit MerkleRootUpdated(oldRoot, newRoot);
    }

    /**
     * @notice Allows a user to claim their accrued Tier and Referral yield.
     * @param cumulativeAmount The total lifetime yield this user has earned.
     * @param merkleProof The proof proving the user's allowance in the current root.
     */
    function claim(uint256 cumulativeAmount, bytes32[] calldata merkleProof) external nonReentrant {
        if (!(currentMerkleRoot != bytes32(0))) revert RootNotSet();

        uint256 claimable = cumulativeAmount - claimed[msg.sender];
        if (!(claimable > 0)) revert NothingToClaim();

        // Verify the merkle proof
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, cumulativeAmount))));
        if (!(MerkleProof.verify(merkleProof, currentMerkleRoot, leaf))) revert InvalidProof();

        // Mark as claimed
        claimed[msg.sender] = cumulativeAmount;

        // Transfer yield to user
        SafeERC20.safeTransfer(usdc, msg.sender, claimable);

        emit YieldClaimed(msg.sender, claimable);
    }

    /**
     * @notice Allows admin to recover unused funds from the distributor if needed.
     */
    function recoverFunds(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SafeERC20.safeTransfer(usdc, to, amount);
        emit FundsRecovered(to, amount);
    }
}
