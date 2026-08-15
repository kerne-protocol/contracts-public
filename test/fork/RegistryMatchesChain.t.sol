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

interface IPsmGateLike {
    function solvencyCheckDisabled() external view returns (bool);
    function depegCheckDisabled() external view returns (bool);
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

    /// @notice The vault's deposit state, read from the registry rather than
    ///         hardcoded, and asserted against the chain.
    ///
    ///         This test has already earned its place twice. The first time it
    ///         ran, on 2026-07-31, it failed: it still expected the pre-2026-07-30
    ///         state (deposits open, maxDeposit 2^256-1) because the Safe
    ///         transaction had executed on 2026-07-30 and the mirror had never
    ///         been updated. Both documents were corrected in the commit that
    ///         introduced this file.
    ///
    ///         ⛔ It then failed a SECOND time, in a way this file was partly
    ///         responsible for. It hardcoded `0` and `true` here, which made this
    ///         a second copy of the truth rather than a check on the published
    ///         one, and deployments/8453.json went on asserting the opposite for
    ///         nine days with this test passing the whole time. Expectations now
    ///         come from `contracts.KerneVault.depositState` in the registry, so
    ///         there is exactly ONE place to change when the door moves, and
    ///         changing the chain without changing that place fails here and in
    ///         scripts/check_registry_vs_chain.py.
    ///
    ///         A failure here means the disclosure needs updating, not that the
    ///         test is wrong.
    function test_disclosedVaultDepositStateMatchesChain() public onlyForked {
        IKerneVaultLike vault = IKerneVaultLike(LIVE_VAULT);

        // The registry names the address this test probes. If those ever drift
        // apart the rest of the assertions are measuring the wrong contract.
        assertEq(
            vm.parseJsonAddress(registry, ".contracts.KerneVault.address"),
            LIVE_VAULT,
            "registry names the vault this test probes"
        );

        // maxDeposit is carried as a decimal STRING because 2^256-1 does not
        // survive a JSON number, and a silently-truncated expectation is how a
        // check like this passes vacuously.
        uint256 expectedMaxDeposit =
            vm.parseUint(vm.parseJsonString(registry, ".contracts.KerneVault.depositState.maxDepositAnyAddress"));
        bool expectedWhitelist = vm.parseJsonBool(registry, ".contracts.KerneVault.depositState.whitelistEnabled");
        bool expectedPaused = vm.parseJsonBool(registry, ".contracts.KerneVault.depositState.paused");
        uint256 expectedSupply =
            vm.parseUint(vm.parseJsonString(registry, ".contracts.KerneVault.depositState.totalSupply"));
        bool expectedOpen = vm.parseJsonBool(registry, ".contracts.KerneVault.depositState.open");

        assertEq(vault.maxDeposit(address(1)), expectedMaxDeposit, "maxDeposit matches the published registry");
        assertEq(vault.whitelistEnabled(), expectedWhitelist, "whitelistEnabled matches the published registry");
        assertEq(vault.paused(), expectedPaused, "paused matches the published registry");
        assertEq(vault.totalSupply(), expectedSupply, "totalSupply matches the published registry");

        // `open` is a summary of maxDeposit and must not be able to drift from
        // the number it summarises.
        assertEq(vault.maxDeposit(address(1)) > 0, expectedOpen, "the registry's open flag matches its own maxDeposit");
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
    ///
    ///         ⛔ CORRECTED 2026-08-14, and the same correction is made in the
    ///         header of test/regressions/YieldOracleConsensusBrick.t.sol. This
    ///         test used to assert `isRegistered(vault) == false` and describe the
    ///         vault as "not even registered", as though registration were a gate.
    ///         It is not. `isRegistered` is a public mapping that the oracle's
    ///         `updateYield` never reads, so an unregistered vault can be proposed
    ///         on and recorded against exactly like a registered one, and asserting
    ///         it made the publication argument look broader than it was. The fact
    ///         that actually carries the argument is that the observation array is
    ///         EMPTY, which is what is asserted now: `observations(vault, 0)`
    ///         reverts on an out-of-bounds read, so nothing has ever been recorded.
    function test_yieldOracleStillRecordsNothingWhichIsWhyItsDosIsPublishable() public onlyForked {
        assertEq(IOracleLike(YIELD_ORACLE).getTWAY(LIVE_VAULT), 0, "no yield reported");

        (bool ok,) = YIELD_ORACLE.staticcall(
            abi.encodeWithSignature("observations(address,uint256)", LIVE_VAULT, uint256(0))
        );
        assertFalse(ok, "observations(vault, 0) reverts, so the array is empty and nothing was ever recorded");
    }

    /// @notice Configuration state, which is the axis neither a source diff nor a
    ///         bytecode comparison can see: the contract matches its source and a
    ///         setter has switched a check off anyway.
    ///
    ///         Reported by ParthaSarathi on 2026-08-01, who found both that the
    ///         solvency gate was off on the live mint path and that the
    ///         auditor-facing documents carried no pointer to where configuration
    ///         state is published. The documents were corrected on 2026-08-14. This
    ///         test is the other half of the promise made to him, that the finding
    ///         would be credited on a regression header: there is no code defect
    ///         here to regress against, so the assertion is against live
    ///         configuration instead, read from the registry rather than hardcoded.
    ///
    ///         ⛔ A failure here means the flag moved and the disclosure is stale.
    ///         Fix `contracts.KUSDPSM.configurationState` in deployments/8453.json
    ///         and the configuration-state section of audits/DEPLOYED_VS_SOURCE.md
    ///         together, exactly as with the deposit state above. It fails in both
    ///         directions on purpose: quietly re-enabling the gate and leaving the
    ///         disclosure saying it is off is caught here too.
    function test_disclosedPsmGateConfigurationMatchesChain() public onlyForked {
        assertEq(
            vm.parseJsonAddress(registry, ".contracts.KUSDPSM.address"),
            LIVE_MINT_PSM,
            "registry names the PSM this test probes"
        );

        bool expectedSolvencyOff =
            vm.parseJsonBool(registry, ".contracts.KUSDPSM.configurationState.solvencyCheckDisabled");
        bool expectedDepegOff = vm.parseJsonBool(registry, ".contracts.KUSDPSM.configurationState.depegCheckDisabled");

        assertEq(
            IPsmGateLike(LIVE_MINT_PSM).solvencyCheckDisabled(),
            expectedSolvencyOff,
            "solvencyCheckDisabled matches the published registry"
        );
        assertEq(
            IPsmGateLike(LIVE_MINT_PSM).depegCheckDisabled(),
            expectedDepegOff,
            "depegCheckDisabled matches the published registry"
        );

        // The part a flag read alone does not tell you, and the better fact handed
        // back to the reporter: with the vault empty the gate has nothing to
        // measure, so switching it back on would protect nobody. If this ever stops
        // being 0 the effective-state claim in DEPLOYED_VS_SOURCE.md needs rewriting.
        assertEq(
            IKerneVaultLike(LIVE_VAULT).totalSupply(),
            0,
            "the vault the gate reads has no liabilities, so the gate is a sentinel either way"
        );
    }

    /// @notice And the insurance fund: the untracked-injection gap is published
    ///         because the fund is empty and the vault is far above the trigger.
    function test_insuranceFundConditionsThatMakeItsGapUnreachable() public onlyForked {
        assertGe(IKerneVaultLike(LIVE_VAULT).getSolvencyRatio(), 13_000, "vault is above the 1.30x injection trigger");
    }
}
