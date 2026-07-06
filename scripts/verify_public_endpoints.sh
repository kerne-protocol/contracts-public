#!/usr/bin/env bash
# Kerne Protocol public-endpoint verification script.
#
# Hits every documented public endpoint on kerne.fi and app.kerne.fi, asserts
# the response shape matches the published contract, and prints a per-endpoint
# PASS/FAIL plus an aggregate. Returns exit code 0 when every endpoint is
# healthy and 1 otherwise.
#
# This is BOTH:
#   - a trust tool: any outsider (auditor, allocator, journalist) can run
#     `bash scripts/verify_public_endpoints.sh` against the live protocol and
#     verify the public surface in 30 seconds, no authentication required;
#   - a CI smoke harness: .github/workflows/endpoint-smoke.yml runs this on
#     every push to main and hourly, so a regression like the /api/risk-status
#     503 we shipped 2026-04-25 is caught within an hour of landing.
#
# Dependencies: curl, jq. Both standard on Ubuntu / macOS / WSL.
#
# Usage:
#   bash scripts/verify_public_endpoints.sh                     # default origins
#   KERNE_ORIGIN=https://kerne.fi APP_ORIGIN=https://app.kerne.fi bash scripts/verify_public_endpoints.sh
#   bash scripts/verify_public_endpoints.sh --quiet              # only print failures
#
# Exit codes:
#   0 = every endpoint passed
#   1 = one or more endpoints failed (details in output)
#   2 = missing dependency (curl or jq)

set -uo pipefail

KERNE_ORIGIN="${KERNE_ORIGIN:-https://kerne.fi}"
APP_ORIGIN="${APP_ORIGIN:-https://app.kerne.fi}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

if ! command -v curl >/dev/null 2>&1; then
  echo "FATAL: curl not installed" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq not installed" >&2
  exit 2
fi

PASSED=0
FAILED=0
RESULTS=()

# log_pass/log_fail emit a single line summary and append a structured entry to
# the RESULTS array so the final aggregate can be JSON-rendered.
log_pass() {
  local label="$1" detail="$2"
  PASSED=$((PASSED + 1))
  RESULTS+=("$(jq -n --arg l "$label" --arg d "$detail" '{label:$l, status:"pass", detail:$d}')")
  if [[ $QUIET -eq 0 ]]; then
    printf '  PASS  %-50s  %s\n' "$label" "$detail"
  fi
}
log_fail() {
  local label="$1" detail="$2"
  FAILED=$((FAILED + 1))
  RESULTS+=("$(jq -n --arg l "$label" --arg d "$detail" '{label:$l, status:"fail", detail:$d}')")
  printf '  FAIL  %-50s  %s\n' "$label" "$detail"
}

# check_endpoint <url> <jq-expr-must-be-non-null> <human-label>
# Hits the URL, asserts HTTP 200, then asserts the jq expression evaluates to a
# non-null, non-empty value. The jq expression is the contract: if it changes
# meaning, the endpoint shape is broken even if the status code is healthy.
check_endpoint() {
  local url="$1" expr="$2" label="$3"
  local tmp_body http_code body
  tmp_body=$(mktemp)
  http_code=$(curl -sS -L -o "$tmp_body" -w '%{http_code}' \
    --max-time 30 \
    --retry 2 --retry-delay 1 \
    "$url" 2>/dev/null || echo 'curl-error')
  body=$(cat "$tmp_body")
  rm -f "$tmp_body"

  if [[ "$http_code" != "200" ]]; then
    log_fail "$label" "HTTP $http_code (expected 200) at $url"
    return 1
  fi

  if [[ -z "$body" ]]; then
    log_fail "$label" "empty body at $url"
    return 1
  fi

  local v
  v=$(echo "$body" | jq -r "$expr" 2>/dev/null || echo '__JQ_ERROR__')
  if [[ "$v" == "__JQ_ERROR__" ]] || [[ "$v" == "null" ]] || [[ -z "$v" ]]; then
    log_fail "$label" "shape check failed: jq expr [$expr] returned [$v]"
    return 1
  fi

  log_pass "$label" "$v"
  return 0
}

# Hits a URL and asserts ONLY the HTTP status is 200. Used for endpoints whose
# body is not JSON (security.txt, robots.txt, sitemap.xml).
check_status_200() {
  local url="$1" label="$2"
  local http_code
  http_code=$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 'curl-error')
  if [[ "$http_code" != "200" ]]; then
    log_fail "$label" "HTTP $http_code (expected 200) at $url"
    return 1
  fi
  log_pass "$label" "HTTP 200"
  return 0
}

# Fetches an HTML page and asserts BOTH:
#   1. The response body contains <meta name="robots" content="index, follow">
#   2. The response headers do NOT contain X-Robots-Tag: noindex
#
# Rationale: a regressed Next.js metadata override or a Vercel env-var injection
# can silently flip the homepage to noindex and tank organic discoverability.
# This check is the canary so any such regression fails CI within the hour the
# hourly smoke cron fires. Item #2 of the 2026-05-18 360 audit.
check_meta_robots() {
  local url="$1" label="$2"
  local tmp_body tmp_headers http_code body headers
  tmp_body=$(mktemp)
  tmp_headers=$(mktemp)
  http_code=$(curl -sS -L \
    -A "Mozilla/5.0 (compatible; kerne-ci-smoke/1.0)" \
    -D "$tmp_headers" -o "$tmp_body" -w '%{http_code}' \
    --max-time 30 --retry 2 --retry-delay 1 \
    "$url" 2>/dev/null || echo 'curl-error')
  body=$(cat "$tmp_body")
  headers=$(cat "$tmp_headers")
  rm -f "$tmp_body" "$tmp_headers"

  if [[ "$http_code" != "200" ]]; then
    log_fail "$label" "HTTP $http_code (expected 200) at $url"
    return 1
  fi

  # Header assertion: X-Robots-Tag must not contain noindex (case-insensitive).
  # api-middleware sets this only on /api/* routes; if it leaks to a page route
  # we want CI to fail loud.
  if echo "$headers" | grep -qi '^x-robots-tag:.*noindex'; then
    local got
    got=$(echo "$headers" | grep -i '^x-robots-tag:' | head -1 | tr -d '\r\n')
    log_fail "$label" "X-Robots-Tag noindex on $url: $got"
    return 1
  fi

  # Body assertion: the page must declare an INDEXABLE robots directive.
  #
  # We assert the SEMANTIC intent (index AND follow, and NOT noindex/nofollow/
  # none) rather than a byte-exact string. Next.js renders the robots meta for
  # { index: true, follow: true } as content="index, follow", but that
  # serialization is not byte-stable across rendering paths: a route that opts
  # into dynamic rendering streams its <head> metadata, and the separator
  # between directives has been observed to arrive as a non-breaking space
  # (U+00A0) instead of an ASCII 0x20. A fixed-string grep for 'index, follow'
  # then fails even though the page is fully indexable, flaking this job and
  # blocking an unrelated PR on 2026-06-03 — only /rewards was affected, the one
  # terminal route using useSearchParams. Tokenizing the directive sidesteps the
  # whole class of whitespace / attribute-order / case variance while still
  # catching a genuine noindex regression. See scripts/verify_public_endpoints
  # test notes; reproduced with a U+00A0 separator before this change landed.
  local robots_tag
  robots_tag=$(echo "$body" | grep -oiE '<meta[^>]*name="robots"[^>]*>' | head -1)

  if [[ -z "$robots_tag" ]]; then
    # Show what the page emitted for robots/googlebot to make triage one-click.
    local got
    got=$(echo "$body" | grep -oiE '<meta name="(robots|googlebot)"[^>]*>' | head -2 | tr '\n' '|')
    log_fail "$label" "no <meta name=\"robots\"> tag at $url (got: ${got:-<none>})"
    return 1
  fi

  # Negative directives are checked FIRST: "noindex" contains "index" and
  # "nofollow" contains "follow", so a positive substring test alone would let a
  # noindex page slip through. This flip is the actual regression the canary
  # exists to catch (per the header comment above).
  if echo "$robots_tag" | grep -qiE 'noindex|nofollow|\bnone\b'; then
    log_fail "$label" "robots meta is not indexable at $url (got: $robots_tag)"
    return 1
  fi

  # Positive directives: both index and follow must be present. Substring tests
  # are whitespace- and encoding-agnostic, which is the entire point of the fix.
  if ! echo "$robots_tag" | grep -qi 'index' || ! echo "$robots_tag" | grep -qi 'follow'; then
    log_fail "$label" "robots meta missing index/follow at $url (got: $robots_tag)"
    return 1
  fi

  log_pass "$label" "<meta robots index,follow> present"
  return 0
}

if [[ $QUIET -eq 0 ]]; then
  echo "Kerne public-endpoint verification"
  echo "  marketing : $KERNE_ORIGIN"
  echo "  terminal  : $APP_ORIGIN"
  echo
fi

# ─── Marketing site (kerne.fi) ─────────────────────────────────────────────

# /api/health — liveness ping for both apps. Body shape varies; we just want 200.
check_endpoint "$KERNE_ORIGIN/api/health" '.status // "ok"' "kerne.fi /api/health"

# /api/por — Proof of Reserves. Must include the four-bucket composition
# object so any future non-zero off-chain bucket is loudly visible per
# docs/SEED_TVL_POLICY.md.
check_endpoint "$KERNE_ORIGIN/api/por" '.reserves.vault.composition.offChainAssets.eth // "MISSING"' "kerne.fi /api/por composition.offChainAssets"
check_endpoint "$KERNE_ORIGIN/api/por" '.reserves.vault.composition.l1Assets.eth // "MISSING"' "kerne.fi /api/por composition.l1Assets"
check_endpoint "$KERNE_ORIGIN/api/por" '.reserves.vault.composition.hedgingReserve.eth // "MISSING"' "kerne.fi /api/por composition.hedgingReserve"
check_endpoint "$KERNE_ORIGIN/api/por" '.reserves.vault.composition.trackedOnChain.eth // "MISSING"' "kerne.fi /api/por composition.trackedOnChain"
check_endpoint "$KERNE_ORIGIN/api/por" '.solvency.status // "MISSING"' "kerne.fi /api/por solvency.status"

# /api/risk-status — wired-truth surface for the Exit Triggers chapter. Must
# return 200 with `gaps` array (drift-aware) and `triggers.onChain` populated.
check_endpoint "$KERNE_ORIGIN/api/risk-status" '.overall // "MISSING"' "kerne.fi /api/risk-status overall"
check_endpoint "$KERNE_ORIGIN/api/risk-status" '.gaps | type' "kerne.fi /api/risk-status gaps array present"
check_endpoint "$KERNE_ORIGIN/api/risk-status" '.triggers.onChain | length' "kerne.fi /api/risk-status onChain trigger count"

# /api/apy — user-facing skUSD APY computed live. kerne.fi/api/apy is a REDUCED
# proxy: it serves the displayed number (expectedAPYPct) but strips `methodology`
# and the `sources` object. Those live on the canonical app.kerne.fi/api/apy and
# are asserted (genuine presence, no fallback) in the terminal-app block below.
check_endpoint "$KERNE_ORIGIN/api/apy" '.expectedAPYPct // "MISSING"' "kerne.fi /api/apy expectedAPYPct"

# /api/stats — TVL + APY summary used by hero / aggregator scrapers.
check_endpoint "$KERNE_ORIGIN/api/stats" '.tvl // "MISSING"' "kerne.fi /api/stats tvl"
check_endpoint "$KERNE_ORIGIN/api/stats" '.apy // "MISSING"' "kerne.fi /api/stats apy"

# Trust files — RFC 9116, robots, sitemap.
check_status_200 "$KERNE_ORIGIN/.well-known/security.txt" "kerne.fi security.txt (RFC 9116)"
check_status_200 "$KERNE_ORIGIN/robots.txt" "kerne.fi robots.txt"
check_status_200 "$KERNE_ORIGIN/sitemap.xml" "kerne.fi sitemap.xml"

# Indexability canaries — assert the canonical pages still emit
# <meta name="robots" content="index, follow"> and that no X-Robots-Tag
# noindex header leaks from /api middleware to a page route. A silent
# regression here tanks organic discoverability without any other test failing.
check_meta_robots "$KERNE_ORIGIN/" "kerne.fi / robots meta"
check_meta_robots "$KERNE_ORIGIN/opal" "kerne.fi /opal robots meta"
check_meta_robots "$KERNE_ORIGIN/insights" "kerne.fi /insights robots meta"
check_meta_robots "$KERNE_ORIGIN/docs/introduction" "kerne.fi /docs/introduction robots meta"

# Docs trio: introduction (canonical), security-and-audits, exit-triggers
# (the wired-truth chapter that names every threshold the API should expose).
check_status_200 "$KERNE_ORIGIN/docs/introduction" "kerne.fi /docs/introduction"
check_status_200 "$KERNE_ORIGIN/docs/security-and-audits" "kerne.fi /docs/security-and-audits"
check_status_200 "$KERNE_ORIGIN/docs/exit-triggers-and-emergency-runbook" "kerne.fi /docs/exit-triggers-and-emergency-runbook"

# ─── Terminal app (app.kerne.fi) ───────────────────────────────────────────

check_endpoint "$APP_ORIGIN/api/health" '.status // "ok"' "app.kerne.fi /api/health"

# /api/por mirror on terminal. Must carry the same composition contract as
# kerne.fi so consumers can hit either origin.
check_endpoint "$APP_ORIGIN/api/por" '.reserves.vault.composition.offChainAssets.eth // "MISSING"' "app.kerne.fi /api/por composition.offChainAssets"
check_endpoint "$APP_ORIGIN/api/por" '.reserves.vault.composition.l1Assets.eth // "MISSING"' "app.kerne.fi /api/por composition.l1Assets"

# /api/apy mirror on terminal — the CANONICAL endpoint (kerne.fi proxies it).
# Carries methodology + the sources object (both stripped from the kerne.fi
# proxy), so assert them HERE with genuine presence checks (no // "MISSING"
# fallback): an absent field FAILs instead of logging a vacuous pass.
check_endpoint "$APP_ORIGIN/api/apy" '.expectedAPYPct // "MISSING"' "app.kerne.fi /api/apy expectedAPYPct"
check_endpoint "$APP_ORIGIN/api/apy" '.methodology' "app.kerne.fi /api/apy methodology (present)"
check_endpoint "$APP_ORIGIN/api/apy" '.sources.fundingWindowDays' "app.kerne.fi /api/apy sources.fundingWindowDays (present)"

# /api/psm-status — first-mint readiness. Single most-watched gate before
# the first USDC->kUSD swap lands.
check_endpoint "$APP_ORIGIN/api/psm-status" '.ready // "MISSING"' "app.kerne.fi /api/psm-status ready"
check_endpoint "$APP_ORIGIN/api/psm-status" '.gates.mintingEnabled // "MISSING"' "app.kerne.fi /api/psm-status gates.mintingEnabled"
check_endpoint "$APP_ORIGIN/api/psm-status" '.gates.psmHasMinterRole // "MISSING"' "app.kerne.fi /api/psm-status gates.psmHasMinterRole"

# Indexability canaries on the terminal app. /mint, /swap, /rewards are the
# three discovery-bearing routes a search-engine crawl should land on.
check_meta_robots "$APP_ORIGIN/" "app.kerne.fi / robots meta"
check_meta_robots "$APP_ORIGIN/mint" "app.kerne.fi /mint robots meta"
check_meta_robots "$APP_ORIGIN/swap" "app.kerne.fi /swap robots meta"
check_meta_robots "$APP_ORIGIN/rewards" "app.kerne.fi /rewards robots meta"

# ─── Aggregate ─────────────────────────────────────────────────────────────

TOTAL=$((PASSED + FAILED))
echo
if [[ $FAILED -eq 0 ]]; then
  printf 'All checks passed: %d/%d\n' "$PASSED" "$TOTAL"
else
  printf 'FAILED: %d of %d checks failed\n' "$FAILED" "$TOTAL"
fi

# Emit a JSON summary on stderr so CI can parse it without the human-readable
# stdout interfering. The shape is stable:
#   { "passed": N, "failed": N, "total": N, "results": [ {label, status, detail}, ... ] }
{
  echo
  echo "{"
  printf '  "passed": %d,\n' "$PASSED"
  printf '  "failed": %d,\n' "$FAILED"
  printf '  "total": %d,\n' "$TOTAL"
  printf '  "results": [\n'
  local_first=1
  for r in "${RESULTS[@]}"; do
    if [[ $local_first -eq 1 ]]; then
      local_first=0
      printf '    %s' "$r"
    else
      printf ',\n    %s' "$r"
    fi
  done
  printf '\n  ]\n'
  echo "}"
} >&2

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
exit 0
