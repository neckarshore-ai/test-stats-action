# test-stats-action

A reusable GitHub **composite action** that maps a test runner's **native reporter
output** to the estate [`stats.json` contract](https://github.com/neckarshore-ai/neckarshore-planning/blob/main/docs/reference/stats-json-contract.md).

It is the **transform** half of the estate test-scope pipeline. The design decision
that matters: **centralize the transform, not the test-run.** Each repo already runs
its own suites in its own CI with its own install/build/test commands — that part is
not generalizable and stays per-repo. What *is* generalizable is the thin step that
maps a runner's reporter output to the contract JSON. That ships here, once, with one
handler per runner family. When the contract evolves, it changes in one place (AP-1:
ADD, never REPLACE-in-N-repos).

**The number moves on its own (PR-following):** each repo regenerates its `stats.json`
in its own CI, so when a PR adds or removes tests the estate number moves without any
central re-run. **No grep, ever** — counts come from each runner's own reporter (the
3.7k-vs-74 lesson: grep counted ~3.7k `test()` hits for a suite the runner reported as 74).

## Usage

Run your suite, point the action at the reporter output:

```yaml
- uses: actions/checkout@v5            # required: audited_sha = git rev-parse HEAD
  # ... install + run your suites, emitting each runner's native reporter to a file ...

- uses: neckarshore-ai/test-stats-action@v1
  with:
    repo: ${{ github.repository }}     # owner/name (default: the current repo)
    out: stats.json                    # where to write (the repo's statsPath)
    runners: |                         # one line per distinct runner total -> byType (additive)
      unit:vitest:reports/vitest.json
      e2e:playwright:reports/pw-list.txt
    lenses: |                          # optional: overlapping subsets -> display-only, NEVER summed
      accessibility:playwright:reports/a11y-list.txt
    endpoints: '96'                    # optional: API count for the tile facet (omitted if empty)
```

Then commit the emitted `stats.json` (typically only on `main`).

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `repo` | yes (default `${{ github.repository }}`) | `owner/name` — the canonical GitHub slug. |
| `out` | yes (default `stats.json`) | Target path to write (the repo's `statsPath`). |
| `runners` | yes | One `type:runner:reporterpath` line per distinct runner total → `tests.byType`. Same-type lines are merge-added. |
| `lenses` | no | One `type:runner:reporterpath` line per overlapping subset → `tests.lenses`. **Display-only, never summed.** |
| `endpoints` | no | API endpoint count for the tile facet. Omitted from output when empty. |
| `sha` | no | `audited_sha` override. Defaults to `git rev-parse HEAD`. |

## Supported runners

Each handler parses **only** that runner's own reporter format. Produce the reporter
file in your CI, then name it in a `runners:` line.

| Runner | How to produce the reporter file | What the handler reads |
|--------|----------------------------------|------------------------|
| `jest` | `jest --json --outputFile=r.json` | top-level `.numPassedTests` |
| `vitest` | `vitest run --reporter=json --outputFile=r.json` | top-level `.numPassedTests` (jest-compatible) |
| `playwright` | `playwright test --list > r.txt` | the `Total: N tests in M files` summary line |
| `pytest` | `pytest --collect-only -q > r.txt` | the `N tests collected` summary line |
| `bats` | `bats --count tests/ > r.txt` | the bare integer |
| `python-direct` | `python -m unittest ... > r.txt 2>&1` | the `Ran N tests` summary line |

> **Count semantics:** the jest/vitest handlers count `numPassedTests` — tests that ran
> and passed, **excluding `.skip`/`.todo`**. This matches the reference producer
> (`omnopsis-backend`). On a green CI run `numPassedTests == numTotalTests` (any failure
> would already make CI red). Repos with deliberately-skipped tests should confirm their
> reconciliation target counts the same way.

## Contract guarantees (enforced by the fixture tests)

1. **Runner-reported, never grep** — one handler per runner, parsing the runner's own output.
2. **`tests.total == sum(values of tests.byType)`** — additive, distinct runner totals only.
3. **`tests.lenses` are display-only** — overlapping subsets, **never** summed into `total`/`byType`.
4. **`audited_sha` + `repo` always present** — the count is auditable + reproducible.
5. **Fail-closed-visible** — a missing/unparseable reporter, an unknown runner, an empty
   producer, or a malformed line **exits non-zero and writes no `stats.json`**. Never a
   silent `0` that quietly drops the public number.

## Fixtures provenance

Every fixture under [`tests/fixtures/`](tests/fixtures) is **real captured reporter
output**, not hand-authored — a fabricated fixture would encode a wrong mental model that
passes here and fails live. Sources (captured 2026-06-21):

| Fixture | Source | Count |
|---------|--------|-------|
| `jest-report.json` | `omnopsis-backend` integration suite, `jest --json` | 27 |
| `golden/{unit,integration,e2e}.json` | `omnopsis-backend` three suites (real summaries) | 302 / 27 / 255 → **584** |
| `vitest-report.json` | `omnopsis-contracts` `vitest run --reporter=json` | 85 |
| `playwright-list.txt` | `neckarshore-website` `playwright test --list` | 197 |
| `pytest-collect.txt` | real `pytest 9.1.1 --collect-only -q` | 5 |
| `bats-count.txt` | `dev-environment` `bats --count tests/` | 82 |
| `unittest-output.txt` | real `python -m unittest` | 2 |

The **golden conformance fixture** is `omnopsis-backend`: the action reproduces its live
`backend/stats.json` `byType` (302 / 27 / 255 = **584**) exactly.

> **`audited_sha` makes the number SHA-aware, not fixed.** The reference repo `omnopsis-contracts`
> was Lenin-audited at **81** @ `d53a95f`; the action emits **85** @ `bcc5b9d` because the
> post-audit commit `e9dfa9b` added 4 real tests (`event-type-coverage.test.ts`). `85 = 81 + 4`,
> fully explained by `audited_sha` — this is the PR-following design working, not a producer bug.

## Development

```bash
npm install -g bats@1.13.0   # pinned, exact
bats tests/emit-test-stats.bats
shellcheck emit-test-stats.sh
```

## License

[MIT](LICENSE).
