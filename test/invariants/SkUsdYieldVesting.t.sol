// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// skUSD: yield streaming, flash-deposit defence, and the orphan reset
//
// Self-found (2026-05-28 High, immediate-distribution share-price jump), fixed by
// the 2026-07-03 redeploy. An external researcher separately observed on
// 2026-07-28 that a depositor entering mid-vest shares the remaining unvested
// yield; that is an accepted property of the locked-profit design rather than a
// defect, and it is asserted explicitly below so the trade-off is public rather
// than folklore. That researcher has not confirmed public credit and so is not
// named: Kerne lists a researcher only after they ask to be. See
// https://kerne.fi/security/acknowledgments.
//
// Status:       FIXED AND LIVE. `audits/DEPLOYED_VS_SOURCE.md` records this row as
//               "Closed on chain since the last revision". Deployed skUSD
//               0x96F5102C15b839757f811A98CEc3725Ac21DfA14 runs the streaming
//               source this bundle mirrors. These tests are a proof of
//               remediation, not a disclosure.
//
// What is being locked in:
//   1. A distribution does NOT hit the share price atomically. It vests linearly
//      over yieldVestingPeriod and is excluded from totalAssets() until it does.
//   2. A depositor who brackets a distribution inside one block captures none of
//      it. This is the defect the redeploy closed.
//   3. totalAssets() reads an internal ledger, so a direct ERC-20 donation cannot
//      move the share price (the classic ERC-4626 inflation primitive).
//   4. KRN-26-SKUSD-ORPHAN: on the last exit the vest collapses and the ledger
//      resets, so still-vesting yield does not become simultaneously un-owned and
//      un-recoverable.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { skUSD } from "../../contracts/skUSD/src/skUSD.sol";
import { ERC20 } from "../../contracts/skUSD/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @dev skUSD's constructor takes an OpenZeppelin `ERC20` (the contract type, not
///      the interface), and it must be the one vendored inside the skUSD bundle.
contract MockKUSD is ERC20 {
    constructor() ERC20("Kerne Synthetic Dollar", "kUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SkUsdYieldVestingTest is KerneTest {
    skUSD internal vault;
    MockKUSD internal kusd;

    address internal admin = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal flasher = makeAddr("flasher");

    uint256 internal constant STAKE = 1_000e18;
    uint256 internal constant YIELD = 100e18;

    function setUp() public {
        _startClock(1_700_000_000);

        kusd = new MockKUSD();
        vault = new skUSD(ERC20(address(kusd)), admin);

        kusd.mint(alice, STAKE);
        kusd.mint(flasher, STAKE);
        kusd.mint(admin, YIELD * 10);

        vm.startPrank(alice);
        kusd.approve(address(vault), type(uint256).max);
        vault.deposit(STAKE, alice);
        vm.stopPrank();

        vm.prank(admin);
        kusd.approve(address(vault), type(uint256).max);
    }

    function _distribute(uint256 amount) internal {
        vm.prank(admin);
        vault.distributeYield(amount);
    }

    /// @notice Distributed yield is locked at the instant it arrives, and vests
    ///         linearly over the 24-hour default.
    function test_distributedYieldIsLockedThenVestsLinearly() public {
        uint256 assetsBefore = vault.totalAssets();

        _distribute(YIELD);

        assertEq(vault.lockedYield(), YIELD, "the whole distribution is locked on arrival");
        assertEq(vault.totalAssets(), assetsBefore, "and none of it is in the share price yet");
        assertEq(vault.yieldVestingPeriod(), 24 hours, "default vest is 24h");

        _advance(12 hours);
        assertApproxEqAbs(vault.lockedYield(), YIELD / 2, 1, "half vested at the halfway point");
        assertApproxEqAbs(vault.totalAssets(), assetsBefore + YIELD / 2, 1, "and half is in the share price");

        _advance(12 hours);
        assertEq(vault.lockedYield(), 0, "fully vested");
        assertEq(vault.totalAssets(), assetsBefore + YIELD, "the whole distribution is now owned by stakers");
    }

    /// @notice THE FIX, asserted directly. Deposit, distribute and redeem inside a
    ///         single block and the flash depositor captures nothing.
    function test_flashDepositCapturesNoneOfTheDistribution() public {
        vm.startPrank(flasher);
        kusd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(STAKE, flasher);
        vm.stopPrank();

        _distribute(YIELD); // same block, no warp

        vm.prank(flasher);
        uint256 out = vault.redeem(shares, flasher, flasher);

        assertLe(out, STAKE, "the flash depositor got back no more than they put in");
        assertApproxEqAbs(out, STAKE, 1, "and no less, bar rounding");
    }

    /// @notice The accepted trade-off, stated rather than left implicit: a depositor
    ///         who enters mid-vest DOES share the still-unvested remainder with the
    ///         stakers who were already there. The defence targets single-block
    ///         theft, and it is honest about not being a lockup.
    function test_ACCEPTED_midVestDepositorSharesTheRemainingUnvestedYield() public {
        _distribute(YIELD);
        _advance(12 hours); // half the yield still locked

        uint256 lockedAtEntry = vault.lockedYield();
        assertApproxEqAbs(lockedAtEntry, YIELD / 2, 1);

        vm.startPrank(flasher);
        kusd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(STAKE, flasher);
        vm.stopPrank();

        _advance(12 hours); // let the rest vest
        uint256 out = vault.previewRedeem(shares);

        assertGt(out, STAKE, "the mid-vest depositor did earn a share of the remainder");
        assertLt(out, STAKE + lockedAtEntry, "but less than all of it; it is shared, not captured");
    }

    /// @notice A direct token donation must not move the share price. This is the
    ///         reason totalAssets() reads a ledger rather than balanceOf.
    function test_donationCannotInflateTheSharePrice() public {
        uint256 priceBefore = vault.convertToAssets(1e18);

        kusd.mint(address(vault), 500e18); // straight transfer, no deposit

        assertEq(vault.convertToAssets(1e18), priceBefore, "share price is unmoved by a donation");
        assertEq(vault.totalAssets(), STAKE, "and the ledger ignores it");
    }

    /// @notice KRN-26-SKUSD-ORPHAN. When the last staker leaves mid-vest, the
    ///         remaining unvested yield must not stay counted as tracked principal,
    ///         or it becomes both ownerless and unsweepable.
    function test_lastExitCollapsesTheVestAndResetsTheLedger() public {
        _distribute(YIELD);
        _advance(6 hours); // three quarters still locked

        assertGt(vault.lockedYield(), 0);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertEq(vault.totalSupply(), 0, "everyone has left");
        assertEq(vault.lockedYield(), 0, "the vest collapsed");
        assertEq(vault.totalAssets(), 0, "and the ledger reset to genesis");

        // The stranded kUSD is now a recoverable donation rather than phantom principal.
        uint256 stuck = kusd.balanceOf(address(vault));
        assertGt(stuck, 0, "the tokens are still physically here");

        vm.prank(admin);
        vault.sweepDonations(admin);
        assertEq(kusd.balanceOf(address(vault)), 0, "and the strategist can recover them");
    }

    /// @notice The vesting period is admin-tunable but bounded, so it can be neither
    ///         set to zero (restoring the atomic jump) nor stretched indefinitely.
    function test_vestingPeriodIsBounded() public {
        assertEq(vault.MIN_VESTING_PERIOD(), 1 hours);
        assertEq(vault.MAX_VESTING_PERIOD(), 30 days);

        vm.prank(admin);
        vm.expectRevert(skUSD.InvalidVestingPeriod.selector);
        vault.setYieldVestingPeriod(0);

        vm.prank(admin);
        vm.expectRevert(skUSD.InvalidVestingPeriod.selector);
        vault.setYieldVestingPeriod(31 days);
    }
}
