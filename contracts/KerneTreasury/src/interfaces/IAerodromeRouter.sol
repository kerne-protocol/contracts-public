// Created: 2026-01-14
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAerodromeRouter
 * @notice Interface for Aerodrome DEX Router on Base
 * @dev Aerodrome is the primary DEX on Base, forked from Velodrome on Optimism
 *      Uses stable/volatile pool differentiation for optimal routing
 */
interface IAerodromeRouter {
    /// @notice Route struct for multi-hop swaps
    struct Route {
        address from; // Token to swap from
        address to; // Token to swap to
        bool stable; // True for stable pools, false for volatile
        address factory; // Factory address (can be address(0) for default)
    }

    /// @notice Returns the address of the default factory
    function defaultFactory() external view returns (address);

    /// @notice Returns WETH address
    function weth() external view returns (address);

    /// @notice Sort tokens to determine pool address
    function sortTokens(
        address tokenA,
        address tokenB
    ) external pure returns (address token0, address token1);

    /// @notice Calculate pool address for a pair
    function poolFor(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory
    ) external view returns (address pool);

    /// @notice Get reserves for a pair
    function getReserves(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory
    ) external view returns (uint256 reserveA, uint256 reserveB);

    /// @notice Calculate output amount for a given input
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amount, bool stable);

    /// @notice Get amounts out for a route
    function getAmountsOut(
        uint256 amountIn,
        Route[] calldata routes
    ) external view returns (uint256[] memory amounts);

    /// @notice Swap exact tokens for tokens
    /// @param amountIn Amount of input token to swap
    /// @param amountOutMin Minimum amount of output token to receive (slippage protection)
    /// @param routes Array of routes to take
    /// @param to Address to receive output tokens
    /// @param deadline Unix timestamp deadline for the swap
    /// @return amounts Array of amounts at each step
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swap exact ETH for tokens
    function swapExactETHForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Swap exact tokens for ETH
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Add liquidity to a pool
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Remove liquidity from a pool
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice Quote liquidity given amount of tokenA
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Quote removal liquidity
    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB);
}
