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
assert d["schema_version"] == 1
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
