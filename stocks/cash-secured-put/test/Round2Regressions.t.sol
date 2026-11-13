// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KerneCashSecuredPutVault, IAggregatorV3} from "../src/KerneCashSecuredPutVault.sol";
import {PutVaultFixture} from "./KerneCashSecuredPutVault.t.sol";

/// @dev Regressions for the second review round (reviewer C). Each scenario is the reviewer's own
///      proof of concept, now asserting the fixed behaviour.

// C-1: the supply floor was a share count that a donation to the empty vault could hold a funded
// vault under, so $1 could stop every sale. The floor is now the shares one unit of USDC mints at
// par, which any deposit larger than the donation clears.
contract DonationCannotStopSalesTest is PutVaultFixture {
    function _closedVault() internal returns (KerneCashSecuredPutVault v) {
        v = new KerneCashSecuredPutVault(
            IERC20(address(usdc)), IERC20(address(stock)), IAggregatorV3(address(feed)), "n", "s", owner, keeper
        );
    }

    function _openCapAndFill(KerneCashSecuredPutVault v) internal {
        vm.prank(owner);
        v.setParams(CAP, 25 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        vm.warp(T0 + 1 days); // Wednesday 15:00 UTC, notice period over, inside sale hours
        feed.push(SPOT, block.timestamp);
        usdc.mint(alice, CAP);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(v.maxDeposit(alice), alice); // fill the vault to its $1,000,000 cap
        vm.stopPrank();
    }

    function _sellsAndDelivers(KerneCashSecuredPutVault v) internal {
        vm.prank(keeper);
        uint256 id = v.openEpoch(K, 150, block.timestamp + 1 hours, block.timestamp + 1 days);
        assertEq(v.epochs(id).capacity, CAP, "the whole vault is for sale");
        vm.startPrank(buyer);
        usdc.approve(address(v), type(uint256).max);
        stock.approve(address(v), type(uint256).max);
        v.buyPut(id, 10 * ONE, type(uint256).max);
        vm.warp(v.epochs(id).expiry);
        v.exercise(10 * ONE, buyer);
        vm.stopPrank();
        assertApproxEqAbs(v.claimableStock(alice), 10 * ONE, 1_000, "and the depositor is credited the delivery");
        assertGt(v.claimableStock(alice), 10 * ONE * 9_998 / 10_000);
    }

    function test_donationToClosedVaultCannotStopSales() public {
        KerneCashSecuredPutVault v = _closedVault();
        assertEq(v.maxDeposit(alice), 0, "still closed");
        vm.prank(bob);
        usdc.transfer(address(v), 100 * USD); // the attack: one plain transfer into the closed vault
        _openCapAndFill(v);
        assertEq(v.totalAssets(), CAP);
        assertGe(v.totalSupply(), v.minSupply());
        _sellsAndDelivers(v);
    }

    function test_oneDollarDonationCannotStopAMillionDollarVault() public {
        KerneCashSecuredPutVault v = _closedVault();
        usdc.mint(address(this), 1_010_000);
        usdc.transfer(address(v), 1_010_000); // $1.01
        _openCapAndFill(v);
        _sellsAndDelivers(v);
    }

    function test_donationAfterTheVaultEmptiesCannotStopSales() public {
        uint256 s = _deposit(alice, 50_000 * USD);
        _open(K, 150);
        _buy(buyer, 10 * ONE);
        _toExerciseEnd();
        vault.settle();
        vm.prank(alice);
        vault.redeem(s, alice, alice); // everyone is out during the exit window
        assertEq(vault.totalSupply(), 0);
        vm.prank(buyer2);
        usdc.transfer(address(vault), 100 * USD); // the donation

        _toNextSale();
        _deposit(alice, 50_000 * USD);
        _deposit(bob, 50_000 * USD);
        uint256 id = _open(K, 150);
        assertGt(vault.epochs(id).capacity, 100_000 * USD - 1, "everything deposited is for sale");
        _buy(buyer2, 10 * ONE);
        assertEq(vault.epochs(id).sold, 10 * ONE);
    }

    /// The floor still does its job: a deposit smaller than the donation mints almost no shares,
    /// and an epoch over that vault sells nothing.
    function test_depositSmallerThanDonationSellsNothing() public {
        vm.prank(bob);
        usdc.transfer(address(vault), 5_000 * USD);
        _deposit(alice, 1 * USD);
        assertLt(vault.totalSupply(), vault.minSupply());
        uint256 id = _open(K, 150);
        assertEq(vault.epochs(id).capacity, 0);
    }
}

// C-2: one address acting as the dominant depositor and the only buyer could ratchet the share
// supply to its bound in about 14 self-dealt epochs for a few dollars, after which the vault
// refused deposits for as long as that address left anything in. The owner can now wind holders
// down once the share price has collapsed, which empties the vault and returns it to par.
contract WindDownTest is PutVaultFixture {
    uint256 constant K3 = 388e8; // exactly 3% below spot
    address attacker = makeAddr("attacker");

    function _selfDealtEpoch() internal {
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 hours, block.timestamp + 1 days);
        _buy(attacker, uint256(_ep().capacity) * 1e16 / (K3 * 1e6));
        _toExpiry();
        uint256 n = vault.notionalOf(vault.currentEpoch(), attacker);
        vm.startPrank(attacker);
        vault.exercise(n, attacker); // delivered although the put is 3% out of the money
        vault.settle(); // everything sold was exercised: early settle
        vault.claimStock(attacker);
        vm.stopPrank();
    }

    function _forceRetirement() internal returns (uint256 cycles) {
        usdc.mint(attacker, 102_000 * USD);
        stock.mint(attacker, 300 * ONE);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        _deposit(bob, 1_000 * USD); // an honest depositor who stays in throughout
        while (cycles < 40) {
            _toNextSale();
            uint256 d = Math.min(vault.maxDeposit(attacker), usdc.balanceOf(attacker) - 2_000 * USD);
            if (d < USD) break;
            _deposit(attacker, d);
            _selfDealtEpoch();
            cycles++;
        }
        _toNextSale();
        assertLt(vault.maxDeposit(alice), USD / 100, "the vault has stopped taking deposits");
    }

    function test_forcedRetirementIsNotPermanent() public {
        uint256 cycles = _forceRetirement();
        assertLt(cycles, 20);
        assertTrue(vault.windingDown());

        // The owner winds down the attacker, who would otherwise keep the vault shut for good.
        uint256 attackerValue = vault.previewRedeem(vault.balanceOf(attacker));
        assertGt(attackerValue, 0);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 bobStock = vault.claimableStock(bob);
        vm.prank(owner);
        uint256 parked = vault.windDown(attacker);
        assertEq(parked, attackerValue, "at exactly the price a redeem would have given");
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.escrowOf(attacker), parked);
        assertEq(vault.cashEscrow(), parked);
        assertEq(vault.balanceOf(bob), bobShares, "other holders are untouched");
        assertEq(vault.claimableStock(bob), bobStock, "and keep their delivered stock");
        assertLe(vault.totalAssets(), 5, "escrowed cash is no longer vault assets");

        // The supply is back far under the bound and the vault takes deposits again, although
        // the small holder never moved and the parked cash is still sitting in the vault.
        assertLt(vault.totalSupply(), vault.MAX_SUPPLY() / 1e20);
        assertFalse(vault.windingDown());
        assertGe(vault.maxDeposit(alice), 100_000 * USD);
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.NotWindingDown.selector);
        vault.windDown(bob); // the valve closes as soon as it is no longer needed
        _deposit(alice, 50_000 * USD);
        uint256 id = _open(K, 150);
        assertApproxEqAbs(vault.epochs(id).capacity, 50_000 * USD, 5, "escrow is not for sale");
        _buy(buyer, 100 * ONE);
        _toExpiry();
        _exercise(buyer, vault.notionalOf(id, buyer)); // assigned while the escrow is unclaimed
        assertGe(usdc.balanceOf(address(vault)), parked, "the parked cash is still there in full");

        // The holder who was wound down pulls what is theirs, mid-epoch, to any address.
        address cold = makeAddr("cold");
        vm.startPrank(attacker);
        vault.claimEscrow(cold);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToClaim.selector);
        vault.claimEscrow(cold);
        vm.stopPrank();
        assertEq(usdc.balanceOf(cold), parked);
        assertEq(vault.cashEscrow(), 0);
        _toExerciseEnd();
        vault.settle();
        vm.prank(alice);
        vault.claimStock(alice);
    }

    function test_windDownGuards() public {
        uint256 s = _deposit(alice, 10_000 * USD);
        // a healthy vault cannot be wound down, by anyone
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.NotWindingDown.selector);
        vault.windDown(alice);
        // not even after one full assignment
        _open(K, 100);
        _buy(buyer, _maxNotional(10_000 * USD));
        _toExpiry();
        _exercise(buyer, vault.notionalOf(1, buyer));
        vault.settle();
        assertFalse(vault.windingDown());
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.NotWindingDown.selector);
        vault.windDown(alice);
        assertEq(vault.balanceOf(alice), s);

        _forceRetirement();
        // only the owner
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.windDown(attacker);
        // never while an epoch is live
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 hours, block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.EpochIsLive.selector);
        vault.windDown(attacker);
        vm.warp(block.timestamp + 1 hours);
        vault.settle(); // nothing was sold
        vm.prank(owner);
        vault.windDown(attacker);
        // escrow can only be sent somewhere real, and only by the holder it belongs to
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.NothingToClaim.selector);
        vault.claimEscrow(owner);
        vm.startPrank(attacker);
        vm.expectRevert(KerneCashSecuredPutVault.BadRecipient.selector);
        vault.claimEscrow(address(vault));
        vm.expectRevert(KerneCashSecuredPutVault.BadRecipient.selector);
        vault.claimEscrow(address(0));
        vault.claimEscrow(attacker);
        vm.stopPrank();
        assertEq(vault.cashEscrow(), 0);
    }
}

// C-3: `exercise` wrote back a cached balance after the stock transfer and `transferPut` had no
// reentrancy guard, so a stock token with a sender hook let one put be exercised over and over.
// Not reachable with a B20 precompile, closed anyway.
interface ISendHook {
    function onStockSend() external;
}

contract HookStock is ERC20 {
    constructor() ERC20("Hook Stock", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// ERC-777 style: the sender is told before its tokens move
    function transferFrom(address from, address to, uint256 v) public override returns (bool) {
        if (from.code.length != 0) ISendHook(from).onStockSend();
        return super.transferFrom(from, to, v);
    }
}

contract ReentrantBuyer is ISendHook {
    KerneCashSecuredPutVault immutable vault;
    address public partner;
    uint8 mode; // 0 idle, 1 move the put, 2 exercise again, 3 claim stock

    constructor(KerneCashSecuredPutVault v, IERC20 usdc_, IERC20 stock_) {
        vault = v;
        usdc_.approve(address(v), type(uint256).max);
        stock_.approve(address(v), type(uint256).max);
    }

    function setPartner(address p) external {
        partner = p;
    }

    function buy(uint256 id, uint256 n) external {
        vault.buyPut(id, n, type(uint256).max);
    }

    function exerciseWithHook(uint256 n, uint8 mode_) external {
        mode = mode_;
        vault.exercise(n, address(this));
    }

    function onStockSend() external {
        uint8 m = mode;
        mode = 0;
        if (m == 1) vault.transferPut(partner, vault.notionalOf(vault.currentEpoch(), address(this)));
        if (m == 2) vault.exercise(1, address(this));
        if (m == 3) vault.claimStock(address(this));
    }
}

contract ExerciseReentrancyTest is PutVaultFixture {
    function test_hookTokenCannotReenter() public {
        HookStock hook = new HookStock();
        KerneCashSecuredPutVault v = new KerneCashSecuredPutVault(
            IERC20(address(usdc)), IERC20(address(hook)), IAggregatorV3(address(feed)), "n", "s", owner, keeper
        );
        vm.prank(owner);
        v.setParams(CAP, 25 hours, 300, 10, 1 days, 35 days, 1 days, 12 hours);
        vm.warp(T0 + 1 days);
        feed.push(SPOT, block.timestamp);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(3_800 * USD, alice); // secures 10 tokens at $380
        vm.stopPrank();

        ReentrantBuyer a = new ReentrantBuyer(v, IERC20(address(usdc)), IERC20(address(hook)));
        ReentrantBuyer b = new ReentrantBuyer(v, IERC20(address(usdc)), IERC20(address(hook)));
        a.setPartner(address(b));
        usdc.mint(address(a), 100 * USD);
        hook.mint(address(a), 5 * ONE);

        vm.prank(keeper);
        uint256 id = v.openEpoch(K, 150, block.timestamp + 1 hours, block.timestamp + 1 days);
        a.buy(id, ONE);
        vm.warp(v.epochs(id).expiry);

        // every way back in from inside the stock transfer is refused
        for (uint8 m = 1; m <= 3; m++) {
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            a.exerciseWithHook(ONE, m);
        }
        a.exerciseWithHook(ONE, 0); // a plain exercise still works
        KerneCashSecuredPutVault.Epoch memory e = v.epochs(id);
        assertEq(e.exercised, e.sold, "one put, exercised once");
        assertEq(e.paid, 380 * USD);
        assertEq(v.notionalOf(id, address(a)), 0);
        assertEq(v.notionalOf(id, address(b)), 0);
        assertEq(v.totalAssets(), 3_800 * USD - 380 * USD);
    }
}

// C-4: the notice for a parameter change used the new window, so a 7 day window could be
// replaced by 12 hours and an epoch opened 12 hours later.
contract NoticeUsesLongerWindowTest is PutVaultFixture {
    function test_shorteningTheWindowStillWaitsTheOldOne() public {
        _setParams(CAP, 300, 10, 1 days, 7 days);
        vm.warp(vault.nextOpenAt());
        _deposit(alice, 10_000 * USD);
        _setParams(CAP, 100, 10, 3 days, 12 hours); // looser terms and a 12 hour window
        assertEq(vault.nextOpenAt(), block.timestamp + 7 days, "the old 7 days still apply");
        vm.warp(block.timestamp + 12 hours);
        feed.push(SPOT, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(KerneCashSecuredPutVault.ExitWindowOpen.selector);
        vault.openEpoch(K, 100, block.timestamp + 1 days, block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        feed.push(SPOT, block.timestamp);
        _open(K, 100);
    }
}
