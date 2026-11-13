// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Stand-in for a Coinbase B20 tokenized stock (8 decimals). Real B20s are precompiles, so an
///      anvil fork cannot execute them; the vault only uses the ERC-20 surface.
contract MockStock is ERC20 {
    mapping(address => bool) public blocked; // mimics a B20 policy blocklist

    constructor() ERC20("Tesla (Coinbase tokenized)", "TSLAc") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blocked[from] && !blocked[to], "B20: policy");
        super._update(from, to, v);
    }
}

/// @dev Chainlink-style aggregator with a full round history (8 decimals).
contract MockFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    uint80 public latest;
    mapping(uint80 => Round) public rounds;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function push(int256 answer, uint256 updatedAt) external returns (uint80 id) {
        id = ++latest;
        rounds[id] = Round(answer, updatedAt);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latest];
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[id];
        require(r.updatedAt != 0, "No data present.");
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}
