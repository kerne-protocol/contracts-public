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
 * @dev kUSD is intentionally a thin ERC-20 with role-gated mint and pull-burn, plus EIP-2612
 *      permit support. The complexity of the yield mechanism lives in KerneVault; kUSD stays
 *      lean to minimize attack surface and remain easily auditable.
 *
 *      Self-burn (`burn(uint256)`) remains permissionless — any holder can destroy their own
 *      tokens. Pull-burn (`burnFrom(address, uint256)`) is gated behind `BURNER_ROLE`.
 *      Without this gate, any contract a user has approved (e.g., a DEX router with a standing
 *      ERC-20 allowance) could permissionlessly destroy that user's kUSD via `burnFrom` —
 *      turning every approval into an indirect burn primitive. With it, only protocol contracts
 *      explicitly granted `BURNER_ROLE` (kUSDMinter for closeLeveragedPosition / liquidate,
 *      KernePrime for repay / liquidate) can pull-burn.
 */
contract kUSD is ERC20, ERC20Permit, ERC20Burnable, AccessControl {
    /// @notice Role identifier for addresses authorized to mint new kUSD.
    /// @dev Granted to KerneVault (or a dedicated minting controller) during deployment.
    ///      Holders of this role can create kUSD from thin air, so it must be guarded with
    ///      the same diligence as DEFAULT_ADMIN_ROLE. Revoke immediately if the minter is compromised.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for addresses authorized to pull-burn (burnFrom) kUSD.
    /// @dev Granted to protocol contracts that need to consume user allowances and burn
    ///      tokens — kUSDMinter for closeLeveragedPosition/liquidate flows, KernePrime
    ///      for repay/liquidate. NOT granted to PSM (PSM holds kUSD in inventory rather
    ///      than burning it on swap-in). NOT granted to KerneVault (vault mints, never burns).
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @dev Reverts when burnFrom is called by an address without BURNER_ROLE.
    error UnauthorizedBurner();

    /// @notice Deploys the kUSD token and grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to `defaultAdmin`.
    /// @dev The deployer is expected to be the Kerne protocol multisig or a trusted deployment script.
    ///      After deployment, transfer DEFAULT_ADMIN_ROLE to the multisig and grant MINTER_ROLE /
    ///      BURNER_ROLE only to trusted vault / minter / Prime contracts. EIP-2612 permit domain
    ///      is "Kerne Synthetic Dollar".
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
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Burns `amount` from `account`, deducting from the caller's allowance.
     * @dev SECURITY (audit 2026-05-11): pull-burn is gated by BURNER_ROLE. ERC20Burnable's
     *      default `burnFrom` is permissionless — any contract a user has approved (e.g., a
     *      DEX, an aggregator, an EOA the user typed by mistake) can destroy that user's kUSD
     *      by calling `burnFrom(user, allowance)`. We override to require BURNER_ROLE so only
     *      protocol contracts that legitimately consume allowances on the user's behalf
     *      (kUSDMinter, KernePrime) can pull-burn. Self-burn via `burn(uint256)` is unaffected.
     * @param account The address to burn from. Must have approved msg.sender for at least `amount`.
     * @param amount The amount to burn.
     */
    function burnFrom(
        address account,
        uint256 amount
    ) public override {
        if (!hasRole(BURNER_ROLE, msg.sender)) revert UnauthorizedBurner();
        super.burnFrom(account, amount);
    }
}
