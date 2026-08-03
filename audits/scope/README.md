# Audit scope: the source Hexens actually reviewed

The Hexens report names its scope as five contracts at commit
`0912c870a89f1fa707f69c60fc05c05ea85e2fa8`, and links each one to
`github.com/enerzy17/kerne-main`. **That repository is private, so those links return 404 for
every reader.** A report whose scope cannot be opened is a report you have to take on trust, which
is the opposite of the point.

This directory removes that problem. It publishes the exact source of both commits the report
names, so anyone can read what was reviewed, and diff it against what was changed afterwards,
without access to the private monorepo.

Nothing here is new code. It is the same bytes, at the same two commits, moved to a repository you
can open.

## The five scope files, and where each dead link now resolves

Every row was taken out of the private repository at the commit named in the report and written
here unmodified. The SHA-256 is of the file as published in this directory.

| Report scope link (404) | Published here | Bytes | SHA-256 |
|---|---|---|---|
| `.../kerne-main/blob/0912c870.../src/KerneVault.sol` | [`0912c870/src/KerneVault.sol`](0912c870/src/KerneVault.sol) | 129,521 | `243c554f3e11b4b6812d370d743d197b292a34b3a156c7b77440dfc55dd2adde` |
| `.../kerne-main/blob/0912c870.../src/kUSD.sol` | [`0912c870/src/kUSD.sol`](0912c870/src/kUSD.sol) | 5,275 | `dfc3339c1e4175006d2fedd6e532bb3fd7e221363021e829930eae1de894a4ca` |
| `.../kerne-main/blob/0912c870.../src/skUSD.sol` | [`0912c870/src/skUSD.sol`](0912c870/src/skUSD.sol) | 10,421 | `7a1c9a2d2a62989d1abfe23d58157894bef5217ca86ca89c480c9cf89eff50c4` |
| `.../kerne-main/blob/0912c870.../src/KUSDPSM.sol` | [`0912c870/src/KUSDPSM.sol`](0912c870/src/KUSDPSM.sol) | 45,019 | `013bd7e6fc2bcb5e780aaa5f924a905f3f63e88bee49d1bf3d832d7c963b99f9` |
| `.../kerne-main/blob/0912c870.../src/esKERNE.sol` | [`0912c870/src/esKERNE.sol`](0912c870/src/esKERNE.sol) | 32,694 | `c7d7f0cfea8c09e3021baa2b143f702f372f447f9ebe9c623876ed74c7424875` |

The report also links the remediation commit as a repository tree,
`.../kerne-main/tree/98f29e55...`, which 404s for the same reason. The same five files at that
commit are in [`98f29e55/`](98f29e55/).

Three interface files are included in each directory because the five contracts import them.
They are identical at both commits.

## Read this before you read the source

- **These are reference copies, not a build target.** `foundry.toml` sets `src = "contracts"`, so
  nothing in `audits/` is compiled by `forge build`. The buildable, testable mirror of the
  **deployed** contracts is [`../../contracts/`](../../contracts/), which is a different thing and
  the next bullet explains why.
- **None of this is the bytecode running on Base.** The live KerneVault was deployed on
  16 June 2026 from source that predates both commits below. So the audited source, the remediated
  source and the deployed source are three different versions of KerneVault, and the ten findings
  are open against the deployed one. That is stated at length, with the operating rules that bound
  it, in [`../DEPLOYED_VS_SOURCE.md`](../DEPLOYED_VS_SOURCE.md) and at
  [kerne.fi/security/deployed-vs-source](https://kerne.fi/security/deployed-vs-source). The vault
  holds no user funds, has never issued a share, and public deposits have been closed on chain
  since 30 July 2026.
- **Publishing the reviewed source discloses no mechanism the report did not.** All ten findings,
  their severities and their dispositions are already public in the report itself and at
  [kerne.fi/security/hexens-2026](https://kerne.fi/security/hexens-2026).

## What the two directories show when you diff them

`0912c870` is what Hexens reviewed. `98f29e55` is the same five files after the eight fixed
findings were addressed. Diffing them is the cheapest way to check the report's dispositions
against real code rather than against our summary of it.

Two things fall out of that diff, and both match what the report says:

1. **Only `KerneVault.sol` changes.** `kUSD.sol`, `KUSDPSM.sol` and `esKERNE.sol` are byte-identical
   at the two commits, and `skUSD.sol` is byte-identical at both commits and on chain. The report
   places all ten findings in `KerneVault.sol`, and the remediation touches nothing else.
2. **The vault change is 12 hunks, 120 lines added and 60 removed**, taking the file from 2,196 to
   2,256 lines. No function is added or removed; every fix is a change inside an existing one.

One caveat that must travel with point 1. "esKERNE drew no findings" is true as written, but both
High findings (KERNE1-4 and KERNE1-5) concern the **esKERNE forfeiture mechanism** and are filed
against the vault because that is where the code sits. Reading "esKERNE: zero findings" as "the
esKERNE design was unexamined" is the wrong conclusion.

Two of the ten were acknowledged rather than fixed, KERNE1-4 (High) and KERNE1-10 (Low), so they
are deliberately absent from the diff. Kerne's reasoning on both is in the report and at
[kerne.fi/insights/hexens-audit-every-finding-and-our-response](https://kerne.fi/insights/hexens-audit-every-finding-and-our-response).

## Verifying that these are the files the report reviewed

```sh
# Every file in this directory, hashed. Compare against the table above.
find audits/scope -name '*.sol' -exec sha256sum {} \;

# What the remediation actually changed.
diff -u audits/scope/0912c870/src/KerneVault.sol \
        audits/scope/98f29e55/src/KerneVault.sol
```

The report itself is [`../hexens-kerne-protocol-final-2026-07-31.pdf`](../hexens-kerne-protocol-final-2026-07-31.pdf),
SHA-256 `655e7126030c750e9d58f2ab30b58215ce604942f06997d5c01532d6f687a4ca`, and Hexens publishes it
on their own domain at
[hexens.io/audit-reports/kerne-protocol-july-2026](https://hexens.io/audit-reports/kerne-protocol-july-2026).
