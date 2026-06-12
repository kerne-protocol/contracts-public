// Created: 2026-02-27
// Updated: 2026-03-19 - Gas optimization: Migrated all require() strings to custom errors
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAerodromeRouter } from "./interfaces/IAerodromeRouter.sol";

/**
 * @title KerneTreasury
 * @author Kerne Protocol
 * @notice Protocol treasury that accumulates fee revenue and executes KERNE buybacks via Aerodrome.
 *         This is the terminal destination for all protocol performance fees — it converts them
 *         into KERNE buy pressure, feeding the BribeVortex flywheel and the staking rewards pool.
 *
 * @dev FLOW:
 *      1. Protocol fees (USDC, WETH, etc.) accumulate in this contract.
 *      2. The buyback bot (or anyone) calls `executeBuyback()` to swap fees for KERNE.
 *      3. Purchased KERNE is distributed to the staking contract as rewards.
 *
 *      This creates a self-reinforcing loop: more TVL → more fees → more KERNE buybacks
 *      → higher KERNE price → more attractive staking APY → more TVL.
 */
contract KerneTreasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                        STATE
    // ============================================================

    /// @notice The KERNE governance token — the target of all buybacks.
    address public kerneToken;

    /// @notice The staking contract — receives purchased KERNE as rewards.
    address public stakingContract;

    /// @notice The Aerodrome router — executes all KERNE buyback swaps.
    IAerodromeRouter public aerodromeRouter;

    /// @notice Slippage tolerance for buyback swaps in basis points (default: 200 = 2%).
    ///         Protects against sandwich attacks while allowing reasonable price impact.
    uint256 public slippageBps = 200;

    /// @notice Tokens approved for use in KERNE buybacks (e.g. USDC, WETH).
    mapping(address => bool) public approvedBuybackTokens;

    /// @notice Optional routing hops for multi-hop swaps (e.g. USDC → WETH → KERNE).
    ///         If set for a token, the buyback routes through this intermediate token.
    mapping(address => address) public routingHops;

    // ============================================================
    //                        EVENTS
    // ============================================================

    /// @notice Emitted when a KERNE buyback swap is executed successfully.
    event BuybackExecuted(address indexed token, uint256 amountIn, uint256 kerneOut);

    /// @notice Emitted when purchased KERNE is distributed to the staking contract as rewards.
    event KerneDistributed(address indexed staking, uint256 amount);

    /// @notice Emitted when a token is approved or revoked for use in KERNE buybacks.
    event BuybackTokenApproved(address indexed token, bool approved);

    /// @notice Emitted when a routing hop is configured for a fee token (multi-hop swap path).
    event RoutingHopSet(address indexed token, address indexed hop);

    /// @notice Emitted when the buyback slippage tolerance is updated.
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the KERNE token address is updated (rare migration event).
    event KerneTokenUpdated(address indexed oldToken, address indexed newToken);

    /// @notice Emitted when the staking contract address is updated.
    event StakingContractUpdated(address indexed oldStaking, address indexed newStaking);

    /// @notice Emitted when fee tokens are received from protocol components.
    event FeeReceived(address indexed token, uint256 amount, address indexed from);

    // ============================================================
    //                CUSTOM ERRORS
    // ============================================================
    // Gas optimization: Custom errors save ~50-100 gas per revert vs require() strings.
    // ============================================================

    /// @dev Thrown when a zero address is provided where a valid address is required.
    error ZeroAddress();

    /// @dev Thrown when an amount is zero but must be positive.
    error ZeroAmount();

    /// @dev Thrown when a token is not approved for buyback operations.
    error TokenNotApprovedForBuyback();

    /// @dev Thrown when the treasury lacks sufficient token balance for an operation.
    error InsufficientBalance();

    /// @dev Thrown when the KERNE token address has not been configured.
    error KerneTokenNotSet();

    /// @dev Thrown when the staking contract address has not been configured.
    error StakingContractNotSet();

    /// @dev Thrown when a buyback preview returns zero (no liquidity available).
    error NoLiquidityForBuyback();

    /// @dev Thrown when actual swap output is less than the minimum acceptable (slippage protection).
    error SlippageExceeded();

    /// @dev Thrown when the slippage tolerance exceeds the maximum allowed (10%).
    error SlippageTooHigh();

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    /**
     * @param _kerneToken The KERNE token address.
     * @param _stakingContract The staking contract that receives purchased KERNE.
     * @param _aerodromeRouter The Aerodrome router for executing swaps.
     */
    constructor(
        address _kerneToken,
        address _stakingContract,
        address _aerodromeRouter
    ) Ownable(msg.sender) {
        if (_aerodromeRouter == address(0)) revert ZeroAddress();
        kerneToken = _kerneToken;
        stakingContract = _stakingContract;
        aerodromeRouter = IAerodromeRouter(_aerodromeRouter);
    }

    // ============================================================
    //                     FEE RECEPTION
    // ============================================================

    /**
     * @notice Accepts incoming fee tokens from protocol components.
     * @dev Any approved token can be sent here. The treasury accumulates them
     *      until a buyback cycle is triggered.
     * @param token The fee token being deposited.
     * @param amount The amount of fee tokens.
     */
    function receiveFees(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FeeReceived(token, amount, msg.sender);
    }

    // ============================================================
    //                     BUYBACK EXECUTION
    // ============================================================

    /**
     * @notice Executes a KERNE buyback using accumulated fee tokens.
     * @dev Swaps `amount` of `token` for KERNE via Aerodrome, then distributes
     *      the purchased KERNE to the staking contract as rewards.
     *
     *      If a routing hop is set for `token`, the swap routes through it:
     *      e.g. USDC → WETH → KERNE (better liquidity than direct USDC/KERNE).
     *
     * @param token The fee token to sell for KERNE.
     * @param amount The amount of fee tokens to use in this buyback.
     */
    function executeBuyback(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (!approvedBuybackTokens[token]) revert TokenNotApprovedForBuyback();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();
        if (kerneToken == address(0)) revert KerneTokenNotSet();
        if (stakingContract == address(0)) revert StakingContractNotSet();

        // Preview the expected output to calculate minimum acceptable output
        (uint256 expectedOut,) = previewBuyback(token, amount);
        if (expectedOut == 0) revert NoLiquidityForBuyback();

        // Apply slippage tolerance to get minimum acceptable KERNE output
        uint256 minOut = (expectedOut * (10000 - slippageBps)) / 10000;

        // Approve the router to spend the fee tokens. forceApprove (set to 0
        // then to amount) avoids USDT-class non-zero-to-non-zero revert AND
        // prevents allowance leakage if a misbehaving router consumed less
        // than `amount` and the residual remained approved across calls.
        IERC20(token).forceApprove(address(aerodromeRouter), amount);

        uint256 kerneBalanceBefore = IERC20(kerneToken).balanceOf(address(this));

        // Build the swap route — direct or via routing hop
        address hop = routingHops[token];
        if (hop != address(0) && hop != kerneToken) {
            // Multi-hop: token → hop → KERNE (e.g. USDC → WETH → KERNE)
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](2);
            routes[0] = IAerodromeRouter.Route({
                from: token,
                to: hop,
                stable: false,
                factory: address(0) // Use default factory
            });
            routes[1] = IAerodromeRouter.Route({ from: hop, to: kerneToken, stable: false, factory: address(0) });
            aerodromeRouter.swapExactTokensForTokens(amount, minOut, routes, address(this), block.timestamp + 300);
        } else {
            // Direct: token → KERNE
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
            routes[0] = IAerodromeRouter.Route({ from: token, to: kerneToken, stable: false, factory: address(0) });
            aerodromeRouter.swapExactTokensForTokens(amount, minOut, routes, address(this), block.timestamp + 300);
        }

        uint256 kerneReceived = IERC20(kerneToken).balanceOf(address(this)) - kerneBalanceBefore;
        if (kerneReceived < minOut) revert SlippageExceeded();

        // Reset router allowance to 0 so a misbehaving router that only
        // consumed part of the approval cannot retain residual permission
        // to pull the remainder on a later block.
        IERC20(token).forceApprove(address(aerodromeRouter), 0);

        emit BuybackExecuted(token, amount, kerneReceived);

        // Distribute purchased KERNE to the staking contract as rewards
        _distributeToStaking(kerneReceived);
    }

    /**
     * @notice Previews the expected KERNE output for a given buyback.
     * @param token The fee token to sell.
     * @param amount The amount of fee tokens.
     * @return expected The expected KERNE output.
     * @return minOut The minimum acceptable output after slippage.
     */
    function previewBuyback(
        address token,
        uint256 amount
    ) public view returns (uint256 expected, uint256 minOut) {
        if (!approvedBuybackTokens[token] || kerneToken == address(0)) {
            return (0, 0);
        }

        address hop = routingHops[token];

        try this._previewSwap(token, hop, amount) returns (uint256 out) {
            expected = out;
            minOut = (expected * (10000 - slippageBps)) / 10000;
        } catch {
            expected = 0;
            minOut = 0;
        }
    }

    /**
     * @notice Internal preview helper — external so it can be called with try/catch.
     */
    function _previewSwap(
        address token,
        address hop,
        uint256 amount
    ) external view returns (uint256) {
        if (hop != address(0) && hop != kerneToken) {
            // Multi-hop preview
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](2);
            routes[0] = IAerodromeRouter.Route({ from: token, to: hop, stable: false, factory: address(0) });
            routes[1] = IAerodromeRouter.Route({ from: hop, to: kerneToken, stable: false, factory: address(0) });
            uint256[] memory amounts = aerodromeRouter.getAmountsOut(amount, routes);
            return amounts[amounts.length - 1];
        } else {
            // Direct preview
            IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
            routes[0] = IAerodromeRouter.Route({ from: token, to: kerneToken, stable: false, factory: address(0) });
            uint256[] memory amounts = aerodromeRouter.getAmountsOut(amount, routes);
            return amounts[amounts.length - 1];
        }
    }

    /**
     * @notice Distributes KERNE to the staking contract as rewards.
     * @dev Transfers KERNE to the staking contract. The staking contract is expected
     *      to handle the reward distribution internally (e.g. via `notifyRewardAmount`).
     */
    function _distributeToStaking(
        uint256 amount
    ) internal {
        if (amount == 0 || stakingContract == address(0)) return;

        IERC20(kerneToken).safeTransfer(stakingContract, amount);
        emit KerneDistributed(stakingContract, amount);
    }

    // ============================================================
    //                     ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Approves or revokes a token for use in KERNE buybacks.
     * @param token The token address.
     * @param approved Whether to approve or revoke.
     */
    function setApprovedBuybackToken(
        address token,
        bool approved
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        approvedBuybackTokens[token] = approved;
        emit BuybackTokenApproved(token, approved);
    }

    /**
     * @notice Sets a routing hop for multi-hop buyback swaps.
     * @dev Use this when there's no direct liquidity between `token` and KERNE.
     *      e.g. setRoutingHop(USDC, WETH) routes USDC → WETH → KERNE.
     * @param token The input fee token.
     * @param hop The intermediate token to route through.
     */
    function setRoutingHop(
        address token,
        address hop
    ) external onlyOwner {
        routingHops[token] = hop;
        emit RoutingHopSet(token, hop);
    }

    /**
     * @notice Updates the slippage tolerance for buyback swaps.
     * @param _slippageBps New slippage in basis points (max 1000 = 10%).
     */
    function setSlippage(
        uint256 _slippageBps
    ) external onlyOwner {
        if (_slippageBps > 1000) revert SlippageTooHigh();
        uint256 old = slippageBps;
        slippageBps = _slippageBps;
        emit SlippageUpdated(old, _slippageBps);
    }

    /**
     * @notice Updates the KERNE token address.
     * @dev Only callable by owner. Rare operation — only needed if KERNE token migrates to a new contract.
     *      All subsequent buybacks will target the new token address. Ensure the new token has
     *      sufficient Aerodrome liquidity before updating, or existing buyback calls will fail.
     * @param _kerneToken The new KERNE token contract address.
     */
    function updateKerneToken(
        address _kerneToken
    ) external onlyOwner {
        if (_kerneToken == address(0)) revert ZeroAddress();
        address old = kerneToken;
        kerneToken = _kerneToken;
        emit KerneTokenUpdated(old, _kerneToken);
    }

    /**
     * @notice Updates the Aerodrome router address used for buyback swaps.
     * @dev Only callable by owner. Only needed if Aerodrome deploys a new router version.
     *      After updating, verify that the new router supports the same route format before
     *      triggering any buyback calls to avoid failed swaps.
     * @param _router The new Aerodrome router contract address.
     */
    function setRouter(
        address _router
    ) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        aerodromeRouter = IAerodromeRouter(_router);
    }

    /**
     * @notice Updates the staking contract that receives purchased KERNE rewards.
     * @dev Only callable by owner. The new staking contract must be able to handle
     *      incoming KERNE transfers as reward distributions. Coordinate with the staking
     *      contract team before changing this address to avoid disrupting reward flows.
     * @param _stakingContract The new staking contract address.
     */
    function setStakingContract(
        address _stakingContract
    ) external onlyOwner {
        if (_stakingContract == address(0)) revert ZeroAddress();
        address old = stakingContract;
        stakingContract = _stakingContract;
        emit StakingContractUpdated(old, _stakingContract);
    }

    /**
     * @notice Emergency withdrawal of any token held in the treasury to a recipient address.
     * @dev Only callable by owner (Kerne multisig). Use for emergency recovery of mis-sent tokens
     *      or urgent rebalancing. This bypasses the normal buyback flow — use with care.
     *      No event is emitted intentionally; on-chain tx calldata provides the audit trail.
     * @param token The ERC-20 token to withdraw from the treasury.
     * @param amount The amount of tokens to withdraw.
     * @param recipient The address to send the tokens to (must be non-zero).
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @notice Allows the treasury to receive ETH directly (e.g. from WETH unwrapping or direct ETH fees).
    /// @dev ETH received here is not automatically converted — the owner must manually handle it.
    receive() external payable { }

    /**
     * @notice Sweeps native ETH out of the treasury to a recipient.
     * @dev SECURITY (audit 2026-05-11): without this, ETH sent to the treasury
     *      via `receive()`, selfdestruct injection, or a misrouted refund had
     *      no exit path — `emergencyWithdraw` only handles ERC-20 tokens. ETH
     *      could accumulate indefinitely with no way to recover. Owner-only;
     *      recipient must be non-zero. Uses `.call` (not `.transfer`) to
     *      support smart-wallet recipients like Safe.
     * @param recipient The address to receive the ETH.
     * @param amount The amount of ETH (wei) to sweep.
     */
    function sweepETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert("KerneTreasury: ETH sweep failed");
    }
}
