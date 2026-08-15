# Audits

This directory publishes external audit reports as they land. Each report is committed verbatim alongside the source version audited (commit hash), the date issued, and the protocol's response noting which findings were fixed and which were acknowledged.

## Current status: first external audit completed, final report published

**[Hexens, Security Review Report for Kerne Protocol, final report dated 31 July 2026.](hexens-kerne-protocol-final-2026-07-31.pdf)**

| | |
|---|---|
| Reviewer | [Hexens](https://hexens.io), lead security researcher Trung Dinh |
| Report | [`hexens-kerne-protocol-final-2026-07-31.pdf`](hexens-kerne-protocol-final-2026-07-31.pdf) (29 pages, 8,269,537 bytes) |
| Published by the auditor | [hexens.io/audit-reports/kerne-protocol-july-2026](https://hexens.io/audit-reports/kerne-protocol-july-2026), the same review hosted by Hexens rather than by Kerne |
| SHA-256 | `655e7126030c750e9d58f2ab30b58215ce604942f06997d5c01532d6f687a4ca` |
| Commit reviewed | `0912c870a89f1fa707f69c60fc05c05ea85e2fa8`, frozen before fieldwork began |
| Scope | five contracts: `kUSD.sol`, `skUSD.sol`, `KUSDPSM.sol`, `KerneVault.sol`, `esKERNE.sol`, published verbatim in [`scope/`](scope/) |
| Fieldwork | 13 July 2026 to 20 July 2026 (initial report), revision received 21 July 2026, final report 31 July 2026 |
| Remediation commit | `98f29e55e587ea81d18e61a5ec2061b8a23287f4`, also published in [`scope/`](scope/) |

The report's own Scope section links those five files on `github.com/enerzy17/kerne-main`, which is
private, so every one of those links returns 404. [`scope/`](scope/) republishes the exact source of
both commits, with per-file SHA-256, so the reviewed code can be read and the remediation diffed
without access to the private repository.

### Findings, as counted by the report itself

| Severity | Findings |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 2 |
| Low | 4 |
| Informational | 2 |
| **Total** | **10** |

Eight were fixed and two were acknowledged without a code change. Every one of the ten is in `KerneVault.sol`. `kUSD.sol`, `skUSD.sol`, `KUSDPSM.sol` and `esKERNE.sol` drew no findings between them.

| ID | Title | Severity | Disposition |
|---|---|---|---|
| KERNE1-4 | Transferable kLP shares can separate withdrawal and esKERNE forfeiture identities | High | Acknowledged |
| KERNE1-5 | esKERNE forfeiture can be bypassed by gas-starving the best-effort forfeit call | High | Fixed |
| KERNE1-7 | `totalAssets` silently under-reports NAV when the verification node call fails | Medium | Fixed |
| KERNE1-9 | `_checkCRCircuitBreaker` should be applied to `captureFounderWealth` | Medium | Fixed |
| KERNE1-2 | Unable to update `offChainAssets` when `offChainAssets == 0` and `_offChainAssetsBootstrapped == true` | Low | Fixed |
| KERNE1-3 | `maxTotalAssets` check overestimates deposited assets | Low | Fixed |
| KERNE1-10 | `_checkCRCircuitBreaker` should pause the protocol when the collateral ratio exceeds `SAFE_CR_THRESHOLD` | Low | Acknowledged |
| KERNE1-11 | Withdrawal requests are not bound to the share price at request time | Low | Fixed |
| KERNE1-6 | Redundant `_checkSolvency()` function in KerneVault | Informational | Fixed |
| KERNE1-8 | Redundant extracted variable in `captureFounderWealth` | Informational | Fixed |

Kerne's response to every finding, including the reasoning on the two acknowledged rather than changed, is at [kerne.fi/insights/hexens-audit-every-finding-and-our-response](https://kerne.fi/insights/hexens-audit-every-finding-and-our-response). The client commentary on both acknowledged findings is reproduced verbatim inside the report itself.

### What this report does not say

Read this part before you read the table above.

- **An audit reviews a commit, not a chain.** The reviewed commit is `0912c870`. The remediation commit is `98f29e55`. **Neither is the bytecode running in the live KerneVault**, which was deployed on 16 June 2026 from earlier source. The vault findings above are therefore open against the live vault. That vault holds no user funds and has never issued a share, public deposits are closed on chain as of 30 July 2026, and no deposit reopens until a remediated build is deployed and verified. The full map is in [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md) and at [kerne.fi/security/deployed-vs-source](https://kerne.fi/security/deployed-vs-source).
- A completed audit is not a guarantee of safety, and this one does not cover the off-chain hedge leg, which runs on a single venue and is self-reported.
- Two findings were acknowledged, not fixed. They are listed above with the same weight as the eight that were fixed, and the report carries Kerne's written reasoning on both.

## Independent researcher review, June 2026

Separate from the firm engagement above, a three-person independent security research team reviewed the deployed core contracts on their own initiative in June 2026 and submitted eight written findings. The anonymized summary and Kerne's full per-finding response are in [`INDEPENDENT_REVIEW_2026-06.md`](INDEPENDENT_REVIEW_2026-06.md). None of the eight is exploitable on the live deployment: four duplicate issues Kerne had already found and fixed, three are false positives against the deployed code, and one is a valid, currently-inert pre-launch item now fixed in source. A researcher-initiated review is not a firm audit.

## Independent backing verification, July 2026

Distinct from the code reviews above: in July 2026 the independent stablecoin analyst TokenBrice, who maintains the [pharos.watch](https://pharos.watch) stablecoin transparency dashboard, verified Kerne's Peg Stability Module backing against the on-chain Base PSM balances and kUSD `totalSupply` before refreshing the kUSD figures on his dashboard. His own public commit records the check ([TokenBrice/pharos-watch@e0d62f31](https://github.com/TokenBrice/pharos-watch/commit/e0d62f31a6cf42db87d4da6aeeaba8ec754bc42e), closing [issue #468](https://github.com/TokenBrice/pharos-watch/issues/468)): about 1,115.85 USDC backing 1,114.737154 kUSD, roughly 100.10%. This is an independent verification of the reserves, not a code audit, and kUSD stays marked pre-active on pharos.watch pending an independent runtime price source. The same backing is reproducible from the hourly signed proof of reserves at [kerne.fi/verify](https://kerne.fi/verify).

Internal posture:

- 82 tests across 15 suites in this repository, reproducible from a clean checkout in two commands, plus a much larger private Foundry suite covering happy paths, revert paths, edge cases, and role-gated access.
- Python (bot) and TypeScript (SDK) test suites, including a drift-guard suite that asserts every numeric threshold cited in `kerne.fi/docs/exit-triggers-and-emergency-runbook` matches the live constant in the bot's risk engine.

The protocol's public bug bounty is live (see [`../SECURITY.md`](../SECURITY.md) and [kerne.fi/security](https://kerne.fi/security)). Internal adversarial audit reports are published at [kerne.fi/security/audits](https://kerne.fi/security/audits).
