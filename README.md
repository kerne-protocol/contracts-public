# Kerne Protocol Contracts (public mirror)

Public verification surface for [Kerne Protocol](https://kerne.fi), a delta-neutral synthetic dollar on Base mainnet (chain 8453). This repository exists so that external auditors, allocators, integrators, and journalists can read the deployment registry, run the live-protocol verification script, and check Kerne's published claims against on-chain state, without needing access to any private repo or any Kerne-controlled infrastructure.

## What this repo is

- **`deployments/8453.json`** — the canonical address registry: every deployed contract, its address, type, and explorer link.
- **`scripts/verify_public_endpoints.sh`** — a zero-dependency-beyond-`curl`-and-`jq` script any outsider can run against the live protocol to assert that every public endpoint matches its published contract. Returns exit code 0 when healthy, 1 otherwise. The same script runs on Kerne's CI hourly.
- **`HOW_TO_VERIFY_KERNE.md`** — the full hostile-reader walkthrough: how to reproduce the APY formula, read the Proof-of-Reserves buckets with `cast call`, check the risk triggers, confirm PSM mint readiness, and verify the 2-of-3 Safe holds admin, all from public RPCs.
- **`docs/SEED_TVL_POLICY.md`** — the standing policy on seed TVL and off-chain accounting, including approaches considered and explicitly rejected.
- **`SECURITY.md`**, **`audits/`** — disclosure path and audit posture (pre-audit; reports published here as they land).

## Where the contract source is

The deployed contracts are **source-verified on-chain**. The fastest way to read the exact source that corresponds to the deployed bytecode is the explorer's verified-source tab for each address in `deployments/8453.json`:

- BaseScan: `https://basescan.org/address/<address>#code`
- Sourcify (perfect-match for several v2 contracts incl. KerneToken v2, Treasury v2, Insurance Fund v2, skUSD): `https://repo.sourcify.dev/contracts/full_match/8453/<address>/`

A full **forge-testable source mirror** (so you can `git clone && forge test` and diff bytecode locally) will be added to this repo at the next contract redeploy, when the in-development source and the deployed bytecode are realigned. Until then, the explorer-verified source above is the canonical, bytecode-matched reference, and the verification script + `HOW_TO_VERIFY_KERNE.md` cover the live-protocol claims end to end.

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
# Example: KerneVault. Compare the explorer-verified source's compiled bytecode
# against the on-chain runtime bytecode.
cast code 0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC --rpc-url https://mainnet.base.org
```

Cross-check the verified source and verification status on BaseScan (`#code` tab) or Sourcify for the address. Known source-vs-deployed drift (for contracts with in-development fixes awaiting a redeploy) is disclosed in the `gaps` array of [`kerne.fi/api/risk-status`](https://kerne.fi/api/risk-status).

## Reporting bugs

See [`SECURITY.md`](SECURITY.md). Do not open public issues for vulnerabilities. Bug bounty live at [kerne.fi/security](https://kerne.fi/security).

## License

MIT. See [`LICENSE`](LICENSE).
