// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KerneCoveredCallVault, IAggregatorV3} from "../src/KerneCoveredCallVault.sol";

/// @notice Deploys one covered-call vault. Defaults to TSLAc on Base mainnet.
///         The vault deploys CLOSED (depositCap = 0). Opening it is a separate owner call.
///
///   Dry run (no broadcast):
///     OWNER=0x... KEEPER=0x... forge script script/Deploy.s.sol --rpc-url base
///   Broadcast from a hardware wallet:
///     OWNER=0x... KEEPER=0x... forge script script/Deploy.s.sol --rpc-url base --trezor --broadcast
contract Deploy is Script {
    address constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;
    address constant TSLA_FEED = 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4;

    function run() external returns (KerneCoveredCallVault vault) {
        address owner = vm.envAddress("OWNER");
        address keeper = vm.envAddress("KEEPER");
        address stock = vm.envOr("STOCK", TSLAC);
        address feed = vm.envOr("FEED", TSLA_FEED);
        string memory name = vm.envOr("NAME", string("Kerne Covered Call TSLAc"));
        string memory symbol = vm.envOr("SYMBOL", string("kccTSLAc"));
        require(owner != address(0) && keeper != address(0) && owner != keeper, "owner/keeper");
        require(IAggregatorV3(feed).decimals() == 8, "feed decimals");

        vm.startBroadcast();
        vault = new KerneCoveredCallVault(IERC20(stock), IAggregatorV3(feed), name, symbol, owner, keeper);
        vm.stopBroadcast();

        require(vault.depositCap() == 0, "must deploy closed");
        console2.log("vault", address(vault));
        console2.log("asset", vault.asset(), "feed", address(vault.feed()));
        console2.log("owner", vault.owner(), "keeper", vault.keeper());
    }
}
