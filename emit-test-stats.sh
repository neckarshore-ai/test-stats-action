#!/usr/bin/env bash
#
# emit-test-stats.sh — the transform core of the test-stats-action composite action.
#
# Maps a test runner's OWN native reporter output to the estate stats.json contract:
#   neckarshore-planning/docs/reference/stats-json-contract.md
#
# Counts come from each runner's own reporter — NEVER from grepping source for test()
# calls (the 3.7k-vs-74 lesson: grep counted ~3.7k test() hits for a suite the runner
# reported as 74). The five global constraints, enforced below:
#   1. runner-reported, never grep                4. fail-closed-visible (no silent 0)
#   2. total == sum(byType); lenses NEVER summed   5. exact tool versions (jq/git/date, runner-provided)
#   3. audited_sha + repo always present
#
# Driven entirely by INPUT_* env vars so action.yml is a thin wrapper and this script
# is testable in isolation by tests/emit-test-stats.bats. Every checkable decision is
# here, not in action.yml.

set -o pipefail

# --- optional inputs default to empty so unset is never an error ---
INPUT_REPO="${INPUT_REPO:-}"
INPUT_OUT="${INPUT_OUT:-}"
INPUT_RUNNERS="${INPUT_RUNNERS:-}"
INPUT_LENSES="${INPUT_LENSES:-}"
INPUT_ENDPOINTS="${INPUT_ENDPOINTS:-}"
INPUT_SHA="${INPUT_SHA:-}"

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
    *)
      die "unknown runner family: '$runner' (supported: jest vitest playwright pytest bats python-direct)"
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

# --- lenses (overlapping subsets — display-only, NEVER summed into total/byType) ---
lenses="$(accumulate '{}' "$INPUT_LENSES")" || exit 1

# --- total = sum(byType); lenses deliberately excluded ---
total="$(jq -n --argjson b "$byType" '[$b[]] | add // 0')" || die "failed to compute total"

# --- audited_sha + timestamp ---
sha="$INPUT_SHA"
[ -n "$sha" ] || sha="$(git rev-parse HEAD 2>/dev/null)" || true
[ -n "$sha" ] || die "cannot determine audited_sha (no sha input and 'git rev-parse HEAD' failed)"
updatedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- assemble the contract object (key order: repo, audited_sha, tests, [endpoints], updatedAt) ---
result="$(jq -n \
  --arg repo "$INPUT_REPO" \
  --arg sha "$sha" \
  --arg updated "$updatedAt" \
  --argjson total "$total" \
  --argjson byType "$byType" \
  --argjson lenses "$lenses" \
  '{repo:$repo, audited_sha:$sha, tests:{total:$total, byType:$byType, lenses:$lenses}, updatedAt:$updated}')" \
  || die "failed to assemble stats object"

if [ -n "$INPUT_ENDPOINTS" ]; then
  is_uint "$INPUT_ENDPOINTS" || die "endpoints must be a non-negative integer (got '$INPUT_ENDPOINTS')"
  result="$(jq --argjson ep "$INPUT_ENDPOINTS" '{repo, audited_sha, tests, endpoints: $ep, updatedAt}' <<<"$result")" \
    || die "failed to add endpoints"
fi

# Write once, only after every handler succeeded — no partial/silent-0 output.
printf '%s\n' "$result" > "$INPUT_OUT" || die "failed to write $INPUT_OUT"
echo "emit-test-stats: wrote $INPUT_OUT (total=$total)" >&2
cat "$INPUT_OUT"
