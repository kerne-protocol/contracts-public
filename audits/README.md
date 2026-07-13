# Audits

This directory publishes external audit reports as they land. Each report is committed verbatim alongside the source version audited (commit hash), the date issued, and the protocol's response noting which findings were fixed and which were risk-accepted.

## Current status: audit underway (fieldwork began 2026-07-13)

As of the most recent commit, there is no published external audit. Kerne has engaged Hexens for its first external smart-contract audit (scope: kUSD, skUSD, KUSDPSM, KerneVault); fieldwork has been underway since 2026-07-13 and no report has been published yet. This README and directory will be updated while fieldwork runs and again when a report lands. Internal adversarial audit reports are published at [kerne.fi/security/audits](https://kerne.fi/security/audits).

The protocol's public bug bounty is live (see [`../SECURITY.md`](../SECURITY.md) and [kerne.fi/security](https://kerne.fi/security)).

## Independent researcher review, June 2026

Separate from the firm engagement above, a three-person independent security research team reviewed the deployed core contracts on their own initiative in June 2026 and submitted eight written findings. The anonymized summary and Kerne's full per-finding response are in [`INDEPENDENT_REVIEW_2026-06.md`](INDEPENDENT_REVIEW_2026-06.md). None of the eight is exploitable on the live deployment: four duplicate issues Kerne had already found and fixed, three are false positives against the deployed code, and one is a valid, currently-inert pre-launch item now fixed in source. A researcher-initiated review is not a firm audit, and the firm engagement above is still the item this directory is waiting on.

## Independent backing verification, July 2026

Distinct from the code reviews above: in July 2026 the independent stablecoin analyst TokenBrice, who maintains the [pharos.watch](https://pharos.watch) stablecoin transparency dashboard, verified Kerne's Peg Stability Module backing against the on-chain Base PSM balances and kUSD `totalSupply` before refreshing the kUSD figures on his dashboard. His own public commit records the check ([TokenBrice/pharos-watch@e0d62f31](https://github.com/TokenBrice/pharos-watch/commit/e0d62f31a6cf42db87d4da6aeeaba8ec754bc42e), closing [issue #468](https://github.com/TokenBrice/pharos-watch/issues/468)): about 1,115.85 USDC backing 1,114.737154 kUSD, roughly 100.10%. This is an independent verification of the reserves, not a code audit, and kUSD stays marked pre-active on pharos.watch pending an independent runtime price source. The same backing is reproducible from the hourly signed proof of reserves at [kerne.fi/verify](https://kerne.fi/verify).

Internal posture:

- An extensive Foundry test suite (900+ Solidity tests) covering happy paths, revert paths, edge cases, and role-gated access.
- Python (bot) and TypeScript (SDK) test suites, including a drift-guard suite that asserts every numeric threshold cited in `kerne.fi/docs/exit-triggers-and-emergency-runbook` matches the live constant in the bot's risk engine.

Once external reports are published here, this README will carry a table linking each report to the commit it audited and the protocol's response.
