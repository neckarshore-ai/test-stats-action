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
    runners: |                         # GATED, disjoint runner totals -> byType (additive) -> total
      unit:vitest:reports/vitest.json
      e2e:playwright:reports/pw-list.txt
    declared: |                        # optional: executed-but-UNGATED / --list-only -> tests.declared, NEVER in total
      e2e:playwright:reports/ungated-e2e-list.txt
    lenses: |                          # optional: overlapping subsets -> display-only, NEVER summed
      accessibility:playwright:reports/a11y-list.txt
    endpoints: '96'                    # optional: API count for the tile facet (omitted if empty)
    test_result: ${{ job.status }}     # optional: non-green => red:true (file still written)
```

Then commit the emitted `stats.json` (typically only on `main`).

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `repo` | yes (default `${{ github.repository }}`) | `owner/name` — the canonical GitHub slug. |
| `out` | yes (default `stats.json`) | Target path to write (the repo's `statsPath`). |
| `runners` | yes | One `type:runner:reporterpath` line per **gated, disjoint** runner total → `tests.byType` → `tests.total`. Same-type lines are merge-added. Pass **only** what your CI actually gates on (see `total` below). |
| `declared` | no | One `type:runner:reporterpath` line per **executed-but-ungated** or `--list`-only total → `tests.declared`. **Display-only, never summed into `total`/`byType`.** |
| `lenses` | no | One `type:runner:reporterpath` line per overlapping subset → `tests.lenses`. **Display-only, never summed.** |
| `endpoints` | no | API endpoint count for the tile facet. Omitted from output when empty. |
| `sha` | no | `audited_sha` override. Defaults to `git rev-parse HEAD`. |
| `test_result` | no | The suite/job result (typically `${{ job.status }}`). Empty or `success` (any case) → `red:false`; anything else → `red:true` (the file is **still written**, so the aggregator WARNs rather than going blind). |
| `red_detail` | no | One line naming the failure, emitted as `red_detail` when red. Forced to `null` on a green run; a generic detail is synthesized if omitted on a red run. |

### `total` = executed AND CI-gated AND disjoint

`tests.total` (= `sum(tests.byType)`) is your repo's **additive** contribution to the estate
number, and it is **only** counts that are all three of:

1. **Executed** — the runner actually ran them (a reporter total, never a `grep` of source).
2. **CI-gated** — a red suite fails your CI. A suite that runs in **no** CI job (or only via
   `--list`) is **not** gated → it goes in `declared`, **not** `runners`. This is the
   neckarshore-website **308 → 87** fix: ~293 ungated e2e belong in `declared`, out of the headline.
3. **Disjoint** — no double-counting. `byType` holds distinct runner totals; overlapping subsets
   go in `lenses`. See the cascade note below for the inverse trap.

You decide which runner lines are gated — that knowledge lives in your CI, so it lives in your
`runners:` vs `declared:` split, not in this action.

### Disjoint cascade (the md-viewer 54 example)

When a parent suite **delegates** to a child with the child's output suppressed (`>/dev/null`)
or re-emitted as a single "child passed" line, the child's assertions are **not** in the parent's
printed total → they are **disjoint** → count **both** as distinct `runners` lines:

```yaml
runners: |
  unit:node:reports/frontmatter.out        # frontmatter.test.mjs      -> 8  (nested, output hidden)
  integration:bash:reports/smoke.out       # smoke.sh                  -> 13 (nested, output hidden)
  e2e:bash:reports/web-smoke.out           # web-smoke.sh (own output) -> 33
# tests.total == 54, byType == { unit: 8, integration: 13, e2e: 33 }
```

`33 + 13 + 8 = 54`, **not** 33 — each script's own reporter prints only its own `ok -` lines.
Only collapse into one number when a single command's printed total **visibly** re-includes the
child's assertions.

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
| `node` | `node your-test.mjs > r.txt` | count of TAP-lite `ok - <label>` lines (a hand-rolled Node harness) |
| `node-test` | `node --test path/to/*.test.mjs > r.txt 2>&1` | the `node --test` **summary**: `# pass N` (TAP) or `ℹ pass N` (spec) |
| `tsx` | `tsx your.test.ts > r.txt 2>&1` | the bespoke `<N> passed, <M> failed` summary, one line per test file (summed) |
| `bash` | `./your-smoke.sh > r.txt` | count of TAP-lite `  ok   - <label>` lines (a bash smoke script) |

> **`node`/`bash` are ok-line counters, not source greps.** They count `ok - ` lines the
> runner **prints** — its own structured output (one line per passed assertion), exactly like
> the playwright/pytest handlers read their runner's printed summary. Both indentation shapes
> match (`ok  - ` and `  ok   - `). Only trusted on a **green** run: a failure prints `FAIL -`
> instead of `ok -`, so a red run undercounts — which is why a red run is excluded via `red:true`.

> **`node-test` is not `node`.** A `node --test` suite prints `ok 6 - name` (numbered); the
> `node` handler's `ok - ` regex matches **none** of it, which is why every node:test suite in
> the estate silently counted 0 before this handler existed. Use `node-test` for anything run
> by `node --test`, and `node` only for a hand-rolled harness that prints its own `ok - ` lines.
> The family is spelled `node-test`, not `node:test`, because `runners` lines are
> `type:runner:path` — a colon in the family name would split the field.

> **`node-test` parses the summary, and both shapes of it.** Never the `ok N -` lines: TAP
> prints one per subtest *and* per enclosing suite, so ok-counting double-counts nested
> `describe`s. Which summary you get depends on the **node version**, because `node --test`
> chooses its default reporter by version once its output is piped (which is always, in CI):
> node 20 emits TAP (`# pass N`), node 22+ emits spec (`ℹ pass N`). Both are parsed — pinning
> to one would count correctly until someone bumps node, then silently count 0.

> **`node-test`/`tsx` flag red from the runner's own summary.** If a suite reports `fail > 0`,
> the emit is `red:true` **even when `test_result` says success**. That combination is what a
> `|| true`, a non-blocking step, or a mis-gated suite produces — and it is the one path by
> which this action could publish a silently under-counted *green* number.

> **The `tsx` pattern ships in the action, not in your workflow.** The `<N> passed, <M> failed`
> shape is allow-listed here deliberately: a consumer-supplied regex would turn the `runners`
> input into an injection surface. A suite printing a different shape needs a handler added
> here — never a silent 0.

> **Count semantics:** the jest/vitest handlers count `numPassedTests` — tests that ran
> and passed, **excluding `.skip`/`.todo`**. This matches the reference producer
> (`omnopsis-backend`). On a green CI run `numPassedTests == numTotalTests` (any failure
> would already make CI red). Repos with deliberately-skipped tests should confirm their
> reconciliation target counts the same way.

## Contract guarantees (enforced by the fixture tests + schema)

1. **Runner-reported, never grep** — one handler per runner, parsing the runner's own output.
2. **`tests.total == sum(values of tests.byType)`** — additive, distinct, gated runner totals only.
3. **`tests.declared` are display-only** — executed-but-ungated / `--list`-only counts, **never**
   summed into `total`/`byType` (the neckarshore-website 308 → 87 fix).
4. **`tests.lenses` are display-only** — overlapping subsets, **never** summed into `total`/`byType`.
5. **`red`/`red_detail`** — a non-green `test_result` emits `red:true` + a one-line `red_detail`,
   and **still writes the file** (so the aggregator WARNs, never goes blind). Green → `red:false`,
   `red_detail:null`.
6. **`audited_sha` + `repo` always present** — the count is auditable + reproducible.
7. **Fail-closed-visible** — a missing/unparseable reporter, an unknown runner, an empty
   producer, or a malformed line **exits non-zero and writes no `stats.json`**. Never a
   silent `0` that quietly drops the public number.
8. **No silent zero, red-aware** — a runner line that parses **0 tests out of non-empty
   reporter output** is a wiring bug (wrong family, glob matched nothing, suite never ran)
   and **dies loudly on a green run**. On a **red** run a 0 is legitimate — a crashed suite
   reports nothing — so it **still emits, with `red:true`**. Dying there would blind the
   aggregator exactly when it most needs the signal: fail-closed-*visible* means the number
   stays visible **and** flagged, not that the file disappears.
9. **Schema-conformant** — every emitted `stats.json` validates against
   [`tests/stats.schema.json`](tests/stats.schema.json) (the hardened contract) in this action's CI.

## Fixtures provenance

Every fixture under [`tests/fixtures/`](tests/fixtures) is **real captured reporter
output**, not hand-authored — a fabricated fixture would encode a wrong mental model that
passes here and fails live. Sources (captured 2026-06-21):

| Fixture | Source | Count |
|---------|--------|-------|
| `bats-count.txt` | `dev-environment` `bats --count tests/` | 82 |
| `golden/{unit,integration,e2e}.json` | `omnopsis-backend` three suites (real summaries) | 302 / 27 / 255 → **584** |
| `goldoni/e2e-list.out` | `goldoni-website` @`401cdf5` `playwright test --grep-invert @external --list` (captured 2026-07-17) | 20 |
| `goldoni/lighthouse-unit-spec.out` | `goldoni-website` @`401cdf5` `node --test --test-reporter=spec scripts/lighthouse-profiles.test.mjs` (captured 2026-07-17) | 6 |
| `goldoni/lighthouse-unit-tap.out` | `goldoni-website` @`401cdf5` `node --test --test-reporter=tap scripts/lighthouse-profiles.test.mjs` (captured 2026-07-17) | 6 |
| `goldoni/search-index-data.out` | `goldoni-website` @`401cdf5` `tsx tests/search/index-data.test.ts` (captured 2026-07-17) | 9 |
| `jest-report.json` | `omnopsis-backend` integration suite, `jest --json` | 27 |
| `md-viewer/frontmatter.out` | `md-viewer` `node test/frontmatter.test.mjs` (captured 2026-07-07) | 8 |
| `md-viewer/smoke.out` | `md-viewer` `./test/smoke.sh` (captured 2026-07-07) | 13 |
| `md-viewer/web-smoke.out` | `md-viewer` `./test/web-smoke.sh` (captured 2026-07-07) | 33 |
| `node-test-red.out` | a 4-test `node:test` suite with one deliberate failure, real `--test-reporter=tap` output (captured 2026-07-17) — the one *authored-suite* fixture, see the note below | 3 pass / 1 fail |
| `oakwood/blog-unit.out` | `oakwoodgolfclub-website` @`56285c2` `npm run test:blog:unit` — three `tsx` files chained with `&&` into one output, interleaved log noise included (captured 2026-07-17) | 9 + 12 + 8 = **29** |
| `oakwood/search-index-data-red.out` | `oakwoodgolfclub-website` @`56285c2` `tsx tests/search/index-data.test.ts` — genuinely RED at HEAD (known #257, deliberately ungated) (captured 2026-07-17) | 4 pass / 1 fail |
| `playwright-list.txt` | `neckarshore-website` `playwright test --list` | 197 |
| `pytest-collect.txt` | real `pytest 9.1.1 --collect-only -q` | 5 |
| `unittest-output.txt` | real `python -m unittest` | 2 |
| `vitest-report.json` | `omnopsis-contracts` `vitest run --reporter=json` | 85 |

Three **golden conformance fixtures**:

1. **`omnopsis-backend`** — the action reproduces its live `backend/stats.json` `byType`
   (302 / 27 / 255 = **584**) exactly.
2. **`md-viewer`** — the three real captures above reproduce the human- + canary-verified
   **54** (`8 + 13 + 33`, disjoint cascade) — proving the deterministic Layer-1 emitter agrees
   with the Layer-2 canary at 54.
3. **`goldoni-website`** — the four real captures above reproduce **35** (`20` e2e + `6` + `9`
   unit), the disjoint own-runner total independently measured by Lenin at `1d55153`
   ([report](https://github.com/neckarshore-ai/neckarshore-planning/blob/main/docs/reports/2026-07-17-lenin-phase1-verify-queue.md)).
   The live emitter reported **20** — its whole CI-gated unit half fell on the floor because
   neither `node --test` nor `tsx` had a handler. This fixture is what proves that gap closed.

> **Golden means measured-elsewhere, never self-asserted.** Each golden number above comes
> from an *independent* source — a live `stats.json`, a human+canary audit, an own-runner
> audit by the test-governance steward. A number this action computed and then asserted
> against itself would only prove it is self-consistent, which is exactly what a
> wrong-but-consistent total already is. The shape gates (`total == sum(byType)`) catch form;
> only a golden baseline catches truth.

> **The one authored-suite fixture: `node-test-red.out`.** No repo in the estate has a
> *gated* red `node:test` suite to capture (a red gated suite gets fixed, not committed), so
> the red-path fixture is a purpose-written 4-test suite — but its output is **real
> `node --test` reporter output**, not hand-typed. It locks two things a green fixture cannot:
> `fail>0` forces `red:true`, and the handler reads the summary (`pass 3`) rather than the
> three `ok N -` lines a red run happens to print.

> **The one shape fixture: `declared/website-e2e-list.txt`.** This single fixture is **real
> playwright `--list` FORMAT** with an **illustrative count (293)** rather than a captured one —
> it exercises the *declared-split mechanic* (a large ungated e2e suite held out of `total`),
> reproducing the neckarshore-website **308 → 87** case. Reporter *parsing* is covered by the
> captured playwright fixture (197); this one covers the *routing* (`declared` ≠ `total`).

> **`audited_sha` makes the number SHA-aware, not fixed.** The reference repo `omnopsis-contracts`
> was Lenin-audited at **81** @ `d53a95f`; the action emits **85** @ `bcc5b9d` because the
> post-audit commit `e9dfa9b` added 4 real tests (`event-type-coverage.test.ts`). `85 = 81 + 4`,
> fully explained by `audited_sha` — this is the PR-following design working, not a producer bug.

## Development

```bash
npm install -g bats@1.13.0 ajv-cli@5.0.0   # pinned, exact
bats tests/emit-test-stats.bats            # counts + contract invariants (28 tests)
shellcheck emit-test-stats.sh tests/validate-schema.sh
bash tests/validate-schema.sh              # emitted stats.json validates against tests/stats.schema.json
```

## License

[MIT](LICENSE).
