// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// The mint capacity, executed rather than asserted
//
// Kerne publishes a capacity figure: the live mint PSM will accept 9,999,970
// more USDC than it holds today. That number is two `cast call`s and a
// subtraction, so anyone can check the INPUTS. This file checks the
// CONSEQUENCE, which is the part a depositor actually cares about: it forks
// Base, hands a fresh address one million USDC, mints through the real
// deployed bytecode, and asserts what comes back.
//
// It also walks the number to its edge. A mint of exactly the published
// headroom succeeds. One USDC more reverts with StableCapExceeded. That pair is
// what makes the figure a boundary rather than a brochure.
//
// WHY A MEMO NEEDS A TEST
//
// "We can take a million dollars" is the single most load-bearing sentence
// Kerne says to an allocator, and until this file existed it was a sentence
// rather than a demonstration. The failure mode this guards against is not
// dishonesty, it is drift: a cap lowered by an admin transaction, a pause, a
// revoked MINTER_ROLE, or a stable quietly de-supported would each make the
// published figure false while every word of the prose stayed the same.
//
// It has already caught one such error, in Kerne's own records rather than on
// chain. An internal audit dated 2026-08-12 recorded "no cap getter" for this
// contract, having probed `stableCap`, `cap`, `mintCap`, `maxMint` and
// `supplyCap`. All five revert. The getter is `stableCaps` and it takes the
// stable's address as an argument, which is why five guesses missed it and why
// the capacity was believed to be unmeasurable for a day. A test is how a
// finding like that stops being rediscoverable.
//
// OPT-IN, like every file under test/fork. Without BASE_RPC_URL set, each test
// returns early and says so rather than failing, because a public repository
// that goes red when somebody else's RPC endpoint rate-limits teaches
// maintainers to ignore the badge.
//
//     BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/PsmCapacityIsReal.t.sol' -vv
//
// The fork is PINNED to a block, so this file is reproducible: it asserts exact
// figures and would otherwise drift the moment anybody mints. The pin is also
// what keeps the Chainlink staleness gate inside its heartbeat. Re-pin it when
// the numbers below stop being current, and change the numbers in the same
// commit.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";

interface IPsmCapacity {
    function stableCaps(address stable) external view returns (uint256);
    function currentExposure(address stable) external view returns (uint256);
    function supportedStables(address stable) external view returns (bool);
    function mintingEnabled() external view returns (bool);
    function paused() external view returns (bool);
    function getFee(address stable, uint256 amount) external view returns (uint256);
    function swapStableForKUSD(address stable, uint256 amount) external;
    function solvencyCheckDisabled() external view returns (bool);
    function minSolvencyThreshold() external view returns (uint256);
    function flashFeeBps() external view returns (uint256);
    function maxFlashLoan(address token) external view returns (uint256);
}

interface IErc20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract PsmCapacityIsRealTest is KerneTest {
    bool internal forked;

    // Pinned so the assertions below are exact rather than approximate. Every
    // literal in this file was read at this block.
    uint256 internal constant PINNED_BLOCK = 49_930_000; // 2026-08-13 19:29:07Z

    address internal constant LIVE_MINT_PSM = 0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803;
    address internal constant RETIRED_MINT_PSM = 0x07eBb486e11BD217e6085eb5ab663e4517595993;
    address internal constant V1_REDEEM_PSM = 0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc;
    address internal constant KUSD = 0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // USDC is 6 decimals, kUSD is 18.
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant PUBLISHED_CAP = 10_000_000 * ONE_USDC;
    uint256 internal constant EXPOSURE_AT_PIN = 30 * ONE_USDC;
    uint256 internal constant PUBLISHED_HEADROOM = 9_999_970 * ONE_USDC;

    // `StableCapExceeded()`, the revert the cap raises. Named here so a reader
    // can match it against the selector printed in the memo.
    bytes4 internal constant STABLE_CAP_EXCEEDED = 0x40e97e29;

    address internal depositor = address(0xA11CE);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc, PINNED_BLOCK);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) {
            // Not a silent pass: say so, so an empty run is never mistaken for a
            // green one.
            emit log("SKIPPED: set BASE_RPC_URL to execute the capacity proof against Base");
            return;
        }
        _;
    }

    // ── The published number ─────────────────────────────────────────────────

    /// @notice The capacity Kerne publishes is the capacity the contract
    ///         enforces, derived the way the contract derives it.
    ///
    /// @dev The gate is not `currentExposure + amount <= cap`. KUSDPSM.sol
    ///      binds it on `max(currentExposure, balanceOf(this))`, a 2026-06-07
    ///      fix (KRN-26-PSM-EXPOSURE-FLOOR-RESET) for the case where a
    ///      redemption larger than the tracked counter floors that counter to
    ///      zero while the module still holds the stable. Publishing headroom
    ///      off the counter alone would over-state it in exactly that case, so
    ///      this asserts the max().
    function test_publishedHeadroomIsWhatTheContractEnforces() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);

        uint256 cap = psm.stableCaps(USDC);
        uint256 exposure = psm.currentExposure(USDC);
        uint256 held = IErc20Like(USDC).balanceOf(LIVE_MINT_PSM);

        assertEq(cap, PUBLISHED_CAP, "stableCaps(USDC) is ten million at 6 decimals");
        assertEq(exposure, EXPOSURE_AT_PIN, "currentExposure(USDC) at the pinned block");

        uint256 effective = held > exposure ? held : exposure;
        assertEq(cap - effective, PUBLISHED_HEADROOM, "headroom = cap - max(exposure, balance)");
    }

    /// @notice The door is open, and it is this module's door. Four reads, each
    ///         of which would silently falsify the capacity if it flipped.
    function test_theMintPathIsActuallyOpen() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);

        assertFalse(psm.paused(), "not paused");
        assertTrue(psm.mintingEnabled(), "minting enabled");
        assertTrue(psm.supportedStables(USDC), "USDC is a supported stable");
        assertTrue(IErc20Like(KUSD).hasRole(MINTER_ROLE, LIVE_MINT_PSM), "and this module can mint kUSD");
    }

    // ── The consequence ──────────────────────────────────────────────────────

    /// @notice One million USDC, from an address that has never touched Kerne,
    ///         through the deployed bytecode, in one transaction.
    ///
    /// @dev The fee is read from the chain rather than assumed. At this size the
    ///      tiered ladder charges 5 bps, so 1,000,000 USDC in returns 999,500
    ///      kUSD and the module's exposure rises by the GROSS deposit, fee
    ///      included. That asymmetry is deliberate in the contract (the fee is
    ///      the slice of the deposit not matched by minted kUSD, and it stays
    ///      recorded as exposure until skimmed) and it is asserted here so the
    ///      memo cannot describe it the easy, wrong way.
    function test_aMillionDollarMintCompletes() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);
        uint256 amount = 1_000_000 * ONE_USDC;

        uint256 exposureBefore = psm.currentExposure(USDC);
        uint256 fee = psm.getFee(USDC, amount);
        assertEq(fee, 500 * ONE_USDC, "5 bps at a million, from the live tiered ladder");

        deal(USDC, depositor, amount);
        assertEq(IErc20Like(KUSD).balanceOf(depositor), 0, "the depositor starts with no kUSD");

        vm.startPrank(depositor);
        IErc20Like(USDC).approve(LIVE_MINT_PSM, amount);
        psm.swapStableForKUSD(USDC, amount);
        vm.stopPrank();

        // 6 decimals in, 18 decimals out.
        uint256 expectedKusd = (amount - fee) * 1e12;
        assertEq(IErc20Like(KUSD).balanceOf(depositor), expectedKusd, "999,500 kUSD received");
        assertEq(IErc20Like(USDC).balanceOf(depositor), 0, "and the USDC left the depositor");

        assertEq(psm.currentExposure(USDC), exposureBefore + amount, "exposure rises by the GROSS deposit");
        assertEq(
            psm.stableCaps(USDC) - psm.currentExposure(USDC), PUBLISHED_HEADROOM - amount, "headroom falls by the same"
        );
    }

    // ── The edge ─────────────────────────────────────────────────────────────

    /// @notice The last USDC of published headroom mints.
    function test_exactlyTheHeadroomMints() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);

        deal(USDC, depositor, PUBLISHED_HEADROOM);
        vm.startPrank(depositor);
        IErc20Like(USDC).approve(LIVE_MINT_PSM, PUBLISHED_HEADROOM);
        psm.swapStableForKUSD(USDC, PUBLISHED_HEADROOM);
        vm.stopPrank();

        assertEq(psm.currentExposure(USDC), PUBLISHED_CAP, "the cap is now exactly met");
        assertGt(IErc20Like(KUSD).balanceOf(depositor), 0, "and the kUSD was minted");
    }

    /// @notice One USDC past it does not.
    ///
    /// @dev This is the assertion that makes the published figure a real bound.
    ///      Without it the number could be any value at or below the true cap
    ///      and every other test here would still pass.
    function test_oneUsdcPastTheHeadroomReverts() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);
        uint256 overCap = PUBLISHED_HEADROOM + ONE_USDC;

        deal(USDC, depositor, overCap);
        vm.startPrank(depositor);
        IErc20Like(USDC).approve(LIVE_MINT_PSM, overCap);
        vm.expectRevert(STABLE_CAP_EXCEEDED);
        psm.swapStableForKUSD(USDC, overCap);
        vm.stopPrank();
    }

    // ── What the memo discloses beside the number ────────────────────────────

    /// @notice The same cap is configured on all three modules, which is why the
    ///         memo says "each module" rather than quoting one and implying the
    ///         rest.
    function test_theSameCapIsSetOnAllThreeModules() public onlyForked {
        assertEq(IPsmCapacity(LIVE_MINT_PSM).stableCaps(USDC), PUBLISHED_CAP, "live mint module");
        assertEq(IPsmCapacity(RETIRED_MINT_PSM).stableCaps(USDC), PUBLISHED_CAP, "retired mint module");
        assertEq(IPsmCapacity(V1_REDEEM_PSM).stableCaps(USDC), PUBLISHED_CAP, "v1 redeem module");
    }

    /// @notice The retired module reads as though it could mint and cannot.
    ///
    /// @dev This is disclosed rather than buried because a reviewer running
    ///      `mintingEnabled()` against it will get `true` and deserves to know
    ///      why that is not what it looks like. Both flags are module-local
    ///      state; the authority is on the TOKEN, and the token refuses. A mint
    ///      attempted here reverts KusdMintFailed at KUSDPSM.sol:399.
    function test_theRetiredModuleLooksMintableAndIsNot() public onlyForked {
        IPsmCapacity retired = IPsmCapacity(RETIRED_MINT_PSM);

        assertFalse(retired.paused(), "its own pause flag is off");
        assertTrue(retired.mintingEnabled(), "and its own minting flag is on");
        assertFalse(IErc20Like(KUSD).hasRole(MINTER_ROLE, RETIRED_MINT_PSM), "but kUSD will not accept it as a minter");
        assertTrue(IErc20Like(KUSD).hasRole(MINTER_ROLE, LIVE_MINT_PSM), "the live module is the one that can");
    }

    /// @notice The solvency gate is configured and switched off, on the live
    ///         module, today.
    ///
    /// @dev Disclosed at kerne.fi/risk since 2026-07-24 and written up in
    ///      docs/security/PSM_SOLVENCY_GATE_DISABLED_2026-07-24.md. Asserted
    ///      here so the disclosure cannot go stale in either direction: if the
    ///      flag is ever cleared, this fails and the published text needs
    ///      changing.
    function test_theSolvencyGateIsConfiguredAndOff() public onlyForked {
        IPsmCapacity psm = IPsmCapacity(LIVE_MINT_PSM);

        assertTrue(psm.solvencyCheckDisabled(), "the gate is bypassed");
        assertEq(psm.minSolvencyThreshold(), 10_100, "while a 101% threshold sits configured behind it");
    }

    /// @notice Every module lends its entire USDC balance atomically at no fee.
    ///
    /// @dev ERC-3156, so the loan is repaid inside the same transaction or the
    ///      whole thing reverts. Stated in the memo because a reader will find
    ///      `maxFlashLoan` themselves and should find Kerne's description of it
    ///      first.
    function test_everyModuleLendsItsWholeBalanceAtZeroFee() public onlyForked {
        address[3] memory modules = [LIVE_MINT_PSM, RETIRED_MINT_PSM, V1_REDEEM_PSM];

        for (uint256 i = 0; i < modules.length; i++) {
            IPsmCapacity psm = IPsmCapacity(modules[i]);
            assertEq(psm.flashFeeBps(), 0, "no flash fee");
            assertEq(psm.maxFlashLoan(USDC), IErc20Like(USDC).balanceOf(modules[i]), "the whole balance is borrowable");
        }
    }
}
