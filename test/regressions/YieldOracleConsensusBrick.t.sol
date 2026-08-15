// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Yield oracle: denial of service in the multi-party consensus path
//
// Reported by:  Gaurang Maheta, 2026-05-16, to kerne.systems@protonmail.com.
//               Then independently by @Olamdeen, 2026-07-04. Then again by three
//               researchers in the 2026-07-29 disclosure burst and by a fourth on
//               2026-07-31; of those four, only Abhinav Raj and Dmitriy Filatov
//               have confirmed public credit, so the rest are recorded here and
//               deliberately not named.
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with each researcher's consent, and only with it)
//
// CREDIT CORRECTION, 2026-08-14. This header named @Olamdeen alone as the
// reporter from the day it was published. Gaurang Maheta reported the same defect
// SEVEN WEEKS EARLIER, on 2026-05-16, and was not named here at all. The order
// above was established first-hand from the disclosure mailbox on 2026-08-06; the
// error was known internally from 2026-07-31 and went unfixed here for two weeks.
// The correction was promised in writing on 2026-08-06 to the three researchers
// who had been told their reports duplicated an earlier one, because telling a
// researcher their finding is a duplicate is only honest if the earlier report is
// identified correctly. Two of those three, Abhinav Raj and Dmitriy Filatov, have
// confirmed public credit and are named; the third has not, and is not. It is
// owed to Gaurang Maheta on its own terms as well: he was first, and this file is
// where that is recorded. @Olamdeen's credit is unchanged. He found it independently and is
// second on the timeline, not displaced from it.
//
// Status:       Fixed in source. Nothing has ever been recorded through this path
//               on the live oracle, KerneYieldOracle
//               0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB: at Base block
//               49,986,375 on 2026-08-14, `observations(vault, 0)` REVERTS, so the
//               array is empty and there is no first observation for a second
//               round to have been locked out of, and `getTWAY(vault)` returns 0.
//               The fix ships with the next oracle deployment.
//
// WITHDRAWN, 2026-08-14, and named to Dmitriy Filatov as a framing this file got
// wrong: the paragraph above used to cite `isRegistered(vault) == false` as part
// of the same argument. `isRegistered` is a public mapping that `updateYield`
// never reads. Its value bounds nothing, because an unregistered vault can be
// proposed on, confirmed on and recorded against exactly like a registered one.
// Citing it made the safety argument look broader than it is. Two facts do the
// bounding instead: the empty observation array above, and the confirmer set,
// where `requiredConfirmations()` is 3 while the operational hot wallet
// 0x09a2780a...A37e is the only address confirmed to hold UPDATER_ROLE, and a
// lone updater stalls at two (`test_KNOWN_soloUpdaterStallsAtTwoConfirmations`
// below). This oracle uses plain AccessControl, which is not enumerable, so role
// holders cannot be listed exhaustively from chain. The empty observation array
// is the fact that does not depend on that, which is why it leads.
//
// The finding, stated exactly: `Proposal` holds a `mapping(address => bool)
// hasConfirmed`. Solidity's `delete` does not clear mappings inside a struct, so
// the `delete pendingProposals[vault]` that runs on a SUCCESSFUL round leaves
// every confirmer permanently flagged. From the second round onward every
// confirmation by one of those addresses reverts `AlreadyConfirmed`, the proposal
// can never reach `requiredConfirmations`, and no further observation is
// recorded.
//
// CORRECTED, 2026-08-14, also to Dmitriy Filatov. This paragraph used to close
// "It reports 0% yield forever." Two things are wrong with that sentence, and one
// of them makes the defect worse rather than milder:
//
//   1. `getTWAY` does not report a yield of zero. It returns the integer 0, and
//      it returns that same 0 for at least four unrelated reasons: fewer than two
//      observations, a zero time delta, a share price that did not rise, and a
//      growth ratio that rounds away. A consumer cannot tell "this oracle is
//      bricked" from "the vault earned nothing" by reading the return value,
//      because the two are indistinguishable at the ABI. That is a worse property
//      than a wrong number would be, and it is why nothing kerne.fi publishes
//      reads `getTWAY` for an APY.
//   2. "Forever" overstates it. `hasConfirmed` is flagged PER ADDRESS, so the
//      lock binds only the addresses that already confirmed. DEFAULT_ADMIN_ROLE
//      escapes it two ways, both ordinary and both proven below: grant
//      UPDATER_ROLE to enough addresses that have never confirmed, or call
//      `setRequiredConfirmations`. This is a denial of service that persists
//      until an admin acts, not an unrecoverable brick, and it should be read as
//      the first.
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

        // Consensus is unreachable for THIS confirmer set. There is still exactly
        // one observation, and there will be no second one until the set changes.
        vm.expectRevert();
        oracle.observations(_vault(), 1);

        // And `getTWAY` returns 0, which is the same value it returns for a vault
        // that simply earned nothing. See the header: the caller cannot tell the
        // two apart, which is the part of this finding that survives the fix
        // landing on the confirmation logic.
        assertEq(oracle.getTWAY(_vault()), 0, "getTWAY needs two observations and has one");
    }

    /// @notice The first half of the "forever" correction, made executable rather
    ///         than left as prose. The lock is per address, so an admin who grants
    ///         UPDATER_ROLE to addresses that have never confirmed gets consensus
    ///         back on the very next round. Recorded because the original header
    ///         called this permanent, and a researcher reading that would size the
    ///         severity wrong.
    function test_theLockIsPerAddressAndFreshConfirmersEscapeIt() public {
        vm.prank(u1);
        oracle.updateYield(_vault());
        vm.prank(u2);
        oracle.updateYield(_vault());
        vm.prank(u3);
        oracle.updateYield(_vault());

        _advance(2 hours);

        address u4 = makeAddr("updater4");
        address u5 = makeAddr("updater5");
        address u6 = makeAddr("updater6");
        vm.startPrank(admin);
        oracle.grantRole(oracle.UPDATER_ROLE(), u4);
        oracle.grantRole(oracle.UPDATER_ROLE(), u5);
        oracle.grantRole(oracle.UPDATER_ROLE(), u6);
        vm.stopPrank();

        vm.prank(u4);
        oracle.updateYield(_vault()); // proposes, confirmations = 1
        vm.prank(u5);
        oracle.updateYield(_vault()); // never confirmed before, so this lands
        vm.prank(u6);
        oracle.updateYield(_vault()); // consensus reached

        (, uint256 price) = oracle.observations(_vault(), 1);
        assertEq(price, 1e18, "a second observation is recorded, so the oracle is not permanently bricked");
    }

    /// @notice The second half. `setRequiredConfirmations` is a DEFAULT_ADMIN_ROLE
    ///         setter, and at 1 a proposal satisfies itself on creation, so the
    ///         stale flags never get consulted. Cheaper than rotating the set, and
    ///         it costs the entire consensus property, which is exactly why it is
    ///         recorded here rather than recommended.
    function test_theLockIsAlsoEscapedByLoweringRequiredConfirmations() public {
        vm.prank(u1);
        oracle.updateYield(_vault());
        vm.prank(u2);
        oracle.updateYield(_vault());
        vm.prank(u3);
        oracle.updateYield(_vault());

        _advance(2 hours);

        vm.prank(admin);
        oracle.setRequiredConfirmations(1);

        vm.prank(u2); // still flagged from round one, and it no longer matters
        oracle.updateYield(_vault());

        (, uint256 price) = oracle.observations(_vault(), 1);
        assertEq(price, 1e18, "a single-signer round records, so the DoS is admin-recoverable");
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
