// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

/// @notice Shared base for the Kerne mirror test suite.
///
/// @dev READ THIS BEFORE ADDING A TEST THAT MOVES TIME.
///
///      This project builds with `via_ir = true` and the optimizer on, to match
///      how every mirrored bundle was verified. Under those settings solc is
///      entitled to common-subexpression-eliminate repeated `block.timestamp`
///      reads, because on a real chain the timestamp genuinely cannot change
///      inside a single transaction. `vm.warp` breaks that assumption, so the
///      common Foundry idiom
///
///          vm.warp(block.timestamp + 12 hours);   // once: fine
///          ...
///          vm.warp(block.timestamp + 12 hours);   // twice in one function: NOT fine
///
///      can silently warp to the SAME timestamp twice. The second call re-uses the
///      cached first read, time does not advance, and the test quietly asserts
///      against a state it never reached. It does not revert and it does not warn.
///      It cost a real debugging round here: a vesting test read half the yield as
///      still locked twenty-four hours after a twenty-four hour vest began.
///
///      Use `_startClock` once and `_advance` thereafter. `clock` lives in storage,
///      so it cannot be folded into a cached TIMESTAMP read, and every warp is an
///      absolute value the compiler cannot second-guess.
abstract contract KerneTest is Test {
    /// @notice The test's own view of wall-clock time, in seconds.
    uint256 internal clock;

    /// @notice Anchor the chain at a plausible timestamp. Foundry otherwise starts
    ///         at 1, which is inside every cooldown window these contracts define.
    function _startClock(uint256 startAt) internal {
        clock = startAt;
        vm.warp(startAt);
    }

    /// @notice Move time forward by `delta` seconds. Safe to call repeatedly inside
    ///         one test function.
    function _advance(uint256 delta) internal {
        clock += delta;
        vm.warp(clock);
    }
}
