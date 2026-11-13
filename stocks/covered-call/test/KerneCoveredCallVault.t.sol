// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KerneCoveredCallVault, IAggregatorV3} from "../src/KerneCoveredCallVault.sol";
import {MockStock, MockFeed} from "./Mocks.sol";

contract KerneCoveredCallVaultTest is Test {
    MockStock stock;
    MockFeed feed;
    KerneCoveredCallVault vault;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    uint256 constant ONE = 1e8; // one TSLAc
    int256 constant SPOT = 400e8; // $400

    function setUp() public {
        vm.warp(1_800_000_000);
        stock = new MockStock();
        feed = new MockFeed();
        feed.push(SPOT, block.timestamp);
        vault = new KerneCoveredCallVault(
            IERC20(address(stock)), IAggregatorV3(address(feed)), "Kerne Covered Call TSLAc", "kccTSLAc", owner, keeper
        );
        vm.prank(owner);
        vault.setParams(1_000 * ONE, 25 hours, 300, 10, 1 days, 35 days, 7 days, 12 hours);

        address[4] memory users = [alice, bob, buyer, buyer2];
        for (uint256 i; i < users.length; i++) {
            stock.mint(users[i], 100 * ONE);
            vm.prank(users[i]);
            stock.approve(address(vault), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amt, who);
    }

    function _open(uint256 strike, uint256 premiumBps) internal returns (uint256 id) {
        vm.prank(keeper);
        id = vault.openEpoch(strike, premiumBps, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function _buy(address who, uint256 notional) internal returns (uint256 p) {
        vm.prank(who);
        p = vault.buyCall(notional, type(uint256).max);
    }

    /// pushes a round before expiry and one after; returns the round id to settle with
    function _priceAtExpiry(int256 price) internal returns (uint80 id) {
        (,, uint64 expiry,,,,,,,) = vault.epochs(vault.currentEpoch());
        feed.push(SPOT, expiry - 1);
        vm.warp(expiry + 10);
        id = feed.push(price, expiry + 5);
    }

    // ---------------------------------------------------------------- deposits

    function test_depositClosedUntilCapSet() public {
        vm.prank(owner);
        vault.setParams(0, 25 hours, 300, 10, 1 days, 35 days, 7 days, 12 hours);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(ONE, alice);
    }

    function test_depositCapEnforced() public {
        vm.prank(owner);
        vault.setParams(5 * ONE, 25 hours, 300, 10, 1 days, 35 days, 7 days, 12 hours);
        _deposit(alice, 5 * ONE);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1, bob);
    }

    function test_depositWithdrawRoundTrip() public {
        uint256 s = _deposit(alice, 10 * ONE);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertEq(out, 10 * ONE);
        assertEq(stock.balanceOf(alice), 100 * ONE);
    }

    function test_flowsFrozenDuringEpoch() public {
        uint256 s = _deposit(alice, 10 * ONE);
        _open(420e8, 100);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(ONE, bob);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(s, alice, alice);
    }

    // ---------------------------------------------------------------- open bounds

    function test_onlyKeeperOpens() public {
        vm.expectRevert(KerneCoveredCallVault.NotKeeper.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_strikeMustBeOtm() public {
        vm.prank(keeper);
        vm.expectRevert(KerneCoveredCallVault.StrikeTooLow.selector);
        vault.openEpoch(411e8, 100, block.timestamp + 1 days, block.timestamp + 7 days); // < 3% OTM
    }

    function test_premiumFloor() public {
        vm.prank(keeper);
        vm.expectRevert(KerneCoveredCallVault.PremiumTooLow.selector);
        vault.openEpoch(420e8, 9, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_durationBounds() public {
        vm.startPrank(keeper);
        vm.expectRevert(KerneCoveredCallVault.BadDuration.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 hours, block.timestamp + 12 hours);
        vm.expectRevert(KerneCoveredCallVault.BadDuration.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 days, block.timestamp + 36 days);
        vm.expectRevert(KerneCoveredCallVault.BadDuration.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 8 days, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function test_stalePriceBlocksOpen() public {
        vm.warp(block.timestamp + 26 hours);
        vm.prank(keeper);
        vm.expectRevert(KerneCoveredCallVault.StalePrice.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_cannotOpenTwice() public {
        _open(420e8, 100);
        vm.prank(keeper);
        vm.expectRevert(KerneCoveredCallVault.EpochIsLive.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_idleWindowGuaranteesExit() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 100);
        vault.settle(_priceAtExpiry(SPOT));
        feed.push(SPOT, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(KerneCoveredCallVault.ExitWindowOpen.selector);
        vault.openEpoch(420e8, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        // alice can leave inside the window
        uint256 s = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        vm.warp(block.timestamp + 12 hours);
        feed.push(SPOT, block.timestamp);
        _open(420e8, 100);
    }

    // ---------------------------------------------------------------- buying

    function test_buyPullsPremiumAndCapsAtCapacity() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150); // 1.5%
        uint256 p = _buy(buyer, 4 * ONE);
        assertEq(p, 6e6); // 0.06 TSLAc
        assertEq(vault.totalAssets(), 10 * ONE, "premium excluded while live");
        vm.prank(buyer2);
        vm.expectRevert(KerneCoveredCallVault.OverCapacity.selector);
        vault.buyCall(6 * ONE + 1, type(uint256).max);
        _buy(buyer2, 6 * ONE);
    }

    function test_buySlippageGuard() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.PremiumTooLow.selector);
        vault.buyCall(4 * ONE, 6e6 - 1);
    }

    function test_saleWindowCloses() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        vm.warp(block.timestamp + 1 days);
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.SaleClosed.selector);
        vault.buyCall(ONE, type(uint256).max);
    }

    function test_pausedSales() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        vm.prank(owner);
        vault.setSalesPaused(true);
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.Paused.selector);
        vault.buyCall(ONE, type(uint256).max);
    }

    // ---------------------------------------------------------------- settlement

    function test_settleOtmPremiumBecomesYield() public {
        uint256 s = _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 10 * ONE);
        vault.settle(_priceAtExpiry(415e8));
        assertEq(vault.totalAssets(), 10 * ONE + 15e6);
        assertEq(vault.claimable(1, buyer), 0);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertApproxEqAbs(out, 10 * ONE + 15e6, 1);
    }

    function test_settleItmPaysBuyersInKind() public {
        uint256 s = _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 6 * ONE);
        _buy(buyer2, 4 * ONE);
        vault.settle(_priceAtExpiry(500e8)); // payout fraction = 80/500 = 16%
        assertEq(vault.claimable(1, buyer), 96e6);
        assertEq(vault.claimable(1, buyer2), 64e6);
        assertEq(vault.unclaimedPayouts(), 160e6);
        assertEq(vault.totalAssets(), 10 * ONE + 15e6 - 160e6);

        vm.prank(buyer);
        vault.claim(1, buyer);
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.NothingToClaim.selector);
        vault.claim(1, buyer);

        // depositor exits before buyer2 claims: buyer2 is still fully reserved
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        vm.prank(buyer2);
        vault.claim(1, buyer2);
        assertEq(stock.balanceOf(buyer2), 100 * ONE - 6e6 + 64e6);
        assertLe(stock.balanceOf(address(vault)), 2);
    }

    function test_blockedBuyerCannotJamOthers() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 5 * ONE);
        _buy(buyer2, 5 * ONE);
        vault.settle(_priceAtExpiry(500e8));
        stock.setBlocked(buyer, true);
        vm.prank(buyer);
        vm.expectRevert();
        vault.claim(1, buyer);
        vm.prank(buyer2);
        vault.claim(1, buyer2); // unaffected
        stock.setBlocked(buyer, false); // once the policy clears, the buyer's claim is intact
        vm.prank(buyer);
        vault.claim(1, buyer);
        assertLe(stock.balanceOf(address(vault)), 10 * ONE + 15e6);
    }

    function test_settleRequiresExpiry() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        vm.expectRevert(KerneCoveredCallVault.NotExpired.selector);
        vault.settle(1);
    }

    function test_settlerCannotPickALaterRound() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 10 * ONE);
        uint80 first = _priceAtExpiry(415e8);
        uint80 later = feed.push(600e8, block.timestamp + 1);
        vm.expectRevert(KerneCoveredCallVault.BadRoundHint.selector);
        vault.settle(later);
        vm.expectRevert(KerneCoveredCallVault.BadRoundHint.selector);
        vault.settle(first - 1); // pre-expiry round
        vault.settle(first);
        (,,,,,,, uint128 px,,) = vault.epochs(1);
        assertEq(px, 415e8);
    }

    function test_fallbackRefusesWhenHintExists() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 10 * ONE);
        uint80 hint = _priceAtExpiry(500e8); // ITM at expiry
        vm.warp(block.timestamp + 8 days);
        feed.push(300e8, block.timestamp); // price later collapses
        vm.expectRevert(KerneCoveredCallVault.UseHint.selector);
        vault.settleFallback(); // cannot pick the later, lower price
        vault.settle(hint);
        assertGt(vault.claimable(1, buyer), 0);
    }

    function test_fallbackDeadFeedSettlesAtLastPrice() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        (,, uint64 expiry,,,,,,,) = vault.epochs(1);
        vm.warp(expiry + 1 days);
        vm.expectRevert(KerneCoveredCallVault.FallbackNotReady.selector);
        vault.settleFallback();
        vm.warp(expiry + 7 days); // feed silent since open
        vault.settleFallback();
        (,,,,,,, uint128 px,,) = vault.epochs(1);
        assertEq(px, uint128(uint256(SPOT)));
        assertFalse(vault.epochLive());
    }

    function test_fallbackDelayFrozenAtOpen() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        vm.prank(owner);
        vault.setParams(1_000 * ONE, 25 hours, 300, 10, 1 days, 35 days, 4 days, 12 hours);
        (,, uint64 expiry,,,,,,,) = vault.epochs(1);
        vm.warp(expiry + 5 days);
        vm.expectRevert(KerneCoveredCallVault.FallbackNotReady.selector);
        vault.settleFallback();
    }

    function test_hintMustBeInCurrentPhase() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        uint80 hint = _priceAtExpiry(410e8);
        vm.expectRevert(KerneCoveredCallVault.BadRoundHint.selector);
        vault.settle(uint80((uint256(1) << 64) | hint));
        vault.settle(hint);
    }

    /// Regression for review H-1: an option that moved into the money cannot be bought.
    function test_cannotBuyInTheMoney() public {
        _deposit(alice, 10 * ONE);
        vm.prank(keeper);
        vault.openEpoch(420e8, 100, block.timestamp + 7 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days - 60);
        feed.push(500e8, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.StrikeTooLow.selector);
        vault.buyCall(10 * ONE, type(uint256).max);
        feed.push(410e8, block.timestamp); // within 3% of strike: still blocked
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.StrikeTooLow.selector);
        vault.buyCall(10 * ONE, type(uint256).max);
    }

    function test_buyNeedsFreshPrice() public {
        _deposit(alice, 10 * ONE);
        vm.prank(keeper);
        vault.openEpoch(420e8, 100, block.timestamp + 6 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 26 hours); // feed frozen (weekend-like)
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.StalePrice.selector);
        vault.buyCall(ONE, type(uint256).max);
    }

    function test_deadFeedLongStopSettlesAtStrike() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 150);
        _buy(buyer, 10 * ONE);
        (,, uint64 expiry,,,,,,,) = vault.epochs(1);
        feed.push(SPOT, expiry - 1);
        vm.warp(expiry + 8 days);
        uint80 bad = feed.push(-1, expiry + 1); // first post-expiry round is broken: no hint is ever valid
        vm.expectRevert(KerneCoveredCallVault.BadRoundHint.selector);
        vault.settle(bad);
        vm.expectRevert(KerneCoveredCallVault.UseHint.selector);
        vault.settleFallback();
        vm.warp(expiry + 37 days);
        vault.settleFallback();
        assertEq(vault.claimable(1, buyer), 0);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.redeem(sh, alice, alice), 10 * ONE + 15e6 - 1);
    }

    function test_weekendBuyBlocked() public {
        _deposit(alice, 10 * ONE);
        _open(420e8, 100);
        vm.warp(block.timestamp + 4 hours + 1); // feed frozen after the close
        vm.prank(buyer);
        vm.expectRevert(KerneCoveredCallVault.StalePrice.selector);
        vault.buyCall(ONE, type(uint256).max);
    }

    // ---------------------------------------------------------------- inflation attack

    function test_firstDepositorDonationAttackUnprofitable() public {
        vm.prank(alice);
        vault.deposit(1, alice);
        vm.prank(alice);
        stock.transfer(address(vault), 50 * ONE); // donation
        uint256 s = _deposit(bob, 10 * ONE);
        assertGt(s, 0);
        vm.prank(bob);
        uint256 out = vault.redeem(s, bob, bob);
        assertApproxEqRel(out, 10 * ONE, 1e15); // bob loses < 0.1%
    }

    // ---------------------------------------------------------------- admin

    function test_paramBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(KerneCoveredCallVault.BadParams.selector);
        vault.setParams(1, 0, 300, 10, 1 days, 35 days, 7 days, 12 hours);
        vm.expectRevert(KerneCoveredCallVault.BadParams.selector);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 3 days, 12 hours);
        vm.expectRevert(KerneCoveredCallVault.BadParams.selector);
        vault.setParams(1, 1 hours, 0, 10, 1 days, 35 days, 7 days, 12 hours);
        vm.expectRevert(KerneCoveredCallVault.BadParams.selector);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 7 days, 0);
        vm.stopPrank();
        vm.expectRevert();
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 7 days, 12 hours);
    }

    // ---------------------------------------------------------------- fuzz

    /// Solvency for any price: every buyer can claim, then every depositor can redeem.
    function testFuzz_solventForAnyPrice(uint96 dep, uint96 sold1, uint96 sold2, uint64 px, uint16 prem) public {
        dep = uint96(bound(dep, 1e4, 100 * ONE));
        uint256 premBps = bound(prem, 10, 2_000);
        uint256 price = bound(px, 1, 1e14);
        _deposit(alice, dep);
        _open(420e8, premBps);
        uint256 a = bound(sold1, 0, dep);
        uint256 b = bound(sold2, 0, dep - a);
        if (a > 0) _buy(buyer, a);
        if (b > 0) _buy(buyer2, b);
        vault.settle(_priceAtExpiry(int256(price)));

        uint256 c1 = vault.claimable(1, buyer);
        uint256 c2 = vault.claimable(1, buyer2);
        if (c1 > 0) {
            vm.prank(buyer);
            vault.claim(1, buyer);
        }
        if (c2 > 0) {
            vm.prank(buyer2);
            vault.claim(1, buyer2);
        }
        uint256 s = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        assertLe(stock.balanceOf(address(vault)), 3, "only rounding dust remains");
        // payouts never exceed notional
        assertLe(c1, a);
        assertLe(c2, b);
    }
}
