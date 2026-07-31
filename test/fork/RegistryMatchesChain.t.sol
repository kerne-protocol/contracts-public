// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// The registry, checked against the chain it describes
//
// Every other test in this repository is hermetic: it runs from a clean clone
// with no network and no API key, which is what makes `forge test` a two-command
// promise. This file is the deliberate exception. It forks Base and asserts that
// the addresses and claims published in this repository are true of live state.
//
// It is OPT-IN. Without BASE_RPC_URL set, every test here returns early rather
// than failing, because a public repository that goes red when somebody else's
// RPC endpoint rate-limits teaches maintainers to ignore the badge. CI runs the
// hermetic suite; this one is for a reviewer who wants to check the claims
// themselves:
//
//     BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'
//
// Anyone can run it. That is the point: the claims in README.md and
// audits/DEPLOYED_VS_SOURCE.md stop being things Kerne says and become things a
// stranger can verify in one command.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";

interface IKerneVaultLike {
    function maxDeposit(address) external view returns (uint256);
    function whitelistEnabled() external view returns (bool);
    function paused() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function getSolvencyRatio() external view returns (uint256);
}

interface IPsmLike {
    function treasury() external view returns (address);
}

interface IRolesLike {
    function hasRole(bytes32, address) external view returns (bool);
}

interface IEsKerneLike {
    function totalSupply() external view returns (uint256);
    function totalEmitted() external view returns (uint256);
}

interface IOracleLike {
    function getTWAY(address) external view returns (uint256);
    function isRegistered(address) external view returns (bool);
}

contract RegistryMatchesChainTest is KerneTest {
    string internal registry;
    bool internal forked;

    // kUSD MINTER_ROLE
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address internal constant LIVE_VAULT = 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B;
    address internal constant LIVE_MINT_PSM = 0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803;
    address internal constant RETIRED_MINT_PSM = 0x07eBb486e11BD217e6085eb5ab663e4517595993;
    address internal constant LIVE_TREASURY = 0x5343C41d4FF2B61DAacA9cbC050550C40605B075;
    address internal constant KUSD = 0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3;
    address internal constant ESKERNE = 0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34;
    address internal constant YIELD_ORACLE = 0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB;

    function setUp() public {
        registry = vm.readFile("deployments/8453.json");

        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) {
            // Not a silent pass: say so, so an empty run is never mistaken for a
            // green one.
            emit log("SKIPPED: set BASE_RPC_URL to check the registry against live Base state");
            return;
        }
        _;
    }

    /// @notice The registry's live mint PSM really is the one holding MINTER_ROLE,
    ///         and the retired one really has lost it. This is the single most
    ///         consequential claim in the README.
    function test_onlyTheRegistrysMintPsmCanMint() public onlyForked {
        address registryPsm = vm.parseJsonAddress(registry, ".contracts.KUSDPSM.address");
        assertEq(registryPsm, LIVE_MINT_PSM, "registry names the live PSM");

        assertTrue(IRolesLike(KUSD).hasRole(MINTER_ROLE, registryPsm), "the published PSM can mint");
        assertFalse(IRolesLike(KUSD).hasRole(MINTER_ROLE, RETIRED_MINT_PSM), "the retired PSM cannot");
    }

    /// @notice The treasury pointer, which is the one that historically sent
    ///         researchers at the wrong contract.
    function test_registryTreasuryIsTheAddressTheLivePsmActuallySweepsTo() public onlyForked {
        address registryTreasury = vm.parseJsonAddress(registry, ".contracts.KerneTreasury.address");
        assertEq(registryTreasury, LIVE_TREASURY, "registry names v3");
        assertEq(IPsmLike(LIVE_MINT_PSM).treasury(), registryTreasury, "and the live PSM agrees");
    }

    /// @notice audits/DEPLOYED_VS_SOURCE.md row 1 and the README both state the
    ///         vault's deposit state and print the exact cast calls. This asserts
    ///         the same four facts, so those documents cannot go stale without
    ///         something failing.
    ///
    ///         This test has already earned its place. The first time it ran, on
    ///         2026-07-31, it failed: it still expected the pre-2026-07-30 state
    ///         (deposits open, maxDeposit 2^256-1) because the Safe transaction had
    ///         executed on 2026-07-30 and the mirror had never been updated. The
    ///         website had been corrected the same day; this repository had not.
    ///         Both documents were corrected in the commit that introduced this
    ///         file. A failure here means the disclosure needs updating, not that
    ///         the test is wrong.
    function test_disclosedVaultDepositStateMatchesChain() public onlyForked {
        IKerneVaultLike vault = IKerneVaultLike(LIVE_VAULT);
        assertEq(vault.maxDeposit(address(1)), 0, "deposits closed since 2026-07-30, as disclosed");
        assertTrue(vault.whitelistEnabled(), "whitelist on, as disclosed");
        assertFalse(vault.paused(), "NOT paused: withdrawals stay open, as disclosed");
        assertEq(vault.totalSupply(), 0, "the vault holds no user funds, as disclosed");
    }

    /// @notice The esKERNE findings in test/regressions are published on the
    ///         grounds that the escrow is unfunded and therefore unreachable. If
    ///         that ever stops being true, the disclosure basis is gone and this
    ///         test is what says so.
    function test_esKerneIsStillUnfundedWhichIsWhyItsFindingsArePublishable() public onlyForked {
        assertEq(IEsKerneLike(ESKERNE).totalEmitted(), 0, "nothing has ever been emitted");
        assertEq(IEsKerneLike(ESKERNE).totalSupply(), 0, "and nothing is outstanding");
    }

    /// @notice Same for the yield oracle: the consensus DoS is published because
    ///         the live oracle records nothing.
    function test_yieldOracleStillRecordsNothingWhichIsWhyItsDosIsPublishable() public onlyForked {
        assertEq(IOracleLike(YIELD_ORACLE).getTWAY(LIVE_VAULT), 0, "no yield reported");
        assertFalse(IOracleLike(YIELD_ORACLE).isRegistered(LIVE_VAULT), "the vault is not even registered");
    }

    /// @notice And the insurance fund: the untracked-injection gap is published
    ///         because the fund is empty and the vault is far above the trigger.
    function test_insuranceFundConditionsThatMakeItsGapUnreachable() public onlyForked {
        assertGe(IKerneVaultLike(LIVE_VAULT).getSolvencyRatio(), 13_000, "vault is above the 1.30x injection trigger");
    }
}
