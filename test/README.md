# The regression suite

Ten external security researchers have sent Kerne findings that turned out to be
real. This directory is their work, kept runnable.

Every file names the person who reported the finding, the date they reported it,
and what its status is today. Run `forge test` from the repository root; nothing
here needs a network, an API key or an environment file.

## Who is named, and who is not

Kerne lists a researcher publicly only after they have told us they want public
credit. That rule is set out on
[kerne.fi/security/acknowledgments](https://kerne.fi/security/acknowledgments) and
it governs this directory too. **Twelve researchers have confirmed public credit
on that wall, and ten of them are named in a test header here.** The other two
reported findings that have no test in this directory, which is a statement about
coverage and not about them. Counts updated 2026-08-14, when ParthaSarathi and
Abhinav Raj were added to the wall and to headers here.

Some findings covered here were also reported by researchers who have not
confirmed. Those files describe the finding and say plainly that a reporter exists
and is not named. That is not an oversight and it is not us keeping the credit:
if you reported one of these and would like your name on it, write to
kerne.systems@protonmail.com and it goes in.

If you are named here and would rather not be, the same address works and the
commit removing you needs no discussion.

## What may be published, and when

The second rule from the same page: a finding's mechanism is published only once
it is **no longer exploitable on the live contracts**, whether because the fix
shipped or because the surface was never reachable. Enough detail to verify a bug
is enough detail to use it.

A Foundry test is mechanism. So every test in this directory clears that bar
before it is written, and each file states which of the two reasons applies, with
the on-chain reading that supports it. Where a finding is live and unfixed, there
is no test here. There are findings in that category. They are held, their
reporters are credited privately, and they arrive here when they are closed.

This is why the suite is not a list of things Kerne got right. Several tests
assert that a defect **is** present in the deployed bytecode, because that is what
[`../audits/DEPLOYED_VS_SOURCE.md`](../audits/DEPLOYED_VS_SOURCE.md) already
discloses in prose. Those tests are named `test_KNOWN_...`. They are supposed to
pass today and to start failing on the day the remediated contracts are mirrored
here. **A failure in a `test_KNOWN_` case is good news.**

## Layout

| Directory | What it holds |
|---|---|
| `regressions/` | One file per externally reported finding |
| `disclosures/` | Three of the four standing divergences, as executable assertions. The skUSD row added 2026-08-14 is not covered here yet |
| `invariants/` | Properties that are fixed and live, kept from regressing |
| `fork/` | Opt-in checks of published claims against live Base state |
| `helpers/` | Mocks and the shared test base |

## The findings, and who reported them

| Finding | Reported by | Date | Status |
|---|---|---|---|
| Buyback slippage floor derived from a same-transaction pool quote | Dmitriy Filatov | 2026-07-14 | Fixed in source, not on chain. Unreachable: no inventory, no keeper, no venue |
| Denial of service in the yield oracle's multi-party consensus path | Gaurang Maheta, then @Olamdeen 2026-07-04 | 2026-05-16 | Fixed in source. The live oracle has never recorded an observation |
| Insurance-fund accounting gap on untracked injections | Kor_HaeTae | 2026-07-04 | Fixed in source. The vault half of the fix is live; the fund half is not, and the gap survives there. Fund is empty |
| Forfeiture-on-exit bypass on the escrowed-KERNE vesting path | SpokoDev (Yaroslav Hrydkovets) | 2026-06-23 | Fixed in source. Escrow never funded |
| Vesting-accounting review of the escrowed-KERNE path | Jay | 2026-06-24 | Fixed in source. Escrow never funded |
| Stale-quote handling in the mint flow | Ekankaar | 2026-06-25 | Fixed and live |
| Yield-oracle-to-vault linkage and the honesty of the displayed APY | Gaurang Maheta | 2026-06-16 | Addressed |
| Drift between documented and deployed state of retired components | reodkt (Deni Roni) | 2026-07-21 | Reviewed, accepted, repaired 2026-07-28 |

Two further researchers reported findings covered by files in this directory and
have not confirmed public credit, so they are described but not named: the
independent rediscovery of the CR-bucket circuit-breaker gap (2026-07-28) and the
mid-vest yield-sharing observation on skUSD (2026-07-28).

**Correction, 2026-08-14, on the oracle row.** Until today that row credited
@Olamdeen alone, from 2026-07-04. Gaurang Maheta reported the same defect on
2026-05-16, seven weeks earlier, and was missing from it. The order was
established from the disclosure mailbox on 2026-08-06 and the correction was
promised in writing to three researchers who had been told their reports were
duplicates. @Olamdeen's credit is unchanged: he found it independently and is
second on the timeline, not displaced from it. The full history is in the header
of
[`regressions/YieldOracleConsensusBrick.t.sol`](regressions/YieldOracleConsensusBrick.t.sol),
which also withdraws two claims that file used to make about the defect's reach.

**Correction, 2026-08-14, on the insurance-fund row.** That file used to assert
that the deployed vault had no `injectFromInsurance` entry point. It has one, and
it works when called; what is missing is the call, on the fund side. The old test
inferred absence from a failed low-level call, which is an inference a reverting
function satisfies just as well. See the header of
[`regressions/InsuranceFundUntrackedInjection.t.sol`](regressions/InsuranceFundUntrackedInjection.t.sol)
for both halves and the commands that reproduce them.

## Two traps, if you are adding a test

Both of these cost a real debugging round here, and neither announces itself.

**1. `vm.warp(block.timestamp + X)` twice in one function does not work.** This
project builds with `via_ir = true` to match how the bundles were verified, and
under viaIR solc may cache repeated `block.timestamp` reads, because on a real
chain the timestamp cannot change inside a transaction. `vm.warp` breaks that
assumption. The second warp then re-uses the first read and time does not advance,
silently. Extend
[`helpers/KerneTest.sol`](helpers/KerneTest.sol) and use `_startClock` and
`_advance` instead.

**2. `IERC20` is not one type here, it is eleven.** Each bundle vendors its own
OpenZeppelin tree, so `IERC20` imported from the canonical `lib/` copy will not
implicitly convert to the `IERC20` a given bundle's constructor expects. Import
the type from the same bundle as the contract under test, for example
`contracts/KerneVault/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol`.
That is the per-bundle isolation doing its job, not a misconfiguration.

One more, less subtle: `vm.prank` is consumed by the very next external call, and
`escrow.EMITTER_ROLE()` is an external call. Cache role ids and view results into
locals before pranking, or use `vm.startPrank`.

## Reporting something new

kerne.systems@protonmail.com, and please read
[`../SECURITY.md`](../SECURITY.md) first. Kerne does not run a paid bounty and is
explicit about what it can and cannot pay: see
[kerne.fi/security#reward-capacity](https://kerne.fi/security#reward-capacity),
which publishes the treasury balance, the block it was read at, and what is
currently owed to whom. Read it before you spend a weekend.
