#!/usr/bin/env bash
# Regression tests for assets/scripts/review-result.py.
#
# These call the script. Fixtures are built once, in Python, into a fake
# $HOME/.claude/projects tree — the same shape real subagent sidecars and
# Workflow runs leave on disk (see the docstring's pointer to the real
# session used to shape this: an Aeolus session with 15 subagent pairs and
# 11 workflow files). Nothing is asserted against prose; every case calls
# the script and checks its exit code, its stdout/stderr, and the files it
# did or did not write.
#
# The suite does NOT `set -e`: half the properties under test are "the
# REFUSE fired and nothing was written", and a failed assertion must be
# allowed to keep running the rest of the suite rather than abort silently.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/review-result.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-result-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# The env var review-result.py resolves the session id from. Some harnesses
# (this one, on the author's machine) already export it — the "unset
# session id" case would silently pass on a fake positive if it leaked in
# from the wrapping shell, so it is unset unconditionally, exactly the way
# session-seed.test.sh unsets CLAUDE_HANDOFF_DIR/CLAUDE_CODE_SESSION_ID.
unset CLAUDE_CODE_SESSION_ID

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
flat(){ printf '%s' "$1" | tr '\n' '|'; }

echo "review-result.test.sh"

# ------------------------------------------------------------------ fixtures
HOMEDIR="$TMP/home"
PROJ="$HOMEDIR/.claude/projects/-fake-proj"
mkdir -p "$PROJ"

# Built once, in Python, so every fixture is genuinely valid JSON — a shell
# heredoc constructing JSON-with-embedded-JSON is exactly the kind of
# quoting trap this suite exists to not fall into.
"$PY" - "$PROJ" "$HOMEDIR" <<'PYEOF'
import json, os, sys

proj, home = sys.argv[1], sys.argv[2]

def jsonl(path, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for o in objs:
            f.write(json.dumps(o) + "\n")

def jfile(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)

def assistant(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}

def fenced(doc):
    return "```json review-result\n" + json.dumps(doc) + "\n```"

GOOD = {"verdict": "approve", "body_matches_tree": True,
        "findings": [{"severity": "nitpick", "title": "t", "evidence": "e",
                       "mutation_ran": False, "red_line": False}]}

# ---- sess-rec: ordinary record() success + unknown-agent REFUSE target ----
sdir = os.path.join(proj, "sess-rec")
jfile(os.path.join(sdir, "subagents", "agent-aec00001.meta.json"), {"agentType": "general-purpose"})
jsonl(os.path.join(sdir, "subagents", "agent-aec00001.jsonl"), [])

# ---- sess-force: pre-existing .result.json for the overwrite/--force path ----
sdir = os.path.join(proj, "sess-force")
jfile(os.path.join(sdir, "subagents", "agent-aec00002.meta.json"), {"agentType": "general-purpose"})
jsonl(os.path.join(sdir, "subagents", "agent-aec00002.jsonl"), [])
jfile(os.path.join(sdir, "subagents", "agent-aec00002.result.json"),
      {"schema": 1, "source": "record", "recorded_at": "2020-01-01T00:00:00Z",
       "session": "sess-force", "agent": "agent-aec00002", "skill": "old-skill",
       "pr": 1, "result": {"verdict": "comment", "body_matches_tree": None, "findings": []}})

# ---- sess-harvest: the four harvest cases ----
sdir = os.path.join(proj, "sess-harvest")
harvest_doc = {"verdict": "request_changes", "body_matches_tree": False,
               "findings": [
                   {"severity": "critical", "title": "bug found", "evidence": "stack trace X",
                    "mutation_ran": True, "red_line": False},
                   {"severity": "suggestion", "title": "minor", "evidence": "note",
                    "mutation_ran": False, "red_line": False},
               ], "skill": "agent-review", "pr": 99}
jsonl(os.path.join(sdir, "subagents", "agent-aaaa.jsonl"), [
    {"type": "user", "message": {"content": [{"type": "text", "text": "go"}]}},
    assistant("first draft, ignore, no block"),
    {"type": "attachment", "payload": "x"},
    assistant("Final report.\n\n" + fenced(harvest_doc) + "\n"),
])
jsonl(os.path.join(sdir, "subagents", "agent-bbbb.jsonl"), [
    assistant("prose only, no structured block"),
])
jsonl(os.path.join(sdir, "subagents", "agent-cccc.jsonl"), [
    assistant("Final report.\n\n" + fenced(GOOD)),
])
jfile(os.path.join(sdir, "subagents", "agent-cccc.result.json"),
      {"schema": 1, "source": "record", "session": "sess-harvest", "agent": "agent-cccc",
       "result": GOOD})
jsonl(os.path.join(sdir, "subagents", "agent-dddd.jsonl"), [
    assistant(fenced({"verdict": "bogus", "body_matches_tree": True, "findings": []})),
])

# ---- sess-list: list's own-result.json + workflow recursive-walk ----
sdir = os.path.join(proj, "sess-list")
jfile(os.path.join(sdir, "subagents", "agent-list0001.result.json"),
      {"schema": 1, "source": "record", "recorded_at": "2026-09-01T00:00:00Z",
       "session": "sess-list", "agent": "agent-list0001", "skill": "agent-review", "pr": 55,
       "result": {
           "verdict": "approve", "body_matches_tree": True,
           "findings": [
               {"severity": "critical", "title": "c1", "evidence": "e", "mutation_ran": True, "red_line": False},
               {"severity": "critical", "title": "c2", "evidence": "e", "mutation_ran": False, "red_line": False},
               {"severity": "suggestion", "title": "s1", "evidence": "e", "mutation_ran": False, "red_line": False},
               {"severity": "nitpick", "title": "n1", "evidence": "e", "mutation_ran": False, "red_line": False},
           ], "pr": 55, "skill": "agent-review",
       }})
# A malformed .result.json (no `findings`) — list must warn and skip it, not crash.
jfile(os.path.join(sdir, "subagents", "agent-list0002.result.json"),
      {"schema": 1, "source": "record", "session": "sess-list", "agent": "agent-list0002",
       "result": {"verdict": "approve", "body_matches_tree": None}})
jfile(os.path.join(sdir, "workflows", "wf_xyz.json"), {
    "runId": "wf_xyz",
    "result": [
        {"pr": 10, "tier": "MEDIUM", "delta": {
            "verdict": "comment", "body_matches_tree": None,
            "findings": [{"severity": "nitpick", "title": "n", "evidence": "e",
                          "mutation_ran": True, "red_line": False}],
        }},
        {"pr": 11, "tier": "LOW", "fix": {"pr": 11, "fixed": []}},
    ],
})

# ---- ambiguous session dir: same session id under two project slugs ----
os.makedirs(os.path.join(proj + "-a", "sess-ambig"), exist_ok=True)
os.makedirs(os.path.join(proj + "-b", "sess-ambig"), exist_ok=True)

print("fixtures OK")
PYEOF

# --------------------------------------------------------------------- I/O
GOOD='{"verdict":"approve","body_matches_tree":true,"findings":[{"severity":"nitpick","title":"t","evidence":"e","mutation_ran":false,"red_line":false}]}'
BAD_SEVERITY='{"verdict":"approve","body_matches_tree":true,"findings":[{"severity":"high","title":"t","evidence":"e","mutation_ran":false,"red_line":false}]}'
BAD_MISSING_EVIDENCE='{"verdict":"approve","body_matches_tree":true,"findings":[{"severity":"nitpick","title":"t","mutation_ran":false,"red_line":false}]}'
BAD_MUTATION_TYPE='{"verdict":"approve","body_matches_tree":true,"findings":[{"severity":"nitpick","title":"t","evidence":"e","mutation_ran":"yes","red_line":false}]}'
NO_JSON='just some prose, no fenced block and not JSON either'

# run <session-id-or-'-'> [args...]        (no stdin)
run() {
  local sid=$1; shift
  if [ "$sid" = "-" ]; then
    out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>&1); rc=$?
  else
    out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>&1); rc=$?
  fi
}
# run_in <session-id-or-'-'> <stdin-text> [args...]
run_in() {
  local sid=$1 input=$2; shift 2
  if [ "$sid" = "-" ]; then
    out=$(printf '%s' "$input" | HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>&1); rc=$?
  else
    out=$(printf '%s' "$input" | HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>&1); rc=$?
  fi
}
# run_stdout <session-id-or-'-'> args...  — stdout only, stderr discarded.
# For --json: a warning on stderr (e.g. skipping a malformed .result.json)
# must never land in the captured text, or a real warning would corrupt the
# very round-trip this is checking.
run_stdout() {
  local sid=$1; shift
  if [ "$sid" = "-" ]; then
    out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>/dev/null); rc=$?
  else
    out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>/dev/null); rc=$?
  fi
}
count_results() { find "$PROJ/$1/subagents" -maxdepth 1 -name '*.result.json' 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================== GROUP A — schema
echo; echo "A. schema"

run - schema
[ "$rc" -eq 0 ] && ok "schema exits 0" || bad "schema exits 0" "rc=$rc"
printf '%s' "$out" | "$PY" -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
  && ok "schema prints parseable JSON" || bad "schema prints parseable JSON" "$(flat "$out")"
printf '%s' "$out" | grep -q '"verdict"' && printf '%s' "$out" | grep -q '"mutation_ran"' \
  && printf '%s' "$out" | grep -q '"red_line"' \
  && ok "schema names verdict, mutation_ran, red_line" \
  || bad "schema names verdict, mutation_ran, red_line" "$(flat "$out")"

# ============================================================ GROUP B — validate
echo; echo "B. validate"

run_in - "$GOOD" validate
[ "$rc" -eq 0 ] && ok "validate accepts a good document (stdin)" \
  || bad "validate accepts a good document (stdin)" "rc=$rc $(flat "$out")"

echo "$GOOD" > "$TMP/good.json"
run - validate "$TMP/good.json"
[ "$rc" -eq 0 ] && ok "validate accepts a good document (file arg)" \
  || bad "validate accepts a good document (file arg)" "rc=$rc $(flat "$out")"

run_in - "Some agent report.

\`\`\`json review-result
$GOOD
\`\`\`

more prose after it" validate
[ "$rc" -eq 0 ] && ok "validate extracts a fenced review-result block from a full report" \
  || bad "validate extracts a fenced review-result block from a full report" "rc=$rc $(flat "$out")"

run_in - "$BAD_SEVERITY" validate
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "findings\[0\].severity" \
  && ok "validate rejects a bad severity, names findings[0].severity" \
  || bad "validate rejects a bad severity, names findings[0].severity" "rc=$rc $(flat "$out")"

run_in - "$BAD_MISSING_EVIDENCE" validate
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "findings\[0\].evidence" \
  && ok "validate rejects missing evidence, names findings[0].evidence" \
  || bad "validate rejects missing evidence, names findings[0].evidence" "rc=$rc $(flat "$out")"

run_in - "$BAD_MUTATION_TYPE" validate
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "findings\[0\].mutation_ran" \
  && ok "validate rejects wrong-type mutation_ran, names findings[0].mutation_ran" \
  || bad "validate rejects wrong-type mutation_ran, names findings[0].mutation_ran" "rc=$rc $(flat "$out")"

run_in - "$NO_JSON" validate
[ "$rc" -eq 2 ] && ok "validate exits 2 when no block and no JSON is found" \
  || bad "validate exits 2 when no block and no JSON is found" "rc=$rc $(flat "$out")"

# ============================================================== GROUP C — record
echo; echo "C. record"

before=$(count_results sess-rec)
run_in sess-rec "$GOOD" record --agent agent-aec00001 --skill agent-review --pr 42
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^result: ' \
  && ok "record writes and prints the proof line" \
  || bad "record writes and prints the proof line" "rc=$rc $(flat "$out")"
RESULT_PATH="$PROJ/sess-rec/subagents/agent-aec00001.result.json"
[ -f "$RESULT_PATH" ] && ok "record's target file exists" || bad "record's target file exists" "missing $RESULT_PATH"
"$PY" - "$RESULT_PATH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == 1
assert d["source"] == "record"
assert d["session"] == "sess-rec"
assert d["agent"] == "agent-aec00001"
assert d["skill"] == "agent-review"
assert d["pr"] == 42
assert d["result"]["verdict"] == "approve"
assert "recorded_at" in d
PY
[ $? -eq 0 ] && ok "record's file wraps the result with schema/source/session/agent/skill/pr" \
  || bad "record's file wraps the result with schema/source/session/agent/skill/pr" "$(cat "$RESULT_PATH")"

# --agent accepted bare-hex too, and --pr/--skill override the document's own fields
run_in sess-rec "$GOOD" record --agent aec00001 --skill full-review --force
"$PY" - "$RESULT_PATH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["skill"] == "full-review", d
assert d["result"]["skill"] == "full-review", d
PY
[ "$rc" -eq 0 ] && [ $? -eq 0 ] \
  && ok "--agent accepts bare hex, and --skill overrides the document's own field" \
  || bad "--agent accepts bare hex, and --skill overrides the document's own field" "rc=$rc $(flat "$out")"

# REFUSE: unset session id — nothing written
before=$(count_results sess-rec)
run_in - "$GOOD" record --agent agent-aec00001 --skill agent-review
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
  && ok "record REFUSEs with unset session id" \
  || bad "record REFUSEs with unset session id" "rc=$rc $(flat "$out")"
after=$(count_results sess-rec)
[ "$before" = "$after" ] && ok "unset-session REFUSE wrote nothing" \
  || bad "unset-session REFUSE wrote nothing" "before=$before after=$after"

# REFUSE: unknown agent — nothing written
before=$(count_results sess-rec)
run_in sess-rec "$GOOD" record --agent agent-doesnotexist --skill agent-review
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
  && ok "record REFUSEs on an unknown agent id" \
  || bad "record REFUSEs on an unknown agent id" "rc=$rc $(flat "$out")"
after=$(count_results sess-rec)
[ "$before" = "$after" ] && [ ! -f "$PROJ/sess-rec/subagents/agent-doesnotexist.result.json" ] \
  && ok "unknown-agent REFUSE wrote nothing" \
  || bad "unknown-agent REFUSE wrote nothing" "before=$before after=$after"

# REFUSE: ambiguous session dir (two project slugs share the id) — nothing written
run_in sess-ambig "$GOOD" record --agent agent-aec00099 --skill agent-review
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^REFUSE:' && printf '%s' "$out" | grep -q 'found 2' \
  && ok "record REFUSEs on an ambiguous session directory (found 2)" \
  || bad "record REFUSEs on an ambiguous session directory (found 2)" "rc=$rc $(flat "$out")"

# REFUSE: missing session dir — nothing written
run_in sess-does-not-exist-anywhere "$GOOD" record --agent agent-aec00099 --skill agent-review
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^REFUSE:' && printf '%s' "$out" | grep -q 'found 0' \
  && ok "record REFUSEs when no session directory matches (found 0)" \
  || bad "record REFUSEs when no session directory matches (found 0)" "rc=$rc $(flat "$out")"

# REFUSE: existing .result.json without --force — original left untouched
ORIG=$(cat "$PROJ/sess-force/subagents/agent-aec00002.result.json")
run_in sess-force "$GOOD" record --agent agent-aec00002 --skill agent-review
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'already exists' \
  && ok "record refuses to overwrite an existing .result.json without --force" \
  || bad "record refuses to overwrite an existing .result.json without --force" "rc=$rc $(flat "$out")"
AFTER=$(cat "$PROJ/sess-force/subagents/agent-aec00002.result.json")
[ "$ORIG" = "$AFTER" ] && ok "the un-forced overwrite attempt left the file byte-identical" \
  || bad "the un-forced overwrite attempt left the file byte-identical" "changed"

# --force allows the overwrite
run_in sess-force "$GOOD" record --agent agent-aec00002 --skill agent-review --pr 777 --force
NEW=$(cat "$PROJ/sess-force/subagents/agent-aec00002.result.json")
[ "$rc" -eq 0 ] && [ "$ORIG" != "$NEW" ] && printf '%s' "$NEW" | grep -q '"pr": 777' \
  && ok "--force overwrites the existing .result.json" \
  || bad "--force overwrites the existing .result.json" "rc=$rc"

# ============================================================= GROUP D — harvest
echo; echo "D. harvest"

run sess-harvest harvest
[ "$rc" -eq 0 ] && ok "harvest exits 0" || bad "harvest exits 0" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -Eq 'recorded 1, skipped-existing 1, no-block 1, invalid 1' \
  && ok "harvest's summary line: recorded 1, skipped-existing 1, no-block 1, invalid 1" \
  || bad "harvest's summary line: recorded 1, skipped-existing 1, no-block 1, invalid 1" "$(flat "$out")"
[ -f "$PROJ/sess-harvest/subagents/agent-aaaa.result.json" ] \
  && ok "harvest recorded the block from the last assistant message" \
  || bad "harvest recorded the block from the last assistant message" "missing"
"$PY" - "$PROJ/sess-harvest/subagents/agent-aaaa.result.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["source"] == "harvest"
assert d["result"]["verdict"] == "request_changes"
assert d["pr"] == 99
PY
[ $? -eq 0 ] && ok "harvest's record carries source=harvest and the document's own fields" \
  || bad "harvest's record carries source=harvest and the document's own fields" "$(cat "$PROJ/sess-harvest/subagents/agent-aaaa.result.json")"
[ ! -f "$PROJ/sess-harvest/subagents/agent-bbbb.result.json" ] \
  && ok "harvest ignores a transcript with no fenced block" \
  || bad "harvest ignores a transcript with no fenced block" "wrote one anyway"
printf '%s' "$out" | grep -q 'invalid: agent-dddd' \
  && ok "harvest reports (not crashes on) an invalid block, by agent id" \
  || bad "harvest reports (not crashes on) an invalid block, by agent id" "$(flat "$out")"
[ ! -f "$PROJ/sess-harvest/subagents/agent-dddd.result.json" ] \
  && ok "an invalid block is never recorded" \
  || bad "an invalid block is never recorded" "wrote one anyway"

# agent-cccc already had a .result.json before harvest ran — confirm harvest did not touch it
"$PY" - "$PROJ/sess-harvest/subagents/agent-cccc.result.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["source"] == "record", d
PY
[ $? -eq 0 ] && ok "harvest skips an agent that already has a .result.json" \
  || bad "harvest skips an agent that already has a .result.json" "was overwritten"

# --dry-run: rerun on a fresh harvest fixture, confirm nothing is written
mkdir -p "$PROJ/sess-harvest-dry/subagents"
"$PY" - "$PROJ/sess-harvest-dry/subagents/agent-dry0001.jsonl" "$GOOD" <<'PY'
import json, sys
path, doc = sys.argv[1], json.loads(sys.argv[2])
with open(path, "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "```json review-result\n" + json.dumps(doc) + "\n```"}]}}) + "\n")
PY
run sess-harvest-dry harvest --dry-run
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'recorded 1, skipped-existing 0, no-block 0, invalid 0' \
  && ok "harvest --dry-run reports what it would record" \
  || bad "harvest --dry-run reports what it would record" "$(flat "$out")"
[ ! -f "$PROJ/sess-harvest-dry/subagents/agent-dry0001.result.json" ] \
  && ok "harvest --dry-run writes nothing" \
  || bad "harvest --dry-run writes nothing" "wrote a file"

# ================================================================ GROUP E — list
echo; echo "E. list"

run sess-list list
[ "$rc" -eq 0 ] && ok "list exits 0" || bad "list exits 0" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -q 'agent-list0001' \
  && ok "list shows the recorded row" || bad "list shows the recorded row" "$(flat "$out")"
printf '%s' "$out" | grep -q 'wf_xyz result\[0\].delta' \
  && ok "list shows the workflow-embedded result found by the recursive walk" \
  || bad "list shows the workflow-embedded result found by the recursive walk" "$(flat "$out")"
! printf '%s' "$out" | grep -q 'result\[1\].fix' \
  && ok "list does not surface the non-conforming sibling (result[1].fix)" \
  || bad "list does not surface the non-conforming sibling (result[1].fix)" "$(flat "$out")"
LINE=$(printf '%s' "$out" | grep 'agent-list0001')
printf '%s' "$LINE" | grep -Eq '2[[:space:]]+1[[:space:]]+1[[:space:]]+1/4' \
  && ok "list's severity counts and mutation_ran/total are correct (2 crit, 1 sugg, 1 nit, 1/4 mutated)" \
  || bad "list's severity counts and mutation_ran/total are correct (2 crit, 1 sugg, 1 nit, 1/4 mutated)" "$(flat "$LINE")"

# list --json round-trips (stdout only: a real stderr warning about the
# malformed agent-list0002.result.json fixture must not land inside the
# captured JSON text)
run_stdout sess-list list --json
[ "$rc" -eq 0 ] && ok "list --json exits 0" || bad "list --json exits 0" "rc=$rc"
echo "$out" > "$TMP/list.json"
"$PY" - "$TMP/list.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert isinstance(rows, list)
byid = {r["id"]: r for r in rows}
r = byid["agent-list0001"]
assert r["critical"] == 2 and r["suggestion"] == 1 and r["nitpick"] == 1
assert r["mutation_ran"] == 1 and r["findings_total"] == 4
assert r["body_matches_tree"] is True
assert r["source"] == "record"
wf = [r for r in rows if r["id"].startswith("wf_xyz")]
assert len(wf) == 1, wf
assert wf[0]["source"] == "workflow"
assert wf[0]["verdict"] == "comment"
PY
[ $? -eq 0 ] && ok "list --json round-trips: fields match the fixtures exactly" \
  || bad "list --json round-trips: fields match the fixtures exactly" "$(cat "$TMP/list.json")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
