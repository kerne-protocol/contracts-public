# Contributing

This is a read-only verification mirror. Pull requests that modify protocol logic, deployment records, or the verification script's target contracts will be closed without merge; canonical changes flow through Kerne's working repository.

PRs are welcome for these narrow categories:

- `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`: typo fixes and broken-link fixes.
- `HOW_TO_VERIFY_KERNE.md`: clarifications or additions to the verification walkthrough.
- `scripts/verify_public_endpoints.sh`: bug fixes that do not change which contract or endpoint is being verified.
- `audits/`: corrections or additions to published audit reports.

For anything else, please open an issue describing the change and a maintainer will route it through the canonical repo.

`main` requires signed commits, so a merge into it must be signed. You do not need to sign your own commits to open a PR: maintainers merge through GitHub, which signs the resulting merge commit. If you would like your individual commits to carry your own signature, GitHub's guide to [signing commits](https://docs.github.com/authentication/managing-commit-signature-verification/signing-commits) covers both SSH and GPG. See [`docs/COMMIT_SIGNING.md`](docs/COMMIT_SIGNING.md) for how the rule is configured here and how to verify it.

Secret scanning push protection is on for this repository, so a push carrying something that looks like a live credential is rejected before it lands. If that happens, remove the secret and rewrite the commit rather than asking for a bypass.

For security issues, do **not** open a public issue. Email kerne.systems@protonmail.com per [`SECURITY.md`](SECURITY.md).
