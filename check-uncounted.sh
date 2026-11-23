#!/usr/bin/env bash
# check-uncounted.sh — check (c) of test-stats-action v2 (planning #4209 §6).
#
# Names a test-runner invocation in a `run:` block of this repo's workflows, or one level
# down in a package.json script such a block calls, whose output file is not named in
# runners:, declared: or lenses:, and whose step carries no
# `# test-stats: uncounted <reason>` marker. That is a gated suite nobody configured: its
# tests run, and the estate number never hears of them.
#
# Mode (UNCOUNTED_MODE, internal, not an action input — the marker is the only per-step
# escape):
#   warn (default, until the binding date): every finding is a ::warning:: annotation and
#        a step-summary row; the step exits 0 on EVERY path, including the check's own
#        failure. The action runs this after stats.json is written, so a bug here can
#        never cost a producer its stats.
#   fail (from the binding date, step 5 of #4209): a finding, or a check that cannot run,
#        exits non-zero.
#
# Inputs: INPUT_RUNNERS / INPUT_DECLARED / INPUT_LENSES (the action's own), TSA_WORKSPACE
# (default GITHUB_WORKSPACE, else .), GITHUB_STEP_SUMMARY (optional).
set -uo pipefail

MODE="${UNCOUNTED_MODE:-warn}"
case "$MODE" in
  warn|fail) ;;
  *) echo "check (c): unknown UNCOUNTED_MODE '$MODE' (warn | fail)" >&2; exit 2 ;;
esac

# Warn mode never fails the step: whatever ends this script non-zero (a bug, a signal,
# an unset name under -u) becomes a visible warning and exit 0.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$1
  if [ "$MODE" = warn ] && [ "$rc" -ne 0 ]; then
    echo "::warning title=test-stats (c)::check (c) stopped with status $rc; its findings for this repo are incomplete."
    exit 0
  fi
}
trap 'on_exit $?' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK="$HERE/check-uncounted.awk"
WS="${TSA_WORKSPACE:-${GITHUB_WORKSPACE:-.}}"

cannot_run() {
  echo "::warning title=test-stats (c)::check (c) could not run: $1. No finding is reported for this repo."
  [ "$MODE" = fail ] && exit 1
  exit 0
}

# The configured output paths: field 3 onward of every type:runner:path line.
PATHS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  p="${line#*:}"; p="${p#*:}"
  [ -n "$p" ] && PATHS+=("$p")
done <<< "${INPUT_RUNNERS:-}"$'\n'"${INPUT_DECLARED:-}"$'\n'"${INPUT_LENSES:-}"

# mentions <text>: does the text name a configured path, in full or by its basename as a
# whole file name (not the tail of a longer one)?
mentions() {
  local text="$1" p b esc
  for p in "${PATHS[@]+"${PATHS[@]}"}"; do
    [[ "$text" == *"$p"* ]] && return 0
    b="${p##*/}"
    [ -z "$b" ] && continue
    esc=$(printf '%s' "$b" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
    printf '%s' "$text" | grep -qE "(^|[^A-Za-z0-9_.-])$esc([^A-Za-z0-9_.-]|\$)" && return 0
  done
  return 1
}

# derived <line> <target> <step lines>: the invocation writes <target>, and another line
# of the same step reads <target> and names a configured path (a TAP stream turned into
# the counted file). Line-level matching would flag that; step-level matching would hide
# a second, uncounted runner in a multi-runner emit step. This keeps both right.
derived() {
  local line="$1" t="$2" steps="$3" l
  [ -z "$t" ] && return 1
  # read into an array: an unquoted expansion would glob, and under nullglob a line
  # holding tests/*.test.mjs would vanish.
  local -a ls=()
  IFS=$'\037' read -r -d '' -a ls <<< "$steps" || true
  for l in "${ls[@]+"${ls[@]}"}"; do
    [ "$l" = "$line" ] && continue
    [[ "$l" == *"$t"* ]] || continue
    mentions "$l" && return 0
  done
  return 1
}

[ -f "$AWK" ] || cannot_run "its reader $AWK is missing"
[ -d "$WS/.github/workflows" ] || cannot_run "no .github/workflows under $WS (is the repo checked out before this step?)"

shopt -s nullglob
FILES=("$WS"/.github/workflows/*.yml "$WS"/.github/workflows/*.yaml)
[ "${#FILES[@]}" -gt 0 ] || cannot_run "no workflow file under $WS/.github/workflows"

FINDINGS=()
UNRESOLVED=0
for f in "${FILES[@]}"; do
  rel="${f#"$WS"/}"
  if ! recs=$(LC_ALL=C awk -v mode=wf -f "$AWK" "$f" 2>/dev/null); then
    echo "::warning file=$rel,title=test-stats (c)::check (c) could not read this workflow; it is not checked."
    [ "$MODE" = fail ] && FINDINGS+=("$rel|0|unreadable workflow|")
    continue
  fi
  while IFS=$'\036' read -r kind ln marker what dir text env tgt stepl; do
    [ -z "${kind:-}" ] && continue
    [ "$marker" = 1 ] && continue
    runner="$what"; body=""
    if [ "$kind" = PKG ]; then
      pj="$WS/$dir/package.json"; [ "$dir" = "." ] && pj="$WS/package.json"
      if [ "$dir" = "?" ] || [ ! -f "$pj" ]; then UNRESOLVED=$((UNRESOLVED + 1)); continue; fi
      body=$(jq -r --arg s "$what" '.scripts[$s] // empty' "$pj" 2>/dev/null) || { UNRESOLVED=$((UNRESOLVED + 1)); continue; }
      [ -z "$body" ] && continue
      runner=$(printf '%s\n' "$body" | LC_ALL=C awk -v mode=cmd -f "$AWK" 2>/dev/null) || continue
      [ -z "$runner" ] && continue
      runner="$runner (script '$what' in ${pj#"$WS"/})"
    fi
    mentions "$text $env $body" && continue
    derived "$text" "${tgt:-}" "${stepl:-}" && continue
    why=""
    [ "$marker" = 2 ] && why=" The step has a marker without a reason, which does not count."
    FINDINGS+=("$rel|$ln|$runner|$text")
    echo "::warning file=$rel,line=$ln,title=test-stats (c)::$runner runs here, and its output is not named in runners:, declared: or lenses:. Count it there, or mark the step '# test-stats: uncounted <reason>'.$why Warn-only until the binding date (planning #4209)."
  done <<< "$recs"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### test-stats check (c): ${#FINDINGS[@]} uncounted runner invocation(s), mode $MODE"
    if [ "${#FINDINGS[@]}" -gt 0 ]; then
      echo
      echo "| # | Workflow | Line | Runner | Command |"
      echo "|---|----------|------|--------|---------|"
      i=0
      for x in "${FINDINGS[@]}"; do
        i=$((i + 1))
        IFS='|' read -r a b c d <<< "$x"
        echo "| $i | \`$a\` | $b | $c | \`${d//|/\\|}\` |"
      done
    fi
    [ "$UNRESOLVED" -gt 0 ] && echo && echo "$UNRESOLVED script call(s) not resolved (no package.json at the directory, or a directory built at run time)."
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [ "$MODE" = fail ] && [ "${#FINDINGS[@]}" -gt 0 ]; then exit 1; fi
exit 0
