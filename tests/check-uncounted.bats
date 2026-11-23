#!/usr/bin/env bats
#
# Check (c), planning #4209 section 6: a test-runner invocation in a `run:` block of the
# producer's workflows, or one level down in a package.json script it calls, whose output
# file is not named in runners:, declared: or lenses:, and whose step carries no
# `# test-stats: uncounted <reason>` marker. Warn-only until the binding date.
#
# Fixtures here are authored workflow files, not runner output: the check reads YAML and
# package.json, so the shapes below are the input, written small enough to read.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$ROOT/check-uncounted.sh"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS/.github/workflows"
  export TSA_WORKSPACE="$WS"
  export INPUT_RUNNERS="e2e:playwright-json:/tmp/pw.json"
  export INPUT_DECLARED=""
  export INPUT_LENSES=""
  unset UNCOUNTED_MODE GITHUB_STEP_SUMMARY
}

wf() { cat > "$WS/.github/workflows/$1"; }
warnings() { printf '%s\n' "$output" | grep -c '^::warning' || true; }

@test "a direct runner invocation whose output is not named warns, with file and line" {
  wf ci.yml <<'EOF'
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: e2e
        run: npx playwright test
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(warnings)" -eq 1 ]
  [[ "$output" == *"file=.github/workflows/ci.yml,line=7"* ]]
  [[ "$output" == *"playwright"* ]]
}

@test "the configured path on the invocation line counts it: no warning" {
  wf ci.yml <<'EOF'
jobs:
  e2e:
    steps:
      - run: PLAYWRIGHT_JSON_OUTPUT_FILE=/tmp/pw.json npx playwright test --reporter=json
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(warnings)" -eq 0 ]
}

@test "the basename counts when the emit job reads a downloaded artifact" {
  export INPUT_RUNNERS="e2e:playwright-json:art/results.json"
  wf ci.yml <<'EOF'
jobs:
  e2e:
    steps:
      - run: npx playwright test --reporter=json > results.json
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "a basename only counts as a whole name, not as the tail of another file" {
  export INPUT_RUNNERS="e2e:playwright-json:art/r.json"
  wf ci.yml <<'EOF'
jobs:
  e2e:
    steps:
      - run: npx playwright test --reporter=json > bar.json
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 1 ]
}

@test "a path named in the step's env: block counts" {
  wf ci.yml <<'EOF'
jobs:
  e2e:
    steps:
      - name: e2e
        env:
          PLAYWRIGHT_JSON_OUTPUT_FILE: /tmp/pw.json
        run: |
          npx playwright test --reporter=json
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "paths in declared: and lenses: count too" {
  export INPUT_RUNNERS="unit:jest:/tmp/j.json"
  export INPUT_DECLARED="e2e:playwright:/tmp/list.out"
  export INPUT_LENSES="smoke:vitest:/tmp/v.json"
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx jest --json --outputFile=/tmp/j.json
      - run: npx playwright test --list > /tmp/list.out
      - run: npx vitest run --reporter=json > /tmp/v.json
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "the marker with a reason silences the step; a marker without a reason does not" {
  wf ci.yml <<'EOF'
jobs:
  prod:
    steps:
      # test-stats: uncounted a monitor against production, not a gate
      - run: npx playwright test --project=prod
      - name: second
        # test-stats: uncounted
        run: npx playwright test --project=other
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 1 ]
  [[ "$output" == *"line=8"* ]]
  [[ "$output" == *"marker without a reason"* ]]
}

@test "the marker inside the run block counts for its step" {
  wf ci.yml <<'EOF'
jobs:
  prod:
    steps:
      - run: |
          # test-stats: uncounted smoke against the deployed site
          npx playwright test
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "each of the seven runner patterns warns in command position" {
  export INPUT_RUNNERS="unit:jest:/tmp/none.json"
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx jest
      - run: pnpm exec vitest run
      - run: npx playwright test
      - run: python -m pytest tests/
      - run: bats tests/
      - run: node --test tests/*.test.mjs
      - run: npx tsx tests/run.ts
      - run: cd app && ./node_modules/.bin/jest --ci
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 8 ]
}

@test "installs, version calls and mentions are not invocations" {
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx playwright install --with-deps chromium
      - run: pip install pytest==9.2.0
      - run: sudo npm install -g bats@1.13.0
      - run: bats --version
      - run: echo "now run pytest and jest"
      - run: npm i -D vitest@3.0.0
      - uses: some/pytest-action@v1
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "pytest -v is verbose, not a version call" {
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: pytest -v tests/
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 1 ]
}

@test "one level down: npm run resolves the script in package.json" {
  cat > "$WS/package.json" <<'EOF'
{ "scripts": { "test:e2e": "playwright test", "build": "next build", "test": "jest --ci" } }
EOF
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npm run test:e2e
      - run: npm run build
      - run: npm test
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 2 ]
  [[ "$output" == *"test:e2e"* ]]
}

@test "one level down: the configured path inside the script body counts" {
  cat > "$WS/package.json" <<'EOF'
{ "scripts": { "test:e2e": "PLAYWRIGHT_JSON_OUTPUT_FILE=/tmp/pw.json playwright test --reporter=json" } }
EOF
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npm run test:e2e
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "working-directory at step, job default and cd resolves the right package.json" {
  mkdir -p "$WS/web" "$WS/api"
  echo '{ "scripts": { "test": "vitest run" } }' > "$WS/web/package.json"
  echo '{ "scripts": { "test": "echo none" } }' > "$WS/package.json"
  echo '{ "scripts": { "test": "jest" } }' > "$WS/api/package.json"
  wf ci.yml <<'EOF'
jobs:
  web:
    defaults:
      run:
        working-directory: web
    steps:
      - run: npm test
  root:
    steps:
      - run: npm test
      - run: cd api && npm test
      - name: step level
        working-directory: api
        run: yarn test
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 3 ]
}

@test "a continued line is read as one command" {
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: |
          npx playwright test \
            --reporter=json > /tmp/pw.json
EOF
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "every finding also goes to the step summary" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx jest
      - run: bats tests/
EOF
  run bash "$SCRIPT"
  [ "$(grep -c 'ci.yml' "$GITHUB_STEP_SUMMARY")" -eq 2 ]
}

@test "fail mode: a finding exits non-zero" {
  export UNCOUNTED_MODE=fail
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx jest
EOF
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fail mode: no finding exits zero" {
  export UNCOUNTED_MODE=fail
  wf ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: echo ok
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "an unknown mode is refused" {
  export UNCOUNTED_MODE=off
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "warn mode: no workflows directory is a visible warning, exit 0" {
  rm -rf "$WS/.github"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning"*"could not run"* ]]
}

@test "fail mode: no workflows directory fails" {
  export UNCOUNTED_MODE=fail
  rm -rf "$WS/.github"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "warn mode: malformed YAML and a broken package.json never fail the step" {
  printf 'jobs:\n  a:\n    steps:\n      - run: |\n\t\x01 npm test\n  : : [\n' > "$WS/.github/workflows/bad.yml"
  echo '{ not json' > "$WS/package.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the action runs check (c) after the emit step, so a broken check cannot cost stats.json" {
  emit=$(grep -n 'emit-test-stats.sh' "$ROOT/action.yml" | head -1 | cut -d: -f1)
  check=$(grep -n 'check-uncounted.sh' "$ROOT/action.yml" | head -1 | cut -d: -f1)
  [ -n "$emit" ] && [ -n "$check" ] && [ "$emit" -lt "$check" ]
}

@test "a file the step derives the counted file from counts (dev-environment stats.yml shape)" {
  export INPUT_RUNNERS="unit:node:reports/node.ok"
  wf ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: |
          if node --test --test-reporter=tap tests/*.test.mjs > reports/node.tap 2>&1; then R=success; fi
          grep -E '^ok [0-9]+ - ' reports/node.tap > reports/node.ok
YML
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}

@test "a second, uncounted runner in a step that names another path still warns (md-viewer emit shape)" {
  export INPUT_RUNNERS="e2e:playwright:/tmp/playwright.out"
  wf ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: |
          npx playwright test --list > /tmp/playwright.out 2>&1 || true
          (cd converter && uv run pytest --collect-only -q) > /tmp/converter.out 2>&1 || true
YML
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 1 ]
  [[ "$output" == *"line=6"* ]]
}

@test "a separator inside quotes does not start a command (obsidian-vault-autopilot shape)" {
  wf ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: globs=$(grep -hoE 'node --test [^ ]+' scripts/t.sh | sed 's|node --test ||')
YML
  run bash "$SCRIPT"
  [ "$(warnings)" -eq 0 ]
}
