#!/usr/bin/env bats
#
# Fixture tests for emit-test-stats.sh — one assertion per runner family fed its
# OWN native reporter output (never grep), plus the contract invariants:
#   - tests.total === sum(values of tests.byType)
#   - repo + audited_sha always present
#   - lenses (overlapping subsets) NEVER summed into total/byType
#   - declared (executed-but-ungated) NEVER summed into total/byType
#   - red/red_detail: a non-green run emits red:true and STILL writes the file
#   - fail-closed-visible: a missing/unparseable reporter exits non-zero, no silent 0
#
# Every fixture under tests/fixtures/ is REAL captured reporter output (see README
# § Fixtures provenance), not hand-authored — a fabricated fixture would encode a
# wrong mental model that passes here and fails live. (The one exception, documented
# in the provenance table, is the declared-split shape fixture: real playwright --list
# FORMAT with an illustrative count, exercising the split mechanic, not the parser.)

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  FIX="$BATS_TEST_DIRNAME/fixtures"
  SCRIPT="$ROOT/emit-test-stats.sh"
  OUT="$BATS_TEST_TMPDIR/stats.json"
  export INPUT_REPO="owner/repo"
  export INPUT_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" # deterministic; real CI uses git rev-parse HEAD
  export INPUT_OUT="$OUT"
}

# ---- per-runner-family count handlers (each reads that runner's own reporter) ----

@test "jest handler counts numPassedTests from a real jest --json report" {
  export INPUT_RUNNERS="unit:jest:$FIX/jest-report.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 27 ]
}

@test "vitest handler counts numPassedTests from a real vitest --reporter=json report" {
  export INPUT_RUNNERS="unit:vitest:$FIX/vitest-report.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 85 ]
}

@test "playwright handler counts 'Total: N tests' from a real --list text report" {
  export INPUT_RUNNERS="e2e:playwright:$FIX/playwright-list.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.e2e' "$OUT")" -eq 197 ]
}

@test "pytest handler counts 'N tests collected' from a real --collect-only -q report" {
  export INPUT_RUNNERS="unit:pytest:$FIX/pytest-collect.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 5 ]
}

@test "bats handler counts the bare integer from a real bats --count report" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 82 ]
}

@test "python-direct handler counts 'Ran N tests' from a real unittest report" {
  export INPUT_RUNNERS="unit:python-direct:$FIX/unittest-output.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 2 ]
}

# ---- contract invariants ----

@test "contract: total equals sum(byType) across mixed runners" {
  export INPUT_RUNNERS="unit:jest:$FIX/jest-report.json
e2e:playwright:$FIX/playwright-list.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 224 ]            # 27 + 197
  [ "$(jq '.tests.total == ([.tests.byType[]] | add)' "$OUT")" = "true" ]
}

@test "contract: repo and audited_sha are always present" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repo' "$OUT")" = "owner/repo" ]
  [ "$(jq -r '.audited_sha' "$OUT")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
  [ "$(jq -r '.tests.lenses' "$OUT")" = "{}" ]
  [ "$(jq -e '.updatedAt' "$OUT")" ]
}

@test "merge-add: two lines of the same type sum into one byType entry" {
  export INPUT_RUNNERS="unit:jest:$FIX/jest-report.json
unit:vitest:$FIX/vitest-report.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 112 ]      # 27 + 85
  [ "$(jq '.tests.total' "$OUT")" -eq 112 ]
}

@test "lenses are display-only: counted into lenses, NEVER into total or byType" {
  export INPUT_RUNNERS="unit:vitest:$FIX/vitest-report.json"
  export INPUT_LENSES="accessibility:playwright:$FIX/playwright-list.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 85 ]             # lens 197 excluded
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 85 ]
  [ "$(jq '.tests.byType | has("accessibility")' "$OUT")" = "false" ]
  [ "$(jq '.tests.lenses.accessibility' "$OUT")" -eq 197 ]
}

@test "endpoints input is included when provided" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  export INPUT_ENDPOINTS="96"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.endpoints' "$OUT")" -eq 96 ]
}

@test "endpoints key is omitted when not provided" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("endpoints")' "$OUT")" = "false" ]
}

# ---- the golden conformance fixture: omnopsis-backend's real reporter output ----

@test "golden fixture: backend's three jest reports reproduce byType 302/27/255 and total 584" {
  export INPUT_REPO="omnopsis-ai/omnopsis-backend"
  export INPUT_RUNNERS="unit:jest:$FIX/golden/unit.json
integration:jest:$FIX/golden/integration.json
e2e:jest:$FIX/golden/e2e.json"
  export INPUT_ENDPOINTS="96"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 302 ]
  [ "$(jq '.tests.byType.integration' "$OUT")" -eq 27 ]
  [ "$(jq '.tests.byType.e2e' "$OUT")" -eq 255 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 584 ]
}

# ---- fail-closed-visible (D4): never a silent 0 ----

@test "fail-closed: a missing reporter file exits non-zero and writes no stats" {
  export INPUT_RUNNERS="unit:jest:$FIX/does-not-exist.json"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

@test "fail-closed: a jest report without numPassedTests exits non-zero" {
  echo '{"numTotalTests": 5}' > "$BATS_TEST_TMPDIR/bad.json"
  export INPUT_RUNNERS="unit:jest:$BATS_TEST_TMPDIR/bad.json"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

@test "fail-closed: an unknown runner family exits non-zero" {
  export INPUT_RUNNERS="unit:mocha:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

@test "fail-closed: a malformed runners line (no type) exits non-zero" {
  export INPUT_RUNNERS="$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

@test "fail-closed: empty runners (no producers) exits non-zero" {
  export INPUT_RUNNERS=""
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

# ---- node / bash ok-line handlers (TAP-lite; md-viewer's real reporters) ----

@test "node handler counts 'ok - ' lines from a real node harness report" {
  export INPUT_RUNNERS="unit:node:$FIX/md-viewer/frontmatter.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 8 ]
}

@test "bash handler counts '  ok   - ' lines from a real bash smoke report" {
  export INPUT_RUNNERS="e2e:bash:$FIX/md-viewer/web-smoke.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.e2e' "$OUT")" -eq 33 ]
}

# ---- golden fixture A: md-viewer 54 (node/bash, disjoint cascade) ----

@test "golden A: md-viewer reproduces total 54 = 8/13/33 disjoint, declared {}, red false" {
  export INPUT_REPO="neckarshore-mmps/md-viewer"
  export INPUT_RUNNERS="unit:node:$FIX/md-viewer/frontmatter.out
integration:bash:$FIX/md-viewer/smoke.out
e2e:bash:$FIX/md-viewer/web-smoke.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 8 ]
  [ "$(jq '.tests.byType.integration' "$OUT")" -eq 13 ]
  [ "$(jq '.tests.byType.e2e' "$OUT")" -eq 33 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 54 ]
  [ "$(jq '.tests.declared' "$OUT")" = "{}" ]
  [ "$(jq '.red' "$OUT")" = "false" ]
  [ "$(jq '.red_detail' "$OUT")" = "null" ]
}

# ---- golden fixture B: the declared split (87 gated / 293 declared) ----

@test "golden B: gated 87 total, declared e2e 293 held SEPARATE (never summed)" {
  export INPUT_REPO="neckarshore-ai/neckarshore-website"
  export INPUT_RUNNERS="unit:vitest:$FIX/vitest-report.json
unit:python-direct:$FIX/unittest-output.txt"
  export INPUT_DECLARED="e2e:playwright:$FIX/declared/website-e2e-list.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 87 ]              # 85 + 2, gated only
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 87 ]
  [ "$(jq '.tests.declared.e2e' "$OUT")" -eq 293 ]      # the 293 is NOT in total
  [ "$(jq '.tests.byType | has("e2e")' "$OUT")" = "false" ]
  [ "$(jq '.tests.total == ([.tests.byType[]] | add)' "$OUT")" = "true" ]
}

# ---- golden fixture C: red run still writes ----

@test "golden C: a red test_result yields red:true + non-null red_detail, file still written" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  export INPUT_TEST_RESULT="failure"
  export INPUT_RED_DETAIL="1 failed: test_parser_against_real_source"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]                                          # STILL written on red (WARN, not blind)
  [ "$(jq '.red' "$OUT")" = "true" ]
  [ "$(jq -r '.red_detail' "$OUT")" = "1 failed: test_parser_against_real_source" ]
  [ "$(jq '.tests.total' "$OUT")" -eq 82 ]              # the count is still emitted for the WARN
}

# ---- declared + red invariants ----

@test "declared is display-only: counted into declared, NEVER into total or byType" {
  export INPUT_RUNNERS="unit:vitest:$FIX/vitest-report.json"
  export INPUT_DECLARED="e2e:playwright:$FIX/playwright-list.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 85 ]              # declared 197 excluded
  [ "$(jq '.tests.byType | has("e2e")' "$OUT")" = "false" ]
  [ "$(jq '.tests.declared.e2e' "$OUT")" -eq 197 ]
}

@test "declared is {} when not provided" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.declared' "$OUT")" = "{}" ]
}

@test "red defaults to false with null red_detail when test_result unset (backward compat)" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.red' "$OUT")" = "false" ]
  [ "$(jq '.red_detail' "$OUT")" = "null" ]
}

@test "red: a 'success' test_result (any case) is green, red_detail forced null" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  export INPUT_TEST_RESULT="SUCCESS"
  export INPUT_RED_DETAIL="ignored on green"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.red' "$OUT")" = "false" ]
  [ "$(jq '.red_detail' "$OUT")" = "null" ]
}

@test "red: a red run with no red_detail synthesizes a non-null detail" {
  export INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt"
  export INPUT_TEST_RESULT="failure"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.red' "$OUT")" = "true" ]
  [ "$(jq -r '.red_detail' "$OUT")" != "null" ]
  [ -n "$(jq -r '.red_detail' "$OUT")" ]
}

# ---- node-test handler (node --test summary; TAP + spec shapes) ----
#
# BOTH shapes are live in the estate and both must parse: `node --test` picks its
# default reporter by node version when piped — node 20 (what the website CI jobs
# pin) emits TAP (`# pass N`), node 22+ emits spec (`ℹ pass N`). Counting only one
# shape breaks silently on a node bump.

@test "node-test handler counts the TAP summary from a real node --test report" {
  export INPUT_RUNNERS="unit:node-test:$FIX/goldoni/lighthouse-unit-tap.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 6 ]
}

@test "node-test handler counts the spec summary from a real node --test report" {
  export INPUT_RUNNERS="unit:node-test:$FIX/goldoni/lighthouse-unit-spec.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 6 ]
}

# The reason the handler parses the SUMMARY and never the ok-lines: this real red
# fixture prints 3 `ok N -` lines for 4 tests (1 failed). ok-line counting also
# double-counts nested describes, which the summary is immune to.
@test "node-test handler parses the summary, NOT the ok-lines (red fixture: 3 ok-lines, summary pass 3 / fail 1)" {
  [ "$(grep -cE '^[[:space:]]*ok [0-9]' "$FIX/node-test-red.out")" -eq 3 ]
  export INPUT_RUNNERS="unit:node-test:$FIX/node-test-red.out"
  export INPUT_TEST_RESULT="failure"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 3 ]
}

@test "node-test RED: a run with fail>0 in its own summary emits red:true and STILL writes the file" {
  export INPUT_RUNNERS="unit:node-test:$FIX/node-test-red.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ "$(jq -r '.red' "$OUT")" = "true" ]
  [ "$(jq -r '.red_detail' "$OUT")" != "null" ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 3 ]
}

@test "fail-closed: node-test output with no summary at all exits non-zero" {
  printf 'some noise\nno summary here\n' > "$BATS_TEST_TMPDIR/nosummary.out"
  export INPUT_RUNNERS="unit:node-test:$BATS_TEST_TMPDIR/nosummary.out"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

# ---- tsx handler (bespoke `<N> passed, <M> failed` summary) ----

@test "tsx handler counts a labeled summary line from a real tsx report" {
  export INPUT_RUNNERS="unit:tsx:$FIX/goldoni/search-index-data.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 9 ]
}

# oakwood's `test:blog:unit` chains three tsx files with `&&`; each prints its own
# unlabeled summary line into one output, and interleaves unrelated log noise.
@test "tsx handler SUMS multiple unlabeled summary lines and ignores interleaved noise" {
  export INPUT_RUNNERS="unit:tsx:$FIX/oakwood/blog-unit.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 29 ]
}

@test "tsx RED: a real failing suite emits red:true, counts only the passes, still writes" {
  export INPUT_RUNNERS="unit:tsx:$FIX/oakwood/search-index-data-red.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ "$(jq -r '.red' "$OUT")" = "true" ]
  [ "$(jq -r '.red_detail' "$OUT")" != "null" ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 4 ]
}

@test "fail-closed: tsx output with no summary line exits non-zero" {
  printf 'ran some things\nbut printed no summary\n' > "$BATS_TEST_TMPDIR/nosummary.out"
  export INPUT_RUNNERS="unit:tsx:$BATS_TEST_TMPDIR/nosummary.out"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
}

# ---- no-silent-zero guard (red-aware) ----
#
# The bug class this action exists to prevent, in both directions. A GREEN run that
# parses 0 from non-empty reporter output is a mis-wired runner (bad glob, wrong
# adapter, a suite that never ran) and must fail LOUDLY. A RED run that parses 0 is
# legitimate (the suite crashed/aborted) and must STILL emit red:true — dying there
# would blind the aggregator exactly when it most needs the signal.

@test "no-silent-zero: a GREEN run parsing 0 tests from non-empty output exits non-zero" {
  printf 'v dist smoke passed - nothing this adapter can count\n' > "$BATS_TEST_TMPDIR/zero.out"
  export INPUT_RUNNERS="unit:node:$BATS_TEST_TMPDIR/zero.out"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT" ]
  [[ "$output" == *"silent zero"* ]]
}

@test "no-silent-zero: a RED run parsing 0 tests STILL emits (red:true), never dies" {
  printf 'x dist smoke FAILED (1):\n  - barrel is non-empty\n' > "$BATS_TEST_TMPDIR/zero.out"
  export INPUT_RUNNERS="unit:node:$BATS_TEST_TMPDIR/zero.out"
  export INPUT_TEST_RESULT="failure"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ "$(jq -r '.red' "$OUT")" = "true" ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 0 ]
}

# ---- golden fixture D: goldoni 35 (the adapter gap, closed) ----
#
# GOLDEN BASELINE, not a hand-picked number: every fixture below is goldoni-website's
# OWN reporter output captured at 401cdf5, and 35 is the disjoint own-runner total
# independently measured by Lenin at 1d55153 (report 2026-07-17-lenin-phase1-verify-queue,
# `goldoni_website.disjoint_true`). The emitter previously reported 20 — the entire
# CI-gated unit half (unit.yml: lighthouse 6 + search 9) fell silently on the floor
# because neither runner had an adapter. This test is what proves the gap is closed.

@test "golden D: goldoni reproduces total 35 = e2e 20 + unit 15 (6 node-test + 9 tsx), red false" {
  export INPUT_REPO="neckarshore-websites/goldoni-website"
  export INPUT_RUNNERS="e2e:playwright:$FIX/goldoni/e2e-list.out
unit:node-test:$FIX/goldoni/lighthouse-unit-tap.out
unit:tsx:$FIX/goldoni/search-index-data.out"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.tests.byType.e2e' "$OUT")" -eq 20 ]
  [ "$(jq '.tests.byType.unit' "$OUT")" -eq 15 ]
  [ "$(jq '.tests.total' "$OUT")" -eq 35 ]
  [ "$(jq '.tests.total' "$OUT")" -eq "$(jq '[.tests.byType[]] | add' "$OUT")" ]
  [ "$(jq -r '.red' "$OUT")" = "false" ]
  [ "$(jq -c '.tests.declared' "$OUT")" = "{}" ]
}
