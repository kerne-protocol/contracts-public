// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KerneCoveredCallVault, IAggregatorV3} from "../src/KerneCoveredCallVault.sol";
import {MockStock} from "./Mocks.sol";

/// @notice Runs one full epoch against the REAL Coinbase TSLA Chainlink feed on Base mainnet.
///         Opens at a past block, then rolls the fork forward to the latest block and settles with
///         the real first-round-after-expiry. The stock is a mock because B20 tokens are
///         precompiles that an anvil fork cannot execute.
///         Run: FORK_TESTS=1 forge test --match-contract ForkTslaFeed -vv
contract ForkTslaFeedTest is Test {
    IAggregatorV3 constant TSLA_FEED = IAggregatorV3(0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4);

    function test_fullEpochOnRealFeed() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        string memory rpc = vm.envOr("BASE_RPC", string("https://mainnet.base.org"));

        uint256 latestFork = vm.createSelectFork(rpc);
        uint256 head = block.number;
        uint256 openBlock = head - vm.envOr("BLOCKS_BACK", uint256(86_400 * 5 * 2)); // ~2 days at 200ms blocks
        vm.createSelectFork(rpc, openBlock);
        latestFork; // silence

        address owner = makeAddr("owner");
        address keeper = makeAddr("keeper");
        address lp = makeAddr("lp");
        address buyer = makeAddr("buyer");
        MockStock stock = new MockStock();
        KerneCoveredCallVault vault =
            new KerneCoveredCallVault(IERC20(address(stock)), TSLA_FEED, "Kerne Covered Call TSLAc", "kccTSLAc", owner, keeper);
        vm.makePersistent(address(stock), address(vault));

        vm.prank(owner);
        vault.setParams(100e8, 25 hours, 300, 10, 1 days, 35 days, 7 days, 12 hours);
        stock.mint(lp, 10e8);
        stock.mint(buyer, 1e8);
        vm.prank(lp);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(buyer);
        stock.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(10e8, lp);

        uint256 spot = vault.spotPrice();
        console2.log("open block", openBlock, block.timestamp, spot);
        uint256 strike = spot * 105 / 100;
        uint256 expiry = block.timestamp + 1 days + 1 hours;
        vm.prank(keeper);
        vault.openEpoch(strike, 100, block.timestamp + 1 hours, expiry);
        vm.prank(buyer);
        vault.buyCall(10e8, type(uint256).max);

        // roll to head; vault + stock persist
        vm.createSelectFork(rpc, head);
        console2.log("head", block.number, block.timestamp, expiry);
        require(block.timestamp > expiry, "head not past expiry; raise BLOCKS_BACK");

        (uint80 r,,, uint256 upd,) = TSLA_FEED.latestRoundData();
        require(upd >= expiry, "feed has not updated since expiry");
        // walk back to the first round at/after expiry
        while (true) {
            (,,, uint256 prevUpd,) = TSLA_FEED.getRoundData(r - 1);
            if (prevUpd < expiry) break;
            r--;
        }
        (, int256 px,, uint256 at,) = TSLA_FEED.getRoundData(r);
        console2.log("settle round", uint256(r), "price", uint256(px));
        console2.log("round updatedAt", at, "expiry", expiry);

        vm.expectRevert(KerneCoveredCallVault.BadRoundHint.selector);
        vault.settle(r - 1); // the last pre-expiry round is rejected
        vault.settle(r);

        uint256 owed = vault.claimable(1, buyer);
        uint256 expected = uint256(px) > strike ? 10e8 * (uint256(px) - strike) / uint256(px) : 0;
        assertEq(owed, expected);
        assertEq(vault.totalAssets() + vault.unclaimedPayouts(), 10e8 + 1e7);
        console2.log("buyer payout (stock units)", owed, "vault assets", vault.totalAssets());
    }
}
