# Audits

This directory publishes external audit reports as they land. Each report is committed verbatim alongside the source version audited (commit hash), the date issued, and the protocol's response noting which findings were fixed and which were risk-accepted.

## Current status: pre-audit

As of the most recent commit, there is no published external audit. An audit-firm engagement is underway; this README and directory will be updated when a report lands.

The protocol's public bug bounty is live (see [`../SECURITY.md`](../SECURITY.md) and [kerne.fi/security](https://kerne.fi/security)).

Internal posture:

- An extensive Foundry test suite (900+ Solidity tests) covering happy paths, revert paths, edge cases, and role-gated access.
- Python (bot) and TypeScript (SDK) test suites, including a drift-guard suite that asserts every numeric threshold cited in `kerne.fi/docs/exit-triggers-and-emergency-runbook` matches the live constant in the bot's risk engine.

Once external reports are published here, this README will carry a table linking each report to the commit it audited and the protocol's response.
