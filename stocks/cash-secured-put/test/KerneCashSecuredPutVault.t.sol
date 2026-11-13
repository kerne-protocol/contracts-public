// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KerneCashSecuredPutVault, IAggregatorV3} from "../src/KerneCashSecuredPutVault.sol";
import {MockStock, MockUSDC, MockFeed} from "./Mocks.sol";

/// @dev Shared fixture. Time starts on a Tuesday at 15:00 UTC, inside sale hours.
abstract contract PutVaultFixture is Test {
    MockUSDC usdc;
    MockStock stock;
    MockFeed feed;
    KerneCashSecuredPutVault vault;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    uint256 constant USD = 1e6; // one USDC
    uint256 constant ONE = 1e8; // one TSLAc
    int256 constant SPOT = 400e8; // $400
    uint256 constant K = 380e8; // 5% below spot
    uint256 constant T0 = 1_800_370_800; // Tuesday 2027-01-19 15:00:00 UTC
    uint256 constant CAP = 1_000_000 * USD;

    function setUp() public virtual {
        vm.warp(T0 - 12 hours);
        usdc = new MockUSDC();
        stock = new MockStock();
        feed = new MockFeed();
        feed.push(SPOT, block.timestamp);
        vault = new KerneCashSecuredPutVault(
            IERC20(address(usdc)),
            IERC20(address(stock)),
            IAggregatorV3(address(feed)),
            "Kerne Cash Secured Put TSLAc",
            "kcpTSLAc",
            owner,
            keeper
        );
        _setParams(CAP, 300, 10, 1 days, 12 hours);
        vm.warp(T0); // the notice period after setParams has passed
        feed.push(SPOT, block.timestamp);

        address[4] memory users = [alice, bob, buyer, buyer2];
        for (uint256 i; i < users.length; i++) {
            usdc.mint(users[i], 100_000 * USD);
            stock.mint(users[i], 100 * ONE);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            stock.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- helpers

    function _setParams(uint256 cap, uint256 otm, uint256 prem, uint256 exWindow, uint256 idle) internal {
        vm.prank(owner);
        vault.setParams(cap, 25 hours, otm, prem, 1 days, 35 days, exWindow, idle);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amt, who);
    }

    function _open(uint256 strike, uint256 premiumBps) internal returns (uint256 id) {
        vm.prank(keeper);
        id = vault.openEpoch(strike, premiumBps, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function _ep() internal view returns (KerneCashSecuredPutVault.Epoch memory) {
        return vault.epochs(vault.currentEpoch());
    }

    /// One raw purchase against the current oracle round.
    function _buyRaw(address who, uint256 notional) internal returns (uint256 p) {
        uint256 id = vault.currentEpoch();
        vm.prank(who);
        p = vault.buyPut(id, notional, type(uint256).max);
    }

    /// Buys `notional` across as many fresh oracle rounds as the per-round cap needs. Stops at
    /// a remainder too small to meet the minimum purchase. Returns the premium paid.
    function _buy(address who, uint256 notional) internal returns (uint256 p) {
        KerneCashSecuredPutVault.Epoch memory e = _ep();
        uint256 perRound = uint256(e.capacity) / 10 * 1e16 / (uint256(e.strike) * 1e6);
        while (notional > 0 && perRound > 0) {
            uint256 n = Math.min(notional, perRound);
            (, uint256 prem) = vault.quotePremium(n);
            if (prem * 100_000 < e.capacity) break;
            (, int256 px,,,) = feed.latestRoundData();
            feed.push(px, block.timestamp); // a new round
            p += _buyRaw(who, n);
            notional -= n;
        }
    }

    function _exercise(address who, uint256 notional) internal returns (uint256 cash) {
        vm.prank(who);
        cash = vault.exercise(notional, who);
    }

    function _toExpiry() internal {
        vm.warp(_ep().expiry);
    }

    function _toExerciseEnd() internal {
        vm.warp(_ep().exerciseEnd);
    }

    /// Moves to the next moment an epoch may open and sell: past the notice period, on a weekday
    /// at 15:00 UTC, with a fresh feed print.
    function _toNextSale() internal {
        if (block.timestamp < vault.nextOpenAt()) vm.warp(vault.nextOpenAt());
        if (!vault.inSaleHours()) {
            uint256 t = block.timestamp / 1 days * 1 days + 15 hours;
            if (t <= block.timestamp) t += 1 days;
            while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) t += 1 days;
            vm.warp(t);
        }
        feed.push(SPOT, block.timestamp);
    }

    /// largest notional whose strike cash (rounded up) fits in `cash` at strike K
    function _maxNotional(uint256 cash) internal pure returns (uint256) {
        return cash * 1e16 / (K * 1e6);
    }
}

contract KerneCashSecuredPutVaultTest is PutVaultFixture {
    // ---------------------------------------------------------------- deposits

    function test_deploysClosed() public {
        KerneCashSecuredPutVault v = new KerneCashSecuredPutVault(
            IERC20(address(usdc)), IERC20(address(stock)), IAggregatorV3(address(feed)), "n", "s", owner, keeper
        );
        assertEq(v.depositCap(), 0);
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.maxMint(alice), 0);
        assertEq(v.decimals(), 12);
        assertEq(v.minSupply(), 1e6);
        assertEq(v.asset(), address(usdc));
        assertEq(address(v.stock()), address(stock));
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        v.deposit(USD, alice);
    }

    function test_constructorRejectsSameToken() public {
        vm.expectRevert(KerneCashSecuredPutVault.SameToken.selector);
        new KerneCashSecuredPutVault(
            IERC20(address(usdc)), IERC20(address(usdc)), IAggregatorV3(address(feed)), "n", "s", owner, keeper
        );
    }

    function test_depositClosedUntilCapSet() public {
        _setParams(0, 300, 10, 1 days, 12 hours);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(USD, alice);
    }

    function test_depositCapEnforced() public {
        _setParams(5_000 * USD, 300, 10, 1 days, 12 hours);
        _deposit(alice, 5_000 * USD);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1, bob);
    }

    function test_depositWithdrawRoundTrip() public {
        uint256 s = _deposit(alice, 10_000 * USD);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertEq(out, 10_000 * USD);
        assertEq(usdc.balanceOf(alice), 100_000 * USD);
    }

    function test_flowsFrozenDuringEpoch() public {
        uint256 s = _deposit(alice, 10_000 * USD);
        _open(K, 100);
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(USD, bob);
        vm.prank(bob);
        vm.expectRevert(KerneCashSecuredPutVault.EpochIsLive.selector);
        vault.deposit(0, bob); // not even a zero-amount call goes through
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(s, alice, alice);
        // still frozen through the whole exercise window
        _toExpiry();
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(s, alice, alice);
    }

    /// Review L-2 (B): shares cannot change hands while an epoch is live.
    function test_shareTransfersFrozenWhileLive() public {
        uint256 s = _deposit(alice, 10_000 * USD);
        _open(K, 100);
        vm.prank(alice);
        vm.expectRevert(KerneCashSecuredPutVault.EpochIsLive.selector);
        vault.transfer(bob, s);
        _toExerciseEnd();
        vault.settle();
        vm.prank(alice);
        vault.transfer(bob, s);
        assertEq(vault.balanceOf(bob), s);
    }

    // ---------------------------------------------------------------- open bounds

    function test_onlyKeeperOpens() public {
        vm.expectRevert(KerneCashSecuredPutVault.NotKeeper.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_strikeMustBeOtm() public {
        vm.startPrank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.openEpoch(388e8 + 1, 100, block.timestamp + 1 days, block.timestamp + 7 days); // < 3% OTM
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.openEpoch(0, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vault.openEpoch(388e8, 100, block.timestamp + 1 days, block.timestamp + 7 days); // exactly 3% is allowed
        vm.stopPrank();
    }

    function test_premiumFloor() public {
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.openEpoch(K, 9, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_durationBounds() public {
        vm.startPrank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.BadDuration.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 hours, block.timestamp + 12 hours);
        vm.expectRevert(KerneCashSecuredPutVault.BadDuration.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 36 days);
        vm.expectRevert(KerneCashSecuredPutVault.BadDuration.selector);
        vault.openEpoch(K, 100, block.timestamp + 8 days, block.timestamp + 7 days);
        vm.expectRevert(KerneCashSecuredPutVault.BadDuration.selector);
        vault.openEpoch(K, 100, block.timestamp, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function test_stalePriceBlocksOpen() public {
        vm.warp(block.timestamp + 26 hours);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.StalePrice.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_cannotOpenTwice() public {
        _open(K, 100);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.EpochIsLive.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_pausedBlocksOpen() public {
        vm.prank(owner);
        vault.setSalesPaused(true);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.Paused.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
    }

    function test_idleWindowGuaranteesExit() public {
        _deposit(alice, 10_000 * USD);
        _open(K, 100);
        _toExerciseEnd();
        vault.settle();
        feed.push(SPOT, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        // alice can leave inside the window
        uint256 s = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        vm.warp(block.timestamp + 12 hours - 1);
        feed.push(SPOT, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 1);
        _open(K, 100);
    }

    /// Review M-2 (B) / L-1 (A): the exit window an epoch opened with cannot be cut afterwards.
    function test_idleWindowFrozenAtOpen() public {
        _setParams(CAP, 300, 10, 1 days, 2 days);
        vm.warp(vault.nextOpenAt());
        _toNextSale();
        _deposit(alice, 10_000 * USD);
        _open(K, 100); // this epoch carries a 2 day exit window
        _setParams(CAP, 300, 10, 1 days, 12 hours); // owner cuts it mid-epoch
        _toExerciseEnd();
        vault.settle();
        assertEq(vault.nextOpenAt(), block.timestamp + 2 days);
        vm.warp(block.timestamp + 12 hours);
        feed.push(SPOT, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        _setParams(CAP, 300, 10, 1 days, 12 hours); // cutting it after settlement does not help either
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 36 hours);
        feed.push(SPOT, block.timestamp);
        _open(K, 100);
    }

    /// Review M-2 (B) / L-6 (A): a change of rules or keeper gives depositors a full exit window.
    function test_paramOrKeeperChangeGivesNotice() public {
        uint256 s = _deposit(alice, 10_000 * USD);
        _setParams(CAP, 100, 10, 3 days, 12 hours); // loosen the OTM floor, lengthen the window
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 12 hours);
        feed.push(SPOT, block.timestamp);
        vm.prank(owner);
        vault.setKeeper(bob); // a new keeper restarts the clock too
        vm.prank(bob);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vm.prank(alice);
        vault.redeem(s, alice, alice); // anyone who disagrees is out before an epoch can open
    }

    // ---------------------------------------------------------------- buying

    function test_buyPullsPremiumAndCapsAtCapacity() public {
        _deposit(alice, 3_800 * USD); // secures exactly 10 TSLAc at $380
        _open(K, 150); // 1.5% of strike cash
        (uint256 cash, uint256 quoted) = vault.quotePremium(ONE);
        assertEq(cash, 380 * USD);
        assertEq(quoted, 5_700_000);
        uint256 p = _buy(buyer, 4 * ONE);
        assertEq(p, 22_800_000); // 22.80 USDC
        assertEq(vault.totalAssets(), 3_800 * USD, "premium excluded while live");
        _buy(buyer2, 6 * ONE);
        feed.push(SPOT, block.timestamp);
        vm.startPrank(buyer2);
        vm.expectRevert(KerneCashSecuredPutVault.OverCapacity.selector);
        vault.buyPut(1, ONE / 10, type(uint256).max);
        vm.expectRevert(KerneCashSecuredPutVault.OverCapacity.selector);
        vault.buyPut(1, 0, type(uint256).max);
        vm.stopPrank();
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(1);
        assertEq(e.capacity, 3_800 * USD);
        assertEq(e.soldCash, 3_800 * USD);
        assertEq(e.sold, 10 * ONE);
        assertEq(e.premium, 57 * USD);
    }

    function test_buySlippageGuard() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.buyPut(1, ONE, 5_700_000 - 1);
    }

    /// Review L-5 (A): a purchase names its epoch, so it cannot land on a later epoch's strike.
    function test_buyMustNameTheLiveEpoch() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.WrongEpoch.selector);
        vault.buyPut(2, ONE, type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.WrongEpoch.selector);
        vault.buyPut(0, ONE, type(uint256).max);
    }

    function test_saleWindowCloses() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.warp(block.timestamp + 1 days);
        feed.push(SPOT, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.SaleClosed.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    function test_pausedSales() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.prank(owner);
        vault.setSalesPaused(true);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.Paused.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    function test_buyNeedsLiveEpoch() public {
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NoLiveEpoch.selector);
        vault.buyPut(0, ONE, type(uint256).max);
    }

    /// With no shares outstanding nobody could be credited delivered stock, so nothing is sold.
    function test_noSharesNoCapacity() public {
        vm.prank(alice);
        usdc.transfer(address(vault), 5_000 * USD); // donation, zero supply
        _open(K, 150);
        assertEq(vault.epochs(1).capacity, 0);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OverCapacity.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    /// Review H (both), refined in round 2: with next to no shares outstanding the vault sells
    /// nothing. That needs a deposit smaller than a donation already sitting in the vault.
    function test_belowMinSupplySellsNothing() public {
        vm.prank(alice);
        usdc.transfer(address(vault), 5_000 * USD);
        _deposit(alice, USD); // mints about 200 share units against the donation
        assertGt(vault.totalSupply(), 0);
        assertLt(vault.totalSupply(), vault.minSupply());
        _open(K, 150);
        assertEq(vault.epochs(1).capacity, 0);
    }

    /// Review H-1 (B) / M-1 (A): no sale outside the US cash session, even against a "fresh" print.
    function test_afterCloseSaleBlocked() public {
        _deposit(alice, 3_800 * USD);
        vm.prank(keeper);
        vault.openEpoch(388e8, 10, block.timestamp + 3 days, block.timestamp + 7 days);
        uint256 day = T0 / 1 days * 1 days;
        vm.warp(day + 19 hours + 55 minutes - 1);
        feed.push(SPOT, block.timestamp);
        _buyRaw(buyer, ONE / 2); // last second of sale hours
        vm.warp(day + 19 hours + 55 minutes);
        feed.push(SPOT, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OutsideSaleHours.selector);
        vault.buyPut(1, ONE / 2, type(uint256).max);
        // earnings land after the close; the last print is minutes old and says $400
        vm.warp(day + 21 hours + 5 minutes);
        feed.push(SPOT, block.timestamp - 6 minutes);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OutsideSaleHours.selector);
        vault.buyPut(1, ONE / 2, type(uint256).max);
        // next morning before the window: still closed
        vm.warp(day + 1 days + 14 hours + 35 minutes - 1);
        feed.push(SPOT, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OutsideSaleHours.selector);
        vault.buyPut(1, ONE / 2, type(uint256).max);
        // at the open the feed shows the gap, and the put is refused as in the money
        vm.warp(day + 1 days + 14 hours + 35 minutes);
        feed.push(360e8, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.buyPut(1, ONE / 2, type(uint256).max);
    }

    function test_weekendSaleBlocked() public {
        _deposit(alice, 3_800 * USD);
        vm.prank(keeper);
        vault.openEpoch(K, 100, block.timestamp + 6 days, block.timestamp + 7 days);
        vm.warp(T0 + 4 days); // Saturday 15:00 UTC
        feed.push(SPOT, block.timestamp); // even if the feed printed
        assertFalse(vault.inSaleHours());
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OutsideSaleHours.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        vm.warp(T0 + 5 days); // Sunday
        feed.push(SPOT, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.OutsideSaleHours.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        vm.warp(T0 + 6 days - 1 hours); // Monday 14:00 UTC, before the window
        assertFalse(vault.inSaleHours());
        vm.warp(T0 + 6 days - 1); // Monday 14:59:59
        assertTrue(vault.inSaleHours());
    }

    /// Review H-1 (B): only a tenth of the epoch can be sold against one oracle round, so a frozen
    /// feed (a halt, an early close) cannot be used to take the whole vault.
    function test_perRoundSaleCap() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buyRaw(buyer, ONE); // exactly 10% of capacity
        vm.prank(buyer2);
        vm.expectRevert(KerneCashSecuredPutVault.RoundCapReached.selector);
        vault.buyPut(1, ONE / 100, type(uint256).max);
        vm.warp(block.timestamp + 3 hours); // still the same print: a halt looks like this
        vm.prank(buyer2);
        vm.expectRevert(KerneCashSecuredPutVault.RoundCapReached.selector);
        vault.buyPut(1, ONE / 100, type(uint256).max);
        feed.push(SPOT, block.timestamp); // the feed prints again
        _buyRaw(buyer2, ONE / 2);
        _buyRaw(buyer2, ONE / 2);
        vm.prank(buyer2);
        vm.expectRevert(KerneCashSecuredPutVault.RoundCapReached.selector);
        vault.buyPut(1, ONE / 100, type(uint256).max);
        assertEq(vault.epochs(1).soldCash, 760 * USD);
    }

    /// Review M-4 (B) / L-2 (A): a dust purchase cannot hold an epoch open for free.
    function test_dustPurchaseRefused() public {
        _deposit(alice, 100_000 * USD);
        _open(K, 100);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.buyPut(1, 1, type(uint256).max);
        // the smallest accepted purchase pays 1/100,000 of capacity in premium: 1 USDC here
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.buyPut(1, _maxNotional(100 * USD) - 1_000, type(uint256).max);
        uint256 p = _buyRaw(buyer, _maxNotional(100 * USD) + 1_000);
        assertGe(p, 1 * USD);
    }

    function test_keeperCanEndSaleEarly() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.expectRevert(KerneCashSecuredPutVault.NotKeeper.selector);
        vault.closeSale();
        vm.prank(keeper);
        vault.closeSale();
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.SaleClosed.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.SaleClosed.selector);
        vault.closeSale(); // it can only shorten, once
        vault.settle(); // nothing was sold, so depositors are free at once
        assertFalse(vault.epochLive());
    }

    function test_keeperCanOnlyRaisePremium() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.startPrank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.raisePremium(150);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.raisePremium(149);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.raisePremium(10_000);
        vault.raisePremium(300);
        vm.stopPrank();
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.PremiumTooLow.selector);
        vault.buyPut(1, ONE, 5_700_000); // the buyer's limit protects them from the new price
        assertEq(_buyRaw(buyer, ONE), 11_400_000);
        vm.expectRevert(KerneCashSecuredPutVault.NotKeeper.selector);
        vault.raisePremium(400);
    }

    // ---------------------------------------------------------------- settlement

    function test_lapsedPremiumBecomesYield() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExerciseEnd();
        vault.settle();
        assertEq(vault.totalAssets(), 3_857 * USD);
        assertEq(vault.claimableStock(alice), 0);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertApproxEqAbs(out, 3_857 * USD, 1);
    }

    function test_exerciseDeliversStockAndPaysStrike() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        _buy(buyer2, 4 * ONE);
        _toExpiry();
        uint256 cash = _exercise(buyer, 6 * ONE);
        assertEq(cash, 2_280 * USD);
        assertEq(usdc.balanceOf(buyer), 100_000 * USD - 34_200_000 + 2_280 * USD);
        assertEq(stock.balanceOf(buyer), 94 * ONE);
        assertEq(stock.balanceOf(address(vault)), 6 * ONE);
        assertEq(vault.unclaimedStock(), 6 * ONE);
        assertApproxEqAbs(vault.claimableStock(alice), 6 * ONE, 1);
        assertEq(vault.totalAssets(), 3_800 * USD - 2_280 * USD, "cash paid out, premium still excluded");

        // buyer2 lets the put lapse
        _toExerciseEnd();
        vault.settle();
        assertEq(vault.totalAssets(), 3_800 * USD - 2_280 * USD + 57 * USD);

        vm.prank(alice);
        uint256 got = vault.claimStock(alice);
        assertApproxEqAbs(got, 6 * ONE, 1);
        assertEq(stock.balanceOf(alice), 100 * ONE + got);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertApproxEqAbs(out, 1_577 * USD, 1);
        assertLe(usdc.balanceOf(address(vault)), 2);
        assertLe(stock.balanceOf(address(vault)), 1);
    }

    function test_partialExerciseAndLimits() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        _toExpiry();
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.exercise(6 * ONE + 1, buyer);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.exercise(0, buyer);
        vm.prank(buyer2); // never bought
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.exercise(ONE, buyer2);
        _exercise(buyer, 2 * ONE);
        _exercise(buyer, 4 * ONE);
        assertEq(vault.notionalOf(1, buyer), 0);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.exercise(1, buyer);
    }

    function test_exerciseOnlyInsideWindow() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        KerneCashSecuredPutVault.Epoch memory e = _ep();
        assertEq(e.exerciseEnd, e.expiry + 1 days);
        vm.warp(e.expiry - 1);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NotExpired.selector);
        vault.exercise(ONE, buyer);
        vm.warp(e.exerciseEnd);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseClosed.selector);
        vault.exercise(ONE, buyer);
        vm.warp(e.exerciseEnd - 1);
        _exercise(buyer, ONE);
    }

    function test_settleWaitsForExerciseWindow() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        KerneCashSecuredPutVault.Epoch memory e = _ep();
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        vm.warp(e.expiry);
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        vm.warp(e.exerciseEnd - 1);
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        vm.warp(e.exerciseEnd);
        vault.settle();
        assertTrue(vault.epochs(1).settled);
        vm.expectRevert(KerneCashSecuredPutVault.NoLiveEpoch.selector);
        vault.settle();
    }

    /// Unexercised puts lapse at settlement and cannot be used in a later epoch.
    function test_lapsedPutsCannotBeExercisedLater() public {
        _deposit(alice, 7_600 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        _toExerciseEnd();
        vault.settle();
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NoLiveEpoch.selector);
        vault.exercise(ONE, buyer);
        _toNextSale();
        _open(K, 150);
        _toExpiry();
        vm.prank(buyer); // holds epoch 1 notional only
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.exercise(ONE, buyer);
    }

    function test_earlySettleWhenNothingOutstanding() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle(); // sale window still open: a put could still be sold
        vm.warp(block.timestamp + 1 days);
        vault.settle(); // sale over, nothing sold: no reason to keep depositors locked
        assertFalse(vault.epochLive());
    }

    function test_earlySettleOnceEverythingIsExercised() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        _toExpiry();
        _exercise(buyer, 5 * ONE);
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        _exercise(buyer, ONE);
        vault.settle();
        assertFalse(vault.epochLive());
    }

    function test_blockedBuyerCannotJamOthers() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 5 * ONE);
        _buy(buyer2, 5 * ONE);
        _toExpiry();
        stock.setBlocked(buyer, true);
        vm.prank(buyer);
        vm.expectRevert();
        vault.exercise(5 * ONE, buyer);
        _exercise(buyer2, 5 * ONE); // unaffected
        stock.setBlocked(buyer, false); // once the policy clears, the buyer's put is intact
        _exercise(buyer, 5 * ONE);
        assertEq(stock.balanceOf(address(vault)), 10 * ONE);
    }

    /// Review L-1 (B): a buyer who gets blocked on the stock can move the put to an address that
    /// can deliver.
    function test_blockedBuyerCanMoveThePut() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 5 * ONE);
        stock.setBlocked(buyer, true);
        vm.startPrank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToExercise.selector);
        vault.transferPut(buyer2, 5 * ONE + 1);
        vm.expectRevert(KerneCashSecuredPutVault.BadRecipient.selector);
        vault.transferPut(address(0), ONE);
        vm.expectRevert(KerneCashSecuredPutVault.BadRecipient.selector);
        vault.transferPut(address(vault), ONE);
        vault.transferPut(buyer2, 5 * ONE);
        vm.stopPrank();
        assertEq(vault.notionalOf(1, buyer), 0);
        assertEq(vault.notionalOf(1, buyer2), 5 * ONE);
        _toExpiry();
        assertEq(_exercise(buyer2, 5 * ONE), 1_900 * USD);
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(1);
        assertEq(e.sold, 5 * ONE, "moving a put does not change what the vault owes");
        assertEq(e.exercised, 5 * ONE);
    }

    function test_usdcBlockedBuyerCanRedirectCash() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 5 * ONE);
        _toExpiry();
        usdc.setBlocked(buyer, true);
        vm.prank(buyer);
        vm.expectRevert();
        vault.exercise(5 * ONE, buyer);
        vm.prank(buyer);
        vault.exercise(5 * ONE, buyer2);
        assertEq(usdc.balanceOf(buyer2), 100_000 * USD + 1_900 * USD);
    }

    /// Review L-1 (B): if the token delivers less than asked, the vault pays for and credits only
    /// what arrived, and the buyer keeps the rest of the put.
    function test_exercisePaysOnWhatArrived() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 5 * ONE);
        _toExpiry();
        stock.setSkim(1_000); // each transfer arrives 1,000 units short
        uint256 cash = _exercise(buyer, 5 * ONE);
        assertEq(cash, vault.strikeCash(5 * ONE - 1_000, K, Math.Rounding.Floor));
        assertEq(vault.notionalOf(1, buyer), 1_000);
        assertEq(vault.unclaimedStock(), 5 * ONE - 1_000);
        assertEq(stock.balanceOf(address(vault)), 5 * ONE - 1_000);
        assertEq(vault.epochs(1).exercised, 5 * ONE - 1_000);
    }

    /// Settlement needs no oracle: a dead feed cannot lock buyers or depositors.
    function test_deadFeedCannotLockEpoch() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        feed.setBroken(true);
        _toExpiry();
        _exercise(buyer, 6 * ONE);
        vault.settle(); // everything exercised
        vm.prank(alice);
        vault.claimStock(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertApproxEqAbs(out, 3_800 * USD - 2_280 * USD + 34_200_000, 1);
    }

    function test_deadFeedLapseStillSettles() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        feed.setBroken(true);
        _toExerciseEnd();
        vault.settle();
        assertFalse(vault.epochLive());
    }

    function test_pauseNeverBlocksExerciseSettleOrExit() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        vm.prank(owner);
        vault.setSalesPaused(true);
        _toExpiry();
        _exercise(buyer, 6 * ONE);
        vault.settle();
        vm.prank(alice);
        vault.claimStock(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
    }

    function test_exerciseWindowFrozenAtOpen() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 6 * ONE);
        _setParams(CAP, 300, 10, 6 hours, 12 hours);
        uint256 expiry = _ep().expiry;
        vm.warp(expiry + 7 hours); // past the new 6h window, inside the 1 day this epoch opened with
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        _exercise(buyer, 6 * ONE);
    }

    function test_minOtmFrozenAtOpen() public {
        _deposit(alice, 7_600 * USD);
        _open(K, 150); // opened under a 3% floor
        _setParams(CAP, 100, 10, 1 days, 12 hours); // loosen to 1%
        feed.push(390e8, block.timestamp); // 380 is only 2.56% below 390
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        _setParams(CAP, 1_000, 10, 1 days, 12 hours); // tighten to 10%
        feed.push(SPOT, block.timestamp);
        _buyRaw(buyer, ONE); // the live epoch keeps its own 3% floor
    }

    /// Carried over from the call vault's review H-1: a put that moved into the money cannot be bought.
    function test_cannotBuyInTheMoney() public {
        _deposit(alice, 3_800 * USD);
        vm.prank(keeper);
        vault.openEpoch(K, 100, block.timestamp + 7 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days - 60);
        feed.push(300e8, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        feed.push(390e8, block.timestamp); // within 3% of strike: still blocked
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StrikeTooHigh.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        feed.push(392e8, block.timestamp); // 392 * 0.97 = 380.24 >= 380
        _buyRaw(buyer, ONE);
    }

    function test_buyNeedsFreshPrice() public {
        _deposit(alice, 3_800 * USD);
        vm.prank(keeper);
        vault.openEpoch(K, 100, block.timestamp + 6 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 26 hours); // Wednesday 17:00, no print since Tuesday
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StalePrice.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    function test_staleBuyBlockedInsideSaleHours() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 100);
        vm.warp(block.timestamp + 4 hours + 1); // 19:00:01, last print 15:00
        assertTrue(vault.inSaleHours());
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StalePrice.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    function test_badFeedAnswerBlocksSale() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 100);
        feed.push(0, block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StalePrice.selector);
        vault.buyPut(1, ONE, type(uint256).max);
        feed.push(SPOT, block.timestamp + 1); // timestamp from the future
        vm.prank(buyer);
        vm.expectRevert(KerneCashSecuredPutVault.StalePrice.selector);
        vault.buyPut(1, ONE, type(uint256).max);
    }

    // ---------------------------------------------------------------- delivered stock

    function test_stockCreditedProRata() public {
        _deposit(alice, 3_000 * USD);
        _deposit(bob, 1_000 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExpiry();
        _exercise(buyer, 10 * ONE);
        assertApproxEqAbs(vault.claimableStock(alice), 75 * ONE / 10, 1);
        assertApproxEqAbs(vault.claimableStock(bob), 25 * ONE / 10, 1);
        assertLe(vault.claimableStock(alice) + vault.claimableStock(bob), vault.unclaimedStock());
        vm.prank(bob);
        vault.claimStock(bob);
        vm.prank(bob);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToClaim.selector);
        vault.claimStock(bob);
        vm.prank(alice);
        vm.expectRevert(KerneCashSecuredPutVault.BadRecipient.selector);
        vault.claimStock(address(vault));
        vm.prank(alice);
        vault.claimStock(alice); // works while the epoch is still live
        assertLe(stock.balanceOf(address(vault)), 2);
    }

    function test_stockStaysWithHolderOnShareTransfer() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExpiry();
        _exercise(buyer, 4 * ONE);
        _toExerciseEnd();
        vault.settle(); // the other 6 lapse
        vm.prank(alice);
        vault.transfer(bob, s); // sells her shares between epochs
        assertApproxEqAbs(vault.claimableStock(alice), 4 * ONE, 1);
        assertEq(vault.claimableStock(bob), 0);

        _toNextSale();
        _open(K, 150);
        _buy(buyer2, 5 * ONE);
        _toExpiry();
        _exercise(buyer2, vault.notionalOf(2, buyer2)); // later deliveries belong to the new holder
        assertApproxEqAbs(vault.claimableStock(alice), 4 * ONE, 1);
        assertApproxEqAbs(vault.claimableStock(bob), vault.epochs(2).exercised, 1);
        assertGt(vault.claimableStock(bob), 4 * ONE);
        vault.settle();
        vm.prank(alice);
        vault.claimStock(alice);
        vm.prank(bob);
        vault.claimStock(bob);
    }

    function test_redeemKeepsStockClaim() public {
        uint256 s = _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExpiry();
        _exercise(buyer, 10 * ONE);
        vault.settle();
        vm.prank(alice);
        vault.redeem(s, alice, alice); // leaves with the cash first
        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqAbs(vault.claimableStock(alice), 10 * ONE, 1);
        vm.prank(alice);
        uint256 got = vault.claimStock(alice);
        assertApproxEqAbs(got, 10 * ONE, 1);
    }

    /// A deposit after an assignment buys no claim on stock delivered before it.
    function test_lateDepositorGetsNoEarlierStock() public {
        _deposit(alice, 3_800 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExpiry();
        _exercise(buyer, 10 * ONE);
        vault.settle();
        uint256 aliceBefore = vault.claimableStock(alice);
        _deposit(bob, 50_000 * USD);
        assertEq(vault.claimableStock(bob), 0);
        assertEq(vault.claimableStock(alice), aliceBefore);

        // next epoch: both share new deliveries by their share of the vault
        _toNextSale();
        _open(K, 150);
        _buy(buyer2, 10 * ONE);
        _toExpiry();
        _exercise(buyer2, 10 * ONE);
        uint256 total = vault.totalSupply();
        assertApproxEqAbs(vault.claimableStock(bob), 10 * ONE * vault.balanceOf(bob) / total, 2);
        assertApproxEqAbs(vault.claimableStock(alice) - aliceBefore, 10 * ONE * vault.balanceOf(alice) / total, 2);
    }

    function test_blockedHolderCanSendStockElsewhere() public {
        _deposit(alice, 3_000 * USD);
        _deposit(bob, 800 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExpiry();
        _exercise(buyer, 10 * ONE);
        stock.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert();
        vault.claimStock(alice);
        vm.prank(bob);
        vault.claimStock(bob); // unaffected
        address cold = makeAddr("cold");
        vm.prank(alice);
        uint256 got = vault.claimStock(cold);
        assertEq(stock.balanceOf(cold), got);
    }

    // ---------------------------------------------------------------- inflation attack

    function test_firstDepositorDonationAttackUnprofitable() public {
        vm.prank(alice);
        vault.deposit(1, alice);
        vm.prank(alice);
        usdc.transfer(address(vault), 50_000 * USD); // donation
        uint256 s = _deposit(bob, 10_000 * USD);
        assertGt(s, 0);
        vm.prank(bob);
        uint256 out = vault.redeem(s, bob, bob);
        assertApproxEqRel(out, 10_000 * USD, 1e15); // bob loses < 0.1%
    }

    // ---------------------------------------------------------------- admin

    function test_paramBounds() public {
        vm.startPrank(owner);
        bytes4 bad = KerneCashSecuredPutVault.BadParams.selector;
        vm.expectRevert(bad);
        vault.setParams(1, 0, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 3 days + 1, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 99, 10, 1 days, 35 days, 1 days, 12 hours); // OTM floor under 1%
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 5_001, 10, 1 days, 35 days, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 9, 1 days, 35 days, 1 days, 12 hours); // premium floor under 10 bps
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 hours - 1, 35 days, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 36 days, 35 days, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 45 days + 1, 1 days, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 6 hours - 1, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 3 days + 1, 12 hours);
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours - 1); // exit window under 12h
        vm.expectRevert(bad);
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 1 days, 7 days + 1);
        vm.expectRevert(bad);
        vault.setParams(uint256(type(uint88).max) + 1, 1 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        vault.setParams(type(uint88).max, 3 days, 100, 10, 1 hours, 45 days, 3 days, 7 days);
        vm.stopPrank();
        vm.expectRevert();
        vault.setParams(1, 1 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours);
    }

    /// Review L-3 (A): the max* views never revert, even at the largest allowed cap.
    function test_maxViewsNeverRevertAtLargestCap() public {
        _setParams(type(uint88).max, 300, 10, 1 days, 12 hours);
        assertGt(vault.maxDeposit(alice), 0);
        assertGt(vault.maxMint(alice), 0);
        _deposit(alice, 10_000 * USD);
        assertGt(vault.maxMint(alice), 0);
        assertEq(vault.maxDeposit(alice), uint256(type(uint88).max) - 10_000 * USD);
    }

    function test_onlyOwnerAdmin() public {
        vm.expectRevert();
        vault.setKeeper(alice);
        vm.expectRevert();
        vault.setSalesPaused(true);
        vm.prank(owner);
        vault.setKeeper(alice);
        assertEq(vault.keeper(), alice);
    }

    // ---------------------------------------------------------------- fuzz

    /// Fully cash-secured for any mix of sales and exercises: every buyer can exercise in full,
    /// then every depositor gets the stock and the remaining cash.
    function testFuzz_cashSecuredForAnyExercise(uint96 dep, uint96 n1, uint96 n2, uint96 x1, uint96 x2, uint16 prem)
        public
    {
        dep = uint96(bound(dep, 2 * USD, 90_000 * USD));
        _deposit(alice, dep);
        _open(K, bound(prem, 10, 2_000));
        uint256 premiums = _buy(buyer, bound(n1, 0, Math.min(_maxNotional(dep), 100 * ONE)));
        premiums += _buy(buyer2, bound(n2, 0, Math.min(_maxNotional(dep - vault.epochs(1).soldCash), 100 * ONE)));

        _toExpiry();
        uint256 a = bound(x1, 0, vault.notionalOf(1, buyer)); // the amounts exercised
        uint256 b = bound(x2, 0, vault.notionalOf(1, buyer2));
        uint256 paid;
        if (a > 0) paid += _exercise(buyer, a);
        if (b > 0) paid += _exercise(buyer2, b);
        _toExerciseEnd();
        vault.settle();

        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(1);
        assertEq(e.paid, paid);
        assertLe(paid, e.soldCash, "payouts never exceed the cash reserved");
        assertLe(e.soldCash, e.capacity, "reserved never exceeds the cash frozen at open");
        assertEq(usdc.balanceOf(address(vault)), uint256(dep) + premiums - paid);

        if (vault.claimableStock(alice) > 0) {
            vm.prank(alice);
            vault.claimStock(alice);
        }
        uint256 s = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        assertLe(usdc.balanceOf(address(vault)), 3, "only rounding dust remains");
        assertLe(stock.balanceOf(address(vault)), 3, "only rounding dust remains");
        assertGe(stock.balanceOf(alice) + 3, 100 * ONE + a + b, "depositor received the delivered stock");
    }

    /// Many small purchases exercised in one go: reservations round up, payouts round down.
    function testFuzz_roundingFavoursVault(uint8 count, uint32 each) public {
        uint256 n = bound(count, 1, 40);
        uint256 size = bound(each, 300_001, 3_000_000); // 0.003 to 0.03 TSLAc, above the minimum purchase
        _deposit(alice, 10_000 * USD);
        _open(K, 1_000);
        for (uint256 i; i < n; i++) {
            _buyRaw(buyer, size);
        }
        _toExpiry();
        uint256 paid = _exercise(buyer, n * size);
        uint256 soldCash = vault.epochs(1).soldCash;
        assertLe(paid, soldCash);
        assertGe(usdc.balanceOf(address(vault)), 10_000 * USD - soldCash);
    }

    /// Stock credits never exceed what was delivered, and at most dust is left uncredited, for
    /// any split of holders and any way of slicing the delivery.
    function testFuzz_stockCreditsMatchDelivered(uint64 depA, uint64 depB, uint64 notional, uint8 slices) public {
        uint256 a = bound(depA, USD, 400_000 * USD);
        uint256 b = bound(depB, USD, 400_000 * USD);
        usdc.mint(alice, a);
        usdc.mint(bob, b);
        _deposit(alice, a);
        _deposit(bob, b);
        _open(K, 100);
        _buy(buyer, bound(notional, 1, Math.min(_maxNotional(a + b), 100 * ONE)));
        uint256 n = vault.notionalOf(1, buyer);
        vm.assume(n > 0);
        _toExpiry();
        uint256 k = bound(slices, 1, 12);
        uint256 each = n / k;
        vm.assume(each >= 10);
        uint256 delivered;
        for (uint256 i; i < k; i++) {
            _exercise(buyer, each);
            delivered += each;
        }
        uint256 ca = vault.claimableStock(alice);
        uint256 cb = vault.claimableStock(bob);
        assertLe(ca + cb, delivered);
        assertGe(ca + cb + 3, delivered, "at most one unit per holder is still in flight");
        if (ca > 0) {
            vm.prank(alice);
            vault.claimStock(alice);
        }
        if (cb > 0) {
            vm.prank(bob);
            vault.claimStock(bob);
        }
    }
}

/// @dev Regressions for the share-supply ratchet found by both reviewers (H-1 in review A, H-2 in
///      review B): every full assignment multiplies the shares minted per USDC, and in the first
///      version the stock credit eventually truncated to zero.
contract SupplyRatchetTest is PutVaultFixture {
    uint256 constant K3 = 388e8; // exactly 3% below spot

    function _cycleSelfDealt(address who, uint256 amount) internal {
        _toNextSale();
        _deposit(who, amount);
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 hours, block.timestamp + 1 days);
        _buy(who, uint256(_ep().capacity) * 1e16 / (K3 * 1e6));
        _toExpiry();
        uint256 n = vault.notionalOf(vault.currentEpoch(), who);
        vm.prank(who);
        vault.exercise(n, who);
        _toExerciseEnd();
        vault.settle();
        vm.prank(who);
        vault.claimStock(who);
    }

    /// Review A's scenario: an attacker who is the only depositor runs seven self-dealt epochs for
    /// a fraction of a cent, then an honest depositor and an honest buyer arrive.
    function test_selfDealtRatchetCannotStrandStock() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1_000 * USD);
        stock.mint(attacker, 1_000 * ONE);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 7; i++) {
            _cycleSelfDealt(attacker, 1 * USD);
        }
        assertGt(vault.totalSupply(), 1e29, "the supply has ratcheted");

        _toNextSale();
        uint256 bobShares = _deposit(bob, 100_000 * USD);
        vm.prank(keeper);
        vault.openEpoch(K3, 100, block.timestamp + 1 hours, block.timestamp + 1 days);
        stock.mint(buyer, 300 * ONE);
        usdc.mint(buyer, 100_000 * USD);
        _buy(buyer, 250 * ONE);
        _toExpiry();
        uint256 n = vault.notionalOf(vault.currentEpoch(), buyer);
        assertGt(n, 249 * ONE);
        // delivered in awkward slices, the way the first version lost stock
        uint256 delivered;
        for (uint256 i; i < 25; i++) {
            delivered += n / 25;
            _exercise(buyer, n / 25);
        }
        uint256 expected = delivered * bobShares / vault.totalSupply();
        assertApproxEqAbs(vault.claimableStock(bob), expected, 30, "bob is credited his share of every slice");
        assertGt(vault.claimableStock(bob), delivered * 999 / 1000, "and it is essentially all of it");
        vm.prank(bob);
        vault.claimStock(bob);
    }

    /// Run the ratchet until the vault refuses deposits. Nothing is ever dropped on the way, the
    /// refusal is an explicit one, and the holders who are in can still run epochs and leave.
    function test_ratchetEndsInRefusedDepositsNotLostStock() public {
        address[25] memory lps;
        uint256 cycles;
        usdc.mint(buyer, 10_000_000 * USD);
        stock.mint(buyer, 100_000 * ONE);
        for (uint256 i; i < lps.length; i++) {
            lps[i] = makeAddr(string(abi.encodePacked("lp", i)));
            usdc.mint(lps[i], 100_000 * USD);
            vm.prank(lps[i]);
            usdc.approve(address(vault), type(uint256).max);
            _toNextSale();
            if (vault.maxDeposit(lps[i]) < 100_000 * USD) break; // the vault has stopped taking deposits
            _deposit(lps[i], 100_000 * USD); // a fresh $100k each cycle; earlier LPs never redeem
            cycles++;
            _fullAssignment(lps, cycles);
        }
        assertGt(cycles, 8, "many full assignments fit before the supply bound");
        assertLt(cycles, lps.length, "and then deposits are refused");
        assertLe(vault.totalSupply(), vault.MAX_SUPPLY());
        address late = lps[cycles];
        vm.prank(late);
        vm.expectRevert();
        vault.deposit(100_000 * USD, late);

        // the holders already in can still run a full epoch with an exact credit, and leave
        _toNextSale();
        _fullAssignment(lps, cycles);
        vm.warp(vault.nextOpenAt());
        for (uint256 j; j < cycles; j++) {
            vm.startPrank(lps[j]);
            if (vault.claimableStock(lps[j]) > 0) vault.claimStock(lps[j]);
            vault.redeem(vault.balanceOf(lps[j]), lps[j], lps[j]);
            vm.stopPrank();
        }
        assertEq(vault.totalSupply(), 0);
        assertLe(stock.balanceOf(address(vault)), 30 * cycles, "only rounding dust is left behind");
        // with everyone out the share price is back at par and the vault takes deposits again
        assertGe(vault.maxDeposit(late), 100_000 * USD);
    }

    function _fullAssignment(address[25] memory lps, uint256 holders) internal {
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 hours, block.timestamp + 1 days);
        _buy(buyer, uint256(_ep().capacity) * 1e16 / (K3 * 1e6));
        _toExpiry();
        uint256 n = vault.notionalOf(vault.currentEpoch(), buyer);
        // a third, a dust clip, then the rest
        _exercise(buyer, n / 3);
        _exercise(buyer, 1_000);
        _exercise(buyer, n - n / 3 - 1_000);
        // Nobody has claimed, so everything ever delivered must be sitting in the holders'
        // credits: never more, and short only by the unit each holder has in flight.
        uint256 credited;
        for (uint256 j; j < holders; j++) {
            credited += vault.claimableStock(lps[j]);
        }
        assertLe(credited, vault.unclaimedStock());
        assertGe(credited + holders + 1, vault.unclaimedStock(), "every delivered unit is credited, bar per-holder dust");
        _toExerciseEnd();
        vault.settle();
    }
}
