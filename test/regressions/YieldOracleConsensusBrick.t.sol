// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Yield oracle: denial of service in the multi-party consensus path
//
// Reported by:  @Olamdeen, 2026-07-04, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Status:       Fixed in source. No live impact, because the live oracle records
//               nothing through this path: read at Base mainnet on 2026-07-30,
//               KerneYieldOracle 0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB
//               returns getTWAY(vault) == 0, has no observation at index 0, and
//               isRegistered(vault) is false. The fix ships with the next oracle
//               deployment. Publishing the mechanism is safe precisely because
//               there is nothing live behind it.
//
// The finding, stated exactly: `Proposal` holds a `mapping(address => bool)
// hasConfirmed`. Solidity's `delete` does not clear mappings inside a struct, so
// the `delete pendingProposals[vault]` that runs on a SUCCESSFUL round leaves
// every confirmer permanently flagged. From the second round onward every
// confirmation reverts `AlreadyConfirmed`, the proposal can never reach
// `requiredConfirmations`, and no further observation is ever recorded.
//
// The oracle therefore accepts exactly one observation in its lifetime per set of
// confirmers, and `getTWAY` needs two. It reports 0% yield forever.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { KerneYieldOracle } from "../../contracts/KerneYieldOracle/src/KerneYieldOracle.sol";
import { SharePriceStub } from "../helpers/Mocks.sol";

contract YieldOracleConsensusBrickTest is KerneTest {
    KerneYieldOracle internal oracle;
    SharePriceStub internal vault;

    address internal admin = makeAddr("admin");
    address internal u1 = makeAddr("updater1");
    address internal u2 = makeAddr("updater2");
    address internal u3 = makeAddr("updater3");

    function setUp() public {
        _startClock(1_700_000_000);
        vm.prank(admin);
        oracle = new KerneYieldOracle(admin);

        vault = new SharePriceStub(1e18);

        vm.startPrank(admin);
        oracle.grantRole(oracle.UPDATER_ROLE(), u1);
        oracle.grantRole(oracle.UPDATER_ROLE(), u2);
        oracle.grantRole(oracle.UPDATER_ROLE(), u3);
        vm.stopPrank();
    }

    function _vault() internal view returns (address) {
        return address(vault);
    }

    /// @notice The first round works exactly as designed. This is the control.
    function test_firstConsensusRoundSucceeds() public {
        assertEq(oracle.requiredConfirmations(), 3, "three-of-N consensus by default");

        vm.prank(u1);
        oracle.updateYield(_vault()); // proposes, confirmations = 1

        vm.prank(u2);
        oracle.updateYield(_vault()); // confirmations = 2

        vm.prank(u3);
        oracle.updateYield(_vault()); // confirmations = 3 -> recorded

        (uint256 ts, uint256 price) = oracle.observations(_vault(), 0);
        assertEq(price, 1e18, "the first observation is recorded");
        assertGt(ts, 0);
    }

    /// @notice THE FINDING. The second round can never complete, because the
    ///         confirmers from round one are still flagged as having confirmed.
    function test_KNOWN_oracleBricksAfterTheFirstSuccessfulRound() public {
        // Round one, as above.
        vm.prank(u1);
        oracle.updateYield(_vault());
        vm.prank(u2);
        oracle.updateYield(_vault());
        vm.prank(u3);
        oracle.updateYield(_vault());

        // Move past the one-hour proposal window so a genuinely fresh proposal opens.
        _advance(2 hours);

        // u1 opens round two. It never confirmed in round one (the proposer is not
        // recorded as a confirmer), so this succeeds and sets confirmations = 1.
        vm.prank(u1);
        oracle.updateYield(_vault());

        // u2 and u3 are still flagged from round one. `delete pendingProposals[vault]`
        // reset sharePrice, timestamp and confirmations, but left the mapping intact.
        vm.prank(u2);
        vm.expectRevert(KerneYieldOracle.AlreadyConfirmed.selector);
        oracle.updateYield(_vault());

        vm.prank(u3);
        vm.expectRevert(KerneYieldOracle.AlreadyConfirmed.selector);
        oracle.updateYield(_vault());

        // Consensus is unreachable. There is still exactly one observation, and
        // there always will be.
        vm.expectRevert();
        oracle.observations(_vault(), 1);

        // Which is what the live contract shows: a TWAY of zero, forever.
        assertEq(oracle.getTWAY(_vault()), 0, "getTWAY needs two observations and will never get them");
    }

    /// @notice The second leg of the same finding: a share price that moves inside
    ///         the one-hour window blocks consensus for that window outright. On a
    ///         yield-bearing vault the price moves every block, so in production the
    ///         window is almost never quiet enough to agree in.
    function test_KNOWN_anyPriceDriftInsideTheWindowBlocksConsensus() public {
        vm.prank(u1);
        oracle.updateYield(_vault()); // proposal pinned at 1e18

        // One wei of yield accrues. Well inside the 5% outlier band, so this is a
        // perfectly ordinary reading, not an attack.
        vault.setPrice(1e18 + 1);

        vm.prank(u2);
        vm.expectRevert(KerneYieldOracle.ConsensusMismatch.selector);
        oracle.updateYield(_vault());
    }

    /// @notice A single updater cannot self-confirm to consensus either: it reaches
    ///         two and is then locked out of its own proposal. Recorded so nobody
    ///         "fixes" the DoS by cutting the updater set to one.
    function test_KNOWN_soloUpdaterStallsAtTwoConfirmations() public {
        vm.startPrank(u1);
        oracle.updateYield(_vault()); // proposes, confirmations = 1
        oracle.updateYield(_vault()); // confirms own proposal, confirmations = 2

        vm.expectRevert(KerneYieldOracle.AlreadyConfirmed.selector);
        oracle.updateYield(_vault());
        vm.stopPrank();

        vm.expectRevert();
        oracle.observations(_vault(), 0);
    }

    /// @notice Guards the assumption the whole file rests on: the oracle's only call
    ///         into a registered vault is `convertToAssets(1e18)`, which is why a stub
    ///         is an honest stand-in here rather than a shortcut. If the oracle ever
    ///         starts reading something else, the stub stops answering and this test
    ///         is the one that says so.
    function test_oracleOnlyReadsSharePriceFromTheVault() public {
        vault.setPrice(2e18);

        vm.prank(u1);
        oracle.updateYield(_vault());
        vm.prank(u2);
        oracle.updateYield(_vault());
        vm.prank(u3);
        oracle.updateYield(_vault());

        (, uint256 price) = oracle.observations(_vault(), 0);
        assertEq(price, 2e18, "the recorded observation is exactly convertToAssets(1e18)");
    }
}
