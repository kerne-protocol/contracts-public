# Kerne Seed TVL & Off-Chain Accounting Policy

**Last updated:** 2026-04-25
**Owner:** Protocol governance (2-of-3 Safe `0x52d3E450bA6c299B1B07298F1E87DD74732D4877`)
**Status:** In force

This document records Kerne Protocol's policy on seed TVL, off-chain accounting, and proof-of-reserves transparency. It exists so the policy is auditable in a single place, and so that approaches considered and rejected during design are recorded explicitly rather than buried in commit history.

---

## 1. Affirmative policy

1. **`totalAssets()` is the sum of real, verifiable collateral.** It is never used to display protocol-owned fictional capital. Every unit of asset reported by `totalAssets()` is reconcilable to either an on-chain ERC-20 balance, an off-chain hedge-venue balance with a published attestation, or a verified Hyperliquid L1 bridge balance.

2. **The four accounting buckets are broken out individually on `/api/por` and on the Transparency Dashboard.** Specifically: `_trackedOnChainAssets` (real ERC-20 balance held by the vault), `offChainAssets` (CEX hedge collateral), `l1Assets` (Hyperliquid L1 bridge balance), and `hedgingReserve` (on-chain hedge buffer). The aggregate is never the only number a reviewer can see. A non-zero value in any single bucket is loudly visible to any caller fetching the PoR JSON or rendering the dashboard.

3. **Each non-zero off-chain bucket is paired with a public attestation that names the venue, the wallet or account address, and the timestamp of the last reconciliation.** The bot's PoR attestation pipeline (`bot/por_attestation.py`, `bot/zk_attestation_service.py`) writes `netDelta`, `exchangeEquity`, and `timestamp` fields for this purpose. The public-facing render is the PoR JSON plus the attestation epoch.

4. **The `STRATEGIST_ROLE` that gates `updateOffChainAssets`, `updateL1Assets`, and `updateHedgingReserve` is held by an automated bot under documented operational scope.** A human under social-engineering pressure cannot manually inflate any bucket. The bot's update logic is further constrained by `offChainUpdateCooldown` and `maxOffChainChangeRateBps` enforced inside `KerneVault.sol` (lines 644 to 658). Neither guard can be bypassed without a contract upgrade, which itself requires the 2-of-3 Safe.

5. **User-facing copy never describes protocol-owned reserves as user TVL or "Institutional Partners".** API field naming, dashboard labels, marketing copy, and aggregator submissions use plain accounting words: "vault collateral", "off-chain hedge collateral", "L1 bridge balance", "on-chain hedge buffer". If the protocol ever deploys its own capital into the vault, that capital is labeled `protocolOwnedReserves` and broken out as its own bucket on `/api/por`.

---

## 2. Approaches considered and rejected

For the public record, this section names approaches that were considered during the protocol design phase and explicitly rejected. They are documented so the reasoning is auditable and so a future operator cannot silently revisit them.

### 2.1 Rejected: "Ghost TVL" via inflated `offChainAssets`

A 2026-Q1 internal draft proposed using the `offChainAssets` state variable to represent fictional protocol-owned seed capital. The mechanism was: deposit a small real amount, then call `updateOffChainAssets(N)` with N orders of magnitude larger than reality, so `totalAssets()` reports a TVL number unrelated to actual collateral. The draft also proposed re-labeling the resulting display as "Institutional Seed / Hedging Reserve" or relabeling user counts as "Institutional Partners" to maintain the appearance of credibility.

This approach was rejected on three grounds.

**Solvency failure mode.** If `totalAssets()` reports values that do not correspond to real collateral, the contract's solvency-ratio circuit breaker (`getSolvencyRatio()` at `KerneVault.sol` line 575) is operating on numbers it cannot defend. A real liquidity event, kUSD redemption or vault withdrawal at scale, would expose the gap on the same block.

**Reputational failure mode.** Any future audit, public source-mirror publication, journalist review, or hostile review thread that surfaces the approach lands Kerne in the same category as Stream Finance, Elixir's xUSD recursive loop, and earlier collapses where internal documentation surfaced fictional-collateral mechanisms in the post-mortem. The reputational cost of one screenshot exceeds any plausible TVL benefit.

**Deceptive copy.** Re-labeling protocol-owned reserves as "Institutional Partners" is explicitly deceptive. Word choice is not a substitute for actual institutional capital. Kerne's policy is to describe capital sources accurately, including when they are protocol-owned.

The rejection is recorded here, in plain language, in a top-level docs file, so any future operator reading this policy stops before reconsidering.

### 2.2 Rejected: silent absorption of off-chain buckets in `/api/por`

An earlier version of the PoR endpoint reported `vault.assetAmount` as the sum of `_trackedOnChainAssets + offChainAssets + l1Assets + hedgingReserve` without breaking out the four buckets. This was rejected in favor of explicit per-bucket disclosure. The current `/api/por` JSON includes a `reserves.vault.composition` object naming each bucket with its current value, in both ETH and USD-denominated terms, so any non-zero off-chain value is impossible to absorb silently into the aggregate.

### 2.3 Rejected: re-labeling depositor count as "Institutional Partners"

The same Q1 draft proposed updating the frontend `/api/stats` user-count field to read "Institutional Partners" instead of an honest depositor count. This UI lever was never implemented. The current `/api/stats` exposes only objective metrics (TVL in WETH and USD, kUSD supply, vault address). No user-count field exists, and none will be added that re-categorizes individual depositors as institutions.

---

## 3. How to verify this policy is in force

Anyone, including auditors, allocators, and journalists, can verify the policy is in force at any time using only public RPC endpoints and a curl command.

```bash
# Bucket-by-bucket on-chain read
cast call 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC "offChainAssets()(uint256)" --rpc-url https://mainnet.base.org
cast call 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC "l1Assets()(uint256)"        --rpc-url https://mainnet.base.org
cast call 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC "hedgingReserve()(uint256)"  --rpc-url https://mainnet.base.org
cast call 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC "totalAssets()(uint256)"     --rpc-url https://mainnet.base.org

# Same data, public PoR endpoint
curl -s https://kerne.fi/api/por | jq '.reserves.vault.composition'
curl -s https://app.kerne.fi/api/por | jq '.reserves.vault.composition'
```

The four `cast call` results must sum to the `totalAssets()` reading on the same block. The `composition` object on the PoR endpoint must mirror the four `cast` reads at any point in time. The Transparency Dashboard at `https://app.kerne.fi/dashboard/transparency` renders the same composition via wagmi reads against the same contract.

When a non-zero off-chain bucket appears, the bot's PoR attestation pipeline publishes the corresponding `netDelta`, `exchangeEquity`, and `timestamp` so the off-chain venue side of the accounting is also independently verifiable. Pre-launch, all off-chain buckets are zero and this section serves as the standing policy for the first non-zero value.

---

## 4. Change control

Any future change to this policy requires:

1. A pull request that updates this file.
2. A corresponding PR that updates `/api/por` (both `kerne.fi` and `app.kerne.fi`) and the Transparency Dashboard composition wiring, if and only if the change adds, removes, or renames a bucket.
3. A 2-of-3 Safe acknowledgement transaction emitting an event at the protocol governance address. The transaction body is the keccak hash of the new policy file, so the policy version in force at any block is provable.
4. A Twitter or Farcaster post from the canonical `@KerneProtocol` handle announcing the policy change with a link to the PR and the Safe transaction.

---

*This policy supersedes the retired `docs/marketing/seed_tvl_strategy.md` draft, which was removed from the repository on 2026-04-25 along with this document's publication. The retirement was first noted in `docs/marketing/MARKETING_MASTER.md` as part of the 2026-Q1 ethical-hardening pass; this file completes the retirement by recording the affirmative policy that replaces it.*
