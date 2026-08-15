# Audit scope reference

For security firms scoping a review of Kerne Protocol. Generated 2026-06-12 from the verified source mirror in [`contracts/`](../contracts/README.md); every file below that names a `contracts/` path is bytecode-matched to its deployed address on Base mainnet (chain 8453). Addresses deployed after the mirror snapshot are called out in the notes below and should be read from the explorer.

> **2026-06-16 ceremony note.** KUSDPSM and KerneVault were redeployed after this scope was generated. That ceremony put **KUSDPSM v3 `0x07eBb486e11BD217e6085eb5ab663e4517595993`** and **KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`** on the mint path (both source-verified on BaseScan/Sourcify 2026-06-17). The pre-ceremony deployment (old PSM `0xFf3025ec...5Fbc`, MINTER revoked, now redeem reserve; v1 vault `0x8005bc7A...F2AC`, retired) is recorded under `retired` in [`deployments/8453.json`](../deployments/8453.json). The `contracts/KUSDPSM/` and `contracts/KerneVault/` source bundles were refreshed on 2026-07-11 to mirror **this ceremony's** PSM and vault, that is KUSDPSM **v3 `0x07eBb486...5993`** and KerneVault v2 `0x8ccc56B5...292B` (verified byte-for-byte against Sourcify). **Read that with the 2026-07-10 note below: the mint PSM was redeployed the day before that refresh, and the bundle mirrors the retired v3, not the live mint path.** This sentence used to say only "the PSM and vault source", which a reader arriving in date order takes to mean the current mint PSM. Clarified 2026-08-14.
>
> **2026-07-03 skUSD redeploy.** The staking vault was additionally redeployed to **skUSD `0x96F5102C15b839757f811A98CEc3725Ac21DfA14`** (from the prepared skUSD source, which also reset a distorted share-price state), superseding `0xdEd74F7E...09DB4` (retired, recorded under `retired.skUSD_v1`). The address in the Tier 1 table below is the live one, and the `contracts/skUSD/` bundle was refreshed on 2026-07-11 to mirror it (verified byte-for-byte against Sourcify). The live source implements the yield-vesting defense (`yieldVestingPeriod`, with `lockedYield()` excluded from `totalAssets()`); see [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md). skUSD is in this audit's scope.
>
> **2026-07-10 PSM redeploy (current mint path).** The mint PSM was redeployed again. The **live** mint PSM is now **`0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803`**, and kUSD `MINTER_ROLE` was revoked on KUSDPSM v3 `0x07eBb486...5993` the same day. Today `MINTER_ROLE` on kUSD is held by exactly two contracts: **KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`** and the **live KUSDPSM `0xaBDE1138...9803`**. KUSDPSM v3 `0x07eBb486...5993` is retired from minting and retained redeem-only; its USDC reserve still backs the kUSD minted through it until reserves migrate, so it stays in scope as a reserve-holding contract even though it can no longer mint. Both PSM instances are listed in the Tier 1 table below. The `contracts/KUSDPSM/` bundle in this repo mirrors the retired v3 address, so pull the live PSM's source from BaseScan or Sourcify for `0xaBDE1138...9803` rather than assuming that bundle matches it.
>
> **Re-checked byte for byte on 2026-08-14, because two notes in this file could be read as disagreeing about it.** `contracts/KUSDPSM/src/KUSDPSM.sol` is **byte-identical** to the Sourcify-verified source of the retired v3 `0x07eBb486...5993` (43,240 bytes, `diff` returns nothing) and **differs** from the live mint PSM `0xaBDE1138...9803` (45,019 bytes). The whole of the difference is the **2026-07-06 redeem-burn fix, `KRN-26-PSM-REDEEM-NO-BURN`**: the live PSM adds a `KusdBurnFailed()` error and, on the redeem path while `mintingEnabled` is true, self-burns the returned kUSD instead of parking it as inventory. Deploying that fix is why the PSM was redeployed on 2026-07-10 in the first place. Reproduce it:
>
> ```bash
> curl -s "https://sourcify.dev/server/v2/contract/8453/0x07eBb486e11BD217e6085eb5ab663e4517595993?fields=sources" \
>   | jq -r '.sources["src/KUSDPSM.sol"].content' > v3.sol
> curl -s "https://sourcify.dev/server/v2/contract/8453/0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803?fields=sources" \
>   | jq -r '.sources["src/KUSDPSM.sol"].content' > live.sol
> diff v3.sol contracts/KUSDPSM/src/KUSDPSM.sol   # no output: the bundle IS v3
> diff v3.sol live.sol                            # the redeem-burn fix, and nothing else
> ```

## Tier 1 — core risk-bearing contracts (deployed), ~960 nSLOC

| Contract | File | Address | nSLOC |
|---|---|---|---|
| kUSD | `contracts/kUSD/src/kUSD.sol` | `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3` | 17 |
| skUSD (live) | `contracts/skUSD/src/skUSD.sol` | `0x96F5102C15b839757f811A98CEc3725Ac21DfA14` | 57 |
| KUSDPSM (live mint path) | BaseScan/Sourcify verified source for this address (see note above) | `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803` | 309 |
| KUSDPSM v3 (retired 2026-07-10, redeem-only reserve) | `contracts/KUSDPSM/src/KUSDPSM.sol` | `0x07eBb486e11BD217e6085eb5ab663e4517595993` | (same contract, not counted twice) |
| KerneVault v2 (live) | `contracts/KerneVault/src/KerneVault.sol` | `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B` | 577 |

Note on "the minter": earlier RFP materials listed a `kUSDMinter` contract in the core scope. `kUSDMinter` is **not deployed** (it is Phase 2/3 leverage infrastructure). All live minting runs through the live `KUSDPSM` (`0xaBDE1138...9803`) and `KerneVault` v2, both in Tier 1, so the deployed core scope is the Tier 1 contracts above.

## Tier 2 — full deployed verified surface, ~1,683 nSLOC

Tier 1 plus:

| Contract | File | Address | nSLOC |
|---|---|---|---|
| KERNE (v2) | `contracts/KERNE/src/KerneTokenV2.sol` | `0x230f3a63E8413D42bEe9103b98a204030206186c` | 95 |
| esKERNE | `contracts/esKERNE/src/esKERNE.sol` | `0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34` | 148 |
| KerneTreasury v2 (retired 2026-07-13, superseded as fee sink) | `contracts/KerneTreasury/src/KerneTreasury.sol` | `0x7c07517ABcc4BD674CC74B76D2Ab0d95A41560d5` | 191 |
| KerneInsuranceFund | `contracts/KerneInsuranceFund/src/KerneInsuranceFund.sol` | `0xE8799FCF327C6D2f78103a3c9308C93592A30403` | 108 |
| KerneReferral | `contracts/KerneReferral/src/KerneReferral.sol` | `0x1A04AF62baFc84b08b19d2aF7285eD5f8dAe4D9f` | 29 |
| KerneYieldDistributor | `contracts/KerneYieldDistributor/src/KerneYieldDistributor.sol` | `0x096e38a04B632D28E017f86836225E0956CaD878` | 50 |
| KerneYieldOracle | `contracts/KerneYieldOracle/src/KerneYieldOracle.sol` | `0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB` | 102 |

> **KerneTreasury note (2026-07-28).** The address in the Tier 2 row above is the **retired** treasury v2. The **live** treasury is **v3 `0x5343C41d4FF2B61DAacA9cbC050550C40605B075`** (deployed 2026-06-16), and the live mint PSM `0xaBDE1138...9803` returns it from `treasury()`, so PSM fee sweeps accrue there. v3 has **no published source**: checked 2026-07-28 against BaseScan, the Sourcify v2 API and Blockscout, none of which holds a verification. It is therefore outside the "full deployed verified surface" this tier describes and is excluded from the nSLOC totals; treat it as unverified bytecode. It holds no protocol assets today (0 ETH, 0 WETH, 0 USDC, 0 KERNE) and its `owner()` is the 2-of-3 Safe. The `contracts/KerneTreasury/` bundle mirrors v2, which stays listed because it is the source that is actually published and bytecode-matched. The retired PSM `0x07eBb486...5993` still returns v2 from `treasury()`.

## nSLOC method

Non-blank, non-comment lines of the primary contract file per bundle. OpenZeppelin dependencies, project interfaces, and the deploy-time dependency copies inside each bundle are excluded from the counts (they are present in `contracts/` for compilation completeness).

## Deployed vs source

Where deployed bytecode differs from the current source (four standing divergences, each with a mitigation and an operating rule), see [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md). Read it before triaging any finding marked FIXED in Kerne's internal documents: FIXED means fixed in source, and that file is the canonical record of what is and is not live on chain.

**Configuration state is a separate axis, and it does not show up in a diff.** A contract can match its source exactly and still have a check switched off by a setter, in which case comparing source against the explorer shows nothing. The live example is the PSM solvency gate, currently disabled on the live mint path `0xaBDE1138...9803`. The live value of every flag of this kind is published as an on-chain read under `triggers.onChain` at [kerne.fi/api/risk-status](https://kerne.fi/api/risk-status), human-readable at [kerne.fi/risk](https://kerne.fi/risk); read it there rather than inferring gate state from source. The configuration-state section of [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md) sets out the category. Raised by **ParthaSarathi**, 2026-08-01.

**A third axis, added 2026-08-14: a control that is declared and never implemented.** `KerneVault.maxLiquidationPerHourBps()` returns 500 on the live vault, which reads as a 5 percent per hour liquidation throttle. There is no throttle. The variable is read nowhere, its hourly-amount mapping is written nowhere, and its `LiquidationRateLimited` event is emitted nowhere and its topic is absent from the deployed bytecode. Source and bytecode agree with each other here, so this shows up in neither a diff nor a flag read, which is why it is called out separately. Full disclosure, with the three reproduction commands, in [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md). Found by Kerne while adjudicating the 2026-07-29 disclosure burst, and it appeared in neither document until today.

**The skUSD row is in scope for anyone reviewing that contract, and it postdates the report.** `KRN-26-SKUSD-SQUAT`: the `KRN-26-SKUSD-ORPHAN` reset in the deployed `skUSD._withdraw` is gated on `totalSupply() == 0`, which one wei of shares holds open indefinitely, so a dust position can inherit an unvested yield distribution once the staked capital exits. Self-found 2026-07-30, fixed in source the same day, open on chain because skUSD is not a proxy. skUSD was in the core review scope of the 2026-07-31 Hexens report, which carries no findings against it, so read that clean result as covering the reviewed commit rather than as covering this. The measurement is reproducible from this repository: `forge test --match-contract SkusdOrphanResetSquatDisclosureTest`.

The KerneVault row is the one that matters most for scoping this review: the live KerneVault v2 `0x8ccc56B5...292B` is **not** the audited commit. Its verified source is byte-identical to repository commit `ecc95cf7` (2026-06-15), roughly three weeks before the audited commit `0912c870`, so all ten findings of the Hexens report are live on the deployed bytecode and the on-chain deposit gate was never deployed. **Public WETH deposits were closed on chain on 2026-07-30** by the 2-of-3 Safe call to `setWhitelistEnabled(true)` at nonce 18; `maxDeposit` now returns 0 for a non-whitelisted address, and the vault is not paused, so withdrawals are untouched. See [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md) for the transaction hash and the reproduction commands.

## Out of scope

- The off-chain hedging engine, risk engine, and operational tooling (Python, not smart contracts).
- Frontends (kerne.fi, app.kerne.fi).
- Undeployed in-development contracts (including `kUSDMinter`).
- `KerneStaking` and `KerneFlashArbBot`: deployed but not source-verified (disclosed in the [root README](../README.md)); both are queued for redeploy-and-verify and can be added to scope at that point.
