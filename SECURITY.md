# Security Policy

## Reporting a vulnerability

Email **kerne.systems@protonmail.com** with subject `Security Report: <brief description>`. This is the same disclosure path published at [kerne.fi/security](https://kerne.fi/security) and [kerne.fi/.well-known/security.txt](https://kerne.fi/.well-known/security.txt) (RFC 9116).

We acknowledge receipt within 48 hours and provide an initial assessment within 7 business days. The coordinated-disclosure window is 90 days from acknowledgement before any public discussion.

Good-faith researchers acting under this policy receive safe-harbor treatment.

**On rewards, before you spend hours on a report.** Kerne may offer a discretionary reward for a valid, previously unknown vulnerability, prioritising critical findings. This policy creates no contractual obligation and no reward is offered or implied for a report submitted today. As of July 29, 2026 the total dollar balance across every account Kerne controls is $29.52, and there are already 1,250 USDC of unpaid reward commitments ahead of you. The current figure and the full disclosure are at [kerne.fi/security#reward-capacity](https://kerne.fi/security#reward-capacity), which is the authoritative version of this paragraph. The work is genuinely wanted. The money is not there yet, and you should know that first.

## Scope

In scope:

- The deployed smart contracts on Base mainnet at the addresses in [`deployments/8453.json`](deployments/8453.json).
- The web interfaces at `kerne.fi` and `app.kerne.fi`.
- Public API endpoints: `/api/health`, `/api/por`, `/api/risk-status`, `/api/apy`, `/api/stats`, and `/api/psm-status`.
- Transparency claims: a number cited in `kerne.fi/docs` or on a public endpoint that does not match the live contract is a transparency bug and is in scope.

Out of scope:

- Third-party services Kerne integrates with (Hyperliquid, Lido, Aerodrome, Vercel, Alchemy).
- Issues requiring physical access to operator devices.
- Denial-of-service against the marketing site.
- Issues already publicly disclosed at the time of report.

## Known posture and caveats

- **First external audit completed, and the report is published here in full.** Hexens reviewed five contracts (`kUSD`, `skUSD`, `KUSDPSM`, `KerneVault`, `esKERNE`) at commit `0912c870`; fieldwork ran from July 13, 2026 and the final report published on July 31, 2026. Ten findings: 0 critical, 2 high, 2 medium, 4 low, 2 informational, of which eight were fixed and two acknowledged. All ten are in `KerneVault.sol`. The report is [`audits/hexens-kerne-protocol-final-2026-07-31.pdf`](audits/hexens-kerne-protocol-final-2026-07-31.pdf) and the per-finding response is at [kerne.fi/insights/hexens-audit-every-finding-and-our-response](https://kerne.fi/insights/hexens-audit-every-finding-and-our-response). **An audit reviews a commit, not a chain:** the live KerneVault runs earlier bytecode than the reviewed commit, so the vault findings are open against it, which is why public deposits are closed on chain. See [`audits/README.md`](audits/README.md) and [`audits/DEPLOYED_VS_SOURCE.md`](audits/DEPLOYED_VS_SOURCE.md).
- **Test evidence: 69 tests you can run, and a larger private suite you cannot.** This repository carries 69 tests across 14 suites, and those are the ones that count as evidence for a reader, because a clean checkout reproduces them in two commands with no RPC endpoint, API key, or environment file:

  ```
  git clone --recurse-submodules https://github.com/kerne-protocol/contracts-public
  cd contracts-public && forge test
  ```

  CI runs that same suite on every push. Kerne's private monorepo carries a much larger suite, measured at 2,516 Solidity test functions across 137 test files on July 31, 2026, plus Python (bot) and TypeScript (SDK) suites. Nobody outside Kerne can execute that number, so read it as a statement about our internal process and read the 69 as the evidence. Earlier revisions of this file cited "900+ Solidity tests" without saying which of them an outside reader could run; that figure was real and, as it turns out, conservative, but it was not checkable, which is the part that mattered.
- **Source-vs-deployed drift.** Several contracts have in-development fixes that are written and tested but not yet deployed (they ship at the next redeploy ceremony, which requires the 2-of-3 Safe). Drift between source and deployed bytecode is disclosed in the `gaps` array of [`kerne.fi/api/risk-status`](https://kerne.fi/api/risk-status). Read the deployed, explorer-verified source for the bytecode that is actually live.
- **Admin custody.** On-chain admin actions are gated by a 2-of-3 Gnosis Safe (`0x52d3E450bA6c299B1B07298F1E87DD74732D4877`). That protection is exactly as strong as the three signers' operational security.
- **Independent backing check.** In July 2026 the independent stablecoin analyst TokenBrice verified Kerne's PSM backing against on-chain Base balances and kUSD `totalSupply` (about 100.10%) and refreshed his [pharos.watch](https://pharos.watch) dashboard accordingly ([commit](https://github.com/TokenBrice/pharos-watch/commit/e0d62f31a6cf42db87d4da6aeeaba8ec754bc42e)). This is a reserves check, not a code audit; the same figure is reproducible any time from the hourly signed proof of reserves at [kerne.fi/verify](https://kerne.fi/verify).
