// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal ERC-20 used as a stand-in for WETH / USDC / KERNE in these tests.
/// @dev Deliberately dumb. Nothing here is a Kerne contract; it exists so the mirrored
///      sources under `contracts/` can be exercised without a network fork.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "MockERC20: allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Chainlink-shaped feed whose answer and `updatedAt` are settable, so the
///         PSM's staleness and depeg branches can both be driven deterministically.
contract MockAggregatorV3 {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 private _decimals;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, _updatedAt, _updatedAt, 0);
    }
}

/// @notice An Aerodrome-shaped router backed by a single settable exchange rate.
/// @dev The point of this mock is that `getAmountsOut` (what KerneTreasury previews
///      against) and `swapExactTokensForTokens` (what it executes against) read the
///      SAME rate, exactly like a real constant-product pool read and swapped inside
///      one transaction. Moving `rateBps` is the mock's stand-in for moving the pool.
///      The struct layout matches `IAerodromeRouter.Route`, so the selectors line up
///      without this mock inheriting the interface.
contract MockAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Output per unit of input, in basis points. 10000 = 1:1.
    uint256 public rateBps = 10_000;

    /// @notice When true, the pool reports no liquidity and previews revert.
    bool public dry;

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function setDry(bool d) external {
        dry = d;
    }

    function _out(uint256 amountIn) internal view returns (uint256) {
        return (amountIn * rateBps) / 10_000;
    }

    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory) {
        require(!dry, "MockRouter: no liquidity");
        uint256[] memory amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = _out(amountIn);
        }
        return amounts;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory) {
        uint256 out = _out(amountIn);
        require(out >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MockERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(routes[routes.length - 1].to).mint(to, out);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
        return amounts;
    }
}

/// @notice Answers only `convertToAssets(uint256)`, which is the single call
///         KerneYieldOracle makes against a registered vault.
/// @dev Used where the finding under test lives in the oracle's own consensus state
///      machine rather than in the vault, so standing up a 2,000-line vault would add
///      noise without adding evidence.
contract SharePriceStub {
    uint256 public price;

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        return price;
    }
}
