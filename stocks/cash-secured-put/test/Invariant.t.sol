// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KerneCashSecuredPutVault, IAggregatorV3} from "../src/KerneCashSecuredPutVault.sol";
import {MockStock, MockUSDC, MockFeed} from "./Mocks.sol";

/// @dev Drives random sequences of every public action against the vault.
contract Handler is Test {
    KerneCashSecuredPutVault public vault;
    MockUSDC public usdc;
    MockStock public stock;
    MockFeed public feed;
    address public keeper;
    address[] public lps;
    address[] public buyers;

    uint256 public delivered; // ghost: stock delivered through exercise
    uint256 public stockClaimed; // ghost: stock pulled by holders
    uint256 public cashPaid; // ghost: USDC paid on exercise
    uint256 public premiumIn; // ghost
    uint256 public deposited; // ghost
    uint256 public redeemed; // ghost
    uint256 public checkpoints; // ghost: holder checkpoints, each can floor away under one unit
    uint256 public settles;
    uint256 public exercises;
    uint256 public opens;
    uint256 public buys;

    constructor(KerneCashSecuredPutVault v, MockUSDC u, MockStock s, MockFeed f, address keeper_) {
        vault = v;
        usdc = u;
        stock = s;
        feed = f;
        keeper = keeper_;
        for (uint256 i; i < 3; i++) {
            lps.push(makeAddr(string(abi.encodePacked("lp", i))));
            buyers.push(makeAddr(string(abi.encodePacked("buyer", i))));
        }
        for (uint256 i; i < 3; i++) {
            usdc.mint(lps[i], 1_000_000e6);
            usdc.mint(buyers[i], 1_000_000e6);
            stock.mint(buyers[i], 100_000e8);
            vm.prank(lps[i]);
            usdc.approve(address(vault), type(uint256).max);
            vm.startPrank(buyers[i]);
            usdc.approve(address(vault), type(uint256).max);
            stock.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function lpCount() external view returns (uint256) {
        return lps.length;
    }

    /// next weekday 15:00 UTC at or after now, or now if already inside sale hours
    function _nextSaleTime() internal view returns (uint256 t) {
        if (vault.inSaleHours()) return block.timestamp;
        t = block.timestamp / 1 days * 1 days + 15 hours;
        if (t <= block.timestamp) t += 1 days;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) t += 1 days;
    }

    function deposit(uint256 who, uint256 amt) external {
        address lp = lps[who % 3];
        uint256 max = vault.maxDeposit(lp);
        if (max == 0) return;
        amt = bound(amt, 1, max > 200_000e6 ? 200_000e6 : max);
        vm.prank(lp);
        vault.deposit(amt, lp);
        deposited += amt;
        checkpoints++;
    }

    function redeem(uint256 who, uint256 frac) external {
        address lp = lps[who % 3];
        uint256 max = vault.maxRedeem(lp);
        if (max == 0) return;
        uint256 shares = bound(frac, 1, max);
        vm.prank(lp);
        redeemed += vault.redeem(shares, lp, lp);
        checkpoints++;
    }

    function transferShares(uint256 from, uint256 to, uint256 frac) external {
        if (vault.epochLive()) return;
        address a = lps[from % 3];
        address b = lps[to % 3];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        vault.transfer(b, bound(frac, 1, bal));
        checkpoints += 2;
    }

    function claimStock(uint256 who) external {
        address lp = lps[who % 3];
        if (vault.claimableStock(lp) == 0) return;
        vm.prank(lp);
        stockClaimed += vault.claimStock(lp);
        checkpoints++;
    }

    function pushPrice(uint256 px) external {
        feed.push(int256(bound(px, 150e8, 900e8)), block.timestamp);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 10 minutes, 12 hours));
    }

    function open(uint256 otmBps, uint256 premBps, uint256 saleDur, uint256 dur) external {
        _open(otmBps, premBps, saleDur, dur);
    }

    function _open(uint256 otmBps, uint256 premBps, uint256 saleDur, uint256 dur) internal {
        if (vault.epochLive()) return;
        if (vault.totalSupply() < vault.minSupply()) {
            // an epoch with nobody in it sells nothing: seed it so the campaign reaches sales
            uint256 max = vault.maxDeposit(lps[0]);
            if (max < 10_000e6) return;
            vm.prank(lps[0]);
            vault.deposit(10_000e6, lps[0]);
            deposited += 10_000e6;
            checkpoints++;
        }
        if (block.timestamp < vault.nextOpenAt()) vm.warp(vault.nextOpenAt());
        vm.warp(_nextSaleTime());
        (, int256 px,,,) = feed.latestRoundData();
        feed.push(px, block.timestamp);
        uint256 strike = uint256(px) * (10_000 - bound(otmBps, 300, 3_000)) / 10_000;
        dur = bound(dur, 1 days, 10 days);
        saleDur = bound(saleDur, 1 days, dur); // at least one more sale session after the open
        vm.prank(keeper);
        try vault.openEpoch(strike, bound(premBps, 10, 1_000), block.timestamp + saleDur, block.timestamp + dur) {
            opens++;
        } catch {}
    }

    function buy(uint256 who, uint256 notional, bool refresh) external {
        if (!vault.epochLive()) _open(notional, who, notional, who);
        if (!vault.epochLive()) return;
        uint256 id = vault.currentEpoch();
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(id);
        uint256 t = _nextSaleTime();
        if (t >= e.saleEnd) return;
        vm.warp(t);
        // most of the time the feed has just printed a price that keeps the put out of the money;
        // otherwise the sale runs against whatever the feed last said (and may be refused)
        if (refresh || who % 4 != 0) feed.push(int256(uint256(e.strike) * 10_000 / 9_700 + 1), block.timestamp);
        uint256 room = uint256(e.capacity) / 10;
        if (feed.latest() == vault.saleRound()) {
            uint256 used = vault.soldInRound();
            room = room > used ? room - used : 0;
        }
        if (room > uint256(e.capacity) - e.soldCash) room = uint256(e.capacity) - e.soldCash;
        uint256 maxN = room * 1e16 / (uint256(e.strike) * 1e6);
        if (maxN == 0) return;
        notional = bound(notional, maxN / 8 + 1, maxN);
        vm.prank(buyers[who % 3]);
        try vault.buyPut(id, notional, type(uint256).max) returns (uint256 p) {
            premiumIn += p;
            buys++;
        } catch {}
    }

    function transferPut(uint256 from, uint256 to, uint256 notional) external {
        if (!vault.epochLive()) return;
        address a = buyers[from % 3];
        uint256 held = vault.notionalOf(vault.currentEpoch(), a);
        if (held == 0) return;
        vm.prank(a);
        vault.transferPut(buyers[to % 3], bound(notional, 1, held));
    }

    function keeperTightens(bool endSale, uint256 bps) external {
        if (!vault.epochLive()) return;
        vm.prank(keeper);
        if (endSale) {
            try vault.closeSale() {} catch {}
        } else {
            try vault.raisePremium(bound(bps, 11, 2_000)) {} catch {}
        }
    }

    function exercise(uint256 who, uint256 notional, uint256 when) external {
        if (!vault.epochLive()) return;
        address b = buyers[who % 3];
        uint256 id = vault.currentEpoch();
        uint256 held = vault.notionalOf(id, b);
        if (held == 0) return;
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(id);
        if (block.timestamp < e.expiry) vm.warp(bound(when, e.expiry, e.exerciseEnd - 1));
        notional = bound(notional, 1, held);
        vm.prank(b);
        try vault.exercise(notional, b) returns (uint256 cash) {
            delivered += notional;
            cashPaid += cash;
            exercises++;
        } catch {}
    }

    function settle(uint8 mode) external {
        if (!vault.epochLive()) return;
        if (mode % 4 == 0) {
            uint256 end = vault.epochs(vault.currentEpoch()).exerciseEnd;
            if (block.timestamp < end) vm.warp(end);
        }
        try vault.settle() {
            settles++;
        } catch {}
    }
}

contract KerneCashSecuredPutVaultInvariant is Test {
    MockUSDC usdc;
    MockStock stock;
    MockFeed feed;
    KerneCashSecuredPutVault vault;
    Handler handler;

    function setUp() public {
        vm.warp(1_800_370_800 - 12 hours); // Tuesday 03:00 UTC
        usdc = new MockUSDC();
        stock = new MockStock();
        feed = new MockFeed();
        feed.push(400e8, block.timestamp);
        address owner = makeAddr("owner");
        address keeper = makeAddr("keeper");
        vault = new KerneCashSecuredPutVault(
            IERC20(address(usdc)), IERC20(address(stock)), IAggregatorV3(address(feed)), "Kerne Put", "kcp", owner, keeper
        );
        vm.prank(owner);
        vault.setParams(2_000_000e6, 25 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        handler = new Handler(vault, usdc, stock, feed, keeper);
        targetContract(address(handler));
    }

    /// Every put sold stays fully cash-secured: the vault always holds the unpaid strike cash of
    /// the live epoch on top of the unearned premium.
    function invariant_cashSecured() public view {
        uint256 id = vault.currentEpoch();
        if (id == 0) return;
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(id);
        assertLe(e.paid, e.soldCash);
        assertLe(e.soldCash, e.capacity);
        assertLe(e.exercised, e.sold);
        if (vault.epochLive()) {
            assertGe(usdc.balanceOf(address(vault)), uint256(e.premium) + (e.soldCash - e.paid) + vault.cashEscrow());
            assertLe(vault.soldInRound(), uint256(e.capacity) / 10);
        }
    }

    /// The vault always holds every unit of delivered stock that has not been pulled, holders are
    /// never credited more than was delivered, and nothing beyond rounding dust goes uncredited.
    function invariant_stockBackedAndFullyCredited() public view {
        assertGe(stock.balanceOf(address(vault)), vault.unclaimedStock());
        assertEq(vault.unclaimedStock(), handler.delivered() - handler.stockClaimed());
        uint256 owed;
        for (uint256 i; i < handler.lpCount(); i++) {
            owed += vault.claimableStock(handler.lps(i));
        }
        assertLe(owed, vault.unclaimedStock());
        // each holder checkpoint floors away under one unit, plus one unit in flight per holder
        assertGe(owed + handler.checkpoints() + handler.lpCount() + 1, vault.unclaimedStock());
    }

    /// Cash conservation: nothing leaves except exercise payouts and redemptions.
    function invariant_cashConserved() public view {
        assertEq(
            usdc.balanceOf(address(vault)),
            handler.deposited() + handler.premiumIn() - handler.cashPaid() - handler.redeemed()
        );
        assertLe(vault.totalSupply(), vault.MAX_SUPPLY());
    }

    /// Shows the campaign reached the paths that matter (run with -vv).
    function afterInvariant() public view {
        console2.log("opens", handler.opens(), "buys", handler.buys());
        console2.log("exercises", handler.exercises(), "settles", handler.settles());
        console2.log("delivered", handler.delivered(), "cash paid", handler.cashPaid());
    }
}
