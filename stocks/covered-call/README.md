# Kerne Covered Call Vault (Base, tokenized stocks)

An ERC-4626 covered-call desk over one Coinbase tokenized stock on Base (first market: TSLAc).
Built for Base's Stocks Maxxing Season (Programmable Stock Markets track, Nov 5 to Dec 5, 2026).

**Status: not audited. Deployed on Base mainnet at
[`0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956`](https://basescan.org/address/0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956)
on 2026-11-12, deployed CLOSED (deposit cap 0, still 0 when read on 2026-11-13). Source verified on
[Sourcify](https://repo.sourcify.dev/8453/0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956).**

Its sibling, the cash-secured put vault in [`../cash-secured-put`](../cash-secured-put), is the put
side of the same desk (source and tests only, not deployed as of 2026-11-13).

This contract is separate from the Kerne stablecoin contracts mirrored under `contracts/`. It is not
part of the Hexens audit published under `audits/`, and no outside firm has reviewed it.
Coinbase tokenized stocks are not available to US persons, and nothing here is offered to US persons.

## How it works

1. Holders deposit the stock (TSLAc) and get vault shares.
2. Each epoch the keeper lists one call on the vault's own stock: a strike at least 3% above the
   Chainlink spot, a premium in basis points of notional, a sale window and an expiry (1 to 35 days).
   Deposits and withdrawals freeze for the epoch.
3. Buyers pay the premium in TSLAc and buy up to the vault's assets in notional.
4. At expiry anyone settles with the first Chainlink round at or after expiry. Buyers receive
   `notional * max(0, P - K) / P` in TSLAc, pulled with `claim`. The premium becomes depositor yield.
5. After every settlement there is a guaranteed exit window (12h default) before the next epoch.

Single asset throughout: the vault only ever holds the stock. The Chainlink feed for a Coinbase
tokenized stock is total-return per token (it already includes the B20 multiplier for dividends and
splits), so all accounting is in token units with no multiplier math.

## Why each rule exists

| Rule | Closes |
|---|---|
| No deposits or withdrawals while an epoch is live | entering after a sale to skim premium; exiting ahead of an in-the-money settlement |
| Premium excluded from `totalAssets` until settlement | share price moving on unearned premium |
| Notional sold <= assets frozen at open; payout <= notional | insolvency at any price |
| Settlement round proven by hint (`updatedAt >= expiry > previous.updatedAt`) | the settler choosing a favourable later price |
| Every sale re-checks strike >= fresh spot x 1.03 (price at most 4h old) | buying an option that has moved into the money at the premium quoted at open; weekend trades against a frozen close |
| Fallback settle only where no hint can exist (new phase after expiry, or feed silent since expiry), delay frozen per epoch, min 4 days | a late settler choosing between two prices |
| Unconditional settle at the strike 30 days after the fallback opens | funds frozen forever by a dead or broken feed |
| Exit window after each settlement | a keeper chaining epochs to lock exits |
| Pull-based claims and redeems | one policy-blocked address jamming everyone (B20 blocklists) |
| Strike, premium and duration floors set by the owner | a keeper giving the vault away |
| 6 virtual decimals (OZ offset) | first-depositor inflation attack |

## Trust assumptions

The keeper prices the premium (bounded below by owner floors); depositors who disagree exit in the
window. Share value ignores the in-the-money liability of a live epoch, so integrators must not price
shares with `convertToAssets` while `epochLive` is true. When read on 2026-11-13, owner and keeper
were the same hardware-wallet address (see below), so there is one operator and no multisig on this
contract. Read `owner()` and `keeper()` for the current values.

## Review

A second review pass on 2026-11-12, done in-house and not by an outside firm, found one high (buying
in the money at the opening premium), two mediums (settler price choice, dead-feed lock) and lows.
All are fixed and covered by regression tests; a re-review of the fixes found one more edge-case
lock, also fixed. This is not an audit.

## Run the tests

From a clone of this repository:

```
git submodule update --init lib/forge-std
cd stocks/covered-call
forge test                                   # 31 unit + fuzz (512 runs) tests
FORK_TESTS=1 forge test --match-contract ForkTslaFeed -vv
```

`forge-std` comes from this repository's root submodule. OpenZeppelin is vendored in `lib/` at
v5.5.0 (only the 21 files the vault imports, MIT licensed), which is the revision the deployed
contract was compiled against. Compiler: solc 0.8.28, optimizer 200 runs, cancun.

The fork test runs a full epoch against the real Coinbase TSLA Chainlink feed on Base mainnet: it
opens at a block about two days back, rolls the fork to head and settles on the real first round
after expiry. Without `FORK_TESTS=1` it does nothing and passes. B20 tokens are precompiles, which an
anvil fork cannot execute, so the stock there is a mock with the same 8 decimals and a policy
blocklist.

## Check it against the chain

```
cast call 0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956 "depositCap()(uint256)" --rpc-url https://mainnet.base.org
cast call 0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956 "owner()(address)"      --rpc-url https://mainnet.base.org
cast call 0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956 "keeper()(address)"     --rpc-url https://mainnet.base.org
cast call 0xc6180E9af7Cb4c6D47A230a6c5047fA615Bd0956 "asset()(address)"      --rpc-url https://mainnet.base.org
```

Read on 2026-11-13 at Base block 57036227: `depositCap` is 0 (closed), `owner` and `keeper` are both
`0x14f04cE02f35B29Af564A98544dD7e2393993946`, `asset` is TSLAc, `currentEpoch` is 0 (no epoch has
been opened) and `totalAssets` is 0.

Bytecode, checked on 2026-11-12: `forge build` in this folder produces runtime bytecode equal to the
code at the address above once the constructor immutables are masked, except for the trailing
metadata hash. That hash differs because the import paths in this folder differ from the tree the
contract was deployed from. Sourcify holds the exact sources and settings it was verified with.

## Addresses (Base mainnet, from docs.base.org and api.coinbase.com/v1/tokenized-stocks)

- TSLAc: `0xb2000000000000000000001e800a7f5189430cD0`
- Chainlink TSLA (total return, 8 dp): `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4`

## Deployment record

`DEPLOYED.json` holds the address, the creation transaction
([`0x2b121c84...66bc2`](https://basescan.org/tx/0x2b121c846b061866e51bb04e960dbbe328c884dee2789c82c0421d9110266bc2)),
the block (56625249) and the deployer nonce. Constructor arguments:

```
asset   0xb2000000000000000000001e800a7f5189430cD0   (TSLAc)
feed    0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4   (Chainlink TSLA)
name    "Kerne Covered Call TSLAc"
symbol  "kccTSLAc"
owner   0x14f04cE02f35B29Af564A98544dD7e2393993946
keeper  0x14f04cE02f35B29Af564A98544dD7e2393993946
```

`script/Deploy.s.sol` is a reference deploy script for a new vault. It is not the script that
deployed the address above: that deployment was sent from a hardware wallet with separate operator
tooling that is not published here, with owner and keeper set to the same address, which the
reference script refuses on purpose (`owner != keeper`). The constructor arguments above and
Sourcify are the record of what was deployed. The vault deploys closed. Opening deposits is
a separate owner call to `setParams(depositCap, ...)` and is a deliberate decision, not part of the
deploy. Deposits were closed when this was written (2026-11-13); `depositCap()` is the current answer.
