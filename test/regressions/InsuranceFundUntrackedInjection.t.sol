// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// KRN-26-INS-INJECT-UNTRACKED
// Insurance-fund accounting gap on untracked injections
//
// Reported by:  Kor_HaeTae, 2026-07-04, to kerne.systems@protonmail.com
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
//
// CORRECTION, 2026-08-14, promised in writing to Abhinav Raj and Dmitriy Filatov
// on 2026-08-06. The paragraph above used to say the fix was absent from the
// deployed bundle, and the third test below asserted that absence. Both were
// wrong. Half the fix is already live, and the half that is missing is the other
// contract:
//
//   * The VAULT half EXISTS. `injectFromInsurance(uint256)`, selector
//     `0xd0d4aa13`, is present in the deployed bytecode at
//     `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B` and reverts
//     `NotInsuranceFund()` (`0x8ce905cb`) for an unauthorised caller. A function
//     that is genuinely absent reverts with EMPTY returndata instead, which is
//     the control that separates the two cases and the check the old test never
//     made: it read a failed call as a missing function.
//   * The FUND half does NOT. `0xd0d4aa13` is absent from the deployed bytecode
//     at `0xE8799FCF327C6D2f78103a3c9308C93592A30403`, and the mirrored fund
//     source still pays out with a bare `safeTransfer` on both the
//     `socializeLoss` and the `checkAndInject` path. The credit hook the vault
//     offers is never called by the one address allowed to call it.
//
// So the gap is real and open, exactly as the two `test_KNOWN_` cases below
// demonstrate, but it lives on the FUND side rather than being a missing vault
// entry point. The old framing understated what is deployed and would have sent
// a reviewer diffing this finding into the wrong contract. Both halves reproduce
// in two commands:
//
//   RPC=https://mainnet.base.org
//   cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
//     "injectFromInsurance(uint256)" 1 --rpc-url $RPC   # reverts 0x8ce905cb
//   cast code 0xE8799FCF327C6D2f78103a3c9308C93592A30403 --rpc-url $RPC \
//     | grep -c d0d4aa13                                # 0, the fund never calls it
//
// Read at Base block 49,986,375 on 2026-08-14, alongside the vault's
// `insuranceFund()`, which returns `0xE8799FCF...0403`. The two contracts are
// wired to each other and the missing call is the only thing between them.
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

    /// @notice CORRECTED 2026-08-14. This test used to assert that the deployed
    ///         bundle had no `injectFromInsurance` entry point, on the strength of a
    ///         low-level call coming back `ok == false`. That was a bad inference: a
    ///         call that reverts and a call to a function that does not exist both
    ///         return false, and this one reverts. The entry point is there.
    ///
    ///         What the returndata proves is the difference. A present-but-gated
    ///         function returns its custom error selector; an absent one returns
    ///         nothing at all, which is asserted here as the control so the two can
    ///         never be confused again.
    function test_theVaultCreditHookExistsAndIsGatedToTheConfiguredFund() public {
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeWithSignature("injectFromInsurance(uint256)", uint256(1)));

        assertFalse(ok, "an unauthorised caller is rejected");
        assertEq(ret.length, 4, "and it is rejected with a custom error, not with empty returndata");
        assertEq(
            bytes4(ret), KerneVault.NotInsuranceFund.selector, "the rejection is NotInsuranceFund(), 0x8ce905cb"
        );

        // The control that the old assertion was missing. `injectFromInsurance`
        // exists; this signature does not. Same call shape, different returndata.
        (bool absentOk, bytes memory absentRet) =
            address(vault).call(abi.encodeWithSignature("thisFunctionDoesNotExist(uint256)", uint256(1)));
        assertFalse(absentOk, "a genuinely absent function also fails");
        assertEq(absentRet.length, 0, "but it fails with NO returndata, which is how absence actually reads");
    }

    /// @notice And the vault half of the fix works when it is actually called. This
    ///         is the assertion that makes the finding's location precise: the
    ///         credit path is live and correct, so the surviving gap is entirely
    ///         that the deployed insurance fund never calls it.
    function test_theCreditHookWorksWhenTheFundItselfCallsIt() public {
        vm.prank(admin);
        vault.setInsuranceFund(address(fund));

        uint256 assetsBefore = vault.totalAssets();

        // Reproduce what the fund does today: a bare transfer, untracked.
        vm.prank(address(fund));
        weth.transfer(address(vault), COVER);
        assertEq(vault.totalAssets(), assetsBefore, "a bare transfer still credits nothing");

        // Now the call the deployed fund does not make.
        vm.prank(address(fund));
        vault.injectFromInsurance(COVER);
        assertEq(vault.totalAssets(), assetsBefore + COVER, "the credit hook does the job it was written to do");
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
