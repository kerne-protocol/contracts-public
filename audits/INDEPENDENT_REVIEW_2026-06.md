# Independent security review, June 2026

For reviewers, allocators, and audit firms. Published 2026-06-29. A plain-language version lives at [kerne.fi/security/audits](https://kerne.fi/security/audits).

In June 2026 a three-person independent security research team, working on their own initiative rather than under a paid engagement, reviewed Kerne's core contracts and sent a set of eight written findings to the protocol's disclosure inbox. This document records what they reviewed, how each finding was assessed against the live deployment, and what we did with it. It is a researcher-initiated review, not a completed third-party firm audit, and it is described as exactly that. The external firm engagement (Hexens, engaged; fieldwork begins 2026-07-13) is tracked separately in [`README.md`](README.md) and at [kerne.fi/security/audits](https://kerne.fi/security/audits).

We publish this for the same reason we publish [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md): a reader doing diligence should be able to see that independent eyes have looked at the code, read exactly what they found, and read our response, rather than take "it has been reviewed" on faith.

## What was reviewed

Eight findings against the deployed core: the WETH vault (ERC-4626) and the peg-stability module (PSM). The team reviewed a snapshot of the source. Each finding was then assessed against what is actually deployed on Base mainnet (chain 8453), not just against repository source, because the two can differ on a young protocol (see [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md)).

## How each finding was assessed

Three independent evidence layers per finding:

1. **Source reading** by separate triage and adversarial-review passes, the second instructed to overturn each ruling rather than confirm it.
2. **Live invariant proof.** The Foundry invariant suite for the vault: five invariants (solvency, share-price monotonicity, accounting consistency, solvency-ratio consistency, fee sanity), 512 runs by 65,536 calls each, zero reverts.
3. **Deployed-bytecode provenance.** Both live contracts are source-verified (partial match) on Sourcify and BaseScan, so every behavior described below is checkable against the bytecode that is actually live:
   - vault `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`
   - PSM `0x07eBb486e11BD217e6085eb5ab663e4517595993`

Public Base RPC reads confirm the live vault holds the WETH asset, has `totalSupply` zero, and reports the empty-vault solvency sentinel.

## Result

No finding is exploitable on the live deployment. Of the eight:

- **Four** describe real bug classes that were already identified and fixed in Kerne's own May to June 2026 internal audit cycle. The live, source-verified bytecode already carries the fix; the submitted proofs were written against a pre-fix snapshot and do not reproduce on deployed code.
- **Three** do not match the deployed code at all: the quoted vulnerable code is not what is live. They are false positives against the deployment.
- **One** is a genuine, currently-inert, pre-launch accounting item. It independently confirms a finding Kerne had already documented in its May 8 internal audit: in the vault's outflow path, on-chain tracked assets are decremented before the matching off-chain or bridged bucket is credited, so a deposit landing inside that reconciliation window could over-mint. It is inert on the live deployment because the vault is empty (any such operation reverts on checked-math underflow and there are no holders to dilute) and the deposit interface is not open. It is now fixed in source (atomic bucket crediting, plus a real on-chain deposit gate to replace interface-only gating), staged for the next vault redeployment, and treated as a pre-launch blocker. The fix is not yet on chain; its status will appear in [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md) and the findings tracker when it deploys.

## Per-finding summary

| # | Area | Assessment | Live-exploitable |
|---|---|---|---|
| 1 | Vault initialization and role control | Already fixed (duplicate of an internal finding); the live source carries the initialization guard and grants roles to explicit parameters | No |
| 2 | Vault privileged-transfer access control | False positive: the quoted self-authorization path does not exist in deployed code; the function is admin-role gated | No |
| 3 | Queued-withdrawal pricing | Already fixed: claims pay value recomputed at claim time, not a stored snapshot | No |
| 4 | Vault outflow accounting gap | Valid, currently inert, fixed in source, staged for redeploy (pre-launch blocker) | Theoretical only (inert at zero-state) |
| 5 | Flash-loan share inflation | False positive: the vault has no flash-loan path (removed February 2026) and the share price does not read raw balances | No |
| 6 | Withdrawal-limit enforcement | Already fixed: the limit is enforced on the live exit path | No |
| 7 | Solvency-ratio denominator | False positive: deployed code normalizes the denominator and gates the pause by role; the proof's assertions fail on live code | No |
| 8 | PSM unit handling and cap | Already fixed: deployed PSM accounts in stable units and binds the cap on the larger of exposure and balance | No |

The full per-finding reasoning, with the specific live source lines and the on-chain reads that confirm each ruling, is held in Kerne's internal triage record and was sent to the research team directly.

## What we did with it

- Acknowledged receipt within the disclosure window and committed to a written per-finding assessment.
- Sent the team the full per-finding assessment directly.
- Queued the one valid item, plus two minor pre-launch hardening notes the review surfaced (a claim-time re-check on the withdrawal breaker, and a value-based solvency denominator), into the pre-launch fix set. The primary item is fixed in source.
- Offered the researchers public credit. If they consent to be named, this document and the web summary will be updated to name them.

An independent team reaching four of the same conclusions Kerne had already reached, on its own, is a useful signal: it is evidence the internal audit cycle found the real issues. We would rather show that with the findings and our response attached than assert it.

## Related

- [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md): where deployed bytecode differs from current source.
- [`SCOPE.md`](SCOPE.md): contract scope for external audit.
- [`../SECURITY.md`](../SECURITY.md): disclosure policy and coordinated-disclosure window.
- [kerne.fi/security/audits](https://kerne.fi/security/audits): full security posture.
