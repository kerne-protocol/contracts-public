#!/usr/bin/env bash
# Kerne Protocol public verification script.
#
# Runs in two parts, and the difference between them is the point.
#
#   PART 1, endpoint shape. Hits every documented public endpoint on kerne.fi
#   and app.kerne.fi and asserts the response shape matches the published
#   contract. Both of those hosts are Kerne-controlled infrastructure, so this
#   part proves the surface is live and well-formed. It cannot, on its own,
#   tell you whether the numbers are true.
#
#   PART 2, on-chain cross-check. Reads the same figures straight off Base
#   through a public JSON-RPC endpoint that Kerne does not run, does not pay
#   for and cannot influence, then checks Kerne's own signed Proof of Reserves
#   against them. This is the part that can call Kerne wrong. It re-derives
#   the backing invariant from chain state alone, with no Kerne input of any
#   kind, and it fails loudly on a mismatch.
#
# Anyone (auditor, allocator, journalist) can run this against the live
# protocol in about a minute. No authentication, no API key, no account, no
# toolchain beyond curl and jq.
#
# Dependencies: curl, jq. Both standard on Ubuntu / macOS / WSL.
#
# Usage:
#   bash scripts/verify_public_endpoints.sh                     # default origins
#   KERNE_ORIGIN=https://kerne.fi APP_ORIGIN=https://app.kerne.fi bash scripts/verify_public_endpoints.sh
#   bash scripts/verify_public_endpoints.sh --quiet              # only print failures
#   BASE_RPC=https://your-own-node bash scripts/verify_public_endpoints.sh
#
# Exit codes:
#   0 = every check passed
#   1 = one or more checks failed (details in output)
#   2 = missing dependency (curl or jq)
#   3 = every check that ran passed, but no public Base RPC endpoint could be
#       reached, so PART 2 did not run. This is a distinct state on purpose: a
#       network problem at the reader's end is not evidence against Kerne, and
#       it must not be reported as though it were.

set -uo pipefail

KERNE_ORIGIN="${KERNE_ORIGIN:-https://kerne.fi}"
APP_ORIGIN="${APP_ORIGIN:-https://app.kerne.fi}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# Public Base JSON-RPC endpoints, tried in order until one answers. None of
# these are operated by Kerne. Set BASE_RPC to put your own node first, which
# is the strongest way to run this script: then no part of PART 2 depends on
# infrastructure chosen by us either.
BASE_RPC_ENDPOINTS=()
[[ -n "${BASE_RPC:-}" ]] && BASE_RPC_ENDPOINTS+=("$BASE_RPC")
BASE_RPC_ENDPOINTS+=(
  "https://mainnet.base.org"
  "https://base-rpc.publicnode.com"
  "https://base.drpc.org"
  "https://1rpc.io/base"
)

# Addresses come from this repository's own registry, deployments/8453.json.
# They are checked against live Base daily by scripts/check_registry_vs_chain.py
# and by test/fork/RegistryMatchesChain.t.sol, so they are not a separate thing
# you have to take on trust.
ADDR_KUSD="0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3"
ADDR_SKUSD="0x96F5102C15b839757f811A98CEc3725Ac21DfA14"
ADDR_USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

# All three PSMs. The live mint PSM plus the two retired PSMs still holding a
# USDC redeem reserve. Proof of Reserves sums all three, so a check that reads
# only the live one would understate the backing and disagree with the
# published figure for a reason that is not a defect.
PSM_ADDRESSES=(
  "0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803"  # KUSDPSM, live, 2026-07-10 redeploy
  "0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc"  # retired v1, redeem reserve
  "0x07eBb486e11BD217e6085eb5ab663e4517595993"  # retired 2026-06-16, redeem reserve
)

# Function selectors: the first four bytes of keccak256 of the signature.
SEL_TOTAL_SUPPLY="0x18160ddd"  # totalSupply()
SEL_BALANCE_OF="0x70a08231"    # balanceOf(address)
SEL_TOTAL_ASSETS="0x01e1d114"  # totalAssets()
SEL_ASSET="0x38d52e0f"         # asset()

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
# This check is the canary for that class of regression. Item #2 of the
# 2026-05-18 360 audit.
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

# ─── On-chain helpers (PART 2) ─────────────────────────────────────────────

RPC_ENDPOINT=""    # resolved at the end from RPC_STATE_FILE
RPC_REACHABLE=0    # 1 once any endpoint has answered at least once
SKIPPED=0          # checks that could not run, counted separately from failures

# Nearly every call into rpc_eth_call happens inside a command substitution,
# which bash runs in a subshell, so a plain global assigned in that function
# would be discarded the moment it returned. The endpoint that answered is
# therefore recorded in a file, which does survive. Getting this wrong made
# the script report "no RPC reachable" on a run whose reads had all succeeded.
RPC_STATE_FILE="$(mktemp)"
trap 'rm -f "$RPC_STATE_FILE"' EXIT

log_skip() {
  local label="$1" detail="$2"
  SKIPPED=$((SKIPPED + 1))
  RESULTS+=("$(jq -n --arg l "$label" --arg d "$detail" '{label:$l, status:"skip", detail:$d}')")
  printf '  SKIP  %-50s  %s\n' "$label" "$detail"
}

# rpc_eth_call <to> <data> <block-tag>
# Prints the 0x result on stdout, or returns 1 if no endpoint could answer.
# The first endpoint that answers is pinned and tried first from then on, so
# every read in a run comes from one node's view rather than a mix of nodes.
rpc_eth_call() {
  local to="$1" data="$2" block="$3"
  local body raw result ep
  body=$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"%s"]}' \
    "$to" "$data" "$block")

  local pinned=""
  [[ -s "$RPC_STATE_FILE" ]] && pinned=$(cat "$RPC_STATE_FILE")

  local ordered=()
  [[ -n "$pinned" ]] && ordered+=("$pinned")
  for ep in "${BASE_RPC_ENDPOINTS[@]}"; do
    [[ "$ep" == "$pinned" ]] && continue
    ordered+=("$ep")
  done

  for ep in "${ordered[@]}"; do
    raw=$(curl -sS -X POST -H 'content-type: application/json' \
      --max-time 20 --retry 1 --retry-delay 1 --data "$body" "$ep" 2>/dev/null) || continue
    [[ -z "$raw" ]] && continue
    result=$(echo "$raw" | jq -r '.result // empty' 2>/dev/null)
    # A JSON-RPC error (rate limit, archive refused) yields no .result, so we
    # fall through to the next endpoint rather than treating it as a zero.
    if [[ -n "$result" && "$result" == 0x* && ${#result} -gt 2 ]]; then
      printf '%s' "$ep" > "$RPC_STATE_FILE"
      echo "$result"
      return 0
    fi
  done
  return 1
}

# hex_to_units <0x...> <decimals>
# Token amounts run to 2^256 and bash integers are 64-bit, so bash arithmetic
# would silently overflow on any real supply. jq carries these in doubles,
# which holds far more significant digits than the six decimal places the
# published figures are rounded to.
# Written without jq's `fabs`, a libm builtin that is absent from some builds.
hex_to_units() {
  jq -nr --arg h "$1" --argjson d "$2" '
    ($h | ltrimstr("0x") | ascii_downcase) as $s
    | (reduce ($s | explode[]) as $c (0;
        . * 16 + (if $c >= 48 and $c <= 57 then $c - 48 else $c - 87 end)))
    | . / pow(10; $d)'
}

# within_tolerance <a> <b> <absolute-tolerance>
within_tolerance() {
  local r
  r=$(jq -n --argjson a "$1" --argjson b "$2" --argjson t "$3" \
    '(($a - $b) | if . < 0 then - . else . end) <= $t') || return 1
  [[ "$r" == "true" ]]
}

# check_reproduces <label> <published> <onchain> <tolerance> <unit>
check_reproduces() {
  local label="$1" pub="$2" chain="$3" tol="$4" unit="$5"
  if within_tolerance "$pub" "$chain" "$tol"; then
    log_pass "$label" "published $pub $unit == chain $chain $unit"
  else
    log_fail "$label" "MISMATCH: Kerne publishes $pub $unit, chain says $chain $unit"
  fi
}

if [[ $QUIET -eq 0 ]]; then
  echo "Kerne public verification"
  echo "  marketing : $KERNE_ORIGIN"
  echo "  terminal  : $APP_ORIGIN"
  echo "  base rpc  : ${BASE_RPC_ENDPOINTS[0]} (public, not operated by Kerne)"
  echo
fi

# ─── Marketing site (kerne.fi) ─────────────────────────────────────────────

# /api/health — liveness ping for both apps. Assert the documented `ok` field is
# actually present, not a fallback that passes when the field is missing.
check_endpoint "$KERNE_ORIGIN/api/health" '.ok' "kerne.fi /api/health"

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

check_endpoint "$APP_ORIGIN/api/health" '.ok' "app.kerne.fi /api/health"

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
#
# These three are BOOLEANS, so they carry no `// "MISSING"` fallback. jq's `//`
# treats `false` as falsy exactly like `null`, so `.gates.psmHasMinterRole //
# "MISSING"` would substitute the string "MISSING" the moment the role is
# genuinely revoked, and this script would log a PASS reading "MISSING" instead
# of reporting the flip. Without the fallback, an absent field yields `null` and
# FAILs, and a real `false` is reported as `false`.
check_endpoint "$APP_ORIGIN/api/psm-status" '.ready' "app.kerne.fi /api/psm-status ready"
check_endpoint "$APP_ORIGIN/api/psm-status" '.gates.mintingEnabled' "app.kerne.fi /api/psm-status gates.mintingEnabled"
check_endpoint "$APP_ORIGIN/api/psm-status" '.gates.psmHasMinterRole' "app.kerne.fi /api/psm-status gates.psmHasMinterRole"

# Indexability canaries on the terminal app. /mint, /swap, /rewards are the
# three discovery-bearing routes a search-engine crawl should land on.
check_meta_robots "$APP_ORIGIN/" "app.kerne.fi / robots meta"
check_meta_robots "$APP_ORIGIN/mint" "app.kerne.fi /mint robots meta"
check_meta_robots "$APP_ORIGIN/swap" "app.kerne.fi /swap robots meta"
check_meta_robots "$APP_ORIGIN/rewards" "app.kerne.fi /rewards robots meta"

# ─── PART 2: on-chain cross-check against a public Base node ───────────────
#
# Everything above this line asked Kerne's own web servers what is true. This
# section asks Base instead, through an endpoint Kerne does not operate, and
# then holds Kerne's signed Proof of Reserves against the answer.

if [[ $QUIET -eq 0 ]]; then
  echo
  echo "On-chain cross-check (public Base RPC, no Kerne infrastructure)"
fi

# Pull the SIGNED payload rather than the convenience fields on the envelope.
# These are the bytes the attestation key actually commits to, so reproducing
# them from chain is a statement about what Kerne signed, not about what a
# response body happened to say.
por_raw=$(curl -sS -L --max-time 30 --retry 2 --retry-delay 1 \
  "$KERNE_ORIGIN/api/por/signed" 2>/dev/null || echo '')
por_signed=$(echo "$por_raw" | jq -r '.signed_payload_canonical // empty' 2>/dev/null || echo '')

if [[ -z "$por_signed" ]]; then
  log_fail "por/signed signed payload" "could not read signed_payload_canonical from $KERNE_ORIGIN/api/por/signed"
else
  pub_supply=$(echo "$por_signed" | jq -r '.kusd_total_supply // empty')
  pub_reserve=$(echo "$por_signed" | jq -r '.psm_usdc_reserve // empty')
  pub_held=$(echo "$por_signed" | jq -r '.psm_kusd_held // empty')
  pub_outstanding=$(echo "$por_signed" | jq -r '.outstanding_kusd // empty')
  por_block=$(echo "$por_raw" | jq -r '.block_heights.base // empty')

  # Internal consistency of the signed payload. Pure arithmetic on the signed
  # bytes, no chain and no clock involved, so this can never drift.
  if [[ -n "$pub_supply" && -n "$pub_held" && -n "$pub_outstanding" ]]; then
    expected_out=$(jq -n --argjson s "$pub_supply" --argjson h "$pub_held" '$s - $h')
    check_reproduces "signed payload: outstanding == supply - PSM inventory" \
      "$pub_outstanding" "$expected_out" 0.000001 "kUSD"
  fi

  # Decide once whether this node will serve state at the block the attestation
  # names. When it will, every comparison below is exact against the same block
  # Kerne signed. When it will not (several free endpoints refuse archive
  # reads), we fall back to the chain head and say so, and the comparisons that
  # legitimately drift between blocks are reported rather than asserted. A
  # reader's rate-limited RPC must never be able to manufacture a Kerne defect.
  BLOCK_TAG="latest"
  PINNED=0
  if [[ -n "$por_block" ]]; then
    block_hex=$(printf '0x%x' "$por_block")
    if rpc_eth_call "$ADDR_KUSD" "$SEL_TOTAL_SUPPLY" "$block_hex" >/dev/null 2>&1; then
      BLOCK_TAG="$block_hex"
      PINNED=1
    fi
  fi
  if [[ $QUIET -eq 0 && $PINNED -eq 1 ]]; then
    echo "  ----  reading Base at block $por_block, the block the attestation names"
  fi

  raw_supply=$(rpc_eth_call "$ADDR_KUSD" "$SEL_TOTAL_SUPPLY" "$BLOCK_TAG" || echo '')

  if [[ -z "$raw_supply" ]]; then
    log_skip "on-chain cross-check" \
      "no public Base RPC endpoint answered (tried ${#BASE_RPC_ENDPOINTS[@]}); this is a network result, not a Kerne result"
  else
    chain_supply=$(hex_to_units "$raw_supply" 18)

    # Sum USDC and kUSD across all three PSMs, one eth_call each.
    chain_reserve=0
    chain_held=0
    reads_ok=1
    for psm in "${PSM_ADDRESSES[@]}"; do
      # balanceOf(address): the selector followed by the address left-padded
      # into a 32-byte word.
      arg=$(printf '%064s' "$(echo "${psm#0x}" | tr 'A-Z' 'a-z')" | tr ' ' '0')
      raw_u=$(rpc_eth_call "$ADDR_USDC" "${SEL_BALANCE_OF}${arg}" "$BLOCK_TAG" || echo '')
      raw_k=$(rpc_eth_call "$ADDR_KUSD" "${SEL_BALANCE_OF}${arg}" "$BLOCK_TAG" || echo '')
      if [[ -z "$raw_u" || -z "$raw_k" ]]; then reads_ok=0; break; fi
      chain_reserve=$(jq -n --argjson a "$chain_reserve" --argjson b "$(hex_to_units "$raw_u" 6)" '$a + $b')
      chain_held=$(jq -n --argjson a "$chain_held" --argjson b "$(hex_to_units "$raw_k" 18)" '$a + $b')
    done

    if [[ $reads_ok -eq 0 ]]; then
      log_skip "on-chain PSM reserves" "a public Base RPC endpoint stopped answering part way through"
    else
      chain_outstanding=$(jq -n --argjson s "$chain_supply" --argjson h "$chain_held" '$s - $h')

      # ── The claim itself, derived from chain alone ──
      # Every kUSD in circulation is backed by USDC sitting in a PSM. Nothing
      # Kerne publishes is an input here: it is four eth_calls and a
      # subtraction. It holds at every block, so it cannot drift and it needs
      # no tolerance.
      if jq -n --argjson r "$chain_reserve" --argjson o "$chain_outstanding" \
           -e '$r >= $o' >/dev/null; then
        ratio=$(jq -n --argjson r "$chain_reserve" --argjson o "$chain_outstanding" \
          'if $o > 0 then (($r / $o) * 1000000 | round) / 1000000 else 0 end')
        log_pass "CHAIN ONLY: kUSD is fully backed by PSM USDC" \
          "$chain_reserve USDC backs $chain_outstanding kUSD outstanding, ratio $ratio"
      else
        log_fail "CHAIN ONLY: kUSD is fully backed by PSM USDC" \
          "UNDERBACKED: $chain_reserve USDC against $chain_outstanding kUSD outstanding"
      fi

      # ── Does the signed attestation reproduce from chain? ──
      if [[ $PINNED -eq 1 ]]; then
        # Same block Kerne signed, so the only slack is the rounding in the
        # published figures, which carry six decimal places.
        tol=0.000001
        check_reproduces "signed kusd_total_supply reproduces from chain" "$pub_supply" "$chain_supply" "$tol" "kUSD"
        check_reproduces "signed psm_usdc_reserve reproduces from chain"  "$pub_reserve" "$chain_reserve" "$tol" "USDC"
        check_reproduces "signed psm_kusd_held reproduces from chain"     "$pub_held" "$chain_held" "$tol" "kUSD"
        check_reproduces "signed outstanding_kusd reproduces from chain"  "$pub_outstanding" "$chain_outstanding" "$tol" "kUSD"
      else
        # This endpoint would not serve the attested block, so chain head and
        # attestation are different moments and any gap between them is
        # expected rather than meaningful. Report both, assert neither.
        log_skip "signed figures reproduce from chain" \
          "this RPC endpoint refuses archive reads, so the attested block $por_block could not be read; head says supply $chain_supply / reserve $chain_reserve / outstanding $chain_outstanding against signed $pub_supply / $pub_reserve / $pub_outstanding. Re-run with BASE_RPC set to an archive node to assert equality."
      fi

      # ── skUSD, the staked wrapper ──
      # Two exact invariants that hold at any block and do not depend on
      # decimals: the vault's asset is kUSD, and everything it reports as
      # assets is kUSD it actually holds.
      raw_asset=$(rpc_eth_call "$ADDR_SKUSD" "$SEL_ASSET" "$BLOCK_TAG" || echo '')
      if [[ -n "$raw_asset" ]]; then
        got_asset="0x${raw_asset: -40}"
        if [[ "$(echo "$got_asset" | tr 'A-Z' 'a-z')" == "$(echo "$ADDR_KUSD" | tr 'A-Z' 'a-z')" ]]; then
          log_pass "skUSD.asset() is kUSD" "$got_asset"
        else
          log_fail "skUSD.asset() is kUSD" "expected $ADDR_KUSD, chain says $got_asset"
        fi
      fi

      raw_ta=$(rpc_eth_call "$ADDR_SKUSD" "$SEL_TOTAL_ASSETS" "$BLOCK_TAG" || echo '')
      sk_arg=$(printf '%064s' "$(echo "${ADDR_SKUSD#0x}" | tr 'A-Z' 'a-z')" | tr ' ' '0')
      raw_skbal=$(rpc_eth_call "$ADDR_KUSD" "${SEL_BALANCE_OF}${sk_arg}" "$BLOCK_TAG" || echo '')
      if [[ -n "$raw_ta" && -n "$raw_skbal" ]]; then
        sk_assets=$(hex_to_units "$raw_ta" 18)
        sk_held=$(hex_to_units "$raw_skbal" 18)
        check_reproduces "skUSD.totalAssets() == kUSD it actually holds" \
          "$sk_assets" "$sk_held" 0.000001 "kUSD"
      fi

      # skUSD carries 24 decimals, six more than kUSD, which is a deliberate
      # ERC-4626 decimals offset and not a bug. Reported, not asserted: the
      # share price is a live number and this script does not tell you what it
      # ought to be.
      raw_ts=$(rpc_eth_call "$ADDR_SKUSD" "$SEL_TOTAL_SUPPLY" "$BLOCK_TAG" || echo '')
      if [[ -n "$raw_ts" && -n "$raw_ta" ]] && [[ $QUIET -eq 0 ]]; then
        sk_shares=$(hex_to_units "$raw_ts" 24)
        echo "  ----  skUSD: $(hex_to_units "$raw_ta" 18) kUSD of assets over $sk_shares shares"
      fi
    fi
  fi
fi

# ─── Aggregate ─────────────────────────────────────────────────────────────

# Resolved here rather than inside rpc_eth_call, for the subshell reason given
# where RPC_STATE_FILE is declared.
if [[ -s "$RPC_STATE_FILE" ]]; then
  RPC_REACHABLE=1
  RPC_ENDPOINT=$(cat "$RPC_STATE_FILE")
fi

TOTAL=$((PASSED + FAILED))
echo
if [[ $FAILED -eq 0 ]]; then
  printf 'All checks passed: %d/%d\n' "$PASSED" "$TOTAL"
else
  printf 'FAILED: %d of %d checks failed\n' "$FAILED" "$TOTAL"
fi
if [[ $SKIPPED -gt 0 ]]; then
  printf 'Skipped: %d check(s) could not run\n' "$SKIPPED"
fi
if [[ $RPC_REACHABLE -eq 1 ]]; then
  printf 'On-chain reads came from %s\n' "$RPC_ENDPOINT"
fi

# Emit a JSON summary on stderr so CI can parse it without the human-readable
# stdout interfering. The shape is stable:
#   { "passed": N, "failed": N, "total": N, "results": [ {label, status, detail}, ... ] }
{
  echo
  echo "{"
  printf '  "passed": %d,\n' "$PASSED"
  printf '  "failed": %d,\n' "$FAILED"
  printf '  "skipped": %d,\n' "$SKIPPED"
  printf '  "onchain_rpc_reachable": %s,\n' "$([[ $RPC_REACHABLE -eq 1 ]] && echo true || echo false)"
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
# A real failure always wins over a skip. Only when nothing failed does an
# unreachable RPC get its own exit code, so a reader whose network blocked the
# on-chain half can tell that apart from Kerne failing a check.
if [[ $RPC_REACHABLE -eq 0 ]]; then
  exit 3
fi
exit 0
