// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// KRN-26-TREASURY-BUYBACK-TWAP
//
// Reported by:  Dmitriy Filatov, 2026-07-14, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Disclosure:   audits/DEPLOYED_VS_SOURCE.md, section "Added 2026-07-29: the
//               buyback floor is now fixed in source and not on chain"
// Status:       Accepted. Fixed in source, NOT on the deployed bytecode this
//               bundle mirrors. Unreachable on the live system: the treasury
//               holds no buyback inventory, no buyback keeper is granted, and
//               no KERNE venue deep enough to sandwich exists, so
//               `previewBuyback` returns zero and `executeBuyback` reverts
//               before any swap. That unreachability is what makes it publishable.
//
// The researcher's original proof of concept was an ethereumjs harness that put
// the loss at roughly 30 percent of buyback value. The acknowledgments wall has
// said since 2026-07-14 that it "is being folded into the buyback regression
// suite". This file is that promise kept, rewritten against the mirrored source
// so it runs from a clean `git clone` with no fork and no API key.
//
// The finding in one line: the slippage floor is not weak, it is INERT. It is
// derived from a quote read against the same pool the swap executes on, inside
// the same transaction, so it moves by exactly the factor an attacker moves the
// pool by and therefore clears at every manipulation size.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { KerneTreasury } from "../../contracts/KerneTreasury/src/KerneTreasury.sol";
import { MockERC20, MockAerodromeRouter } from "../helpers/Mocks.sol";

contract TreasuryBuybackFloorTest is Test {
    KerneTreasury internal treasury;
    MockERC20 internal usdc;
    MockERC20 internal kerne;
    MockAerodromeRouter internal router;

    address internal staking = makeAddr("stakingContract");

    uint256 internal constant FEES = 1_000e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        kerne = new MockERC20("Kerne", "KERNE", 18);
        router = new MockAerodromeRouter();

        treasury = new KerneTreasury(address(kerne), staking, address(router));
        treasury.setApprovedBuybackToken(address(usdc), true);

        // Fee revenue has accumulated in the treasury, ready to be bought back.
        usdc.mint(address(treasury), FEES);
    }

    /// @notice The honest baseline: at an unmanipulated pool the 2% floor is what
    ///         it claims to be. This is the control the next test is measured against.
    function test_floorHoldsAtAnUnmanipulatedPool() public view {
        (uint256 expected, uint256 minOut) = treasury.previewBuyback(address(usdc), FEES);

        assertEq(expected, FEES, "1:1 pool should quote 1:1");
        assertEq(minOut, (FEES * 9800) / 10_000, "floor should sit 2% under the quote");
        assertEq(treasury.slippageBps(), 200, "default slippage tolerance is 2%");
    }

    /// @notice THE FINDING. Move the pool 90% against the treasury and the buyback
    ///         still executes, because the floor is recomputed from the moved pool.
    ///         A floor that adapts to the manipulation is not a floor.
    function test_KNOWN_sameBlockQuoteMakesTheSlippageFloorInert() public {
        // What the treasury would have received at an honest price.
        (uint256 honestQuote,) = treasury.previewBuyback(address(usdc), FEES);
        assertEq(honestQuote, FEES);

        // The attacker moves the pool inside the same block, ahead of the buyback.
        // 1000 bps = the treasury now receives a tenth of what it should.
        router.setRate(1_000);

        treasury.executeBuyback(address(usdc), FEES);

        uint256 received = kerne.balanceOf(staking);

        // No revert. SlippageExceeded never fired. The treasury paid 1000 USDC of
        // real fee revenue for 100 KERNE.
        assertEq(received, honestQuote / 10, "attacker captured 90% of the buyback");

        // State the loss the way the disclosure states it, so a reader does not have
        // to do the arithmetic: the executed price was 90% worse than the honest one
        // and the guard that exists to stop exactly this did not fire.
        uint256 lossBps = ((honestQuote - received) * 10_000) / honestQuote;
        assertEq(lossBps, 9_000, "90% loss cleared a 2% slippage guard");
    }

    /// @notice The mechanism, isolated: `previewBuyback` is a live pool read, so the
    ///         floor is a function of the manipulated state, not of any independent
    ///         price. This is the precise reason the guard cannot bind.
    function test_KNOWN_theFloorIsDerivedFromTheManipulatedPool() public {
        (, uint256 floorBefore) = treasury.previewBuyback(address(usdc), FEES);

        router.setRate(1_000);
        (, uint256 floorAfter) = treasury.previewBuyback(address(usdc), FEES);

        assertEq(floorAfter, floorBefore / 10, "the floor moved with the pool, by the same factor");
    }

    /// @notice Why this is disclosed rather than embargoed: on the live system the
    ///         path is not reachable. With no liquidity the preview returns zero and
    ///         the function reverts before approving or swapping anything. This is
    ///         the state the live treasury is in today.
    function test_unreachableWithoutLiquidity() public {
        router.setDry(true);

        (uint256 expected, uint256 minOut) = treasury.previewBuyback(address(usdc), FEES);
        assertEq(expected, 0, "no liquidity previews as zero");
        assertEq(minOut, 0);

        vm.expectRevert(KerneTreasury.NoLiquidityForBuyback.selector);
        treasury.executeBuyback(address(usdc), FEES);
    }

    /// @notice The shape of the fix, asserted as an absence so this test starts
    ///         failing the day the remediated treasury replaces this bundle.
    /// @dev Current source requires the CALLER to supply an output floor drawn from
    ///      a price the caller cannot move in the execution block, and rejects a zero
    ///      floor outright with `CallerFloorRequired()`. The deployed bytecode this
    ///      bundle mirrors takes no floor argument at all: `executeBuyback` is
    ///      (address,uint256). When the v4 redeploy lands, the mirror updates and this
    ///      assertion is the tripwire that says so.
    function test_deployedSourceTakesNoCallerSuppliedFloor() public pure {
        assertEq(
            KerneTreasury.executeBuyback.selector,
            bytes4(keccak256("executeBuyback(address,uint256)")),
            "deployed executeBuyback takes no caller floor; the fix adds one"
        );
    }
}
