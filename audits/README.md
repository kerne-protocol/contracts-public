# Audits

This directory publishes external audit reports as they land. Each report is committed verbatim alongside the source version audited (commit hash), the date issued, and the protocol's response noting which findings were fixed and which were risk-accepted.

## Current status: pre-audit

As of the most recent commit, there is no published external audit. Hexens has been selected for Kerne's first external smart-contract audit (scope: kUSD, skUSD, KUSDPSM, KerneVault); as of 2026-06-24 the engagement has not yet started and no report has been published. This README and directory will be updated when the engagement starts and again when a report lands. Internal adversarial audit reports are published at [kerne.fi/security/audits](https://kerne.fi/security/audits).

The protocol's public bug bounty is live (see [`../SECURITY.md`](../SECURITY.md) and [kerne.fi/security](https://kerne.fi/security)).

## Independent researcher review, June 2026

Separate from the firm engagement above, a three-person independent security research team reviewed the deployed core contracts on their own initiative in June 2026 and submitted eight written findings. The anonymized summary and Kerne's full per-finding response are in [`INDEPENDENT_REVIEW_2026-06.md`](INDEPENDENT_REVIEW_2026-06.md). None of the eight is exploitable on the live deployment: four duplicate issues Kerne had already found and fixed, three are false positives against the deployed code, and one is a valid, currently-inert pre-launch item now fixed in source. A researcher-initiated review is not a firm audit, and the firm engagement above is still the item this directory is waiting on.

Internal posture:

- An extensive Foundry test suite (900+ Solidity tests) covering happy paths, revert paths, edge cases, and role-gated access.
- Python (bot) and TypeScript (SDK) test suites, including a drift-guard suite that asserts every numeric threshold cited in `kerne.fi/docs/exit-triggers-and-emergency-runbook` matches the live constant in the bot's risk engine.

Once external reports are published here, this README will carry a table linking each report to the commit it audited and the protocol's response.
