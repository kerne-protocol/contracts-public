# Verified source mirror

Each directory here is the **explorer-verified source bundle for one deployed contract**, mirrored verbatim from [Sourcify](https://sourcify.dev) (`sourcify.dev/server/files/any/8453/<address>`) on 2026-06-12. These are the exact sources that match the deployed bytecode on Base mainnet, per address.

## Layout

```
contracts/<ContractName>/
  src/<Primary>.sol          the contract itself
  src/interfaces/...         project interfaces it imports
  lib/openzeppelin-.../...   dependency sources, pinned at deploy time
  metadata.json              compiler version + settings (bytecode-reproducible)
  constructor-args.txt       ABI-encoded constructor arguments
  creator-tx-hash.txt        deployment transaction
```

## How to read this mirror

- **Bundles are per-address snapshots at deploy time.** The same dependency file can appear in several bundles and may differ between them, because contracts were deployed from different commits. Do not treat `contracts/` as one unified source tree; each bundle is self-consistent against its own deployed bytecode.
- **Match tier per contract** (Sourcify "exact match" vs "match") is listed in the table in the [root README](../README.md). Both tiers are bytecode-verified; "exact match" additionally matches the metadata hash.
- **Not mirrored:** `KerneStaking` and `KerneFlashArbBot` (unverified, reasons disclosed plainly in the root README; both queued for redeploy-and-verify), and the retired `KERNE` v1 token (verified source remains readable on BaseScan/Sourcify).

## For auditors

Scoping reference with per-contract nSLOC: [`audits/SCOPE.md`](../audits/SCOPE.md).

To reproduce any bundle from the source of truth:

```bash
curl -s https://sourcify.dev/server/files/any/8453/<address> | jq -r '.files[].path'
```

Addresses are in [`deployments/8453.json`](../deployments/8453.json).
