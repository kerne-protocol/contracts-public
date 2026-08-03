// Created: 2026-03-02
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// =============================================================================
// IKerneOracleRouter — Interface for the Kerne Dual-Feed Oracle Router
// =============================================================================
// Any contract that needs live asset pricing (KernePrime, kUSDMinter, etc.)
// should depend on this interface rather than the concrete implementation.
// This allows the router to be upgraded or swapped without touching consumers.
// =============================================================================

interface IKerneOracleRouter {
    // -------------------------------------------------------------------------
    // Emitted when a new asset feed configuration is registered or updated.
    // -------------------------------------------------------------------------
    event FeedConfigured(address indexed asset, bytes32 pythFeedId, address chainlinkFeed, uint8 assetDecimals);

    // -------------------------------------------------------------------------
    // Emitted when the router falls back from Pyth to Chainlink due to
    // staleness or deviation exceeding the tolerance threshold.
    // -------------------------------------------------------------------------
    event FallbackToChainlink(address indexed asset, string reason);

    // -------------------------------------------------------------------------
    // Emitted when both feeds deviate beyond the circuit-breaker threshold.
    // This is a critical warning — downstream consumers should halt operations.
    // -------------------------------------------------------------------------
    event OracleCircuitBreakerTriggered(address indexed asset, uint256 pythPrice, uint256 chainlinkPrice);

    // =========================================================================
    // CORE PRICE FUNCTIONS
    // =========================================================================

    // -------------------------------------------------------------------------
    // getPrice
    // Returns the canonical USD price of `asset` in 18-decimal precision.
    // Internally: queries Pyth first, validates against Chainlink heartbeat.
    // If Pyth is stale or deviates beyond tolerance, falls back to Chainlink.
    // If both are deformed beyond the circuit-breaker threshold, reverts.
    // @param asset  The ERC-20 token address to price.
    // @return price  USD price with 18 decimals (e.g., 1e18 = $1.00).
    // -------------------------------------------------------------------------
    function getPrice(
        address asset
    ) external view returns (uint256 price);

    // -------------------------------------------------------------------------
    // getPriceWithConfidence
    // Returns the Pyth price along with its confidence interval.
    // Useful for volatility-adjusted LTV calculations in kUSDMinter.
    // @param asset  The ERC-20 token address to price.
    // @return price       USD price with 18 decimals.
    // @return confidence  Confidence interval (±) in 18 decimals.
    // -------------------------------------------------------------------------
    function getPriceWithConfidence(
        address asset
    ) external view returns (uint256 price, uint256 confidence);

    // -------------------------------------------------------------------------
    // getValueUSD
    // Convenience function: returns the USD value of `amount` of `asset`.
    // Handles decimal normalization between the asset's native decimals and 18.
    // @param asset   The ERC-20 token address.
    // @param amount  The raw token amount (in the asset's native decimals).
    // @return valueUSD  USD value in 18-decimal precision.
    // -------------------------------------------------------------------------
    function getValueUSD(
        address asset,
        uint256 amount
    ) external view returns (uint256 valueUSD);

    // =========================================================================
    // RISK PARAMETER FUNCTIONS
    // =========================================================================

    // -------------------------------------------------------------------------
    // getVolatilityAdjustedLTV
    // Returns the maximum LTV ratio for `asset`, adjusted for current volatility.
    // Base LTV is reduced proportionally when Pyth confidence interval is wide,
    // preventing under-collateralization during high-volatility events.
    // @param asset  The ERC-20 token address.
    // @return ltvBps  LTV in basis points (e.g., 8000 = 80%).
    // -------------------------------------------------------------------------
    function getVolatilityAdjustedLTV(
        address asset
    ) external view returns (uint256 ltvBps);

    // -------------------------------------------------------------------------
    // getLiquidationThreshold
    // Returns the liquidation threshold for `asset` in basis points.
    // This is the collateral ratio below which a position becomes liquidatable.
    // @param asset  The ERC-20 token address.
    // @return thresholdBps  Threshold in basis points (e.g., 12000 = 120%).
    // -------------------------------------------------------------------------
    function getLiquidationThreshold(
        address asset
    ) external view returns (uint256 thresholdBps);

    // =========================================================================
    // FEED MANAGEMENT (admin only in implementation)
    // =========================================================================

    // -------------------------------------------------------------------------
    // configureFeed
    // Registers or updates the oracle feeds for a given asset.
    // @param asset           ERC-20 token address.
    // @param pythFeedId      32-byte Pyth price feed ID.
    // @param chainlinkFeed   Chainlink AggregatorV3 address.
    // @param assetDecimals   Native decimals of the asset (e.g., 6 for USDC).
    // @param baseLtvBps      Base LTV in basis points before volatility adjustment.
    // @param liquidationBps  Liquidation threshold in basis points.
    // -------------------------------------------------------------------------
    function configureFeed(
        address asset,
        bytes32 pythFeedId,
        address chainlinkFeed,
        uint8 assetDecimals,
        uint256 baseLtvBps,
        uint256 liquidationBps
    ) external;

    // -------------------------------------------------------------------------
    // isFeedConfigured
    // Returns true if the asset has a registered oracle feed.
    // -------------------------------------------------------------------------
    function isFeedConfigured(
        address asset
    ) external view returns (bool);
}
