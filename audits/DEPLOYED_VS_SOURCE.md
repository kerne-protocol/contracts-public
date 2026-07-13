# Deployed vs source: state disclosure

For reviewers and audit firms. Last updated 2026-07-11. Canonical web version: [kerne.fi/security/deployed-vs-source](https://kerne.fi/security/deployed-vs-source).

On any young protocol the repository moves faster than the chain. This document is the canonical table of every place where Kerne's deployed bytecode behaves differently from the current source, published before any external audit begins, so a reviewer reading the code finds context here rather than surprises there.

The reading rule: when an internal security document marks a finding FIXED, that means fixed in source. Whether the fix is live on chain is a separate fact, and this document is where that fact lives.

## The four buckets

1. **Fixed and deployed.** Live bytecode. Per-finding closing commits at [kerne.fi/security/findings-tracker](https://kerne.fi/security/findings-tracker).
2. **Fixed and deployed in the 2026-06-16 ceremony.** KerneVault v2 (`0x8ccc56B5...292B`) and KUSDPSM v3 (`0x07eBb486...5993`) were deployed and now hold kUSD `MINTER_ROLE`: they are the live mint path (confirm on chain, and see the verification table in the [root README](../README.md)). The vault and PSM findings that ceremony targeted are fixed on chain as of that deployment, and the price-oracle router the vault reads (`priceOracle`) is deployed and wired. Any residual per-finding on-chain status is tracked in the findings tracker and the `gaps` array of [kerne.fi/api/risk-status](https://kerne.fi/api/risk-status).
3. **Open on chain, with a mitigation and an operating rule.** The two standing divergences below.
4. **Source only, never deployed.** The repository contains contracts that have never been deployed (including `kUSDMinter` and the cross-chain bridge stack, the latter under an explicit do-not-deploy quarantine). Findings against them affect no live funds. [`SCOPE.md`](SCOPE.md) draws this boundary precisely.

## The two standing divergences

Both contracts are source-verified on Sourcify and BaseScan, so every behavior described here is checkable against the deployed code itself.

| Contract | Address | Deployed bytecode | Current source | Practical exposure | Operating rule |
|---|---|---|---|---|---|
| kUSD | `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3` (deployed 2026-04-08) | Standard OpenZeppelin `ERC20Burnable`: `burnFrom` is callable by any address holding an allowance. No role gate on burning. | Burning gated behind `BURNER_ROLE`. | An attacker must first obtain an allowance from the holder (a malicious or compromised approval target); with one, they can destroy the holder's kUSD rather than transfer it. No path to burn without an allowance, so the surface equals standard ERC-20 approval hygiene. | Permanent disclosure item. No kUSD redeploy planned: a token migration would cost holders more than the role gate is worth at current scale. |
| KerneYieldDistributor | `0x096e38a04B632D28E017f86836225E0956CaD878` | `ROOT_UPDATER_ROLE` sets a new Merkle root with immediate effect; the role is held by the operational hot wallet `0x09a2780ac8Be6D5d2d1F85A8D92b09D40C9CA37e`. | Root updates go through `proposeMerkleRoot` / `executeMerkleRoot` with a 24-hour `ROOT_UPDATE_TIMELOCK`. | If the contract held funds and the hot key were compromised, an arbitrary root could claim them. Exposure is zero in practice because the contract is deliberately unfunded. | Never fund the deployed distributor. Redeploy from current source (with the timelock) before any real yield routes through it. The unfunded state is verifiable on chain at any time. |

## Closed on chain since the last revision

**skUSD immediate-distribution (self-found High, 2026-05-28).** The prior staking vault credited each yield distribution to the share price atomically, so a depositor could bracket a distribution within a single block (deposit, distribute, redeem) and capture a share of it. The 2026-07-03 redeploy to the live skUSD `0x96F5102C15b839757f811A98CEc3725Ac21DfA14` deployed the streaming source: distributed yield now vests linearly over `yieldVestingPeriod` (86400 seconds / 24 hours on chain, floored at `MIN_VESTING_PERIOD` = 1 hour) and the still-unvested portion is excluded from `totalAssets()` via `lockedYield()`, so a single-block flash deposit captures none of it. This is checkable directly against the deployed bytecode (Sourcify runtime match; source mirrored at [`../contracts/skUSD/src/skUSD.sol`](../contracts/skUSD/src/skUSD.sol)) and by reading `yieldVestingPeriod()` on chain. skUSD remains in the Hexens core-4 audit scope (fieldwork underway since 2026-07-13).

## Why we publish this

A reviewer who finds a source-versus-chain gap on their own has every reason to read it as concealment. The same facts, stated by the team first with addresses and operating rules, are evidence the team knows its own system. If a future deployment changes any row above, this document and the web version change in the same commit as the deployment record.

Related: [`SCOPE.md`](SCOPE.md) (audit scoping), [`../HOW_TO_VERIFY_KERNE.md`](../HOW_TO_VERIFY_KERNE.md) (independent verification), [kerne.fi/dataroom](https://kerne.fi/dataroom) (one-URL diligence surface).
