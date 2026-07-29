# Deployed vs source: state disclosure

For reviewers and audit firms. Last updated 2026-07-28. Mirrors the canonical web version, last updated 2026-07-25: [kerne.fi/security/deployed-vs-source](https://kerne.fi/security/deployed-vs-source).

On any young protocol the repository moves faster than the chain. This document is the canonical table of every place where Kerne's deployed bytecode behaves differently from the current source. It was first published before any external review began, and it is where the gap between the audited commit and the deployed contracts is stated, so a reviewer reading the code finds context here rather than surprises there.

The reading rule: when an internal security document marks a finding FIXED, that means fixed in source. Whether the fix is live on chain is a separate fact, and this document is where that fact lives.

> **Correction, 2026-07-28.** The revision of this file dated 2026-07-20 listed **two** standing divergences and said the vault findings targeted by the 2026-06-16 ceremony "are fixed on chain". Both statements were wrong, and the web version had already been corrected on 2026-07-25 while this mirror had not. There are **three** standing divergences, the first of them the vault, and the vault fixes are **not** on chain. The promise at the foot of this document, that the mirror and the web version change in the same commit, was broken inside the document that makes it. A CI check now enforces it: see [`../.github/workflows/mirror-freshness.yml`](../.github/workflows/mirror-freshness.yml).

## The four buckets

1. **Fixed and deployed.** Live bytecode. Per-finding closing commits at [kerne.fi/security/findings-tracker](https://kerne.fi/security/findings-tracker).
2. **Fixed in source, not yet on chain.** The deployment ceremony this document once described as pending has since executed, in two parts: the vault on 2026-06-16 and the mint PSM on 2026-07-10. The PSM was deployed from the frozen audit commit and matches it. The vault was deployed from source that **predates** the vault fixes, so those fixes did not close on chain when the ceremony ran, and the eight Hexens remediations written afterwards are not on chain either. That is the first row of the table below, stated rather than left for a reader to infer from the word FIXED. Today kUSD `MINTER_ROLE` is held by exactly two contracts, KerneVault v2 `0x8ccc56B5...292B` and the live KUSDPSM `0xaBDE1138...9803` (confirm on chain, and see the verification table in the [root README](../README.md)).
3. **Open on chain, with a mitigation and an operating rule.** The three standing divergences below. These are the gaps that persist today, each with a stated rule that bounds its exposure.
4. **Source only, never deployed.** The repository contains contracts that have never been deployed (including `kUSDMinter` and the cross-chain bridge stack, the latter under an explicit do-not-deploy quarantine). Findings against them affect no live funds. [`SCOPE.md`](SCOPE.md) draws this boundary precisely.

## The three standing divergences

Each row states what the live bytecode does, what the current source does instead, the practical exposure, and the operating rule that bounds it. All three contracts are source-verified on BaseScan and Sourcify, so everything described here is independently checkable against the deployed code itself.

### 1. KerneVault v2

**Address:** [`0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`](https://basescan.org/address/0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B#code) (deployed 2026-06-16)

**Deployed bytecode.** The verified source of the live vault is byte-identical to repository commit `ecc95cf7` (2026-06-15), the day before it was deployed. That is roughly three weeks earlier than commit `0912c870`, the commit the Hexens review covers. All ten findings in the Hexens initial report are live on this bytecode, along with three defects we found and fixed ourselves after the deploy and before the audit freeze: two NAV accounting gaps on the sweep, L1 and prime-allocation paths, and the withdrawal-side esKERNE forfeiture dust bypass reported by a whitehat. The on-chain public-deposits gate is also absent, so calling `depositsEnabled()` on the live contract reverts.

**Current source.** Current source carries the two NAV reclassification fixes, the forfeiture high-water fix, and the `depositsEnabled` gate. The remediation branch `flip/hexens-remediation-jul20` at commit `98f29e55`, a child of the audited commit, additionally carries eight of the ten Hexens fixes. The other two findings are acknowledged by design, with the reasoning published in full rather than patched under time pressure.

**Practical exposure.** The vault holds no user funds. `totalSupply()` is 0, its WETH balance is 0, and no third party has ever held a share. Both High findings concern esKERNE forfeiture, and esKERNE `totalSupply()` and `totalEmitted()` are both 0, so nothing has ever been emitted for the mechanism to act on. There is no open drain. The real exposure is forward-looking and it is specific: because the on-chain deposits gate was never deployed, `maxDeposit()` returns the maximum uint256 for any address, so a depositor could put funds into pre-audit bytecode before the remediated build is live.

**Operating rule.** Standing operating rule, and the sequencing this protocol commits to: remediated bytecode before capital, not before announcement. No deposit is opened into this address until the remediated build is deployed and verified. Closing the door on chain is a single 2-of-3 Safe call to `setWhitelistEnabled(true)`, which reproduces the missing gate exactly and leaves withdrawals untouched. The full finding-by-finding on-chain map, with commands to reproduce every claim, is in the repository at `docs/security/DEPLOYED_BYTECODE_VS_AUDITED_SOURCE_2026-07-25.md`.

**Closure status, as of 2026-07-28.** That Safe call is **proposed and not executed**. `safeTxHash` `0xf08a3a84f8beb6a5fcc17ebafb1a0732bd3eeebc88cf7f933baad6a56519505c` at Safe nonce 18, `to` the vault, calldata `0x052d9e7e` with the boolean set true, signed by 1 of the 2 required owners. Until it executes, deposits are open, and this line says so. Check it yourself:

```bash
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "maxDeposit(address)(uint256)" 0x0000000000000000000000000000000000000001 \
  --rpc-url https://mainnet.base.org      # returns 2^256-1 while deposits are open
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "whitelistEnabled()(bool)" --rpc-url https://mainnet.base.org   # false until the Safe call executes
```

### 2. kUSD

**Address:** [`0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3`](https://basescan.org/address/0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3#code) (deployed 2026-04-08)

**Deployed bytecode.** Standard OpenZeppelin `ERC20Burnable`: `burnFrom` is callable by any address holding an allowance from the token owner. No role gate on burning.

**Current source.** Burning is gated behind `BURNER_ROLE` in `src/kUSD.sol`; only role holders can burn third-party balances, allowance or not.

**Practical exposure.** An attacker must first obtain an allowance from the holder (a malicious or compromised approval target). With one, they can destroy the holder's kUSD rather than transfer it. There is no path to burn without an allowance, so the practical surface is the same approval hygiene every ERC-20 demands.

**Operating rule.** Permanent disclosure item. No kUSD redeploy is planned: a token migration would cost holders more than the role gate is worth at current scale. Treat kUSD approvals with the same care as any token approval.

### 3. KerneYieldDistributor

**Address:** [`0x096e38a04B632D28E017f86836225E0956CaD878`](https://basescan.org/address/0x096e38a04B632D28E017f86836225E0956CaD878#code) (deployed 2026-04, pre-timelock source)

**Deployed bytecode.** `ROOT_UPDATER_ROLE` can set a new Merkle distribution root with immediate effect. The role is held by the operational hot wallet `0x09a2780ac8Be6D5d2d1F85A8D92b09D40C9CA37e` (the same EOA that signs the hourly Proof of Reserves).

**Current source.** Root updates go through `proposeMerkleRoot` and `executeMerkleRoot` with a 24-hour `ROOT_UPDATE_TIMELOCK`, so a compromised updater key cannot route funds instantly.

**Practical exposure.** If the deployed contract held funds and the hot key were compromised, an arbitrary root could claim them. Today the exposure is zero in practice because the contract is deliberately unfunded: there is nothing on it to route.

**Operating rule.** Standing operating rule: never fund the deployed distributor. Redeploy from current source (with the timelock) before any real yield routes through it. The unfunded state is verifiable on chain at any time.

## Closed on chain since the last revision

**skUSD immediate-distribution (self-found High, 2026-05-28).** The prior staking vault credited each yield distribution to the share price atomically, so a depositor could bracket a distribution within a single block (deposit, distribute, redeem) and capture a share of it. The 2026-07-03 redeploy to the live skUSD `0x96F5102C15b839757f811A98CEc3725Ac21DfA14` deployed the streaming source: distributed yield now vests linearly over `yieldVestingPeriod` (86400 seconds / 24 hours on chain, floored at `MIN_VESTING_PERIOD` = 1 hour) and the still-unvested portion is excluded from `totalAssets()` via `lockedYield()`, so a single-block flash deposit captures none of it. This is checkable directly against the deployed bytecode (Sourcify runtime match; source mirrored at [`../contracts/skUSD/src/skUSD.sol`](../contracts/skUSD/src/skUSD.sol)) and by reading `yieldVestingPeriod()` on chain. Deployed now matches source, so the row has left the table above. skUSD remains in the Hexens core audit scope (fieldwork ran from July 13, 2026 and the initial report landed on July 20, 2026, with remediation underway).

## Not a divergence, but read it before you file one

**KerneTreasury v3 `0x5343C41d4FF2B61DAacA9cbC050550C40605B075`** is the live treasury and the address the live mint PSM returns from `treasury()`. It has **no published source** on BaseScan, Sourcify or Blockscout as of 2026-07-28, so there is no source to diverge from; it is unverified bytecode rather than a source-versus-chain gap. It holds no protocol assets (0 ETH, 0 WETH, 0 USDC, 0 KERNE) and its `owner()` is the 2-of-3 Safe. The retired v2 `0x7c07517A...60d5` is source-verified and is what the `contracts/KerneTreasury/` bundle in this repo mirrors. Both are recorded in [`../deployments/8453.json`](../deployments/8453.json), and the unverified status is disclosed in the [root README](../README.md) and [`SCOPE.md`](SCOPE.md).

## Why we publish this

A reviewer who finds a source-versus-chain gap on their own has every reason to read it as concealment. The same facts, stated by the team first with addresses and operating rules, are evidence the team knows its own system. If a future deployment changes any row above, this document and the web version change in the same commit as the deployment record. That promise is now checked by CI on every push and on a daily schedule, comparing the parsed date and the divergence count in this file against the canonical web version.

Related: [`SCOPE.md`](SCOPE.md) (audit scoping), [`../HOW_TO_VERIFY_KERNE.md`](../HOW_TO_VERIFY_KERNE.md) (independent verification), [kerne.fi/dataroom](https://kerne.fi/dataroom) (one-URL diligence surface).
