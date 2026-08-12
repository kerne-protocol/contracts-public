# Commit signing and provenance

**Last updated:** 2026-08-12
**Audience:** anyone who treats this repository as a source of truth for Kerne's contract addresses, and would like that trust to rest on something better than "the account was probably not compromised."

[`deployments/8453.json`](../deployments/8453.json) is the canonical public address registry for Kerne Protocol. It is the file DefiLlama's kUSD entry points at, and it is what an integrator following this repository will read to learn which address is the live mint PSM. Repointing one address in that file is the single highest-leverage edit anybody could make to Kerne's public surface, and until 2026-08-12 nothing in this repository would have distinguished such an edit from a legitimate one.

Two things changed on 2026-08-12:

1. Every commit on `main` from that date forward is signed with an SSH key.
2. `main` is configured to reject any push containing an unsigned commit, including pushes from repository administrators.

The rest of this document is how you check both claims without taking our word for either.

---

## 1. The fastest check

GitHub renders a **Verified** badge next to signed commits. Read it from the API rather than the page, so you get the reason string too:

```bash
curl -s https://api.github.com/repos/kerne-protocol/contracts-public/commits/main \
  | jq '.commit.verification'
```

A signed commit returns `"verified": true` with `"reason": "valid"`. An unsigned one returns `"verified": false, "reason": "unsigned"`.

To see the whole recent history at once:

```bash
curl -s "https://api.github.com/repos/kerne-protocol/contracts-public/commits?per_page=30" \
  | jq -r '.[] | "\(.sha[0:8])  \(.commit.verification.verified)  \(.commit.message | split("\n")[0])"'
```

This check asks GitHub whether GitHub believes the signature. That is a real check, but it trusts GitHub. Section 2 does not.

## 2. Verify locally, without trusting GitHub

This repository ships the public half of the signing key at [`docs/allowed_signers`](allowed_signers), in OpenSSH's `allowed_signers` format. Point git at it and verify directly:

```bash
git clone https://github.com/kerne-protocol/contracts-public
cd contracts-public

git -c gpg.ssh.allowedSignersFile=docs/allowed_signers verify-commit HEAD
```

Expected output, with a non-zero exit code if anything is wrong:

```
Good "git" signature for kerne.systems@protonmail.com with ED25519 key SHA256:8CT6w3pVOQn2TnP3l5vVoChMOvePDpeYcfbU3R2iQT4
```

To check every commit since signing began, rather than only the tip:

```bash
git -c gpg.ssh.allowedSignersFile=docs/allowed_signers \
  log --format='%G? %h %s' 32f4273d393bf40737b994110f98e0f383518198..main
```

Every line must begin with `G` (good signature). `N` means no signature, `B` means bad, `U` means good signature from an untrusted key. Anything other than `G` in that range is a finding, and we would like to hear about it at kerne.systems@protonmail.com.

To check only the file that actually matters:

```bash
git -c gpg.ssh.allowedSignersFile=docs/allowed_signers \
  log --format='%G? %h %an %s' -- deployments/8453.json
```

## 3. The obvious objection, answered

**"The key is published in the same repository as the commits it signs, by the same person. An attacker who can rewrite the registry can rewrite `allowed_signers` too."**

Correct, and worth stating rather than glossing. `docs/allowed_signers` is a convenience for offline verification, not a root of trust. The root of trust is that the private key is held outside GitHub and is registered as a signing key on the GitHub account, so:

- An attacker with the GitHub account's session or token, but without the signing key, can push, and every commit they push is unsigned. Branch protection rejects those pushes outright, and if protection were also disabled, the missing signature is still visible in section 1's output and in the on-page badge.
- An attacker who swaps `docs/allowed_signers` for their own key must do it in a commit, and that commit is subject to the same two checks. It would appear as either an unsigned commit or a signature from a key whose fingerprint is not `SHA256:8CT6w3pVOQn2TnP3l5vVoChMOvePDpeYcfbU3R2iQT4`.

So pin the fingerprint, not the file. It is published here, in this document, and in the commit that introduced it. If you are integrating against this registry and want a stronger anchor than that, record the fingerprint out of band when you first read it and compare on each pull.

## 4. What is NOT signed, stated plainly

**Every commit up to and including `32f4273d393bf40737b994110f98e0f383518198` is unsigned.** That is the entire history of this repository before 2026-08-12, including the commits that established the registry, published the Hexens report, and made the mirror buildable.

We did not backfill signatures over that history, and we are not going to. Backfilling means rewriting every commit, which would change every commit hash in this repository, break every permalink and every audit reference that points at one, and produce signatures asserting that commits were signed at times when no signing key existed. An unsigned history that is labelled unsigned is worth more than a rewritten one that looks better.

The boundary is therefore a real boundary. Provenance claims in this document apply forward from `32f4273d`, and to nothing before it.

Also not covered:

- **Tags.** Tag signing is enabled in the repository configuration, but this repository currently carries no tags, so there is nothing to verify.
- **The contract source bundles under `contracts/`.** Their provenance is Sourcify and BaseScan, not this repository's git history. Verify those against the explorers as described in [`HOW_TO_VERIFY_KERNE.md`](../HOW_TO_VERIFY_KERNE.md), not against a commit signature.
- **The private monorepo.** Nothing here says anything about commit provenance in Kerne's working repository.

## 5. Branch protection

`main` carries a protection rule requiring signed commits, applied to administrators as well. You can read the enforced configuration yourself:

```bash
curl -s https://api.github.com/repos/kerne-protocol/contracts-public/branches/main/protection/required_signatures \
  -H "Accept: application/vnd.github+json"
```

The public `branches` listing also reports the branch as protected:

```bash
curl -s https://api.github.com/repos/kerne-protocol/contracts-public/branches | jq '.[] | {name, protected}'
```

Note the limit of what this proves: branch protection is a GitHub-side control, and the account that can push is also the account that can remove it. It raises the cost of a silent registry rewrite, and it makes an attempted one leave marks. It does not make one impossible.

## 6. For maintainers: signing configuration

The key is an Ed25519 SSH key used only for signing, registered on GitHub as a **signing key** rather than an authentication key. Those are two separate lists in GitHub's settings and a key registered in the wrong one produces valid local signatures that GitHub reports as unverified, with no error anywhere to explain why.

Per-clone configuration:

```bash
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519_kerne_signing
git config commit.gpgsign true
git config tag.gpgsign true
git config gpg.ssh.allowedSignersFile docs/allowed_signers
```

The committer email must be an email address verified on the GitHub account holding the signing key, or GitHub reports `unverified_email` and shows no badge even though the signature itself is perfectly good. Commits here use the neutral `Kerne Protocol <kerne.systems@protonmail.com>` author identity, which is the established convention for this repository's public surface, and a GitHub-routable committer identity so the badge resolves.

**Key handling.** The private key exists on one workstation and is not escrowed. If it is lost, no history becomes invalid and nothing already published stops verifying; the consequence is that new commits cannot be signed until a replacement key is generated, registered on GitHub as a signing key, and added to `docs/allowed_signers`. Do that as an ordinary signed-then-unsigned transition: register the new key first, then rotate, then remove the old key only after the last commit signed with it is no longer the tip. Leave the retired key's line in `docs/allowed_signers` permanently, since removing it would make previously valid history stop verifying.

If branch protection ever blocks a legitimate push because signing is misconfigured on a fresh clone, the fix is the config block above, not disabling the rule.
