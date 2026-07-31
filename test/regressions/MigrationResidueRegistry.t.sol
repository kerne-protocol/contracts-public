// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Migration residue: the registry must not point a reader at a retired contract
//
// Reported by:  reodkt (Deni Roni), 2026-07-21, to kerne.systems@protonmail.com
// Credited at:  https://kerne.fi/security/acknowledgments  (public credit given
//               with the researcher's consent)
// Status:       Reviewed and accepted, and repaired in this repository on
//               2026-07-28. No fund-loss path: every item was drift between the
//               documented state and the deployed state of retired migration
//               components.
//
// The reported class was documentation drift, not a contract bug: a reader of the
// registry could be sent at a superseded address and file a finding against a
// contract that is no longer in the path. That is a real cost. It burns a
// researcher's weekend and it produces false positives that make the genuine
// reports harder to see.
//
// Drift is invisible to a compiler, so it comes back unless something checks it.
// This file is that check. It reads deployments/8453.json, the registry an
// outsider actually clones, and asserts the migration-sensitive pointers are the
// live ones. If a future edit re-points KerneTreasury at the retired v2, or drops
// a retired entry, the suite fails here rather than in somebody's inbox.
//
// These assertions are about internal consistency and do not need a network. The
// same pointers are checked against live chain state, with an RPC, in
// test/fork/RegistryMatchesChain.t.sol.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";

contract MigrationResidueRegistryTest is KerneTest {
    string internal registry;

    // The live addresses this repository publishes, restated here so the test is
    // an independent assertion rather than a tautology over the same file.
    address internal constant LIVE_TREASURY = 0x5343C41d4FF2B61DAacA9cbC050550C40605B075;
    address internal constant RETIRED_TREASURY_V2 = 0x7c07517ABcc4BD674CC74B76D2Ab0d95A41560d5;
    address internal constant LIVE_MINT_PSM = 0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803;
    address internal constant RETIRED_MINT_PSM = 0x07eBb486e11BD217e6085eb5ab663e4517595993;
    address internal constant LIVE_VAULT = 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B;
    address internal constant RETIRED_VAULT_V1 = 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC;
    address internal constant LIVE_SKUSD = 0x96F5102C15b839757f811A98CEc3725Ac21DfA14;
    address internal constant RETIRED_SKUSD_V1 = 0xdEd74F7E06efc76455C07418b8b74Cc2bc009DB4;
    address internal constant LIVE_KERNE = 0x230f3a63E8413D42bEe9103b98a204030206186c;
    address internal constant RETIRED_KERNE_V1 = 0xfEA3D217F5f2304C8551dc9F5B5169F2c2d87340;

    function setUp() public {
        registry = vm.readFile("deployments/8453.json");
    }

    function _addr(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(registry, key);
    }

    /// @notice THE REGRESSION. The primary KerneTreasury pointer must be the live
    ///         treasury, not the retired v2. Pointing it at v2 is precisely what
    ///         sent researchers at a contract whose `kerneToken()` still reads the
    ///         retired KERNE v1, generating findings against a dead path.
    function test_primaryTreasuryPointerIsTheLiveTreasuryNotTheRetiredV2() public view {
        assertEq(_addr(".contracts.KerneTreasury.address"), LIVE_TREASURY, "KerneTreasury must be v3");
        assertEq(_addr(".retired.KerneTreasury_v2"), RETIRED_TREASURY_V2, "v2 must be filed under retired");
        assertTrue(LIVE_TREASURY != RETIRED_TREASURY_V2);
    }

    /// @notice The mint path is the one a depositor actually touches, so a stale
    ///         pointer here is the most expensive kind of drift.
    function test_mintPsmPointerIsTheLiveInstance() public view {
        assertEq(_addr(".contracts.KUSDPSM.address"), LIVE_MINT_PSM, "KUSDPSM must be the 2026-07-10 redeploy");
        assertEq(_addr(".retired.KUSDPSM_2026_06_16_redeemReserve"), RETIRED_MINT_PSM, "prior mint PSM is retired");
    }

    /// @notice Every contract that has been through a migration keeps BOTH a live
    ///         pointer and a retired pointer, and they are never the same address.
    ///         A retired entry that quietly disappears is drift too: it leaves an
    ///         address live on chain with nothing in the registry explaining it.
    function test_everyMigratedContractKeepsDistinctLiveAndRetiredPointers() public view {
        assertEq(_addr(".contracts.KerneVault.address"), LIVE_VAULT);
        assertEq(_addr(".retired.KerneVault_v1"), RETIRED_VAULT_V1);
        assertTrue(LIVE_VAULT != RETIRED_VAULT_V1, "vault");

        assertEq(_addr(".contracts.skUSD.address"), LIVE_SKUSD);
        assertEq(_addr(".retired.skUSD_v1"), RETIRED_SKUSD_V1);
        assertTrue(LIVE_SKUSD != RETIRED_SKUSD_V1, "skUSD");

        assertEq(_addr(".contracts.KERNE.address"), LIVE_KERNE);
        assertEq(_addr(".retired.KERNE_v1"), RETIRED_KERNE_V1);
        assertTrue(LIVE_KERNE != RETIRED_KERNE_V1, "KERNE");
    }

    /// @notice No address may appear as both live and retired. This is the single
    ///         assertion that catches a copy-paste during the next redeploy, which
    ///         is when this class of drift is actually introduced.
    function test_noAddressIsSimultaneouslyLiveAndRetired() public view {
        address[6] memory live =
            [LIVE_TREASURY, LIVE_MINT_PSM, LIVE_VAULT, LIVE_SKUSD, LIVE_KERNE, _addr(".contracts.kUSD.address")];
        address[6] memory retired = [
            RETIRED_TREASURY_V2,
            RETIRED_MINT_PSM,
            RETIRED_VAULT_V1,
            RETIRED_SKUSD_V1,
            RETIRED_KERNE_V1,
            _addr(".retired.kUSD_v1")
        ];

        for (uint256 i = 0; i < live.length; i++) {
            for (uint256 j = 0; j < retired.length; j++) {
                assertTrue(live[i] != retired[j], "a live address is also listed as retired");
            }
        }
    }

    /// @notice The registry must carry a date. An undated registry cannot be
    ///         reasoned about by a reader deciding whether to trust it.
    function test_registryIsDated() public view {
        string memory updated = vm.parseJsonString(registry, ".lastUpdated");
        assertGt(bytes(updated).length, 0, "lastUpdated must be present");
    }
}
