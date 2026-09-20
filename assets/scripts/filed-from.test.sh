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


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
