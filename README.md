# Kerne Protocol Contracts (public mirror)

Public verification surface for [Kerne Protocol](https://kerne.fi), a delta-neutral synthetic dollar on Base mainnet (chain 8453). This repository exists so that external auditors, allocators, integrators, and journalists can read the deployment registry, run the live-protocol verification script, and check Kerne's published claims against on-chain state, without needing access to any private repo or any Kerne-controlled infrastructure.

> **Live mint path (current).** kUSD `MINTER_ROLE` is held today by exactly two contracts: **KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`** and the **live KUSDPSM `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803`** (redeployed 2026-07-10). `0xaBDE1138...9803` is the address users mint through today. Any PSM address other than that one returns `false` for `hasRole(MINTER_ROLE, ...)` on kUSD; see the key-rotation check in [`HOW_TO_VERIFY_KERNE.md`](HOW_TO_VERIFY_KERNE.md). The canonical live registry is [`deployments/8453.json`](deployments/8453.json).
>
> **2026-06-16 ceremony note.** The vault and mint PSM were redeployed and kUSD `MINTER_ROLE` was rerouted after this mirror's verification snapshot (2026-06-11/12). That ceremony moved minting to KUSDPSM v3 `0x07eBb486e11BD217e6085eb5ab663e4517595993` and KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B` (both source-verified on BaseScan and Sourcify, 2026-06-17). The KUSDPSM `0xFf3025ec...5Fbc` and KerneVault `0x8005bc7A...F2AC` rows below are the **pre-ceremony** deployment: the old PSM had `MINTER_ROLE` revoked and is retained only as the kUSD-to-USDC redeem reserve, and the v1 vault is retired (still the vault the Proof of Reserves attests until reserves migrate). The `contracts/KUSDPSM/` and `contracts/KerneVault/` source bundles below were refreshed on 2026-07-11 (verified byte-for-byte against Sourcify); the live verified source is also on BaseScan and Sourcify.
>
> **2026-07-03 skUSD redeploy.** The staked-kUSD vault was redeployed from the prepared source to reset a distorted share-price accounting state (the prior vault's shares had drifted far from par). The **live** skUSD is now **`0x96F5102C15b839757f811A98CEc3725Ac21DfA14`** (holds the staked kUSD, asset = kUSD; Sourcify-verified as a partial match 2026-07-04 and source-verified on BaseScan 2026-07-10 via the Etherscan v2 standard-json-input flow, compiler 0.8.24 with optimizer disabled, viaIR, cancun). The prior skUSD `0xdEd74F7E...09DB4` is retired (residual dust only) and recorded under `retired.skUSD_v1` in [`deployments/8453.json`](deployments/8453.json). The `contracts/skUSD/` source bundle was refreshed on 2026-07-11 to mirror this live deployment (verified byte-for-byte against Sourcify).
>
> **2026-07-10 PSM redeploy.** The mint PSM was redeployed to `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803` and kUSD `MINTER_ROLE` was revoked on KUSDPSM v3 `0x07eBb486...5993` the same day. KUSDPSM v3 no longer mints. It is retained redeem-only, and its USDC reserve still backs the kUSD that was minted through it until reserves migrate, which is why it still appears in the Proof of Reserves totals at [`kerne.fi/api/por`](https://kerne.fi/api/por). Both rows appear in the table below.

## What this repo is

- **`deployments/8453.json`** — the canonical address registry: every deployed contract, its address, type, and explorer link.
- **`scripts/verify_public_endpoints.sh`** — a zero-dependency-beyond-`curl`-and-`jq` script any outsider can run against the live protocol to assert that every public endpoint matches its published contract. Returns exit code 0 when healthy, 1 otherwise. The same script runs on Kerne's CI hourly.
- **`HOW_TO_VERIFY_KERNE.md`** — the full hostile-reader walkthrough: how to reproduce the APY formula, read the Proof-of-Reserves buckets with `cast call`, check the risk triggers, confirm PSM mint readiness, and verify the 2-of-3 Safe holds admin, all from public RPCs.
- **`docs/SEED_TVL_POLICY.md`** — the standing policy on seed TVL and off-chain accounting, including approaches considered and explicitly rejected.
- **`SECURITY.md`**, **`audits/`** — disclosure path and audit posture (Hexens engaged, initial report received July 20, 2026, remediation underway; reports published here as they land). Auditor scoping reference: [`audits/SCOPE.md`](audits/SCOPE.md). Deployed-vs-source state disclosure (where live bytecode differs from current source, with operating rules): [`audits/DEPLOYED_VS_SOURCE.md`](audits/DEPLOYED_VS_SOURCE.md).

## Where the contract source is

Every contract in the table below is source-verified on both BaseScan and Sourcify except KerneStaking and KerneFlashArbBot (disclosed below) and the live mint PSM, whose status postdates this snapshot and is marked as not re-checked rather than asserted. The live skUSD is a Sourcify partial match and was source-verified on BaseScan 2026-07-10 after its 2026-07-03 redeploy (see the note above). Per-contract status checked 2026-06-11 (Sourcify status via `sourcify.dev/server/v2/contract/8453/<address>`, BaseScan via each address's `#code` tab; the four formerly BaseScan-pending contracts were verified on BaseScan 2026-06-11 via the Etherscan v2 API using the Sourcify source bundles). KUSDPSM v3 and KerneVault v2 (deployed in the 2026-06-16 ceremony) were source-verified on BaseScan and Sourcify 2026-06-17; KUSDPSM v3 has since been retired from minting (see the 2026-07-10 note above) and the live mint PSM `0xaBDE1138...9803` has not been re-checked in this snapshot:

| Contract | Address | BaseScan | Sourcify |
|---|---|---|---|
| kUSD | `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3` | Verified | Verified (match) |
| skUSD (live) | `0x96F5102C15b839757f811A98CEc3725Ac21DfA14` | Verified | Verified (partial) |
| skUSD (v1, retired) | `0xdEd74F7E06efc76455C07418b8b74Cc2bc009DB4` | Verified | Verified (match) |
| KUSDPSM (live mint path, deployed 2026-07-10) | `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803` | Not re-checked in this snapshot | Not re-checked in this snapshot |
| KUSDPSM v3 (retired 2026-07-10, redeem-only reserve) | `0x07eBb486e11BD217e6085eb5ab663e4517595993` | Verified | Verified |
| KUSDPSM (v1, redeem reserve) | `0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc` | Verified | Verified (exact match) |
| KerneVault v2 (live) | `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B` | Verified | Verified |
| KerneVault (v1, retired) | `0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC` | Verified | Verified (match) |
| KERNE (v2) | `0x230f3a63E8413D42bEe9103b98a204030206186c` | Verified | Verified (match) |
| KERNE (v1, retired) | `0xfEA3D217F5f2304C8551dc9F5B5169F2c2d87340` | Verified | Verified (match) |
| esKERNE | `0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34` | Verified | Verified (exact match) |
| KerneStaking | `0x032Af1631671126A689614c0c957De774b45D582` | **Not verified** | **Not verified** |
| KerneTreasury | `0x7c07517ABcc4BD674CC74B76D2Ab0d95A41560d5` | Verified | Verified (exact match) |
| KerneInsuranceFund | `0xE8799FCF327C6D2f78103a3c9308C93592A30403` | Verified | Verified (exact match) |
| KerneReferral | `0x1A04AF62baFc84b08b19d2aF7285eD5f8dAe4D9f` | Verified | Verified (match) |
| KerneYieldDistributor | `0x096e38a04B632D28E017f86836225E0956CaD878` | Verified | Verified (match) |
| KerneYieldOracle | `0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB` | Verified | Verified (match) |
| KerneFlashArbBot | `0x57e73919Efc8a70B40a0bFc562C4DC9e58c4D76F` | **Not verified** | **Not verified** |

KERNE (v1) is retired and superseded by KERNE (v2); it remains source-verified and is listed for completeness (see the `retired` section of `deployments/8453.json`).

The live mint PSM `0xaBDE1138...9803` postdates this mirror's verification snapshot, so its explorer status is marked "not re-checked" above rather than asserted. Read it directly on BaseScan (`#code` tab) or via the Sourcify v2 API for the current status. The retired KUSDPSM v3 row stays in the table because its USDC reserve still backs kUSD minted through it.

The two unverified contracts, disclosed plainly:

- **KerneStaking** was deployed from source that predates a 2026-01-07 git-history reset; the deployed bytecode cannot be reproduced from any source tree we still hold (re-attempted 2026-06-11: current source compiles to a different code body, not a metadata-only difference). It will be re-deployed from verified source at the next contract ceremony.
- **KerneFlashArbBot** has source-vs-deployed drift (in-development fixes awaiting redeploy) and is queued for redeploy, after which it will be verified at deploy time.

Read the verified source per address:

- **In this repo:** [`contracts/`](contracts/README.md) mirrors the explorer-verified source bundle for each of the 11 active verified contracts (one bundle per deployed address, including compiler `metadata.json` and constructor args), pulled verbatim from Sourcify: the 2026-06-12 snapshot for most, with the skUSD, KUSDPSM v3, and KerneVault v2 bundles refreshed to their then-current redeployed source on 2026-07-11 (the KUSDPSM bundle mirrors v3 `0x07eBb486...5993`, which was the mint PSM until 2026-07-10 and is now the retired redeem-only instance; for the live PSM `0xaBDE1138...9803`, pull the source from the explorer for that address). Auditors: scoping reference with per-contract nSLOC at [`audits/SCOPE.md`](audits/SCOPE.md).
- BaseScan: `https://basescan.org/address/<address>#code`
- Sourcify: `https://repo.sourcify.dev/contracts/full_match/8453/<address>/` (or `partial_match` for "match"-tier entries)

A unified **forge-testable tree** (so you can `git clone && forge test` and diff bytecode locally from a single build) will be added at the next contract redeploy, when the in-development source and the deployed bytecode are realigned. Until then, the per-address bundles in `contracts/` and the explorers are the canonical, bytecode-matched reference, and the verification script + `HOW_TO_VERIFY_KERNE.md` cover the live-protocol claims end to end.

## What this repo is NOT

- **Not the bot.** The off-chain hedging engine, sentinel, capital router, and operational tooling are out of scope and are not published here.
- **Not the frontend.** The marketing site (kerne.fi) and terminal (app.kerne.fi) are separate.
- **Not always the latest in-development state.** This is a verification snapshot; for live state, read the contracts and endpoints directly.

## Quick start: verify the live protocol

```bash
# One-liner against the live protocol (read the script first if you prefer)
curl -sL https://raw.githubusercontent.com/kerne-protocol/contracts-public/main/scripts/verify_public_endpoints.sh | bash

# Or clone and run locally
git clone https://github.com/kerne-protocol/contracts-public
cd contracts-public
bash scripts/verify_public_endpoints.sh        # needs curl + jq
```

Exit code 0 means every documented public endpoint matched its contract. Exit code 1 names the check that failed.

## Verify a deployed contract's bytecode

```bash
# Example: KerneVault v2 (the live vault). Compare the explorer-verified source's
# compiled bytecode against the on-chain runtime bytecode.
cast code 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B --rpc-url https://mainnet.base.org
```

Cross-check the verified source and verification status on BaseScan (`#code` tab) or Sourcify for the address. Known source-vs-deployed drift (for contracts with in-development fixes awaiting a redeploy) is disclosed in the `gaps` array of [`kerne.fi/api/risk-status`](https://kerne.fi/api/risk-status).

## Reporting bugs

See [`SECURITY.md`](SECURITY.md). Do not open public issues for vulnerabilities. Bug bounty live at [kerne.fi/security](https://kerne.fi/security).

## License

MIT. See [`LICENSE`](LICENSE).
