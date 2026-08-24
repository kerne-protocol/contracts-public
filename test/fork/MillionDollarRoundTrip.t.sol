// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// The million dollar round trip, executed
//
// test/fork/PsmCapacityIsReal.t.sol proves the DOOR: one million USDC enters
// the live mint module, and one USDC past the published headroom reverts. That
// answers half of the question an allocator actually asks. The other half is
// "and then what, can I get it back out", and until this file existed Kerne's
// answer to that was arithmetic rather than execution.
//
// This file runs the whole cycle against deployed bytecode on a Base fork:
// one million USDC in, kUSD out, staked into skUSD, unstaked, and the kUSD
// redeemed back to USDC. Seven transactions, one address, no allowlist, no
// application. Every figure below was read off that run.
//
// ⛔⛔ THE CAVEAT IS NOT A FOOTNOTE, AND IT IS THE REASON THIS FILE IS HONEST.
// The mint leg is unconstrained: the cap is ten million and the reserve does
// not gate a deposit. The REDEEM leg is funded solely by the module's own
// stable reserve, so at the pinned block the largest single-transaction exit
// available anywhere in the system is 995.003 USDC, not one million. The round
// trip below only closes because the mint immediately before it is what put the
// reserve there. test_theExitIsBoundedByReserveDepthNotByTheContract asserts
// exactly that, in both directions, so the limitation is executed rather than
// promised. Do not delete it, and do not describe this file without it.
//
// WHAT THE RUN ESTABLISHES THAT ARITHMETIC COULD NOT
//
//  1. The cost is 11.9965 bps, and the reason is a TIER BOUNDARY. The ladder
//     charges 5 bps at or above 1,000,000 USDC and 7 bps at or above 250,000.
//     One million enters at 5 bps and returns 999,500 kUSD, which is below the
//     million-dollar tier, so the exit prices one step up. A reader who assumes
//     "5 bps each way" gets 10 and is wrong by 20%.
//
//  2. The redeemed kUSD is BURNED, not parked. The live module is the audited
//     build (audits/scope/0912c870), which carries the KRN-26-PSM-REDEEM-NO-BURN
//     fix; the older bundle mirrored at contracts/KUSDPSM/src is the RETIRED
//     module 0x07eBb486 and does not. So a complete round trip returns kUSD
//     supply to within one wei of where it started rather than inflating it.
//     That one wei is measured below and it is not rounding error in our favour.
//
//  3. The fee ledger under-counts the retained fee by exactly one stable-wei.
//     That is the documented flooring in _swapKUSDForStableInner, and this is
//     the first time it has been observed at size rather than reasoned about.
//
// OPT-IN, like every file under test/fork. Without BASE_RPC_URL each test says
// SKIPPED and passes, because a public repository that goes red when somebody
// else's RPC endpoint rate-limits teaches maintainers to ignore the badge. CI
// runs this file only to prove it skips cleanly. CI does not run the round trip.
// You run it:
//
//     BASE_RPC_URL=https://mainnet.base.org forge test \
//       --match-path 'test/fork/MillionDollarRoundTrip.t.sol' -vv
//
// The fork is PINNED, so this file is reproducible: it asserts exact integers
// and would otherwise drift the moment anybody mints or the vault accrues. The
// pin is also what keeps the Chainlink staleness gate inside its heartbeat.
// Re-pin it when the numbers below stop being current, and change the numbers
// in the same commit.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";

interface IPsm {
    function stableCaps(address stable) external view returns (uint256);
    function currentExposure(address stable) external view returns (uint256);
    function accruedFees(address stable) external view returns (uint256);
    function supportedStables(address stable) external view returns (bool);
    function mintingEnabled() external view returns (bool);
    function paused() external view returns (bool);
    function getFee(address stable, uint256 amount) external view returns (uint256);
    function swapStableForKUSD(address stable, uint256 amount) external;
    function swapKUSDForStable(address stable, uint256 amount) external;
}

interface IErc20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IStakedKusd {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

contract MillionDollarRoundTripTest is KerneTest {
    bool internal forked;

    // Pinned so the assertions below are exact rather than approximate. Every
    // literal in this file was read at this block.
    uint256 internal constant PINNED_BLOCK = 50_400_000; // 2026-08-24 16:35:47Z

    address internal constant LIVE_MINT_PSM = 0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803;
    address internal constant RETIRED_MINT_PSM = 0x07eBb486e11BD217e6085eb5ab663e4517595993;
    address internal constant V1_REDEEM_PSM = 0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc;
    address internal constant KUSD = 0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3;
    address internal constant SKUSD = 0x96F5102C15b839757f811A98CEc3725Ac21DfA14;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // USDC is 6 decimals, kUSD and skUSD are 18.
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant ONE_KUSD = 1e18;
    uint256 internal constant SCALE = 1e12; // 18dp / 6dp

    // ── The trip, in exact integers ──────────────────────────────────────────
    uint256 internal constant DEPOSIT_USDC = 1_000_000 * ONE_USDC; // 1,000,000.000000
    uint256 internal constant MINT_FEE_USDC = 500 * ONE_USDC; //         500.000000  (5 bps)
    uint256 internal constant KUSD_MINTED = 999_500 * ONE_KUSD; //   999,500.000000
    // The staking leg gives back one wei less than it took in. See
    // test_theStakingLegReturnsAllButOneWei for where that wei goes and why.
    uint256 internal constant KUSD_AFTER_STAKING = KUSD_MINTED - 1;
    uint256 internal constant REDEEM_FEE_KUSD = 699_649_999_999_999_999_999; // 699.649999999999999999 (7 bps)
    uint256 internal constant RETURNED_USDC = 998_800_350_000; //     998,800.350000
    uint256 internal constant ROUND_TRIP_COST_USDC = 1_199_650_000; //  1,199.650000

    // The fee ledger records one stable-wei less than the PSM actually keeps.
    uint256 internal constant LEDGER_UNDERCOUNT = 1;

    // ── Preconditions at the pin ─────────────────────────────────────────────
    uint256 internal constant PUBLISHED_CAP = 10_000_000 * ONE_USDC;
    uint256 internal constant EXPOSURE_AT_PIN = 30 * ONE_USDC;
    uint256 internal constant PUBLISHED_HEADROOM = 9_999_970 * ONE_USDC;
    uint256 internal constant KUSD_SUPPLY_AT_PIN = 1_144_707_154_000_000_000_000; // 1,144.707154 kUSD
    uint256 internal constant SKUSD_ASSETS_AT_PIN = 1_011_582_169_134_048_985_696; // 1,011.582169... kUSD

    // ── The exit ceiling actually available at the pin, per module ───────────
    // Largest kUSD redemption each module's own USDC reserve can settle. These
    // are the numbers that make the round trip below a MECHANISM demonstration
    // and not a liquidity claim.
    uint256 internal constant LIVE_MAX_EXIT_USDC = 30 * ONE_USDC; //          30.000000
    uint256 internal constant RETIRED_MAX_EXIT_USDC = 995_003_000; //        995.003000
    uint256 internal constant V1_MAX_EXIT_USDC = 85_885_006; //               85.885006
    // The largest kUSD redemption the deepest module can settle, to the wei.
    // Derived from its balance and the 10 bps tier, then walked to its edge in
    // test_theExitIsBoundedByReserveDepthNotByTheContract: this amount pays out
    // the module's entire reserve, and ONE WEI more reverts.
    uint256 internal constant RETIRED_MAX_EXIT_KUSD = 995_998_999_999_999_999_998;

    // `InsufficientStableReserves()`, the revert a redemption raises when the
    // module cannot fund it. Named so a reader can match it against the selector
    // printed on the page.
    bytes4 internal constant INSUFFICIENT_STABLE_RESERVES = 0x49d5a855;

    // Derived from a string rather than typed, so a reader can regenerate it:
    //     cast wallet address --private-key $(cast keccak "kerne round trip depositor")
    //
    // It is NOT a hand-picked vanity address, and that distinction cost a
    // rewrite. The obvious choice, address(0xA11CE), turns out to hold 22 USDC
    // on Base: somebody has been sending funds to the vanity constant. Nothing
    // in the round trip depends on the depositor being empty, because `deal`
    // SETS a balance rather than adding to one, but a file that claims its
    // depositor is a stranger owes the reader an address that actually is one.
    // test_theDepositorIsAStrangerToThisProtocol asserts it, on chain, at the pin.
    address internal depositor = makeAddr("kerne round trip depositor");
    address internal exiter = makeAddr("kerne round trip exiter");

    address internal constant EXPECTED_DEPOSITOR = 0xa72F3e0ddb8Fbdf4594cdc614528d95Ea46f2Eb9;
    address internal constant EXPECTED_EXITER = 0x5DB086ACDa2E3b76455778d6DAc69cd0f374d204;

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
            emit log("SKIPPED: set BASE_RPC_URL to execute the round trip against Base");
            return;
        }
        _;
    }

    // ── Preconditions ────────────────────────────────────────────────────────

    /// @notice Everything the round trip depends on, read rather than assumed.
    ///
    /// @dev Each of these would silently falsify the trip if it flipped, so
    ///      they are asserted here instead of being taken on trust inside the
    ///      trip itself. If this test fails, nothing else in the file means
    ///      what it says.
    function test_thePreconditionsAreWhatKernePublishes() public onlyForked {
        IPsm psm = IPsm(LIVE_MINT_PSM);

        assertEq(psm.stableCaps(USDC), PUBLISHED_CAP, "the USDC concentration cap is ten million");
        assertEq(psm.currentExposure(USDC), EXPOSURE_AT_PIN, "tracked exposure at the pin");
        assertEq(IErc20Like(USDC).balanceOf(LIVE_MINT_PSM), EXPOSURE_AT_PIN, "and the module holds the same");
        assertEq(psm.stableCaps(USDC) - EXPOSURE_AT_PIN, PUBLISHED_HEADROOM, "9,999,970 USDC of headroom");

        assertFalse(psm.paused(), "not paused");
        assertTrue(psm.mintingEnabled(), "minting enabled");
        assertTrue(psm.supportedStables(USDC), "USDC is a supported stable");
        assertTrue(IErc20Like(KUSD).hasRole(MINTER_ROLE, LIVE_MINT_PSM), "and this module can mint kUSD");

        // The staking leg is open to anyone. An ERC-4626 vault that capped
        // deposits would break the trip at leg two without touching the PSM.
        assertEq(IStakedKusd(SKUSD).maxDeposit(depositor), type(uint256).max, "skUSD caps nobody");

        assertEq(IErc20Like(KUSD).totalSupply(), KUSD_SUPPLY_AT_PIN, "kUSD supply at the pin");
        assertEq(IStakedKusd(SKUSD).totalAssets(), SKUSD_ASSETS_AT_PIN, "staked kUSD at the pin");
    }

    /// @notice The address doing this has never touched Kerne, or anything else.
    ///
    /// @dev The claim being defended is "no allowlist, no application, no prior
    ///      relationship". An address that already held kUSD, or that the
    ///      protocol had ever granted a role, would not defend it.
    function test_theDepositorIsAStrangerToThisProtocol() public onlyForked {
        // Pinned so the address on the published page is the address that runs.
        assertEq(depositor, EXPECTED_DEPOSITOR, "the depositor is the one the page names");
        assertEq(exiter, EXPECTED_EXITER, "and so is the exiter");

        address[2] memory strangers = [depositor, exiter];
        for (uint256 i = 0; i < strangers.length; i++) {
            address who = strangers[i];
            assertEq(IErc20Like(USDC).balanceOf(who), 0, "no USDC");
            assertEq(IErc20Like(KUSD).balanceOf(who), 0, "no kUSD");
            assertEq(IErc20Like(SKUSD).balanceOf(who), 0, "no skUSD");
            assertEq(who.balance, 0, "no ETH");
            assertEq(who.code.length, 0, "not a contract");
            assertEq(vm.getNonce(who), 0, "and it has never sent a transaction");

            // No role on the token, and none on the module it is about to use.
            assertFalse(IErc20Like(KUSD).hasRole(MINTER_ROLE, who), "holds no minter role");
            assertFalse(IErc20Like(LIVE_MINT_PSM).hasRole(0x00, who), "and no admin role on the module it uses");
        }
    }

    // ── The trip ─────────────────────────────────────────────────────────────

    /// @notice One million USDC in, and back out again, through deployed bytecode.
    ///
    /// @dev Seven calls: approve, mint, approve, stake, unstake, approve, redeem.
    ///      Every intermediate figure is asserted, because the interesting part
    ///      of a round trip is not that it terminates, it is where the money
    ///      goes at each hop.
    function test_aMillionDollarRoundTripCompletes() public onlyForked {
        IPsm psm = IPsm(LIVE_MINT_PSM);

        deal(USDC, depositor, DEPOSIT_USDC);
        vm.startPrank(depositor);

        // Leg 1. Mint. 5 bps, read from the chain rather than assumed.
        assertEq(psm.getFee(USDC, DEPOSIT_USDC), MINT_FEE_USDC, "5 bps at a million");
        IErc20Like(USDC).approve(LIVE_MINT_PSM, DEPOSIT_USDC);
        psm.swapStableForKUSD(USDC, DEPOSIT_USDC);
        assertEq(IErc20Like(KUSD).balanceOf(depositor), KUSD_MINTED, "999,500 kUSD received");
        assertEq(IErc20Like(USDC).balanceOf(depositor), 0, "and the USDC left the depositor");

        // Leg 2. Stake. The vault's assets rise by exactly what went in.
        uint256 vaultAssetsBefore = IStakedKusd(SKUSD).totalAssets();
        IErc20Like(KUSD).approve(SKUSD, KUSD_MINTED);
        uint256 shares = IStakedKusd(SKUSD).deposit(KUSD_MINTED, depositor);
        assertGt(shares, 0, "shares issued");
        assertEq(IStakedKusd(SKUSD).totalAssets(), vaultAssetsBefore + KUSD_MINTED, "the vault holds the deposit");
        assertEq(IErc20Like(KUSD).balanceOf(depositor), 0, "the kUSD is staked, not held");

        // Leg 3. Unstake. Same block, so no yield has vested and none is owed.
        uint256 kusdBack = IStakedKusd(SKUSD).redeem(shares, depositor, depositor);
        assertEq(kusdBack, KUSD_AFTER_STAKING, "999,500 kUSD back, less one wei");
        assertEq(IErc20Like(SKUSD).balanceOf(depositor), 0, "no shares left");

        // Leg 4. Redeem. 7 bps, because 999,500 is below the million tier.
        IErc20Like(KUSD).approve(LIVE_MINT_PSM, kusdBack);
        psm.swapKUSDForStable(USDC, kusdBack);
        vm.stopPrank();

        assertEq(IErc20Like(USDC).balanceOf(depositor), RETURNED_USDC, "998,800.35 USDC returned");
        assertEq(IErc20Like(KUSD).balanceOf(depositor), 0, "and no kUSD is left over");

        // The whole point, in one line.
        uint256 cost = DEPOSIT_USDC - IErc20Like(USDC).balanceOf(depositor);
        assertEq(cost, ROUND_TRIP_COST_USDC, "1,199.65 USDC of round trip cost");
        // 11.9965 bps, expressed without floating point: cost * 1e8 / deposit
        // is bps to four decimal places.
        assertEq((cost * 1e8) / DEPOSIT_USDC, 119_965, "11.9965 basis points");
    }

    /// @notice The cost is 12 bps and not 10 because of a tier boundary.
    ///
    /// @dev This is the arithmetic a reader is most likely to get wrong on
    ///      their own, so it is asserted rather than explained. The mint enters
    ///      at the 1,000,000 tier. What comes back is 999,500, which is 500
    ///      short of that tier, so the exit prices one step up the ladder.
    ///      Redeeming a round million would cost 5 bps; redeeming the proceeds
    ///      of a round million costs 7.
    function test_theRoundTripCostsTwelveBpsBecauseOfATierBoundary() public onlyForked {
        IPsm psm = IPsm(LIVE_MINT_PSM);

        // The ladder, read at the pin. Sizes are in USDC native units.
        assertEq(psm.getFee(USDC, 1_000_000 * ONE_USDC), 500 * ONE_USDC, "5 bps at 1,000,000");
        assertEq(psm.getFee(USDC, 999_500 * ONE_USDC), 699_650_000, "7 bps at 999,500");
        assertEq(psm.getFee(USDC, 250_000 * ONE_USDC), 175 * ONE_USDC, "7 bps at 250,000");
        assertEq(psm.getFee(USDC, 50_000 * ONE_USDC), 40 * ONE_USDC, "8 bps at 50,000");
        assertEq(psm.getFee(USDC, 1_000 * ONE_USDC), ONE_USDC, "10 bps below the ladder");

        // 5 in plus 7 out is 12, and the 0.0035 bps shortfall from 12 is the
        // fee being charged on 999,500 rather than on 1,000,000.
        uint256 mintFee = psm.getFee(USDC, DEPOSIT_USDC);
        uint256 redeemFeeStable = REDEEM_FEE_KUSD / SCALE;
        assertEq(mintFee + redeemFeeStable + 1, ROUND_TRIP_COST_USDC, "the two legs are the whole cost");
    }

    /// @notice The staking leg gives back one wei less than it took, and the
    ///         wei stays with the vault rather than going anywhere else.
    ///
    /// @dev ERC-4626 rounds shares down on deposit and assets down on redeem,
    ///      so a same-block in-and-out cannot be exactly lossless. Stated here
    ///      because "999,500 in, 999,500 out" would be the tidier sentence and
    ///      it is false by one wei. The wei is a rounding gain to whoever is
    ///      still staked, which at the pin is the protocol's own position.
    function test_theStakingLegReturnsAllButOneWei() public onlyForked {
        uint256 vaultAssetsBefore = IStakedKusd(SKUSD).totalAssets();

        deal(KUSD, depositor, KUSD_MINTED, true);
        vm.startPrank(depositor);
        IErc20Like(KUSD).approve(SKUSD, KUSD_MINTED);
        uint256 shares = IStakedKusd(SKUSD).deposit(KUSD_MINTED, depositor);
        uint256 back = IStakedKusd(SKUSD).redeem(shares, depositor, depositor);
        vm.stopPrank();

        assertEq(back, KUSD_MINTED - 1, "one wei short");
        assertEq(IStakedKusd(SKUSD).totalAssets(), vaultAssetsBefore + 1, "and the vault kept it");
    }

    /// @notice A completed round trip leaves kUSD supply where it found it, and
    ///         leaves the protocol richer by exactly the fees.
    ///
    /// @dev The live module is the audited build, which BURNS the kUSD returned
    ///      on the redeem leg (KRN-26-PSM-REDEEM-NO-BURN, 2026-07-06). Without
    ///      that fix the returned kUSD would sit in the module as dead
    ///      inventory while the next mint minted afresh, so a caller paying only
    ///      fees could inflate reported supply without bound. This asserts the
    ///      fix at size: supply ends one wei above where it started, and the wei
    ///      is the one the vault kept in the test above, not a rounding gift.
    function test_theRoundTripNetsToFeesOnly() public onlyForked {
        IPsm psm = IPsm(LIVE_MINT_PSM);

        uint256 supplyBefore = IErc20Like(KUSD).totalSupply();
        uint256 psmUsdcBefore = IErc20Like(USDC).balanceOf(LIVE_MINT_PSM);
        uint256 ledgerBefore = psm.accruedFees(USDC);

        _runTheTrip();

        assertEq(IErc20Like(KUSD).totalSupply(), supplyBefore + 1, "kUSD supply returns to within the staking wei");
        assertEq(IErc20Like(KUSD).balanceOf(LIVE_MINT_PSM), 0, "the module parked no kUSD: it burned it");

        assertEq(
            IErc20Like(USDC).balanceOf(LIVE_MINT_PSM),
            psmUsdcBefore + ROUND_TRIP_COST_USDC,
            "the module keeps exactly what the depositor paid"
        );

        // The ledger that governs skimSurplus records one stable-wei less than
        // the module actually holds. That is the documented flooring in
        // _swapKUSDForStableInner, and the direction is deliberate: it can
        // never over-skim into backing.
        assertEq(
            psm.accruedFees(USDC),
            ledgerBefore + ROUND_TRIP_COST_USDC - LEDGER_UNDERCOUNT,
            "the fee ledger floors one stable-wei below the cash, never above"
        );
    }

    // ── The bound that matters ───────────────────────────────────────────────

    /// @notice The exit is limited by reserve depth, not by the contract, and at
    ///         the pinned block that depth is 995.003 USDC.
    ///
    /// @dev THIS IS THE TEST THAT KEEPS THE REST OF THE FILE HONEST, and it is
    ///      asserted in three directions:
    ///
    ///        1. Present the live module with 999,500 kUSD and no preceding
    ///           mint and it reverts InsufficientStableReserves. The round trip
    ///           above closes only because the mint one line earlier is what
    ///           funded it.
    ///        2. The largest redemption each module can actually settle today
    ///           is its own USDC balance. Nothing pools them; a holder picks a
    ///           module and is bounded by that module.
    ///        3. The deepest of the three settles 995.003 USDC and drains to
    ///           zero doing it, and one kUSD more reverts.
    ///
    ///      So "a million dollars can round trip" is a statement about the
    ///      mechanism at size. It is not a statement about liquidity, and this
    ///      file must never be cited as one.
    function test_theExitIsBoundedByReserveDepthNotByTheContract() public onlyForked {
        // 1. No mint first, so no reserve. The same call that succeeds above
        //    fails here, and the difference is entirely the reserve.
        deal(KUSD, depositor, KUSD_MINTED, true);
        vm.startPrank(depositor);
        IErc20Like(KUSD).approve(LIVE_MINT_PSM, KUSD_MINTED);
        vm.expectRevert(INSUFFICIENT_STABLE_RESERVES);
        IPsm(LIVE_MINT_PSM).swapKUSDForStable(USDC, KUSD_MINTED);
        vm.stopPrank();

        // 2. What each module can actually settle, which is what it holds.
        assertEq(IErc20Like(USDC).balanceOf(LIVE_MINT_PSM), LIVE_MAX_EXIT_USDC, "live module reserve");
        assertEq(IErc20Like(USDC).balanceOf(RETIRED_MINT_PSM), RETIRED_MAX_EXIT_USDC, "retired module reserve");
        assertEq(IErc20Like(USDC).balanceOf(V1_REDEEM_PSM), V1_MAX_EXIT_USDC, "v1 module reserve");

        // 3. The deepest one, walked to its edge the way the cap test walks the
        //    mint. The last kUSD that can leave, and one WEI more.
        deal(KUSD, exiter, RETIRED_MAX_EXIT_KUSD + 1, true);
        vm.startPrank(exiter);
        IErc20Like(KUSD).approve(RETIRED_MINT_PSM, RETIRED_MAX_EXIT_KUSD + 1);
        vm.expectRevert(INSUFFICIENT_STABLE_RESERVES);
        IPsm(RETIRED_MINT_PSM).swapKUSDForStable(USDC, RETIRED_MAX_EXIT_KUSD + 1);

        IPsm(RETIRED_MINT_PSM).swapKUSDForStable(USDC, RETIRED_MAX_EXIT_KUSD);
        vm.stopPrank();

        assertEq(IErc20Like(USDC).balanceOf(exiter), RETIRED_MAX_EXIT_USDC, "995.003 USDC is the whole of it");
        assertEq(IErc20Like(USDC).balanceOf(RETIRED_MINT_PSM), 0, "and the module is empty afterwards");
    }

    /// @notice The three reserves do not pool, so the system-wide single
    ///         transaction exit is the largest module, not the sum.
    ///
    /// @dev 1,110.888006 USDC exists across the three modules. A holder cannot
    ///      reach it in one call, and the honest ceiling to quote is 995.003.
    function test_theThreeReservesDoNotPool() public onlyForked {
        uint256 total = IErc20Like(USDC).balanceOf(LIVE_MINT_PSM) + IErc20Like(USDC).balanceOf(RETIRED_MINT_PSM)
            + IErc20Like(USDC).balanceOf(V1_REDEEM_PSM);

        assertEq(total, 1_110_888_006, "1,110.888006 USDC in total");
        assertGt(total, RETIRED_MAX_EXIT_USDC, "which is strictly more than any one module can settle");
    }

    // ── Helper ───────────────────────────────────────────────────────────────

    /// @dev The same seven calls as test_aMillionDollarRoundTripCompletes,
    ///      without the intermediate assertions, so the invariant tests above
    ///      read as invariants rather than as a second copy of the trip.
    function _runTheTrip() internal {
        deal(USDC, depositor, DEPOSIT_USDC);
        vm.startPrank(depositor);

        IErc20Like(USDC).approve(LIVE_MINT_PSM, DEPOSIT_USDC);
        IPsm(LIVE_MINT_PSM).swapStableForKUSD(USDC, DEPOSIT_USDC);

        uint256 minted = IErc20Like(KUSD).balanceOf(depositor);
        IErc20Like(KUSD).approve(SKUSD, minted);
        uint256 shares = IStakedKusd(SKUSD).deposit(minted, depositor);
        uint256 back = IStakedKusd(SKUSD).redeem(shares, depositor, depositor);

        IErc20Like(KUSD).approve(LIVE_MINT_PSM, back);
        IPsm(LIVE_MINT_PSM).swapKUSDForStable(USDC, back);

        vm.stopPrank();
    }
}
