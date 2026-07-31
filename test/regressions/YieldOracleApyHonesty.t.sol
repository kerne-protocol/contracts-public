// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Yield oracle to vault linkage, and the honesty of the displayed APY
//
// Reported by:  Gaurang Maheta, 2026-06-16, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Status:       Addressed. The APY methodology and its public presentation were
//               hardened, including an independent-yield comparator.
//
// The report was about presentation as much as code: whether a displayed APY is
// actually derived from the vault, and whether it can be conjured out of thin
// air. That is not a fund-loss bug, and it is the kind of finding that usually
// gets a thank-you and no artefact.
//
// It deserves an artefact, because "our APY is derived, not asserted" is exactly
// the sort of claim a reader has no way to check. These tests pin the contract
// side of it: the oracle's yield number is a function of two real observations of
// the vault's own share price, it refuses to report anything without them, and it
// reports zero rather than a flattering number when the share price has not grown.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { KerneYieldOracle } from "../../contracts/KerneYieldOracle/src/KerneYieldOracle.sol";
import { SharePriceStub } from "../helpers/Mocks.sol";

contract YieldOracleApyHonestyTest is KerneTest {
    KerneYieldOracle internal oracle;
    SharePriceStub internal vault;

    address internal admin = makeAddr("admin");
    address internal updater = makeAddr("updater");

    function setUp() public {
        _startClock(1_700_000_000);

        vm.prank(admin);
        oracle = new KerneYieldOracle(admin);

        vault = new SharePriceStub(1e18);

        bytes32 updaterRole = oracle.UPDATER_ROLE();
        vm.startPrank(admin);
        oracle.grantRole(updaterRole, updater);
        // Single-signer consensus, so this file exercises the reporting maths
        // rather than the consensus DoS covered in YieldOracleConsensusBrick.t.sol.
        oracle.setRequiredConfirmations(1);
        vm.stopPrank();
    }

    function _record(uint256 sharePrice) internal {
        vault.setPrice(sharePrice);
        vm.prank(updater);
        oracle.updateYield(address(vault));
    }

    /// @notice With nothing recorded, the oracle reports zero. It does not
    ///         extrapolate, and it does not fall back to a configured number.
    function test_noObservationsMeansNoYield() public view {
        assertEq(oracle.getTWAY(address(vault)), 0, "an unobserved vault yields zero");
    }

    /// @notice One observation is still not a rate. A rate needs two points and a
    ///         time between them.
    function test_oneObservationIsStillNotARate() public {
        _record(1e18);
        assertEq(oracle.getTWAY(address(vault)), 0, "one point is not a rate");
    }

    /// @notice The reported figure is derived from the vault's own share price over
    ///         real elapsed time. 1% growth over 365 days annualises to 100 bps.
    function test_reportedYieldIsDerivedFromTheVaultsOwnSharePrice() public {
        _record(1e18);
        _advance(365 days);
        _record(1.01e18); // +1% over exactly one year

        uint256 apyBps = oracle.getTWAY(address(vault));
        assertApproxEqAbs(apyBps, 100, 1, "1% over a year reads as ~100 bps");
    }

    /// @notice Annualisation is real, not cosmetic: the same 1% over a quarter of
    ///         the time reports roughly four times the annualised rate.
    function test_annualisationScalesWithElapsedTime() public {
        _record(1e18);
        _advance(91.25 days); // a quarter of a year
        _record(1.01e18);

        uint256 apyBps = oracle.getTWAY(address(vault));
        assertApproxEqAbs(apyBps, 400, 2, "1% over a quarter annualises to ~400 bps");
    }

    /// @notice THE HONESTY PROPERTY. A flat share price reports zero, and a FALLING
    ///         share price reports zero rather than an absolute value or a wrap. The
    ///         oracle cannot be made to display a positive yield the vault did not
    ///         earn.
    function test_flatOrFallingSharePriceCannotProduceAPositiveYield() public {
        _record(1e18);
        _advance(180 days);
        _record(1e18); // flat
        assertEq(oracle.getTWAY(address(vault)), 0, "flat is zero, not noise");

        _advance(180 days);
        _record(0.99e18); // a real loss
        assertEq(oracle.getTWAY(address(vault)), 0, "a loss reports zero, never a positive number");
    }

    /// @notice The outlier guard: a share price that jumps more than 5% from the
    ///         last observation is rejected rather than recorded. Without this a
    ///         single bad reading becomes a headline APY.
    function test_outlierReadingsAreRejectedNotRecorded() public {
        _record(1e18);
        _advance(1 days);

        vault.setPrice(2e18); // a 100% jump
        vm.prank(updater);
        vm.expectRevert(bytes("Outlier rejected: Price deviation too high"));
        oracle.updateYield(address(vault));

        assertEq(oracle.maxPriceDeviationBps(), 500, "the band is 5%");
    }
}
