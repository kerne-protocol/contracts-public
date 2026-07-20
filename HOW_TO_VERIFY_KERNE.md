# How to Verify Kerne Yourself

**Last updated:** 2026-07-20
**Audience:** Auditors, allocators, journalists, integrators, researchers, anyone wanting to verify Kerne Protocol's published claims directly against the live system without trusting Kerne's own infrastructure.

> **Live mint path (current).** kUSD `MINTER_ROLE` is held today by exactly two contracts: **KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`** and the **live KUSDPSM `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803`** (redeployed 2026-07-10). `0xaBDE1138...9803` is the address users mint through today. Two earlier PSM instances are retained without minting rights: **KUSDPSM v3 `0x07eBb486e11BD217e6085eb5ab663e4517595993`** (`MINTER_ROLE` revoked 2026-07-10, redeem-only, its USDC reserve still backs the kUSD minted through it until reserves migrate) and **`0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc`** (`MINTER_ROLE` revoked in the 2026-06-16 ceremony, kUSD-to-USDC redeem reserve). The v1 vault `0x8005bc7A...F2AC` is the retired/legacy vault the Proof of Reserves currently attests. Section 4 below gives the `cast call` that proves this rotation for yourself.

This document is the canonical how-to. Every claim Kerne publishes about itself can be cross-checked from outside Kerne's tooling using public RPCs, public HTTPS endpoints, and standard CLI utilities. If you find a divergence between something Kerne claims and what these checks return, that is a bug in the protocol's transparency surface and we want to know about it (kerne.systems@protonmail.com, see `kerne.fi/security`).

---

## TL;DR: one-line verification

```bash
git clone https://github.com/kerne-protocol/contracts-public && cd contracts-public && bash scripts/verify_public_endpoints.sh
```

Or, without cloning the repo, against the live protocol directly:

```bash
curl -sL https://raw.githubusercontent.com/kerne-protocol/contracts-public/main/scripts/verify_public_endpoints.sh | bash
```

(If you would rather not pipe the internet to bash, read the script first or copy-paste the inlined checks below.)

The script hits every documented public endpoint on `kerne.fi` and `app.kerne.fi`, validates HTTP 200, and asserts the response shape matches the contract Kerne advertises. Exit code 0 means every check passed. Exit code 1 means at least one check failed and the per-check output names which one. A JSON summary is emitted on stderr for downstream monitoring.

Dependencies: `curl`, `jq`. Both standard on Ubuntu, macOS, and most Linux distros. Windows users can install jq via `winget install jqlang.jq`.

The same script runs on Kerne's own CI hourly and on every push to `main` (`.github/workflows/endpoint-smoke.yml`), so a broken endpoint surfaces in CI before it surfaces here.

---

## What you can verify, and how

### 1. Vault collateral composition (Proof of Reserves)

Kerne publishes a four-bucket composition of vault collateral at `/api/por`. Each bucket is independently verifiable with a single `cast call` so you do not need to trust Kerne's API.

```bash
# What Kerne reports (aggregate)
curl -s https://kerne.fi/api/por | jq '.reserves.vault'

# Each bucket, read directly from the contract.
# NOTE: this is the legacy v1 vault the Proof of Reserves currently attests; it is
# the address /api/por reads, so these calls must match that endpoint. The live
# deposit/mint vault is KerneVault v2 (0x8ccc56B5...292B), holding kUSD MINTER_ROLE.
VAULT=0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC
RPC=https://mainnet.base.org

cast call $VAULT "totalAssets()(uint256)"           --rpc-url $RPC
cast call $VAULT "offChainAssets()(uint256)"        --rpc-url $RPC
cast call $VAULT "l1Assets()(uint256)"              --rpc-url $RPC
cast call $VAULT "hedgingReserve()(uint256)"        --rpc-url $RPC
```

**The contract:** the four `cast call` results must sum to the `totalAssets()` reading on the same block. The `composition` object on `/api/por` must mirror the same four values. The current `offChainAssets` value should match the bot's most recent CEX hedge attestation. If `offChainAssets` is non-zero on the contract but absent or smaller in `/api/por`, that is a transparency bug.

The full policy (including approaches considered and rejected, e.g. inflated `offChainAssets` for "Ghost TVL" or "Institutional Partners" relabeling) is in [docs/SEED_TVL_POLICY.md](docs/SEED_TVL_POLICY.md).

### 2. Live APY methodology

Kerne publishes the displayed APY at `/api/apy`. The canonical endpoint `app.kerne.fi/api/apy` (which `kerne.fi/api/apy` proxies) carries a `methodology` string and a `sources` object that name every input, every deduction, and the **leverage the strategy is running this cycle**. You can replicate the whole computation yourself from free public data sources.

```bash
# Methodology string + every numeric input/output, including the live leverage:
curl -s https://app.kerne.fi/api/apy | jq '.methodology, .sources'

# The displayed number kerne.fi serves to the landing page:
curl -s https://kerne.fi/api/apy | jq '{expectedAPY, stakingYield, avgAnnualFunding}'
```

Live formula:

```
leverage       = sources.leverage          # read live; set by the strategy each cycle, NOT a hardcoded constant
grossAPY       = leverage × (liveStakingAPR + liveFundingAPR)
strategyNet    = grossAPY × (1 − STRATEGY_COST_FRACTION)
afterInsurance = strategyNet × (1 − INSURANCE_ALLOCATION_DEFAULT)
userAPY        = afterInsurance × (1 − PROTOCOL_FEE_GENESIS)
```

Terms:

- `leverage` is **published live in `sources.leverage`; this document does not assume a value, read the one the engine is actually running.** The strategy's design leverage is dynamic and funding-linked (target `clamp(1.5 + fundingAPR × 10, 1.5, 12.0)`, mirroring the hedge engine `bot/engine.py`: `MIN_LEVERAGE = 1.5`, `MAX_LEVERAGE = 12.0`), with 3.0 the ceiling it targets in a healthy bull-funding regime. Use whatever `sources.leverage` reports at the moment you check; do not hardcode 3.0 or any other constant.
- `STRATEGY_COST_FRACTION = 0.2232` (trading 6.08 + slippage 6.84 + gas 2.28 + margin 7.12 = 22.32%)
- `INSURANCE_ALLOCATION_DEFAULT = 0.10` (Dynamic Insurance Fund default; range 500-2500 bps)
- `PROTOCOL_FEE_GENESIS = 0.00` (Genesis phase, TVL < $100k)

Live inputs:

- `liveStakingAPR` from `https://eth-api.lido.fi/v1/protocol/steth/apr/sma`
- `liveFundingAPR` from Hyperliquid ETH perp `fundingHistory` endpoint, 180-day trailing mean

Reproduce:

```bash
LIDO=$(curl -s https://eth-api.lido.fi/v1/protocol/steth/apr/sma | jq -r '.data.smaApr')
echo "Lido SMA APR: $LIDO%"
# Pull the HL 180d funding window, take the mean, annualize (mean × 24 × 365).
# Read leverage from sources.leverage; the engine's dynamic target is min(12, max(1.5, 1.5 + fundingAPR × 10)).
```

Plug in the live leverage from `sources.leverage` rather than a hardcoded constant. If your computed `userAPY` differs from the `expectedAPY` on `app.kerne.fi/api/apy` by more than 0.5% on the same inputs, that is a methodology bug.

### 3. Risk triggers and exit policy

The chapter at `kerne.fi/docs/exit-triggers-and-emergency-runbook` cites every wired threshold by source identifier. The endpoint at `kerne.fi/api/risk-status` mirrors the same thresholds with their live values. The drift-guard test suite at `bot/tests/test_threshold_constants.py` asserts the chapter values equal the bot constants in CI.

```bash
# Live thresholds + drift-aware gaps
curl -s https://kerne.fi/api/risk-status | jq '{overall, gaps, summary, triggers: .triggers.onChain[:5]}'
```

The `gaps` array names every selector that reverts on the deployed bytecode. If a threshold the docs chapter names is not present in `/api/risk-status` and is not in `gaps`, that is a transparency bug. If a threshold IS in `gaps`, that means the docs chapter cites a value the deployed contract does not currently expose as a public getter (source-vs-deployed drift), and a contract redeploy is required to verify on-chain.

### 4. PSM mint readiness

Kerne's live mint PSM at `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803` (redeployed 2026-07-10) accepts USDC and mints kUSD. It holds kUSD `MINTER_ROLE`, and the readiness gates are public at `/api/psm-status`. Any caller can verify each gate independently.

```bash
PSM=0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803       # live mint PSM
OLD_PSM_V3=0x07eBb486e11BD217e6085eb5ab663e4517595993 # retired 2026-07-10, redeem-only
OLD_PSM_V1=0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc # retired 2026-06-16, redeem reserve
KUSD=0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
RPC=https://mainnet.base.org

cast call $PSM "mintingEnabled()(bool)"        --rpc-url $RPC
cast call $PSM "paused()(bool)"                --rpc-url $RPC
cast call $PSM "supportedStables(address)(bool)" $USDC --rpc-url $RPC
cast call $PSM "stableCaps(address)(uint256)"  $USDC --rpc-url $RPC
cast call $PSM "currentExposure(address)(uint256)" $USDC --rpc-url $RPC
```

Compare against `curl -s https://app.kerne.fi/api/psm-status | jq .gates`. Discrepancy = bug.

**Key-rotation proof.** The same `hasRole` call, run against all three PSM instances, shows that mint authority moved and that the retired instances cannot mint. Run all four:

```bash
MINTER=$(cast keccak "MINTER_ROLE")

cast call $KUSD "hasRole(bytes32,address)(bool)" $MINTER $PSM        --rpc-url $RPC  # expect true
cast call $KUSD "hasRole(bytes32,address)(bool)" $MINTER $OLD_PSM_V3 --rpc-url $RPC  # expect false
cast call $KUSD "hasRole(bytes32,address)(bool)" $MINTER $OLD_PSM_V1 --rpc-url $RPC  # expect false
# The only other MINTER_ROLE holder is KerneVault v2:
cast call $KUSD "hasRole(bytes32,address)(bool)" $MINTER 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B --rpc-url $RPC  # expect true
```

kUSD `MINTER_ROLE` is held today by exactly two contracts: KerneVault v2 and the live PSM above. Both retired PSM instances return `false` by design and a mint call against either reverts. If any of those four reads returns something other than the expected value, that is a bug and we want the report.

KUSDPSM v3 `0x07eBb486...5993` is nonetheless still a live-funds contract: it is retained as a redeem-only reserve, and its USDC balance still backs the kUSD that was minted through it until reserves migrate, which is why `/api/por` sums it into the backing total. Do not read its presence in the reserve total as evidence it can still mint.

### 5. Multisig governance

The 2-of-3 Safe at `0x52d3E450bA6c299B1B07298F1E87DD74732D4877` holds `DEFAULT_ADMIN_ROLE` on every Kerne contract. You can verify each role grant directly.

```bash
SAFE=0x52d3E450bA6c299B1B07298F1E87DD74732D4877
VAULT=0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B   # KerneVault v2 (live)
RPC=https://mainnet.base.org

# DEFAULT_ADMIN_ROLE is 0x00...00 (32 zero bytes)
cast call $VAULT "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 $SAFE --rpc-url $RPC
# Confirm Safe threshold and signer count
cast call $SAFE "getThreshold()(uint256)" --rpc-url $RPC
cast call $SAFE "getOwners()(address[])"  --rpc-url $RPC
```

Expected: `true`, `2`, and an array of 3 signer addresses.

### 6. Geographic restriction policy

Kerne blocks 20 OFAC-sanctioned jurisdictions via Vercel middleware. To verify, set the `x-vercel-ip-country` header to a sanctioned ISO code and check the response:

```bash
curl -sI -H 'x-vercel-ip-country: KP' https://kerne.fi | grep -i 'HTTP/'
# Expected: HTTP/2 451 (Unavailable for Legal Reasons)
```

Any ISO code in your local jurisdiction list that does NOT return 451 from this header probe is a misconfigured geo-block.

### 7. Source code and tests

The deployment registry (`deployments/8453.json`) and this verification tooling live in `github.com/kerne-protocol/contracts-public`. The exact source corresponding to each deployed contract's bytecode is verified on-chain; read it on the explorer's verified-source tab:

```bash
# Verified source for any deployed address (BaseScan "Contract" tab):
#   https://basescan.org/address/<address>#code
# Sourcify (perfect-match for several v2 contracts, incl. KerneToken v2,
# Treasury v2, Insurance Fund v2, skUSD):
#   https://repo.sourcify.dev/contracts/full_match/8453/<address>/

# Confirm the on-chain runtime bytecode for yourself (KerneVault v2, the live vault):
cast code 0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B --rpc-url https://mainnet.base.org
```

A full forge-testable source mirror (clone + `forge test` + local bytecode diff) will be added to this repository at the next contract redeploy, when the in-development source and the deployed bytecode are realigned. Known source-vs-deployed drift in the interim is disclosed in the `gaps` array of `kerne.fi/api/risk-status`. The extensive Foundry suite (900+ Solidity tests) plus the Python threshold-drift suite run in Kerne's CI on every push.

### 8. Audit posture

Kerne does not yet have a published external audit. Kerne has engaged Hexens for its first external smart-contract audit (scope: kUSD, skUSD, KUSDPSM, KerneVault). Fieldwork ran from July 13, 2026 and Hexens delivered its initial report on July 20, 2026, with remediation underway. The report is confidential while remediation runs, the final report is still pending, and the code is not yet through a completed external audit. The bug-bounty page at `kerne.fi/security` is live (RFC 9116 `security.txt` at `kerne.fi/.well-known/security.txt`). External reports will be published in the `kerne-protocol/contracts-public/audits/` directory once they land.

If you find a vulnerability, use the disclosure path on `kerne.fi/security`. If you find a transparency or claims bug, the same address works.

---

## What "verified" does NOT mean

Running this verification confirms that what Kerne claims about its own state matches what is on-chain and on its public endpoints at the moment you ran the check. It does NOT prove:

- That the strategy is profitable in the future. Past funding and staking yields do not guarantee future ones; see `/docs/risk-disclosures`.
- That the smart contracts are free of bugs. Pre-audit, you are reading source the team has tested but no third party has independently certified.
- That an off-chain venue (Hyperliquid, Binance, etc.) will remain solvent or accessible. Off-chain risk is real and itemized in the `triggers.offChain` array of `/api/risk-status`.
- That Kerne governance will not act maliciously. Only the 2-of-3 Safe gates on-chain admin actions, and that protection is exactly as strong as the three signers' opsec.

The verification above narrows the question to "are the published numbers honest right now?" That is a smaller question than "is Kerne safe?" but it is a necessary first step.

---

## Reporting verification failures

If `bash scripts/verify_public_endpoints.sh` returns a non-zero exit code, or if any of the `cast call` checks above contradicts what Kerne's API or docs claim, please report:

- Where the divergence is (endpoint, doc page, contract address)
- The exact values you observed and what you expected
- The block number / timestamp at which you observed it

Send to `kerne.systems@protonmail.com` with subject `Verification: <brief description>`. We treat verification reports the same as security reports under the disclosure policy at `kerne.fi/security`.

---

## Why this document exists

A stablecoin yield product earning double-digit APY has to answer three questions before users deposit:

1. Where does the yield come from?
2. What is backing the dollar?
3. What would force you to exit?

Every other answer is a marketing claim. This document is Kerne's answer to those questions in a form a hostile reader can verify in 30 seconds without trusting any Kerne-controlled infrastructure.

Trust is symmetric. We ask you to trust us with capital, so we owe you the rules we operate under in writing AND the verification path to prove we are following them. Run the script.
