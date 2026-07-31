// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// KRN-26-VAULT-CR-BUCKET-BYPASS
// Red Halt must arm on every bucket that feeds the collateral ratio
//
// Found internally, fixed in source 2026-06-07, and independently rediscovered by
// an external researcher on 2026-07-28. That researcher has not confirmed public
// credit, so they are not named here; Kerne's standing rule is that a researcher
// is listed only after they ask to be. See
// https://kerne.fi/security/acknowledgments.
//
// Status:       FIXED AND LIVE. This is the good case, and the reason it is worth
//               having in a public suite. The live vault
//               0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B was deployed from
//               commit ecc95cf7 (2026-06-15), which is AFTER the 2026-06-07 fix,
//               so the bundle mirrored here already carries it. These tests pass
//               against the deployed bytecode's own source, which makes them a
//               proof of remediation rather than a disclosure.
//
// The defect that was closed: `totalAssets()` sums four buckets (tracked
// on-chain assets, off-chain assets, L1 (Hyperliquid sovereign vault) assets and
// the hedging reserve) so a loss reported through ANY of them lowers
// `getSolvencyRatio()`. But the Red Halt circuit breaker was only armed on
// `updateOffChainAssets`. A Hyperliquid hedge loss, reported through the hedging
// or L1 bucket, could therefore drive the vault below the 99% critical threshold
// without ever pausing it.
//
// Each test below drives the vault under CRITICAL_CR_THRESHOLD through one bucket
// and asserts the breaker armed and the vault paused. If a future edit unwires any
// bucket, exactly one of these fails and names it.
// ─────────────────────────────────────────────────────────────────────────────

import { KerneTest } from "../helpers/KerneTest.sol";
import { KerneVault } from "../../contracts/KerneVault/src/KerneVault.sol";
import { IERC20 } from "../../contracts/KerneVault/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../helpers/Mocks.sol";

contract VaultCircuitBreakerBucketsTest is KerneTest {
    KerneVault internal vault;
    MockERC20 internal weth;

    address internal admin = makeAddr("safe");
    address internal strategist = makeAddr("strategist");
    address internal depositor = makeAddr("depositor");

    uint256 internal constant DEPOSIT = 10 ether;

    /// @dev Assets parked off the vault's on-chain balance, ready to be reported
    ///      back through whichever bucket a given test exercises.
    uint256 internal parked;

    function setUp() public {
        // Foundry starts at block.timestamp == 1. The per-bucket cooldown check is
        // `block.timestamp < lastWrite + offChainUpdateCooldown`, and lastWrite is 0,
        // so even the first strategist write would revert UpdateCooldownNotMet at
        // t=1. Start the chain somewhere plausible instead.
        _startClock(1_700_000_000);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vault = new KerneVault(
            IERC20(address(weth)), "Kerne WETH Vault", "kWETH", admin, strategist, makeAddr("exchange")
        );

        weth.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        weth.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, depositor);
        vm.stopPrank();

        // The ordinary lifecycle: user WETH is swept out to the venue, and the
        // strategist then reports it back through one of the accounting buckets.
        parked = vault.totalAssets();
        vm.prank(admin);
        vault.sweepToExchange(parked);

        assertEq(vault.totalAssets(), 0, "all assets are off the vault's own balance");
        assertFalse(vault.crCircuitBreakerActive(), "breaker starts disarmed");
    }

    /// @dev Report `parked` into a bucket, then report a 15% drawdown on it. 15% is
    ///      inside the 2000 bps per-write rate limit, so this is an ordinary report,
    ///      not an attempt to bypass the rate limiter.
    function _reportThenDrawdown(bytes4 setter) internal {
        (bool ok,) = address(vault).call(abi.encodeWithSelector(setter, parked));
        require(ok, "initial bucket write failed");

        _advance(11 minutes); // clear the 10-minute per-bucket cooldown

        (ok,) = address(vault).call(abi.encodeWithSelector(setter, (parked * 8500) / 10_000));
        require(ok, "drawdown write failed");
    }

    function _assertHalted() internal view {
        assertLt(vault.getSolvencyRatio(), vault.CRITICAL_CR_THRESHOLD(), "vault is under the 99% critical threshold");
        assertTrue(vault.crCircuitBreakerActive(), "Red Halt armed");
        assertTrue(vault.paused(), "and the vault paused itself");
    }

    /// @notice The bucket the breaker was always wired to. Control case.
    function test_redHaltArmsOnTheOffChainAssetsBucket() public {
        vm.startPrank(strategist);
        _reportThenDrawdown(KerneVault.updateOffChainAssets.selector);
        vm.stopPrank();
        _assertHalted();
    }

    /// @notice The first bucket the 2026-06-07 fix wired in. A Hyperliquid hedge
    ///         loss arrives here.
    function test_redHaltArmsOnTheHedgingReserveBucket() public {
        vm.startPrank(strategist);
        _reportThenDrawdown(KerneVault.updateHedgingReserve.selector);
        vm.stopPrank();
        _assertHalted();
    }

    /// @notice The second bucket the fix wired in. A sovereign-vault drawdown
    ///         arrives here.
    function test_redHaltArmsOnTheL1AssetsBucket() public {
        vm.startPrank(strategist);
        _reportThenDrawdown(KerneVault.updateL1Assets.selector);
        vm.stopPrank();
        _assertHalted();
    }

    /// @notice A drawdown that does not breach the threshold must NOT halt the
    ///         vault. Without this, the three tests above would also pass on a
    ///         contract that paused on every write, which would prove nothing.
    function test_aShallowDrawdownDoesNotArmTheBreaker() public {
        vm.startPrank(strategist);
        vault.updateL1Assets(parked);
        _advance(11 minutes);
        vault.updateL1Assets((parked * 9950) / 10_000); // 0.5% down, still over 99%
        vm.stopPrank();

        assertGe(vault.getSolvencyRatio(), vault.CRITICAL_CR_THRESHOLD());
        assertFalse(vault.crCircuitBreakerActive(), "breaker stays disarmed above the threshold");
        assertFalse(vault.paused(), "and the vault stays open");
    }

    /// @notice The thresholds themselves, pinned. A silent widening of the critical
    ///         band would defeat every test above without failing any of them.
    function test_thresholdsAreWhatTheDisclosureSays() public view {
        assertEq(vault.CRITICAL_CR_THRESHOLD(), 9_900, "Red Halt at 99%");
        assertEq(vault.WARNING_CR_THRESHOLD(), 10_000, "soft alert at 100%");
        assertEq(vault.SAFE_CR_THRESHOLD(), 10_100, "recovery at 101%");
    }
}
