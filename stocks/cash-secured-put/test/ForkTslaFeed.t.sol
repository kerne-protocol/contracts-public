// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KerneCashSecuredPutVault, IAggregatorV3} from "../src/KerneCashSecuredPutVault.sol";
import {MockStock} from "./Mocks.sol";

interface IFeedHistory {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80);
    function description() external view returns (string memory);
}

/// @notice Runs one full epoch against the REAL Coinbase TSLA Chainlink feed and the REAL USDC
///         contract on Base mainnet, in three real moments:
///           A. about 13 hours before the sale: deploy closed, open the cap, deposit;
///           B. just after a real feed print inside US sale hours, at least 25 hours before head:
///              the keeper opens the epoch and puts are sold through the live checks;
///           C. head: the buyer decides with the real price whether to deliver. One token is
///              delivered either way to show assignment. Settlement needs no oracle.
///         The stock is a mock because B20 tokens are precompiles that a local fork cannot execute.
///         Run: FORK_TESTS=1 forge test --match-contract ForkTslaFeed -vv
contract ForkTslaFeedTest is Test {
    IFeedHistory constant TSLA_FEED = IFeedHistory(0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");
    address buyer = makeAddr("buyer"); // exercises only if the real price is below the strike
    address hedger = makeAddr("hedger"); // always delivers one token, to show delivery on the fork

    MockStock stock;
    KerneCashSecuredPutVault vault;
    uint256 head;
    uint256 headTs;
    uint256 strike;
    uint256 expiry;
    uint256 prem;

    function test_fullEpochOnRealFeed() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        // Sanity-gate the fork: the right chain, the right feed, a recent head.
        assertEq(block.chainid, 8453, "not Base mainnet");
        assertEq(TSLA_FEED.description(), "Coinbase TSLA", "unexpected feed");
        assertApproxEqAbs(vm.unixTime() / 1000, block.timestamp, 1 hours, "fork head is not recent");
        head = block.number;
        headTs = block.timestamp;

        (uint80 round, uint256 roundTs) = _latestSaleHoursRound();
        _deployAndFund(roundTs - 13 hours); // moment A
        _openAndSell(round, roundTs + 120); // moment B

        // Moment C: roll to head; vault, stock and USDC state persist, the feed is at its real state.
        vm.rollFork(head);
        assertGt(block.timestamp, expiry, "head not past expiry");
        (, int256 px,,,) = TSLA_FEED.latestRoundData();
        console2.log("head block", head, "time", block.timestamp);
        console2.log("real price at head", uint256(px), "strike", strike);

        uint256 paid;
        uint256 deliveredStock;
        if (uint256(px) < strike) {
            vm.prank(buyer);
            paid += vault.exercise(10e8, buyer);
            deliveredStock += 10e8;
            console2.log("in the money: buyer delivered 10 TSLAc for USDC", paid);
        } else {
            console2.log("out of the money: buyer lets the put lapse");
        }
        vm.prank(hedger);
        uint256 hedgerCash = vault.exercise(1e8, hedger);
        assertEq(hedgerCash, vault.strikeCash(1e8, strike, Math.Rounding.Floor));
        assertEq(stock.balanceOf(hedger), 0);
        paid += hedgerCash;
        deliveredStock += 1e8;

        // Settlement is the clock only: no round hint, no price.
        vm.expectRevert(KerneCashSecuredPutVault.ExerciseOpen.selector);
        vault.settle();
        vm.warp(vault.epochs(1).exerciseEnd);
        vault.settle();
        assertEq(vault.totalAssets(), 100_000e6 + prem - paid);
        assertEq(stock.balanceOf(address(vault)), deliveredStock);

        vm.startPrank(lp);
        uint256 gotStock = vault.claimStock(lp);
        uint256 gotCash = vault.redeem(vault.balanceOf(lp), lp, lp);
        vm.stopPrank();
        assertApproxEqAbs(gotStock, deliveredStock, 2);
        assertApproxEqAbs(gotCash, 100_000e6 + prem - paid, 2);
        console2.log("depositor leaves with USDC", gotCash, "and TSLAc units", gotStock);
        console2.log("premium earned (USDC units)", prem);
    }

    /// @dev Latest real feed round printed inside the vault's sale hours and at least 25 hours
    ///      before head, so a one-day put opened on it has already reached expiry.
    function _latestSaleHoursRound() internal view returns (uint80 r, uint256 upd) {
        (r,,, upd,) = TSLA_FEED.latestRoundData();
        while (headTs - upd < 25 hours || !_inSaleHours(upd + 120)) {
            r--;
            (,,, upd,) = TSLA_FEED.getRoundData(r);
        }
    }

    function _inSaleHours(uint256 t) internal pure returns (bool) {
        uint256 day = (t / 1 days + 4) % 7;
        uint256 tod = t % 1 days;
        return day != 0 && day != 6 && tod >= 14 hours + 35 minutes && tod < 19 hours + 50 minutes;
    }

    function _deployAndFund(uint256 ts) internal {
        uint256 blk = _blockAt(ts);
        console2.log("deploy block", blk, "time", block.timestamp);
        stock = new MockStock();
        vault = new KerneCashSecuredPutVault(
            USDC, IERC20(address(stock)), IAggregatorV3(address(TSLA_FEED)), "Kerne Cash Secured Put TSLAc", "kcpTSLAc", owner, keeper
        );
        vm.makePersistent(address(stock), address(vault), address(USDC));
        assertEq(vault.depositCap(), 0, "deploys closed");
        assertEq(vault.maxDeposit(lp), 0, "deploys closed");

        vm.prank(owner);
        vault.setParams(1_000_000e6, 25 hours, 300, 10, 1 days, 35 days, 3 days, 12 hours);
        deal(address(USDC), lp, 100_000e6);
        deal(address(USDC), buyer, 1_000e6);
        deal(address(USDC), hedger, 1_000e6);
        stock.mint(buyer, 10e8);
        stock.mint(hedger, 1e8);
        address[3] memory who = [lp, buyer, hedger];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(who[i]);
            USDC.approve(address(vault), type(uint256).max);
            stock.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lp);
        vault.deposit(100_000e6, lp);
        // the notice period after setParams is still running: no epoch can open yet
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(1, 100, block.timestamp + 1 hours, block.timestamp + 2 days);
    }

    function _openAndSell(uint80 round, uint256 ts) internal {
        uint256 blk = _blockAt(ts);
        (uint80 liveRound,,, uint256 liveUpd,) = TSLA_FEED.latestRoundData();
        assertEq(liveRound, round, "sale block does not sit on the chosen round");
        assertLt(block.timestamp - liveUpd, 1 hours, "feed not fresh at the sale block");
        assertTrue(vault.inSaleHours(), "sale block is outside sale hours");

        uint256 spot = vault.spotPrice();
        strike = spot * 95 / 100;
        expiry = headTs - 10 minutes; // at least one day after this block, already past at head
        console2.log("sale block", blk, "time", block.timestamp);
        console2.log("real spot", spot, "strike (5% below)", strike);
        vm.prank(keeper);
        vault.openEpoch(strike, 100, block.timestamp + 1 hours, expiry);
        vm.prank(buyer);
        prem = vault.buyPut(1, 10e8, type(uint256).max);
        vm.prank(hedger);
        prem += vault.buyPut(1, 1e8, type(uint256).max);
        assertEq(USDC.balanceOf(address(vault)), 100_000e6 + prem);
        assertEq(vault.totalAssets(), 100_000e6, "premium excluded while live");
    }

    /// @dev Rolls the fork to the first block at or after `ts`, found by measuring the real block
    ///      rate and correcting. Base block times are not assumed.
    function _blockAt(uint256 ts) internal returns (uint256 blk) {
        vm.rollFork(head - 50_000);
        uint256 per50k = headTs - block.timestamp; // seconds per 50,000 blocks
        blk = head - (headTs - ts) * 50_000 / per50k;
        for (uint256 i; i < 3; i++) {
            vm.rollFork(blk);
            if (block.timestamp == ts) break;
            if (block.timestamp > ts) blk -= (block.timestamp - ts) * 50_000 / per50k;
            else blk += (ts - block.timestamp) * 50_000 / per50k;
        }
        vm.rollFork(blk);
        // never land before `ts`: step forward until the block is at or after it
        while (block.timestamp < ts) {
            blk += 1 + (ts - block.timestamp) * 50_000 / per50k;
            vm.rollFork(blk);
        }
    }
}
