#!/usr/bin/env bash
# Regression tests for assets/scripts/session-distill.py.
#
# These call the script. Fixtures are built once, in Python, into a fake
# $HOME/.claude/projects tree -- the same shape a real main transcript
# (<session-dir>.jsonl, a sibling of <session-dir>/) and its subagent
# sidecars (<session-dir>/subagents/ and <session-dir>/subagents/workflows/
# <runId>/, review-result.py's own two levels) leave on disk.
#
# `--model-cmd` is pointed at a small python fixture script built alongside
# the transcripts: it reads the RUN_ID/SESSION_DISTILL_PASS markers this
# script's own prompt-builder writes, and returns a canned `claude -p
# --output-format json` envelope keyed on exactly those two fields -- never
# a real model, so this suite spends nothing and needs no network.
#
# The suite does NOT `set -e`: several cases assert "the REFUSE fired and
# nothing was written", and one failed assertion must not abort the rest.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# This suite IMPORTS the SUT, which would otherwise drop __pycache__/ into the
# tracked source tree -- and pr-record.test.sh, running later in the same CI job,
# asserts that directory is absent. Same fix usage-pace.test.sh carries.
export PYTHONDONTWRITEBYTECODE=1
SUT="$HERE/session-distill.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-distill-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Same discipline as review-result.test.sh: unset unconditionally so a
# harness-exported value on the author's own machine can't leak in and turn
# a REFUSE case into a silent false pass.
unset CLAUDE_CODE_SESSION_ID

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

echo "session-distill.test.sh"

# ------------------------------------------------------------------ fixtures
HOMEDIR="$TMP/home"
PROJ="$HOMEDIR/.claude/projects/-fake-proj"
mkdir -p "$PROJ"

"$PY" - "$PROJ" <<'PYEOF'
import json, os, sys

proj = sys.argv[1]

def w_jsonl(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for l in lines:
            f.write(json.dumps(l) + "\n")

def w_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)

def user(text, ts, origin=None, is_meta=False, is_sidechain=False):
    o = {"type": "user", "timestamp": ts, "message": {"content": text}}
    if origin is not None:
        o["origin"] = {"kind": origin}
    if is_meta:
        o["isMeta"] = True
    if is_sidechain:
        o["isSidechain"] = True
    return o

def user_blocks(text, ts):
    return {"type": "user", "timestamp": ts,
            "message": {"content": [{"type": "text", "text": text}]}}

def assistant(text, ts, tool_use=None):
    content = []
    if tool_use:
        content.append({"type": "tool_use", "id": tool_use["id"],
                         "name": tool_use["name"], "input": tool_use["input"]})
    if text:
        content.append({"type": "text", "text": text})
    return {"type": "assistant", "timestamp": ts, "message": {"content": content}}

def tool_result(tool_use_id, ts, is_error=False):
    return {"type": "user", "timestamp": ts,
            "message": {"content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                      "content": "ok", "is_error": is_error}]}}

def tool_result_content(tool_use_id, ts, content, is_error=False):
    # Like tool_result() but with caller-supplied CONTENT instead of the
    # fixed "ok" -- #285's verification-linking tests need two commands'
    # tool_results to carry DIFFERENT text so a test can assert each
    # verification entry picked up its OWN output, not a neighbor's.
    return {"type": "user", "timestamp": ts,
            "message": {"content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                      "content": content, "is_error": is_error}]}}

def bash_use(tool_use_id, command, ts):
    return assistant(None, ts, tool_use={"id": tool_use_id, "name": "Bash",
                                          "input": {"command": command}})

# ============================================================ sess-main
# The primary fixture: origin-based segmentation (2 human turns, one
# harness task-notification line that must NOT become a turn), a
# system-reminder-prefixed first prompt (stripping), a tool call on the
# first turn (tool trace), a top-level subagent, a subagent with NO
# .meta.json (still emitted, null provenance), and a subagent nested one
# level into subagents/workflows/<runId>/ (the second sidecar level).
sdir = os.path.join(proj, "sess-main")
main_lines = [
    user("<system-reminder>boilerplate preamble</system-reminder>\nReal ask one",
         "2026-09-20T01:00:00Z", origin="human"),
    assistant(None, "2026-09-20T01:00:05Z",
              tool_use={"id": "t1", "name": "Bash", "input": {"command": "echo hi"}}),
    tool_result("t1", "2026-09-20T01:00:06Z"),
    assistant("Done the thing.", "2026-09-20T01:00:07Z"),
    user("<task-notification>an agent finished</task-notification>",
         "2026-09-20T01:05:00Z", origin="task-notification"),
    user("Real ask two", "2026-09-20T01:10:00Z", origin="human"),
    assistant("Second reply.", "2026-09-20T01:10:05Z"),
]
w_jsonl(sdir + ".jsonl", main_lines)

w_json(os.path.join(sdir, "subagents", "agent-aaaa0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "do a thing"})
w_jsonl(os.path.join(sdir, "subagents", "agent-aaaa0001.jsonl"), [
    user_blocks("brief text", "2026-09-20T01:01:00Z"),
    assistant("final report text", "2026-09-20T01:01:05Z"),
])

# no .meta.json at all -- must still be emitted, with null provenance.
w_jsonl(os.path.join(sdir, "subagents", "agent-bbbb0002.jsonl"), [
    user_blocks("brief2", "2026-09-20T01:02:00Z"),
    assistant("report2", "2026-09-20T01:02:05Z"),
])

# nested one level into subagents/workflows/<runId>/ -- the second sidecar
# level review-result.py's sidecar_dirs/iter_agent_jsonl already walk.
w_json(os.path.join(sdir, "subagents", "workflows", "wf1", "agent-cccc0003.meta.json"),
       {"agentType": "reviewer", "model": "opus", "description": "nested run",
        "workflowPhase": "Fix"})
w_jsonl(os.path.join(sdir, "subagents", "workflows", "wf1", "agent-cccc0003.jsonl"), [
    user_blocks("brief3", "2026-09-20T01:03:00Z"),
    assistant("report3", "2026-09-20T01:03:05Z"),
])

# ============================================================ sess-shape
# No line anywhere carries an `origin` key -- pins the fallback rule. Line 3
# is plain harness-adjacent text with NO recognizable prefix: under the
# shape rule it is indistinguishable from a real human turn and is counted,
# which is exactly the overcounting the origin rule exists to avoid.
sdir2 = os.path.join(proj, "sess-shape")
# resolve_session_dir (review-result.py, reused) requires the session
# DIRECTORY itself to exist under ~/.claude/projects/*/ -- the main
# transcript is a sibling FILE (<session-dir>.jsonl), not something inside
# it, so a session with no subagents at all still needs the bare directory.
os.makedirs(sdir2, exist_ok=True)
shape_lines = [
    user("Real ask one", "t1"),
    assistant("reply one", "t2"),
    user("pasted terminal scrollback with no recognizable harness prefix", "t3"),
    user("<task-notification>an agent finished</task-notification>", "t4"),
    user("Real ask two", "t5"),
    assistant("reply two", "t6"),
]
w_jsonl(sdir2 + ".jsonl", shape_lines)

# ============================================================ sess-empty
# Session with a main transcript and no subagents/ dir at all -- runs must
# not crash on an absent sidecar tree.
sdir3 = os.path.join(proj, "sess-empty")
os.makedirs(sdir3, exist_ok=True)
w_jsonl(sdir3 + ".jsonl", [
    user("Only turn", "2026-09-20T02:00:00Z", origin="human"),
    assistant("Only reply.", "2026-09-20T02:00:01Z"),
])

# ============================================================ sess-truly-empty
# main transcript exists, opens fine, and is genuinely 0 bytes -- the
# LEGITIMATE empty case #278 C1 must not turn into a false "unreadable".
sdir_te = os.path.join(proj, "sess-truly-empty")
os.makedirs(sdir_te, exist_ok=True)
open(sdir_te + ".jsonl", "w").close()

# ============================================================ sess-unreadable
# main transcript exists but cannot be opened at all (#278 C1 repro #1).
# Before the fix this produced the exact same output as a healthy empty
# session, at exit 0.
sdir_u = os.path.join(proj, "sess-unreadable")
os.makedirs(sdir_u, exist_ok=True)
w_jsonl(sdir_u + ".jsonl", [user("will be chmod 000'd", "t1", origin="human")])
os.chmod(sdir_u + ".jsonl", 0)

# ============================================================ sess-garbage
# main transcript exists, opens fine, and contains ONLY lines that fail
# json.loads (#278 C1 repro #2) -- readable but unparseable, a genuinely
# different failure mode from sess-unreadable, and previously
# indistinguishable from BOTH sess-unreadable and a healthy empty session.
sdir_g = os.path.join(proj, "sess-garbage")
os.makedirs(sdir_g, exist_ok=True)
with open(sdir_g + ".jsonl", "w", encoding="utf-8") as f:
    f.write("not json at all\n")
    f.write("{also not valid json\n")

# ============================================================ sess-origin-string
# One line carries a bare `"origin": "human"` STRING rather than the
# `{"kind": "human"}` dict shape every other fixture uses (#278 N1) -- the
# old `origin.get("kind")` raised AttributeError on this shape instead of
# simply not matching it.
sdir_os = os.path.join(proj, "sess-origin-string")
os.makedirs(sdir_os, exist_ok=True)
w_jsonl(sdir_os + ".jsonl", [
    {"type": "user", "timestamp": "t1", "message": {"content": "Weird origin shape"},
     "origin": "human"},
    assistant("reply1", "t2"),
    user("Real ask, normal origin dict", "t3", origin="human"),
    assistant("reply2", "t4"),
])

# ============================================================ sess-origin-second
# `origin` is present on the SECOND user line, not the first (#278 S1) --
# pins that `has_origin` is computed over the WHOLE transcript, not just
# line 0. The first line must NOT start a turn under the origin rule (it
# carries no origin key at all), even though it is otherwise
# indistinguishable in shape from a real human prompt.
sdir_o2 = os.path.join(proj, "sess-origin-second")
os.makedirs(sdir_o2, exist_ok=True)
w_jsonl(sdir_o2 + ".jsonl", [
    user("First line, no origin key at all", "t1"),
    assistant("reply1", "t2"),
    user("Second line IS the real human turn", "t3", origin="human"),
    assistant("reply2", "t4"),
])

# ============================================================ sess-c2
# Isolated fixture for the later_wrong/classified_as evidence-chain
# enforcement (#278 C2): one subagent run whose canned `chain` response
# carries a dangling `supports` pointer alongside a valid one, and a
# `later_wrong` entry naming a claim id that does not exist.
sdir_c2 = os.path.join(proj, "sess-c2")
os.makedirs(sdir_c2, exist_ok=True)
w_json(os.path.join(sdir_c2, "subagents", "agent-dddd0004.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "c2 fixture"})
w_jsonl(os.path.join(sdir_c2, "subagents", "agent-dddd0004.jsonl"), [
    user_blocks("brief4", "2026-09-20T01:04:00Z"),
    assistant("report4", "2026-09-20T01:04:05Z"),
])

# ============================================================ sess-285
# #285: report extraction (StructuredOutput / harness_error) and
# deterministic verifications[] (linking by tool_use_id, missing
# tool_result, exit_masked_by_pipe vs output_truncated, gates_named_not_run).
sdir_285 = os.path.join(proj, "sess-285")
os.makedirs(sdir_285, exist_ok=True)

# agent-eeee0005 -- ends in a StructuredOutput tool_use with NO trailing
# text block at all. review-result.py's last_assistant_text (text-blocks-
# only) would return None here -> "" silently. extract_report must instead
# report_source "structured_output" with the tool_use's `input` as the
# report.
w_json(os.path.join(sdir_285, "subagents", "agent-eeee0005.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "structured-output-only run"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-eeee0005.jsonl"), [
    user_blocks("Fix the thing", "2026-09-21T00:00:00Z"),
    assistant(None, "2026-09-21T00:00:05Z",
              tool_use={"id": "su1", "name": "StructuredOutput",
                        "input": {"summary": "Fixed the thing", "verified": True}}),
])

# agent-ffff0006 -- the run was cut off by the harness; the last (only)
# assistant text IS the harness's own session-limit message, not a report.
w_json(os.path.join(sdir_285, "subagents", "agent-ffff0006.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "cut off by harness"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-ffff0006.jsonl"), [
    user_blocks("Investigate CI", "2026-09-21T00:01:00Z"),
    assistant("You've hit your session limit · resets 2:40am (America/Los_Angeles)",
              "2026-09-21T00:01:05Z"),
])

# agent-gggg0007 -- two Bash verification commands with DIFFERENT outputs;
# each verifications[] entry must carry its OWN tool_result's output, never
# a neighbor's (LINKING WITHOUT EVIDENCE is one of the four defect classes
# this suite exists to catch).
w_json(os.path.join(sdir_285, "subagents", "agent-gggg0007.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "run tests and build"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-gggg0007.jsonl"), [
    user_blocks("Run tests and build", "2026-09-21T00:02:00Z"),
    bash_use("b1", "swift test", "2026-09-21T00:02:01Z"),
    tool_result_content("b1", "2026-09-21T00:02:02Z", "Test Suite All tests passed: 42 tests, 0 failures"),
    bash_use("b2", "swift build", "2026-09-21T00:02:03Z"),
    tool_result_content("b2", "2026-09-21T00:02:04Z", "Build complete! (1.23s)"),
    assistant("Ran tests and build, both green.", "2026-09-21T00:02:05Z"),
])

# agent-hhhh0008 -- a ci_read Bash tool_use with NO matching tool_result at
# all (the run was truncated mid-tool-call). output must be null with
# output_present False, and empty_ci_result must NOT fire on missing
# output (VERDICTS FROM INCOMPLETE DATA is one of the four defect classes).
w_json(os.path.join(sdir_285, "subagents", "agent-hhhh0008.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "check ci status"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-hhhh0008.jsonl"), [
    user_blocks("Check CI status", "2026-09-21T00:03:00Z"),
    bash_use("c1", "gh pr checks 123", "2026-09-21T00:03:01Z"),
    # NO tool_result for c1 -- the transcript ends mid-call.
])

# agent-iiii0009 -- exit_masked_by_pipe vs output_truncated, one positive
# and three negative cases in a single trace (#285, and the #286
# conflation this docstring calls out by name).
w_json(os.path.join(sdir_285, "subagents", "agent-iiii0009.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "lint/test/build with pipes"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-iiii0009.jsonl"), [
    user_blocks("Verify lint, test, and build", "2026-09-21T00:04:00Z"),
    # 1. MASKED: pipes to head, then reads $? -- EXIT=0 is head's exit
    #    status, not swift-format's.
    bash_use("p1", 'swift format lint --recursive --strict Sources Tests Tools 2>&1 | head -50; echo "EXIT=$?"',
              "2026-09-21T00:04:01Z"),
    tool_result_content("p1", "2026-09-21T00:04:02Z", "EXIT=0"),
    # 2. NOT masked: no pipe at all.
    bash_use("p2", 'swift test; echo "exit=$?"', "2026-09-21T00:04:03Z"),
    tool_result_content("p2", "2026-09-21T00:04:04Z", "exit=0"),
    # 3. output_truncated ONLY: pipes to tail, but never reads $?.
    bash_use("p3", "swift build | tail -3", "2026-09-21T00:04:05Z"),
    tool_result_content("p3", "2026-09-21T00:04:06Z", "Build complete! (1.23s)"),
    # 4. output_truncated but NOT masked: pipefail protects the $? read.
    bash_use("p4", "set -o pipefail; npm run lint | tail; echo $?", "2026-09-21T00:04:07Z"),
    tool_result_content("p4", "2026-09-21T00:04:08Z", "0"),
    assistant("Lint, test, and build all verified.", "2026-09-21T00:04:09Z"),
])

# agent-jjjj0010 -- gates_named_not_run: the BRIEF names "lint" but the
# trace never runs one (only a test command runs) -- "lint" must appear in
# gates_named_not_run, "test" must NOT (it did run).
w_json(os.path.join(sdir_285, "subagents", "agent-jjjj0010.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "omitted lint gate"})
w_jsonl(os.path.join(sdir_285, "subagents", "agent-jjjj0010.jsonl"), [
    user_blocks("Run the tests and fix the lint issues", "2026-09-21T00:05:00Z"),
    bash_use("g1", "swift test", "2026-09-21T00:05:01Z"),
    tool_result_content("g1", "2026-09-21T00:05:02Z", "42 tests, 0 failures"),
    assistant("Tests pass.", "2026-09-21T00:05:03Z"),
])

print("fixtures OK")
PYEOF

# --------------------------------------------------------------- model stub
# Reads the RUN_ID / SESSION_DISTILL_PASS markers off stdin (written by
# session-distill.py's own build_distill_prompt/build_chain_prompt) and
# returns a canned `claude -p --output-format json` envelope. Every
# invocation is appended to $MODEL_CALL_LOG when that env var is set, so
# tests can assert exactly how many real calls a --dry-run/--resume made
# without a real model ever running.
cat > "$TMP/stub_model.py" <<'STUBEOF'
#!/usr/bin/env python3
import json, os, sys

stdin = sys.stdin.read()
run_id = pass_kind = None
for line in stdin.splitlines():
    if line.startswith("RUN_ID: "):
        run_id = line[len("RUN_ID: "):]
    if line.startswith("SESSION_DISTILL_PASS: "):
        pass_kind = line[len("SESSION_DISTILL_PASS: "):]

log = os.environ.get("MODEL_CALL_LOG")
if log:
    with open(log, "a", encoding="utf-8") as f:
        f.write("%s %s\n" % (run_id, pass_kind))

def envelope(result, is_error=False, cost=None):
    # STUB_CALL_COST lets a test dictate the OBSERVED per-call cost the
    # model "reports" (#278 M2), independent of DEFAULT_COST_PER_CALL_USD
    # in the script under test -- so a test can prove the budget check
    # binds against what calls actually cost, not a hard-coded guess.
    if cost is None:
        cost = float(os.environ.get("STUB_CALL_COST", "0.0075"))
    r = result if isinstance(result, str) else json.dumps(result)
    return {"is_error": is_error, "result": r, "total_cost_usd": cost}

if pass_kind == "distill":
    if run_id == "agent-dddd0004":
        # #278 C2 fixture: two claims, so a later_wrong/classified_as
        # response can reference both a valid and an invalid claim id.
        doc = {"asked": "do Y", "understood": "do Y", "delivered": "did Y",
               "claims": [
                   {"id": "c1", "text": "claim one", "kind": "verification",
                    "proof": "ran it", "quote": "q1"},
                   {"id": "c2", "text": "claim two", "kind": "verification",
                    "proof": None, "quote": "q2"},
               ]}
        print(json.dumps(envelope(doc)))
    else:
        doc = {"asked": "do X", "understood": "do X", "delivered": "did X",
               "claims": [{"id": "c1", "text": "the thing works", "kind": "verification",
                           "proof": "ran it", "quote": "it works"}]}
        print(json.dumps(envelope(doc)))
elif pass_kind == "chain":
    if run_id == "agent-dddd0004":
        # #278 C2: later_wrong[1] names a claim id ("c99-nonexistent")
        # that does not exist -> must be DROPPED, leaving only
        # later_wrong[0] ("c1") in the record, so any `supports` pointer
        # at index 1 becomes dangling too. classified_as then exercises
        # ELEMENT-WISE supports filtering: entry 1 has one good pointer
        # ("c1") and one bad one ("c99-bogus") and must survive with only
        # the good one kept; entry 2 points at the now-nonexistent
        # later_wrong index 1 and must be dropped entirely; entry 3 points
        # at the surviving later_wrong index 0 and must survive untouched.
        doc = {
            "later_wrong": [
                {"claim": "c1", "how": "h1",
                 "contradicted_by": {"run": "x", "at": "t1", "quote": "q1"}},
                {"claim": "c99-nonexistent", "how": "h2",
                 "contradicted_by": {"run": "y", "at": "t2", "quote": "q2"}},
            ],
            "classified_as": [
                {"label": "proxy-as-thing", "supports": ["c1", "c99-bogus"],
                 "why": "partial-valid"},
                {"label": "green-as-done", "supports": ["1"],
                 "why": "dangling index after later_wrong[1] is dropped"},
                {"label": "outcome-not-reason", "supports": ["0"],
                 "why": "valid surviving later_wrong index"},
            ],
        }
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-aaaa0001":
        # off-vocabulary label -> must become "unclassified" + reason recorded
        doc = {"later_wrong": [], "classified_as": [
            {"label": "made-up-label-nobody-asked-for", "supports": ["c1"], "why": "bogus"}]}
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-bbbb0002":
        # supports names no real claim id / later_wrong index -> entry dropped entirely
        doc = {"later_wrong": [], "classified_as": [
            {"label": "proxy-as-thing", "supports": ["c99-does-not-exist"], "why": "nope"}]}
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-cccc0003":
        # 'result' is not valid JSON -> recorded failure, not a crash
        print(json.dumps(envelope("{this is not valid json", cost=0.0075)))
    elif run_id == "main-turn-002":
        # is_error: true -> recorded failure, not a crash
        print(json.dumps(envelope(None, is_error=True)))
    else:
        doc = {"later_wrong": [], "classified_as": [
            {"label": "proxy-as-thing", "supports": ["c1"], "why": "fine"}]}
        print(json.dumps(envelope(doc)))
else:
    print(json.dumps(envelope({}, is_error=True)))
STUBEOF
MODEL_CMD="$PY $TMP/stub_model.py"

# --------------------------------------------------------------------- I/O
run() {
  # run <session-id-or-'-'> [args...] -- stdout+stderr combined into $out, rc into $rc
  local sid=$1; shift
  if [ "$sid" = "-" ]; then
    out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>&1); rc=$?
  else
    out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>&1); rc=$?
  fi
}
run_stdout() {
  local sid=$1; shift
  if [ "$sid" = "-" ]; then
    out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>/dev/null); rc=$?
  else
    out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>/dev/null); rc=$?
  fi
}

# ============================================================== GROUP A — schema
echo; echo "A. schema"

run_stdout - schema
[ "$rc" -eq 0 ] && ok "schema exits 0" || bad "schema exits 0" "rc=$rc"
echo "$out" > "$TMP/schema.json"
"$PY" - "$TMP/schema.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
labels = d["labels"]
assert len(labels) == 9, labels
assert labels[-1] == "unclassified", labels
expected = {"absence-without-second-search", "plural-from-one-check", "proxy-as-thing",
            "green-as-done", "outcome-not-reason", "recalled-not-reopened",
            "consumers-unfound", "letter-not-goal", "unclassified"}
assert set(labels) == expected, labels
enum = d["chain_call_schema"]["properties"]["classified_as"]["items"]["properties"]["label"]["enum"]
assert set(enum) == expected, enum
PY
[ $? -eq 0 ] && ok "schema: exactly the 9 labels, and the chain-call enum matches" \
  || bad "schema: exactly the 9 labels, and the chain-call enum matches" "$(cat "$TMP/schema.json")"

# ======================================================== GROUP B — missing sibling
echo; echo "B. missing review-result.py sibling"

mv "$HERE/review-result.py" "$TMP/review-result.py.hidden"
run sess-main runs
[ "$rc" -eq 2 ] && ok "runs: missing sibling exits 2" || bad "runs: missing sibling exits 2" "rc=$rc out=$out"
case "$out" in
  REFUSE:*review-result.py*) ok "runs: missing-sibling REFUSE names review-result.py" ;;
  *) bad "runs: missing-sibling REFUSE names review-result.py" "$out" ;;
esac

run sess-main distill --model-cmd "$MODEL_CMD"
[ "$rc" -eq 2 ] && ok "distill: missing sibling exits 2" || bad "distill: missing sibling exits 2" "rc=$rc"
mv "$TMP/review-result.py.hidden" "$HERE/review-result.py"

# ============================================================ GROUP C — runs / segmentation
echo; echo "C. runs — segmentation, stripping, both sidecar levels, missing meta"

run_stdout sess-main runs --json
[ "$rc" -eq 0 ] && ok "runs sess-main exits 0" || bad "runs sess-main exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-main.json"
"$PY" - "$TMP/runs-main.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] == "origin", d["segmented_by"]
assert d["main_turns"] == 2, d["main_turns"]
assert d["subagent_runs"] == 3, d["subagent_runs"]

runs = {r["id"]: r for r in d["runs"]}
assert set(runs) == {"main-turn-001", "main-turn-002", "agent-aaaa0001",
                      "agent-bbbb0002", "agent-cccc0003"}, set(runs)

t1 = runs["main-turn-001"]
assert t1["kind"] == "main-turn"
assert t1["segmented_by"] == "origin"
# system-reminder block stripped, but the turn is real (non-empty brief)
assert t1["brief"] == "Real ask one", repr(t1["brief"])
assert "<system-reminder>" not in t1["brief"]
assert t1["tool_calls"] == 1, t1["tool_calls"]
assert t1["tool_trace"][0]["tool"] == "Bash"
assert t1["tool_trace"][0]["errored"] is False

t2 = runs["main-turn-002"]
assert t2["brief"] == "Real ask two", repr(t2["brief"])

# the harness task-notification line must NOT have become a third turn
assert len(d["runs"]) == 5, len(d["runs"])

top = runs["agent-aaaa0001"]
assert top["spawned_by"] == "session", top["spawned_by"]
assert top["agent_type"] == "general-purpose"
assert top["model"] == "sonnet"

missing_meta = runs["agent-bbbb0002"]
assert missing_meta["spawned_by"] == "session"
assert missing_meta["agent_type"] is None
assert missing_meta["model"] is None
assert missing_meta["description"] is None
assert missing_meta["workflow_phase"] is None
assert missing_meta["brief"] == "brief2"  # the run itself is still fully emitted

nested = runs["agent-cccc0003"]
assert nested["spawned_by"] == "wf1", nested["spawned_by"]
assert nested["agent_type"] == "reviewer"
assert nested["workflow_phase"] == "Fix"
PY
[ $? -eq 0 ] && ok "runs sess-main: origin segmentation (2 turns), stripping, both sidecar levels, missing-meta run emitted" \
  || bad "runs sess-main: origin segmentation (2 turns), stripping, both sidecar levels, missing-meta run emitted" "$(cat "$TMP/runs-main.json")"

run_stdout sess-shape runs --json
[ "$rc" -eq 0 ] && ok "runs sess-shape exits 0" || bad "runs sess-shape exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-shape.json"
"$PY" - "$TMP/runs-shape.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] == "shape", d["segmented_by"]
# 3 turns: "Real ask one", the unprefixed scrollback line, "Real ask two" --
# the task-notification-prefixed line is excluded, demonstrating both the
# rule AND the overcount the origin rule exists to avoid (a real human turn
# count here would be 2, not 3).
assert d["main_turns"] == 3, d["main_turns"]
briefs = [r["brief"] for r in d["runs"]]
assert "pasted terminal scrollback with no recognizable harness prefix" in briefs, briefs
assert not any(b.startswith("<task-notification>") for b in briefs), briefs
for r in d["runs"]:
    assert r["segmented_by"] == "shape"
PY
[ $? -eq 0 ] && ok "runs sess-shape: shape fallback fires with no origin key anywhere, and overcounts (3, not 2)" \
  || bad "runs sess-shape: shape fallback fires with no origin key anywhere, and overcounts (3, not 2)" "$(cat "$TMP/runs-shape.json")"

run_stdout sess-empty runs --json
[ "$rc" -eq 0 ] && ok "runs sess-empty (no subagents dir) exits 0" || bad "runs sess-empty (no subagents dir) exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-empty.json"
"$PY" - "$TMP/runs-empty.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["main_turns"] == 1, d["main_turns"]
assert d["subagent_runs"] == 0, d["subagent_runs"]
PY
[ $? -eq 0 ] && ok "runs sess-empty: no subagents/ dir does not crash" \
  || bad "runs sess-empty: no subagents/ dir does not crash" "$(cat "$TMP/runs-empty.json")"

# ============================================================ GROUP D — distill pipeline
echo; echo "D. distill — vocabulary enforcement, model-failure handling"

export MODEL_CALL_LOG="$TMP/calls-d.log"
rm -f "$MODEL_CALL_LOG"
OUT_D="$TMP/out-d.json"
run sess-main distill --out "$OUT_D" --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-main (full run) exits 0" || bad "distill sess-main (full run) exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_D" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["kind"] == "session-distill-document"
assert d["schema_version"] == 2
recs = {r["run"]["id"]: r for r in d["records"]}
assert len(recs) == 5, recs.keys()

# off-vocabulary label -> "unclassified" + the offending string recorded,
# never invented, never passed through as-is.
aaaa = recs["agent-aaaa0001"]
labels = [c["label"] for c in aaaa["classified_as"]]
assert labels == ["unclassified"], labels
assert aaaa["unclassified_reason"] == "made-up-label-nobody-asked-for", aaaa["unclassified_reason"]

# an entry whose `supports` names no real claim id / later_wrong index is
# DROPPED entirely, not merely relabelled.
bbbb = recs["agent-bbbb0002"]
assert bbbb["classified_as"] == [], bbbb["classified_as"]
assert bbbb["unclassified_reason"] is None

# a claim from a successful distill call still round-trips.
assert aaaa["claims"][0]["id"] == "c1"
assert aaaa["claims"][0]["text"] == "the thing works"

failures = {f["run"]: f for f in d["failures"]}
# invalid JSON in the model's own 'result' string -> recorded failure, not a crash
assert "agent-cccc0003" in failures, failures
assert failures["agent-cccc0003"]["phase"] == "chain"
cccc = recs["agent-cccc0003"]
assert cccc["distilled"]["passes"] == ["distill"], cccc["distilled"]["passes"]
assert cccc["claims"][0]["id"] == "c1"  # the distill pass still succeeded

# is_error: true -> recorded failure, not a crash
assert "main-turn-002" in failures, failures
assert failures["main-turn-002"]["phase"] == "chain"
mt2 = recs["main-turn-002"]
assert mt2["distilled"]["passes"] == ["distill"]

assert d["total_cost_usd"] > 0
PY
[ $? -eq 0 ] && ok "distill: off-vocab->unclassified+reason, unsupported->dropped, invalid-JSON and is_error recorded as failures not crashes" \
  || bad "distill: off-vocab->unclassified+reason, unsupported->dropped, invalid-JSON and is_error recorded as failures not crashes" "$(cat "$OUT_D")"

CALLS_D=$(wc -l < "$MODEL_CALL_LOG" | tr -d ' ')
[ "$CALLS_D" = "10" ] && ok "distill: exactly 2 model calls per run (5 runs = 10 calls)" \
  || bad "distill: exactly 2 model calls per run (5 runs = 10 calls)" "calls=$CALLS_D"
unset MODEL_CALL_LOG

# ============================================================ GROUP E — dry-run
echo; echo "E. --dry-run spends nothing and writes nothing"

export MODEL_CALL_LOG="$TMP/calls-e.log"
rm -f "$MODEL_CALL_LOG"
OUT_E="$TMP/out-e.json"
run sess-main distill --out "$OUT_E" --dry-run --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "--dry-run exits 0" || bad "--dry-run exits 0" "rc=$rc out=$out"
case "$out" in
  *"cost (projected)"*) ok "--dry-run prints a cost projection" ;;
  *) bad "--dry-run prints a cost projection" "$out" ;;
esac
[ ! -f "$OUT_E" ] && ok "--dry-run writes nothing" || bad "--dry-run writes nothing" "$OUT_E exists"
[ ! -f "$MODEL_CALL_LOG" ] && ok "--dry-run calls the model zero times" \
  || bad "--dry-run calls the model zero times" "$(cat "$MODEL_CALL_LOG")"
unset MODEL_CALL_LOG

# ============================================================ GROUP F — resume
echo; echo "F. --resume skips runs already in the output document"

export MODEL_CALL_LOG="$TMP/calls-f.log"
rm -f "$MODEL_CALL_LOG"
OUT_F="$TMP/out-f.json"
run sess-main distill --out "$OUT_F" --limit 2 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill --limit 2 (first pass) exits 0" || bad "distill --limit 2 (first pass) exits 0" "rc=$rc out=$out"
FIRST_CALLS=$(wc -l < "$MODEL_CALL_LOG" | tr -d ' ')
[ "$FIRST_CALLS" = "4" ] && ok "distill --limit 2: exactly 4 calls (2 runs x 2 calls)" \
  || bad "distill --limit 2: exactly 4 calls (2 runs x 2 calls)" "calls=$FIRST_CALLS"

run sess-main distill --out "$OUT_F" --resume --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill --resume (second pass) exits 0" || bad "distill --resume (second pass) exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_F" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["records"]) == 5, len(d["records"])
PY
[ $? -eq 0 ] && ok "distill --resume: all 5 runs present after completing the remaining 3" \
  || bad "distill --resume: all 5 runs present after completing the remaining 3" "$(cat "$OUT_F")"

TOTAL_CALLS=$(wc -l < "$MODEL_CALL_LOG" | tr -d ' ')
[ "$TOTAL_CALLS" = "10" ] && ok "distill --resume: total calls is still 10, not 14 -- the first 2 runs were not re-called" \
  || bad "distill --resume: total calls is still 10, not 14 -- the first 2 runs were not re-called" "calls=$TOTAL_CALLS"
# 2 runs x 2 calls (distill+chain) each = 4 log lines total for these two
# runs; anything more would mean --resume re-called an already-done run.
REPEATS=$(grep -cE '^(main-turn-001|agent-aaaa0001) ' "$MODEL_CALL_LOG")
[ "$REPEATS" = "4" ] && ok "distill --resume: the 2 already-done runs' calls appear exactly once each (4 log lines), never repeated" \
  || bad "distill --resume: the 2 already-done runs' calls appear exactly once each (4 log lines), never repeated" "repeats=$REPEATS"
unset MODEL_CALL_LOG

# ============================================================ GROUP G — max-cost-usd
echo; echo "G. --max-cost-usd stops before exceeding the budget"

OUT_G="$TMP/out-g.json"
run sess-main distill --out "$OUT_G" --max-cost-usd 0.02 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "--max-cost-usd exits 0 (an intentional stop, not a failure)" \
  || bad "--max-cost-usd exits 0 (an intentional stop, not a failure)" "rc=$rc out=$out"
"$PY" - "$OUT_G" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["stopped"] is not None, d["stopped"]
assert "max-cost-usd" in d["stopped"]["reason"], d["stopped"]
assert d["total_cost_usd"] <= 0.02, d["total_cost_usd"]
assert len(d["records"]) < 5, len(d["records"])
PY
[ $? -eq 0 ] && ok "--max-cost-usd: stops early, records the reason, never exceeds the budget, never truncates silently" \
  || bad "--max-cost-usd: stops early, records the reason, never exceeds the budget, never truncates silently" "$(cat "$OUT_G")"

# ============================================================ GROUP H — --force
echo; echo "H. --force required to overwrite an existing output file"

OUT_H="$TMP/out-h.json"
run sess-main distill --out "$OUT_H" --only main-turn-001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "--only main-turn-001 (first write) exits 0" || bad "--only main-turn-001 (first write) exits 0" "rc=$rc out=$out"

run sess-main distill --out "$OUT_H" --only main-turn-001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 2 ] && ok "distill without --force/--resume on an existing --out REFUSES (exit 2)" \
  || bad "distill without --force/--resume on an existing --out REFUSES (exit 2)" "rc=$rc out=$out"
case "$out" in
  REFUSE:*"--force"*) ok "the REFUSE names --force as the way out" ;;
  *) bad "the REFUSE names --force as the way out" "$out" ;;
esac

run sess-main distill --out "$OUT_H" --only main-turn-001 --force --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "--force allows the overwrite" || bad "--force allows the overwrite" "rc=$rc out=$out"

run sess-main distill --out "$OUT_H" --only nope-does-not-exist --model-cmd "$MODEL_CMD"
[ "$rc" -eq 2 ] && ok "--only naming a run that does not exist REFUSES (exit 2)" \
  || bad "--only naming a run that does not exist REFUSES (exit 2)" "rc=$rc out=$out"

# ============================================================ GROUP I — C1: unreadable/unparseable transcript
echo; echo "I. C1 — an unreadable or unparseable main transcript is never a silent zero"

run_stdout sess-truly-empty runs --json
[ "$rc" -eq 0 ] && ok "runs sess-truly-empty (0-byte main transcript) exits 0 -- legitimate emptiness is not an error" \
  || bad "runs sess-truly-empty (0-byte main transcript) exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-truly-empty.json"
"$PY" - "$TMP/runs-truly-empty.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] is None, d["segmented_by"]
assert d["main_turns"] == 0, d["main_turns"]
assert d["unreadable"] == [], d["unreadable"]
PY
[ $? -eq 0 ] && ok "runs sess-truly-empty: segmented_by null, unreadable[] empty, exit 0" \
  || bad "runs sess-truly-empty: segmented_by null, unreadable[] empty, exit 0" "$(cat "$TMP/runs-truly-empty.json")"

run_stdout sess-unreadable runs --json
[ "$rc" -eq 2 ] && ok "runs sess-unreadable (chmod 000 main transcript) exits 2" \
  || bad "runs sess-unreadable (chmod 000 main transcript) exits 2" "rc=$rc"
echo "$out" > "$TMP/runs-unreadable.json"
"$PY" - "$TMP/runs-unreadable.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] is None, d["segmented_by"]
assert d["main_turns"] == 0, d["main_turns"]
assert d["unreadable"], d["unreadable"]
assert any("main transcript" in u for u in d["unreadable"]), d["unreadable"]
PY
[ $? -eq 0 ] && ok "runs sess-unreadable: segmented_by null (never a rule name), unreadable[] names the main transcript, distinguishable from sess-truly-empty" \
  || bad "runs sess-unreadable: segmented_by null, unreadable[] names the main transcript" "$(cat "$TMP/runs-unreadable.json")"

run sess-unreadable runs
case "$out" in
  *"warning: could not fully read"*"main transcript"*) ok "runs sess-unreadable: stderr warns about the unreadable transcript" ;;
  *) bad "runs sess-unreadable: stderr warns about the unreadable transcript" "$out" ;;
esac

run_stdout sess-garbage runs --json
[ "$rc" -eq 2 ] && ok "runs sess-garbage (main transcript is only unparseable lines) exits 2" \
  || bad "runs sess-garbage (main transcript is only unparseable lines) exits 2" "rc=$rc"
echo "$out" > "$TMP/runs-garbage.json"
"$PY" - "$TMP/runs-garbage.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] is None, d["segmented_by"]
assert d["main_turns"] == 0, d["main_turns"]
assert d["unreadable"], d["unreadable"]
assert any("parsed" in u for u in d["unreadable"]), d["unreadable"]
PY
[ $? -eq 0 ] && ok "runs sess-garbage: segmented_by null, unreadable[] reports the unparseable-line count, distinguishable from both sess-truly-empty and sess-unreadable" \
  || bad "runs sess-garbage: segmented_by null, unreadable[] reports unparseable lines" "$(cat "$TMP/runs-garbage.json")"

OUT_I="$TMP/out-i.json"
run sess-unreadable distill --out "$OUT_I" --model-cmd "$MODEL_CMD"
[ "$rc" -eq 2 ] && ok "distill sess-unreadable exits 2" || bad "distill sess-unreadable exits 2" "rc=$rc out=$out"
"$PY" - "$OUT_I" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["unreadable"], d["unreadable"]
assert d["segmented_by"] is None, d["segmented_by"]
assert d["records"] == [], d["records"]
PY
[ $? -eq 0 ] && ok "distill sess-unreadable: document still written in full (JSON emitted), unreadable[] populated, segmented_by null" \
  || bad "distill sess-unreadable: document still written in full" "$(cat "$OUT_I")"

# ============================================================ GROUP J — C2: evidence-chain enforcement
echo; echo "J. C2 — element-wise supports filtering; later_wrong claim ids validated"

export MODEL_CALL_LOG="$TMP/calls-j.log"
rm -f "$MODEL_CALL_LOG"
OUT_J="$TMP/out-j.json"
run sess-c2 distill --out "$OUT_J" --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-c2 exits 0" || bad "distill sess-c2 exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
recs = {r["run"]["id"]: r for r in d["records"]}
assert "agent-dddd0004" in recs, recs.keys()
rec = recs["agent-dddd0004"]

# later_wrong[1] named a nonexistent claim id ("c99-nonexistent") -> DROPPED,
# only the "c1" entry survives.
lw = rec["later_wrong"]
assert len(lw) == 1, lw
assert lw[0]["claim"] == "c1", lw

ca = {c["label"]: c for c in rec["classified_as"]}
# entry 1: one good pointer ("c1") + one dangling one ("c99-bogus") ->
# entry SURVIVES, `supports` keeps only the pointer that resolves.
assert "proxy-as-thing" in ca, rec["classified_as"]
assert ca["proxy-as-thing"]["supports"] == ["c1"], ca["proxy-as-thing"]["supports"]

# entry 2: pointed at later_wrong index "1", which no longer exists once
# later_wrong[1] was dropped -> entry DROPPED entirely.
assert "green-as-done" not in ca, rec["classified_as"]

# entry 3: pointed at later_wrong index "0", which DOES survive -> kept
# with `supports` unchanged.
assert "outcome-not-reason" in ca, rec["classified_as"]
assert ca["outcome-not-reason"]["supports"] == ["0"], ca["outcome-not-reason"]["supports"]

assert rec["unclassified_reason"] is None, rec["unclassified_reason"]
PY
[ $? -eq 0 ] && ok "C2: supports filtered element-wise (dangling pointer dropped, valid one kept); a later_wrong entry naming a nonexistent claim is dropped, not silently kept" \
  || bad "C2: element-wise supports filtering / later_wrong claim validation" "$(cat "$OUT_J")"

case "$out" in
  *"warning:"*"c99-nonexistent"*"dropped"*) ok "C2: dropping the unresolvable later_wrong claim is warned to stderr, not silent" ;;
  *) bad "C2: dropping the unresolvable later_wrong claim is warned to stderr" "$out" ;;
esac
unset MODEL_CALL_LOG

# ============================================================ GROUP K — M1: prompt construction / trace-to-proof plumbing
echo; echo "K. M1 — the distill prompt carries the full tool trace and a floor proof instruction"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_m1", sys.argv[1])
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)

assert "PROOF IS A FLOOR" in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT
assert "verbatim" in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT
assert "TOOL TRACE" in sd.DISTILL_SYSTEM_PROMPT.upper(), sd.DISTILL_SYSTEM_PROMPT

assert "proxy-as-thing" in sd.CHAIN_SYSTEM_PROMPT, sd.CHAIN_SYSTEM_PROMPT
assert "EXIT=$?" in sd.CHAIN_SYSTEM_PROMPT or "echo $?" in sd.CHAIN_SYSTEM_PROMPT, sd.CHAIN_SYSTEM_PROMPT
assert "head" in sd.CHAIN_SYSTEM_PROMPT and "tail" in sd.CHAIN_SYSTEM_PROMPT, sd.CHAIN_SYSTEM_PROMPT

r = {
    "id": "agent-x", "kind": "subagent", "description": "d",
    "brief": "b", "report": "r",
    "tool_calls": 2,
    "tool_trace": [
        {"tool": "Bash", "digest": 'swift format lint ... | head -50; echo "EXIT=$?"', "errored": False},
        {"tool": "Bash", "digest": "swift test", "errored": False},
    ],
}
prompt = sd.build_distill_prompt(r)
assert "TOOL TRACE" in prompt, prompt
assert 'EXIT=$?' in prompt, prompt
assert "swift test" in prompt, prompt
PY
[ $? -eq 0 ] && ok "M1: DISTILL_SYSTEM_PROMPT states proof as a floor sourced from the trace; CHAIN_SYSTEM_PROMPT names the exit-code-proxy pattern; build_distill_prompt carries the full trace" \
  || bad "M1: prompt construction / trace-to-proof plumbing" "rc=nonzero"

# ============================================================ GROUP L — M2: honest cost projection, budget binds on observed cost
echo; echo "L. M2 — cost projection states its basis; budget genuinely binds on OBSERVED cost"

OUT_L1="$TMP/out-l1.json"
run sess-main distill --out "$OUT_L1" --only main-turn-001 --dry-run --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "dry-run --only main-turn-001 exits 0" || bad "dry-run --only main-turn-001 exits 0" "rc=$rc out=$out"
case "$out" in
  *'$0.3340'*) ok 'M2: dry-run cost projection uses the corrected ~$0.167/call default (2 calls = $0.3340), not the old $0.0075' ;;
  *) bad 'M2: dry-run cost projection uses the corrected ~$0.167/call default' "$out" ;;
esac
case "$out" in
  *"basis:"*) ok "M2: dry-run states the projection's basis rather than a bare number" ;;
  *) bad "M2: dry-run states the projection's basis rather than a bare number" "$out" ;;
esac

# The stub is told to report a REAL per-call cost of $0.30 (STUB_CALL_COST),
# above DEFAULT_COST_PER_CALL_USD (~$0.167). With a $0.35 budget, the OLD
# code's checks used the hard-coded $0.0075 estimate throughout and would
# let BOTH the distill ($0.30) and chain ($0.30) calls for this run go
# through -- landing at $0.60, 71% over budget, before ever noticing (no
# post-call check existed at all). The fix must stop before the chain
# call once the OBSERVED $0.30 distill cost makes it unaffordable.
export MODEL_CALL_LOG="$TMP/calls-l.log"
rm -f "$MODEL_CALL_LOG"
OUT_L2="$TMP/out-l2.json"
STUB_CALL_COST=0.30 run sess-main distill --out "$OUT_L2" --only main-turn-001 --max-cost-usd 0.35 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "M2: --max-cost-usd 0.35 with \$0.30/call observed cost exits 0 (an intentional stop, not a failure)" \
  || bad "M2: --max-cost-usd 0.35 with \$0.30/call observed cost exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_L2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["total_cost_usd"] <= 0.35 + 1e-9, d["total_cost_usd"]
assert d["stopped"] is not None, d["stopped"]
assert "chain call" in d["stopped"]["reason"], d["stopped"]
assert len(d["records"]) == 1, len(d["records"])
assert d["records"][0]["distilled"]["passes"] == ["distill"], d["records"][0]["distilled"]["passes"]
PY
[ $? -eq 0 ] && ok "M2: budget binds on OBSERVED \$0.30/call spend -- stops before the chain call, total_cost_usd stays <= budget" \
  || bad "M2: budget binds on OBSERVED spend, not a stale estimate" "$(cat "$OUT_L2")"
CALLS_L=$(wc -l < "$MODEL_CALL_LOG" | tr -d ' ')
[ "$CALLS_L" = "1" ] && ok "M2: exactly 1 model call was made (the chain call never fired, so it never spent the second \$0.30)" \
  || bad "M2: exactly 1 model call was made" "calls=$CALLS_L"
unset MODEL_CALL_LOG

# ============================================================ GROUP M — M3: tool_digest head+tail truncation
echo; echo "M. M3 — tool_digest keeps the TAIL as well as the head when truncating"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_m3", sys.argv[1])
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)

long_cmd = ("x" * 150) + ' swift format lint --recursive --strict Sources Tests Tools 2>&1 | head -50; echo "EXIT=$?"'
assert len(long_cmd) > 180, len(long_cmd)
digest = sd.tool_digest({"command": long_cmd})
assert "…" in digest, digest
assert digest.startswith(long_cmd[:120]), digest
assert digest.endswith(long_cmd[-60:]), digest
assert 'EXIT=$?' in digest, digest  # the tail-end proxy pattern survives truncation
PY
[ $? -eq 0 ] && ok "M3: tool_digest truncation keeps the tail -- an exit-code read at the end of a long pipeline survives the digest" \
  || bad "M3: tool_digest truncation keeps the tail" "rc=nonzero"

# ============================================================ GROUP N — N1: non-dict origin value does not crash
echo; echo "N. N1 — a non-dict origin value (bare string) does not crash segmentation"

run_stdout sess-origin-string runs --json
[ "$rc" -eq 0 ] && ok "runs sess-origin-string exits 0 (no AttributeError crash)" \
  || bad "runs sess-origin-string exits 0 (no AttributeError crash)" "rc=$rc"
echo "$out" > "$TMP/runs-origin-string.json"
"$PY" - "$TMP/runs-origin-string.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] == "origin", d["segmented_by"]
assert d["main_turns"] == 1, d["main_turns"]
briefs = [r["brief"] for r in d["runs"]]
assert briefs == ["Real ask, normal origin dict"], briefs
PY
[ $? -eq 0 ] && ok "N1: a bare-string origin value is treated as no-match (isinstance guard), never a crash" \
  || bad "N1: a bare-string origin value is treated as no-match, never a crash" "$(cat "$TMP/runs-origin-string.json")"

# ============================================================ GROUP O — S1: origin on the second line, not the first
echo; echo "O. S1 — origin present only on the SECOND line still triggers the origin rule"

run_stdout sess-origin-second runs --json
[ "$rc" -eq 0 ] && ok "runs sess-origin-second exits 0" || bad "runs sess-origin-second exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-origin-second.json"
"$PY" - "$TMP/runs-origin-second.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["segmented_by"] == "origin", d["segmented_by"]
assert d["main_turns"] == 1, d["main_turns"]
briefs = [r["brief"] for r in d["runs"]]
assert briefs == ["Second line IS the real human turn"], briefs
PY
[ $? -eq 0 ] && ok "S1: has_origin is computed over the WHOLE transcript -- origin on line 2 still selects the origin rule, line 1 (no origin key) is correctly excluded" \
  || bad "S1: has_origin is computed over the whole transcript" "$(cat "$TMP/runs-origin-second.json")"

# ============================================================ GROUP P — S3: cmd_report coverage, default output path, --out -
echo; echo "P. S3 — cmd_report coverage, default output path, --out -"

DEFAULT_OUT="$PROJ/sess-main/session-distill.json"
rm -f "$DEFAULT_OUT"

run sess-main distill --only main-turn-001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill with NO --out (default path) exits 0" \
  || bad "distill with NO --out (default path) exits 0" "rc=$rc out=$out"
[ -f "$DEFAULT_OUT" ] && ok "distill with no --out writes to <session-dir>/session-distill.json" \
  || bad "distill with no --out writes to <session-dir>/session-distill.json" "expected $DEFAULT_OUT"
case "$out" in
  *"session-distill.json"*) ok "distill's own stdout names session-distill.json (the default path)" ;;
  *) bad "distill's own stdout names session-distill.json (the default path)" "$out" ;;
esac

run sess-main report
[ "$rc" -eq 0 ] && ok "report (default path, no --in, human output) exits 0" \
  || bad "report (default path, no --in, human output) exits 0" "rc=$rc out=$out"
case "$out" in
  *"classified_as label distribution"*) ok "report human output has the expected section" ;;
  *) bad "report human output has the expected section" "$out" ;;
esac

run sess-main report --json
[ "$rc" -eq 0 ] && ok "report --json (default path) exits 0" || bad "report --json (default path) exits 0" "rc=$rc out=$out"
echo "$out" > "$TMP/report-json.json"
"$PY" - "$TMP/report-json.json" "$DEFAULT_OUT" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a == b, "report --json did not round-trip the on-disk document"
PY
[ $? -eq 0 ] && ok "report --json round-trips the on-disk session-distill.json exactly" \
  || bad "report --json round-trips the on-disk session-distill.json exactly" "mismatch"

run - report --in "$OUT_D" --json
[ "$rc" -eq 0 ] && ok "report --in PATH --json exits 0 (bypasses --session entirely)" \
  || bad "report --in PATH --json exits 0" "rc=$rc out=$out"

run sess-main distill --only main-turn-002 --out - --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill --out - exits 0" || bad "distill --out - exits 0" "rc=$rc out=$out"
echo "$out" > "$TMP/out-stdout.json"
"$PY" - "$TMP/out-stdout.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["kind"] == "session-distill-document"
recs = {r["run"]["id"] for r in d["records"]}
assert recs == {"main-turn-002"}, recs
PY
[ $? -eq 0 ] && ok "distill --out - prints the full document to stdout" \
  || bad "distill --out - prints the full document to stdout" "$(cat "$TMP/out-stdout.json")"

# ============================================================ GROUP Q — N3: runs_total vs runs_selected; --force+--only warns
echo; echo "Q. N3 — runs_total is the SESSION total, distinct from a --only-narrowed selection"

"$PY" - "$OUT_H" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["runs_total"] == 5, d["runs_total"]        # the whole sess-main session
assert d["runs_selected"] == 1, d["runs_selected"]  # narrowed by --only main-turn-001
assert len(d["records"]) == 1, len(d["records"])
PY
[ $? -eq 0 ] && ok "N3: runs_total reports the session's real total; runs_selected reports the --only-narrowed count, separately" \
  || bad "N3: runs_total vs runs_selected" "$(cat "$OUT_H")"

OUT_Q="$TMP/out-q.json"
run sess-main distill --out "$OUT_Q" --only main-turn-001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "N3 setup: first --only write exits 0" || bad "N3 setup: first --only write exits 0" "rc=$rc out=$out"
run sess-main distill --out "$OUT_Q" --only main-turn-002 --force --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "--force --only (second run) still exits 0" || bad "--force --only (second run) still exits 0" "rc=$rc out=$out"
case "$out" in
  *"warning:"*"--force"*"discard"*) ok "N3: --force without --resume combined with --only warns before discarding the prior run's record" ;;
  *) bad "N3: --force without --resume combined with --only warns before discarding" "$out" ;;
esac

# ============================================================ GROUP R — N2: record cost_usd reconciles with total_cost_usd
echo; echo "R. N2 — a record's own cost_usd reconciles with total_cost_usd, even after a failed chain call"

"$PY" - "$OUT_D" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
recs = {r["run"]["id"]: r for r in d["records"]}
cccc = recs["agent-cccc0003"]
# distill succeeded (cost 0.0075); chain FAILED (invalid JSON in 'result')
# but the model still reported a real total_cost_usd for that failed call
# (0.0075, from the stub) -- the record's own cost must include it.
assert cccc["distilled"]["passes"] == ["distill"], cccc["distilled"]["passes"]
assert abs(cccc["distilled"]["cost_usd"] - 0.015) < 1e-9, cccc["distilled"]["cost_usd"]
total_from_records = sum(r["distilled"]["cost_usd"] for r in d["records"])
assert abs(total_from_records - d["total_cost_usd"]) < 1e-6, (total_from_records, d["total_cost_usd"])
PY
[ $? -eq 0 ] && ok "N2: a failed chain call's real cost is folded into its record's cost_usd, so sum(records) reconciles with total_cost_usd" \
  || bad "N2: record cost_usd reconciles with total_cost_usd" "$(cat "$OUT_D")"

# ============================================================ GROUP S — T1 (#278 round 2): supports normalized to strings
echo; echo "S. T1 — enforce_classified_as writes every surviving supports pointer as a string"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_t1", sys.argv[1])
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)

claims = [{"id": "c1", "text": "x", "kind": "verification", "proof": None, "quote": None}]
later_wrong = [{"claim": "c1", "how": "h", "contradicted_by": {}}]

# One entry points via a RAW INT later_wrong index (what a model that
# ignores the schema's digit-string convention might send), one via the
# digit-string form, one via a claim id. All three must resolve, and
# every surviving pointer -- whatever type it arrived as -- must come
# back out as a str: a consumer (#272's gate ledger) should never have
# to handle both `0` and `"0"` for the same evidence pointer.
raw = [
    {"label": "proxy-as-thing", "supports": [0], "why": "int index"},
    {"label": "green-as-done", "supports": ["0"], "why": "digit-string index"},
    {"label": "outcome-not-reason", "supports": ["c1"], "why": "claim id"},
]
out, reason = sd.enforce_classified_as(raw, claims, later_wrong)
assert reason is None, reason
by_label = {e["label"]: e for e in out}
for label in ("proxy-as-thing", "green-as-done", "outcome-not-reason"):
    supports = by_label[label]["supports"]
    assert all(isinstance(s, str) for s in supports), (label, supports)
assert by_label["proxy-as-thing"]["supports"] == ["0"], by_label["proxy-as-thing"]["supports"]
assert by_label["green-as-done"]["supports"] == ["0"], by_label["green-as-done"]["supports"]
assert by_label["outcome-not-reason"]["supports"] == ["c1"], by_label["outcome-not-reason"]["supports"]

# A mixed entry (one int pointer, one string pointer) must come back
# with BOTH normalized, not just the one that started as an int.
raw_mixed = [{"label": "proxy-as-thing", "supports": [0, "c1"], "why": "mixed"}]
out2, _ = sd.enforce_classified_as(raw_mixed, claims, later_wrong)
assert out2[0]["supports"] == ["0", "c1"], out2[0]["supports"]
assert all(isinstance(s, str) for s in out2[0]["supports"]), out2[0]["supports"]
PY
[ $? -eq 0 ] && ok "T1: enforce_classified_as normalizes every surviving supports pointer to a string, including int later_wrong indices, in single-type and mixed-type entries alike" \
  || bad "T1: supports normalized to strings" "rc=nonzero"

# ============================================================ GROUP T — #285: report extraction
echo; echo "T. #285 — report extraction: StructuredOutput, harness_error, plain text, none"

run_stdout sess-285 runs --json
[ "$rc" -eq 0 ] && ok "runs sess-285 exits 0" || bad "runs sess-285 exits 0" "rc=$rc"
echo "$out" > "$TMP/runs-285.json"
"$PY" - "$TMP/runs-285.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = {r["id"]: r for r in d["runs"]}

# StructuredOutput-only line -> report_source "structured_output", and the
# report is NOT empty (the old last_assistant_text-only extraction would
# have silently produced report_chars == 0, report_source absent entirely).
eeee = runs["agent-eeee0005"]
assert eeee["report_source"] == "structured_output", eeee["report_source"]
assert eeee["report_chars"] > 0, eeee["report_chars"]
assert "Fixed the thing" in eeee["report"], eeee["report"]
parsed = json.loads(eeee["report"])
assert parsed["verified"] is True, parsed

# harness cutoff text -> report_source "harness_error", text KEPT verbatim
# (never discarded), never reported as source "text" (which would let it
# be distilled as if it were a real result).
ffff = runs["agent-ffff0006"]
assert ffff["report_source"] == "harness_error", ffff["report_source"]
assert ffff["report"].startswith("You've hit your session limit"), ffff["report"]
PY
[ $? -eq 0 ] && ok "#285: StructuredOutput -> non-empty report + source structured_output; harness cutoff text -> source harness_error, kept verbatim" \
  || bad "#285: report extraction sources" "$(cat "$TMP/runs-285.json")"

run_stdout sess-main runs --json
echo "$out" > "$TMP/runs-main-285.json"
"$PY" - "$TMP/runs-main-285.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = {r["id"]: r for r in d["runs"]}
# the ordinary case (plain text report, no tool_use in the final line) is
# still report_source "text" -- both kinds.
assert runs["agent-aaaa0001"]["report_source"] == "text", runs["agent-aaaa0001"]["report_source"]
assert runs["main-turn-001"]["report_source"] == "text", runs["main-turn-001"]["report_source"]
# a main-turn's report_source is only ever "text"/"none" -- never
# structured_output/harness_error (main turns do not end in a
# StructuredOutput tool_use).
for r in runs.values():
    if r["kind"] == "main-turn":
        assert r["report_source"] in ("text", "none"), (r["id"], r["report_source"])
PY
[ $? -eq 0 ] && ok "#285: ordinary text reports (both kinds) still report_source text; main-turn report_source is only ever text/none" \
  || bad "#285: report_source on ordinary runs" "$(cat "$TMP/runs-main-285.json")"

# a Bash tool_use with NO trailing text at all and no StructuredOutput ->
# report_source "none", report "" -- neither is silently "text".
"$PY" - "$TMP/runs-285.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = {r["id"]: r for r in d["runs"]}
hhhh = runs["agent-hhhh0008"]
assert hhhh["report_source"] == "none", hhhh["report_source"]
assert hhhh["report"] == "", repr(hhhh["report"])
PY
[ $? -eq 0 ] && ok "#285: a run ending mid-tool-call with no text and no StructuredOutput is report_source none, report \"\"" \
  || bad "#285: report_source none case" "$(cat "$TMP/runs-285.json")"

# ============================================================ GROUP U — #285: deterministic verifications[]
echo; echo "U. #285 — deterministic verifications[]: linking, missing tool_result, pipe flags, gates"

"$PY" - "$TMP/runs-285.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = {r["id"]: r for r in d["runs"]}

# ---- LINKING WITHOUT EVIDENCE: each verification carries its OWN
# tool_result's output, matched by tool_use_id, never a neighbor's.
gggg = runs["agent-gggg0007"]
v = gggg["verifications"]
assert len(v) == 2, v
by_id = {e["tool_use_id"]: e for e in v}
assert by_id["b1"]["categories"] == ["test"], by_id["b1"]
assert by_id["b1"]["output"] == "Test Suite All tests passed: 42 tests, 0 failures", by_id["b1"]["output"]
assert by_id["b2"]["categories"] == ["build"], by_id["b2"]
assert by_id["b2"]["output"] == "Build complete! (1.23s)", by_id["b2"]["output"]
assert by_id["b1"]["output"] != by_id["b2"]["output"]
assert by_id["b1"]["output_present"] is True
assert by_id["b2"]["output_present"] is True
# index lines up with the entry's position in tool_trace (2 Bash calls only).
assert by_id["b1"]["index"] == 0, by_id["b1"]["index"]
assert by_id["b2"]["index"] == 1, by_id["b2"]["index"]
assert gggg["gates_run"] == {"test": 1, "lint": 0, "build": 1, "ci_read": 0}, gggg["gates_run"]

# ---- VERDICTS FROM INCOMPLETE DATA: no tool_result at all -> output is
# null (never ""), output_present False, and empty_ci_result must NOT fire
# even though the command is a ci_read.
hhhh = runs["agent-hhhh0008"]
v = hhhh["verifications"]
assert len(v) == 1, v
assert v[0]["categories"] == ["ci_read"], v[0]
assert v[0]["output"] is None, v[0]["output"]
assert v[0]["output_present"] is False, v[0]
assert v[0]["empty_ci_result"] is False, v[0]

# ---- exit_masked_by_pipe vs output_truncated: NOT the same condition.
iiii = runs["agent-iiii0009"]
v = {e["tool_use_id"]: e for e in iiii["verifications"]}
assert len(v) == 4, v
# p1: MASKED -- pipes to head, reads $?, no pipefail protection.
assert v["p1"]["exit_masked_by_pipe"] is True, v["p1"]
assert v["p1"]["output_truncated"] is True, v["p1"]
assert v["p1"]["categories"] == ["lint"], v["p1"]
# p2: no pipe at all -- NEITHER flag.
assert v["p2"]["exit_masked_by_pipe"] is False, v["p2"]
assert v["p2"]["output_truncated"] is False, v["p2"]
assert v["p2"]["categories"] == ["test"], v["p2"]
# p3: pipes to tail but never reads $? -- output_truncated ONLY.
assert v["p3"]["exit_masked_by_pipe"] is False, v["p3"]
assert v["p3"]["output_truncated"] is True, v["p3"]
assert v["p3"]["categories"] == ["build"], v["p3"]
# p4: pipes to tail AND reads $?, but `pipefail` protects it -- truncated,
# NOT masked.
assert v["p4"]["exit_masked_by_pipe"] is False, v["p4"]
assert v["p4"]["output_truncated"] is True, v["p4"]
assert v["p4"]["categories"] == ["lint"], v["p4"]
assert iiii["gates_run"] == {"test": 1, "lint": 2, "build": 1, "ci_read": 0}, iiii["gates_run"]

# ---- gates_named_not_run: the brief names "lint" but no lint command ran
# ("test" is named too, but it DID run, so it must not appear).
jjjj = runs["agent-jjjj0010"]
assert jjjj["gates_run"] == {"test": 1, "lint": 0, "build": 0, "ci_read": 0}, jjjj["gates_run"]
assert jjjj["gates_named_not_run"] == ["lint"], jjjj["gates_named_not_run"]
PY
[ $? -eq 0 ] && ok "#285: verifications[] linked by tool_use_id, missing tool_result -> output null (never empty-string), exit_masked_by_pipe vs output_truncated kept separate, gates_named_not_run" \
  || bad "#285: deterministic verifications[]" "$(cat "$TMP/runs-285.json")"

# ---- build_distill_prompt carries the VERIFICATION COMMANDS section
"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_285_prompt", sys.argv[1])
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)

assert "VERIFICATION COMMANDS" in sd.DISTILL_SYSTEM_PROMPT.upper() \
    or "verification" in sd.DISTILL_SYSTEM_PROMPT.lower(), sd.DISTILL_SYSTEM_PROMPT
assert "omitted-gate" in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT
assert "harness_error" in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT

r = {
    "id": "agent-x", "kind": "subagent", "description": "d",
    "brief": "b", "report": "r", "report_source": "text",
    "tool_calls": 1,
    "tool_trace": [{"tool": "Bash", "digest": "swift format lint ... | head -50", "errored": False}],
    "verifications": [{
        "index": 0, "tool_use_id": "p1", "categories": ["lint"],
        "command": 'swift format lint --recursive --strict 2>&1 | head -50; echo "EXIT=$?"',
        "errored": False, "output": "EXIT=0", "output_present": True,
        "exit_masked_by_pipe": True, "output_truncated": True, "empty_ci_result": False,
    }],
    "gates_run": {"test": 0, "lint": 1, "build": 0, "ci_read": 0},
    "gates_named_not_run": ["build"],
}
prompt = sd.build_distill_prompt(r)
assert "VERIFICATION COMMANDS" in prompt, prompt
assert "exit_masked_by_pipe" in prompt, prompt
assert "EXIT=0" in prompt, prompt
assert "gates_named_not_run" in prompt, prompt
assert '"build"' in prompt, prompt
assert "REPORT_SOURCE: text" in prompt, prompt

# a run with no verifications/gates keys at all (as an older caller might
# construct) must not crash build_distill_prompt.
r2 = {"id": "agent-y", "kind": "subagent", "description": "d", "brief": "b", "report": "r",
      "tool_calls": 0, "tool_trace": []}
sd.build_distill_prompt(r2)
PY
[ $? -eq 0 ] && ok "#285: DISTILL_SYSTEM_PROMPT mentions omitted-gate/harness_error; build_distill_prompt renders VERIFICATION COMMANDS + gates, and tolerates a stub missing those keys" \
  || bad "#285: build_distill_prompt VERIFICATION COMMANDS section" "rc=nonzero"

# ---- verifications/gates_run/gates_named_not_run persist on the RECORD
# regardless of what the model returns (the stub model never emits them).
export MODEL_CALL_LOG="$TMP/calls-u.log"
rm -f "$MODEL_CALL_LOG"
OUT_U="$TMP/out-u.json"
run sess-285 distill --out "$OUT_U" --only agent-gggg0007 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-285 --only agent-gggg0007 exits 0" \
  || bad "distill sess-285 --only agent-gggg0007 exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_U" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rec = d["records"][0]
assert rec["run"]["id"] == "agent-gggg0007", rec["run"]["id"]
assert rec["run"]["report_source"] == "text", rec["run"]["report_source"]
assert len(rec["verifications"]) == 2, rec["verifications"]
assert rec["gates_run"] == {"test": 1, "lint": 0, "build": 1, "ci_read": 0}, rec["gates_run"]
assert rec["gates_named_not_run"] == [], rec["gates_named_not_run"]
PY
[ $? -eq 0 ] && ok "#285: verifications/gates_run/gates_named_not_run/report_source persist on the written record" \
  || bad "#285: verifications persist on the record" "$(cat "$OUT_U")"
unset MODEL_CALL_LOG

# ---- `report` surfaces report_source and verification-flag counts, never silently
run sess-285 distill --only agent-iiii0009 --force --out "$TMP/out-u2.json" --model-cmd "$MODEL_CMD"
run - report --in "$TMP/out-u2.json"
case "$out" in
  *"report_source distribution"*) ok "#285: report prints a report_source distribution section" ;;
  *) bad "#285: report prints a report_source distribution section" "$out" ;;
esac
case "$out" in
  *"exit_masked_by_pipe="*) ok "#285: report surfaces exit_masked_by_pipe run counts" ;;
  *) bad "#285: report surfaces exit_masked_by_pipe run counts" "$out" ;;
esac

# ============================================================ GROUP V — #285: schema_version bump + --resume refusal
echo; echo "V. #285 — SCHEMA_VERSION bumped to 2; --resume refuses a document from a different schema"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_285_schema", sys.argv[1])
sd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sd)
assert sd.SCHEMA_VERSION == 2, sd.SCHEMA_VERSION
PY
[ $? -eq 0 ] && ok "#285: SCHEMA_VERSION is 2" || bad "#285: SCHEMA_VERSION is 2" "rc=nonzero"

OUT_V="$TMP/out-v.json"
"$PY" - "$OUT_V" <<'PY'
import json, sys
doc = {
    "kind": "session-distill-document", "schema_version": 1, "session": "sess-285",
    "session_dir": "/nonexistent", "generated_at": "t", "segmented_by": None,
    "model_cmd": "x", "total_cost_usd": 0.0, "runs_total": 0, "runs_selected": 0,
    "records": [], "failures": [], "unreadable": [], "stopped": None,
}
json.dump(doc, open(sys.argv[1], "w"))
PY
run sess-285 distill --out "$OUT_V" --resume --only agent-eeee0005 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 2 ] && ok "#285: --resume against a schema_version 1 document REFUSES (exit 2)" \
  || bad "#285: --resume against an old-schema document REFUSES" "rc=$rc out=$out"
case "$out" in
  REFUSE:*"schema_version"*) ok "#285: the REFUSE names schema_version as the reason" ;;
  *) bad "#285: the REFUSE names schema_version" "$out" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
