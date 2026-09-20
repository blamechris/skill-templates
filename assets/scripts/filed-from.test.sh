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
# Does NOT `set -e`: an assertion that fails must be reported and the rest
# still run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/filed-from.py"
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

# ============================================================ GROUP B — check
echo; echo "B. check"

# Fake gh: logs every invocation (one line per call, space-joined argv) to
# $GH_LOG so tests can assert what filed-from.py actually asked for, and
# answers from fixture files under $GH_FIXTURES. GH_FAIL=1 makes every call
# fail, for the exit-2 path.
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
    label=0; search=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --label) label=1; shift 2 ;;
        --search) search="$2"; shift 2 ;;
        --repo|--state|--limit|--json) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$search" ]; then
      n=$(printf '%s' "$search" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
      cat "$FIX/children-$n.json" 2>/dev/null || echo '[]'
    elif [ "$label" = 1 ]; then
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
cat > "$FIX/list-labeled.json" <<'JSON'
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
cat > "$FIX/list-labeled.json" <<'JSON'
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

# --- --all drops the --label filter (asserted on what gh was actually asked) -
cat > "$FIX/list-all.json" <<'JSON'
[{"number": 20, "title": "unlabelled", "url": "u20", "labels": [],
  "body": "## Context\n\nFiled from: none\n"}]
JSON
GH_LOG="$TMP/log-all.txt"; : > "$GH_LOG"
out=$(GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates --all)
grep -q -- '--label from-review' "$GH_LOG" \
  && bad "check --all: gh was NOT asked to drop --label" "$(cat "$GH_LOG")" \
  || ok "check --all: gh was asked without --label from-review"
grep -q '^issue list ' "$GH_LOG" \
  && ok "check --all: an issue list call did happen" \
  || bad "check --all: an issue list call did happen" "$(cat "$GH_LOG")"

# without --all, the label IS present
GH_LOG="$TMP/log-labeled.txt"; : > "$GH_LOG"
GH_LOG="$GH_LOG" run_ff "$FIX" 0 check --repo blamechris/skill-templates >/dev/null
grep -q -- '--label from-review' "$GH_LOG" \
  && ok "check (default): gh WAS asked with --label from-review" \
  || bad "check (default): gh WAS asked with --label from-review" "$(cat "$GH_LOG")"

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

# ============================================================ GROUP C — chain
echo; echo "C. chain"

CFIX="$TMP/cfix"; mkdir -p "$CFIX"
echo '"blamechris/skill-templates"' > "$CFIX/repo.json"

# Three-link fixture: #10 (issue, standalone) <- #20 (PR, filed from #10) <-
# #30 (issue, filed from #20). #20 has no issue-20.json, only pr-20.json, so
# _fetch_node's issue-then-pr fallback is exercised for real.
cat > "$CFIX/issue-10.json" <<'JSON'
{"number": 10, "title": "root ancestor", "state": "CLOSED",
 "body": "## Context\n\nFiled from: none\n"}
JSON
cat > "$CFIX/pr-20.json" <<'JSON'
{"number": 20, "title": "the PR in the middle", "state": "MERGED",
 "body": "## Context\n\nFiled from: #10\n"}
JSON
cat > "$CFIX/issue-30.json" <<'JSON'
{"number": 30, "title": "the child issue", "state": "OPEN",
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
 "body": "## Context\n\nFiled from: #41\n"}
JSON
cat > "$CFIX/issue-41.json" <<'JSON'
{"number": 41, "title": "cycle b", "state": "OPEN",
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


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
