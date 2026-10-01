#!/usr/bin/env bash
# Regression tests for assets/scripts/filed-from.py.
#
# #268: the machine-read discriminator this check exists to protect is
# grammar-vs-prose -- a body that LOOKS like it names a source but doesn't
# parse must be told apart from a body that never tried. Group A pins the
# grammar directly, by importing the script (`pymod`, same trick
# usage-pace.test.sh uses) rather than round-tripping through `gh issue
# create`. Groups B and C exercise `check` and `chain` against a fake `gh`
# on PATH, the same way session-seed.test.sh fakes `git` and
# usage-benchmark-row.test.sh fakes `gh` itself (see its GHBIN block) --
# these tests must not depend on a network, on credentials, or on what is
# actually filed in this repo today.
#
# Group D exists because of a #274 review finding (C1): four of the six
# templates put the new line inside a QUOTED bash heredoc, so `${PR_NUM}`
# etc. never expanded and the emitted issue body was literally malformed --
# every OTHER group here tests the CHECKER, and none of them would ever have
# caught a bug in what the TEMPLATES emit. Group D extracts the real heredoc
# out of each edited generic/*.md, runs it through bash with the variables
# set, and feeds the result to parse_filed_from -- this is the test that
# would have caught C1, and it reads the templates fresh on every run so a
# future edit that reintroduces a quoting bug fails here too.
#
# Does NOT `set -e`: an assertion that fails must be reported and the rest
# still run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# This suite IMPORTS the SUT, which would otherwise drop __pycache__/ into the
# tracked source tree -- and pr-record.test.sh, running later in the same CI job,
# asserts that directory is absent. Same fix usage-pace.test.sh carries.
export PYTHONDONTWRITEBYTECODE=1
SUT="$HERE/filed-from.py"
GENERIC=$(cd "$HERE/../../generic" && pwd)
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/filed-from-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
flat(){ printf '%s' "$1" | tr '\n' '|'; }

# pymod <python-expr-using-ff> [argv...] -- imports filed-from.py as module
# `ff` by file path (never via `import filed_from`, which the hyphen forbids)
# and evaluates the given statement against it. Mirrors usage-pace.test.sh's
# `pymod` helper.
pymod() {
  "$PY" - "$SUT" "$@" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ff", sys.argv[1])
ff = importlib.util.module_from_spec(spec); spec.loader.exec_module(ff)
exec(sys.argv[2])
PYEOF
}

echo "filed-from.test.sh"

# ============================================================ GROUP A — grammar
echo; echo "A. grammar (parse_filed_from)"

body_ref="## Context

Filed from: #268

## Description
"
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'], p['number'], p['url'])" "$body_ref")
[ "$got" = "ref 268 None" ] && ok "Filed from: #NNN parses (form=ref, no url)" \
  || bad "Filed from: #NNN parses (form=ref, no url)" "$(flat "$got")"

body_url="## Context

Filed from: #268 (https://github.com/blamechris/skill-templates/pull/12#discussion_r1)
"
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'], p['number'], p['url'])" "$body_url")
[ "$got" = "ref 268 https://github.com/blamechris/skill-templates/pull/12#discussion_r1" ] \
  && ok "Filed from: #NNN (<url>) captures the url" \
  || bad "Filed from: #NNN (<url>) captures the url" "$(flat "$got")"

body_session="## Context

Filed from: session 63d851b4-bbab-45d5-bc1d-fd17396cebce
"
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'], p['session_id'])" "$body_session")
[ "$got" = "session 63d851b4-bbab-45d5-bc1d-fd17396cebce" ] \
  && ok "Filed from: session <id> parses" \
  || bad "Filed from: session <id> parses" "$(flat "$got")"

body_none="## Context

Filed from: none
"
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'])" "$body_none")
[ "$got" = "none" ] && ok "Filed from: none parses (the literal word, not absence)" \
  || bad "Filed from: none parses (the literal word, not absence)" "$(flat "$got")"

# --- malformed: starts with the exact prefix, fails the grammar -----------
for case in "Filed from: PR #12" "Filed from:#12"; do
  got=$(pymod "print(ff.parse_filed_from(sys.argv[3]))" "$case")
  pref=$(pymod "m=ff.FILED_FROM_PREFIX_RE.search(sys.argv[3]); print(bool(m))" "$case")
  [ "$got" = "None" ] && [ "$pref" = "True" ] \
    && ok "MALFORMED: '$case' fails the grammar but matches the prefix" \
    || bad "MALFORMED: '$case' fails the grammar but matches the prefix" "parse=$got prefix=$pref"
done

# --- not matched at all: wrong case, or not at line start -----------------
got=$(pymod "print(ff.parse_filed_from(sys.argv[3]))" "filed from: #12")
pref=$(pymod "m=ff.FILED_FROM_PREFIX_RE.search(sys.argv[3]); print(bool(m))" "filed from: #12")
[ "$got" = "None" ] && [ "$pref" = "False" ] \
  && ok "MISSING (not malformed): lowercase 'filed from:' matches neither regex" \
  || bad "MISSING (not malformed): lowercase 'filed from:' matches neither regex" "parse=$got prefix=$pref"

midline="See note: Filed from: #12 buried mid-sentence, not at line start"
got=$(pymod "print(ff.parse_filed_from(sys.argv[3]))" "$midline")
pref=$(pymod "m=ff.FILED_FROM_PREFIX_RE.search(sys.argv[3]); print(bool(m))" "$midline")
[ "$got" = "None" ] && [ "$pref" = "False" ] \
  && ok "MISSING (not malformed): 'Filed from:' not anchored at line start" \
  || bad "MISSING (not malformed): 'Filed from:' not anchored at line start" "parse=$got prefix=$pref"

got=$(pymod "print(ff.parse_filed_from(''))")
[ "$got" = "None" ] && ok "empty body -> None" || bad "empty body -> None" "$(flat "$got")"

# --- S6: CRLF ---------------------------------------------------------------
# `$` in MULTILINE mode matches only right before a bare \n (or string end);
# an unconverted \r\n body leaves a trailing \r after "Filed from: #42",
# which is a REAL, correctly-written line that must not read as malformed
# just because the source used Windows line endings.
body_crlf=$(printf '## Context\r\n\r\nFiled from: #42\r\n')
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'], p['number'])" "$body_crlf")
[ "$got" = "ref 42" ] && ok "CRLF body: a correctly-formed line still parses (S6)" \
  || bad "CRLF body: a correctly-formed line still parses (S6)" "$(flat "$got")"

# --- S5: fenced code blocks are stripped before parsing --------------------
body_fenced="## Context

Filed from: none

## Example

\`\`\`
Filed from: #999
\`\`\`
"
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print(p['form'])" "$body_fenced")
[ "$got" = "none" ] && ok "S5: a Filed from: line quoted inside a fenced example is ignored" \
  || bad "S5: a Filed from: line quoted inside a fenced example is ignored" "$(flat "$got")"

body_fenced_only="## Context

\`\`\`
Filed from: #999
\`\`\`
"
got=$(pymod "print(ff.parse_filed_from(sys.argv[3]))" "$body_fenced_only")
[ "$got" = "None" ] && ok "S5: a Filed from: line ONLY inside a fence does not count as valid" \
  || bad "S5: a Filed from: line ONLY inside a fence does not count as valid" "$(flat "$got")"

# ============================================================ GROUP B — check
echo; echo "B. check"

# Fake gh: logs every invocation (one line per call, space-joined argv) to
# $GH_LOG so tests can assert what filed-from.py actually asked for, and
# answers from fixture files under $GH_FIXTURES. GH_FAIL=1 makes every call
# fail, for the exit-2 path. A `children-<N>.FAIL` marker (as opposed to a
# missing `children-<N>.json`, which means "no fixture defined for this
# number -> answer with an empty list") makes ONLY that number's children
# search fail, for C2's "gh fails mid-walk" tests.
GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
[ "${GH_FAIL:-0}" = 1 ] && { echo "gh: fake failure (GH_FAIL=1)" >&2; exit 1; }
FIX="${GH_FIXTURES:?GH_FIXTURES not set}"
case "$1 $2" in
  "repo view")
    cat "$FIX/repo.json" 2>/dev/null || exit 1
    ;;
  "issue list")
    shift 2
    labels=""; search=""; limit=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --label) labels="$labels $2"; shift 2 ;;
        --search) search="$2"; shift 2 ;;
        --limit) limit="$2"; shift 2 ;;
        --repo|--state|--json) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$search" ]; then
      n=$(printf '%s' "$search" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
      if [ -f "$FIX/children-$n.FAIL" ]; then
        echo "gh: search failed for #$n (fake)" >&2
        exit 1
      fi
      cat "$FIX/children-$n.json" 2>/dev/null || echo '[]'
    elif [ -n "$labels" ]; then
      cat "$FIX/list-labeled.json" 2>/dev/null || echo '[]'
    else
      cat "$FIX/list-all.json" 2>/dev/null || echo '[]'
    fi
    ;;
  "issue view")
    cat "$FIX/issue-$3.json" 2>/dev/null || { echo "gh: issue $3 not found" >&2; exit 1; }
    ;;
  "pr view")
    cat "$FIX/pr-$3.json" 2>/dev/null || { echo "gh: pr $3 not found" >&2; exit 1; }
    ;;
  *)
    echo "fake gh: unhandled invocation: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$GHBIN/gh"

FIX="$TMP/fix"; mkdir -p "$FIX"
echo '"blamechris/skill-templates"' > "$FIX/repo.json"

run_ff() {  # run_ff <fixtures-dir> [gh_fail] -- args...
  local fixdir=$1 fail=$2; shift 2
  GH_FIXTURES="$fixdir" GH_FAIL="$fail" PATH="$GHBIN:$PATH" "$PY" "$SUT" "$@" 2>&1
}

# --- a clean set: every issue has a valid line -----------------------------
cat > "$FIX/list-all.json" <<'JSON'
[
  {"number": 1, "title": "clean ref", "url": "u1", "labels": [],
   "body": "## Context\n\nFiled from: #100\n"},
  {"number": 2, "title": "clean none", "url": "u2", "labels": [],
   "body": "## Context\n\nFiled from: none\n"}
]
JSON
out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates)
rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '0 flagged' \
  && ok "check: a clean set passes, exit 0" \
  || bad "check: a clean set passes, exit 0" "rc=$rc $(flat "$out")"

# --- missing vs malformed, with the right reason ---------------------------
cat > "$FIX/list-all.json" <<'JSON'
[
  {"number": 10, "title": "no line at all", "url": "u10", "labels": [],
   "body": "## Context\n\nNothing about a source here.\n"},
  {"number": 11, "title": "bad grammar", "url": "u11", "labels": [],
   "body": "## Context\n\nFiled from: PR #12\n"},
  {"number": 12, "title": "clean", "url": "u12", "labels": [],
   "body": "## Context\n\nFiled from: #9\n"}
]
JSON
out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates)
rc=$?
[ "$rc" -eq 1 ] && ok "check: exit 1 when anything is flagged" \
  || bad "check: exit 1 when anything is flagged" "rc=$rc"
printf '%s' "$out" | grep -Eq '#10 +missing' \
  && ok "check: #10 (no line) is flagged missing" \
  || bad "check: #10 (no line) is flagged missing" "$(flat "$out")"
printf '%s' "$out" | grep -Eq '#11 +malformed: Filed from: PR #12' \
  && ok "check: #11 (bad grammar) is flagged malformed with the offending line" \
  || bad "check: #11 (bad grammar) is flagged malformed with the offending line" "$(flat "$out")"
printf '%s' "$out" | grep -q '#12' && printf '%s' "$out" | grep -Eq '#12 +(missing|malformed)' \
  && bad "check: #12 (clean) must not be flagged" "$(flat "$out")" \
  || ok "check: #12 (clean) is not flagged"

# --json emits the same distinction as structured records
out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates --json)
got=$("$PY" - <<PY
import json
d = json.loads('''$out''')
byno = {f['number']: f for f in d['flagged']}
print(byno[10]['status'], byno[11]['status'], byno[11]['detail'])
PY
)
[ "$got" = "missing malformed Filed from: PR #12" ] \
  && ok "check --json: records carry status + detail" \
  || bad "check --json: records carry status + detail" "$(flat "$got")"

# --- S4: default scope is EVERY open issue; --label narrows (repeatable) ---
# A skill can file with `enhancement` (autonomous-dev-flow), `bug,from-bug-hunt`
# (bug-hunt), `from-audit` (project-audit), or no special label at all
# (decompose-issue) -- a default that only ever looked at label:from-review
# would silently never see any of those.
cat > "$FIX/list-labeled.json" <<'JSON'
[{"number": 20, "title": "labeled", "url": "u20", "labels": [],
  "body": "## Context\n\nFiled from: none\n"}]
JSON

GH_LOG="$TMP/log-default.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates >/dev/null
grep -q -- '--label' "$GH_LOG" \
  && bad "check (default): gh must NOT be asked with any --label (S4)" "$(cat "$GH_LOG")" \
  || ok "check (default): gh is asked with no --label at all -- every open issue (S4)"

GH_LOG="$TMP/log-onelabel.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates --label from-review >/dev/null
grep -q -- '--label from-review' "$GH_LOG" \
  && ok "check --label from-review: gh IS asked with that label" \
  || bad "check --label from-review: gh IS asked with that label" "$(cat "$GH_LOG")"

GH_LOG="$TMP/log-twolabel.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates \
  --label bug --label from-bug-hunt >/dev/null
grep -q -- '--label bug' "$GH_LOG" && grep -q -- '--label from-bug-hunt' "$GH_LOG" \
  && ok "check --label (repeatable): both labels are passed through to gh" \
  || bad "check --label (repeatable): both labels are passed through to gh" "$(cat "$GH_LOG")"

# --all is now a deprecated no-op -- same as no flag, never re-adds a label
GH_LOG="$TMP/log-all-noop.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates --all >/dev/null
grep -q -- '--label' "$GH_LOG" \
  && bad "check --all: is a no-op -- must not add a --label" "$(cat "$GH_LOG")" \
  || ok "check --all: is a no-op (deprecated), same as passing nothing"

# --- gh failure is exit 2, never treated as clean --------------------------
out=$(run_ff "$FIX" 1 check --repo blamechris/skill-templates)
rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'gh issue list failed' \
  && ok "check: a failed gh issue list is exit 2 with gh's stderr, never a clean 0" \
  || bad "check: a failed gh issue list is exit 2 with gh's stderr, never a clean 0" "rc=$rc $(flat "$out")"

# --- no --repo and gh repo view fails -> REFUSE, exit 2 --------------------
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
out=$(GH_FIXTURES="$NOREPO" GH_FAIL=0 PATH="$GHBIN:$PATH" "$PY" "$SUT" check 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
  && ok "check: no --repo and gh repo view unresolved -> REFUSE, exit 2" \
  || bad "check: no --repo and gh repo view unresolved -> REFUSE, exit 2" "rc=$rc $(flat "$out")"

# --- S2: exactly LIST_LIMIT (500) results -> truncated -----------------
"$PY" - "$FIX/list-all.json" <<'PY'
import json, sys
items = [{"number": i, "title": "item %d" % i, "url": "u%d" % i, "labels": [],
          "body": "## Context\n\nFiled from: none\n"} for i in range(1, 501)]
json.dump(items, open(sys.argv[1], "w"))
PY
out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates --json)
got=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print(d['truncated'], d['total'])
PY
)
[ "$got" = "True 500" ] && ok "check: 500 results (== the limit) sets truncated=true (S2)" \
  || bad "check: 500 results (== the limit) sets truncated=true (S2)" "$(flat "$got")"

out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates)
printf '%s' "$out" | grep -qi 'TRUNCATED' \
  && ok "check: the summary line notes the truncation" \
  || bad "check: the summary line notes the truncation" "$(flat "$out")"

"$PY" - "$FIX/list-all.json" <<'PY'
import json, sys
items = [{"number": i, "title": "item %d" % i, "url": "u%d" % i, "labels": [],
          "body": "## Context\n\nFiled from: none\n"} for i in range(1, 500)]
json.dump(items, open(sys.argv[1], "w"))
PY
out=$(run_ff "$FIX" 0 check --repo blamechris/skill-templates --json)
got=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print(d['truncated'], d['total'])
PY
)
[ "$got" = "False 499" ] && ok "check: 499 results (< the limit) is not truncated" \
  || bad "check: 499 results (< the limit) is not truncated" "$(flat "$got")"

# ============================================================ GROUP C — chain
echo; echo "C. chain"

CFIX="$TMP/cfix"; mkdir -p "$CFIX"
echo '"blamechris/skill-templates"' > "$CFIX/repo.json"

# Three-link fixture: #10 (issue, standalone) <- #20 (a PR, filed from #10) <-
# #30 (issue, filed from #20). #20 is answered by `gh issue view` itself (real
# gh resolves PR numbers through the issue endpoint too -- verified against
# the actual CLI) with a `url` pointing at /pull/ and state MERGED, which is
# what `_fetch_node` reads to detect a PR (S3) -- there is deliberately NO
# pr-20.json, so a test that only passes because of the (defensive, rarely
# taken) `gh pr view` fallback would fail here.
cat > "$CFIX/issue-10.json" <<'JSON'
{"number": 10, "title": "root ancestor", "state": "CLOSED",
 "url": "https://github.com/blamechris/skill-templates/issues/10",
 "body": "## Context\n\nFiled from: none\n"}
JSON
cat > "$CFIX/issue-20.json" <<'JSON'
{"number": 20, "title": "the PR in the middle", "state": "MERGED",
 "url": "https://github.com/blamechris/skill-templates/pull/20",
 "body": "## Context\n\nFiled from: #10\n"}
JSON
cat > "$CFIX/issue-30.json" <<'JSON'
{"number": 30, "title": "the child issue", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/issues/30",
 "body": "## Context\n\nFiled from: #20\n"}
JSON
cat > "$CFIX/children-20.json" <<'JSON'
[{"number": 30, "title": "the child issue", "state": "OPEN",
  "body": "## Context\n\nFiled from: #20\n"}]
JSON
cat > "$CFIX/children-30.json" <<'JSON'
[]
JSON
cat > "$CFIX/children-10.json" <<'JSON'
[]
JSON

run_chain() {  # fixtures depth number [--json]
  local fixdir=$1 depth=$2 num=$3; shift 3
  GH_FIXTURES="$fixdir" GH_FAIL=0 PATH="$GHBIN:$PATH" "$PY" "$SUT" chain "$num" \
    --repo blamechris/skill-templates --depth "$depth" "$@" 2>&1
}
# run_chain_sep: same, but keeps stdout and stderr separate (needed whenever
# stderr may carry text -- mixing it into --json stdout would break the
# parse). Sets $out, $err, $rc.
run_chain_sep() {
  local fixdir=$1 depth=$2 num=$3; shift 3
  local errfile; errfile=$(mktemp)
  out=$(GH_FIXTURES="$fixdir" GH_FAIL=0 PATH="$GHBIN:$PATH" "$PY" "$SUT" chain "$num" \
        --repo blamechris/skill-templates --depth "$depth" "$@" 2>"$errfile")
  rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"
}

out=$(run_chain "$CFIX" 10 20 --json); rc=$?
parents=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print([p['number'] for p in d['parents']], [c['number'] for c in d['children']], d['root']['kind'])
PY
)
[ "$rc" -eq 0 ] && [ "$parents" = "[10] [30] pr" ] \
  && ok "chain: walks the three-link fixture both ways from the middle node (#20, a PR)" \
  || bad "chain: walks the three-link fixture both ways from the middle node (#20, a PR)" "rc=$rc parents=$parents out=$(flat "$out")"

out=$(run_chain "$CFIX" 10 20)
printf '%s' "$out" | grep -q '\^ #10 \[CLOSED\]' \
  && printf '%s' "$out" | grep -q '#20 \[MERGED\] (PR)' \
  && printf '%s' "$out" | grep -q 'v #30 \[OPEN\]' \
  && ok "chain: text tree carries direction markers (^ up, v down) and state/kind" \
  || bad "chain: text tree carries direction markers (^ up, v down) and state/kind" "$(flat "$out")"

# --- S3: gh issue view failing, gh pr view succeeding, is the DEFENSIVE ----
# fallback only -- kind is still detected from the payload (url/state), not
# from "which gh subcommand answered".
cat > "$CFIX/pr-50.json" <<'JSON'
{"number": 50, "title": "pr-only, issue view does not resolve it", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/pull/50",
 "body": "## Context\n\nFiled from: none\n"}
JSON
cat > "$CFIX/children-50.json" <<'JSON'
[]
JSON
out=$(run_chain "$CFIX" 10 50 --json); rc=$?
kind=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print(d['root']['kind'])
PY
)
[ "$rc" -eq 0 ] && [ "$kind" = "pr" ] \
  && ok "chain: defensive fallback -- gh issue view failing, gh pr view succeeding, still detects a PR (S3)" \
  || bad "chain: defensive fallback -- gh issue view failing, gh pr view succeeding, still detects a PR (S3)" "rc=$rc kind=$kind"

# --- S1: children search passes --limit (gh's own default is 30) -----------
GH_LOG="$TMP/log-search-limit.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_chain "$CFIX" 10 20 --json >/dev/null
grep -- '--search' "$GH_LOG" | grep -q -- '--limit 500' \
  && ok "chain: children search passes --limit 500, not gh's silent default of 30 (S1)" \
  || bad "chain: children search passes --limit 500, not gh's silent default of 30 (S1)" "$(cat "$GH_LOG")"

# --- depth bound: from #30, depth 1 sees only the immediate parent (#20) ---
out=$(run_chain "$CFIX" 1 30 --json)
parents=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print([p['number'] for p in d['parents']])
PY
)
[ "$parents" = "[20]" ] && ok "chain: --depth 1 stops after one hop (does not reach #10)" \
  || bad "chain: --depth 1 stops after one hop (does not reach #10)" "$(flat "$parents")"

out=$(run_chain "$CFIX" 10 30 --json)
parents=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print([p['number'] for p in d['parents']])
PY
)
[ "$parents" = "[20, 10]" ] && ok "chain: default depth (10) reaches the full chain from #30" \
  || bad "chain: default depth (10) reaches the full chain from #30" "$(flat "$parents")"

# --- cycle: #40 filed from #41, #41 filed from #40 -- must terminate -------
cat > "$CFIX/issue-40.json" <<'JSON'
{"number": 40, "title": "cycle a", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/issues/40",
 "body": "## Context\n\nFiled from: #41\n"}
JSON
cat > "$CFIX/issue-41.json" <<'JSON'
{"number": 41, "title": "cycle b", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/issues/41",
 "body": "## Context\n\nFiled from: #40\n"}
JSON
cat > "$CFIX/children-40.json" <<'JSON'
[{"number": 41, "title": "cycle b", "state": "OPEN",
  "body": "## Context\n\nFiled from: #40\n"}]
JSON
cat > "$CFIX/children-41.json" <<'JSON'
[{"number": 40, "title": "cycle a", "state": "OPEN",
  "body": "## Context\n\nFiled from: #41\n"}]
JSON

if command -v timeout >/dev/null 2>&1; then
  out=$(timeout 10 env GH_FIXTURES="$CFIX" GH_FAIL=0 PATH="$GHBIN:$PATH" "$PY" "$SUT" chain 40 \
        --repo blamechris/skill-templates --json 2>&1); rc=$?
else
  out=$(run_chain "$CFIX" 10 40 --json); rc=$?
fi
[ "$rc" -eq 0 ] && ok "chain: a mutual cycle (#40 <-> #41) terminates rather than hanging" \
  || bad "chain: a mutual cycle (#40 <-> #41) terminates rather than hanging" "rc=$rc $(flat "$out")"
parents=$("$PY" - <<PY
import json
d = json.loads('''$out''')
print([p['number'] for p in d['parents']])
PY
2>/dev/null)
[ "$parents" = "[41]" ] && ok "chain: cycle -- ancestor walk stops the instant it would revisit a number" \
  || bad "chain: cycle -- ancestor walk stops the instant it would revisit a number" "$(flat "$parents")"

# --- an unresolvable root REFUSES rather than printing an empty tree -------
out=$(run_chain "$CFIX" 10 9999); rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
  && ok "chain: an unresolvable root number REFUSES, exit 2" \
  || bad "chain: an unresolvable root number REFUSES, exit 2" "rc=$rc $(flat "$out")"

# --- C2: a gh failure MID-WALK must not read as "no further ancestors" -----
# #20's own body says "Filed from: #10", but #10 is deliberately absent from
# this fixture set (no issue-10.json, no pr-10.json) -- so ancestors() hits a
# real gh failure fetching the parent, not a legitimate "the chain ends here".
CFIX2="$TMP/cfix2"; mkdir -p "$CFIX2"
echo '"blamechris/skill-templates"' > "$CFIX2/repo.json"
cat > "$CFIX2/issue-20.json" <<'JSON'
{"number": 20, "title": "root, parent fetch will fail", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/issues/20",
 "body": "## Context\n\nFiled from: #10\n"}
JSON
cat > "$CFIX2/children-20.json" <<'JSON'
[]
JSON

run_chain_sep "$CFIX2" 10 20 --json
[ "$rc" -eq 2 ] \
  && ok "chain C2: a gh failure fetching a parent exits 2, never the clean 0 of 'no more ancestors'" \
  || bad "chain C2: a gh failure fetching a parent exits 2, never the clean 0 of 'no more ancestors'" "rc=$rc"
parent0_number=$("$PY" - <<PY
import json
d = json.loads('''$out''')
p = d['parents'][0] if d['parents'] else {}
print(p.get('number'))
PY
)
[ "$parent0_number" = "None" ] \
  && ok "chain C2: the failed parent is a synthetic ? node (number is null, not a fabricated ancestor)" \
  || bad "chain C2: the failed parent is a synthetic ? node (number is null, not a fabricated ancestor)" "$parent0_number"
printf '%s' "$err" | grep -qi 'gh failure during chain walk' \
  && ok "chain C2: the failure is surfaced on stderr, not swallowed" \
  || bad "chain C2: the failure is surfaced on stderr, not swallowed" "$(flat "$err")"

run_chain_sep "$CFIX2" 10 20
printf '%s' "$out" | grep -q '? #10' \
  && ok "chain C2: the text tree renders the failure as a ? node, not a silent gap" \
  || bad "chain C2: the text tree renders the failure as a ? node, not a silent gap" "$(flat "$out")"

# --- C2: same, but the failure is in a CHILDREN search, not a parent fetch -
cat > "$CFIX2/issue-70.json" <<'JSON'
{"number": 70, "title": "root, children search will fail", "state": "OPEN",
 "url": "https://github.com/blamechris/skill-templates/issues/70",
 "body": "## Context\n\nFiled from: none\n"}
JSON
: > "$CFIX2/children-70.FAIL"   # marker: the fake gh fails THIS search deliberately

run_chain_sep "$CFIX2" 10 70 --json
[ "$rc" -eq 2 ] \
  && ok "chain C2: a gh failure searching children also exits 2 (not '0 children found')" \
  || bad "chain C2: a gh failure searching children also exits 2 (not '0 children found')" "rc=$rc"
child0_number=$("$PY" - <<PY
import json
d = json.loads('''$out''')
c = d['children'][0] if d['children'] else {}
print(c.get('number'))
PY
)
[ "$child0_number" = "None" ] \
  && ok "chain C2: a failed children search leaves a synthetic ? child, not an empty (clean-looking) list" \
  || bad "chain C2: a failed children search leaves a synthetic ? child, not an empty (clean-looking) list" "$child0_number"

# ================================================== GROUP D — C1: real templates
echo; echo "D. C1 — the real templates' heredocs actually expand"

# extract_filed_from_heredoc <file> -- prints "Q"|"U" on line 1 (whether the
# heredoc that contains "Filed from:" is quoted <<'EOF' or bare <<EOF), then
# the raw (unexpanded) body. Exit 1 if no such heredoc is found.
extract_filed_from_heredoc() {
  "$PY" - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
pat = re.compile(r"<<(?P<q>'?)EOF'?\n(?P<body>.*?)\nEOF\n", re.DOTALL)
best = None
for m in pat.finditer(text):
    if 'Filed from:' in m.group('body'):
        best = m
        break
if best is None:
    sys.exit(1)
sys.stdout.write('Q' if best.group('q') == "'" else 'U')
sys.stdout.write('\n')
sys.stdout.write(best.group('body'))
PYEOF
}

# run_extracted_heredoc <file> [VAR=val ...] -- extracts, then actually runs
# the heredoc through bash (quoted or unquoted, matching what the source file
# itself uses) with the given variables in its environment, and prints what
# gets emitted. This is real bash execution of real template text, not a
# simulation -- it is exactly what an agent following the template would run.
run_extracted_heredoc() {
  local file=$1; shift
  local extracted quoted body script rc
  extracted=$(extract_filed_from_heredoc "$file") || return 1
  quoted=$(printf '%s\n' "$extracted" | head -1)
  body=$(printf '%s\n' "$extracted" | tail -n +2)
  script=$(mktemp)
  if [ "$quoted" = "Q" ]; then
    { echo "cat <<'FF_HEREDOC_TEST_DELIM'"; printf '%s\n' "$body"; echo 'FF_HEREDOC_TEST_DELIM'; } > "$script"
  else
    { echo "cat <<FF_HEREDOC_TEST_DELIM"; printf '%s\n' "$body"; echo 'FF_HEREDOC_TEST_DELIM'; } > "$script"
  fi
  env "$@" bash "$script"
  rc=$?
  rm -f "$script"
  return $rc
}

out=$(run_extracted_heredoc "$GENERIC/agent-review.md" PR_NUM=99); rc=$?
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('number'))" "$out")
[ "$rc" -eq 0 ] && [ "$got" = "ref 99" ] \
  && ok "C1: agent-review.md's heredoc expands \${PR_NUM} (unquoted heredoc) -> parses as ref" \
  || bad "C1: agent-review.md's heredoc expands \${PR_NUM} (unquoted heredoc) -> parses as ref" "rc=$rc got=$got out=$(flat "$out")"

out=$(run_extracted_heredoc "$GENERIC/check-pr.md" PR_NUM=99 \
      COMMENT_URL='https://github.com/o/r/pull/99#discussion_r1'); rc=$?
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('number'), (p or {}).get('url'))" "$out")
[ "$rc" -eq 0 ] && [ "$got" = "ref 99 https://github.com/o/r/pull/99#discussion_r1" ] \
  && ok "C1: check-pr.md's heredoc expands \${PR_NUM}/\${COMMENT_URL} -> parses as ref with url" \
  || bad "C1: check-pr.md's heredoc expands \${PR_NUM}/\${COMMENT_URL} -> parses as ref with url" "rc=$rc got=$got out=$(flat "$out")"

out=$(run_extracted_heredoc "$GENERIC/autonomous-dev-flow.md" ISSUE_NUM=42); rc=$?
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('number'))" "$out")
[ "$rc" -eq 0 ] && [ "$got" = "ref 42" ] \
  && ok "C1: autonomous-dev-flow.md's heredoc expands \${ISSUE_NUM} -> parses as ref" \
  || bad "C1: autonomous-dev-flow.md's heredoc expands \${ISSUE_NUM} -> parses as ref" "rc=$rc got=$got out=$(flat "$out")"
printf '%s' "$out" | grep -q '`src/path/to/file`' \
  && ok "C1: autonomous-dev-flow.md's escaped backticks survive literally (no command substitution)" \
  || bad "C1: autonomous-dev-flow.md's escaped backticks survive literally (no command substitution)" "$(flat "$out")"

out=$(run_extracted_heredoc "$GENERIC/decompose-issue.md" PARENT_NUM=7 SUB_FILES='src/x.ts'); rc=$?
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('number'))" "$out")
[ "$rc" -eq 0 ] && [ "$got" = "ref 7" ] \
  && ok "C1: decompose-issue.md's heredoc expands \${PARENT_NUM} -> parses as ref" \
  || bad "C1: decompose-issue.md's heredoc expands \${PARENT_NUM} -> parses as ref" "rc=$rc got=$got out=$(flat "$out")"
printf '%s' "$out" | grep -q '`src/x.ts`' \
  && ok "C1: decompose-issue.md's pre-existing escaped backticks still survive literally" \
  || bad "C1: decompose-issue.md's pre-existing escaped backticks still survive literally" "$(flat "$out")"

out=$(run_extracted_heredoc "$GENERIC/bug-hunt.md" CLAUDE_CODE_SESSION_ID=abc12345); rc=$?
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('session_id'))" "$out")
[ "$rc" -eq 0 ] && [ "$got" = "session abc12345" ] \
  && ok "C1: bug-hunt.md's heredoc expands \${CLAUDE_CODE_SESSION_ID} -> parses as session" \
  || bad "C1: bug-hunt.md's heredoc expands \${CLAUDE_CODE_SESSION_ID} -> parses as session" "rc=$rc got=$got out=$(flat "$out")"

# project-audit.md is DELIBERATELY different: its body is filled in by hand
# (single-brace placeholders like {DATE}, {N} throughout, never `${VAR}`), so
# its heredoc is intentionally still quoted (<<'EOF') and must NOT expand --
# consistency with the rest of that template, not a bug. The test proves both
# halves: the placeholder does not expand on its own, and once an agent fills
# it in (as the template instructs), the result is valid.
out=$(run_extracted_heredoc "$GENERIC/project-audit.md" CLAUDE_CODE_SESSION_ID=deadbeef01); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Filed from: session {SESSION_ID}' \
  && ok "C1: project-audit.md's heredoc is intentionally quoted -- {SESSION_ID} does not expand" \
  || bad "C1: project-audit.md's heredoc is intentionally quoted -- {SESSION_ID} does not expand" "rc=$rc $(flat "$out")"
filled=$(printf '%s' "$out" | sed 's/{SESSION_ID}/deadbeef01/')
got=$(pymod "p=ff.parse_filed_from(sys.argv[3]); print((p or {}).get('form'), (p or {}).get('session_id'))" "$filled")
[ "$got" = "session deadbeef01" ] \
  && ok "C1: once the agent fills {SESSION_ID} in by hand, the line parses as session" \
  || bad "C1: once the agent fills {SESSION_ID} in by hand, the line parses as session" "$(flat "$got")"

# ============================================== GROUP E — S7: create-issue.md
echo; echo "E. S7 — create-issue.md's FILED_FROM resolution block, run for real"

# create-issue.md:26-44's ```bash fence is not a heredoc (no "Filed from:"
# line lives inside it directly, so Group D's extractor does not apply) --
# it is the FILED_FROM resolution logic itself. The review flagged real bugs
# in it across two rounds: FROM_PR/FROM_ISSUE/COMMENT_URL were read without
# ever being assigned (unbound under `set -u`); the COMMENT_URL append was a
# bare `[ … ] && … && FILED_FROM=…` as the block's LAST statement, which
# exports the first test's failure as the whole block's exit status under
# `set -e`; and `--standalone` was documented but never referenced in the
# bash, with the terminal `else` silently emitting `none` for ANY unresolved
# case -- which is exactly the "forgetting" Critical Rule 7 exists to make
# distinguishable from a deliberate `none`. This extracts the actual fenced
# block and runs it under `set -euo pipefail` -- the strict-mode conditions
# that caught the first round of bugs -- with a fake `gh` (repo view
# succeeds, pr view fails, matching "not on a PR branch") across every
# resolution path, including the REFUSE path now that reaching the terminal
# `else` is a hard failure rather than a silent `none`.
extract_bash_fence_after() {  # file marker-regex -> prints the first ```bash fence after the first line matching marker-regex
  "$PY" - "$1" "$2" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
marker = re.search(sys.argv[2], text)
if not marker:
    sys.exit(1)
rest = text[marker.end():]
m = re.search(r"```bash\n(?P<body>.*?)\n```", rest, re.DOTALL)
if not m:
    sys.exit(1)
sys.stdout.write(m.group('body'))
PYEOF
}

CI_GHBIN="$TMP/ci_ghbin"; mkdir -p "$CI_GHBIN"
cat > "$CI_GHBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "repo" ] && { echo "owner/repo"; exit 0; }
exit 1
SH
chmod +x "$CI_GHBIN/gh"

FENCE=$(extract_bash_fence_after "$GENERIC/create-issue.md" 'Resolve `FILED_FROM`')
FENCE_SCRIPT="$TMP/create-issue-filed-from-block.sh"
{ echo 'set -euo pipefail'; printf '%s\n' "$FENCE"; echo 'echo "FILED_FROM=$FILED_FROM"'; } > "$FENCE_SCRIPT"

# "nothing resolved" is now a REFUSE + exit 1, never a silent none (Copilot
# thread PRRT_kwDORLSfvs6kLM0m).
out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID -u STANDALONE \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE: no source resolved' \
  && ok "S7: nothing resolved (no PR, no session, no flags) -> REFUSE, exit 1, never a silent none" \
  || bad "S7: nothing resolved (no PR, no session, no flags) -> REFUSE, exit 1, never a silent none" "rc=$rc $(flat "$out")"

# --standalone is now an explicit, real resolution path -> none (not the
# terminal else's old catch-all).
out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID STANDALONE=1 \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FILED_FROM=none" ] \
  && ok "S7: --standalone -> none, under set -euo pipefail" \
  || bad "S7: --standalone -> none, under set -euo pipefail" "rc=$rc $(flat "$out")"

out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE CLAUDE_CODE_SESSION_ID=abc123ef \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FILED_FROM=session abc123ef" ] \
  && ok "S7: CLAUDE_CODE_SESSION_ID set -> session <id>, under set -euo pipefail" \
  || bad "S7: CLAUDE_CODE_SESSION_ID set -> session <id>, under set -euo pipefail" "rc=$rc $(flat "$out")"

out=$(env -u FROM_ISSUE -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID -u STANDALONE FROM_PR=99 \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FILED_FROM=#99" ] \
  && ok "S7: --from-pr (FROM_PR) resolves to #99, under set -euo pipefail" \
  || bad "S7: --from-pr (FROM_PR) resolves to #99, under set -euo pipefail" "rc=$rc $(flat "$out")"

out=$(env -u FROM_ISSUE -u CLAUDE_CODE_SESSION_ID -u STANDALONE FROM_PR=99 COMMENT_URL=https://example.com/x \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FILED_FROM=#99 (https://example.com/x)" ] \
  && ok "S7: --from-pr + --comment-url folds the url in, under set -euo pipefail" \
  || bad "S7: --from-pr + --comment-url folds the url in, under set -euo pipefail" "rc=$rc $(flat "$out")"

out=$(env -u FROM_PR -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID -u STANDALONE FROM_ISSUE=7 \
      PATH="$CI_GHBIN:$PATH" bash "$FENCE_SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FILED_FROM=#7" ] \
  && ok "S7: --from-issue (FROM_ISSUE, decompose case) resolves to #7, under set -euo pipefail" \
  || bad "S7: --from-issue (FROM_ISSUE, decompose case) resolves to #7, under set -euo pipefail" "rc=$rc $(flat "$out")"

# --- #363: only an OPEN PR is the source ------------------------------------------------------
# `gh pr view` returns the branch's PR in ANY state, so the first auto-detect read a CLOSED or
# MERGED PR as the PR the work is filed from -- verified live on archery-apprentice, whose
# checkout sits on a branch whose PR 552 is closed. CI_GHBIN above cannot model that: it fails
# every `pr view`, so it can only ever say "no PR". EMU_GHBIN's gh answers from $FAKE_PR_JSON
# the way the real one does: it keeps ONLY the fields named after --json (a template that
# stopped asking for `state` would really see it missing), then applies the caller's own -q
# with `jq -r`, which is what `gh -q` does. A branch with no PR, or a detached HEAD, is a
# nonzero exit with a message on stderr. `label list` is emulated the same way for Group F,
# including gh's default of 30 results when --limit is absent.
# It is also STRICT, and the first assertions below pin that: an emulator that shrugs at an
# unknown flag or field lets a typo in a fence pass every case that follows, because the
# real gh would refuse it and this one would not.
EMU_GHBIN="$TMP/emu_ghbin"; mkdir -p "$EMU_GHBIN"
cat > "$EMU_GHBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
sub="${1:-} ${2:-}"
[ "$sub" = "repo view" ] && { echo "owner/repo"; exit 0; }
# `pr view` and `label list` accept only the flags and --json fields the fences use, and
# refuse the rest the way real gh does. A flag or field that real gh accepts but this
# emulator does not implement fails too, on purpose: extend the emulator first, then the fence.
case "$sub" in
  "pr view") allowed="number state" ;;
  "label list") allowed="name" ;;
  *) echo "fake gh: unhandled invocation: $*" >&2; exit 1 ;;
esac
shift 2
fields=""; q=""; limit=30
while [ $# -gt 0 ]; do
  case "$1" in
    --json|-q|--jq|-L|--limit)
      [ $# -ge 2 ] || { echo "flag needs an argument: $1" >&2; exit 1; }
      case "$1" in --json) fields="$2" ;; -q|--jq) q="$2" ;; *) limit="$2" ;; esac
      shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) echo "fake gh: unexpected argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$fields" ] || { echo "fake gh: only the --json form is emulated" >&2; exit 1; }
for f in $(printf '%s' "$fields" | tr ',' ' '); do
  case " $allowed " in
    *" $f "*) ;;
    *) echo "Unknown JSON field: \"$f\"" >&2; exit 1 ;;
  esac
done
if [ "$sub" = "pr view" ]; then
  if [ -z "${FAKE_PR_JSON:-}" ]; then
    echo "no pull requests found for the current branch (or HEAD is detached)" >&2
    exit 1
  fi
  json=$(printf '%s' "$FAKE_PR_JSON" | jq -c --arg f "$fields" \
    '($f | split(",")) as $keep | with_entries(select(.key as $k | ($keep | index($k)) != null))') \
    || { echo "fake gh: FAKE_PR_JSON is not valid JSON" >&2; exit 2; }
else
  [ -z "${FAKE_LABELS_FAIL:-}" ] || { echo "fake gh: label list failed" >&2; exit 1; }
  json=$(jq -Rn --argjson n "$limit" '[inputs | select(length > 0) | {name: .}] | .[:$n]' \
    < "${FAKE_LABELS_FILE:?}") || { echo "fake gh: could not read the labels fixture" >&2; exit 2; }
fi
if [ -n "$q" ]; then printf '%s' "$json" | jq -r "$q"; else printf '%s\n' "$json"; fi
SH
chmod +x "$EMU_GHBIN/gh"

# The same §1 fence as above, but echoing the PR it resolved as well as the Filed from: value --
# SOURCE_PR is what selects §3's From-Review form and §4's from-review label.
FENCE_SCRIPT2="$TMP/create-issue-filed-from-block-2.sh"
{ echo 'set -euo pipefail'; printf '%s\n' "$FENCE"
  echo 'echo "FILED_FROM=$FILED_FROM"'; echo 'echo "SOURCE_PR=$SOURCE_PR"'; } > "$FENCE_SCRIPT2"
ff2() { printf 'FILED_FROM=%s\nSOURCE_PR=%s' "$1" "$2"; }   # the two lines that script prints

if ! command -v jq >/dev/null 2>&1; then
  bad "#363: jq is required to emulate gh's --json/-q for these cases (CI's ubuntu-latest has it)" "jq not found on PATH"
else
  # The emulator must stay strict. Each of these is something real gh refuses, and these
  # assertions are what stop a later edit from quietly making the emulator permissive again.
  printf 'bug\n' > "$TMP/emu-selftest-labels.txt"
  out=$(FAKE_LABELS_FILE="$TMP/emu-selftest-labels.txt" "$EMU_GHBIN/gh" label list --no-such-flag --json name 2>&1); rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "unknown flag: --no-such-flag" ] \
    && ok "emulator: an unknown flag is refused, exit 1 (label list --no-such-flag)" \
    || bad "emulator: an unknown flag is refused, exit 1 (label list --no-such-flag)" "rc=$rc $(flat "$out")"

  out=$(FAKE_PR_JSON='{"number":41,"state":"OPEN"}' "$EMU_GHBIN/gh" pr view --json number,noSuchField 2>&1); rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = 'Unknown JSON field: "noSuchField"' ] \
    && ok "emulator: an unknown --json field is refused, exit 1 (pr view --json number,noSuchField)" \
    || bad "emulator: an unknown --json field is refused, exit 1 (pr view --json number,noSuchField)" "rc=$rc $(flat "$out")"

  out=$(FAKE_PR_JSON='{"number":41,"state":"OPEN"}' "$EMU_GHBIN/gh" pr view 41 --json number 2>&1); rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = "fake gh: unexpected argument: 41" ] \
    && ok "emulator: a positional argument is refused, exit 1 (pr view 41)" \
    || bad "emulator: a positional argument is refused, exit 1 (pr view 41)" "rc=$rc $(flat "$out")"

  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE CLAUDE_CODE_SESSION_ID=abc123ef \
        FAKE_PR_JSON='{"number":41,"state":"OPEN"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 '#41' 41)" ] \
    && ok "#363: an OPEN PR on the branch is the source -> #41, SOURCE_PR=41" \
    || bad "#363: an OPEN PR on the branch is the source -> #41, SOURCE_PR=41" "rc=$rc $(flat "$out")"

  # The archery-apprentice case: the old form printed 552 here.
  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE CLAUDE_CODE_SESSION_ID=abc123ef \
        FAKE_PR_JSON='{"number":552,"state":"CLOSED"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 'session abc123ef' '')" ] \
    && ok "#363: a CLOSED PR is no source (archery's 552) -> the session id, SOURCE_PR empty" \
    || bad "#363: a CLOSED PR is no source (archery's 552) -> the session id, SOURCE_PR empty" "rc=$rc $(flat "$out")"

  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE CLAUDE_CODE_SESSION_ID=abc123ef \
        FAKE_PR_JSON='{"number":364,"state":"MERGED"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 'session abc123ef' '')" ] \
    && ok "#363: a MERGED PR is no source either -> the session id, SOURCE_PR empty" \
    || bad "#363: a MERGED PR is no source either -> the session id, SOURCE_PR empty" "rc=$rc $(flat "$out")"

  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID STANDALONE=1 \
        FAKE_PR_JSON='{"number":552,"state":"CLOSED"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 'none' '')" ] \
    && ok "#363: --standalone works on a closed-PR branch -> none, SOURCE_PR empty" \
    || bad "#363: --standalone works on a closed-PR branch -> none, SOURCE_PR empty" "rc=$rc $(flat "$out")"

  # Explicit flags outrank the auto-detected PR, and SOURCE_PR follows what Filed from: names.
  out=$(env -u FROM_PR -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID -u STANDALONE FROM_ISSUE=7 \
        FAKE_PR_JSON='{"number":41,"state":"OPEN"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 '#7' '')" ] \
    && ok "#363: --from-issue outranks an OPEN PR -> #7, SOURCE_PR empty (no from-review)" \
    || bad "#363: --from-issue outranks an OPEN PR -> #7, SOURCE_PR empty (no from-review)" "rc=$rc $(flat "$out")"

  out=$(env -u FROM_ISSUE -u COMMENT_URL -u CLAUDE_CODE_SESSION_ID -u STANDALONE FROM_PR=99 \
        FAKE_PR_JSON='{"number":41,"state":"OPEN"}' PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 '#99' 99)" ] \
    && ok "#363: --from-pr outranks an OPEN PR -> #99, SOURCE_PR=99 (the PR Filed from: names, not the branch's)" \
    || bad "#363: --from-pr outranks an OPEN PR -> #99, SOURCE_PR=99 (the PR Filed from: names, not the branch's)" "rc=$rc $(flat "$out")"

  # No PR at all, or a detached HEAD: gh exits 1, which reads as none.
  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE -u FAKE_PR_JSON CLAUDE_CODE_SESSION_ID=abc123ef \
        PATH="$EMU_GHBIN:$PATH" bash "$FENCE_SCRIPT2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$(ff2 'session abc123ef' '')" ] \
    && ok "#363: no PR on the branch (or a detached HEAD) -> the session id, SOURCE_PR empty" \
    || bad "#363: no PR on the branch (or a detached HEAD) -> the session id, SOURCE_PR empty" "rc=$rc $(flat "$out")"
fi

# ============================================== GROUP F — #357, #369: create-issue.md §4's labels
echo; echo "F. #357, #369 — create-issue.md §4's label set, built and verified for real"

# This lives here rather than in a file of its own because this suite already does the one thing
# the check needs -- extracts create-issue.md's fenced bash and RUNS it, against a fake gh, under
# set -euo pipefail -- and is already a CI step (validate-registry.yml has no *.test.sh glob, so
# a new file would need a step of its own). What it pins:
#   #357: `gh label list` returns only 30 labels, oldest first, so on a repo with more, every
#         label past the 30th read as missing and was silently dropped. The fixture puts
#         `from-review` at position 31 -- archery-apprentice's shape, which has 32 labels.
#   #363 (the from-review half): SOURCE_PR is set only from the PR the issue is filed from,
#         which is now only ever an OPEN one, so a closed-PR branch no longer earns from-review.
#   #369: §4 looped over `"${EXTRA_LABELS[@]}"`, an array nothing defined -- an unbound variable
#         under `set -u` in bash 3.2. §1 now defaults COMPLEXITY and EXTRA_LABELS like its other
#         flag values, so a case passes them through the environment, as Group E passes FROM_PR,
#         and F8 runs with both unset.
# ONE script is built from three fences, in order -- §1 (REPO, FILED_FROM, SOURCE_PR, the flag
# defaults), §4's label-building fence and §4's verification fence -- so what is asserted is the
# LABELS a real run would hand to `gh issue create`, not what each fence does alone. Every case
# pins the EXACT line, because a leading or trailing comma, an empty element or a wrongly
# dropped label each change it, and an empty stderr wherever nothing may be reported.
# F9 is the one place a fence runs alone. An agent's shell keeps nothing between calls and does
# not set -u, so a fence can run with the block before it never having run; it is run in a plain
# bash with those inputs unset, because -u alone would mask exactly what is being checked.
F_LABELS="$TMP/f-labels.txt"
{
  printf '%s\n' bug 'priority: low' Tech-Debt           # 1-3: named labels, Tech-Debt mixed-case on purpose
  for i in $(seq 4 28); do printf 'l%02d\n' "$i"; done   # 4-28: filler
  printf '%s\n' -dash enhancement from-review            # 29: a leading dash, for the grep's `--`; 30, 31
} > "$F_LABELS"

LABELS_FENCE=$(extract_bash_fence_after "$GENERIC/create-issue.md" '### 4\. Determine Labels')
VERIFY_FENCE=$(extract_bash_fence_after "$GENERIC/create-issue.md" '\*\*Verify labels exist\*\*')
F_SCRIPT="$TMP/create-issue-labels-block.sh"
{ echo 'set -euo pipefail'; printf '%s\n' "$FENCE" "$LABELS_FENCE" "$VERIFY_FENCE"
  echo 'echo "LABELS=$LABELS"'; } > "$F_SCRIPT"

labels_are() {  # labels_are <csv> -- the run exited 0 and printed exactly this LABELS line
  [ "$rc" -eq 0 ] && [ "$out" = "LABELS=$1" ]
}
one_warning() {  # one_warning <label> -- stderr is exactly one Warning, and it names that label
  [ "$(printf '%s\n' "$err" | grep -c '^Warning:')" -eq 1 ] \
    && printf '%s\n' "$err" | grep -qF "Warning: '$1' label not found"
}
run_f() {  # run_f [VAR=val ...] -- one run of the script above with every ambient input cleared
           # first, so a variable inherited from whoever runs this suite (CLAUDE_CODE_SESSION_ID
           # is set in every agent session) cannot decide a case. Sets $out, $err and $rc.
  local errfile; errfile=$(mktemp)
  out=$(env -u FROM_PR -u FROM_ISSUE -u COMMENT_URL -u STANDALONE -u CLAUDE_CODE_SESSION_ID \
        -u FAKE_PR_JSON -u FAKE_LABELS_FAIL -u COMPLEXITY -u EXTRA_LABELS \
        FAKE_LABELS_FILE="$F_LABELS" PATH="$EMU_GHBIN:$PATH" "$@" bash "$F_SCRIPT" 2>"$errfile")
  rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"
}
run_alone() {  # run_alone <script> -- one §4 fence on its own, in a plain bash (no set -e or -u)
               # with none of the inputs the blocks before it would have set. Sets $out, $err, $rc.
  local errfile; errfile=$(mktemp)
  out=$(env -u LABELS -u REPO -u FILED_FROM -u SOURCE_PR -u COMMENT_URL -u COMPLEXITY -u EXTRA_LABELS \
        FAKE_LABELS_FILE="$F_LABELS" PATH="$EMU_GHBIN:$PATH" bash "$1" 2>"$errfile")
  rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"
}

if ! command -v jq >/dev/null 2>&1; then
  bad "F: jq is required to emulate gh's --json/-q (CI's ubuntu-latest has it)" "jq not found on PATH"
elif [ -z "$LABELS_FENCE" ] || [ -z "$VERIFY_FENCE" ]; then
  bad "F: could not extract §4's bash fences from create-issue.md" \
      "is the '### 4. Determine Labels' heading or the '**Verify labels exist**' marker renamed?"
else
  # F1 -- from-review is label 31 of 31: it survives only because the listing asks for --limit
  # 500. tech-debt is asked for in lowercase and the repo spells it Tech-Debt. Every label
  # exists, so nothing may be reported missing: stderr stays empty.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' EXTRA_LABELS='priority: low,tech-debt'
  labels_are 'enhancement,from-review,priority: low,tech-debt' && [ -z "$err" ] \
    && ok "F1: from-review at position 31 is kept (--limit 500); tech-debt matches Tech-Debt; no warning" \
    || bad "F1: from-review at position 31 is kept (--limit 500); tech-debt matches Tech-Debt; no warning" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F2 -- #363's AC: a branch whose PR is CLOSED earns no from-review. The session id resolves
  # Filed from:, SOURCE_PR stays empty, and the rest of the set is untouched.
  run_f FAKE_PR_JSON='{"number":552,"state":"CLOSED"}' CLAUDE_CODE_SESSION_ID=abc123ef EXTRA_LABELS='priority: low'
  labels_are 'enhancement,priority: low' && [ -z "$err" ] \
    && ok "F2: a CLOSED-PR branch does not earn from-review (#363); the rest of the set is intact" \
    || bad "F2: a CLOSED-PR branch does not earn from-review (#363); the rest of the set is intact" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F3 -- a label the repo lacks is skipped with a warning, never fatal, and takes nothing else
  # down with it.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' EXTRA_LABELS='priority: low,nonexistent-label'
  labels_are 'enhancement,from-review,priority: low' \
    && ok "F3: a label the repo lacks is dropped; enhancement, from-review and priority: low are kept, exit 0" \
    || bad "F3: a label the repo lacks is dropped; enhancement, from-review and priority: low are kept, exit 0" \
           "rc=$rc out=$out err=$(flat "$err")"
  one_warning nonexistent-label \
    && ok "F3: the drop is one Warning on stderr naming the label" \
    || bad "F3: the drop is one Warning on stderr naming the label" "err=$(flat "$err")"

  # F3b -- names match WHOLE: `review` is a substring of the repo's from-review and must still
  # read as missing.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' EXTRA_LABELS='priority: low,review'
  labels_are 'enhancement,from-review,priority: low' && one_warning review \
    && ok "F3b: names match whole -- review is dropped although it is a substring of from-review" \
    || bad "F3b: names match whole -- review is dropped although it is a substring of from-review" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F4 -- a failed listing must not read as "the repo has no labels": that would file the issue
  # unlabeled and look like success.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' FAKE_LABELS_FAIL=1
  [ "$rc" -eq 1 ] && [ -z "$out" ] && printf '%s\n' "$err" | grep -q '^REFUSE: could not list labels' \
    && ok "F4: a failed label listing REFUSES, exit 1, files nothing -- never an unlabeled issue" \
    || bad "F4: a failed label listing REFUSES, exit 1, files nothing -- never an unlabeled issue" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F5 -- the fixture really does reproduce #357. Asked the way the OLD template asked (no
  # --limit), the emulated gh returns gh's default 30 and from-review is not among them, while
  # enhancement (position 30) still is -- so F1 passing depends on --limit 500 and on nothing else.
  unl=$(FAKE_LABELS_FILE="$F_LABELS" "$EMU_GHBIN/gh" label list --json name -q '.[].name')
  lim=$(FAKE_LABELS_FILE="$F_LABELS" "$EMU_GHBIN/gh" label list --limit 500 --json name -q '.[].name')
  n_unl=$(printf '%s\n' "$unl" | grep -c .); n_lim=$(printf '%s\n' "$lim" | grep -c .)
  [ "$n_unl" -eq 30 ] && [ "$n_lim" -eq 31 ] \
    && grep -qxF -- enhancement <<< "$unl" && ! grep -qxF -- from-review <<< "$unl" \
    && grep -qxF -- from-review <<< "$lim" \
    && ok "F5: the fixture reproduces #357 -- without --limit gh returns 30 labels and from-review is not among them" \
    || bad "F5: the fixture reproduces #357 -- without --limit gh returns 30 labels and from-review is not among them" \
           "default=$n_unl limit500=$n_lim"

  # F6 -- a label whose name starts with a dash reaches grep as data, not as an option: the `--`
  # in `grep -qixF -- "$LABEL"`. Without it grep reads -dash as `-d ash` and errors, so a label
  # that exists is dropped with a warning.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' EXTRA_LABELS=-dash
  labels_are 'enhancement,from-review,-dash' && [ -z "$err" ] \
    && ok "F6: a label starting with a dash is matched as data (the -- in grep), kept, no warning" \
    || bad "F6: a label starting with a dash is matched as data (the -- in grep), kept, no warning" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F7 -- an empty element is skipped silently: the `continue`. The doubled comma sits in the
  # MIDDLE on purpose, because a trailing comma would not test this -- $(...) strips the trailing
  # newline before the loop ever sees it. Without the `continue` the empty name goes to grep,
  # matches nothing, and is reported as a missing label.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}' EXTRA_LABELS='priority: low,,tech-debt'
  labels_are 'enhancement,from-review,priority: low,tech-debt' && [ -z "$err" ] \
    && ok "F7: an empty element (a doubled comma) is skipped without a warning" \
    || bad "F7: an empty element (a doubled comma) is skipped without a warning" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F8 -- #369: nothing supplied at all. EXTRA_LABELS and COMPLEXITY are both unset in the
  # caller's environment, and the block still runs clean under set -euo pipefail. The old array
  # loop died here, in bash 3.2, on an unbound variable. Newer bash (5.2 checked) tolerates an
  # undeclared array under set -u, so only a bash 3.2 run (macOS's /bin/bash) can see that half
  # of the defect; on bash 5 this case still catches COMPLEXITY or EXTRA_LABELS going unbound.
  run_f FAKE_PR_JSON='{"number":41,"state":"OPEN"}'
  labels_are 'enhancement,from-review' && [ -z "$err" ] \
    && ok "F8: #369 -- EXTRA_LABELS and COMPLEXITY both unset runs clean under set -euo pipefail" \
    || bad "F8: #369 -- EXTRA_LABELS and COMPLEXITY both unset runs clean under set -euo pipefail" \
           "rc=$rc out=$out err=$(flat "$err")"

  # F9 -- the input guards, each fence ALONE (review S1). Run in a fresh shell, which is all an
  # agent has between calls, the verification fence used to exit 0 with LABELS empty -- an
  # issue filed unlabeled with no warning -- and the label-building fence built a set from
  # nothing. Both now stop and say which block to run first.
  F9_VERIFY="$TMP/f9-verify-alone.sh"; printf '%s\n' "$VERIFY_FENCE" > "$F9_VERIFY"
  F9_BUILD="$TMP/f9-build-alone.sh";   printf '%s\n' "$LABELS_FENCE" > "$F9_BUILD"
  run_alone "$F9_VERIFY"
  [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q 'LABELS' \
    && ok "F9: the verification fence run alone (LABELS and REPO unset) stops, naming LABELS" \
    || bad "F9: the verification fence run alone (LABELS and REPO unset) stops, naming LABELS" \
           "rc=$rc out=$out err=$(flat "$err")"
  run_alone "$F9_BUILD"
  [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q 'FILED_FROM' \
    && ok "F9: the label-building fence run alone (FILED_FROM unset) stops, naming FILED_FROM" \
    || bad "F9: the label-building fence run alone (FILED_FROM unset) stops, naming FILED_FROM" \
           "rc=$rc out=$out err=$(flat "$err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
