// Created: 2026-04-26
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Pausable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title KerneTokenV2
 * @author Kerne Protocol
 * @notice Replacement governance token for Kerne. Designed to be deployed at a
 *         new address as part of the v1-to-v2 migration described in
 *         docs/security/KERNE_TOKEN_V2_RECOVERY_OPTIONS_2026-04-26.md.
 *
 * @dev Why this contract exists.
 *
 * The original KerneToken at 0xfEA3D217F5f2304C8551dc9F5B5169F2c2d87340 was
 * deployed in early January 2026 from a working copy that had a `mint()` and
 * `MINTER_ROLE`. The on-chain initial supply was 100,000,000 KERNE rather than
 * the 1,000,000,000 described in the head-of-tree source and in the public
 * tokenomics docs. The full deployed supply was retained on the original
 * deployer EOA at 0x57D400cED462a01Ed51a5De038F204Df49690A99, which on
 * 2026-04-06 had its EVM code set to a drainer contract under EIP-7702. The
 * drainer at 0x3ae1f70cf6da80955936f5599d103fcf62162d10 forwards any received
 * ETH to a destination at 0x43b18f8fb488e30d524757d78da1438881d1aaaa and
 * exposes batch-sweep selectors for arbitrary token lists, so the v1 supply is
 * economically frozen on the trapped EOA: not custodially controlled by Kerne
 * and not safely movable by anyone else either.
 *
 * KerneTokenV2 is the clean redeploy. It has the design that the head-of-tree
 * v1 source claimed but the deployed v1 contract did not implement:
 *
 *   1. Initial supply minted exactly once in the constructor and never again.
 *   2. No `MINTER_ROLE`. No `mint()` function. The cap is cryptographic.
 *   3. The full supply is minted to the constructor's `defaultAdmin` parameter
 *      so the deploying script can pass the Kerne 2-of-3 Safe directly and
 *      avoid any "deploy then transfer" race window.
 *
 * It also adds two narrow EIP-7702 awareness features. They do not block any
 * transfer; they only make 7702-delegated recipients observable so wallets,
 * indexers, and the Kerne risk-status API can warn or refuse on the user-facing
 * side without the token contract itself becoming an account-abstraction
 * compatibility hazard:
 *
 *   - A view helper `is7702Delegated(address)` returns true when the queried
 *     address has bytecode that begins with the EIP-7702 magic prefix
 *     `0xef0100`. The follow-on 20 bytes are the delegate address, exposed via
 *     `delegateOf(address)` for completeness.
 *   - The `_update` hook emits a `RecipientHasDelegatedCode` event whenever a
 *     transfer settles to an address with the 7702 prefix. The transfer
 *     succeeds either way; the event is purely advisory.
 *
 * The constant `RETIRED_PREDECESSOR` documents the v1 contract address on chain
 * so that any explorer, indexer, or auditor can resolve the migration history
 * by reading a single getter.
 */
contract KerneTokenV2 is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ERC20Permit, ERC20Votes {
    // ──────────────────────────────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Granted only to the Kerne 2-of-3 Safe. Used to halt transfers
    ///         in an emergency. Notably this contract has no minter, so the
    ///         pauser role is the only privileged operational surface.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ──────────────────────────────────────────────────────────────────────
    // Supply constant
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Permanent maximum supply: 1,000,000,000 KERNE. Minted once in
    ///         the constructor and never increased. There is no minter.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ──────────────────────────────────────────────────────────────────────
    // Migration metadata
    // ──────────────────────────────────────────────────────────────────────

    /// @notice On-chain pointer to the retired v1 contract for indexer and
    ///         explorer use. The v1 contract is retained on chain for
    ///         historical reasons but is not the canonical KERNE token.
    address public constant RETIRED_PREDECESSOR = 0xfEA3D217F5f2304C8551dc9F5B5169F2c2d87340;

    /// @notice On-chain pointer to the address of the legacy deployer EOA
    ///         whose EVM code was set to a drainer under EIP-7702. The
    ///         retired v1 supply is stranded on this address. Surfaced as a
    ///         constant so external observers can verify the migration story
    ///         from the contract itself, without trusting a docs link.
    address public constant TRAPPED_PREDECESSOR_HOLDER = 0x57D400cED462a01Ed51a5De038F204Df49690A99;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Emitted whenever a transfer settles to an address that has
    ///         EIP-7702 delegated code. Advisory only; the transfer succeeds.
    /// @param recipient    The address that just received tokens.
    /// @param delegate     The 20-byte delegate address encoded in the
    ///                     recipient's EIP-7702 code.
    event RecipientHasDelegatedCode(address indexed recipient, address indexed delegate);

    /// @notice Emitted once at deployment to record the migration context on
    ///         chain. Indexers can use this as the canonical "v1 retired,
    ///         v2 live at this address" event.
    /// @param retiredPredecessor          Address of the retired v1 KerneToken.
    /// @param trappedPredecessorHolder    Address of the EIP-7702-trapped v1 holder.
    /// @param canonicalAdmin              Address granted DEFAULT_ADMIN_ROLE on this contract.
    event KerneTokenV2Deployed(
        address indexed retiredPredecessor, address indexed trappedPredecessorHolder, address indexed canonicalAdmin
    );

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error ZeroAddress();

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @param defaultAdmin The address that receives DEFAULT_ADMIN_ROLE,
     *                     PAUSER_ROLE, and the full MAX_SUPPLY. This is
     *                     intended to be the Kerne 2-of-3 Safe at
     *                     0x52d3E450bA6c299B1B07298F1E87DD74732D4877. Passing
     *                     the Safe directly avoids a "deploy then transfer"
     *                     race window in which a third party could observe
     *                     the deploy and attempt to interact with the
     *                     deploy-time admin.
     */
    constructor(
        address defaultAdmin
    ) ERC20("Kerne", "KERNE") ERC20Permit("Kerne") {
        if (defaultAdmin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);

        // Mint the entire fixed supply once and only once, directly to the
        // default admin. No minter is configured. There is no path to
        // increase totalSupply after construction.
        _mint(defaultAdmin, MAX_SUPPLY);

        emit KerneTokenV2Deployed(RETIRED_PREDECESSOR, TRAPPED_PREDECESSOR_HOLDER, defaultAdmin);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Emergency controls
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Pauses all token transfers. Emergency use only.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses token transfers after an emergency is resolved.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Reflexive burn (BuyAndBurn integration parity with v1)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Burns tokens held by the caller to permanently reduce
     *         circulating supply.
     * @dev    Mirrors the v1 reflexiveBurn surface so the KerneBuyAndBurn
     *         contract can integrate with v2 without an interface change.
     *         ERC20Burnable.burn() is also available for direct burns.
     * @param amount The number of KERNE tokens (in wei) to burn from msg.sender.
     */
    function reflexiveBurn(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // EIP-7702 awareness helpers
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns true if `account` has EVM code that begins with the
     *         EIP-7702 magic prefix `0xef0100`. False for plain EOAs and for
     *         non-7702 contracts.
     * @dev    Reading is gas-bounded to a 23-byte tail; full 7702 code is
     *         exactly 23 bytes (3-byte prefix plus 20-byte delegate address).
     */
    function is7702Delegated(
        address account
    ) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        if (size != 23) return false;

        bytes memory code = new bytes(23);
        assembly {
            extcodecopy(account, add(code, 0x20), 0, 23)
        }
        return code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
    }

    /**
     * @notice Returns the delegate address embedded in `account`'s EIP-7702
     *         code, or the zero address if `account` is not 7702-delegated.
     */
    function delegateOf(
        address account
    ) external view returns (address delegate) {
        if (!is7702Delegated(account)) return address(0);

        bytes memory code = new bytes(23);
        assembly {
            extcodecopy(account, add(code, 0x20), 0, 23)
        }
        bytes20 raw;
        assembly {
            raw := mload(add(code, 0x23))
        }
        return address(raw);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Required overrides (Solidity multiple-inheritance resolution)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev    Resolves the diamond-inheritance _update across ERC20,
     *         ERC20Pausable, and ERC20Votes. Adds the EIP-7702 advisory event
     *         after the parent _update settles (so the event only fires on
     *         transfers that actually succeeded, including unpause-bypassing
     *         mints and burns to the zero address which never trigger the
     *         advisory).
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable, ERC20Votes) {
        super._update(from, to, value);

        // Fire the advisory event only on real transfers to non-zero
        // recipients, so mints (from = 0) and burns (to = 0) do not spam
        // the indexer. Mints can still fire the event because the recipient
        // is non-zero, which is intentional: a mint-time delegate detection
        // is just as useful as a transfer-time one.
        if (to != address(0) && is7702Delegated(to)) {
            emit RecipientHasDelegatedCode(to, _delegateOfUnchecked(to));
        }
    }

    /// @dev Internal variant of delegateOf that skips the prefix re-check.
    ///      Only callable from _update where is7702Delegated(to) was just
    ///      verified; saves an extcodesize call on the cold path.
    function _delegateOfUnchecked(
        address account
    ) private view returns (address) {
        bytes memory code = new bytes(23);
        assembly {
            extcodecopy(account, add(code, 0x20), 0, 23)
        }
        bytes20 raw;
        assembly {
            raw := mload(add(code, 0x23))
        }
        return address(raw);
    }

    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
