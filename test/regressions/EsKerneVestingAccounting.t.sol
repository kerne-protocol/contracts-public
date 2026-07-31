// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// esKERNE: vesting-accounting review of the escrowed-KERNE path
//
// Reported by:  Jay, 2026-06-24, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Status:       Fixed in source; ships with the esKERNE redeploy. Latent and
//               unreachable on chain: esKERNE 0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34
//               reported totalSupply() == 0 and totalEmitted() == 0 when read on
//               Base mainnet 2026-07-30, and its redemption token is the retired
//               KERNE v1. Nothing was ever emitted, so nothing can be stranded.
//
// The defect is a double subtraction. `vested()` computes the vested total from
// `balanceOf[user]`, which `convert()` has ALREADY decremented by everything the
// user claimed, and then subtracts `claimed[user]` again:
//
//   vestedTotal = balanceOf[u] * elapsed / DURATION
//   return vestedTotal - claimed[u]
//
// The correct base is `balanceOf + claimed` (the lifetime grant). Using the live
// balance means every conversion permanently lowers the ceiling of what can ever
// vest, and the residual esKERNE becomes unconvertible for the rest of time. The
// matching KERNE stays locked in the conversion reserve, which has no rescue path
// on this bundle.
//
// The same accounting is what defeats forfeiture on exit; that half is covered in
// EsKerneForfeitureOnExit.t.sol, reported independently by SpokoDev.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { esKERNE } from "../../contracts/esKERNE/src/esKERNE.sol";
import { MockERC20 } from "../helpers/Mocks.sol";

contract EsKerneVestingAccountingTest is KerneTest {
    esKERNE internal escrow;
    MockERC20 internal kerne;

    address internal admin = makeAddr("safe");
    address internal emitter = makeAddr("emitterBot");
    address internal alice = makeAddr("alice");

    uint256 internal constant GRANT = 1_000e18;
    uint256 internal constant RESERVE = 5_000e18;

    function setUp() public {
        _startClock(1_700_000_000);
        kerne = new MockERC20("Kerne", "KERNE", 18);

        vm.prank(admin);
        escrow = new esKERNE(address(kerne), admin, 10_000_000e18);

        // Cache the role id first: reading it is itself an external call and would
        // consume the prank, leaving grantRole to run as the test contract.
        bytes32 emitterRole = escrow.EMITTER_ROLE();
        vm.prank(admin);
        escrow.grantRole(emitterRole, emitter);

        kerne.mint(address(escrow), RESERVE);

        vm.prank(emitter);
        escrow.emitRewards(alice, GRANT);
    }

    /// @notice The control: a holder who never converts vests the full grant over
    ///         the 365 days, exactly as documented.
    function test_fullGrantVestsForAHolderWhoNeverConverts() public {
        _advance(365 days);
        assertEq(escrow.vested(alice), GRANT, "the whole grant vests on schedule");
    }

    /// @notice THE FINDING. After converting the vested half at the halfway point,
    ///         the remaining half never vests, no matter how long the holder waits.
    function test_KNOWN_partialConvertPermanentlyStrandsTheRemainder() public {
        _advance(182.5 days);

        uint256 firstClaim = escrow.vested(alice);
        assertEq(firstClaim, GRANT / 2);

        vm.prank(alice);
        escrow.convert(firstClaim);

        assertEq(escrow.balanceOf(alice), GRANT / 2, "she still holds half the grant");

        // Three quarters through the vest: correct accounting would have another
        // quarter of the grant available. It reports zero.
        _advance(91.25 days);
        assertEq(escrow.vested(alice), 0, "nothing further vests");

        // At full term, still zero. The remaining 500 esKERNE is unconvertible for good.
        _advance(365 days);
        assertEq(escrow.vested(alice), 0, "and it never will, even past full term");
        assertEq(escrow.balanceOf(alice), GRANT / 2, "the balance is real and permanently frozen");
    }

    /// @notice The consequence for the protocol side: the KERNE backing the
    ///         stranded esKERNE stays in the conversion reserve, and this bundle
    ///         exposes no way to recover it.
    function test_KNOWN_matchingKerneIsLockedInTheConversionReserveWithNoRescuePath() public {
        _advance(182.5 days);

        uint256 vestedNow = escrow.vested(alice);
        vm.prank(alice);
        escrow.convert(vestedNow);

        _advance(365 days);

        // Half the grant is owed on paper and can never be drawn.
        uint256 strandedClaim = escrow.balanceOf(alice);
        assertEq(strandedClaim, GRANT / 2);
        assertEq(escrow.vested(alice), 0);

        // The reserve still holds KERNE that is now matched to an unclaimable position.
        assertEq(kerne.balanceOf(address(escrow)), RESERVE - GRANT / 2, "reserve still funded");
        assertGt(escrow.conversionReserve(), strandedClaim, "and more than covers a claim nobody can make");

        // No admin sweep, no rescue: attempting one fails because it does not exist.
        (bool ok,) = address(escrow).call(abi.encodeWithSignature("rescueConversionReserve(uint256)", uint256(1)));
        assertFalse(ok, "the deployed bundle exposes no reserve rescue path");
    }

    /// @notice Pins the exact arithmetic, so a future edit that changes the base
    ///         from `balanceOf` to `balanceOf + claimed` fails here first and is
    ///         read as the fix rather than as a regression.
    function test_KNOWN_vestedUsesTheLiveBalanceAsItsBaseNotTheLifetimeGrant() public {
        _advance(182.5 days);

        vm.prank(alice);
        escrow.convert(100e18); // convert less than the full vested amount

        uint256 balance = escrow.balanceOf(alice); // 900e18
        uint256 claimed = escrow.claimed(alice); //  100e18

        // Deployed behaviour: base is the LIVE balance.
        uint256 deployedExpectation = (balance / 2) - claimed; // 450 - 100 = 350
        assertEq(escrow.vested(alice), deployedExpectation, "base is balanceOf, hence the double subtraction");

        // Correct behaviour would have been the lifetime grant as the base.
        uint256 correctExpectation = ((balance + claimed) / 2) - claimed; // 500 - 100 = 400
        assertGt(correctExpectation, deployedExpectation, "the gap is what the fix restores");
    }
}
