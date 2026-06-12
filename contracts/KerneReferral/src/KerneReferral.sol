// SPDX-License-Identifier: MIT
// Created: 2026-03-03
pragma solidity 0.8.24;

// ─── CUSTOM ERRORS ─────────────────────────────────────────────────────────────
// Gas-efficient custom errors replace require() strings per Kerne code style.
// Declared at file-level (outside the contract body) for consistency with the
// codebase-wide custom error migration (batch 2b).
// ────────────────────────────────────────────────────────────────────────────────

/// @dev Reverts when the referrer address is address(0).
error Referral__ZeroAddress();

/// @dev Reverts when a user attempts to refer themselves.
error Referral__SelfReferral();

/// @dev Reverts when a referee already has a referrer (first-referrer-wins rule).
error Referral__AlreadyReferred();

/// @dev Reverts when a referrer has hit the MAX_REFERRALS_PER_ADDRESS cap.
error Referral__CapReached();

/**
 * @title KerneReferral
 * @author Kerne Protocol
 * @notice Lightweight on-chain registry for the Kerne referral graph.
 *
 * ─── ARCHITECTURE RATIONALE ───────────────────────────────────────────────────
 * Storing referral balances on-chain per transaction would be gas intensive.
 * Instead, this contract serves as a TRUSTLESS EVENT LOG for the off-chain snapshot service:
 *
 *   • Referral relationships are stored on-chain (must be tamper-proof and non-repudiable).
 *   • The snapshot bot reads this graph daily to calculate the 10% Hard Yield kickbacks
 *     which are eventually distributed through the KerneYieldDistributor via a Merkle tree.
 */
contract KerneReferral {
    // ============================================================
    //          CONSTANTS
    // ============================================================

    /// @notice Maximum number of referred wallets a single address can receive bonus for.
    /// @dev V7 Final: Cap at 10 to preserve decentralisation and discourage farming rings.
    uint256 public constant MAX_REFERRALS_PER_ADDRESS = 10;

    // ============================================================
    //                   PER-USER STATE
    // ============================================================

    /// @notice The address that referred a given user.
    /// @dev Set once in registerReferral(). Never overwritten — first referrer wins.
    mapping(address => address) public referrerOf;

    /// @notice Number of wallets successfully referred by a given address.
    /// @dev Capped at MAX_REFERRALS_PER_ADDRESS.
    mapping(address => uint256) public referralCount;

    // ============================================================
    //                         EVENTS
    // ============================================================

    /// @notice Emitted whenever a referral relationship is registered on-chain.
    event ReferralRegistered(address indexed referrer, address indexed referee, uint256 timestamp);

    // ============================================================
    //               USER-CALLABLE FUNCTIONS
    // ============================================================

    /// @notice Register a referral relationship on-chain.
    /// @dev This is the PERMANENT on-chain record of who referred whom.
    ///
    /// @param referrer The address that should receive the referral bonus.
    function registerReferral(
        address referrer
    ) external {
        address referee = msg.sender;
        // Zero-address check: referrer must be a real wallet
        if (referrer == address(0)) revert Referral__ZeroAddress();
        // Note: referee == msg.sender, which is never address(0) in practice,
        // but we keep this guard for defense-in-depth against future EVM changes.
        if (referee == address(0)) revert Referral__ZeroAddress();

        // Self-referral explicitly blocked — prevents gaming the 10% kickback
        if (referrer == referee) revert Referral__SelfReferral();

        // First-referrer-wins: once a referee has a referrer, the relationship is permanent.
        if (referrerOf[referee] != address(0)) revert Referral__AlreadyReferred();

        // Cap: max 10 credited referrals per address (V7 Final).
        // Prevents Sybil-style referral farming rings.
        if (referralCount[referrer] >= MAX_REFERRALS_PER_ADDRESS) revert Referral__CapReached();

        referrerOf[referee] = referrer;
        referralCount[referrer] += 1;

        emit ReferralRegistered(referrer, referee, block.timestamp);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the referrer for a given user.
    function getReferrer(
        address user
    ) external view returns (address) {
        return referrerOf[user];
    }
}
