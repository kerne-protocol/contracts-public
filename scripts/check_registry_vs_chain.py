#!/usr/bin/env python3
"""
check_registry_vs_chain.py

Assert that the deposit state this repository publishes is the deposit state on
Base right now.

WHY THIS EXISTS
---------------
The sibling check, scripts/check_mirror_freshness.sh, compares a date and a
count in one markdown file against the same two things on kerne.fi. It makes
zero on-chain calls. On 2026-08-06 that gap showed: deployments/8453.json still
said "verified on chain 2026-07-28: public WETH deposits are OPEN. maxDeposit
(any address) returns 2^256-1" nine days after a Safe transaction shut the door,
and the daily badge had been green throughout. Four other files in this same
repository said the opposite and were correct, so the badge was not even
catching a repo that contradicted itself.

A reader who follows this repository's own instructions catches that in one RPC
call. That is the whole proposition of the mirror, so the badge has to assert it
rather than decorate it.

WHAT IT ASSERTS
---------------
The four fields of contracts.KerneVault.depositState in deployments/8453.json,
against live Base:

    maxDeposit(address)   whitelistEnabled()   paused()   totalSupply()

That JSON object is the single source of truth. The prose in README.md,
audits/DEPLOYED_VS_SOURCE.md, SECURITY.md and HOW_TO_VERIFY_KERNE.md describes
it; test/fork/RegistryMatchesChain.t.sol reads the same object and asserts the
same facts from a fork. Change the door on chain without changing that object
and this fails within a day, IN EITHER DIRECTION. Reopening deposits and leaving
the registry saying they are shut fails exactly as loudly as the reverse.

FAILURE POLICY
--------------
Assertion failures are hard (exit 1). Network problems are not.

  - Fewer than QUORUM endpoints answer            -> exit 0, loud warning
  - The endpoints that answer disagree with each  -> exit 0, loud warning
    other (a reorg, or one node behind)
  - QUORUM endpoints agree and contradict the     -> exit 1
    registry

The two-provider quorum is deliberate and must not be lowered to one. A single
rotating public endpoint produced two false alarms during the 2026-08-03 custody
ceremony, and a check that cries wolf gets ignored, which costs more than the
run it saved. Equally, this must never conclude from one provider: the reason
for the quorum is that a wrong "all clear" is worse than no answer.

No API key, no toolchain, no dependency beyond the Python standard library.
Anyone can run it:

    python3 scripts/check_registry_vs_chain.py
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

REGISTRY = os.environ.get("REGISTRY_FILE", "deployments/8453.json")

# Public Base endpoints, no key required. More than the quorum on purpose, so a
# single outage is absorbed rather than reported.
ENDPOINTS = [
    "https://mainnet.base.org",
    "https://base-rpc.publicnode.com",
    "https://base.drpc.org",
    "https://1rpc.io/base",
]

QUORUM = int(os.environ.get("QUORUM", "2"))
RETRIES = int(os.environ.get("RETRIES", "3"))
TIMEOUT = int(os.environ.get("TIMEOUT", "20"))

# Selectors were computed with `cast sig` and each one was then CHECKED against
# the live vault before being written down. That second step is not ceremony: a
# plausible-looking wrong selector reverts or returns zero, and a checker built
# on one passes vacuously forever. whitelistEnabled() is 0x51fb012d; 0x81b25bbf
# looks just as reasonable and is not a function on this contract.
SEL_MAX_DEPOSIT = "0x402d267d"  # maxDeposit(address)
SEL_WHITELIST_ENABLED = "0x51fb012d"  # whitelistEnabled()
SEL_PAUSED = "0x5c975abb"  # paused()
SEL_TOTAL_SUPPLY = "0x18160ddd"  # totalSupply()

# The address maxDeposit is probed with, ABI-encoded and WITHOUT an 0x prefix,
# because it is concatenated onto a selector that already has one. Any address
# that is not whitelisted does; the question being asked is what a stranger can
# deposit, not what a privileged address can.
PROBE_ADDRESS = "0000000000000000000000000000000000000000000000000000000000000001"


class RequestRejected(RuntimeError):
    """The endpoint answered and refused the request.

    Distinct from a transport failure on purpose. An endpoint that is down is
    somebody else's outage and must not paint this repository red. An endpoint
    that says "invalid params" is telling us THIS SCRIPT is malformed, and
    retrying it on three more endpoints just collects the same answer four
    times and then exits 0 under the quorum rule.

    That is not hypothetical. The first run of this script concatenated a
    prefixed probe argument onto a prefixed selector, every endpoint correctly
    rejected it, and the run reported "0 of 4 endpoints answered" and exited 0.
    A checker that reports its own bugs as somebody else's outage is worth less
    than no checker, because it is trusted.
    """


def say(msg):
    print(msg, flush=True)


def warn(msg):
    print("WARN: %s" % msg, file=sys.stderr, flush=True)


def fail(msg):
    print("FAIL: %s" % msg, file=sys.stderr, flush=True)


def rpc(endpoint, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "content-type": "application/json",
            "user-agent": "kerne-registry-vs-chain-check",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        payload = json.load(resp)
    if "error" in payload:
        # -32700..-32600 are JSON-RPC's own "your request is malformed" band and
        # -32602 is "invalid params". Those are our fault, not the endpoint's.
        code = (payload["error"] or {}).get("code")
        if isinstance(code, int) and -32700 <= code <= -32600:
            raise RequestRejected("%s rejected by %s: %s" % (method, endpoint, payload["error"]))
        raise RuntimeError("%s returned %s" % (method, payload["error"]))
    if "result" not in payload:
        raise RuntimeError("%s returned no result" % method)
    return payload["result"]


def eth_call(endpoint, to, data):
    return rpc(endpoint, "eth_call", [{"to": to, "data": data}, "latest"])


def read_state(endpoint, vault):
    """Every field the registry publishes, from one endpoint, at one block.

    Block number is read FIRST and pinned into the result so that two endpoints
    disagreeing merely because one is a few blocks behind is visible as such.
    """
    block = int(rpc(endpoint, "eth_blockNumber", []), 16)
    max_deposit = int(eth_call(endpoint, vault, SEL_MAX_DEPOSIT + PROBE_ADDRESS), 16)
    whitelist = int(eth_call(endpoint, vault, SEL_WHITELIST_ENABLED), 16)
    paused = int(eth_call(endpoint, vault, SEL_PAUSED), 16)
    supply = int(eth_call(endpoint, vault, SEL_TOTAL_SUPPLY), 16)
    return {
        "block": block,
        "maxDepositAnyAddress": str(max_deposit),
        "whitelistEnabled": bool(whitelist),
        "paused": bool(paused),
        "totalSupply": str(supply),
    }


def comparable(state):
    """The state minus the block number, which legitimately differs per endpoint."""
    return {k: v for k, v in state.items() if k != "block"}


def main():
    if not os.path.isfile(REGISTRY):
        fail("%s not found (run from the repository root)" % REGISTRY)
        return 1

    with open(REGISTRY, encoding="utf-8") as fh:
        registry = json.load(fh)

    try:
        vault_entry = registry["contracts"]["KerneVault"]
        vault = vault_entry["address"]
        claimed = vault_entry["depositState"]
    except KeyError as exc:
        fail("%s has no contracts.KerneVault.depositState (missing key %s)" % (REGISTRY, exc))
        fail("that object is what this check asserts; it is not optional")
        return 1

    say("registry: %s" % REGISTRY)
    say("  vault              %s" % vault)
    say("  claims deposits    %s" % ("OPEN" if claimed["open"] else "SHUT"))
    say("  read at block      %s on %s" % (claimed.get("readAtBlock"), claimed.get("readOn")))

    answers = {}
    for endpoint in ENDPOINTS:
        for attempt in range(1, RETRIES + 1):
            try:
                answers[endpoint] = read_state(endpoint, vault)
                break
            except RequestRejected as exc:
                # Never retried, never soft-failed, never absorbed by the quorum
                # rule. This says the script is wrong, and a wrong script that
                # exits 0 is the thing this whole job exists to prevent.
                fail(str(exc))
                fail("that is a malformed request, not an outage. This script is broken;")
                fail("fix the selector or the encoding rather than the endpoint list.")
                return 1
            except (urllib.error.URLError, OSError, RuntimeError, ValueError) as exc:
                if attempt == RETRIES:
                    warn("%s unavailable after %d attempts (%s)" % (endpoint, RETRIES, exc))
                else:
                    time.sleep(attempt * 2)

    if len(answers) < QUORUM:
        warn("only %d of %d endpoints answered; %d are required." % (len(answers), len(ENDPOINTS), QUORUM))
        warn("refusing to conclude anything about chain state from fewer than %d." % QUORUM)
        warn("this is NOT a pass of the drift check, it is an absence of evidence.")
        return 0

    for endpoint, state in answers.items():
        say("chain: %s (block %d)" % (endpoint, state["block"]))
        for key in ("maxDepositAnyAddress", "whitelistEnabled", "paused", "totalSupply"):
            say("  %-22s %s" % (key, state[key]))

    shapes = {json.dumps(comparable(s), sort_keys=True) for s in answers.values()}
    if len(shapes) > 1:
        warn("the endpoints that answered do not agree with each other.")
        warn("that is a reorg or a node lagging, not a registry defect. Not failing.")
        for endpoint, state in answers.items():
            warn("  %s at block %d: %s" % (endpoint, state["block"], json.dumps(comparable(state), sort_keys=True)))
        return 0

    observed = comparable(next(iter(answers.values())))
    blocks = sorted(s["block"] for s in answers.values())

    mismatches = []
    for key, seen in observed.items():
        want = claimed.get(key)
        if want != seen:
            mismatches.append((key, want, seen))

    # `open` is derived rather than stored twice, so it cannot drift from the
    # number it summarises.
    derived_open = int(observed["maxDepositAnyAddress"]) > 0
    if bool(claimed.get("open")) != derived_open:
        mismatches.append(("open", claimed.get("open"), derived_open))

    if mismatches:
        fail("the registry and the chain disagree about the vault deposit state.")
        fail("%d endpoints agreed, at blocks %s." % (len(answers), blocks))
        for key, want, seen in mismatches:
            fail("  %-22s registry says %-12s chain says %s" % (key, want, seen))
        fail("")
        fail("Fix the CHAIN or fix the REGISTRY, in the same commit as whatever caused this.")
        fail("Update contracts.KerneVault.depositState in %s and the prose that" % REGISTRY)
        fail("describes it in README.md, audits/DEPLOYED_VS_SOURCE.md, SECURITY.md and")
        fail("HOW_TO_VERIFY_KERNE.md. Keep the correction history in the note; this file's")
        fail("value comes from showing its corrections, not from having never needed one.")
        return 1

    say("")
    say(
        "OK: %d endpoints agree (blocks %s) and live Base matches every field of"
        % (len(answers), blocks)
    )
    say("    contracts.KerneVault.depositState. Deposits are %s on chain and the" % ("OPEN" if derived_open else "SHUT"))
    say("    registry says so.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
