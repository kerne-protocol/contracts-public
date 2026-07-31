// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Mint routing: stale-quote handling in the mint flow
//
// Reported by:  Ekankaar, 2026-06-25, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Status:       FIXED AND LIVE. The guard this file locks is the PSM's oracle
//               staleness window on the mint path, hardened across
//               KRN-26-PSM-DEPEG-FAIL-OPEN (2026-06-10) and
//               KRN-26-PSM-ORACLE-HEARTBEAT (2026-06-11). The live mint PSM
//               0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803 was deployed
//               2026-07-10 from the frozen audit commit and carries both.
//
// Three properties are being pinned, and they pull against each other, which is
// why the shape of the fix matters more than its existence:
//
//   1. FAIL CLOSED. An unset oracle used to mean "skip the depeg check", and that
//      was the live default, so the mint path ran with no depeg gate at all. It
//      now reverts unless the Safe explicitly opts out with an event-logged flag.
//   2. STALE PRICES ARE REJECTED. A quote older than the window cannot mint.
//   3. THE WINDOW IS BOUNDED, BUT NOT ONE SIZE. Chainlink's USDC/USD feed on Base
//      updates on ~0.3% deviation or a 24h heartbeat, so its answer is routinely
//      many hours old. A hardcoded 1h bound would have reverted roughly 96% of
//      honest swaps: a bricked PSM. The window is per-stable and manager-set, and
//      capped at MAX_ORACLE_DELAY_BOUND so it can never become a de-facto disable.
//
// Property 3 is the one worth having a test for. It is the point where a
// staleness guard is usually either useless or accidentally a denial of service.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { KUSDPSM } from "../../contracts/KUSDPSM/src/KUSDPSM.sol";
import { kUSD } from "../../contracts/kUSD/src/kUSD.sol";
import { MockERC20, MockAggregatorV3 } from "../helpers/Mocks.sol";

contract MintRoutingStaleQuoteTest is KerneTest {
    KUSDPSM internal psm;
    kUSD internal kusd;
    MockERC20 internal usdc;
    MockAggregatorV3 internal feed;

    address internal admin = makeAddr("safe");
    address internal user = makeAddr("user");

    uint256 internal constant SWAP = 1_000e6; // 1,000 USDC, 6 decimals

    function setUp() public {
        _startClock(1_700_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        kusd = new kUSD(admin);
        psm = new KUSDPSM(address(kusd), admin);
        feed = new MockAggregatorV3(1e8, 8); // $1.00, 8 decimals, fresh

        bytes32 minter = kusd.MINTER_ROLE();
        vm.startPrank(admin);
        kusd.grantRole(minter, address(psm));
        psm.addStable(address(usdc), 10, 10_000_000e6); // 10 bps fee, 10M cap
        psm.setMintingEnabled(true);
        // Mirrors the live PSM's configuration, where the vault-side solvency gate
        // is explicitly opted out rather than left at a sentinel value.
        psm.setSolvencyCheckDisabled(true);
        psm.setOracle(address(usdc), address(feed));
        psm.setMaxOracleDelay(address(usdc), 26 hours); // 24h heartbeat plus margin
        vm.stopPrank();

        usdc.mint(user, SWAP * 10);
        vm.prank(user);
        usdc.approve(address(psm), type(uint256).max);
    }

    function _swap() internal {
        vm.prank(user);
        psm.swapStableForKUSD(address(usdc), SWAP);
    }

    /// @notice The happy path. A fresh, pegged quote mints, and the 10 bps fee is
    ///         the only thing the user gives up.
    function test_freshPeggedQuoteMints() public {
        feed.set(1e8, clock);
        _swap();

        // 1,000 USDC less 10 bps, normalised from 6 to 18 decimals.
        assertEq(kusd.balanceOf(user), 999.0e18, "minted 1,000 USDC less the 10 bps fee");
    }

    /// @notice A quote older than the configured window cannot mint. This is the
    ///         reported behaviour, asserted directly.
    function test_staleQuoteCannotMint() public {
        feed.set(1e8, clock);
        _advance(27 hours); // one hour past the 26h window

        vm.prank(user);
        vm.expectRevert(KUSDPSM.OraclePriceStale.selector);
        psm.swapStableForKUSD(address(usdc), SWAP);
    }

    /// @notice And a quote inside the window still mints, so the guard is a
    ///         staleness check rather than a slow denial of service. This is the
    ///         assertion that would have caught the 1h-versus-24h-heartbeat bug.
    function test_aQuoteInsideTheWindowStillMints() public {
        feed.set(1e8, clock);
        _advance(25 hours); // old, but inside the 26h window for a 24h-heartbeat feed

        _swap();
        assertEq(kusd.balanceOf(user), 999.0e18, "an honest 25-hour-old heartbeat still mints");
    }

    /// @notice FAIL CLOSED. With no oracle wired, minting reverts rather than
    ///         silently skipping the depeg gate. The silent skip was the live
    ///         default before KRN-26-PSM-DEPEG-FAIL-OPEN.
    function test_unsetOracleFailsClosed() public {
        vm.prank(admin);
        psm.setOracle(address(usdc), address(0));

        vm.prank(user);
        vm.expectRevert(KUSDPSM.DepegOracleNotConfigured.selector);
        psm.swapStableForKUSD(address(usdc), SWAP);
    }

    /// @notice The opt-out exists, but it is an explicit, event-logged admin action
    ///         rather than an invisible sentinel value.
    function test_theOptOutIsExplicitNotASentinel() public {
        vm.startPrank(admin);
        psm.setOracle(address(usdc), address(0));
        psm.setDepegCheckDisabled(true);
        vm.stopPrank();

        _swap(); // now permitted, deliberately and visibly
        assertTrue(psm.depegCheckDisabled(), "the disable is readable on chain");
    }

    /// @notice A depegged quote inside the window is still refused. Staleness and
    ///         depeg are separate gates and both must hold.
    function test_depeggedQuoteCannotMint() public {
        feed.set(0.95e8, clock); // 5% under peg, against a 2% default tolerance

        vm.prank(user);
        vm.expectRevert(KUSDPSM.StableDepegged.selector);
        psm.swapStableForKUSD(address(usdc), SWAP);
    }

    /// @notice THE PROPERTY THAT MATTERS MOST. The window is manager-tunable but
    ///         hard-capped, so nobody can widen it into a de-facto disable of the
    ///         staleness guard while leaving it looking configured.
    function test_theStalenessWindowIsHardCapped() public {
        assertEq(psm.MAX_ORACLE_DELAY_BOUND(), 48 hours, "capped at 48h");
        assertEq(psm.DEFAULT_MAX_ORACLE_DELAY(), 1 hours, "unset means the original 1h posture");

        vm.prank(admin);
        vm.expectRevert(KUSDPSM.OracleDelayTooHigh.selector);
        psm.setMaxOracleDelay(address(usdc), 49 hours);

        vm.prank(admin);
        psm.setMaxOracleDelay(address(usdc), 48 hours); // the cap itself is allowed
        assertEq(psm.maxOracleDelay(address(usdc)), 48 hours);
    }
}
