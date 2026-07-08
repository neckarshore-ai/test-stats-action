#!/usr/bin/env bash
#
# emit-test-stats.sh — the transform core of the test-stats-action composite action.
#
# Maps a test runner's OWN native reporter output to the estate stats.json contract:
#   neckarshore-planning/docs/reference/stats-json-contract.md
#
# Counts come from each runner's own reporter — NEVER from grepping source for test()
# calls (the 3.7k-vs-74 lesson: grep counted ~3.7k test() hits for a suite the runner
# reported as 74). The global constraints, enforced below:
#   1. runner-reported, never grep                4. fail-closed-visible (no silent 0)
#   2. total == sum(byType); lenses + declared     5. exact tool versions (jq/git/date, runner-provided)
#      NEVER summed into total/byType              6. a non-green run emits red:true (still written)
#   3. audited_sha + repo always present
#
# Three contract hardenings (2026-07-07, stats.json-contract §1/§4):
#   - tests.declared : executed-but-ungated OR --list-declared counts, held SEPARATE
#                      from total (fixes the neckarshore-website 308->87 over-count).
#   - red/red_detail : the caller's suite result; a failing run must not emit a
#                      stale-green count (the easter-eggs-skills lesson). Still WRITES.
#   - total          : only executed AND CI-gated AND disjoint (= sum(byType)); the
#                      caller decides which runner lines are gated (-> runners) vs
#                      ungated (-> declared). Disjoint cascade: nested suites whose
#                      output is suppressed are distinct byType entries (md-viewer 54).
#
# Driven entirely by INPUT_* env vars so action.yml is a thin wrapper and this script
# is testable in isolation by tests/emit-test-stats.bats. Every checkable decision is
# here, not in action.yml.

set -o pipefail

# --- optional inputs default to empty so unset is never an error ---
INPUT_REPO="${INPUT_REPO:-}"
INPUT_OUT="${INPUT_OUT:-}"
INPUT_RUNNERS="${INPUT_RUNNERS:-}"
INPUT_DECLARED="${INPUT_DECLARED:-}"
INPUT_LENSES="${INPUT_LENSES:-}"
INPUT_ENDPOINTS="${INPUT_ENDPOINTS:-}"
INPUT_SHA="${INPUT_SHA:-}"
INPUT_TEST_RESULT="${INPUT_TEST_RESULT:-}"
INPUT_RED_DETAIL="${INPUT_RED_DETAIL:-}"

# Fail-closed: a loud message on stderr + non-zero exit. Never write a partial stats.json
# (a missing/zero producer must be VISIBLE, not a silent 0 that drops the public number).
die() {
  echo "emit-test-stats: $*" >&2
  exit 1
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"  # leading
  s="${s%"${s##*[![:space:]]}"}"  # trailing
  printf '%s' "$s"
}

# count_for <runner> <reporter-path> -> echoes a non-negative integer, or dies.
# Each branch parses ONLY that runner's own reporter format.
count_for() {
  local runner="$1" path="$2" count=""
  [ -r "$path" ] || die "reporter file not readable for runner '$runner': $path"
  case "$runner" in
    jest|vitest)
      # jest + vitest --reporter=json share a top-level numeric numPassedTests.
      count="$(jq -e '.numPassedTests' "$path" 2>/dev/null)" \
        || die "runner '$runner': reporter at $path has no numeric .numPassedTests"
      ;;
    playwright)
      # `playwright test --list` ends with an authoritative "Total: N tests in M files".
      count="$(grep -oE 'Total: [0-9]+ tests?' "$path" | grep -oE '[0-9]+' | tail -1)"
      ;;
    pytest)
      # `pytest --collect-only -q` ends with "N tests collected in Xs".
      count="$(grep -oE '[0-9]+ tests? collected' "$path" | grep -oE '[0-9]+' | tail -1)"
      ;;
    bats)
      # `bats --count` prints a bare integer.
      count="$(trim "$(cat "$path")")"
      ;;
    python-direct)
      # stdlib unittest prints "Ran N tests in Xs".
      count="$(grep -oE 'Ran [0-9]+ tests?' "$path" | grep -oE '[0-9]+' | tail -1)"
      ;;
    node|bash)
      # ok-line reporters (TAP-lite): a Node harness or a bash smoke script that
      # prints exactly one "ok - <label>" line per PASSED assertion. This is the
      # runner's OWN structured output — counting its ok-lines is reading its reporter,
      # NOT grepping source (the forbidden thing). Matches both md-viewer shapes:
      #   frontmatter.test.mjs -> "ok  - msg"      (Node, no indent)
      #   *-smoke.sh pass()    -> "  ok   - msg"   (bash, 2-space indent)
      # Only trusted on a GREEN run: a failure prints "FAIL -" instead of "ok -", so a
      # red run undercounts — which is why a red run is excluded via red:true, never
      # counted into the estate. Disjoint cascade holds because a parent that delegates
      # to a child with output suppressed (>/dev/null) does not re-print the child's
      # ok-lines, so each script's own ok-count is distinct (md-viewer 33+13+8=54).
      count="$(grep -cE '^[[:space:]]*ok[[:space:]]+-' "$path" || true)"
      ;;
    *)
      die "unknown runner family: '$runner' (supported: jest vitest playwright pytest bats python-direct node bash)"
      ;;
  esac
  is_uint "$count" \
    || die "runner '$runner': could not parse a test count from $path (got '${count}')"
  printf '%s' "$count"
}

# accumulate <bucket-json> <INPUT block> -> echoes the merge-added JSON object.
# Multiple lines with the same type are summed (nested packages -> one byType entry).
accumulate() {
  local bucket="$1" block="$2" line type rest runner path count
  while IFS= read -r line; do
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    [[ "$line" == *:*:* ]] || die "malformed line (need type:runner:path): '$line'"
    type="$(trim "${line%%:*}")"
    rest="${line#*:}"
    runner="$(trim "${rest%%:*}")"
    path="$(trim "${rest#*:}")"
    [ -n "$type" ] || die "malformed line (empty type): '$line'"
    [ -n "$path" ] || die "malformed line (empty reporter path): '$line'"
    count="$(count_for "$runner" "$path")" || exit 1
    bucket="$(jq -c --arg t "$type" --argjson c "$count" '.[$t] = ((.[$t] // 0) + $c)' <<<"$bucket")" \
      || die "failed to merge count for type '$type'"
  done <<<"$block"
  printf '%s' "$bucket"
}

# --- validate required inputs ---
[ -n "$INPUT_REPO" ] || die "missing required input: repo (owner/name)"
[ -n "$INPUT_OUT" ]  || die "missing required input: out (target path)"

# --- byType (additive) ---
byType="$(accumulate '{}' "$INPUT_RUNNERS")" || exit 1
[ "$(jq 'length' <<<"$byType")" -gt 0 ] \
  || die "no runners provided — a producer with zero runner totals is a fail-closed error, not a silent empty stats.json"

# --- declared (executed-but-ungated OR --list-declared) — display-only, NEVER summed ---
# Same type:runner:path format as runners, but held SEPARATE from total/byType so the
# headline never over-counts (the neckarshore-website 308->87 lesson). Optional -> {}.
declared="$(accumulate '{}' "$INPUT_DECLARED")" || exit 1

# --- lenses (overlapping subsets — display-only, NEVER summed into total/byType) ---
lenses="$(accumulate '{}' "$INPUT_LENSES")" || exit 1

# --- total = sum(byType); lenses AND declared deliberately excluded ---
total="$(jq -n --argjson b "$byType" '[$b[]] | add // 0')" || die "failed to compute total"

# --- red / red_detail: a non-green run must not emit a stale-green count ---
# The caller passes its suite/job result (e.g. ${{ job.status }}). Empty or "success"
# (any case) => green. Anything else => red. On red the file is STILL written (with
# red:true) so the aggregator WARNs loudly rather than going blind (fail-closed-visible).
result_lc="$(trim "$INPUT_TEST_RESULT" | tr '[:upper:]' '[:lower:]')"
if [ -z "$result_lc" ] || [ "$result_lc" = "success" ]; then
  red="false"
  red_detail=""
else
  red="true"
  red_detail="$(trim "$INPUT_RED_DETAIL")"
  [ -n "$red_detail" ] || red_detail="test run not green (test_result=${INPUT_TEST_RESULT})"
fi

# --- audited_sha + timestamp ---
sha="$INPUT_SHA"
[ -n "$sha" ] || sha="$(git rev-parse HEAD 2>/dev/null)" || true
[ -n "$sha" ] || die "cannot determine audited_sha (no sha input and 'git rev-parse HEAD' failed)"
updatedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- assemble the contract object ---
# key order: repo, audited_sha, red, red_detail, tests{total,byType,declared,lenses}, [endpoints], updatedAt
result="$(jq -n \
  --arg repo "$INPUT_REPO" \
  --arg sha "$sha" \
  --arg updated "$updatedAt" \
  --argjson red "$red" \
  --arg red_detail "$red_detail" \
  --argjson total "$total" \
  --argjson byType "$byType" \
  --argjson declared "$declared" \
  --argjson lenses "$lenses" \
  '{repo:$repo, audited_sha:$sha, red:$red, red_detail:(if $red then $red_detail else null end),
    tests:{total:$total, byType:$byType, declared:$declared, lenses:$lenses}, updatedAt:$updated}')" \
  || die "failed to assemble stats object"

if [ -n "$INPUT_ENDPOINTS" ]; then
  is_uint "$INPUT_ENDPOINTS" || die "endpoints must be a non-negative integer (got '$INPUT_ENDPOINTS')"
  result="$(jq --argjson ep "$INPUT_ENDPOINTS" '{repo, audited_sha, red, red_detail, tests, endpoints: $ep, updatedAt}' <<<"$result")" \
    || die "failed to add endpoints"
fi

# Write once, only after every handler succeeded — no partial/silent-0 output.
printf '%s\n' "$result" > "$INPUT_OUT" || die "failed to write $INPUT_OUT"
echo "emit-test-stats: wrote $INPUT_OUT (total=$total, red=$red)" >&2
[ "$red" = "true" ] && echo "emit-test-stats: WARNING red run — ${red_detail}" >&2
cat "$INPUT_OUT"
