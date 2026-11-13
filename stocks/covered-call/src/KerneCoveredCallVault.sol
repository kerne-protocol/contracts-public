// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Chainlink V3 aggregator surface used by the vault.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title KerneCoveredCallVault
/// @notice An ERC-4626 covered-call desk over ONE tokenized stock on Base (a Coinbase B20 token,
///         for example TSLAc). Depositors supply the stock. Each epoch the keeper lists an
///         out-of-the-money call on the vault's own stock, inside owner-set bounds. Buyers pay the
///         premium in the stock itself and receive a cash-settled-in-kind payoff at expiry:
///             payout (stock units) = notional * max(0, P - K) / P
///         where P is the Chainlink total-return price of the token at expiry and K the strike.
///         Single-asset accounting: the vault never holds anything but the stock.
///
/// @dev Design rules (each one closes a specific attack):
///      - Deposits and withdrawals only happen while NO epoch is live, so nobody can enter after a
///        sale to skim premium, or exit ahead of an in-the-money settlement.
///      - Premium is excluded from totalAssets until settlement and only then becomes depositor yield.
///      - Calls sold can never exceed the assets frozen at epoch open, and payout <= notional,
///        so the vault is solvent for every price path.
///      - Every sale re-checks that the strike is still minOtmBps above a fresh spot, so an option
///        that has moved into the money can no longer be bought at the premium quoted at open.
///      - Settlement price is the FIRST Chainlink round at or after expiry in the current phase,
///        proven with a round hint (round.updatedAt >= expiry > previous.updatedAt). The fallback
///        only applies where no hint can exist and yields one price, so no settler can choose.
///      - Trust assumptions: the keeper prices premium (bounded below by owner floors); depositors
///        who disagree exit in the window. Share value ignores live in-the-money liability, so
///        integrators must not price shares with convertToAssets while epochLive is true.
///      - After every settlement depositors get an idleWindow in which no epoch can open, so the
///        keeper can never chain epochs to lock exits.
///      - Every transfer out is a pull (claim/redeem); one blocked address can never jam others.
///      - The Chainlink feed already includes the B20 multiplier (total return per token), so the
///        vault works purely in token units and needs no multiplier math.
///
///      NOT AUDITED. Built for the Base "Stocks Maxxing" builder competition. Coinbase tokenized
///      stocks are not available to US persons; this contract offers nothing to US persons.
contract KerneCoveredCallVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant DEAD_FEED_DELAY = 30 days;
    /// @dev Sales need a price at most this old. The feed freezes off-hours while B20s trade 24/7,
    ///      so sales effectively run only in and just after US market hours.
    uint256 public constant BUY_MAX_STALENESS = 4 hours;

    struct Epoch {
        uint128 strike; // feed decimals
        uint64 saleEnd; // buyers can buy while block.timestamp < saleEnd
        uint64 expiry;
        uint32 premiumBps; // premium = notional * premiumBps / BPS, paid in the stock
        uint128 capacity; // max notional (stock units), frozen at open = totalAssets()
        uint128 sold; // notional sold
        uint128 premium; // premium collected
        uint128 settlePrice; // feed decimals, 0 until settled
        uint128 payoutTotal; // stock owed to all buyers, rounded up
        bool settled;
    }

    IAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;

    address public keeper;
    uint256 public depositCap; // max totalAssets after a deposit
    uint256 public maxStaleness; // seconds, for the spot read at epoch open
    uint256 public minOtmBps; // strike >= spot * (1 + minOtmBps)
    uint256 public minPremiumBps;
    uint256 public minDuration;
    uint256 public maxDuration;
    uint256 public fallbackDelay; // after expiry + this, latestRoundData may settle
    uint256 public idleWindow; // guaranteed deposit/withdraw window between epochs
    uint256 public lastSettledAt;
    bool public salesPaused;

    uint256 public currentEpoch; // 0 = none opened yet
    bool public epochLive;
    uint256 public unclaimedPayouts; // stock reserved for buyers of settled epochs

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => uint256) public fallbackDelayOf; // frozen at open
    mapping(uint256 => mapping(address => uint256)) public notionalOf;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event KeeperSet(address keeper);
    event ParamsSet(uint256 depositCap, uint256 maxStaleness, uint256 minOtmBps, uint256 minPremiumBps, uint256 minDuration, uint256 maxDuration, uint256 fallbackDelay, uint256 idleWindow);
    event SalesPaused(bool paused);
    event EpochOpened(uint256 indexed epoch, uint256 strike, uint256 spot, uint256 premiumBps, uint256 saleEnd, uint256 expiry, uint256 capacity);
    event CallBought(uint256 indexed epoch, address indexed buyer, uint256 notional, uint256 premium);
    event EpochSettled(uint256 indexed epoch, uint256 price, uint80 roundId, uint256 payoutTotal, uint256 premium);
    event Claimed(uint256 indexed epoch, address indexed buyer, address to, uint256 amount);

    error NotKeeper();
    error EpochIsLive();
    error NoLiveEpoch();
    error BadParams();
    error StalePrice();
    error StrikeTooLow();
    error PremiumTooLow();
    error BadDuration();
    error SaleClosed();
    error OverCapacity();
    error NotExpired();
    error BadRoundHint();
    error FallbackNotReady();
    error NothingToClaim();
    error Paused();
    error ExitWindowOpen();
    error UseHint();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        IERC20 stock,
        IAggregatorV3 feed_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address keeper_
    ) ERC20(name_, symbol_) ERC4626(stock) Ownable(owner_) {
        feed = feed_;
        feedDecimals = feed_.decimals();
        keeper = keeper_;
        // Conservative launch defaults; owner can tighten or loosen within sane limits.
        depositCap = 0; // closed until the owner opens it
        maxStaleness = 25 hours; // feed heartbeat is 24h in market hours
        minOtmBps = 300; // strike at least 3% above spot
        minPremiumBps = 10; // 0.10% of notional per epoch at minimum
        minDuration = 1 days;
        maxDuration = 35 days;
        fallbackDelay = 7 days;
        idleWindow = 12 hours;
        emit KeeperSet(keeper_);
    }

    // ------------------------------------------------------------------ admin

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setParams(
        uint256 depositCap_,
        uint256 maxStaleness_,
        uint256 minOtmBps_,
        uint256 minPremiumBps_,
        uint256 minDuration_,
        uint256 maxDuration_,
        uint256 fallbackDelay_,
        uint256 idleWindow_
    ) external onlyOwner {
        if (
            maxStaleness_ == 0 || maxStaleness_ > 3 days || minOtmBps_ == 0 || minOtmBps_ > 5_000
                || minPremiumBps_ == 0 || minPremiumBps_ >= BPS || minDuration_ == 0 || minDuration_ > maxDuration_
                || maxDuration_ > 90 days || fallbackDelay_ < 4 days || fallbackDelay_ > 30 days
                || idleWindow_ < 1 hours || idleWindow_ > 7 days
        ) revert BadParams();
        depositCap = depositCap_;
        maxStaleness = maxStaleness_;
        minOtmBps = minOtmBps_;
        minPremiumBps = minPremiumBps_;
        minDuration = minDuration_;
        maxDuration = maxDuration_;
        fallbackDelay = fallbackDelay_;
        idleWindow = idleWindow_;
        emit ParamsSet(depositCap_, maxStaleness_, minOtmBps_, minPremiumBps_, minDuration_, maxDuration_, fallbackDelay_, idleWindow_);
    }

    function setSalesPaused(bool paused) external onlyOwner {
        salesPaused = paused;
        emit SalesPaused(paused);
    }

    // ------------------------------------------------------------------ accounting

    /// @notice Stock that belongs to depositors: balance minus premium not yet earned and
    ///         minus payouts owed to buyers of settled epochs.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = unclaimedPayouts;
        if (epochLive) reserved += epochs[currentEpoch].premium;
        return bal > reserved ? bal - reserved : 0;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (epochLive) return 0;
        uint256 ta = totalAssets();
        return depositCap > ta ? depositCap - ta : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 d = maxDeposit(receiver);
        return d == 0 ? 0 : _convertToShares(d, Math.Rounding.Floor);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return epochLive ? 0 : super.maxWithdraw(owner_);
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return epochLive ? 0 : super.maxRedeem(owner_);
    }

    /// @dev Virtual shares: makes first-depositor inflation attacks unprofitable.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ------------------------------------------------------------------ epochs

    /// @notice Spot price from the feed, reverting if non-positive or older than maxStaleness.
    function spotPrice() public view returns (uint256) {
        return _freshSpot(maxStaleness);
    }

    function _freshSpot(uint256 staleness) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > staleness) {
            revert StalePrice();
        }
        return uint256(answer);
    }

    /// @notice Keeper lists this epoch's call. Freezes deposits/withdrawals until settlement.
    function openEpoch(uint256 strike, uint256 premiumBps, uint256 saleEnd, uint256 expiry)
        external
        onlyKeeper
        returns (uint256 id)
    {
        if (epochLive) revert EpochIsLive();
        if (salesPaused) revert Paused();
        if (lastSettledAt != 0 && block.timestamp < lastSettledAt + idleWindow) revert ExitWindowOpen();
        uint256 spot = spotPrice();
        if (strike < spot.mulDiv(BPS + minOtmBps, BPS, Math.Rounding.Ceil) || strike > type(uint128).max) {
            revert StrikeTooLow();
        }
        if (premiumBps < minPremiumBps || premiumBps >= BPS) revert PremiumTooLow();
        if (saleEnd <= block.timestamp || saleEnd > expiry) revert BadDuration();
        uint256 dur = expiry - block.timestamp;
        if (dur < minDuration || dur > maxDuration) revert BadDuration();

        uint256 capacity = totalAssets();
        id = ++currentEpoch;
        epochs[id] = Epoch({
            strike: SafeCast.toUint128(strike),
            saleEnd: SafeCast.toUint64(saleEnd),
            expiry: SafeCast.toUint64(expiry),
            premiumBps: SafeCast.toUint32(premiumBps),
            capacity: SafeCast.toUint128(capacity),
            sold: 0,
            premium: 0,
            settlePrice: 0,
            payoutTotal: 0,
            settled: false
        });
        fallbackDelayOf[id] = fallbackDelay;
        epochLive = true;
        emit EpochOpened(id, strike, spot, premiumBps, saleEnd, expiry, capacity);
    }

    /// @notice Premium (stock units) for `notional` in the live epoch, rounded up.
    function quotePremium(uint256 notional) public view returns (uint256) {
        return notional.mulDiv(epochs[currentEpoch].premiumBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Buy `notional` stock units of the live epoch's call. Premium is pulled in the stock.
    function buyCall(uint256 notional, uint256 maxPremium) external nonReentrant returns (uint256 premium) {
        if (!epochLive) revert NoLiveEpoch();
        if (salesPaused) revert Paused();
        uint256 id = currentEpoch;
        Epoch storage e = epochs[id];
        if (block.timestamp >= e.saleEnd) revert SaleClosed();
        // The call must still be out of the money by minOtmBps at the moment of sale, so nobody
        // can buy intrinsic value at a premium quoted for an OTM option.
        if (e.strike < _freshSpot(BUY_MAX_STALENESS).mulDiv(BPS + minOtmBps, BPS, Math.Rounding.Ceil)) {
            revert StrikeTooLow();
        }
        if (notional == 0 || uint256(e.sold) + notional > e.capacity) revert OverCapacity();
        premium = quotePremium(notional);
        if (premium == 0 || premium > maxPremium) revert PremiumTooLow();

        e.sold = SafeCast.toUint128(uint256(e.sold) + notional);
        e.premium = SafeCast.toUint128(uint256(e.premium) + premium);
        notionalOf[id][msg.sender] += notional;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), premium);
        emit CallBought(id, msg.sender, notional, premium);
    }

    /// @notice Settle the live epoch at the first feed round at or after expiry.
    /// @param roundId proxy round id in the feed's CURRENT phase whose updatedAt >= expiry while
    ///        the previous round of the same phase has updatedAt < expiry.
    function settle(uint80 roundId) external nonReentrant {
        Epoch storage e = _expiredLive();
        (uint80 latestId,,,,) = feed.latestRoundData();
        if (roundId >> 64 != latestId >> 64 || uint64(roundId) < 2) revert BadRoundHint();
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || updatedAt < e.expiry) revert BadRoundHint();
        (,,, uint256 prevUpdatedAt,) = feed.getRoundData(roundId - 1);
        if (prevUpdatedAt == 0 || prevUpdatedAt >= e.expiry) revert BadRoundHint();
        _settle(e, uint256(answer), roundId);
    }

    /// @notice Deterministic escape hatch for when no hint can exist. Usable only after
    ///         expiry + the fallback delay frozen at epoch open, and never when `settle` could work:
    ///         (a) the current feed phase began after expiry: settle at that phase's first round;
    ///         (b) the feed has not updated since expiry: settle at its last positive answer
    ///             (or at the strike, paying 0, if that answer is not positive);
    ///         (c) DEAD_FEED_DELAY after that, if still unsettled for any reason: settle at the
    ///             strike (payout 0). (a) can differ from an honest old-phase round if the feed
    ///             switched phase after expiry; it is still the only price available.
    ///         Each case yields exactly one possible price, so the caller cannot choose.
    function settleFallback() external nonReentrant {
        Epoch storage e = _expiredLive();
        uint256 readyAt = uint256(e.expiry) + fallbackDelayOf[currentEpoch];
        if (block.timestamp < readyAt) revert FallbackNotReady();
        if (block.timestamp >= readyAt + DEAD_FEED_DELAY) {
            _settle(e, e.strike, 0); // (c) whatever the feed does, nothing stays frozen forever
            return;
        }
        try feed.latestRoundData() returns (uint80 latestId, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt < e.expiry) {
                _settle(e, answer > 0 ? uint256(answer) : e.strike, latestId); // (b)
                return;
            }
            uint80 first = uint80((uint256(latestId >> 64) << 64) | 1);
            (, int256 fAnswer,, uint256 fUpdatedAt,) = feed.getRoundData(first);
            if (fUpdatedAt < e.expiry || fAnswer <= 0) revert UseHint(); // a hint exists in this phase
            _settle(e, uint256(fAnswer), first); // (a)
        } catch {
            revert FallbackNotReady(); // unreadable feed: wait for (c)
        }
    }

    function _expiredLive() internal view returns (Epoch storage e) {
        if (!epochLive) revert NoLiveEpoch();
        e = epochs[currentEpoch];
        if (block.timestamp < e.expiry) revert NotExpired();
    }

    function _settle(Epoch storage e, uint256 price, uint80 roundId) internal {
        uint256 payoutTotal;
        if (price > e.strike) {
            payoutTotal = uint256(e.sold).mulDiv(price - e.strike, price, Math.Rounding.Ceil);
        }
        e.settlePrice = SafeCast.toUint128(price);
        e.payoutTotal = SafeCast.toUint128(payoutTotal);
        e.settled = true;
        unclaimedPayouts += payoutTotal;
        epochLive = false; // premium now counts toward totalAssets
        lastSettledAt = block.timestamp;
        emit EpochSettled(currentEpoch, price, roundId, payoutTotal, e.premium);
    }

    /// @notice Stock owed to `buyer` for a settled epoch (0 if unsettled, OTM or claimed).
    function claimable(uint256 id, address buyer) public view returns (uint256) {
        Epoch storage e = epochs[id];
        if (!e.settled || claimed[id][buyer] || e.settlePrice <= e.strike) return 0;
        return notionalOf[id][buyer].mulDiv(e.settlePrice - e.strike, e.settlePrice, Math.Rounding.Floor);
    }

    function claim(uint256 id, address to) external nonReentrant returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[id][msg.sender] = true;
        // Per-buyer floor <= aggregate ceil, so this never underflows.
        unclaimedPayouts -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit Claimed(id, msg.sender, to, amount);
    }
}
