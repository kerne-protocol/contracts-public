// Created: 2026-01-21
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title kUSD
 * @author Kerne Protocol
 * @notice The Kerne Synthetic Dollar (kUSD) is a delta-neutral yield-bearing stablecoin.
 *         It is minted against KerneVault shares (kLP) and represents a claim on the
 *         vault's delta-neutral collateral backed by LST staking yield + perpetual funding rates.
 * @dev kUSD is intentionally a thin ERC-20 with a minter access-control gate and EIP-2612 permit
 *      support. The complexity of the yield mechanism lives in KerneVault; kUSD stays lean to
 *      minimize attack surface and remain easily auditable. Burn is permissionless (any holder
 *      can burn their own tokens) — only minting is gated behind MINTER_ROLE.
 */
contract kUSD is ERC20, ERC20Permit, ERC20Burnable, AccessControl {
    /// @notice Role identifier for addresses authorized to mint new kUSD.
    /// @dev Granted to KerneVault (or a dedicated minting controller) during deployment.
    ///      Holders of this role can create kUSD from thin air, so it must be guarded with
    ///      the same diligence as DEFAULT_ADMIN_ROLE. Revoke immediately if the minter is compromised.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Deploys the kUSD token and grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to `defaultAdmin`.
    /// @dev The deployer is expected to be the Kerne protocol multisig or a trusted deployment script.
    ///      After deployment, transfer DEFAULT_ADMIN_ROLE to the multisig and grant MINTER_ROLE
    ///      only to trusted vault contracts. EIP-2612 permit domain is "Kerne Synthetic Dollar".
    /// @param defaultAdmin The address that receives DEFAULT_ADMIN_ROLE and the initial MINTER_ROLE.
    constructor(
        address defaultAdmin
    ) ERC20("Kerne Synthetic Dollar", "kUSD") ERC20Permit("Kerne Synthetic Dollar") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
    }

    /**
     * @notice Mints kUSD to a specific address.
     * @dev Only callable by addresses with MINTER_ROLE (i.e., authorized KerneVault contracts).
     *      This is the sole inflationary entry point for kUSD supply. The vault is responsible
     *      for ensuring that minted kUSD is fully backed by delta-neutral collateral before calling.
     *      Reverts via OpenZeppelin AccessControl if the caller lacks MINTER_ROLE.
     * @param to The address to receive the minted kUSD.
     * @param amount The amount of kUSD to mint (18 decimals).
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
