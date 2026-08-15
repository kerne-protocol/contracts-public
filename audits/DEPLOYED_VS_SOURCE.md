# Deployed vs source: state disclosure

For reviewers and audit firms. Last updated 2026-08-14. Mirrors the canonical web version at [kerne.fi/security/deployed-vs-source](https://kerne.fi/security/deployed-vs-source), which carries the July 30, 2026 closure described in the KerneVault row. This file may run slightly ahead of the page after a mirror-side correction; that direction is the safe one, and it is the direction the CI check permits.

**The skUSD row was added on 2026-08-14 and read at Base block 49,987,258. The other three rows were re-read against chain at Base block 49932056 on 2026-08-13.** No row changed state. The re-read confirmed: the vault's `totalSupply()` is still 0 and `depositsEnabled()` still reverts while `whitelistEnabled()` is true and `maxDeposit()` returns 0 for every address; `BURNER_ROLE()` still reverts on kUSD while `MINTER_ROLE()` returns a valid hash; and the distributor still holds 0 ETH, 0 USDC and 0 kUSD with `ROOT_UPDATE_TIMELOCK()` still reverting. A full module-by-module table of the live reads, with the command behind every cell, is published at [kerne.fi/security/module-map](https://kerne.fi/security/module-map).

On any young protocol the repository moves faster than the chain. This document is the canonical table of every place where Kerne's deployed bytecode behaves differently from the current source. It was first published before any external review began, and it is where the gap between the audited commit and the deployed contracts is stated, so a reviewer reading the code finds context here rather than surprises there.

The reading rule: when an internal security document marks a finding FIXED, that means fixed in source. Whether the fix is live on chain is a separate fact, and this document is where that fact lives.

> **Correction, 2026-07-28.** The revision of this file dated 2026-07-20 listed **two** standing divergences and said the vault findings targeted by the 2026-06-16 ceremony "are fixed on chain". Both statements were wrong, and the web version had already been corrected on 2026-07-25 while this mirror had not. There are **three** standing divergences, the first of them the vault, and the vault fixes are **not** on chain. The promise at the foot of this document, that the mirror and the web version change in the same commit, was broken inside the document that makes it. A CI check now enforces it: see [`../.github/workflows/mirror-freshness.yml`](../.github/workflows/mirror-freshness.yml).
>
> **The count moved again on 2026-08-14, to four.** skUSD joined the table when the `KRN-26-SKUSD-SQUAT` fix was written and not deployed. That is the count enforced by CI today; the paragraph above is left as written because it is a dated correction and rewriting it would erase the thing it records.

## The four buckets

1. **Fixed and deployed.** Live bytecode. Per-finding closing commits at [kerne.fi/security/findings-tracker](https://kerne.fi/security/findings-tracker).
2. **Fixed in source, not yet on chain.** The deployment ceremony this document once described as pending has since executed, in two parts: the vault on 2026-06-16 and the mint PSM on 2026-07-10. The PSM was deployed from the frozen audit commit and matches it. The vault was deployed from source that **predates** the vault fixes, so those fixes did not close on chain when the ceremony ran, and the eight Hexens remediations written afterwards are not on chain either. That is the KerneVault row of the table below, stated rather than left for a reader to infer from the word FIXED. **The same bucket now holds a second contract: the skUSD fix tagged `KRN-26-SKUSD-SQUAT` is in source and not on chain, and it is the first row below.** Today kUSD `MINTER_ROLE` is held by exactly two contracts, KerneVault v2 `0x8ccc56B5...292B` and the live KUSDPSM `0xaBDE1138...9803` (confirm on chain, and see the verification table in the [root README](../README.md)).
3. **Open on chain, with a mitigation and an operating rule.** The four standing divergences below. These are the gaps that persist today, each with a stated rule that bounds its exposure.
4. **Source only, never deployed.** The repository contains contracts that have never been deployed (including `kUSDMinter` and the cross-chain bridge stack, the latter under an explicit do-not-deploy quarantine). Findings against them affect no live funds. [`SCOPE.md`](SCOPE.md) draws this boundary precisely.

## The four standing divergences

Each row states what the live bytecode does, what the current source does instead, the practical exposure, and the operating rule that bounds it. All four contracts are source-verified on BaseScan and Sourcify, so everything described here is independently checkable against the deployed code itself.

### 1. skUSD

**Address:** [`0x96F5102C15b839757f811A98CEc3725Ac21DfA14`](https://basescan.org/address/0x96F5102C15b839757f811A98CEc3725Ac21DfA14#code) (deployed 2026-07-03)

**Deployed bytecode.** The live skUSD is byte-identical to commit `0912c870`, the commit the Hexens review covers, and Sourcify reports both a runtime match and a creation match against it. What the bytecode does not carry is a fix written after that freeze. In the deployed `_withdraw`, the `KRN-26-SKUSD-ORPHAN` reset that collapses an in-flight yield vest fires only when `totalSupply()` reaches zero, and one wei of shares holds that trigger open indefinitely. An address that keeps a dust position outstanding while the staked capital exits during a vest ends up owning the entire still-unvested distribution, which would otherwise have gone to the stakers who stayed. Tagged `KRN-26-SKUSD-SQUAT`. skUSD was in the Hexens core scope and the final report carries no findings against it; this one came out of Kerne's own adversarial sweep of the live money surfaces on 2026-07-30.

**Current source.** Current source caps the amount still vesting after an exit at the principal still staked, so one distribution can at most double the remaining stake over its vest and a dust position inherits nothing. The excess leaves the tracked ledger and becomes an untracked donation the strategist can sweep and redistribute, which is the same destination the zero-supply reset already uses. An early exit still forfeits its slice of the vest to the remaining stakers, because that is the locked-profit behaviour the flash-deposit defence rests on, and it is deliberately unchanged. The fix landed on 2026-07-30, the day it was found.

**Practical exposure.** Measured, not estimated. Compiled against the exact source that is deployed, the regression stakes 1,000 kUSD, distributes 1,000 kUSD, exits the staker while the distribution is still fully locked, and the one-wei position then redeems 500.000000000000000001 kUSD. The 1e6 virtual-share offset absorbs the other half, and a larger squat takes proportionally more. Against current source the same position redeems exactly the wei it deposited. Two conditions have to hold at once for that to pay anything on chain and neither holds today. First, a distribution has to be in flight: `lockedYield()` returns **0**, and it is non-zero only inside the vesting window after a `distributeYield()` call, which is gated on `STRATEGIST_ROLE` held by a single address, so the window is opened by Kerne rather than by an attacker. Second, the staked principal has to collapse below the still-unvested amount while that window is open: skUSD holds **1,011.582169134048985696 kUSD** of staked principal, and exactly one distribution has ever run on this contract, 0.1 kUSD at block 48383014 on 2026-07-09, the smoke test that proved the strategist path end to end, fully vested a day later. At those magnitudes more than 99.99 percent of the stake would have to leave inside one vesting window.

**Operating rule.** Standing operating rule: no `distributeYield()` call is made into a vault whose staked principal is not large relative to the distribution, and if `lockedYield()` and `totalAssets()` ever approach each other, distributions stop until the fix is on chain rather than being sized around the defect. Both numbers are readable on chain by anyone at any time, so the rule is checkable rather than promised. `yieldVestingPeriod` is 86,400 seconds against a floor of 3,600 and the 2-of-3 Safe can shorten it in a single call, which narrows the window without closing the gap. The gap closes only on a redeploy: skUSD is not a proxy, and this is the contract where the protocol's staked kUSD actually sits, so shipping the fix means migrating the staked balance across every holder rather than patching an empty vault. No date is claimed here, because a date this document cannot keep is worth less than the plain statement that the fix is written, tested and waiting on a migration.

Read at Base block 49,987,258 on 2026-08-14. Check it yourself:

```bash
SKUSD=0x96F5102C15b839757f811A98CEc3725Ac21DfA14
RPC=https://mainnet.base.org

cast call $SKUSD "lockedYield()(uint256)"         --rpc-url $RPC   # 0, no distribution in flight
cast call $SKUSD "totalAssets()(uint256)"         --rpc-url $RPC   # 1011582169134048985696
cast call $SKUSD "yieldVestingPeriod()(uint256)"  --rpc-url $RPC   # 86400
```

### 2. KerneVault v2

**Address:** [`0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`](https://basescan.org/address/0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B#code) (deployed 2026-06-16)

**Deployed bytecode.** The verified source of the live vault is byte-identical to repository commit `ecc95cf7` (2026-06-15), the day before it was deployed. That is roughly three weeks earlier than commit `0912c870`, the commit the Hexens review covers. All ten findings in the Hexens final report (published 2026-07-31, committed at [`hexens-kerne-protocol-final-2026-07-31.pdf`](hexens-kerne-protocol-final-2026-07-31.pdf)) are live on this bytecode, along with three defects we found and fixed ourselves after the deploy and before the audit freeze: two NAV accounting gaps on the sweep, L1 and prime-allocation paths, and the withdrawal-side esKERNE forfeiture dust bypass reported by a whitehat. The on-chain public-deposits gate is also absent, so calling `depositsEnabled()` on the live contract reverts.

**Current source.** Current source carries the two NAV reclassification fixes, the forfeiture high-water fix, and the `depositsEnabled` gate. The remediation branch `flip/hexens-remediation-jul20` at commit `98f29e55`, a child of the audited commit, additionally carries eight of the ten Hexens fixes. The other two findings are acknowledged by design, with the reasoning published in full rather than patched under time pressure. The final report records the same split: eight fixed, two acknowledged, and it reproduces Kerne's written commentary on both acknowledged findings.

**Practical exposure.** The vault holds no user funds. `totalSupply()` is 0, its WETH balance is 0, and no third party has ever held a share. Both High findings concern esKERNE forfeiture, and esKERNE `totalSupply()` and `totalEmitted()` are both 0, so nothing has ever been emitted for the mechanism to act on. There is no open drain. The forward-looking exposure this row used to describe, that `maxDeposit()` returned the maximum uint256 for any address so a depositor could put funds into pre-audit bytecode, **was closed on chain on 2026-07-30** (see the closure status below). `maxDeposit()` now returns 0 for a non-whitelisted address. The row stays in this table because the deployed bytecode still differs from current source; what changed is that the difference is no longer reachable by a depositor.

**Operating rule.** Standing operating rule, and the sequencing this protocol commits to: remediated bytecode before capital, not before announcement. No deposit is opened into this address until the remediated build is deployed and verified. Closing the door on chain is a single 2-of-3 Safe call to `setWhitelistEnabled(true)`, which reproduces the missing gate exactly and leaves withdrawals untouched. The full finding-by-finding on-chain map, with commands to reproduce every claim, is in the repository at `docs/security/DEPLOYED_BYTECODE_VS_AUDITED_SOURCE_2026-07-25.md`.

**Closure status: EXECUTED 2026-07-30.** The Safe call described above has run. `safeTxHash` `0xf08a3a84f8beb6a5fcc17ebafb1a0732bd3eeebc88cf7f933baad6a56519505c` at Safe nonce 18 executed in transaction [`0x0be06e9a4a4ce3545fdea6af8e83ed1663e8d0ce35cb28a211836ab83a57579e`](https://basescan.org/tx/0x0be06e9a4a4ce3545fdea6af8e83ed1663e8d0ce35cb28a211836ab83a57579e) at block 49318654, status 1. Public deposits into the pre-audit build are closed. Withdrawals were deliberately left untouched: the vault is **not** paused, so any holder can still exit.

Prior revisions of this file said deposits were open. They were accurate when written and are now superseded. Re-verified first-hand at block 49345485 on 2026-07-31, on `https://mainnet.base.org`. Check it yourself:

```bash
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "maxDeposit(address)(uint256)" 0x0000000000000000000000000000000000000001 \
  --rpc-url https://mainnet.base.org      # returns 0
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "whitelistEnabled()(bool)" --rpc-url https://mainnet.base.org   # true
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "paused()(bool)" --rpc-url https://mainnet.base.org             # false, withdrawals still open
cast call 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B \
  "totalSupply()(uint256)" --rpc-url https://mainnet.base.org     # 0, nobody ever deposited
```

Reopening deposits requires both the remediated build and share math backed by payable assets. It is not a configuration change.

These four assertions are also executable. `test/fork/RegistryMatchesChain.t.sol` checks them against live Base, so a future change to any of them fails a test rather than silently ageing this paragraph:

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'
```

### 3. kUSD

**Address:** [`0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3`](https://basescan.org/address/0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3#code) (deployed 2026-04-08)

**Deployed bytecode.** Standard OpenZeppelin `ERC20Burnable`: `burnFrom` is callable by any address holding an allowance from the token owner. No role gate on burning.

**Current source.** Burning is gated behind `BURNER_ROLE` in `src/kUSD.sol`; only role holders can burn third-party balances, allowance or not.

**Practical exposure.** An attacker must first obtain an allowance from the holder (a malicious or compromised approval target). With one, they can destroy the holder's kUSD rather than transfer it. There is no path to burn without an allowance, so the practical surface is the same approval hygiene every ERC-20 demands.

**Operating rule.** Permanent disclosure item. No kUSD redeploy is planned: a token migration would cost holders more than the role gate is worth at current scale. Treat kUSD approvals with the same care as any token approval.

### 4. KerneYieldDistributor

**Address:** [`0x096e38a04B632D28E017f86836225E0956CaD878`](https://basescan.org/address/0x096e38a04B632D28E017f86836225E0956CaD878#code) (deployed 2026-04, pre-timelock source)

**Deployed bytecode.** `ROOT_UPDATER_ROLE` can set a new Merkle distribution root with immediate effect. The role is held by the operational hot wallet `0x09a2780ac8Be6D5d2d1F85A8D92b09D40C9CA37e` (the same EOA that signs the hourly Proof of Reserves).

**Current source.** Root updates go through `proposeMerkleRoot` and `executeMerkleRoot` with a 24-hour `ROOT_UPDATE_TIMELOCK`, so a compromised updater key cannot route funds instantly.

**Practical exposure.** If the deployed contract held funds and the hot key were compromised, an arbitrary root could claim them. Today the exposure is zero in practice because the contract is deliberately unfunded: there is nothing on it to route.

**Operating rule.** Standing operating rule: never fund the deployed distributor. Redeploy from current source (with the timelock) before any real yield routes through it. The unfunded state is verifiable on chain at any time.

## Closed on chain since the last revision

**skUSD immediate-distribution (self-found High, 2026-05-28).** The prior staking vault credited each yield distribution to the share price atomically, so a depositor could bracket a distribution within a single block (deposit, distribute, redeem) and capture a share of it. The 2026-07-03 redeploy to the live skUSD `0x96F5102C15b839757f811A98CEc3725Ac21DfA14` deployed the streaming source: distributed yield now vests linearly over `yieldVestingPeriod` (86400 seconds / 24 hours on chain, floored at `MIN_VESTING_PERIOD` = 1 hour) and the still-unvested portion is excluded from `totalAssets()` via `lockedYield()`, so a single-block flash deposit captures none of it. This is checkable directly against the deployed bytecode (Sourcify runtime match; source mirrored at [`../contracts/skUSD/src/skUSD.sol`](../contracts/skUSD/src/skUSD.sol)) and by reading `yieldVestingPeriod()` on chain, which returns 86,400 at Base block 49,987,258. skUSD was in the Hexens core audit scope and drew no findings; the final report published on July 31, 2026.

**Corrected 2026-08-14.** This entry used to end by saying deployed matched source on this contract, so the row had left the table above. That was accurate from 2026-07-03 until 2026-07-30, when the adversarial sweep of the live money surfaces found a second defect in the same withdrawal path, `KRN-26-SKUSD-SQUAT`. It was fixed in source the same day and it is not on chain, so **skUSD is the first row of the divergence table above rather than a closed entry here.** The two are separate findings against the same contract: the streaming fix that closed in July is live and intact, and the one-wei squat on the orphan reset is not.

## Not a divergence, but read it before you file one

**Added 2026-08-13: skUSD reports 24 decimals against an 18 decimal asset. This is deliberate and it is the single most likely thing on this system to be integrated wrong.**

`skUSD.decimals()` returns **24**. Its ERC-4626 `asset()` is kUSD, which returns **18**. ERC-4626 permits a share token to use a different decimal precision from its asset, and skUSD uses a fixed **1e6 offset** so that share arithmetic keeps precision at small balances. Nothing about it is a bug and there is nothing to fix, but any integrator, wallet, aggregator or lending market that assumes an ERC-4626 share matches its asset's decimals will misprice skUSD by **six orders of magnitude**, and that assumption is common enough that this is stated here rather than left to be discovered during a listing.

Read the conversion, never the ratio of raw integers:

```bash
SKUSD=0x96F5102C15b839757f811A98CEc3725Ac21DfA14
RPC=https://mainnet.base.org

cast call $SKUSD "decimals()(uint8)"  --rpc-url $RPC   # 24, NOT 18
cast call $SKUSD "asset()(address)"   --rpc-url $RPC   # kUSD, which is 18

# One WHOLE skUSD is 1e24 base units, not 1e18.
cast call $SKUSD "convertToAssets(uint256)(uint256)" 1000000000000000000000000 --rpc-url $RPC
#   -> 1000098667771066974        = 1.000098667771066974 kUSD  (correct: ~1.0001)

# Feeding 1e18, the amount that would be one whole share on an 18 decimal vault:
cast call $SKUSD "convertToAssets(uint256)(uint256)" 1000000000000000000 --rpc-url $RPC
#   -> 1000098667771              = 0.000001000098667771 kUSD  (exactly a millionth of the line above)
```

Both reads above are from Base block 49932056, 2026-08-13. `convertToAssets` is the only correct way to price skUSD; the value moves as yield vests, so any hardcoded ratio is wrong the moment it is written.

**KerneTreasury v3 `0x5343C41d4FF2B61DAacA9cbC050550C40605B075`** is the live treasury and the address the live mint PSM returns from `treasury()`. It has **no published source** on BaseScan, Sourcify or Blockscout as of 2026-07-28, so it cannot be diffed on an explorer the way the three rows above can be, which is why it is not one of them. That is a statement about verifiability, not a claim that its bytecode matches current source: where a behavioural gap does exist, it is stated below. It holds no protocol assets (0 ETH, 0 WETH, 0 USDC, 0 KERNE) and its `owner()` is the 2-of-3 Safe. The retired v2 `0x7c07517A...60d5` is source-verified and is what the `contracts/KerneTreasury/` bundle in this repo mirrors. Both are recorded in [`../deployments/8453.json`](../deployments/8453.json), and the unverified status is disclosed in the [root README](../README.md) and [`SCOPE.md`](SCOPE.md).

**Added 2026-07-29: the buyback floor is now fixed in source and not on chain.** A reviewer diffing the repository will find a behavioural gap on this address, so it is stated here rather than left to be discovered. Current source requires the caller of `executeBuyback` to supply an output floor drawn from a price that caller cannot move inside the execution block, and rejects a zero floor outright with `CallerFloorRequired()` and no owner exemption. The deployed bytecode still accepts a zero floor and, in that case, derives the entire floor from a `previewBuyback` quote read against the same Aerodrome pool the swap executes on, inside the same transaction. That floor is not weak, it is inert: it moves by the same factor an attacker moves the pool by, so it clears at every manipulation size. Two independent researchers demonstrated it 13 days apart, at roughly 30 percent of buyback value in an `ethereumjs` harness (Dmitriy Filatov, 2026-07-14) and 79 percent of the treasury fee balance in a Base fork test against the real Aerodrome router (Mohd Huzaifa, 2026-07-27). Tag `KRN-26-TREASURY-BUYBACK-TWAP`.

The same source change fixes a second defect nobody reported, `KRN-26-KEEPER-BURN-SINK`: `KerneKeeper._executeBuyback` verified output by measuring the KERNE delta on the treasury's `stakingContract`, but the patched treasury burns to `0x...dEaD` and sends staking nothing, so that delta was always zero and the check reverted on every **successful** buyback. `KerneKeeper` is not deployed, so this was never live; it is recorded because the buyback execution path had no test coverage until now.

Neither is reachable on the deployed system. This address holds no inventory, `previewBuyback` returns zero so `executeBuyback` reverts `NoLiquidityForBuyback` before any swap, no buyback keeper is granted, and no KERNE venue deep enough to sandwich exists. The fix reaches chain only in a v4 redeploy, which stays behind the external audit. Until then the flywheel stays disarmed and the gate is enforced in code rather than prose: arming is a 2-of-3 Safe action, and `checkUpkeep` now suggests a zero floor precisely so its `performData` reverts if submitted verbatim.

**Added 2026-08-14: configuration state, not bytecode divergence. A contract can match its source exactly and still not behave the way this document describes, because a runtime flag says otherwise.**

The three rows above all describe deployed *code* differing from current *source*. There is a second way the live system can depart from the posture these documents set out, and none of those rows covers it: the bytecode matches, but a setter has left a check switched off. A reviewer diffing source against BaseScan will not find it, because there is nothing in the diff to find.

The live instance is the PSM solvency gate. `solvencyCheckDisabled()` returns **true** on the live mint PSM [`0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803`](https://basescan.org/address/0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803#code), so `_checkSolvency` is skipped on both the mint and the redeem path: the source implements a check the deployed configuration does not run. The same flag is true on the retired v3 PSM `0x07eBb486...5993`, where it is inert, because that contract's kUSD `MINTER_ROLE` was revoked on 2026-07-10. The sibling depeg gate is **not** disabled: `depegCheckDisabled()` returns false, so that circuit breaker is enforced.

**Where a reader checks configuration state.** Every flag of this kind is published as an on-chain read under `triggers.onChain` at [kerne.fi/api/risk-status](https://kerne.fi/api/risk-status), with a human-readable version at [kerne.fi/risk](https://kerne.fi/risk). That endpoint, not this file, is the canonical answer to "is a gate switched off right now", because it is regenerated from chain rather than written by hand. This file names the category and points at it; the endpoint carries today's values.

```bash
PSM=0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803
RPC=https://mainnet.base.org

cast call $PSM "solvencyCheckDisabled()(bool)" --rpc-url $RPC   # true,  the solvency gate is off
cast call $PSM "depegCheckDisabled()(bool)"    --rpc-url $RPC   # false, the depeg gate is enforced
```

Both read at Base block 49,968,702 on 2026-08-14, identical across three independent RPC endpoints.

**Read the effective state, not only the flag.** The endpoint also publishes `psm_solvency_gate_effective`, which answers something the flag alone does not: whether the gate would measure anything if it were switched back on. It reads `getSolvencyRatio()` on the vault at `0x8ccc56B5...292B`, and that vault's `totalSupply()` is 0, verified at the same block. So the reading is a zero-liabilities constant that clears the published `psm_solvency_gate_threshold` of 10100 rather than a measurement of anything. An enabled gate over an empty vault is decoration, and the endpoint states that rather than leaving a reader to assume the flag is the whole story.

Reported by **ParthaSarathi** on 2026-08-01, who identified both that the gate was off on the live mint path and that this file and [`SCOPE.md`](SCOPE.md) carried no pointer to where configuration state is published. The flag itself was already exposed under `triggers.onChain`; the missing pointer from the auditor-facing mirror is what this section closes.

**Added 2026-08-14: an advertised control that is not implemented in either source or bytecode. `maxLiquidationPerHourBps()` returns 500 on the live vault and throttles nothing.**

This one is neither a divergence nor a configuration flag. Source and deployed bytecode agree with each other; what they agree on is a control that does not exist. Disclosed here because a reviewer reading `KerneVault.sol` will find the declaration, and an integrator calling the getter will read 500 and conclude there is a 5 percent per hour cap on liquidations. There is not.

- `maxLiquidationPerHourBps` is declared at [`KerneVault.sol:314`](../contracts/KerneVault/src/KerneVault.sol) with an initialiser of 500, and it is **read nowhere and written nowhere** in the contract. There is no setter for it either.
- Its companion state, `mapping(uint256 => uint256) public hourlyLiquidationAmounts` at line 317, is **never written**.
- Its companion event, `event LiquidationRateLimited(uint256 attempted, uint256 allowed, uint256 hour)` at line 369, is **never emitted**. Its topic `0x879a839d589e7aa8e777837c2ecc347ba525f58284780825323e576c9dcb3497` is **absent from the deployed bytecode at any alignment**, while three control topics from the same contract (`Transfer`, `DynamicBufferUpdated`, `DepositFeeUpdated`) are present in the same search, which is what makes the absence a fact about the contract rather than about the search.
- The declarations are identical at both audited commits `0912c870` and `98f29e55`, so this is not something a remediation branch introduced or removed.

**Practical exposure.** None today, in the sense that matters: the vault holds no user funds, `totalSupply()` is 0, and there is nothing to liquidate. The exposure is to a reader, not to a depositor. Anyone sizing counterparty risk off the getter would be pricing in a rate limit that would not fire.

**Operating rule.** Either the throttle is implemented or the declaration comes out, and that happens in the same redeployment ceremony as the vault remediation, not before, because the deployed bytecode is not being touched again ahead of it. Until then this paragraph is the disclosure. Read it against chain:

```bash
V=0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B
RPC=https://mainnet.base.org

cast call $V "maxLiquidationPerHourBps()(uint256)" --rpc-url $RPC   # 500, and it binds nothing
cast call $V "hourlyLiquidationAmounts(uint256)(uint256)" 0 --rpc-url $RPC   # 0, never written
cast code $V --rpc-url $RPC | grep -c 879a839d589e7aa8e777837c2ecc347ba525f58284780825323e576c9dcb3497
#   -> 0. The rate-limit event is not in the deployed code.
```

Read at Base block 49,986,375 on 2026-08-14. Found by Kerne while adjudicating the 2026-07-29 disclosure burst, not reported by a researcher, and disclosed to the researchers in that burst on 2026-08-06 along with the commitment to publish it here. It appeared in neither this file nor [`SCOPE.md`](SCOPE.md) until today.

## Why we publish this

A reviewer who finds a source-versus-chain gap on their own has every reason to read it as concealment. The same facts, stated by the team first with addresses and operating rules, are evidence the team knows its own system. If a future deployment changes any row above, this document and the web version change in the same commit as the deployment record. That promise is now checked by CI on every push and on a daily schedule, comparing the parsed date and the divergence count in this file against the canonical web version.

Related: [`SCOPE.md`](SCOPE.md) (audit scoping), [`../HOW_TO_VERIFY_KERNE.md`](../HOW_TO_VERIFY_KERNE.md) (independent verification), [kerne.fi/dataroom](https://kerne.fi/dataroom) (one-URL diligence surface).
