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

# ============================================================ sess-291
# #291: the proof-locatable guard. agent-291p0001 is the placeholder-
# response repro (a schema-valid distill doc whose one claim's proof does
# not exist anywhere in the run's own tool inputs -- and the run DOES have
# a real, non-trivial tool call, so an "unlocatable" verdict here is not
# the vacuous "tool_inputs_full was never populated" failure mode).
# agent-291m0001 carries four claims (#295's index+snippet contract): a
# plain snippet at the right index, a snippet elided with `...` and an
# ` -> output` suffix at the right index, a REAL snippet cited against the
# WRONG (neighbouring) index, and an out-of-range index -- only the first
# two may come back proof_located: true.
sdir_291 = os.path.join(proj, "sess-291")
os.makedirs(sdir_291, exist_ok=True)

w_json(os.path.join(sdir_291, "subagents", "agent-291p0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "placeholder repro"})
w_jsonl(os.path.join(sdir_291, "subagents", "agent-291p0001.jsonl"), [
    user_blocks("Investigate the timeout", "2026-09-21T01:00:00Z"),
    bash_use("q1", "grep -r TIMEOUT src", "2026-09-21T01:00:01Z"),
    tool_result_content("q1", "2026-09-21T01:00:02Z", "3 matches"),
    assistant("Timeout was hardcoded.", "2026-09-21T01:00:03Z"),
])

w_json(os.path.join(sdir_291, "subagents", "agent-291m0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "mixed proof forms"})
w_jsonl(os.path.join(sdir_291, "subagents", "agent-291m0001.jsonl"), [
    user_blocks("Fix the build and tests", "2026-09-21T01:01:00Z"),
    bash_use("m0", "ls -la", "2026-09-21T01:01:01Z"),
    tool_result_content("m0", "2026-09-21T01:01:02Z", "total 0"),
    bash_use("m1", "grep -r TODO src --include=*.py | head -20; echo done", "2026-09-21T01:01:03Z"),
    tool_result_content("m1", "2026-09-21T01:01:04Z", "done"),
    bash_use("m2", "pytest -q", "2026-09-21T01:01:05Z"),
    tool_result_content("m2", "2026-09-21T01:01:06Z", "5 passed"),
    bash_use("m3", "swift build", "2026-09-21T01:01:07Z"),
    tool_result_content("m3", "2026-09-21T01:01:08Z", "Build complete!"),
    assistant("Fixed the build and reran tests.", "2026-09-21T01:01:09Z"),
])

# ============================================================ sess-287
# #287: repo-qualified `#N` retrieval. agent-287cl0001 is the CLAIM run,
# resolved to RepoAlpha (via an unrelated `blamechris/RepoAlpha#5` mention
# in its own report -- its claim's own "#99" text carries no qualifier at
# all, so claim-side resolution falls back to the run's own repo set).
# Three LATER runs all mention the SAME "#99" near a correction cue:
# agent-287same0001 (repo set {RepoAlpha} only -- same as the claim run),
# agent-287diff0001 (repo set {RepoBeta} only -- a DIFFERENT resolved
# repo, so #99 there must NOT become a candidate at all), and
# agent-287amb0001 (repo set {RepoAlpha, RepoBeta} -- ambiguous, so #99
# there is kept as a candidate but tagged repo_match: "ambiguous").
sdir_287 = os.path.join(proj, "sess-287")
os.makedirs(sdir_287, exist_ok=True)

w_json(os.path.join(sdir_287, "subagents", "agent-287cl0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "claim run, RepoAlpha"})
w_jsonl(os.path.join(sdir_287, "subagents", "agent-287cl0001.jsonl"), [
    user_blocks("Investigate the regression", "2026-09-21T02:00:00Z"),
    assistant("Root-caused via blamechris/RepoAlpha#5 precedent and filed the fix.",
              "2026-09-21T02:00:05Z"),
])

w_json(os.path.join(sdir_287, "subagents", "agent-287same0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "later, same repo"})
w_jsonl(os.path.join(sdir_287, "subagents", "agent-287same0001.jsonl"), [
    user_blocks("keep going", "2026-09-21T02:01:00Z"),
    assistant("Correction: turns out #99 was already fixed elsewhere. "
              "Filed as blamechris/RepoAlpha#40 for tracking.", "2026-09-21T02:01:05Z"),
])

w_json(os.path.join(sdir_287, "subagents", "agent-287diff0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "later, different repo"})
w_jsonl(os.path.join(sdir_287, "subagents", "agent-287diff0001.jsonl"), [
    user_blocks("keep going", "2026-09-21T02:02:00Z"),
    assistant("Correction: turns out #99 was already fixed elsewhere. "
              "Filed as blamechris/RepoBeta#50 for tracking.", "2026-09-21T02:02:05Z"),
])

w_json(os.path.join(sdir_287, "subagents", "agent-287amb0001.meta.json"),
       {"agentType": "general-purpose", "model": "sonnet", "description": "later, ambiguous repo"})
w_jsonl(os.path.join(sdir_287, "subagents", "agent-287amb0001.jsonl"), [
    user_blocks("keep going", "2026-09-21T02:03:00Z"),
    assistant("Correction: turns out #99 was already fixed elsewhere. Also touched "
              "blamechris/RepoAlpha#12 and blamechris/RepoBeta#34 today.", "2026-09-21T02:03:05Z"),
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

# #294: STUB_FAIL_DISTILL=<run id> makes that run's distill call an
# is_error envelope, so a test can fail a run once and then --resume it
# with the variable unset (a succeeding stub).
if pass_kind == "distill" and run_id and run_id == os.environ.get("STUB_FAIL_DISTILL"):
    print(json.dumps(envelope(None, is_error=True)))
    sys.exit(0)

if pass_kind == "distill":
    if run_id == "agent-dddd0004":
        # #278 C2 fixture: two claims, so a later_wrong/classified_as
        # response can reference both a valid and an invalid claim id.
        doc = {"asked": "do Y", "understood": "do Y", "delivered": "did Y",
               "claims": [
                   # proof left null throughout this fixture on purpose --
                   # #278 C2 is about later_wrong/classified_as pointer
                   # resolution, not #291's proof-locatable guard, and
                   # this run's own transcript has no tool_use at all
                   # (any non-null proof here would be unlocatable and
                   # wrongly trip the #291 placeholder-response FAILURE).
                   {"id": "c1", "text": "claim one", "kind": "verification",
                    "proof": None, "quote": "q1"},
                   {"id": "c2", "text": "claim two", "kind": "verification",
                    "proof": None, "quote": "q2"},
               ]}
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-291p0001":
        # #291: the exact placeholder repro from the issue -- asked/
        # understood/delivered all "test", one claim whose proof ("test
        # proof") does not exist anywhere in this run's real tool inputs
        # ("grep -r TIMEOUT src"). Must become a FAILURE, never a record,
        # and must never reach the chain call.
        doc = {"asked": "test", "understood": "test", "delivered": "test",
               "claims": [{"id": "c1", "text": "test claim", "kind": "unspecified",
                           "proof_index": 0, "proof_snippet": "test proof", "quote": None}]}
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-291m0001":
        # #295: four claims -- a snippet at its right index, an elided
        # snippet with an ` -> output` suffix at its right index (both
        # locatable), a REAL snippet ("swift build", trace [3]) cited
        # against the WRONG index [2], and an out-of-range index (both
        # must come back proof_located: false). A model-written `proof`
        # on c1 must be discarded in favour of the derived one.
        doc = {"asked": "a", "understood": "a", "delivered": "a", "claims": [
            {"id": "c1", "text": "the build passes", "kind": "verification",
             "proof_index": 3, "proof_snippet": "swift build",
             "proof": "a paraphrase the model wrote", "quote": "Build complete!"},
            {"id": "c2", "text": "no TODOs remain", "kind": "verification",
             "proof_index": 1, "proof_snippet": "grep -r TODO src --include=*.py ... -> done",
             "quote": "done"},
            {"id": "c3", "text": "the build passes again", "kind": "verification",
             "proof_index": 2, "proof_snippet": "swift build", "quote": "Build complete!"},
            {"id": "c4", "text": "network reachable", "kind": "verification",
             "proof_index": 99, "proof_snippet": "swift build", "quote": "n/a"},
        ]}
        print(json.dumps(envelope(doc)))
    elif run_id == "agent-287cl0001":
        # #287: the claim run. c1's own text carries "#99" with NO
        # qualifier attached to that occurrence -- claim-side resolution
        # must fall back to this run's own repo set (RepoAlpha, from its
        # unrelated "blamechris/RepoAlpha#5" report mention).
        doc = {"asked": "a", "understood": "a", "delivered": "a",
               "claims": [{"id": "c1", "text": "#99 is caused by a stale cache entry",
                           "kind": "reasoning", "proof": None,
                           "quote": "the fix addresses #99 directly"}]}
        print(json.dumps(envelope(doc)))
    else:
        # proof null here too, for the same #291 reason -- most of these
        # fixture runs have no (or unrelated) tool_use calls, so a
        # non-null proof would be spuriously unlocatable.
        doc = {"asked": "do X", "understood": "do X", "delivered": "did X",
               "claims": [{"id": "c1", "text": "the thing works", "kind": "verification",
                           "proof": None, "quote": "it works"}]}
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
    elif run_id == "agent-287cl0001":
        # #287 enforcement, end-to-end: two later_wrong entries for the
        # SAME claim, one contradicted_by run resolved-ambiguous
        # (agent-287amb0001 -- must be DROPPED, reason
        # "repo-ambiguous-only"), one contradicted_by run resolved-same
        # (agent-287same0001 -- must SURVIVE). classified_as points one
        # label at each later_wrong index: the one supporting the DROPPED
        # index (0) must itself be dropped entirely (no pointer left that
        # resolves to anything); the one supporting the SURVIVING index
        # (1) must survive, remapped to its new position (0).
        doc = {
            "later_wrong": [
                {"claim": "c1", "how": "ambiguous-repo mention",
                 "contradicted_by": {"run": "agent-287amb0001", "at": "2026-09-21T02:03:05Z",
                                      "quote": "turns out #99 was already fixed elsewhere"}},
                {"claim": "c1", "how": "same-repo mention",
                 "contradicted_by": {"run": "agent-287same0001", "at": "2026-09-21T02:01:05Z",
                                      "quote": "turns out #99 was already fixed elsewhere"}},
            ],
            "classified_as": [
                {"label": "recalled-not-reopened", "supports": ["0"], "why": "ambiguous-linked"},
                {"label": "outcome-not-reason", "supports": ["1"], "why": "same-repo-linked"},
            ],
        }
        print(json.dumps(envelope(doc)))
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
assert d["schema_version"] == 4
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

# #286: the exit-code-proxy definition reaches the model through the
# rendered chain prompt's LABELS section, not the system prompt
chain = sd.build_chain_prompt({"id": "r"}, [], [])
proxy_line = [l for l in chain.splitlines() if l.startswith("proxy-as-thing:")]
assert len(proxy_line) == 1, chain
assert "$?" in proxy_line[0] and "head" in proxy_line[0] and "tail" in proxy_line[0], proxy_line

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
[ $? -eq 0 ] && ok "M1: DISTILL_SYSTEM_PROMPT states proof as a floor sourced from the trace; the chain prompt defines the exit-code-proxy pattern; build_distill_prompt carries the full trace" \
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
# #286: the model is told NOT to restate the gates fields as claims -- the
# #285 "omitted-gate" instruction produced claims about the prompt itself
assert "omitted-gate" not in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT
assert "never about this prompt" in sd.DISTILL_SYSTEM_PROMPT, sd.DISTILL_SYSTEM_PROMPT
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
[ $? -eq 0 ] && ok "#285: DISTILL_SYSTEM_PROMPT forbids claims restating the gates fields and mentions harness_error; build_distill_prompt renders VERIFICATION COMMANDS + gates, and tolerates a stub missing those keys" \
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
assert sd.SCHEMA_VERSION == 4, sd.SCHEMA_VERSION
PY
[ $? -eq 0 ] && ok "#295: SCHEMA_VERSION is 4" || bad "#295: SCHEMA_VERSION is 4" "rc=nonzero"

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

# ---- segment-aware exit masking + harness-error wording, from real commands
# on 13cee7be's agent-a353ff10: entries 53/66/72 read lint's own `$?` and
# only pipe a LATER command, and were flagged by a whole-command check.
"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_seg", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
f = sd.classify_pipe_flags
# the named defect: head's status, not lint's
assert f('swift format lint --strict Sources 2>&1 | head -50; echo "EXIT=$?"') == (True, True)
# lint's real status is read; the pipe belongs to the next command
assert f('echo "=== fmt ===" && swift format lint --strict Sources; echo "exit=$?"; '
         'echo "=== swiftlint ===" && swiftlint lint 2>&1 | tail -3') == (False, True)
assert f('swift format lint --strict Sources 2>&1; echo "lint-exit=$?"\nswift build --build-tests | tail -5') == (False, True)
# a pipe whose own status IS the point (grep's rc) masks no gate, even in
# a command that runs a gate elsewhere
assert f("swift test; git log -2 | grep -iE 'co-authored'; echo \"grep rc=$?\"") == (False, True)
# pipefail set AFTER the masked read does not protect it
assert f('npm test | tail; echo $?; set -o pipefail') == (True, True)
# pipefail set before protects
assert f('set -euo pipefail; npm test | tail; echo $?') == (False, True)
assert f('set -e -o pipefail; npm test | tail; echo $?') == (False, True)
assert f('npm test | tail; echo "${PIPESTATUS[0]} $?"') == (False, True)  # PIPESTATUS read in the same segment
# the bare word protects nothing
assert f('echo pipefail; npm test | tail; echo $?') == (True, True)
assert f('set -o pipefail; npm test | tail; echo $?') == (False, True)
# && chains read the pipeline too
assert f('swift test | grep -c passed && echo ok=$?') == (True, True)
# heredoc bodies are data: a script whose TEXT describes the defect is not it
s = sd.strip_heredoc_bodies
assert f(s("python3 - <<'PY'\nnote = 'lint | head -50; echo $?'\nPY\necho done")) == (False, False)
assert f(s("cat > m.md <<EOF\nswift test | tail\necho $?\nEOF")) == (False, False)
# the shell around a heredoc is still read
assert f(s("swift test | tail -5; echo rc=$?; cat <<EOF\nx\nEOF")) == (True, True)
# a <<< here-string has no body to strip
assert s('grep -c x <<< "word"\nswift test | tail; echo $?') == 'grep -c x <<< "word"\nswift test | tail; echo $?'
# through the trace builder, not just the helper: the call site must strip
def use(tid, cmd):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}}
def res(tid):
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}}
objs = [use("h1", "python3 - <<'PY'\nprint('swift test | tail -3; echo $?')\nPY"), res("h1"),
        use("h2", "swift test | tail -3; echo $?"), res("h2")]
_, _, ver, _ = sd.build_tool_trace(objs)
assert all(not v["exit_masked_by_pipe"] for v in ver if "print(" in v["command"]), ver
assert [v["exit_masked_by_pipe"] for v in ver if "print(" not in v["command"]] == [True], ver
# unterminated: nothing after the opener is shell
assert s("cat <<EOF\nswift test | tail; echo $?") == "cat <<EOF"
# a StructuredOutput the harness rejected is not the report; the last
# accepted one is, and all-rejected is labelled rather than trusted
def so(tid, payload):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": "StructuredOutput", "input": payload}]}}
def so_res(tid, err):
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tid, "is_error": err, "content": "x"}]}}
rep, src = sd.extract_report([so("s1", {"v": "GOOD"}), so_res("s1", False),
                              so("s2", {"v": "BAD"}), so_res("s2", True)])
assert src == "structured_output" and "GOOD" in rep and "BAD" not in rep, (src, rep)
rep, src = sd.extract_report([so("s1", {"v": "BAD"}), so_res("s1", True)])
assert src == "structured_output_rejected" and "BAD" in rep, (src, rep)
# image-only tool_result content yields no text: None, never ""
assert sd.extract_tool_result_text([{"type": "image", "source": "x"}]) is None
assert sd.extract_tool_result_text([]) is None
# trace lines carry the same index verification entries use
prompt = sd.build_distill_prompt({"id": "r", "kind": "subagent", "tool_calls": 2,
    "tool_trace": [{"tool": "Read", "digest": "a", "errored": False},
                   {"tool": "Bash", "digest": "swift test", "errored": False}],
    "verifications": [{"index": 1, "categories": ["test"], "command": "swift test",
                       "output_present": True, "output": "ok"}]})
assert "[1] Bash: swift test" in prompt and "[1] categories=test" in prompt, prompt
h = sd.classify_harness_error
assert h("You've hit your weekly limit · resets 4pm (America/Los_Angeles)")
assert h("You've hit your session limit · resets 2:40am (America/Los_Angeles)")
assert not h("The report notes: You've hit your session limit earlier, retried.")
PY
[ $? -eq 0 ] && ok "#285: exit masking is per-pipeline (a later piped command does not mask an earlier \$? read); weekly-limit cutoff is harness_error; heredoc bodies are not classified; rejected StructuredOutput is not the report; no-text result is None; trace lines are indexed" \
  || bad "#285: exit masking, harness_error, heredocs, rejected StructuredOutput, no-text results, trace indexing"

# a pre-v2 record (no report_source) is counted in the distribution, not
# dropped from it while still counted in `records:`
OUT_V1="$TMP/v1-report.json"
"$PY" - "$OUT_V1" <<'PY'
import json, sys
json.dump({"kind": "session-distill", "schema_version": 1, "session": "s",
           "records": [{"kind": "session-distill-record", "run": {"id": "r1"},
                        "claims": [], "classified_as": [], "later_wrong": []}],
           "failures": []}, open(sys.argv[1], "w"))
PY
run - report --in "$OUT_V1"
case "$out" in
  *"(no report_source: pre-v2)"*1*) ok "#285: report counts a pre-v2 record under its own report_source bucket" ;;
  *) bad "#285: report counts a pre-v2 record under its own report_source bucket" "rc=$rc out=$out" ;;
esac

# ============================================================ #286 — label precision
echo; echo "#286. label precision"
"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_286", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
# one definition per label, no more, no fewer
assert set(sd.LABEL_DEFINITIONS) == set(sd.LABELS), set(sd.LABEL_DEFINITIONS) ^ set(sd.LABELS)
# proxy-as-thing carries its negative example: truncated READING is not it
d = sd.LABEL_DEFINITIONS["proxy-as-thing"]
assert "NOT this label" in d and "tail -30" in d, d
# every label is defined in the prompt the model receives
chain = sd.build_chain_prompt({"id": "r", "verifications": [
    {"index": 4, "command": "swift test | tail; echo $?", "exit_masked_by_pipe": True},
    {"index": 5, "command": "swift test | tail -3", "output_truncated": True},
    {"index": 9, "command": "gh pr view 1 --json statusCheckRollup", "empty_ci_result": True}]}, [], [])
for label in sd.LABELS:
    assert ("%s: %s" % (label, sd.LABEL_DEFINITIONS[label])) in chain, label
# flagged entries only: truncation alone is not listed as evidence
assert "[4] exit_masked_by_pipe: swift test | tail; echo $?" in chain, chain
assert "[9] empty_ci_result:" in chain, chain
assert "[5]" not in chain, chain
assert "VERIFICATION FLAGS (deterministic, 2)" in chain, chain
empty = sd.build_chain_prompt({"id": "r"}, [], [])
assert "VERIFICATION FLAGS (deterministic, 0)" in empty and "(none:" in empty, empty
PY
[ $? -eq 0 ] && ok "#286: every label defined once in the chain prompt; proxy-as-thing excludes truncated reading; only flagged verifications are listed" \
  || bad "#286: label definitions / chain prompt flags"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_286b", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
claims = [{"id": "c1"}, {"id": "c2"}]
lw = [{"claim": "c1"}, {"claim": "c1"}, {"claim": "c2"}]
# model labelled only later_wrong[0]: [1] and [2] get explicit unclassified
out, reason = sd.enforce_classified_as(
    [{"label": "proxy-as-thing", "supports": ["0", "c2"], "why": "w"}], claims, lw)
by_ptr = {tuple(e["supports"]): e for e in out}
assert by_ptr[("0", "c2")]["label"] == "proxy-as-thing", out
assert by_ptr[("1",)]["label"] == "unclassified" and "later_wrong[1]" in by_ptr[("1",)]["why"], out
assert by_ptr[("2",)]["label"] == "unclassified", out
assert len(out) == 3, out
assert "later_wrong[1]" in reason and "later_wrong[2]" in reason and "later_wrong[0]" not in reason, reason
# all covered (int and string pointers alike): nothing added, no reason
out, reason = sd.enforce_classified_as(
    [{"label": "green-as-done", "supports": [0, "1"], "why": "w"},
     {"label": "letter-not-goal", "supports": ["2"], "why": "w"}], claims, lw)
assert [e["label"] for e in out] == ["green-as-done", "letter-not-goal"], out
assert reason is None, reason
# a label whose only pointer does not resolve is dropped, and does not
# count as covering anything
out, reason = sd.enforce_classified_as(
    [{"label": "green-as-done", "supports": ["7"], "why": "w"}], claims, lw[:1])
assert out == [{"label": "unclassified", "supports": ["0"],
                "why": "later_wrong[0] was not classified by the model"}], out
# #290 review: pointers address the model's RAW later_wrong array. Dropping
# raw[0] must not slide raw[1]'s label onto raw[2], nor mark raw[1] as
# unclassified. Through build_record, the real call path.
stub = {"id": "r", "kind": "subagent", "brief_chars": 0, "report_chars": 0, "tool_calls": 0}
rec, dropped = sd.build_record(
    "s", stub,
    {"asked": "a", "understood": "u", "delivered": "d",
     "claims": [{"id": "cB", "text": "B"}, {"id": "cC", "text": "C"}]},
    {"later_wrong": [
        {"claim": "c_hallucinated", "how": "x", "contradicted_by": {}},
        {"claim": "cB", "how": "B wrong", "contradicted_by": {}},
        {"claim": "cC", "how": "C wrong", "contradicted_by": {}}],
     "classified_as": [
        {"label": "proxy-as-thing", "supports": ["1"], "why": "about B"},
        {"label": "green-as-done", "supports": [2], "why": "about C"}]},
    "t", "m", 0.0, 2)
lw = rec["later_wrong"]
assert [e["claim"] for e in lw] == ["cB", "cC"], lw
lab = {e["label"]: e["supports"] for e in rec["classified_as"]}
assert lab == {"proxy-as-thing": ["0"], "green-as-done": ["1"]}, rec["classified_as"]
assert rec["unclassified_reason"] is None, rec["unclassified_reason"]
assert dropped == ["c_hallucinated"], dropped
# a pointer at the dropped raw entry resolves to nothing
_, _, imap = sd.normalize_later_wrong(
    [{"claim": "nope"}, {"claim": "cB"}], {"cB"})
assert imap == {1: 0}, imap
out, _ = sd.enforce_classified_as(
    [{"label": "green-as-done", "supports": ["0"], "why": "w"}],
    [{"id": "cB"}], [{"claim": "cB"}], imap)
assert out == [{"label": "unclassified", "supports": ["0"],
                "why": "later_wrong[0] was not classified by the model"}], out
# a digit-only claim id is prefixed, so it cannot pose as a later_wrong index
claims = sd.normalize_claims([{"id": "0", "text": "t"}, {"id": "c2", "text": "t"}])
assert [c["id"] for c in claims] == ["c0", "c2"], claims
out, reason = sd.enforce_classified_as(
    [{"label": "green-as-done", "supports": ["0"], "why": "about claim 0"}],
    claims, [{"claim": "c2"}, {"claim": "c2"}])
assert [(e["label"], e["supports"]) for e in out] == [
    ("green-as-done", ["0"]), ("unclassified", ["1"])], out
PY
[ $? -eq 0 ] && ok "#286: every later_wrong is covered by a label or carries an explicit unclassified entry and reason; index pointers follow the raw array through drops" \
  || bad "#286: later_wrong coverage enforcement"

OUT_COV="$TMP/coverage.json"
"$PY" - "$OUT_COV" <<'PY'
import json, sys
rec = lambda labels: {"kind": "session-distill-record", "run": {"id": "r", "report_source": "text"},
                      "claims": [], "later_wrong": [],
                      "classified_as": [{"label": l, "supports": ["c1"], "why": ""} for l in labels]}
json.dump({"kind": "session-distill", "schema_version": 2, "session": "s", "failures": [],
           "records": [rec(["proxy-as-thing", "proxy-as-thing"]), rec(["green-as-done"]), rec([]), rec([])]},
          open(sys.argv[1], "w"))
PY
run - report --in "$OUT_COV"
case "$out" in
  *"proxy-as-thing"*"   2     1   25.0%"*) ok "#286: report prints each label's entries, runs and run share (base rate)" ;;
  *) bad "#286: report prints label base rates" "rc=$rc out=$out" ;;
esac

# ============================================================ GROUP W — #291: proof-locatable guard
echo; echo "W. #291 — the proof-locatable guard (unit-level)"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_291_unit", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)

# locate_proof_fragment: strip [N] / ToolName: prefixes, cut at first
# elision/arrow, whitespace-collapse.
assert sd.locate_proof_fragment("[3] Bash: swift build") == "swift build", sd.locate_proof_fragment("[3] Bash: swift build")
assert sd.locate_proof_fragment("Bash: swift  test   --filter Foo") == "swift test --filter Foo", \
    sd.locate_proof_fragment("Bash: swift  test   --filter Foo")
assert sd.locate_proof_fragment("grep -r TODO src --include=*.py ... -> done") == "grep -r TODO src --include=*.py", \
    sd.locate_proof_fragment("grep -r TODO src --include=*.py ... -> done")
assert sd.locate_proof_fragment("swift format lint ...  ->  EXIT=0") == "swift format lint", \
    sd.locate_proof_fragment("swift format lint ...  ->  EXIT=0")
assert sd.locate_proof_fragment("") == ""
assert sd.locate_proof_fragment(None) == ""
# no prefix, no cut marker at all -- the whole (collapsed) string is the fragment
assert sd.locate_proof_fragment("swift build") == "swift build"

# proof_located (#295): the index must name a real entry AND the snippet
# must occur in THAT entry -- never vacuously true
full = ["ls -la", "swift build"]
assert sd.proof_located(1, "swift build", full) is True
assert sd.proof_located(1, "[1] Bash: swift build", full) is True, "a copied [N] Tool: prefix is stripped"
assert sd.proof_located(0, "swift build", full) is False, "a real snippet at the WRONG index must be caught"
assert sd.proof_located(2, "swift build", full) is False, "out of range"
assert sd.proof_located(-1, "swift build", full) is False, "negative index is not python's last-item"
assert sd.proof_located(True, "ls -la", full) is False, "a bool is not an index"
assert sd.proof_located(None, "swift build", full) is False
assert sd.proof_located(1, None, full) is False, "an index with no snippet is unchecked, so unlocatable"
assert sd.proof_located(1, "", full) is False
assert sd.proof_located(0, "nonexistent-command-xyz", full) is False
assert sd.proof_located(0, "swift build", []) is False, "empty tool_inputs_full must never be vacuously located"

# compute_proof_located: derives `proof` from the index (discarding any
# model-written text), True/False for a cited claim, None (never absent)
# for an uncited one
claims = [{"id": "c1", "proof_index": 0, "proof_snippet": "swift build", "proof": "paraphrase"},
          {"id": "c2", "proof_index": None, "proof_snippet": None, "proof": None},
          {"id": "c3", "proof_index": 0, "proof_snippet": "missing-cmd-xyz", "proof": None},
          {"id": "c4", "proof_index": 7, "proof_snippet": "swift build", "proof": None},
          {"id": "c5", "proof_index": None, "proof_snippet": None, "proof": "legacy free text"}]
n_nonnull, n_unlocatable = sd.compute_proof_located(claims, ["swift build"])
assert (n_nonnull, n_unlocatable) == (4, 3), (n_nonnull, n_unlocatable)
assert claims[0]["proof_located"] is True and claims[0]["proof"] == "swift build", claims[0]
assert claims[1]["proof_located"] is None and claims[1]["proof"] is None, claims[1]
assert claims[2]["proof_located"] is False and claims[2]["proof"] == "swift build", claims[2]
assert claims[3]["proof_located"] is False and claims[3]["proof"] is None, claims[3]
# a legacy free-text proof counts as cited (so the guard sees it) but is
# never persisted and never locates
assert claims[4]["proof_located"] is False and claims[4]["proof"] is None, claims[4]

# the derived proof is excerpted, so one long heredoc cannot bloat a record
long_cmd = "cat <<EOF " + "x" * 5000
c = [{"id": "c1", "proof_index": 0, "proof_snippet": "cat <<EOF xxxx"}]
sd.compute_proof_located(c, [long_cmd])
assert c[0]["proof_located"] is True and len(c[0]["proof"]) <= 601, len(c[0]["proof"])

# normalize_claims keeps only well-typed citation fields
nc = sd.normalize_claims([{"id": "c1", "text": "t", "kind": "k", "proof_index": "3",
                           "proof_snippet": 5}, {"id": "c2", "proof_index": True}])
assert nc[0]["proof_index"] is None and nc[0]["proof_snippet"] is None, nc[0]
assert nc[1]["proof_index"] is None, nc[1]

# claims_all_proofs_unlocatable: the FAILURE predicate itself
is_fail, nn, nu = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "proof_index": 0, "proof_snippet": "test proof"}]}, ["grep -r TIMEOUT src"])
assert (is_fail, nn, nu) == (True, 1, 1), (is_fail, nn, nu)
# a placeholder that ignores the index contract entirely still fails
is_fail_l, nnl, nul = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "proof": "test proof"}]}, ["grep -r TIMEOUT src"])
assert (is_fail_l, nnl, nul) == (True, 1, 1), (is_fail_l, nnl, nul)
# every citation real but pointed one entry off: still a FAILURE
is_fail_w, nnw, nuw = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "proof_index": 1, "proof_snippet": "grep -r TIMEOUT"}]},
    ["grep -r TIMEOUT src", "swift build"])
assert (is_fail_w, nnw, nuw) == (True, 1, 1), (is_fail_w, nnw, nuw)

is_fail_mixed, nn2, nu2 = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "proof_index": 0, "proof_snippet": "swift build"},
                {"id": "c2", "proof_index": 0, "proof_snippet": "missing-cmd-xyz"}]},
    ["swift build"])
assert (is_fail_mixed, nn2, nu2) == (False, 2, 1), (is_fail_mixed, nn2, nu2)

# policy (left as-is, per the task's own instruction not to invent one):
# zero claims, or every claim uncited, is NOT a #291 failure -- there is
# no cited proof for this guard to fail on.
is_fail3, nn3, nu3 = sd.claims_all_proofs_unlocatable({"claims": []}, ["swift build"])
assert (is_fail3, nn3, nu3) == (False, 0, 0), (is_fail3, nn3, nu3)
is_fail4, nn4, nu4 = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "proof_index": None, "proof_snippet": None}]}, ["swift build"])
assert (is_fail4, nn4, nu4) == (False, 0, 0), (is_fail4, nn4, nu4)
PY
[ $? -eq 0 ] && ok "#291: locate_proof_fragment strips [N]/ToolName: prefixes and cuts at the first elision/arrow; proof_located checks the snippet against the CITED index only (a wrong index is caught) and is never vacuously true; compute_proof_located derives proof from the index and sets True/False/None; claims_all_proofs_unlocatable is the FAILURE predicate, and a zero/all-null-proof result is NOT a failure by this guard" \
  || bad "#291: proof-locatable guard unit tests" "rc=nonzero"

echo; echo "W2. #291 — end to end: placeholder response is a FAILURE, chain never called; mixed doc flags only the invented proof"

export MODEL_CALL_LOG="$TMP/calls-w.log"
rm -f "$MODEL_CALL_LOG"
OUT_W1="$TMP/out-w1.json"
run sess-291 distill --out "$OUT_W1" --only agent-291p0001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-291 --only agent-291p0001 exits 0 (a recorded failure, not a REFUSE)" \
  || bad "distill sess-291 --only agent-291p0001 exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_W1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["records"] == [], d["records"]
failures = {f["run"]: f for f in d["failures"]}
assert "agent-291p0001" in failures, failures
f = failures["agent-291p0001"]
assert f["phase"] == "distill", f
assert f["error"].startswith("proof-not-in-trace:"), f["error"]
PY
[ $? -eq 0 ] && ok "#291: the placeholder response (every non-null proof unlocatable) is a FAILURE (phase distill), records: 0, never a record" \
  || bad "#291: placeholder response is a FAILURE" "$(cat "$OUT_W1")"
case "$(cat "$MODEL_CALL_LOG" 2>/dev/null)" in
  *"agent-291p0001 chain"*) bad "#291: the chain call is NOT made for a placeholder-failed run" "$(cat "$MODEL_CALL_LOG")" ;;
  *) ok "#291: the chain call is NOT made for a placeholder-failed run" ;;
esac
grep -q "^agent-291p0001 distill$" "$MODEL_CALL_LOG" \
  && ok "#291: the distill call WAS made (cost still accounted for)" \
  || bad "#291: the distill call was made" "$(cat "$MODEL_CALL_LOG")"
unset MODEL_CALL_LOG

OUT_W2="$TMP/out-w2.json"
run sess-291 distill --out "$OUT_W2" --only agent-291m0001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-291 --only agent-291m0001 exits 0" \
  || bad "distill sess-291 --only agent-291m0001 exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_W2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["records"]) == 1, d["records"]
rec = d["records"][0]
claims = {c["id"]: c for c in rec["claims"]}
# #295: the two right-index citations locate; a real snippet at the wrong
# index and an out-of-range index do not.
assert claims["c1"]["proof_located"] is True, claims["c1"]
assert claims["c2"]["proof_located"] is True, claims["c2"]
assert claims["c3"]["proof_located"] is False, claims["c3"]
assert claims["c4"]["proof_located"] is False, claims["c4"]
# `proof` is derived from the cited trace entry, never the model's text
assert claims["c1"]["proof"] == "swift build", claims["c1"]
assert claims["c2"]["proof"] == "grep -r TODO src --include=*.py | head -20; echo done", claims["c2"]
assert claims["c3"]["proof"] == "pytest -q", claims["c3"]
assert claims["c4"]["proof"] is None, claims["c4"]
assert claims["c1"]["proof_index"] == 3 and claims["c1"]["proof_snippet"] == "swift build", claims["c1"]
PY
[ $? -eq 0 ] && ok "#295: mixed doc -- record written, right-index citations locate, a real snippet at the wrong index and an out-of-range index do not, and proof is derived from the trace" \
  || bad "#291: mixed doc proof_located flags" "$(cat "$OUT_W2")"

run - report --in "$OUT_W2"
case "$out" in
  *"proof_located: 2/4"*) ok "#291: report prints the unlocatable-proof count/rate" ;;
  *) bad "#291: report prints the unlocatable-proof count/rate" "rc=$rc out=$out" ;;
esac

# ============================================================ GROUP X — #287: repo-qualified retrieval
echo; echo "X. #287 — repo-qualified #N retrieval (unit-level)"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_287_unit", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)

# extract_repo_qualifiers: the four STRONG forms seed the vocabulary; a
# bare mention (no slash, no flag, no path) seeds NOTHING -- "issue #250"
# must not qualify "issue" as a repo.
assert sd.extract_repo_qualifiers("owner/Foo#12 landed") == {"Foo"}
assert sd.extract_repo_qualifiers("see https://github.com/blamechris/Aeolus/pull/264") == {"Aeolus"}
assert sd.extract_repo_qualifiers("gh issue view 5 --repo blamechris/skill-templates") == {"skill-templates"}
assert sd.extract_repo_qualifiers("cd /Users/x/Projects/skill-templates && ls") == {"skill-templates"}
assert sd.extract_repo_qualifiers("git -C /Users/x/Projects/Aeolus fetch origin") == {"Aeolus"}
assert sd.extract_repo_qualifiers("issue #250 needs a look") == set(), \
    "a bare #N with no owner/repo must never seed the vocabulary"
assert sd.extract_repo_qualifiers("") == set()

# repo_from_cwd: slash form is generic; the dash-joined form (a session
# directory basename) is matched against KNOWN names, longest first, so a
# dash-containing repo name is not shadowed by a shorter prefix of itself.
assert sd.repo_from_cwd("/Users/blamechris/Projects/Aeolus/.claude/worktrees/x", set()) == "Aeolus"
dash_path = ("/private/tmp/claude-501/-Users-blamechris-Projects-Aeolus"
             "--claude-worktrees-x/13cee7be/scratchpad")
assert sd.repo_from_cwd(dash_path, {"Aeolus"}) == "Aeolus"
dash_path2 = ("/private/tmp/claude-501/-Users-blamechris-Projects-skill-templates"
              "--claude-worktrees-x/scratchpad")
assert sd.repo_from_cwd(dash_path2, {"skill", "skill-templates"}) == "skill-templates", \
    "longest matching known name must win over a shorter prefix of itself"
assert sd.repo_from_cwd(None, {"Aeolus"}) is None
assert sd.repo_from_cwd("/no/projects/here", {"Aeolus"}) is None

# resolve_hash_qualifier: owner/repo#N and bare repo#N (vocabulary-gated)
# immediately before; the markdown-link URL form immediately after.
t1 = "see blamechris/Aeolus#264 today"
i1 = t1.index("#264")
assert sd.resolve_hash_qualifier(t1, i1, i1 + 4, "264", set()) == "Aeolus"
t2 = "fixed in skill-templates#12 now"
i2 = t2.index("#12")
assert sd.resolve_hash_qualifier(t2, i2, i2 + 3, "12", {"skill-templates"}) == "skill-templates"
assert sd.resolve_hash_qualifier(t2, i2, i2 + 3, "12", set()) is None, \
    "a bare word before #N only qualifies when it is already in vocabulary"
t3 = "See [#264](https://github.com/blamechris/Aeolus/pull/264) for detail"
i3 = t3.index("#264")
assert sd.resolve_hash_qualifier(t3, i3, i3 + 4, "264", set()) == "Aeolus"
t4 = "plain #250 mention"
i4 = t4.index("#250")
assert sd.resolve_hash_qualifier(t4, i4, i4 + 4, "250", set()) is None

# resolve_claim_hash_repo: an occurrence-level qualifier in the claim's
# own text wins over the run-context fallback; absent one, falls back to
# CURRENT_REPOS only when it names exactly one repo.
claims_a = [{"id": "c1", "text": "#99 bad", "quote": None}]
assert sd.resolve_claim_hash_repo(claims_a, "#99", set(), set()) is None
assert sd.resolve_claim_hash_repo(claims_a, "#99", set(), {"RepoAlpha"}) == "RepoAlpha"
assert sd.resolve_claim_hash_repo(claims_a, "#99", set(), {"RepoAlpha", "RepoBeta"}) is None
claims_b = [{"id": "c1", "text": "blamechris/RepoAlpha#99 bad", "quote": None}]
assert sd.resolve_claim_hash_repo(claims_b, "#99", set(), {"RepoBeta"}) == "RepoAlpha", \
    "an explicit qualifier attached to the occurrence wins over the run-context fallback"
PY
[ $? -eq 0 ] && ok "#287: extract_repo_qualifiers seeds the vocabulary from the four strong forms only (never a bare #N); repo_from_cwd handles both path shapes; resolve_hash_qualifier/resolve_claim_hash_repo resolve per-occurrence qualifiers and the run-context fallback correctly" \
  || bad "#287: repo-qualifier unit tests" "rc=nonzero"

echo; echo "X2. #287 — find_chain_candidates: different repo is skipped, same repo tagged same, ambiguous kept and tagged"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_287_candidates", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)

claims = [{"id": "c1", "text": "#99 is caused by a stale cache entry",
           "quote": "the fix addresses #99 directly"}]
current_repos = {"RepoAlpha"}
vocabulary = {"RepoAlpha", "RepoBeta"}
cue = "Correction: turns out #99 was already fixed elsewhere."

run_same = {"id": "run-same", "started_at": "2026-01-01T00:01:00Z", "brief": "",
            "report": cue + " Filed as blamechris/RepoAlpha#40 for tracking.",
            "repos": ["RepoAlpha"]}
run_diff = {"id": "run-diff", "started_at": "2026-01-01T00:02:00Z", "brief": "",
            "report": cue + " Filed as blamechris/RepoBeta#50 for tracking.",
            "repos": ["RepoBeta"]}
run_amb = {"id": "run-amb", "started_at": "2026-01-01T00:03:00Z", "brief": "",
           "report": cue + " Also touched blamechris/RepoAlpha#12 and blamechris/RepoBeta#34 today.",
           "repos": ["RepoAlpha", "RepoBeta"]}

cands = sd.find_chain_candidates(
    claims, "2026-01-01T00:00:00Z", current_repos, [run_same, run_diff, run_amb], vocabulary)
by_run = {c["run"]: c for c in cands}
assert "run-diff" not in by_run, ("a #N resolved to a DIFFERENT repo must never become a candidate", cands)
assert by_run["run-same"]["repo_match"] == "same", by_run.get("run-same")
assert by_run["run-amb"]["repo_match"] == "ambiguous", by_run.get("run-amb")
assert len(cands) == 2, cands

# a non-#N artifact carries no repo concept -- tagged "n/a", never dropped
# by repo logic regardless of the runs' resolved repo sets.
claims_path = [{"id": "c1", "text": "see `foo.py` for details", "quote": None}]
run_path = {"id": "run-path", "started_at": "2026-01-01T00:01:00Z", "repos": [],
            "brief": "", "report": "actually `foo.py` was wrong all along"}
cands2 = sd.find_chain_candidates(
    claims_path, "2026-01-01T00:00:00Z", set(), [run_path], set())
assert len(cands2) == 1 and cands2[0]["repo_match"] == "n/a", cands2
PY
[ $? -eq 0 ] && ok "#287: find_chain_candidates skips a different-repo #N occurrence, tags a same-repo one \"same\" and an ambiguous one \"ambiguous\"; a non-#N artifact is tagged \"n/a\"" \
  || bad "#287: find_chain_candidates repo tagging" "rc=nonzero"

echo; echo "X3. #287 — end to end: an ambiguous-repo-linked later_wrong is dropped (with its sole-support label); a same-repo one survives"

export MODEL_CALL_LOG="$TMP/calls-x.log"
rm -f "$MODEL_CALL_LOG"
OUT_X="$TMP/out-x.json"
run sess-287 distill --out "$OUT_X" --only agent-287cl0001 --model-cmd "$MODEL_CMD"
[ "$rc" -eq 0 ] && ok "distill sess-287 --only agent-287cl0001 exits 0" \
  || bad "distill sess-287 --only agent-287cl0001 exits 0" "rc=$rc out=$out"
"$PY" - "$OUT_X" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["records"]) == 1, d["records"]
rec = d["records"][0]

# the ambiguous-repo-linked later_wrong (contradicted_by.run=agent-287amb0001)
# is dropped; only the same-repo one (agent-287same0001) survives.
lw = rec["later_wrong"]
assert len(lw) == 1, lw
assert lw[0]["contradicted_by"]["run"] == "agent-287same0001", lw

# the classified_as entry whose SOLE support was the DROPPED later_wrong
# index (raw index 0, "recalled-not-reopened") is itself dropped entirely
# -- no pointer of its survives, same treatment #278 C2's unresolvable-
# claim drop already gets. The one supporting the SURVIVING index (raw
# index 1, "outcome-not-reason") survives, remapped to its new position.
ca = rec["classified_as"]
assert [c["label"] for c in ca] == ["outcome-not-reason"], ca
assert ca[0]["supports"] == ["0"], ca
assert rec["unclassified_reason"] is None, rec["unclassified_reason"]
PY
[ $? -eq 0 ] && ok "#287: an ambiguous-repo-only-linked later_wrong is dropped; a same-repo one survives; a classified_as entry whose sole support was the dropped index is itself dropped, the other survives remapped" \
  || bad "#287: end-to-end repo-ambiguity enforcement" "$(cat "$OUT_X")"

case "$out" in
  *"agent-287amb0001"*"repo-ambiguous-only"*) ok "#287: the drop is recorded visibly (stderr warning names the run and the reason)" ;;
  *) bad "#287: the drop is recorded visibly" "$out" ;;
esac
unset MODEL_CALL_LOG

echo; echo "X4. #287 — the chain system prompt tells the model an ambiguous candidate proves nothing alone"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_287_prompt", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
assert "ambiguous" in sd.CHAIN_SYSTEM_PROMPT, sd.CHAIN_SYSTEM_PROMPT
assert "CANNOT on its own support" in sd.CHAIN_SYSTEM_PROMPT, sd.CHAIN_SYSTEM_PROMPT
# #295: a mis-indexed claim's derived proof is a real but unrelated command
assert "`proof_located: false`" in sd.CHAIN_SYSTEM_PROMPT and "NOT evidence" in sd.CHAIN_SYSTEM_PROMPT
chain = sd.build_chain_prompt({"id": "r"}, [{"id": "c1", "text": "#99 x", "quote": None}], [
    {"run": "r2", "started_at": "t", "artifact": "#99", "excerpt": "e", "repo_match": "ambiguous"}])
assert "repo_match=ambiguous" in chain, chain
PY
[ $? -eq 0 ] && ok "#287: CHAIN_SYSTEM_PROMPT states an ambiguous candidate cannot alone support a later_wrong/label; build_chain_prompt prints each candidate's repo_match tag" \
  || bad "#287: chain prompt repo_match wording/printing" "rc=nonzero"

echo; echo "X5. #287 — a single-repo session never tags a bare #N ambiguous"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_287_single", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
claims = [{"id": "c1", "text": "#42 is fixed", "quote": None}]
later = [{"id": "r2", "started_at": "2026-01-02", "repos": [],
          "brief": "", "report": "turns out #42 was wrong, reopened"}]
# neither side resolves a repo (no cwd under ~/Projects, no qualifier)
one = sd.find_chain_candidates(claims, "2026-01-01", set(), later, {"solo"})
assert len(one) == 1 and one[0]["repo_match"] == "same", one
two = sd.find_chain_candidates(claims, "2026-01-01", set(), later, {"solo", "other"})
assert len(two) == 1 and two[0]["repo_match"] == "ambiguous", two
PY
[ $? -eq 0 ] && ok "#287: an unresolved #N is 'same' when the session names <=1 repo, 'ambiguous' only when it names two" \
  || bad "#287: single-repo session ambiguity" "rc=nonzero"

echo; echo "X6. #287 — a label citing a withdrawn later_wrong is dropped even when it also cites a claim; the withdrawal is on the record"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_287_withdrawn", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
stub = {"id": "r1", "kind": "subagent", "tool_inputs_full": ["gh pr view 7"]}
distilled = {"asked": "a", "understood": "u", "delivered": "d", "claims": [
    {"id": "c1", "text": "#7 is fixed", "kind": "k", "proof_index": 0, "proof_snippet": "gh pr view 7", "quote": "q"},
    {"id": "c2", "text": "#8 merged", "kind": "k", "proof_index": 0, "proof_snippet": "gh pr view 7", "quote": "q"}]}
chain = {
    "later_wrong": [
        {"claim": "c1", "how": "h", "contradicted_by": {"run": "amb", "at": "t", "quote": "q"}},
        {"claim": "c2", "how": "h", "contradicted_by": {"run": "same", "at": "t", "quote": "q"}}],
    "classified_as": [
        {"label": "outcome-not-reason", "supports": ["c1", "0"], "why": "w"},
        {"label": "green-as-done", "supports": ["c2", "1"], "why": "w"}]}
cands = [{"run": "amb", "artifact": "#7", "repo_match": "ambiguous"},
         {"run": "same", "artifact": "#8", "repo_match": "same"}]
rec, dropped = sd.build_record("s", stub, distilled, chain, "t", "m", 0.0,
                               ["distill", "chain"], candidates=cands)
assert [lw["claim"] for lw in rec["later_wrong"]] == ["c2"], rec["later_wrong"]
labels = [(e["label"], e["supports"]) for e in rec["classified_as"]]
assert labels == [("green-as-done", ["c2", "0"])], labels
w = rec["later_wrong_withdrawn"]
assert len(w) == 1 and w[0]["claim"] == "c1" and w[0]["run"] == "amb" \
    and w[0]["reason"] == "repo-ambiguous-only" and w[0]["index"] == 0, w
PY
[ $? -eq 0 ] && ok "#287: a label whose supports include a withdrawn later_wrong is dropped though it also names a claim; the surviving label is remapped; later_wrong_withdrawn records the drop" \
  || bad "#287: withdrawn later_wrong label enforcement" "rc=nonzero"

echo; echo "X7. #291/#287 review — locator reads every elided piece, rejects short fabrications; ambiguity drop is per claim; cwd seeds the vocabulary"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_review", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
full = ["cd /Users/x/scratch/wt/skill-templates-frozen && bash assets/t.sh 2>&1 | tail -3",
        "git status", "npm test", "git commit -m 'wip'", "git push origin main"]
loc = lambda p: any(sd.snippet_in_input(p, f) for f in full)
# mid-command elision: the piece before the first "..." is only "cd"; every
# piece must be found, in order, in ONE input
assert loc("cd .../skill-templates-frozen && ... | tail -3")
assert not loc("cd .../skill-templates-frozen && ... | tail -2")      # altered arg
assert not loc("cd .../nowhere-else && ... | tail -3")                 # invented piece
assert not loc("tail -3 ... cd /Users")                                # out of order
# quoted whole, and a leading elision, still locate
assert loc('"npm test" -> exit 0')
assert loc("`git status`")
assert loc("... npm test")
# short fabrications locate only as a whole input
assert not loc("git"), "a 3-char fragment must not locate as a piece"
assert not loc("a")
assert sd.snippet_in_input("ls", "ls") and not sd.snippet_in_input("ls", "ls -la")

# per-claim ambiguity: run-X has an ambiguous #264 candidate backing c1 and a
# 'same' candidate backing only c2 -> c1's later_wrong is withdrawn, c2's kept
cands = [{"run": "run-X", "artifact": "#264", "repo_match": "ambiguous", "claims": ["c1"]},
         {"run": "run-X", "artifact": "auth.py", "repo_match": "n/a", "claims": ["c2"]}]
raw = [{"claim": "c1", "how": "h", "contradicted_by": {"run": "run-X", "at": "t", "quote": "q"}},
       {"claim": "c2", "how": "h", "contradicted_by": {"run": "run-X", "at": "t", "quote": "q"}}]
out, dropped, imap = sd.normalize_later_wrong(raw, {"c1", "c2"}, cands)
assert [x["claim"] for x in out] == ["c2"], out
assert dropped == [{"claim": "c1", "run": "run-X", "index": 0, "reason": "repo-ambiguous-only"}], dropped
# a claim reached only through an ambiguous candidate for ANOTHER claim is
# withdrawn too (13cee7be's c61 never mentions #264)
out, dropped, _ = sd.normalize_later_wrong(raw[:1], {"c1"}, cands[:1] and
    [{"run": "run-X", "artifact": "#264", "repo_match": "ambiguous", "claims": ["c9"]}])
assert out == [] and dropped[0]["reason"] == "repo-ambiguous-only", (out, dropped)

# find_chain_candidates records which claims an artifact came from
cl = [{"id": "c1", "text": "#42 fixed", "quote": None}, {"id": "c2", "text": "other", "quote": "#42"}]
got = sd.find_chain_candidates(cl, "t0", {"solo"}, [{"id": "r2", "started_at": "t1", "repos": ["solo"],
                               "brief": "", "report": "#42 was wrong"}], {"solo"})
assert got and got[0]["claims"] == ["c1", "c2"], got

# a cwd under Projects/<repo> seeds the vocabulary: two repos, one named only by cwd
stubs = [{"brief": "see blamechris/alpha#1", "report": "", "tool_inputs_full": [], "cwds": []},
         {"brief": "", "report": "", "tool_inputs_full": [], "cwds": ["/Users/x/Projects/beta"]}]
assert sd.build_repo_vocabulary(stubs) == {"alpha", "beta"}, sd.build_repo_vocabulary(stubs)
PY
[ $? -eq 0 ] && ok "#291/#287 review: every elided piece located in order; short fabrications rejected; quoted/leading-elision proofs locate; ambiguity drop keyed per claim; candidates carry their claims; cwd seeds the vocabulary" \
  || bad "#291/#287 review fixes" "rc=nonzero"

echo; echo "X8. #291/#287 Copilot review — an empty-string proof is checked, not treated as null; a later qualified occurrence beats an earlier ambiguous one"

"$PY" - "$SUT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sd_copilot", sys.argv[1])
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)

# "" is a proof the model supplied: unlocatable, and it counts toward the
# all-unlocatable FAILURE -- otherwise a placeholder of empty proofs passes
claims = [{"id": "c1", "text": "t", "kind": "k", "proof": "", "quote": None},
          {"id": "c2", "text": "t", "kind": "k", "proof": None, "quote": None}]
n_nonnull, n_unloc = sd.compute_proof_located(claims, ["swift test"])
assert (n_nonnull, n_unloc) == (1, 1), (n_nonnull, n_unloc)
assert claims[0]["proof_located"] is False and claims[1]["proof_located"] is None, claims
is_fail, n, u = sd.claims_all_proofs_unlocatable(
    {"claims": [{"id": "c1", "text": "t", "kind": "k", "proof": "", "quote": None}]}, ["swift test"])
assert is_fail and (n, u) == (1, 1), (is_fail, n, u)

# an early ambiguous occurrence must not shadow a later explicitly-qualified
# one in the SAME run: the candidate is "same", so nothing is withdrawn
cl = [{"id": "c1", "text": "skill-templates#264 is merged", "quote": None}]
later = [{"id": "r2", "started_at": "t1", "repos": ["Aeolus", "skill-templates"],
          "brief": "",
          "report": ("#264 turned out wrong, actually. " + "x" * 300
                     + " and skill-templates#264 was in fact reverted, wrong all along")}]
got = sd.find_chain_candidates(cl, "t0", {"skill-templates"}, later, {"Aeolus", "skill-templates"})
assert len(got) == 1 and got[0]["repo_match"] == "same", got
# with no qualified occurrence anywhere, it stays ambiguous
later[0]["report"] = "#264 turned out wrong, actually."
got = sd.find_chain_candidates(cl, "t0", {"skill-templates"}, later, {"Aeolus", "skill-templates"})
assert len(got) == 1 and got[0]["repo_match"] == "ambiguous", got
PY
[ $? -eq 0 ] && ok "#291: an empty-string proof is unlocatable and counts toward the FAILURE (only null is 'nothing to check'); #287: a later qualified #N occurrence in the same run wins over an earlier ambiguous one" \
  || bad "#291/#287 Copilot review fixes" "rc=nonzero"

# ============================================================ GROUP Y — #294: --resume prunes superseded failures
echo; echo "Y. #294 — --resume drops a failure once its run succeeds; report counts only outstanding failures"

OUT_Y="$TMP/out-y.json"
STUB_FAIL_DISTILL=agent-aaaa0001 run sess-main distill --out "$OUT_Y" --model-cmd "$MODEL_CMD"
"$PY" - "$OUT_Y" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
f = [(x["run"], x["phase"]) for x in d["failures"]]
assert ("agent-aaaa0001", "distill") in f, f
assert "agent-aaaa0001" not in {r["run"]["id"] for r in d["records"]}
PY
[ $? -eq 0 ] && ok "#294: a stubbed distill failure is recorded and leaves no record (precondition)" \
  || bad "#294: stubbed distill failure precondition" "$(cat "$OUT_Y")"

run sess-main distill --out "$OUT_Y" --resume --model-cmd "$MODEL_CMD"
"$PY" - "$OUT_Y" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = [x["run"] for x in d["failures"]]
assert "agent-aaaa0001" not in runs, d["failures"]
assert "agent-aaaa0001" in {r["run"]["id"] for r in d["records"]}
# chain-phase failures are real partials (a record with passes == ["distill"])
# and --resume never retries them -- they must survive the prune.
assert sorted(runs) == ["agent-cccc0003", "main-turn-002"], runs
PY
[ $? -eq 0 ] && ok "#294: --resume with a succeeding stub drops the run's stale distill failure, keeps chain-phase partials" \
  || bad "#294: --resume prunes the superseded failure" "$(cat "$OUT_Y")"

# A pre-fix document already carrying the stale entry: report must not count it.
"$PY" - "$OUT_Y" "$TMP/out-y-legacy.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["failures"].append({"run": "agent-aaaa0001", "phase": "distill", "error": "stale"})
json.dump(d, open(sys.argv[2], "w"))
PY
run - report --in "$TMP/out-y-legacy.json"
case "$out" in
  *"failures: 2"*) ok "#294: report counts only outstanding failures on a document with a stale distill entry" ;;
  *) bad "#294: report counts only outstanding failures" "$out" ;;
esac
OUT_YJ=$(HOME="$HOMEDIR" "$PY" "$SUT" report --in "$TMP/out-y-legacy.json" --json 2>/dev/null)
echo "$OUT_YJ" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); r=sorted(x["run"] for x in d["failures"]); assert r == ["agent-cccc0003", "main-turn-002"], r'
[ $? -eq 0 ] && ok "#294: report --json also carries only outstanding failures" \
  || bad "#294: report --json carries only outstanding failures" "$OUT_YJ"

# ...and --resume over that same pre-fix document drops the stale entry at
# load time, even though no run is re-attempted (every run already has a record).
run sess-main distill --out "$TMP/out-y-legacy.json" --resume --model-cmd "$MODEL_CMD"
"$PY" - "$TMP/out-y-legacy.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(x["run"] for x in d["failures"]) == ["agent-cccc0003", "main-turn-002"], d["failures"]
PY
[ $? -eq 0 ] && ok "#294: --resume over a pre-fix document drops its stale distill failure at load time" \
  || bad "#294: --resume load-time prune of a pre-fix document" "$(cat "$TMP/out-y-legacy.json")"

"$PY" - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("sd", "$SUT")
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
recs = [{"run": {"id": "r1"}}]
got = sd.outstanding_failures(
    [{"run": {"id": "r1"}, "phase": "distill"}, {"run": "r1", "phase": "distill"}, "junk"], recs)
assert got == [{"run": {"id": "r1"}, "phase": "distill"}, "junk"], got
PY
[ $? -eq 0 ] && ok "#294: outstanding_failures tolerates a non-string/unhashable run and non-dict entries (kept, never a crash)" \
  || bad "#294: outstanding_failures on malformed failures[] entries"

# ============================================================ #292 round pairs
echo; echo "#292. round pairs (fix -> delta)"

"$PY" - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("sd_292", "$SUT")
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
k = sd.round_key
assert k("fix:#251") == ("fix", 1, "#251")
assert k("delta2:#251") == ("delta", 2, "#251")
assert k("Fix5:Aeolus#260") == ("fix", 5, "aeolus#260")
assert k("fix2:259a") == ("fix", 2, "259a")
for no in ("Fix Aeolus 259 CI lint failure", "fixture: x", "delta:", "prefix:#1", None, 7):
    assert k(no) is None, no
PY
[ $? -eq 0 ] && ok "#292: round_key parses fix<N>/delta<N>:<target> (bare = round 1) and nothing else" \
  || bad "#292: round_key parsing"

# The 13cee7be wf_30faad6a shape: two fix:#259 and two delta:#259 in one
# workflow, interleaved -- each delta pairs with the LATEST earlier fix.
# Plus: a cross-workflow pair, a round mismatch (delta2 never pairs with a
# round-1 fix), a delta with no earlier fix, and a tie for latest.
"$PY" - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("sd_292p", "$SUT")
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
def r(i, desc, at, end="auto", wf="wf_a", repos=None):
    # A fix ends 5 minutes after it starts unless told otherwise.
    if end == "auto" and at:
        end = at[:14] + "%02d" % (int(at[14:16]) + 5) + at[16:]
    return {"id": i, "description": desc, "started_at": at, "ended_at": end,
            "spawned_by": wf, "repos": repos or []}
runs = [
    r("f1", "fix:#259", "2026-09-16T11:23:04Z"),
    r("d1", "delta:#259", "2026-09-16T11:29:03Z"),
    r("f2", "fix:#259", "2026-09-16T12:11:58Z"),
    r("d2", "delta:#259", "2026-09-16T12:39:12Z"),
    r("f3", "fix:#255", "2026-09-16T09:15:59Z"),
    r("d3", "delta:#255", "2026-09-16T09:42:43Z"),
    r("d4", "delta2:#259", "2026-09-16T13:00:00Z"),
    r("d5", "delta:#300", "2026-09-16T13:00:00Z"),
    r("f6a", "fix:#301", "2026-09-16T10:00:00Z"),
    r("f6b", "fix:#301", "2026-09-16T10:00:00Z"),
    r("d6", "delta:#301", "2026-09-16T11:00:00Z"),
    r("d7", "delta:#259", None),
    r("x", "unrelated run", "2026-09-16T10:00:00Z"),
    # a later-started fix still running when the delta starts must not win
    r("f8old", "fix:#310", "2026-09-16T10:00:00Z"),
    r("f8run", "fix:#310", "2026-09-16T11:00:00Z", end="2026-09-16T12:00:00Z"),
    r("d8", "delta:#310", "2026-09-16T11:29:00Z"),
    # only same-key fix still running -> no-finished-fix
    r("f9", "fix:#311", "2026-09-16T11:00:00Z", end=None),
    r("d9", "delta:#311", "2026-09-16T11:30:00Z"),
    # same bare key, different repo -> repo-mismatch, never a pair
    r("f10", "fix:#312", "2026-09-16T09:00:00Z", repos=["RepoA"]),
    r("d10", "delta:#312", "2026-09-16T10:00:00Z", repos=["RepoB"]),
    # same-workflow fix preferred over a LATER fix in another workflow
    r("f11own", "fix:#313", "2026-09-16T09:00:00Z", wf="wf_own"),
    r("f11other", "fix:#313", "2026-09-16T09:30:00Z", wf="wf_other"),
    r("d11", "delta:#313", "2026-09-16T10:00:00Z", wf="wf_own"),
    # ...but crossing workflows is the fallback when the own one has none
    r("f12", "fix:#314", "2026-09-16T09:00:00Z", wf="wf_x"),
    r("d12", "delta:#314", "2026-09-16T10:00:00Z", wf="wf_y"),
    # top-level ("session") runs are not a workflow: no preference among them
    r("f13s", "fix:#315", "2026-09-16T09:00:00Z", wf="session"),
    r("f13w", "fix:#315", "2026-09-16T09:30:00Z", wf="wf_z"),
    r("d13", "delta:#315", "2026-09-16T10:00:00Z", wf="session"),
]
got = sd.pair_rounds(runs)
pairs = {(p["fix"], p["delta"]) for p in got["pairs"]}
assert pairs == {("f1", "d1"), ("f2", "d2"), ("f3", "d3"), ("f8old", "d8"),
                 ("f11own", "d11"), ("f12", "d12"), ("f13w", "d13")}, got["pairs"]
un = {u["delta"]: u["reason"] for u in got["unpaired_deltas"]}
assert un == {"d4": "no-earlier-fix", "d5": "no-earlier-fix",
              "d6": "ambiguous-latest-fix", "d7": "no-started-at",
              "d9": "no-finished-fix", "d10": "repo-mismatch"}, un
PY
[ $? -eq 0 ] && ok "#292: pair_rounds pairs each delta with the latest FINISHED same-key fix, same workflow first, never across disjoint repos; two pairs under one key stay apart; unpaired and tied deltas are reported with a reason" \
  || bad "#292: pair_rounds"

"$PY" - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("sd_292c", "$SUT")
sd = importlib.util.module_from_spec(spec); spec.loader.exec_module(sd)
fix = {"id": "f1"}
delta = {"id": "d1", "started_at": "t2", "report": "line one\nthe new test cannot fail"}
pairing = {"pairs": [{"fix": "f1", "delta": "d1", "key": "r1:#9"}], "unpaired_deltas": []}
claims = [{"id": "c2"}, {"id": "c1"}]
rp = sd.round_pair_candidates(fix, claims, pairing, {"d1": delta})
assert len(rp) == 1 and rp[0]["source"] == "round-pair", rp
assert rp[0]["claims"] == ["c1", "c2"] and "cannot fail" in rp[0]["excerpt"], rp
assert sd.round_pair_candidates({"id": "other"}, claims, pairing, {"d1": delta}) == []
# repo_match is derived, never asserted: "same" needs both sides resolved and
# intersecting; an unresolved side is "n/a" (still backs, never withdrawn).
assert rp[0]["repo_match"] == "n/a", rp
same = sd.round_pair_candidates({"id": "f1", "repos": ["A", "B"]}, claims, pairing,
                                {"d1": dict(delta, repos=["B"])})
assert same[0]["repo_match"] == "same", same
half = sd.round_pair_candidates({"id": "f1", "repos": ["A"]}, claims, pairing, {"d1": delta})
assert half[0]["repo_match"] == "n/a", half
retrieved = [{"run": "d1", "repo_match": "ambiguous", "claims": ["c1"], "artifact": "#9"},
             {"run": "z", "repo_match": "same", "claims": ["c1"], "artifact": "#9", "excerpt": "e"}]
merged = sd.merge_round_pair_candidates(rp, retrieved)
assert [c["run"] for c in merged] == ["d1", "z"] and merged[0]["source"] == "round-pair", merged
# The delta's ambiguous cue hit no longer withdraws a later_wrong citing it:
lw, dropped, _ = sd.normalize_later_wrong(
    [{"claim": "c2", "how": "h", "contradicted_by": {"run": "d1", "at": "t2", "quote": "q"}}],
    {"c1", "c2"}, merged)
assert len(lw) == 1 and not dropped, (lw, dropped)
# Two deltas on one fix share ONE report budget, not one each.
big = "x" * 100000
two = {"pairs": [{"fix": "f1", "delta": "da", "key": "r1:#9"},
                 {"fix": "f1", "delta": "db", "key": "r1:#9"}], "unpaired_deltas": []}
rp2 = sd.round_pair_candidates(fix, claims, two, {"da": {"id": "da", "report": big},
                                                   "db": {"id": "db", "report": big}})
budget = sd.ROUND_PAIR_REPORT_HEAD + sd.ROUND_PAIR_REPORT_TAIL
assert len(rp2) == 2 and sum(len(c["excerpt"]) for c in rp2) <= budget + 2, [len(c["excerpt"]) for c in rp2]
prompt = sd.build_chain_prompt({"id": "f1"}, claims, merged)
assert "source=round-pair" in prompt and "  | the new test cannot fail" in prompt, prompt
PY
[ $? -eq 0 ] && ok "#292: a fix run's round-pair candidate carries the whole delta report, names every claim, supersedes a cue hit from the same run, and backs a later_wrong citing it" \
  || bad "#292: round_pair_candidates / merge / prompt"

# End to end: a fix and its delta in a workflow dir. The chain prompt for the
# fix run must carry the delta's report, and the later_wrong citing the delta
# must survive into the record. The fix's claims name no artifact the delta
# mentions near a cue word, so cue retrieval alone finds nothing.
"$PY" - "$PROJ" <<'PY'
import json, os, sys
proj = sys.argv[1]
sdir = os.path.join(proj, "sess-rp")
wf = os.path.join(sdir, "subagents", "workflows", "wf_rp")
def w(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for l in lines:
            f.write(json.dumps(l) + "\n")
def run(name, desc, phase, brief, report, t0):
    with open(os.path.join(wf, name + ".meta.json"), "w") as f:
        json.dump({"agentType": "general-purpose", "model": "sonnet",
                   "description": desc, "workflowPhase": phase}, f)
    w(os.path.join(wf, name + ".jsonl"), [
        {"type": "user", "timestamp": t0, "message": {"content": [{"type": "text", "text": brief}]}},
        {"type": "assistant", "timestamp": t0[:-3] + "59Z",
         "message": {"content": [{"type": "text", "text": report}]}},
    ])
os.makedirs(wf, exist_ok=True)
run("agent-rpfix0001", "fix:#77", "Fix", "fix the review findings on #77",
    "Added a regression test for the retry path.", "2026-09-16T10:00:00Z")
run("agent-rpdel0001", "delta:#77", "Delta", "delta-review the fix round on #77",
    "FINDING: the fix round's new retry test compares two constants and cannot fail.",
    "2026-09-16T10:30:00Z")
PY
cat > "$TMP/stub_rp.py" <<'STUBEOF'
import json, os, sys
stdin = sys.stdin.read()
run_id = pass_kind = None
for line in stdin.splitlines():
    if line.startswith("RUN_ID: "): run_id = line[8:]
    if line.startswith("SESSION_DISTILL_PASS: "): pass_kind = line[22:]
def env(doc): return {"is_error": False, "result": json.dumps(doc), "total_cost_usd": 0.001}
if pass_kind == "distill":
    doc = {"asked": "a", "understood": "a", "delivered": "a",
           "claims": [{"id": "c1", "text": "the new test pins the retry path",
                       "kind": "verification", "proof": None, "quote": "Added a regression test"}]}
elif run_id == "agent-rpfix0001":
    with open(os.environ["RP_PROMPT_OUT"], "w", encoding="utf-8") as f:
        f.write(stdin)
    doc = {"later_wrong": [{"claim": "c1", "how": "the delta found the test cannot fail",
                            "contradicted_by": {"run": "agent-rpdel0001", "at": "2026-09-16T10:30:00Z",
                                                "quote": "compares two constants and cannot fail"}}],
           "classified_as": [{"label": "green-as-done", "supports": ["0"], "why": "w"}]}
else:
    doc = {"later_wrong": [], "classified_as": []}
print(json.dumps(env(doc)))
STUBEOF

RP_PROMPT_OUT="$TMP/rp-prompt.txt" run sess-rp distill --out "$TMP/out-rp.json" --model-cmd "$PY $TMP/stub_rp.py"
"$PY" - "$TMP/out-rp.json" "$TMP/rp-prompt.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
prompt = open(sys.argv[2], encoding="utf-8").read()
assert "source=round-pair" in prompt and "cannot fail" in prompt, prompt
assert d["round_pairs"]["pairs"] == [{"fix": "agent-rpfix0001", "delta": "agent-rpdel0001", "key": "r1:#77"}], d["round_pairs"]
rec = next(r for r in d["records"] if r["run"]["id"] == "agent-rpfix0001")
assert [lw["contradicted_by"]["run"] for lw in rec["later_wrong"]] == ["agent-rpdel0001"], rec
PY
[ $? -eq 0 ] && ok "#292: distill feeds the paired delta report into the fix run's chain call, and the later_wrong citing it lands on the fix record" \
  || bad "#292: distill round-pair end to end" "rc=$rc $out"

run_stdout sess-rp runs --json
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert len(d["round_pairs"]["pairs"]) == 1 and d["round_pairs"]["unpaired_deltas"] == [], d["round_pairs"]'
[ $? -eq 0 ] && ok "#292: runs --json carries round_pairs" || bad "#292: runs --json round_pairs" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
