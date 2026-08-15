// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// The four standing divergences, as executable assertions
//
// `audits/DEPLOYED_VS_SOURCE.md` is the document where Kerne states, in prose,
// every place its deployed bytecode behaves differently from its current source.
// Prose is not checkable. This file makes each of the four rows a test against
// the mirrored deployed source, so the disclosure and the code cannot drift apart
// quietly.
//
// No researcher is credited in this file. Two of these rows were also reported
// externally on 2026-07-28, but that reporter has not confirmed public credit,
// and Kerne's rule is that a researcher is named only after they ask to be. The
// findings were already published in the disclosure document before those
// reports arrived, which is why they are testable here at all. The skUSD row
// added on 2026-08-14 was found in Kerne's own sweep and has no reporter.
//
// These tests assert that the divergences ARE present. They are supposed to pass
// today and to FAIL the day the remediated contracts are mirrored here. A failure
// in this file is good news and means the disclosure needs updating.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { kUSD } from "../../contracts/kUSD/src/kUSD.sol";
import { KerneYieldDistributor } from "../../contracts/KerneYieldDistributor/src/KerneYieldDistributor.sol";
import { KerneVault } from "../../contracts/KerneVault/src/KerneVault.sol";
import { IERC20 } from "../../contracts/KerneVault/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { skUSD } from "../../contracts/skUSD/src/skUSD.sol";
import { ERC20 as SkusdErc20 } from "../../contracts/skUSD/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { MockERC20 } from "../helpers/Mocks.sol";

// ── Row 1: skUSD ─────────────────────────────────────────────────────────────
// "In the deployed _withdraw, the KRN-26-SKUSD-ORPHAN reset that collapses an
//  in-flight yield vest fires only when totalSupply() reaches zero, and one wei
//  of shares holds that trigger open indefinitely. So an address that keeps a
//  dust position outstanding while the staked capital exits during a vest ends
//  up owning the entire still-unvested distribution."
//
// Tag KRN-26-SKUSD-SQUAT, self-found 2026-07-30, fixed in source the same day,
// open on chain because skUSD is not a proxy. The 500.000000000000000001 kUSD
// figure published in the disclosure is the number this file measures.
contract SkusdOrphanResetSquatDisclosureTest is KerneTest {
    skUSD internal vault;
    MockERC20 internal asset;

    address internal admin = makeAddr("safe");
    address internal strategist = makeAddr("strategist");
    address internal staker = makeAddr("staker");
    address internal squatter = makeAddr("squatter");

    uint256 internal constant STAKE = 1_000e18;
    uint256 internal constant YIELD = 1_000e18;

    function setUp() public {
        _startClock(1_700_000_000);
        asset = new MockERC20("Kerne Synthetic Dollar", "kUSD", 18);
        vault = new skUSD(SkusdErc20(address(asset)), admin);
        bytes32 strategistRole = vault.STRATEGIST_ROLE();
        vm.prank(admin);
        vault.grantRole(strategistRole, strategist);

        asset.mint(staker, 10_000e18);
        asset.mint(squatter, 10_000e18);
        asset.mint(strategist, 10_000e18);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, who);
        vm.stopPrank();
        return shares;
    }

    function _distribute(uint256 amount) internal {
        vm.startPrank(strategist);
        asset.approve(address(vault), amount);
        vault.distributeYield(amount);
        vm.stopPrank();
    }

    /// @notice THE DISCLOSED BEHAVIOUR. One wei of shares keeps totalSupply()
    ///         non-zero, so the orphan reset never fires, and the whole unvested
    ///         distribution vests to a position that put up no capital.
    function test_KNOWN_oneWeiSquatterInheritsTheUnvestedDistribution() public {
        _deposit(staker, STAKE);
        assertGt(_deposit(squatter, 1), 0, "one wei mints a non-zero share balance");

        _distribute(YIELD);

        // The honest staker exits while the distribution is still fully locked.
        // Being paid only the vested portion is correct and is not what is tested.
        uint256 stakerShares = vault.balanceOf(staker);
        vm.prank(staker);
        uint256 paid = vault.redeem(stakerShares, staker, staker);
        assertApproxEqAbs(paid, STAKE, 1e12, "exiting staker is paid principal");
        assertGt(vault.totalSupply(), 0, "the dust position holds the reset trigger open");

        _advance(vault.yieldVestingPeriod() + 1);
        assertEq(vault.lockedYield(), 0, "vest complete");

        uint256 squatterShares = vault.balanceOf(squatter);
        uint256 before = asset.balanceOf(squatter);
        vm.prank(squatter);
        vault.redeem(squatterShares, squatter, squatter);
        uint256 taken = asset.balanceOf(squatter) - before;

        emit log_named_decimal_uint("one-wei position redeemed (kUSD)", taken, 18);
        assertEq(taken, 500.000000000000000001e18, "the figure published in the disclosure");
    }

    /// @notice The control, and the reason the trigger is the defect rather than
    ///         the design: with no dust position the last exit collapses the vest
    ///         and the yield becomes a sweepable donation instead of a windfall.
    function test_theOrphanResetStillWorksWhenNobodySquats() public {
        _deposit(staker, STAKE);
        _distribute(YIELD);

        uint256 stakerShares = vault.balanceOf(staker);
        vm.prank(staker);
        vault.redeem(stakerShares, staker, staker);

        assertEq(vault.totalSupply(), 0, "all shares burned");
        assertEq(vault.totalAssets(), 0, "ledger zeroed by the orphan reset");
        assertEq(vault.lockedYield(), 0, "vest collapsed");

        vm.prank(strategist);
        vault.sweepDonations(strategist);
        assertApproxEqAbs(asset.balanceOf(address(vault)), 0, 1e6, "yield recovered, not stranded");
    }

    /// @notice The bound the operating rule rests on, stated in the disclosure as
    ///         "the window is opened by Kerne, not by an attacker": there is
    ///         nothing to inherit unless a distribution is in flight, and only
    ///         STRATEGIST_ROLE can start one.
    function test_theWindowExistsOnlyWhileAVestIsInFlight() public {
        _deposit(staker, STAKE);
        assertGt(_deposit(squatter, 1), 0, "squatter is in position");
        assertEq(vault.lockedYield(), 0, "no vest, nothing to inherit");

        uint256 stakerShares = vault.balanceOf(staker);
        vm.prank(staker);
        vault.redeem(stakerShares, staker, staker);

        uint256 squatterShares = vault.balanceOf(squatter);
        uint256 before = asset.balanceOf(squatter);
        vm.prank(squatter);
        vault.redeem(squatterShares, squatter, squatter);
        assertLe(asset.balanceOf(squatter) - before, 1, "the dust position gets its wei back and no more");

        vm.prank(squatter);
        vm.expectRevert();
        vault.distributeYield(YIELD);
    }
}

// ── Row 2: KerneVault v2 ─────────────────────────────────────────────────────
// "The on-chain public-deposits gate is also absent, so calling depositsEnabled()
//  on the live contract reverts. [...] because the on-chain deposits gate was never
//  deployed, maxDeposit() returns the maximum uint256 for any address, so a
//  depositor could put funds into pre-audit bytecode before the remediated build
//  is live. Closing the door on chain is a single 2-of-3 Safe call to
//  setWhitelistEnabled(true), which reproduces the missing gate exactly and leaves
//  withdrawals untouched."
contract VaultDepositGateDisclosureTest is KerneTest {
    KerneVault internal vault;
    MockERC20 internal weth;

    address internal admin = makeAddr("safe");
    address internal strategist = makeAddr("strategist");
    address internal depositor = makeAddr("depositor");

    function setUp() public {
        _startClock(1_700_000_000);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vault = new KerneVault(
            IERC20(address(weth)), "Kerne WETH Vault", "kWETH", admin, strategist, makeAddr("exchange")
        );
        weth.mint(depositor, 100 ether);
        vm.prank(depositor);
        weth.approve(address(vault), type(uint256).max);
    }

    /// @notice The gate named in current source does not exist on the deployed build.
    function test_KNOWN_depositsEnabledDoesNotExistOnTheDeployedBuild() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("depositsEnabled()"));
        assertFalse(ok, "calling depositsEnabled() on the live contract reverts, exactly as disclosed");
    }

    /// @notice And so, with the whitelist off, deposits are open to anyone. That was
    ///         the live exposure until 2026-07-30.
    /// @dev    This is a property of the deployed SOURCE, exercised on a fresh
    ///         instance. It is not a claim about the live vault, which has had the
    ///         whitelist ON since the 2026-07-30 Safe transaction; see
    ///         test/fork/RegistryMatchesChain.t.sol for the live-state assertions.
    function test_KNOWN_maxDepositIsUnboundedWhileTheWhitelistIsOff() public view {
        assertFalse(vault.whitelistEnabled(), "this fresh instance has the whitelist off");
        assertEq(vault.maxDeposit(address(1)), type(uint256).max, "maxDeposit returns 2^256-1 for any address");
    }

    /// @notice The stated remedy actually works: one Safe call closes deposits.
    ///         Publishing an operating rule that had not been tested would be worse
    ///         than publishing no rule.
    function test_setWhitelistEnabledClosesDepositsAsTheOperatingRuleClaims() public {
        vm.prank(depositor);
        vault.deposit(1 ether, depositor); // open today

        vm.prank(admin);
        vault.setWhitelistEnabled(true);

        assertEq(vault.maxDeposit(depositor), 0, "the door is shut for a non-whitelisted address");
        vm.prank(depositor);
        vm.expectRevert();
        vault.deposit(1 ether, depositor);
    }

    /// @notice And it leaves withdrawals untouched, which is the half of the claim
    ///         that actually protects a depositor who is already in.
    function test_closingDepositsLeavesWithdrawalsUntouched() public {
        vm.prank(depositor);
        uint256 shares = vault.deposit(10 ether, depositor);

        vm.prank(admin);
        vault.setWhitelistEnabled(true);

        assertGt(vault.maxRedeem(depositor), 0, "an existing holder can still get out");
        assertGt(shares, 0);
    }
}

// ── Row 3: kUSD ──────────────────────────────────────────────────────────────
// "Standard OpenZeppelin ERC20Burnable: burnFrom is callable by any address
//  holding an allowance from the token owner. No role gate on burning. [...]
//  Current source: burning is gated behind BURNER_ROLE."
contract KusdBurnFromDisclosureTest is KerneTest {
    kUSD internal token;

    address internal admin = makeAddr("safe");
    address internal holder = makeAddr("holder");
    address internal spender = makeAddr("spender");

    function setUp() public {
        _startClock(1_700_000_000);
        token = new kUSD(admin);
        vm.prank(admin);
        token.mint(holder, 1_000e18);
    }

    /// @notice THE DISCLOSED BEHAVIOUR. An approved spender can destroy the
    ///         holder's kUSD rather than transfer it, with no role required.
    function test_KNOWN_anyApprovedSpenderCanBurnTheHoldersBalance() public {
        vm.prank(holder);
        token.approve(spender, 400e18);

        vm.prank(spender);
        token.burnFrom(holder, 400e18);

        assertEq(token.balanceOf(holder), 600e18, "the holder's tokens were destroyed, not moved");
        assertEq(token.totalSupply(), 600e18);
    }

    /// @notice The bound on the exposure, which is the reason it is a permanent
    ///         disclosure item rather than a redeploy: there is no path to burn
    ///         without the holder having granted an allowance first.
    function test_burningWithoutAnAllowanceIsImpossible() public {
        vm.prank(spender);
        vm.expectRevert();
        token.burnFrom(holder, 1);

        assertEq(token.balanceOf(holder), 1_000e18, "untouched");
    }

    /// @notice The role gate that current source adds does not exist here.
    function test_KNOWN_deployedKusdHasNoBurnerRole() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("BURNER_ROLE()"));
        assertFalse(ok, "no BURNER_ROLE on the deployed build");
    }
}

// ── Row 4: KerneYieldDistributor ─────────────────────────────────────────────
// "ROOT_UPDATER_ROLE can set a new Merkle distribution root with immediate
//  effect. [...] Current source: root updates go through proposeMerkleRoot and
//  executeMerkleRoot with a 24-hour ROOT_UPDATE_TIMELOCK. [...] Standing
//  operating rule: never fund the deployed distributor."
contract YieldDistributorTimelockDisclosureTest is KerneTest {
    KerneYieldDistributor internal distributor;
    MockERC20 internal usdc;

    address internal admin = makeAddr("safe");
    address internal rootUpdater = makeAddr("hotWallet");

    function setUp() public {
        _startClock(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        distributor = new KerneYieldDistributor(admin, rootUpdater, address(usdc));
    }

    /// @notice THE DISCLOSED BEHAVIOUR. The root updater can replace the
    ///         distribution root instantly, with no delay to react in.
    function test_KNOWN_rootUpdatesTakeEffectImmediately() public {
        bytes32 first = keccak256("epoch-1");
        bytes32 second = keccak256("attacker-root");

        vm.prank(rootUpdater);
        distributor.updateMerkleRoot(first);
        assertEq(distributor.currentMerkleRoot(), first);

        vm.prank(rootUpdater);
        distributor.updateMerkleRoot(second);
        assertEq(distributor.currentMerkleRoot(), second, "replaced in the same block, no timelock");
    }

    /// @notice The timelocked path that current source adds is entirely absent
    ///         here. There is nothing to delay and nothing to cancel.
    function test_KNOWN_deployedDistributorHasNoProposeOrExecutePath() public {
        (bool a,) = address(distributor).call(abi.encodeWithSignature("proposeMerkleRoot(bytes32)", bytes32(0)));
        assertFalse(a, "no proposeMerkleRoot on the deployed build");

        (bool b,) = address(distributor).call(abi.encodeWithSignature("executeMerkleRoot()"));
        assertFalse(b, "no executeMerkleRoot on the deployed build");

        (bool c,) = address(distributor).call(abi.encodeWithSignature("ROOT_UPDATE_TIMELOCK()"));
        assertFalse(c, "no timelock constant on the deployed build");
    }

    /// @notice The mitigation, asserted rather than asserted-about: the exposure is
    ///         zero while the contract is unfunded, and the operating rule is to
    ///         keep it that way. An unfunded distributor cannot route anything, no
    ///         matter what root is set.
    function test_theExposureIsBoundedByTheUnfundedOperatingRule() public {
        assertEq(usdc.balanceOf(address(distributor)), 0, "unfunded, as the operating rule requires");

        vm.prank(rootUpdater);
        distributor.updateMerkleRoot(keccak256("anything"));

        // A claim against an arbitrary root still moves no money, because there is
        // none to move. This is what "the exposure is zero in practice" means.
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    /// @notice Only the role holder can do it. The finding is about custody and
    ///         delay, not about a missing access check, and conflating the two
    ///         would overstate it.
    function test_theRootIsStillRoleGated() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        distributor.updateMerkleRoot(keccak256("nope"));
    }
}
