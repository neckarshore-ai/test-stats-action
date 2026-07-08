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
