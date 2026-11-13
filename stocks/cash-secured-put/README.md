# Kerne Cash Secured Put Vault (Base, tokenized stocks)

The put side of the Kerne stock options desk. An ERC-4626 vault over USDC that writes fully
cash-secured puts on one Coinbase tokenized stock on Base (first market: TSLAc) and takes delivery
of the stock when a buyer exercises. Its sibling, the covered-call vault in
[`../covered-call`](../covered-call), is the call side. Built for Base's Stocks Maxxing Season
(Programmable Stock Markets track, Nov 5 to Dec 5, 2026), whose idea list names "Covered call and
put desks".

**Status on 2026-11-13: not audited and not deployed.** This folder is the source, the tests and the
review record. There is no address yet. When it is deployed it starts CLOSED (deposit cap 0), and the
address and deployment record will be added here in a later commit.

This contract is separate from the Kerne stablecoin contracts mirrored under `contracts/`. It is not
part of the Hexens audit published under `audits/`, and no outside firm has reviewed it.
Coinbase tokenized stocks are not available to US persons, and nothing here is offered to US persons.

## How it works

1. Depositors supply USDC and get vault shares.
2. Each epoch the keeper lists one put on the stock: a strike at least 3% below the Chainlink spot,
   a premium in basis points of the strike cash, a sale window and an expiry (1 to 35 days).
   Deposits, withdrawals and share transfers freeze for the epoch.
3. Buyers pay the premium in USDC. The vault reserves the full strike cash for every put it sells,
   so it can never sell more than its USDC covers.
4. From expiry until the end of the exercise window (1 day by default) a buyer may deliver the
   stock and receive the strike in USDC for each token delivered. A buyer does that when the stock
   is below the strike. Puts not exercised by the end of the window lapse.
5. Delivered stock is credited pro rata to the shareholders at that moment, who pull it with
   `claimStock`. They can hold it, sell it, or write calls on it in the covered-call vault.
6. `settle` closes the epoch on the clock. The premium becomes depositor yield. After every
   settlement there is an exit window (12h default) before the next epoch can open.

Settlement is physical and buyer-driven, so it uses no settlement price at all. The Chainlink feed
is only used to keep strikes out of the money at open and at every sale.

## Interface

Same keeper surface as the call vault: `openEpoch(strike, premiumBps, saleEnd, expiry)`,
`spotPrice()`, `epochLive`, `currentEpoch`, `minOtmBps`, `minPremiumBps`, `setParams` (8 values),
`setKeeper`, `setSalesPaused`. Put-specific:

| Who | Call |
|---|---|
| Buyer | `buyPut(epochId, notional, maxPremium)`, `transferPut(to, notional)`, `exercise(notional, to)` |
| Keeper | `closeSale()`, `raisePremium(premiumBps)` |
| Anyone | `settle()` |
| Shareholder | `claimStock(to)`, `claimEscrow(to)` |
| Owner | `windDown(holder)` (only once the share price has collapsed, see below) |
| Views | `epochs(id)` (struct), `quotePremium(notional)`, `strikeCash(...)`, `inSaleHours()`, `claimableStock(holder)`, `windingDown()` |

## Why each rule exists

| Rule | Closes |
|---|---|
| No settlement price: the buyer delivers stock, the vault pays the strike | a settler choosing a favourable oracle round; a dead or broken feed locking an epoch |
| No deposits, withdrawals or share transfers while an epoch is live | entering after a sale to skim premium; leaving ahead of an assignment; borrowed shares capturing delivered stock |
| Premium excluded from `totalAssets` until settlement | share price moving on unearned premium |
| Strike cash reserved (rounded up) <= USDC frozen at open; payouts rounded down | under-collateralised puts at any price |
| Sales only on weekdays 14:35 to 19:55 UTC | buying against a print from outside the US cash session, where the feed is sparse and the token keeps trading |
| Every sale re-checks strike <= spot x 0.97, on a price at most 4h old | buying a put that has moved into the money at the premium quoted at open |
| At most 10% of an epoch sold against one oracle round | taking the whole vault while the feed is silent (halt, early close, outage) |
| A purchase pays at least 1/100,000 of capacity in premium | holding an epoch open for free with a dust position |
| `buyPut` names its epoch | a late transaction landing on a later epoch's strike |
| Strike, dates, exercise window, OTM floor and exit window frozen per epoch at open | the owner changing the terms of a live epoch |
| The keeper can only end a sale early or raise the premium | a keeper worsening a live epoch for depositors or buyers |
| Exercise is never pausable and needs no keeper, owner or oracle; a put can be moved with `transferPut` | a buyer being denied what they paid for, or losing it by being blocked on the stock |
| The vault pays for and credits exactly the stock that arrived | a short delivery breaking exercise or the books |
| No epoch for a full exit window (12h minimum) after a settlement or any parameter or keeper change | a keeper chaining epochs to lock exits; the owner changing rules without notice |
| Delivered stock tracked per share (scale 1e60, remainder carried), checkpointed on every share movement | a later depositor diluting earlier deliveries; stock stranded as the share supply grows |
| Sales need at least 1e6 shares outstanding; deposits refused past 1e55 shares; owner `windDown` once the share price is 1e24 below par | overflow in the stock credit; one holder pinning the vault at its supply bound |
| Every outflow is a pull with a `to` address; every entry point is `nonReentrant` | one blocked address jamming everyone; re-entry through a token callback |
| 6 virtual decimals (OZ offset) | first-depositor inflation attack |

## Trust assumptions and limits

- The keeper prices the premium, bounded below only by a flat owner floor (10 bps minimum).
  Depositors see an epoch's terms when it opens, not before, and rely on the keeper and the owner.
- A buyer can exercise at any time in the exercise window and decides on the 24/7 token market, so
  the option's real last moment is `exerciseEnd`, not `expiry`. Depositors are locked until then.
- The feed prints on moves of about 0.5%, around the clock on weekdays and not on weekends. The
  contract does not know US market holidays or half-days; on those days, and in a trading halt,
  only the staleness bound, the out-of-the-money check and the 10% per-round cap protect the
  vault. The keeper should end the sale ahead of known events.
- Depositors are a standing bid for the token at the strike. If the token cannot be sold for the
  feed price elsewhere, buyers will deliver it here.
- `totalAssets` counts USDC only, so the share price steps down on every assignment (the stock sits
  beside it as a per-holder claim). Do not price shares with `convertToAssets` while an epoch is
  live, and do not use them as collateral. A contract that holds shares must be able to call
  `claimStock`.
- After many full assignments the share supply approaches its bound. The owner can then redeem
  holders into a pull escrow at the normal redeem price so the vault keeps taking deposits; the
  owner cannot send that cash anywhere but to the holder's own claim.
- If the issuer's policy stopped the vault from receiving the stock, buyers could not exercise. If
  USDC blacklisted the vault, nothing could move. Stray tokens sent to the vault cannot be
  recovered. None of this can be fixed in the contract.
- Before any cap is raised, one small epoch has to be run end to end on mainnet (deposit, open,
  buy, exercise, claimStock, redeem): the B20 precompile cannot be executed in the local test suite.

## Review

[`REVIEW.md`](REVIEW.md) records three in-house review rounds run on 2026-11-12 by reviewers that
did not write the contract, what each found and how each finding was closed. They were not done by
an outside firm and are not an audit. That record mentions a deploy script; the script is operator
tooling for a hardware wallet and is not published in this folder.

## Run the tests

From a clone of this repository:

```
git submodule update --init lib/forge-std
cd stocks/cash-secured-put
forge test                                   # 84 unit, fuzz (512 runs) and invariant tests
FORK_TESTS=1 forge test --match-contract ForkTslaFeed -vv
```

`forge-std` comes from this repository's root submodule. OpenZeppelin is vendored in `lib/` at
v5.5.0 (only the files the stock vaults import, MIT licensed). Compiler: solc 0.8.28, optimizer
200 runs, cancun.

The invariant suite drives random sequences of deposits, redemptions, share transfers, epochs,
sales, put transfers, exercises, settlements and stock claims, and checks after every call that:
the vault holds the unpaid strike cash of the live epoch on top of unearned premium and escrow;
it holds every unit of delivered stock not yet pulled, and holders are credited all of it bar
rounding dust; and USDC only ever leaves through exercise payouts and redemptions.

The fork test runs a full epoch against the real Coinbase TSLA Chainlink feed and the real USDC
contract on Base mainnet in three real moments: deploy and deposit about 13 hours before the sale;
open and sell just after a real feed print inside sale hours at least 25 hours before head; then
at head the buyer decides with the real price, one token is delivered to show assignment, and the
epoch settles on the clock. Without `FORK_TESTS=1` it does nothing and passes. B20 tokens are
precompiles, which a local fork cannot execute, so the stock there is a mock with the same 8
decimals and a policy blocklist.

## Addresses (Base mainnet)

- USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- TSLAc: `0xb2000000000000000000001e800a7f5189430cD0`
- Chainlink "Coinbase TSLA" (total return, 8 dp): `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4`
- Covered-call vault (sibling): `0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956`
- Cash-secured put vault: not deployed as of 2026-11-13

Opening deposits after a deploy is a separate owner call to `setParams(depositCap, ...)` and is a
deliberate decision, not part of the deploy.
