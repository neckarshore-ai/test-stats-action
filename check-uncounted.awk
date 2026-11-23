# check-uncounted.awk — the reader behind check-uncounted.sh (check (c), planning #4209 §6).
#
# mode=wf  : reads one workflow file and prints one record per runner invocation in a
#            `run:` block, and per package-manager script call that check-uncounted.sh
#            resolves one level down in package.json:
#              INV  line  marker  runner  dir  text  env  target  steplines
#              PKG  line  marker  script  dir  text  env  target  steplines
#            fields separated by \036 (not a tab: bash read collapses empty tab fields),
#            step lines by \037.
#            marker: 0 none, 1 with a reason, 2 without a reason.
# mode=cmd : reads a script body (one package.json script) and prints the runner it
#            invokes in command position, or nothing.
#
# This is a line reader for the YAML GitHub workflows use, not a YAML parser. What it
# does not read is listed in the README under check (c), "does not catch".

function indent(s) { match(s, /^ */); return RLENGTH }
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t\r]+$/, "", s); return s }
function unq(s) {
  s = rtrim(ltrim(s))
  if (s ~ /^".*"$/ || s ~ /^'.*'$/) s = substr(s, 2, length(s) - 2)
  return s
}
function base(w) { sub(/.*\//, "", w); sub(/@[^@]*$/, "", w); return w }
function joinpath(d, p,    n, parts, i, out, k, stack) {
  if (p ~ /^\//) return p
  if (d == "" || d == ".") d = ""
  n = split((d == "" ? "" : d "/") p, parts, "/")
  k = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (k > 0) k--; continue }
    stack[++k] = parts[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") stack[i]
  return out == "" ? "." : out
}

# runner(cmd) -> "jest" | "vitest" | "playwright" | "pytest" | "bats" | "node --test" | "tsx"
#   or "PKG:<script>" for a package-manager script call, or "" for anything else.
# Command position only: a mention inside echo, an install or a version call is no run.
function runner(cmd,    n, w, i, r, j, a, isver) {
  n = split(cmd, w, /[ \t]+/)
  i = 1
  while (i <= n && (w[i] == "" || w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w[i] ~ /^(sudo|env|time|exec|command|nice|nohup|!|\(|\{|if|then|do|else|elif|while|until)$/)) i++
  if (i <= n && w[i] ~ /^(timeout|xvfb-run)$/) { i++; while (i <= n && (w[i] ~ /^-/ || w[i] ~ /^[0-9]+[smh]?$/)) i++ }
  if (i > n) return ""
  a = base(w[i])
  if (a ~ /^(npx|bunx|pnpx)$/) {
    i++; while (i <= n && w[i] ~ /^-/) { if (w[i] ~ /^(-p|--package)$/) i++; i++ }
    if (i > n) return ""
    a = base(w[i])
  } else if (a ~ /^(pnpm|yarn|bun)$/) {
    i++; while (i <= n && w[i] ~ /^-/) { if (w[i] ~ /^(-C|--dir|--cwd|--filter|-F)$/) i++; i++ }
    if (i > n) return ""
    if (w[i] ~ /^(exec|dlx|x)$/) { i++; if (i > n) return ""; a = base(w[i]) }
    else if (w[i] == "run") { i++; while (i <= n && w[i] ~ /^-/) i++; return (i <= n) ? "PKG:" w[i] : "" }
    else if (w[i] ~ /^(install|add|i|ci|remove|rm|up|upgrade|update|audit|outdated|why|list|ls|link|unlink|publish|pack|config|set|cache|store|init|create|version|info|view|import|rebuild|prune|dedupe|patch|setup|env|global)$/ || w[i] ~ /^-/) return ""
    else { a = base(w[i]); if (a !~ /^(jest|vitest|playwright|pytest|bats|tsx)$/) return "PKG:" w[i] }
  } else if (a == "npm") {
    i++; while (i <= n && w[i] ~ /^-/) { if (w[i] ~ /^(--prefix|-C|--workspace|-w)$/) i++; i++ }
    if (i > n) return ""
    if (w[i] ~ /^(test|t|tst)$/) return "PKG:test"
    if (w[i] ~ /^(run|run-script|rum|urn)$/) { i++; while (i <= n && w[i] ~ /^-/) i++; return (i <= n) ? "PKG:" w[i] : "" }
    if (w[i] == "exec") { i++; while (i <= n && w[i] ~ /^-/) i++; if (i > n) return ""; a = base(w[i]) }
    else return ""
  } else if (a ~ /^(python|python3|py)$/) {
    if (i + 2 <= n && w[i+1] == "-m" && w[i+2] == "pytest") { a = "pytest"; i += 2 } else return ""
  } else if (a ~ /^(uv|poetry|pipenv|hatch)$/ && w[i+1] == "run") {
    i += 2; if (i > n) return ""; a = base(w[i])
    if (a ~ /^(python|python3)$/ && w[i+1] == "-m" && w[i+2] == "pytest") { a = "pytest"; i += 2 }
  } else if (a == "node") {
    for (j = i + 1; j <= n; j++) if (w[j] == "--test") return "node --test"
    return ""
  }
  if (a == "playwright") { if (w[i+1] != "test") return "" }
  else if (a !~ /^(jest|vitest|pytest|bats|tsx)$/) return ""
  isver = 0
  for (j = i + 1; j <= n; j++) {
    if (w[j] ~ /^(--version|--help|-h|-V)$/) isver = 1
    if (w[j] == "-v" && a != "pytest") isver = 1
  }
  if (isver) return ""
  return a
}

# split a logical shell line into simple commands; track `cd` for the directory.
# mask(s): blank the separators | ; & that sit inside quotes, so a quoted pattern
# (sed 's|node --test ||') is not split into a command of its own.
function mask(s,    i, ch, q, out) {
  q = ""; out = ""
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (q == "" && (ch == "'" || ch == "\"")) q = ch
    else if (q != "" && ch == q) q = ""
    else if (q != "" && (ch == "|" || ch == ";" || ch == "&")) ch = " "
    out = out ch
  }
  return out
}

# target(s): the file a command line writes its output to: the word after the last
# > or >> (not >&N), or after tee. Empty when it writes none.
function target(s,    t, a, o) {
  t = ""; o = s
  while (match(s, /(^|[^0-9&<])>>?[ \t]*[^ \t&|;>]+/)) {
    a = substr(s, RSTART, RLENGTH); sub(/^[^>]*>>?[ \t]*/, "", a)
    if (a !~ /^&/) t = a
    s = substr(s, RSTART + RLENGTH)
  }
  s = o
  if (t == "" && match(s, /tee[ \t]+(-a[ \t]+)?[^ \t|;&]+/)) { a = substr(s, RSTART, RLENGTH); sub(/^tee[ \t]+(-a[ \t]+)?/, "", a); t = a }
  return unq(t)
}

function scan(text, line, marker, envtext, dir,    n, c, k, r, cdw, m, whole, tgt) {
  whole = text
  text = mask(text)
  gsub(/[0-9]*>&[0-9-]*/, " ", text)
  gsub(/&>/, ">", text)
  gsub(/\|\||&&|;|\|&|\||&/, "\n", text)
  n = split(text, c, "\n")
  for (k = 1; k <= n; k++) {
    m = ltrim(c[k])
    sub(/^[({!]+[ \t]*/, "", m)
    if (m ~ /^#/) continue
    sub(/[ \t]#.*$/, "", m)
    if (m ~ /^cd[ \t]+/) {
      cdw = m; sub(/^cd[ \t]+/, "", cdw); sub(/[ \t].*$/, "", cdw); cdw = unq(cdw)
      if (cdw != "" && cdw !~ /[$`~]/) CWD = joinpath(CWD, cdw); else CWD = "?"
      continue
    }
    r = runner(m)
    if (r == "") continue
    tgt = target(whole)
    if (r ~ /^PKG:/) printf "PKG\036%d\036%d\036%s\036%s\036%s\036%s\036%s\036%s\n", line, marker, substr(r, 5), CWD, whole, envtext, tgt, STEPL
    else printf "INV\036%d\036%d\036%s\036%s\036%s\036%s\036%s\036%s\n", line, marker, r, CWD, whole, envtext, tgt, STEPL
  }
}

function flushstep(    i, j, logical, startl, envtext) {
  if (!SA) return
  # Marker: a comment line in the step, or in the comment block right above its dash.
  envtext = SENV
  STEPL = ""
  for (i = 1; i <= RUNN; i++) STEPL = STEPL (i > 1 ? "\037" : "") RUNTXT[i]
  gsub(/\t/, " ", STEPL)
  gsub(/\t/, " ", envtext)
  CWD = (SWD != "") ? SWD : ((JWD != "") ? JWD : WWD)
  if (CWD == "") CWD = "."
  logical = ""; startl = 0
  for (i = 1; i <= RUNN; i++) {
    if (logical == "") startl = RUNLN[i]
    if (RUNTXT[i] ~ /\\$/) { logical = logical substr(RUNTXT[i], 1, length(RUNTXT[i]) - 1) " "; continue }
    logical = logical RUNTXT[i]
    gsub(/\t/, " ", logical)
    scan(logical, startl, SM, envtext, CWD)
    logical = ""
  }
  if (logical != "") scan(logical, startl, SM, envtext, CWD)
  SA = 0; RUNN = 0; SENV = ""; SWD = ""; SM = 0
}

function markerof(s,    r) {
  if (s !~ /#[ \t]*test-stats:[ \t]*uncounted/) return 0
  r = s; sub(/.*#[ \t]*test-stats:[ \t]*uncounted/, "", r); r = rtrim(ltrim(r))
  return (r == "") ? 2 : 1
}

BEGIN { FS = "\n"; SA = 0; RUNN = 0; INSTEPS = 0; SI = -1; DI = -1; BLOCK = ""; BI = -1; PRE = 0 }

mode == "cmd" {
  CWD = "."
  x = $0
  gsub(/\|\||&&|;|\|&|\||&/, "\n", x)
  nn = split(x, cc, "\n")
  for (kk = 1; kk <= nn; kk++) { r = runner(ltrim(cc[kk])); if (r != "" && r !~ /^PKG:/) { print r; exit } }
  next
}

{
  raw = $0; sub(/\r$/, "", raw)
  ind = indent(raw)
  body = substr(raw, ind + 1)

  # Inside a block scalar (run: | or env: block): collect while indented deeper.
  if (BLOCK != "") {
    if (body == "" || ind > BI) {
      if (BLOCK == "run") {
        RUNN++; RUNLN[RUNN] = NR; RUNTXT[RUNN] = body
        if (markerof(body)) SM = (SM == 1 ? 1 : markerof(body))
      } else if (BLOCK == "env") SENV = SENV " " body
      else if (BLOCK == "defaults") { if (body ~ /^working-directory:/) { v = body; sub(/^working-directory:/, "", v); DWD = unq(v) } }
      next
    }
    if (BLOCK == "defaults") { if (DLEVEL == "job") JWD = DWD; else WWD = DWD }
    BLOCK = ""
  }

  if (body == "") next
  if (body ~ /^#/) {
    if (SA && ind > DI) { mk = markerof(body); if (mk) SM = (SM == 1 ? 1 : mk) }
    else { mk = markerof(body); if (mk) PRE = (PRE == 1 ? 1 : mk) }
    next
  }

  # Leaving the steps list or the step.
  if (INSTEPS && ind <= SI) { flushstep(); INSTEPS = 0; DI = -1 }
  if (SA && ind <= DI && !(ind == DI && body ~ /^- /)) { flushstep() }

  if (ind == 2 && body ~ /^[A-Za-z0-9_-]+:[ \t]*$/ && !INSTEPS) { JWD = ""; }

  if (body ~ /^defaults:[ \t]*$/) { BLOCK = "defaults"; BI = ind; DWD = ""; DLEVEL = (ind == 0 ? "wf" : "job"); next }
  if (body ~ /^steps:[ \t]*$/) { INSTEPS = 1; SI = ind; DI = -1; PRE = 0; next }

  if (INSTEPS && body ~ /^- / && (DI == -1 || ind == DI)) {
    flushstep()
    DI = ind; SA = 1; SM = PRE; PRE = 0
    raw = substr(raw, 1, ind) "  " substr(body, 3); ind = ind + 2; body = substr(raw, ind + 1)
  }
  PRE = 0

  if (!SA || ind != DI + 2) next
  if (body ~ /^working-directory:/) { v = body; sub(/^working-directory:/, "", v); SWD = unq(v); next }
  if (body ~ /^env:[ \t]*$/) { BLOCK = "env"; BI = ind; next }
  if (body ~ /^env:/) { v = body; sub(/^env:/, "", v); SENV = SENV " " v; next }
  if (body ~ /^run:/) {
    v = body; sub(/^run:[ \t]*/, "", v)
    if (v ~ /^[|>][-+0-9]*[ \t]*(#.*)?$/) { BLOCK = "run"; BI = ind; RUNIND = ind + 2; RFOLD = (v ~ /^>/); next }
    v = unq(v)
    mk = markerof(v); if (mk) SM = (SM == 1 ? 1 : mk)
    RUNN++; RUNLN[RUNN] = NR; RUNTXT[RUNN] = v
    next
  }
}

END { if (mode != "cmd") flushstep() }
