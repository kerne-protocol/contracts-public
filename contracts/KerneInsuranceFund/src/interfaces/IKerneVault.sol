// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IKerneVault
 * @notice Interface for KerneVault - the delta-neutral yield vault
 */
interface IKerneVault {
    // ERC-20 functions
    function totalSupply() external view returns (uint256);
    function balanceOf(
        address account
    ) external view returns (uint256);
    function transfer(
        address to,
        uint256 amount
    ) external returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    // ERC-4626 functions
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(
        uint256 assets
    ) external view returns (uint256);
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);
    function maxDeposit(
        address receiver
    ) external view returns (uint256);
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256);
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);
    function maxMint(
        address receiver
    ) external view returns (uint256);
    function previewMint(
        uint256 shares
    ) external view returns (uint256);
    function mint(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);
    function maxWithdraw(
        address owner
    ) external view returns (uint256);
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256);
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);
    function maxRedeem(
        address owner
    ) external view returns (uint256);
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    // Kerne-specific functions
    function getSolvencyRatio() external view returns (uint256);
    function offChainAssets() external view returns (uint256);
    function hedgingReserve() external view returns (uint256);
    function trustAnchor() external view returns (address);
    function verificationNode() external view returns (address);

    // Admin functions
    function updateOffChainAssets(
        uint256 amount
    ) external;
    function pause() external;
}
