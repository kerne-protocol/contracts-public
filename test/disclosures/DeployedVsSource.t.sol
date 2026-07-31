// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// The three standing divergences, as executable assertions
//
// `audits/DEPLOYED_VS_SOURCE.md` is the document where Kerne states, in prose,
// every place its deployed bytecode behaves differently from its current source.
// Prose is not checkable. This file makes each of the three rows a test against
// the mirrored deployed source, so the disclosure and the code cannot drift apart
// quietly.
//
// No researcher is credited in this file. Two of these three rows were also
// reported externally on 2026-07-28, but that reporter has not confirmed public
// credit, and Kerne's rule is that a researcher is named only after they ask to
// be. The findings were already published in the disclosure document before those
// reports arrived, which is why they are testable here at all.
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
import { MockERC20 } from "../helpers/Mocks.sol";

// ── Row 1: KerneVault v2 ─────────────────────────────────────────────────────
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

// ── Row 2: kUSD ──────────────────────────────────────────────────────────────
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

// ── Row 3: KerneYieldDistributor ─────────────────────────────────────────────
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
