// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KerneCashSecuredPutVault} from "../src/KerneCashSecuredPutVault.sol";
import {PutVaultFixture} from "./KerneCashSecuredPutVault.t.sol";

/// @dev Regressions and pinned bounds from the third review round (reviewer D), which looked only
///      at the round-2 changes: the lower supply floor, the wind-down valve and its escrow.

abstract contract RatchetFixture is PutVaultFixture {
    uint256 constant K3 = 388e8; // exactly 3% below spot
    address whale = makeAddr("whale");

    function _fund(address who) internal {
        usdc.mint(who, 400_000 * USD);
        stock.mint(who, 2_000 * ONE);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// One epoch the whale sells to itself, delivering `exerciseBps` of what it bought.
    function _selfDealtEpoch(uint256 exerciseBps) internal {
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 hours, block.timestamp + 1 days);
        _buy(whale, uint256(_ep().capacity) * 1e16 / (K3 * 1e6));
        _toExpiry();
        uint256 n = vault.notionalOf(vault.currentEpoch(), whale) * exerciseBps / 10_000;
        vm.prank(whale);
        vault.exercise(n, whale);
        _toExerciseEnd();
        vault.settle();
        vm.prank(whale);
        vault.claimStock(whale);
    }

    function _ratio() internal view returns (uint256) {
        return vault.totalSupply() / (vault.totalAssets() + 1);
    }

    /// Brings the vault to the edge of winding down, lets three holders in with real money, then
    /// tips it over with one more 60% assignment. Everyone still holds about 40% of their deposit.
    function _windingDownWithRealHolders() internal {
        _fund(whale);
        _deposit(bob, 1_000 * USD); // an early depositor who never leaves
        while (_ratio() <= 5e29) {
            _toNextSale();
            _deposit(whale, 100_000 * USD);
            _selfDealtEpoch(_ratio() <= 1e26 ? 10_000 : 5_000); // full assignments, then halves
        }
        assertFalse(vault.windingDown(), "not yet");
        _toNextSale();
        _deposit(alice, 50_000 * USD);
        _deposit(buyer2, 30_000 * USD);
        _deposit(whale, 20_000 * USD);
        _selfDealtEpoch(6_000);
        assertTrue(vault.windingDown(), "the valve is open");
        _toNextSale();
    }
}

contract WindDownHardeningTest is RatchetFixture {
    /// D-1: a holder cannot dodge `windDown` by hopping to a fresh address, and nobody can add
    /// to the supply, while the vault is winding down. Leaving is always possible.
    function test_windDownCannotBeDodged() public {
        _windingDownWithRealHolders();
        address fresh = makeAddr("fresh");
        uint256 bal = vault.balanceOf(whale);
        vm.prank(whale);
        vm.expectRevert(KerneCashSecuredPutVault.WindingDown.selector);
        vault.transfer(fresh, bal);
        vm.prank(whale);
        vault.approve(fresh, bal);
        vm.prank(fresh);
        vm.expectRevert(KerneCashSecuredPutVault.WindingDown.selector);
        vault.transferFrom(whale, fresh, bal);

        assertEq(vault.maxDeposit(fresh), 0);
        assertEq(vault.maxMint(fresh), 0);
        _fund(fresh);
        vm.prank(fresh);
        vm.expectRevert();
        vault.deposit(1_000 * USD, fresh);

        uint256 value = vault.previewRedeem(bal);
        vm.prank(owner);
        assertEq(vault.windDown(whale), value, "the owner's call lands on the whole position");
        assertEq(vault.balanceOf(whale), 0);

        // anyone else can still simply leave
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        assertGt(vault.redeem(aliceShares, alice, alice), 15_000 * USD);
    }

    /// D-2: a wind-down pays exactly the redeem price, leaves every other holder whole, keeps the
    /// escrow fully backed and outside every epoch's capacity, and the escrow can be pulled in
    /// the middle of a live epoch without touching put collateral.
    function test_windDownIsExactlyARedeemAndEscrowIsOutsideCapacity() public {
        _windingDownWithRealHolders();
        uint256 aliceVal = vault.previewRedeem(vault.balanceOf(alice));
        uint256 b2Val = vault.previewRedeem(vault.balanceOf(buyer2));
        uint256 whaleVal = vault.previewRedeem(vault.balanceOf(whale));
        uint256 bobStock = vault.claimableStock(bob);
        uint256 taBefore = vault.totalAssets();
        assertGt(aliceVal, 15_000 * USD, "a real position");

        vm.prank(owner);
        uint256 parked = vault.windDown(alice);
        assertEq(parked, aliceVal, "the redeem price, to the unit");
        assertEq(vault.totalAssets(), taBefore - parked);
        assertEq(usdc.balanceOf(address(vault)), vault.totalAssets() + vault.cashEscrow(), "escrow fully backed");
        uint256 b2After = vault.previewRedeem(vault.balanceOf(buyer2));
        assertGe(b2After, b2Val, "remaining holders are never worse off");
        assertLe(b2After, b2Val + 1, "and better by at most the unit of rounding");
        assertGe(vault.previewRedeem(vault.balanceOf(whale)), whaleVal);
        assertEq(vault.claimableStock(bob), bobStock);
        assertTrue(vault.windingDown(), "a pro rata exit leaves the valve open for the rest");

        // An epoch over the rest: escrow is not capacity, and pulling it mid-epoch leaves every
        // put fully collateralised.
        uint256 id = _open(K, 150);
        uint256 cap = vault.epochs(id).capacity;
        assertEq(cap, taBefore - parked, "capacity excludes the escrow");
        usdc.mint(buyer, 50_000 * USD);
        stock.mint(buyer, 1_000 * ONE);
        _buy(buyer, _maxNotional(cap));
        vm.prank(alice);
        assertEq(vault.claimEscrow(alice), parked);
        assertEq(vault.cashEscrow(), 0);
        KerneCashSecuredPutVault.Epoch memory e = vault.epochs(id);
        assertGe(usdc.balanceOf(address(vault)), uint256(e.soldCash) + e.premium, "strike cash still all there");
        _toExpiry();
        _exercise(buyer, vault.notionalOf(id, buyer)); // the whole epoch is assigned
        _toExerciseEnd();
        vault.settle();

        // Wind everybody down: the vault takes deposits again.
        address[4] memory rest = [whale, buyer2, bob, alice];
        vm.startPrank(owner);
        for (uint256 i; i < rest.length; i++) {
            if (vault.windingDown()) vault.windDown(rest[i]);
        }
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), vault.totalAssets() + vault.cashEscrow());
        assertFalse(vault.windingDown());
        assertGe(vault.maxDeposit(alice), 100_000 * USD);
    }

    /// D-3: any mix of forced wind-downs, voluntary redemptions and escrow claims, in any order,
    /// hands every holder exactly their redeem value and conserves the vault's cash.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_windDownAnyOrderConservesCash(uint256 seed) public {
        _windingDownWithRealHolders();
        address[4] memory holders = [alice, buyer2, whale, bob];
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        uint256 owed; // what the four positions are worth before anyone moves
        for (uint256 i; i < 4; i++) {
            owed += vault.previewRedeem(vault.balanceOf(holders[i]));
        }
        uint256 paidOut;
        for (uint256 step; step < 12; step++) {
            address h = holders[uint256(keccak256(abi.encode(seed, step))) % 4];
            uint256 action = uint256(keccak256(abi.encode(seed, step, "a"))) % 3;
            uint256 shares = vault.balanceOf(h);
            if (action == 0 && shares > 0 && vault.windingDown()) {
                uint256 expect = vault.previewRedeem(shares);
                vm.prank(owner);
                assertEq(vault.windDown(h), expect);
            } else if (action == 1 && shares > 0) {
                vm.prank(h);
                paidOut += vault.redeem(shares, h, h);
            } else if (vault.escrowOf(h) > 0) {
                vm.prank(h);
                paidOut += vault.claimEscrow(h);
            }
            assertEq(usdc.balanceOf(address(vault)), vault.totalAssets() + vault.cashEscrow(), "books balance");
            assertEq(usdc.balanceOf(address(vault)), balanceBefore - paidOut, "only holders were paid");
        }
        // finish: everyone out, every escrow pulled
        for (uint256 i; i < 4; i++) {
            address h = holders[i];
            uint256 shares = vault.balanceOf(h);
            vm.startPrank(h);
            if (shares > 0) paidOut += vault.redeem(shares, h, h);
            if (vault.escrowOf(h) > 0) paidOut += vault.claimEscrow(h);
            vm.stopPrank();
        }
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.cashEscrow(), 0);
        assertLe(paidOut, owed + 8, "nobody was paid more than their position, bar rounding");
        assertGe(paidOut + 8, owed, "and nobody less");
        assertLe(usdc.balanceOf(address(vault)), 16, "only rounding dust stays behind");
    }

    /// The valve is shut in every ordinary state: a new vault, an empty vault holding a donation,
    /// and a vault of any size right after a full assignment at the minimum 10 bps premium.
    function testFuzz_valveShutInOrdinaryStates(uint256 amt, uint256 donation) public {
        amt = bound(amt, 1, CAP / 2);
        donation = bound(donation, 0, CAP / 2 - 1);
        assertFalse(vault.windingDown());
        usdc.mint(address(vault), donation);
        assertFalse(vault.windingDown());
        usdc.mint(alice, amt);
        _deposit(alice, amt);
        vm.prank(keeper);
        vault.openEpoch(K3, 10, block.timestamp + 1 days, block.timestamp + 7 days);
        // ten per-round slices, each rounded down, so the reservations fit the capacity
        uint256 n = 10 * (uint256(_ep().capacity) / 10 * 1e16 / (K3 * 1e6));
        usdc.mint(buyer, amt + donation);
        stock.mint(buyer, n);
        _buy(buyer, n);
        _toExpiry();
        uint256 held = vault.notionalOf(vault.currentEpoch(), buyer);
        if (held != 0) {
            vm.prank(buyer);
            try vault.exercise(held, buyer) {} catch {}
        }
        _toExerciseEnd();
        vault.settle();
        assertFalse(vault.windingDown());
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.NotWindingDown.selector);
        vault.windDown(alice);
    }

    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(KerneCashSecuredPutVault.Disabled.selector);
        vault.renounceOwnership();
        vm.expectRevert();
        vault.renounceOwnership(); // not the owner
        // handing it over in two steps still works
        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), owner);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }
}

/// Bounds of the per-share stock credit at the supply floor (1e6 shares).
contract MinSupplyBoundsTest is PutVaultFixture {
    /// supply == minSupply exactly, with `2 * half + 1` USDC behind it
    function _vaultAtTheFloor(uint256 half) internal {
        usdc.mint(address(vault), half); // donation to the empty vault
        usdc.mint(alice, half + 1);
        _deposit(alice, half + 1);
        assertEq(vault.totalSupply(), vault.minSupply(), "supply sits exactly on the floor");
    }

    /// $1,000,000 behind 1e6 shares, an honest strike, the whole epoch assigned: the credit works
    /// and uses about 2.3e-12 of the accumulator's range.
    function test_fullAssignmentAtTheSupplyFloor() public {
        _vaultAtTheFloor(CAP / 2 - 1);
        uint256 id = _open(K, 150);
        uint256 n = _maxNotional(vault.epochs(id).capacity);
        usdc.mint(buyer, 20_000 * USD);
        stock.mint(buyer, n);
        _buy(buyer, n);
        _toExpiry();
        uint256 held = vault.notionalOf(id, buyer);
        _exercise(buyer, held);
        assertEq(vault.claimableStock(alice), held, "credited in full, no dust at this supply");
        uint256 acc = vault.accStockPerShare();
        assertEq(acc, held * 1e54);
        assertGt(type(uint256).max / acc, 4e11, "over 4e11 such epochs of headroom");
    }

    /// The exact limit: exercise starts to revert once the notional delivered per share, summed
    /// over the vault's life, reaches 2^256 / 1e60 = 1.158e17. At 1e6 shares that is 1.158e23
    /// stock units, 1.158e15 whole tokens. Reaching it here takes a keeper who lists a strike of
    /// $0.00000001, $12,000,000 behind 1e6 shares, and hundreds of thousands of times every
    /// Tesla share in existence. Not reachable; the test only pins the number.
    function test_overflowBoundIsWhereTheMathSaysItIs() public {
        _setParams(type(uint88).max, 300, 10, 1 days, 12 hours);
        _toNextSale();
        _vaultAtTheFloor(6e12);
        uint256 id = _open(1, 10); // strike = 1e-8 USD
        uint256 n = uint256(vault.epochs(id).capacity) * 1e10; // 1.2e23 units
        usdc.mint(buyer, 100_000 * USD);
        stock.mint(buyer, n);
        _buy(buyer, n);
        _toExpiry();
        uint256 held = vault.notionalOf(id, buyer);
        assertGt(held, 1.158e23);
        vm.startPrank(buyer);
        vm.expectRevert(); // mulDiv overflow: more than 1.158e17 per share in one delivery
        vault.exercise(held, buyer);
        vault.exercise(1.15e23, buyer); // just under the bound: fine
        vm.expectRevert(); // the running total would overflow
        vault.exercise(held - 1.15e23, buyer);
        vm.stopPrank();
    }
}
