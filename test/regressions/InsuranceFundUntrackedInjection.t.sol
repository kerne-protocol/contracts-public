// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// KRN-26-INS-INJECT-UNTRACKED
// Insurance-fund accounting gap on untracked injections
//
// Reported by:  Kor_HaeTae (Suil Yoon), 2026-07-04, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent, 2026-07-13)
// Status:       Fixed in source, pending redeploy. Unreachable on the live
//               system: KerneInsuranceFund 0xE8799FCF327C6D2f78103a3c9308C93592A30403
//               held 0 WETH when read on Base mainnet 2026-07-30, and the live
//               vault reports a collateral ratio of 20000 bps against a 13000 bps
//               injection trigger. There is nothing in the fund to inject and no
//               deficit to inject it into.
//
// The finding is an accounting gap, not a drain. The fund covers a vault loss with
// a bare ERC-20 `safeTransfer`. KerneVault's `totalAssets()` deliberately reads an
// internal ledger (`_trackedOnChainAssets`) rather than its raw token balance,
// because reading the balance is the textbook ERC-4626 donation-inflation
// primitive. The consequence the researcher spotted: capital pushed by the
// insurance fund lands as exactly that kind of untracked donation, so it does NOT
// raise `getSolvencyRatio()`. The fund can pay out in full and the vault still
// reads as undercollateralised, which means the coverage does not do the one job
// coverage exists to do.
//
// The fix in current source adds `injectFromInsurance(amount)`, an authenticated
// call that credits the pushed capital into the vault's tracked NAV. This file
// asserts the gap as it exists in the deployed bundle, so the day the remediated
// fund and vault are mirrored here, these tests fail and say so.
// ─────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { KerneInsuranceFund } from "../../contracts/KerneInsuranceFund/src/KerneInsuranceFund.sol";
import { KerneVault } from "../../contracts/KerneVault/src/KerneVault.sol";
// NOTE: this must be the vault bundle's OWN IERC20, not the canonical one under
// lib/. Each bundle vendors its own OpenZeppelin tree, so `IERC20` from a
// different bundle is a genuinely different Solidity type and will not implicitly
// convert. That is the per-bundle isolation working, not a misconfiguration.
import { IERC20 } from "../../contracts/KerneVault/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../helpers/Mocks.sol";

contract InsuranceFundUntrackedInjectionTest is Test {
    KerneInsuranceFund internal fund;
    KerneVault internal vault;
    MockERC20 internal weth;

    address internal admin = makeAddr("safe");
    address internal strategist = makeAddr("strategist");
    address internal depositor = makeAddr("depositor");

    uint256 internal constant DEPOSIT = 10 ether;
    uint256 internal constant COVER = 4 ether;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        vault = new KerneVault(
            IERC20(address(weth)), "Kerne WETH Vault", "kWETH", admin, strategist, makeAddr("exchange")
        );

        vm.prank(admin);
        fund = new KerneInsuranceFund(address(weth), admin);

        // The fund is capitalised, and the vault is a recognised destination.
        weth.mint(address(fund), 100 ether);
        vm.prank(admin);
        fund.setAuthorization(address(vault), true);

        // A depositor is in the vault, so the vault has real liabilities.
        weth.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        weth.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, depositor);
        vm.stopPrank();
    }

    /// @notice THE FINDING. The fund pays, the vault receives the tokens, and the
    ///         vault's own accounting does not move by a single wei.
    function test_KNOWN_socializedLossDoesNotRaiseTheVaultsTrackedAssets() public {
        uint256 assetsBefore = vault.totalAssets();
        uint256 ratioBefore = vault.getSolvencyRatio();
        uint256 rawBalanceBefore = weth.balanceOf(address(vault));

        // The admin holds DEFAULT_ADMIN_ROLE on the fund, so this is the intended,
        // fully authorised coverage path. Nothing here is an attack.
        vm.prank(admin);
        fund.socializeLoss(address(vault), COVER);

        // The tokens really did move.
        assertEq(weth.balanceOf(address(vault)), rawBalanceBefore + COVER, "the vault physically received the cover");

        // And the vault's accounting ignored all of it.
        assertEq(vault.totalAssets(), assetsBefore, "totalAssets() did not move");
        assertEq(vault.getSolvencyRatio(), ratioBefore, "the collateral ratio did not improve");
    }

    /// @notice The same gap on the automated path. `checkAndInject` is the function
    ///         that is supposed to defend a vault falling through the 1.30x critical
    ///         threshold, and its capital lands just as untracked.
    function test_KNOWN_automatedInjectionIsAlsoUntracked() public {
        // Drive the vault under the 13000 bps trigger by moving its on-chain assets
        // out to the exchange, which is the ordinary hedging lifecycle.
        vm.prank(admin);
        vault.sweepToExchange(5 ether);

        uint256 crBefore = vault.getSolvencyRatio();
        assertLt(crBefore, 13_000, "vault is under the injection threshold");

        uint256 fundBefore = weth.balanceOf(address(fund));

        // Anyone may call this; only the DESTINATION is role-checked.
        fund.checkAndInject(address(vault));

        assertLt(weth.balanceOf(address(fund)), fundBefore, "the fund paid out");
        assertEq(vault.getSolvencyRatio(), crBefore, "and the vault is exactly as undercollateralised as before");
    }

    /// @notice The shape of the fix, asserted as an absence. Current source credits
    ///         injected capital through `injectFromInsurance(uint256)`. The deployed
    ///         bundle has no such function, so a low-level call to it must fail.
    function test_deployedVaultHasNoInjectFromInsuranceEntryPoint() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("injectFromInsurance(uint256)", uint256(1)));
        assertFalse(ok, "the credit path the fix adds does not exist on the deployed bundle");
    }

    /// @notice Why this is disclosed rather than embargoed: an empty fund cannot
    ///         mis-credit anything. This is the live state.
    function test_unreachableWhileTheFundIsEmpty() public {
        vm.prank(admin);
        fund.socializeLoss(address(vault), 100 ether); // drain the test fund fully

        assertEq(fund.getBalance(), 0, "fund empty, as it is on chain today");

        uint256 assetsBefore = vault.totalAssets();
        fund.checkAndInject(address(vault));
        assertEq(vault.totalAssets(), assetsBefore, "nothing to inject, nothing happens");
    }
}
