// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// esKERNE: forfeiture-on-exit can be bypassed on the vesting path
//
// Reported by:  SpokoDev (Yaroslav Hrydkovets), 2026-06-23, to
//               kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent; they also granted a public review
//               attestation on 2026-07-22)
// Fix commit:   8193babd (source), 2026-05-28 onward for the vesting-base class
// Status:       Fixed in source. Latent on chain and unreachable: esKERNE
//               0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34 reported
//               totalSupply() == 0 and totalEmitted() == 0 when read on Base
//               mainnet 2026-07-30. Nothing has ever been emitted, so there is
//               nothing to forfeit and nothing to bypass. It ships fixed with the
//               esKERNE v2 redeploy.
//
// The mechanism, in the deployed bundle:
//
//   vested(u)   = balanceOf[u] * elapsed / DURATION  -  claimed[u]
//   unvested(u) = balanceOf[u] - (vested(u) + claimed[u])
//
// `convert()` decrements `balanceOf` AND increments `claimed` for the same
// tokens. So after any partial conversion the vesting base has shrunk while
// `claimed` has grown, and `vested + claimed` reaches or exceeds the remaining
// balance. `unvested()` then returns zero for a holder who is still sitting on a
// locked position, and `forfeit()`, which returns early on a zero amount, takes
// nothing from them on exit.
//
// A holder who converts even one wei of vested esKERNE walks away from the vault
// with the rest of their locked balance intact. The prisoner's-dilemma mechanic
// the escrow exists to enforce simply does not bind.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { esKERNE } from "../../contracts/esKERNE/src/esKERNE.sol";
import { MockERC20 } from "../helpers/Mocks.sol";

contract EsKerneForfeitureOnExitTest is KerneTest {
    esKERNE internal escrow;
    MockERC20 internal kerne;

    address internal admin = makeAddr("safe");
    address internal emitter = makeAddr("emitterBot");
    address internal vaultRole = makeAddr("kerneVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant GRANT = 1_000e18;

    function setUp() public {
        _startClock(1_700_000_000);
        kerne = new MockERC20("Kerne", "KERNE", 18);

        vm.prank(admin);
        escrow = new esKERNE(address(kerne), admin, 10_000_000e18);

        vm.startPrank(admin);
        escrow.grantRole(escrow.EMITTER_ROLE(), emitter);
        escrow.grantRole(escrow.VAULT_ROLE(), vaultRole);
        vm.stopPrank();

        // Fund the conversion reserve so `convert()` can pay out.
        kerne.mint(address(escrow), 10_000_000e18);

        vm.startPrank(emitter);
        escrow.emitRewards(alice, GRANT);
        escrow.emitRewards(bob, GRANT); // a second holder, so forfeiture has somewhere to go
        vm.stopPrank();
    }

    /// @notice The control. Without touching `convert()`, forfeiture works exactly
    ///         as designed: half-way through the vest, half the grant is forfeited.
    function test_forfeitureWorksForAHolderWhoNeverConverted() public {
        _advance(182.5 days); // 50% of the 365-day vest

        assertEq(escrow.unvested(alice), GRANT / 2, "half the grant is still locked");

        vm.prank(vaultRole);
        escrow.forfeit(alice);

        assertEq(escrow.balanceOf(alice), GRANT / 2, "the locked half was taken on exit");
        assertEq(escrow.totalForfeited(), GRANT / 2);
    }

    /// @notice THE FINDING. Converting the vested half first makes the locked half
    ///         invisible to `unvested()`, and exit forfeits nothing at all.
    function test_KNOWN_partialConvertZeroesUnvestedAndDefeatsForfeiture() public {
        _advance(182.5 days);

        uint256 vestedNow = escrow.vested(alice);
        assertEq(vestedNow, GRANT / 2, "half has vested");

        // Alice takes her vested half, which is entirely legitimate.
        vm.prank(alice);
        escrow.convert(vestedNow);

        // She still holds the other half, and it is still inside the 365-day lock.
        assertEq(escrow.balanceOf(alice), GRANT / 2, "the locked half is still on her balance");

        // But the contract now believes none of it is locked.
        assertEq(escrow.unvested(alice), 0, "unvested() reports zero for a locked position");

        uint256 forfeitedBefore = escrow.totalForfeited();

        vm.prank(vaultRole);
        escrow.forfeit(alice);

        assertEq(escrow.totalForfeited(), forfeitedBefore, "forfeit() took nothing");
        assertEq(escrow.balanceOf(alice), GRANT / 2, "she exits with the locked half intact");
    }

    /// @notice The bypass is not an artefact of the exact halfway point. Converting
    ///         the vested amount anywhere at or past the midpoint of the vest
    ///         collapses `unvested()` to zero.
    function test_KNOWN_bypassHoldsAnywherePastTheMidpointOfTheVest() public {
        _advance(300 days); // ~82% through the 365-day vest

        uint256 vestedNow = escrow.vested(alice);
        vm.prank(alice);
        escrow.convert(vestedNow);

        assertGt(escrow.balanceOf(alice), 0, "she still holds esKERNE");
        assertEq(escrow.unvested(alice), 0, "and none of it counts as locked");
    }

    /// @notice Stated precisely rather than overstated: BEFORE the midpoint the
    ///         bypass is partial, not total. `unvested()` is understated by exactly
    ///         the converted amount, so exit forfeits less than it should without
    ///         forfeiting nothing. Recorded so nobody reads the tests above as
    ///         claiming a total bypass at every point on the curve.
    function test_KNOWN_beforeTheMidpointTheBypassIsPartialNotTotal() public {
        _advance(91.25 days); // 25% through the vest

        uint256 vestedNow = escrow.vested(alice); // 250e18
        vm.prank(alice);
        escrow.convert(vestedNow);

        uint256 remaining = escrow.balanceOf(alice); // 750e18, all of it still locked
        uint256 reportedLocked = escrow.unvested(alice);

        assertGt(reportedLocked, 0, "some of it is still seen as locked");
        assertLt(reportedLocked, remaining, "but less than the holder actually has locked");
        assertEq(reportedLocked, remaining - vestedNow, "understated by exactly what was converted");
    }

    /// @notice The other side of the same accounting: the holders who stayed get
    ///         nothing, because the forfeiture that should have been redistributed
    ///         to them never happened.
    function test_KNOWN_stayersReceiveNoRedistributionFromTheBypassedExit() public {
        _advance(182.5 days);

        uint256 vestedNow = escrow.vested(alice);
        vm.prank(alice);
        escrow.convert(vestedNow);

        uint256 bobEarnedBefore = escrow.earned(bob);

        vm.prank(vaultRole);
        escrow.forfeit(alice);

        assertEq(escrow.earned(bob), bobEarnedBefore, "the stayer is not compensated, because nothing was forfeited");
    }
}
