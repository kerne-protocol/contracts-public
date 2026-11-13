// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
}

/// @title KerneCashSecuredPutVault
/// @notice The put side of the Kerne stock options desk: an ERC-4626 vault over a cash token (USDC)
///         that writes fully cash-secured puts on ONE US-listed tokenized stock on Base (a Coinbase
///         B20 token, for example TSLAc). Depositors supply USDC. Each epoch the keeper lists an
///         out-of-the-money put inside owner-set bounds. Buyers pay the premium in USDC. From
///         `expiry` until `exerciseEnd` a buyer may deliver the stock and receive the strike in
///         USDC for every unit delivered:
///             cash out = notional delivered * strike
///         The delivered stock is credited pro rata to the vault's shareholders, who pull it with
///         `claimStock`. Puts not exercised by `exerciseEnd` lapse and the premium becomes
///         depositor yield.
///
/// @dev Design rules (each one closes a specific attack; the call vault's review findings and
///      this vault's own review are carried in):
///      - Settlement is physical and buyer-driven, so it needs NO settlement price. Nobody can pick
///        a favourable oracle round, and a dead or broken feed can never lock an epoch: `settle`
///        depends on the clock only.
///      - While an epoch is live there are no deposits, no withdrawals and no share transfers, so
///        nobody can enter after a sale to skim premium or leave ahead of an assignment, and the
///        share supply is constant for the whole epoch.
///      - Premium is excluded from totalAssets until the epoch settles and only then becomes yield.
///      - Strike cash reserved for puts sold can never exceed the depositor USDC frozen at epoch
///        open, and while an epoch is live that cash only leaves through exercise (cash parked in
///        escrow by `windDown` is outside capacity from the start), so every put is fully
///        cash-secured for every price path. Reservations round up, payouts round down.
///      - Sales are fenced four ways, because the chain cannot see the stock's price between
///        feed prints. The feed prints on moves of about 0.5%, around the clock on weekdays and
///        not at all on weekends; outside the US cash session prints are sparse (gaps of 3 to 10
///        hours were observed in Nov 2026), and a quiet tape looks the same on chain as a halted
///        one. So: (1) sales only on weekdays between SALE_OPEN_UTC and SALE_CLOSE_UTC, a window
///        inside the US cash session in both daylight-saving regimes, where the reference market
///        is deepest and prints are densest on regular trading days (US market holidays and
///        half-days are not known to the contract; on those days only rules 2 to 4 apply and the
///        keeper should end the sale beforehand); (2) the feed price must be at most BUY_MAX_STALENESS
///        old; (3) the strike must still be the epoch's OTM floor below that price at the moment
///        of sale; (4) at most MAX_SALE_PER_ROUND_BPS of the epoch's capacity can be sold against
///        any one oracle round, which bounds the loss whenever the feed is silent while the real
///        price moves (a trading halt, an early close, a sequencer or oracle outage).
///      - Exercise is never pausable and needs no keeper, owner or oracle. Strike, sale end,
///        expiry, exercise window, OTM floor and the exit window that follows are frozen per epoch
///        at open. The keeper can only make a live epoch safer for depositors: end the sale early
///        or raise the premium. A put can be moved to another address with `transferPut`.
///      - After every settlement, and after every change of parameters or keeper, no epoch can
///        open for a full idleWindow (at least 12 hours; for a parameter change, the longer of
///        the old and the new window), so the keeper cannot chain epochs to lock exits and the
///        owner cannot change the rules without notice.
///      - Every transfer out is a pull by the receiving party (exercise, claimStock, claimEscrow,
///        redeem), each with a destination address; one blocked address can never jam others.
///      - Delivered stock is tracked by a per-share accumulator checkpointed on every share
///        movement, so stock from an assignment belongs to the holders at that moment and a later
///        depositor gets none of it. totalAssets counts USDC only, so the share price steps down
///        by design on every assignment and later deposits mint more shares per USDC. The
///        accumulator scale (1e60), a carried remainder and the share supply bounds (MAX_SUPPLY,
///        minSupply) mean delivered stock is credited in full however far the supply has grown,
///        bar under one stock unit of rounding per holder checkpoint. Deposits that would take
///        the supply past MAX_SUPPLY are refused. Long before that, once the share price has
///        fallen by a factor of 1e24 from par (`windingDown`), the vault takes no deposits and
///        shares stop moving between holders, and the owner may redeem holders into a pull
///        escrow (`windDown`) at the same price a redeem would give them. So no holder can keep
///        the vault shut by staying in or by moving shares around, and once the large holders
///        are out the vault takes deposits again.
///
///      Trust assumptions and limits (not closed by code):
///      - The keeper prices the premium, bounded below only by a flat owner floor; depositors see
///        an epoch's terms when it opens, not before. Depositors trust the keeper and the owner.
///      - The buyer may exercise at any time from `expiry` to `exerciseEnd` and decides on the
///        24/7 token market, so the option's real last moment is `exerciseEnd`.
///      - A halt, an early close or an outage inside sale hours can still be sold against, up to
///        the per-round cap. The keeper should end the sale (`closeSale`) ahead of known events.
///      - Depositors are a standing bid for the token at the strike: if the token cannot be sold
///        for the feed price elsewhere, buyers will deliver it here.
///      - Integrators must not price shares with convertToAssets while an epoch is live, and a
///        contract that holds shares must be able to call `claimStock` and `claimEscrow`.
///      - The stock token is assumed to make no callback on transfer (true of B20 precompiles).
///        Every entry point that moves tokens, puts or stock credits is nonReentrant regardless.
///      - Stock that reaches the vault other than through `exercise` is not credited to anyone.
///      - If the stock issuer's policy stops the vault from receiving the stock, or USDC
///        blacklists the vault, exercise cannot work. Nothing in the contract can fix that.
///
///      NOT AUDITED. Built for the Base "Stocks Maxxing" builder competition. Coinbase tokenized
///      stocks are not available to US persons; this contract offers nothing to US persons.
contract KerneCashSecuredPutVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant BPS = 10_000;
    /// @dev Sales need a feed price at most this old.
    uint256 public constant BUY_MAX_STALENESS = 4 hours;
    /// @dev Sale hours, seconds after 00:00 UTC, Monday to Friday. The US cash session is
    ///      13:30-20:00 UTC in summer and 14:30-21:00 UTC in winter; this is inside both.
    uint256 public constant SALE_OPEN_UTC = 14 hours + 35 minutes;
    uint256 public constant SALE_CLOSE_UTC = 19 hours + 55 minutes;
    /// @dev Share of an epoch's capacity that can be sold against one oracle round.
    uint256 public constant MAX_SALE_PER_ROUND_BPS = 1_000;
    /// @dev A purchase must pay at least capacity / MIN_PREMIUM_DIVISOR in premium, so holding an
    ///      epoch open with a dust position is not free.
    uint256 public constant MIN_PREMIUM_DIVISOR = 100_000;
    /// @dev No deposit may take the share supply above this.
    uint256 public constant MAX_SUPPLY = 1e55;
    /// @dev Shares per unit of USDC above which the owner may wind holders down. Par is 1e6, so
    ///      this is a share price 1e24 times below par: several full assignments in a row.
    uint256 public constant WIND_DOWN_SHARES_PER_ASSET = 1e30;
    uint256 internal constant ACC = 1e60;

    struct Epoch {
        uint128 strike; // feed decimals, USD per whole stock token
        uint64 saleEnd; // buyers can buy while block.timestamp < saleEnd
        uint64 expiry; // exercise opens
        uint64 exerciseEnd; // exercise closes; `settle` is open from here
        uint32 premiumBps; // premium = strike cash * premiumBps / BPS, paid in USDC
        uint32 minOtmBps; // OTM floor frozen at open, used for every sale in this epoch
        uint32 idleWindow; // exit window after this epoch settles, frozen at open
        uint128 capacity; // depositor USDC frozen at open (0 if the share supply is below minSupply)
        uint128 soldCash; // strike cash reserved for puts sold, rounded up per sale
        uint128 sold; // notional sold, stock units
        uint128 exercised; // notional delivered, stock units
        uint128 premium; // USDC premium collected
        uint128 paid; // USDC paid out on exercise
        bool settled;
    }

    IERC20 public immutable stock;
    IAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;
    /// @notice Share supply below which an epoch sells nothing. It equals the shares one unit
    ///         of USDC mints at par, so a donation to the empty vault cannot hold a funded vault
    ///         under it: deposits larger than the donation always clear it.
    uint256 public immutable minSupply;
    /// @dev strike cash (asset units) = notional * strike * cashNum / cashDen
    uint256 internal immutable cashNum;
    uint256 internal immutable cashDen;

    address public keeper;
    uint256 public depositCap; // max totalAssets after a deposit
    uint256 public maxStaleness; // seconds, for the spot read at epoch open
    uint256 public minOtmBps; // strike <= spot * (1 - minOtmBps)
    uint256 public minPremiumBps;
    uint256 public minDuration;
    uint256 public maxDuration;
    uint256 public exerciseWindow; // seconds after expiry in which buyers may deliver
    uint256 public idleWindow; // exit window between epochs and notice period for changes
    uint256 public lastSettledAt;
    uint256 public nextOpenAt; // no epoch can open before this
    bool public salesPaused;

    uint256 public currentEpoch; // 0 = none opened yet
    bool public epochLive;
    uint80 public saleRound; // oracle round the per-round counter refers to
    uint256 public soldInRound; // strike cash sold against `saleRound` in the live epoch

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => mapping(address => uint256)) public notionalOf; // unexercised notional

    // delivered stock, credited per share
    uint256 public accStockPerShare; // scaled by ACC
    uint256 public unclaimedStock; // stock credited to shareholders and not yet pulled
    uint256 internal stockCarry; // remainder of the last credit, scaled by ACC, carried forward

    // USDC parked for holders redeemed by `windDown`; not part of totalAssets
    uint256 public cashEscrow;
    mapping(address => uint256) public escrowOf;
    mapping(address => uint256) public accPaid;
    mapping(address => uint256) public pendingStock;

    event KeeperSet(address keeper);
    event ParamsSet(uint256 depositCap, uint256 maxStaleness, uint256 minOtmBps, uint256 minPremiumBps, uint256 minDuration, uint256 maxDuration, uint256 exerciseWindow, uint256 idleWindow);
    event SalesPaused(bool paused);
    event EpochOpened(uint256 indexed epoch, uint256 strike, uint256 spot, uint256 premiumBps, uint256 saleEnd, uint256 expiry, uint256 exerciseEnd, uint256 capacity);
    event SaleClosed_(uint256 indexed epoch, uint256 saleEnd);
    event PremiumRaised(uint256 indexed epoch, uint256 premiumBps);
    event PutBought(uint256 indexed epoch, address indexed buyer, uint256 notional, uint256 strikeCash, uint256 premium);
    event PutTransferred(uint256 indexed epoch, address indexed from, address indexed to, uint256 notional);
    event Exercised(uint256 indexed epoch, address indexed buyer, address to, uint256 notional, uint256 cashOut);
    event EpochSettled(uint256 indexed epoch, uint256 sold, uint256 exercised, uint256 paid, uint256 premium);
    event StockClaimed(address indexed holder, address to, uint256 amount);
    event WoundDown(address indexed holder, uint256 shares, uint256 assets);
    event EscrowClaimed(address indexed holder, address to, uint256 assets);

    error NotKeeper();
    error EpochIsLive();
    error NoLiveEpoch();
    error BadParams();
    error StalePrice();
    error StrikeTooHigh();
    error PremiumTooLow();
    error BadDuration();
    error SaleClosed();
    error OutsideSaleHours();
    error RoundCapReached();
    error OverCapacity();
    error NotExpired();
    error ExerciseClosed();
    error ExerciseOpen();
    error NothingToExercise();
    error NothingToClaim();
    error Paused();
    error ExitWindowOpen();
    error SameToken();
    error SupplyCap();
    error BadRecipient();
    error WrongEpoch();
    error NotWindingDown();
    error WindingDown();
    error Disabled();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        IERC20 cash,
        IERC20 stock_,
        IAggregatorV3 feed_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address keeper_
    ) ERC20(name_, symbol_) ERC4626(cash) Ownable(owner_) {
        if (address(cash) == address(stock_)) revert SameToken();
        stock = stock_;
        feed = feed_;
        feedDecimals = feed_.decimals();
        cashNum = 10 ** uint256(IERC20Metadata(address(cash)).decimals());
        cashDen = 10 ** (uint256(IERC20Metadata(address(stock_)).decimals()) + feedDecimals);
        minSupply = 10 ** uint256(_decimalsOffset());
        keeper = keeper_;
        // Conservative launch defaults; the owner can move them inside the hard bounds of setParams.
        depositCap = 0; // closed until the owner opens it
        maxStaleness = 25 hours; // feed heartbeat is 24h in market hours
        minOtmBps = 300; // strike at least 3% below spot
        minPremiumBps = 10; // 0.10% of strike cash per epoch at minimum
        minDuration = 1 days;
        maxDuration = 35 days;
        exerciseWindow = 1 days;
        idleWindow = 12 hours;
        emit KeeperSet(keeper_);
    }

    // ------------------------------------------------------------------ admin

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        _notice(idleWindow);
        emit KeeperSet(keeper_);
    }

    /// @dev Changes apply to epochs opened afterwards, and no epoch can open for a full idleWindow
    ///      after a change. A live epoch keeps every term it was opened with.
    function setParams(
        uint256 depositCap_,
        uint256 maxStaleness_,
        uint256 minOtmBps_,
        uint256 minPremiumBps_,
        uint256 minDuration_,
        uint256 maxDuration_,
        uint256 exerciseWindow_,
        uint256 idleWindow_
    ) external onlyOwner {
        if (
            depositCap_ > type(uint88).max || maxStaleness_ == 0 || maxStaleness_ > 3 days || minOtmBps_ < 100
                || minOtmBps_ > 5_000 || minPremiumBps_ < 10 || minPremiumBps_ >= BPS || minDuration_ < 1 hours
                || minDuration_ > maxDuration_
                || maxDuration_ > 45 days || exerciseWindow_ < 6 hours || exerciseWindow_ > 3 days
                || idleWindow_ < 12 hours || idleWindow_ > 7 days
        ) revert BadParams();
        _notice(Math.max(idleWindow, idleWindow_)); // the longer of the old and the new window
        depositCap = depositCap_;
        maxStaleness = maxStaleness_;
        minOtmBps = minOtmBps_;
        minPremiumBps = minPremiumBps_;
        minDuration = minDuration_;
        maxDuration = maxDuration_;
        exerciseWindow = exerciseWindow_;
        idleWindow = idleWindow_;
        emit ParamsSet(depositCap_, maxStaleness_, minOtmBps_, minPremiumBps_, minDuration_, maxDuration_, exerciseWindow_, idleWindow_);
    }

    /// @dev The vault needs an owner (parameters, pause, wind-down), so ownership can be handed
    ///      over in two steps but not thrown away.
    function renounceOwnership() public view override onlyOwner {
        revert Disabled();
    }

    /// @notice Stops new sales and new epochs. Never stops exercise, settlement, claims or exits.
    function setSalesPaused(bool paused) external onlyOwner {
        salesPaused = paused;
        emit SalesPaused(paused);
    }

    /// @dev Pushes the earliest next open out to now + window; never pulls it in.
    function _notice(uint256 window) internal {
        uint256 t = block.timestamp + window;
        if (t > nextOpenAt) nextOpenAt = t;
    }

    // ------------------------------------------------------------------ accounting

    /// @notice USDC that belongs to depositors: balance minus premium not yet earned and minus
    ///         cash parked in escrow by `windDown`. Delivered stock is not counted here; it is
    ///         credited per share and pulled with `claimStock`.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = cashEscrow;
        if (epochLive) reserved += _epochs[currentEpoch].premium;
        return bal > reserved ? bal - reserved : 0;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (epochLive || windingDown()) return 0;
        uint256 supply = totalSupply();
        if (supply >= MAX_SUPPLY) return 0;
        uint256 ta = totalAssets();
        uint256 room = depositCap > ta ? depositCap - ta : 0;
        return Math.min(room, _convertToAssets(MAX_SUPPLY - supply, Math.Rounding.Floor));
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
        if (totalSupply() > MAX_SUPPLY) revert SupplyCap();
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Shares do not move while an epoch is live, and do not move between holders while
    ///      the vault is winding down (a holder could otherwise dodge `windDown` by hopping
    ///      addresses). Otherwise delivered stock is checkpointed for both sides before any
    ///      balance changes, so stock already delivered stays with the holder it was credited to.
    function _update(address from, address to, uint256 value) internal override {
        if (epochLive) revert EpochIsLive();
        if (from != address(0) && to != address(0) && windingDown()) revert WindingDown();
        _accrue(from);
        _accrue(to);
        super._update(from, to, value);
    }

    function _accrue(address holder) internal {
        if (holder == address(0)) return;
        uint256 acc = accStockPerShare;
        uint256 paid = accPaid[holder];
        if (acc != paid) {
            pendingStock[holder] += balanceOf(holder).mulDiv(acc - paid, ACC);
            accPaid[holder] = acc;
        }
    }

    /// @notice Delivered stock `holder` can pull right now.
    function claimableStock(address holder) public view returns (uint256) {
        return pendingStock[holder] + balanceOf(holder).mulDiv(accStockPerShare - accPaid[holder], ACC);
    }

    /// @notice Pull the caller's share of delivered stock. Works at any time, epoch live or not.
    function claimStock(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert BadRecipient();
        _accrue(msg.sender);
        amount = pendingStock[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingStock[msg.sender] = 0;
        // Per-holder floors sum to at most what was credited, so this never underflows.
        unclaimedStock -= amount;
        stock.safeTransfer(to, amount);
        emit StockClaimed(msg.sender, to, amount);
    }

    // ------------------------------------------------------------------ wind-down

    /// @notice True once repeated assignments have cut the share price by a factor of 1e24 from
    ///         par: about 8 full assignments at a 0.1% premium, 12 at 1%. It is always true by
    ///         the time the supply nears MAX_SUPPLY. While true the vault takes no deposits and
    ///         shares do not move between holders. Pro rata exits leave the ratio where it is,
    ///         so it turns false only when the holders of nearly all the supply are out.
    function windingDown() public view returns (bool) {
        return totalSupply() > (totalAssets() + 1) * WIND_DOWN_SHARES_PER_ASSET;
    }

    /// @notice Between epochs, while `windingDown`, the owner may redeem any holder: the shares
    ///         are burned at the price a redeem would give, the USDC is parked for the holder to
    ///         pull with `claimEscrow`, and their delivered stock stays claimable. This is how a
    ///         vault whose share supply has grown too far is brought back under the bound
    ///         without needing every holder to act. The owner cannot direct the cash anywhere
    ///         else.
    function windDown(address holder) external onlyOwner nonReentrant returns (uint256 assets) {
        if (epochLive) revert EpochIsLive();
        if (!windingDown()) revert NotWindingDown();
        uint256 shares = balanceOf(holder);
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        _burn(holder, shares); // checkpoints the holder's delivered stock first
        escrowOf[holder] += assets;
        cashEscrow += assets;
        emit WoundDown(holder, shares, assets);
    }

    /// @notice Pull USDC parked for the caller by `windDown`. Works at any time.
    function claimEscrow(address to) external nonReentrant returns (uint256 assets) {
        if (to == address(0) || to == address(this)) revert BadRecipient();
        assets = escrowOf[msg.sender];
        if (assets == 0) revert NothingToClaim();
        escrowOf[msg.sender] = 0;
        cashEscrow -= assets;
        IERC20(asset()).safeTransfer(to, assets);
        emit EscrowClaimed(msg.sender, to, assets);
    }

    // ------------------------------------------------------------------ epochs

    /// @notice Full record of epoch `id` (ABI-identical to a public mapping getter).
    function epochs(uint256 id) external view returns (Epoch memory) {
        return _epochs[id];
    }

    /// @notice Spot price from the feed, reverting if non-positive or older than maxStaleness.
    function spotPrice() public view returns (uint256 price) {
        (, price) = _freshRound(maxStaleness);
    }

    function _freshRound(uint256 staleness) internal view returns (uint80 roundId, uint256 price) {
        int256 answer;
        uint256 updatedAt;
        (roundId, answer,, updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > staleness) {
            revert StalePrice();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer); // answer > 0 was checked above
    }

    /// @notice True while the clock is inside sale hours (weekdays, SALE_OPEN_UTC to SALE_CLOSE_UTC).
    function inSaleHours() public view returns (bool) {
        uint256 day = (block.timestamp / 1 days + 4) % 7; // 0 = Sunday ... 6 = Saturday
        uint256 tod = block.timestamp % 1 days;
        return day != 0 && day != 6 && tod >= SALE_OPEN_UTC && tod < SALE_CLOSE_UTC;
    }

    /// @notice USDC the vault pays for `notional` stock units delivered at `strike`.
    function strikeCash(uint256 notional, uint256 strike, Math.Rounding rounding) public view returns (uint256) {
        return notional.mulDiv(strike * cashNum, cashDen, rounding);
    }

    /// @notice Keeper lists this epoch's put. Freezes deposits, withdrawals and share transfers
    ///         until settlement.
    function openEpoch(uint256 strike, uint256 premiumBps, uint256 saleEnd, uint256 expiry)
        external
        onlyKeeper
        returns (uint256 id)
    {
        if (epochLive) revert EpochIsLive();
        if (salesPaused) revert Paused();
        if (block.timestamp < nextOpenAt) revert ExitWindowOpen();
        uint256 spot = spotPrice();
        if (strike == 0 || strike > spot.mulDiv(BPS - minOtmBps, BPS, Math.Rounding.Floor)) revert StrikeTooHigh();
        if (premiumBps < minPremiumBps || premiumBps >= BPS) revert PremiumTooLow();
        if (saleEnd <= block.timestamp || saleEnd > expiry) revert BadDuration();
        uint256 dur = expiry - block.timestamp;
        if (dur < minDuration || dur > maxDuration) revert BadDuration();

        // With (next to) no shares outstanding there is nobody to credit delivered stock to,
        // and the per-share credit could overflow: sell nothing.
        uint256 capacity = totalSupply() < minSupply ? 0 : totalAssets();
        uint256 exerciseEnd = expiry + exerciseWindow;
        id = ++currentEpoch;
        Epoch storage e = _epochs[id];
        e.strike = SafeCast.toUint128(strike);
        e.saleEnd = SafeCast.toUint64(saleEnd);
        e.expiry = SafeCast.toUint64(expiry);
        e.exerciseEnd = SafeCast.toUint64(exerciseEnd);
        e.premiumBps = SafeCast.toUint32(premiumBps);
        e.minOtmBps = SafeCast.toUint32(minOtmBps);
        e.idleWindow = SafeCast.toUint32(idleWindow);
        e.capacity = SafeCast.toUint128(capacity);
        soldInRound = 0;
        saleRound = 0;
        epochLive = true;
        emit EpochOpened(id, strike, spot, premiumBps, saleEnd, expiry, exerciseEnd, capacity);
    }

    /// @notice Keeper ends the live epoch's sale now. It can only shorten the sale.
    function closeSale() external onlyKeeper {
        if (!epochLive) revert NoLiveEpoch();
        Epoch storage e = _epochs[currentEpoch];
        if (block.timestamp >= e.saleEnd) revert SaleClosed();
        e.saleEnd = SafeCast.toUint64(block.timestamp);
        emit SaleClosed_(currentEpoch, block.timestamp);
    }

    /// @notice Keeper raises the live epoch's premium for later sales. It can never lower it;
    ///         buyers are protected by `maxPremium`.
    function raisePremium(uint256 premiumBps) external onlyKeeper {
        if (!epochLive) revert NoLiveEpoch();
        Epoch storage e = _epochs[currentEpoch];
        if (premiumBps <= e.premiumBps || premiumBps >= BPS) revert PremiumTooLow();
        e.premiumBps = SafeCast.toUint32(premiumBps);
        emit PremiumRaised(currentEpoch, premiumBps);
    }

    /// @notice Strike cash reserved and premium (both USDC, rounded up) for `notional` stock units
    ///         in the live epoch.
    function quotePremium(uint256 notional) public view returns (uint256 cash, uint256 premium) {
        Epoch storage e = _epochs[currentEpoch];
        cash = strikeCash(notional, e.strike, Math.Rounding.Ceil);
        premium = cash.mulDiv(e.premiumBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Buy the live epoch's put on `notional` stock units. Premium is pulled in USDC.
    /// @param epochId the epoch the buyer means to buy; a transaction that lands in a later
    ///        epoch (a different strike) reverts.
    function buyPut(uint256 epochId, uint256 notional, uint256 maxPremium)
        external
        nonReentrant
        returns (uint256 premium)
    {
        if (!epochLive) revert NoLiveEpoch();
        if (salesPaused) revert Paused();
        uint256 id = currentEpoch;
        if (epochId != id) revert WrongEpoch();
        Epoch storage e = _epochs[id];
        if (block.timestamp >= e.saleEnd) revert SaleClosed();
        if (!inSaleHours()) revert OutsideSaleHours();
        // The put must still be out of the money by the epoch's floor at the moment of sale, so
        // nobody can buy intrinsic value at a premium quoted for an OTM option.
        (uint80 roundId, uint256 spot) = _freshRound(BUY_MAX_STALENESS);
        if (e.strike > spot.mulDiv(BPS - e.minOtmBps, BPS, Math.Rounding.Floor)) revert StrikeTooHigh();

        uint256 cash;
        (cash, premium) = quotePremium(notional);
        if (notional == 0 || uint256(e.soldCash) + cash > e.capacity) revert OverCapacity();
        if (premium > maxPremium || premium * MIN_PREMIUM_DIVISOR < e.capacity) revert PremiumTooLow();
        // Only a slice of the epoch can be sold against one oracle round: if the feed is frozen
        // (a halt, an early close) the vault's exposure to the unseen move is bounded.
        uint256 inRound = roundId == saleRound ? soldInRound + cash : cash;
        if (inRound > uint256(e.capacity) * MAX_SALE_PER_ROUND_BPS / BPS) revert RoundCapReached();
        saleRound = roundId;
        soldInRound = inRound;

        e.soldCash = SafeCast.toUint128(uint256(e.soldCash) + cash);
        e.sold = SafeCast.toUint128(uint256(e.sold) + notional);
        e.premium = SafeCast.toUint128(uint256(e.premium) + premium);
        notionalOf[id][msg.sender] += notional;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), premium);
        emit PutBought(id, msg.sender, notional, cash, premium);
    }

    /// @notice Move `notional` of the caller's unexercised put in the live epoch to `to`. The
    ///         vault's total obligation does not change.
    function transferPut(address to, uint256 notional) external nonReentrant {
        if (!epochLive) revert NoLiveEpoch();
        if (to == address(0) || to == address(this)) revert BadRecipient();
        uint256 id = currentEpoch;
        uint256 held = notionalOf[id][msg.sender];
        if (notional == 0 || notional > held) revert NothingToExercise();
        notionalOf[id][msg.sender] = held - notional;
        notionalOf[id][to] += notional;
        emit PutTransferred(id, msg.sender, to, notional);
    }

    /// @notice Deliver up to `notional` stock units against the live epoch's put and receive the
    ///         strike in USDC for what arrives. Open from expiry until exerciseEnd. Never pausable,
    ///         no oracle involved.
    /// @param to receiver of the USDC.
    function exercise(uint256 notional, address to) external nonReentrant returns (uint256 cashOut) {
        if (!epochLive) revert NoLiveEpoch();
        uint256 id = currentEpoch;
        Epoch storage e = _epochs[id];
        if (block.timestamp < e.expiry) revert NotExpired();
        if (block.timestamp >= e.exerciseEnd) revert ExerciseClosed();
        uint256 held = notionalOf[id][msg.sender];
        if (notional == 0 || notional > held) revert NothingToExercise();

        // Pay and credit exactly what arrived, never more than was asked for.
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), notional);
        uint256 received = Math.min(stock.balanceOf(address(this)) - before, notional);
        cashOut = strikeCash(received, e.strike, Math.Rounding.Floor);
        if (cashOut == 0) revert NothingToExercise();

        notionalOf[id][msg.sender] -= received; // read again after the transfer, never a cached value
        e.exercised = SafeCast.toUint128(uint256(e.exercised) + received);
        e.paid = SafeCast.toUint128(uint256(e.paid) + cashOut);
        // Pro rata to the shares outstanding. Supply is constant for the whole epoch and at least
        // minSupply (capacity is 0 otherwise, so nothing could have been sold). The remainder of
        // the division is carried into the next credit, so nothing is lost to the division.
        uint256 supply = totalSupply();
        uint256 carry = stockCarry + mulmod(received, ACC, supply);
        accStockPerShare += received.mulDiv(ACC, supply) + carry / supply;
        stockCarry = carry % supply;
        unclaimedStock += received;

        IERC20(asset()).safeTransfer(to, cashOut);
        emit Exercised(id, msg.sender, to, received, cashOut);
    }

    /// @notice Close the live epoch. Open to anyone once the exercise window has ended, or earlier
    ///         if the sale is over and no unexercised put remains. Unexercised puts lapse and the
    ///         premium becomes depositor yield. Depends on the clock only.
    function settle() external nonReentrant {
        if (!epochLive) revert NoLiveEpoch();
        uint256 id = currentEpoch;
        Epoch storage e = _epochs[id];
        bool nothingOutstanding = block.timestamp >= e.saleEnd && e.sold == e.exercised;
        if (block.timestamp < e.exerciseEnd && !nothingOutstanding) revert ExerciseOpen();
        e.settled = true;
        epochLive = false; // premium now counts toward totalAssets
        lastSettledAt = block.timestamp;
        _notice(e.idleWindow);
        emit EpochSettled(id, e.sold, e.exercised, e.paid, e.premium);
    }
}
