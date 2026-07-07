#!/usr/bin/env bash
#
# validate-schema.sh — emit representative stats.json outputs from the real fixtures
# and validate each against tests/stats.schema.json (the hardened contract schema).
#
# This is the "schema-validation in the action's own CI" DoD gate: it proves the
# emitter's OUTPUT conforms to the published contract, not just that the counts are
# right (the bats suite covers counts). Uses ajv-cli (draft-07) — see .github/ci.yml.
#
# Run locally: PATH includes `ajv`, then `bash tests/validate-schema.sh`.

set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
SCHEMA="$ROOT/tests/stats.schema.json"
SCRIPT="$ROOT/emit-test-stats.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

AJV="${AJV:-ajv}"
command -v "$AJV" >/dev/null 2>&1 || { echo "validate-schema: '$AJV' not found on PATH" >&2; exit 1; }

export INPUT_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# A — md-viewer 54 (node/bash disjoint), declared {}, green.
INPUT_REPO="neckarshore-mmps/md-viewer" INPUT_OUT="$WORK/a.json" \
INPUT_RUNNERS="unit:node:$FIX/md-viewer/frontmatter.out
integration:bash:$FIX/md-viewer/smoke.out
e2e:bash:$FIX/md-viewer/web-smoke.out" \
INPUT_ENDPOINTS="12" bash "$SCRIPT" >/dev/null || { echo "validate-schema: sample A emit failed" >&2; exit 1; }

# B — declared split (gated 87, declared e2e 293).
INPUT_REPO="neckarshore-ai/neckarshore-website" INPUT_OUT="$WORK/b.json" \
INPUT_RUNNERS="unit:vitest:$FIX/vitest-report.json
unit:python-direct:$FIX/unittest-output.txt" \
INPUT_DECLARED="e2e:playwright:$FIX/declared/website-e2e-list.txt" \
bash "$SCRIPT" >/dev/null || { echo "validate-schema: sample B emit failed" >&2; exit 1; }

# C — red run (still written).
INPUT_REPO="owner/repo" INPUT_OUT="$WORK/c.json" \
INPUT_RUNNERS="unit:bats:$FIX/bats-count.txt" \
INPUT_TEST_RESULT="failure" INPUT_RED_DETAIL="1 failed: test_parser_against_real_source" \
bash "$SCRIPT" >/dev/null || { echo "validate-schema: sample C emit failed" >&2; exit 1; }

echo "validate-schema: validating A/B/C against $(basename "$SCHEMA")"
"$AJV" validate -s "$SCHEMA" -d "$WORK/a.json" -d "$WORK/b.json" -d "$WORK/c.json"
