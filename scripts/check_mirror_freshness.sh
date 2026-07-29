#!/usr/bin/env bash
#
# check_mirror_freshness.sh
#
# Enforces the promise made at the foot of audits/DEPLOYED_VS_SOURCE.md: that this
# mirror and the canonical web version change in the same commit. On 2026-07-28 that
# promise was found broken inside the file that makes it. The mirror was dated
# 2026-07-20 and listed two standing divergences while kerne.fi/security/deployed-vs-source
# was dated 2026-07-25 and listed three, so the auditor-facing mirror contradicted
# our own live site on the most sensitive open finding we have. This check makes the
# promise enforceable instead of aspirational.
#
# Two assertions:
#   1. the mirror's "Last updated" date is not older than the web version's
#   2. the mirror's standing-divergence count equals the web version's
#
# Dates are compared as parsed epoch seconds, never as strings, because the two
# surfaces deliberately use different formats ("2026-07-28" here, "July 25, 2026"
# on the page) and a string comparison would be brittle for no reason.
#
# Exit codes: 0 pass (or the page was unreachable, see below), 1 drift detected.
#
# If kerne.fi cannot be reached after retries this exits 0 with a loud warning.
# A public repo showing a red X because someone else's CDN blipped teaches
# maintainers to ignore the check, which costs more than the missed run.
#
# Dependencies: curl, GNU date, sed, grep. No API keys.

set -uo pipefail

MIRROR_FILE="${MIRROR_FILE:-audits/DEPLOYED_VS_SOURCE.md}"
PAGE_URL="${PAGE_URL:-https://kerne.fi/security/deployed-vs-source}"
RETRIES="${RETRIES:-3}"

fail=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# Map the spelled-out counts the page uses in prose back to integers.
word_to_int() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    zero) echo 0 ;; one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;;
    five) echo 5 ;; six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;; nine) echo 9 ;;
    ''|*[!0-9]*) echo "" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- mirror side

if [ ! -f "$MIRROR_FILE" ]; then
  err "$MIRROR_FILE not found (run from the repository root)"
  exit 1
fi

mirror_date_raw="$(grep -m1 -oE 'Last updated [0-9]{4}-[0-9]{2}-[0-9]{2}' "$MIRROR_FILE" \
  | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
mirror_count_word="$(grep -m1 -oiE '^## The ([a-z]+|[0-9]+) standing divergences' "$MIRROR_FILE" \
  | sed -E 's/^## [Tt]he ([A-Za-z0-9]+) standing divergences/\1/')"

if [ -z "$mirror_date_raw" ]; then
  err "could not read a 'Last updated YYYY-MM-DD' line from $MIRROR_FILE"
fi
if [ -z "$mirror_count_word" ]; then
  err "could not read a '## The N standing divergences' heading from $MIRROR_FILE"
fi
[ "$fail" -eq 1 ] && exit 1

mirror_epoch="$(date -u -d "$mirror_date_raw" +%s 2>/dev/null)"
if [ -z "$mirror_epoch" ]; then
  err "could not parse mirror date '$mirror_date_raw' as a date"
  exit 1
fi
mirror_count="$(word_to_int "$mirror_count_word")"

say "mirror: $MIRROR_FILE"
say "  last updated       $mirror_date_raw (epoch $mirror_epoch)"
say "  standing divergences $mirror_count ($mirror_count_word)"

# ------------------------------------------------------------------ page side

html=""
for attempt in $(seq 1 "$RETRIES"); do
  html="$(curl -sS --fail --max-time 30 -A 'kerne-mirror-freshness-check' "$PAGE_URL" 2>/dev/null)" && break
  html=""
  warn "attempt $attempt/$RETRIES could not fetch $PAGE_URL"
  sleep $(( attempt * 3 ))
done

if [ -z "$html" ]; then
  warn "canonical page unreachable after $RETRIES attempts; skipping the comparison."
  warn "this is NOT a pass of the drift check, only an absence of evidence."
  exit 0
fi

# React server-renders adjacent text nodes separated by <!-- --> comments, so the
# heading arrives as "The <!-- -->three<!-- --> standing divergences". Drop the
# comments and collapse whitespace and the prose can be matched as prose. Tags are
# deliberately left alone: both strings we want sit in plain text nodes (and in the
# OpenGraph meta tags, which are generated from the same constant), so stripping
# tags would only add ways to break.
text="$(printf '%s' "$html" \
  | sed -E 's/<!--[^>]*-->//g' \
  | tr '\n' ' ' \
  | sed -E 's/[[:space:]]+/ /g')"

# grep -o prints every match on a line and the document is effectively one line,
# so take the first match explicitly rather than relying on -m1.
page_date_raw="$(printf '%s' "$text" \
  | grep -oE 'Last updated:? [A-Z][a-z]+ [0-9]{1,2}, [0-9]{4}' \
  | head -1 | sed -E 's/^Last updated:? //')"
page_count_word="$(printf '%s' "$text" \
  | grep -oiE 'The ([a-z]+|[0-9]+) standing divergences' \
  | head -1 | sed -E 's/^[Tt]he ([A-Za-z0-9]+) standing divergences/\1/')"

if [ -z "$page_date_raw" ] || [ -z "$page_count_word" ]; then
  warn "fetched $PAGE_URL but could not locate the 'Last updated' line or the"
  warn "'The N standing divergences' heading. The page markup may have changed;"
  warn "update this script's selectors. Not failing the build on a parse miss."
  exit 0
fi

page_epoch="$(date -u -d "$page_date_raw" +%s 2>/dev/null)"
if [ -z "$page_epoch" ]; then
  warn "could not parse page date '$page_date_raw' as a date; skipping comparison"
  exit 0
fi
page_count="$(word_to_int "$page_count_word")"

say "page: $PAGE_URL"
say "  last updated       $page_date_raw (epoch $page_epoch)"
say "  standing divergences $page_count ($page_count_word)"

# ----------------------------------------------------------------- assertions

if [ "$mirror_epoch" -lt "$page_epoch" ]; then
  err "the mirror is STALE. $MIRROR_FILE is dated $mirror_date_raw but the canonical"
  err "page is dated $page_date_raw. Copy the current page content into the mirror and"
  err "bump its 'Last updated' line in the same commit as the change that caused this."
fi

if [ -n "$mirror_count" ] && [ -n "$page_count" ] && [ "$mirror_count" != "$page_count" ]; then
  err "divergence-count drift. The mirror lists $mirror_count standing divergences and the"
  err "canonical page lists $page_count. These must agree: a reviewer who finds fewer"
  err "divergences in the mirror than on the site reads the mirror as decoration."
fi

if [ "$fail" -eq 0 ]; then
  say "OK: mirror is not older than the canonical page and both list $mirror_count standing divergences."
fi
exit "$fail"
