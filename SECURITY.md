# Security Policy

## Reporting a vulnerability

Email **kerne.systems@protonmail.com** with subject `Security Report: <brief description>`. This is the same disclosure path published at [kerne.fi/security](https://kerne.fi/security) and [kerne.fi/.well-known/security.txt](https://kerne.fi/.well-known/security.txt) (RFC 9116).

We acknowledge receipt within 48 hours and provide an initial assessment within 7 business days. The coordinated-disclosure window is 90 days from acknowledgement before any public discussion.

Bug-bounty rewards are at the protocol's discretion based on severity and impact (tiers: Critical, High, Medium, Low), payable in USDC, ETH, or other digital assets. Good-faith researchers acting under this policy receive safe-harbor treatment.

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

- **Audit underway.** The protocol has internal review and an extensive test suite (900+ Solidity tests plus Python and TypeScript suites), but no published external audit yet. Kerne has engaged Hexens for its first external audit; fieldwork has been underway since 2026-07-13 and reports will be published in [`audits/`](audits/) as they land.
- **Source-vs-deployed drift.** Several contracts have in-development fixes that are written and tested but not yet deployed (they ship at the next redeploy ceremony, which requires the 2-of-3 Safe). Drift between source and deployed bytecode is disclosed in the `gaps` array of [`kerne.fi/api/risk-status`](https://kerne.fi/api/risk-status). Read the deployed, explorer-verified source for the bytecode that is actually live.
- **Admin custody.** On-chain admin actions are gated by a 2-of-3 Gnosis Safe (`0x52d3E450bA6c299B1B07298F1E87DD74732D4877`). That protection is exactly as strong as the three signers' operational security.
- **Independent backing check.** In July 2026 the independent stablecoin analyst TokenBrice verified Kerne's PSM backing against on-chain Base balances and kUSD `totalSupply` (about 100.10%) and refreshed his [pharos.watch](https://pharos.watch) dashboard accordingly ([commit](https://github.com/TokenBrice/pharos-watch/commit/e0d62f31a6cf42db87d4da6aeeaba8ec754bc42e)). This is a reserves check, not a code audit; the same figure is reproducible any time from the hourly signed proof of reserves at [kerne.fi/verify](https://kerne.fi/verify).
