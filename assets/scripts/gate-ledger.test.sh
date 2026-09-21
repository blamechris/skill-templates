#!/usr/bin/env bash
# Regression tests for assets/scripts/gate-ledger.py (#272, epic #266).
#
# Hermetic: a fixture registry (skill-guards.json + gates.jsonl variants), a
# handful of fixture session-distill.json documents, and fixture pr-record.py
# ledgers, all built once under a mktemp dir. The real siblings
# session-distill.py and pr-record.py are used as-is (they sit next to the
# SUT in this checkout) -- only their INPUT files are fixtures.
#
# HOME is pinned to a fake, empty directory for the WHOLE suite (S6): the
# default pr-records ledger path (pr-record.py's DEFAULT_LEDGER) resolves
# under $HOME, and the real developer machine this runs on may have a real,
# unrelated ledger at ~/Obsidian/no-it-all/ledgers/pr-records.jsonl -- every
# invocation that does not explicitly set --pr-records/$CLAUDE_PR_LEDGER
# must never be able to reach it. Section T proves this control actually
# does something (a poisoned ledger under the fake HOME's default path is
# never read unless nothing overrides it).
#
# set -uo pipefail, no -e: many cases are "the REFUSE fired and nothing more
# happened", and one failed assertion must not abort the rest of the suite.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/gate-ledger.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate-ledger-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# This suite imports the SUT's siblings (session-distill.py, pr-record.py) by
# path -- the same discipline pr-record.test.sh and session-distill.test.sh
# use to keep __pycache__/ out of the checkout.
export PYTHONDONTWRITEBYTECODE=1

unset CLAUDE_PR_LEDGER
mkdir -p "$TMP/fakehome_empty"
export HOME="$TMP/fakehome_empty"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq() {  # assert_eq NAME ACTUAL EXPECTED
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi
}
assert_contains() {  # assert_contains NAME HAYSTACK NEEDLE
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to find [$3]" ;; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) bad "$1" "did not expect to find [$3]" ;; *) ok "$1" ;; esac
}

echo "gate-ledger.test.sh"

# =========================================================================
# 1. Build every fixture once, in Python (JSON-with-embedded-JSON in a shell
#    heredoc is exactly the quoting trap pr-record.test.sh's own comment
#    warns about).
# =========================================================================
"$PY" - "$TMP" <<'PYEOF'
import json, os, sys

TMP = sys.argv[1]

def w(path, obj_or_text):
    full = os.path.join(TMP, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        if isinstance(obj_or_text, str):
            f.write(obj_or_text)
        else:
            f.write(json.dumps(obj_or_text))

def wb(path, data):
    full = os.path.join(TMP, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(data)

def guards_doc():
    return {
        "_comment": "fixture",
        "demo-skill": [
            {"label": "demo-guard-legacy", "anyOf": ["x"]},
            {"label": "demo-guard-legacy2", "anyOf": ["y"]},
            {"label": "demo-guard", "anyOf": ["z"], "gate": {
                "targets": [{"label": "green-as-done", "mode": "m"}],
                "added": {"repo": "acme/widgets", "pr": 10, "at": "2026-01-01T00:00:00Z"},
                "evidence": [{"kind": "issue", "repo": "acme/widgets", "number": 1}],
            }},
        ],
    }

# ---- baseline registries -------------------------------------------------
w("reg_base/skill-guards.json", guards_doc())                       # no gates.jsonl at all
w("reg_happy/skill-guards.json", guards_doc())
w("reg_happy/gates.jsonl", json.dumps({
    "id": "hooks/valid", "kind": "hook", "where": "some place",
    "targets": [{"label": "proxy-as-thing", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 11, "at": "2026-01-02T00:00:00Z"},
    "evidence": [{"kind": "pr", "repo": "acme/widgets", "number": 11}],
}) + "\n")

w("reg_chmod/skill-guards.json", guards_doc())
w("reg_chmod/gates.jsonl", json.dumps({
    "id": "hooks/valid", "kind": "hook",
    "targets": [{"label": "proxy-as-thing", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 12, "at": "2026-01-02T00:00:00Z"},
    "evidence": [{"kind": "pr", "repo": "acme/widgets", "number": 12}],
}) + "\n")

w("reg_garbage_line/skill-guards.json", guards_doc())
w("reg_garbage_line/gates.jsonl",
  json.dumps({
      "id": "hooks/ok", "kind": "hook",
      "targets": [{"label": "proxy-as-thing", "mode": "m"}],
      "added": {"repo": "acme/widgets", "pr": 13, "at": "2026-01-02T00:00:00Z"},
      "evidence": [{"kind": "pr", "repo": "acme/widgets", "number": 13}],
  }) + "\n" + "{not json at all\n")

w("reg_nonobj_line/skill-guards.json", guards_doc())
w("reg_nonobj_line/gates.jsonl", "[1, 2, 3]\n")

os.makedirs(os.path.join(TMP, "reg_missing_guards"), exist_ok=True)

w("reg_guards_chmod/skill-guards.json", guards_doc())

# ---- D1..D12 check-rejection fixtures -------------------------------------
def valid_line(**overrides):
    d = {
        "id": "hooks/d", "kind": "hook",
        "targets": [{"label": "proxy-as-thing", "mode": "m"}],
        "added": {"repo": "acme/widgets", "pr": 99, "at": "2026-01-02T00:00:00Z"},
        "evidence": [{"kind": "pr", "repo": "acme/widgets", "number": 99}],
    }
    d.update(overrides)
    return d

d_cases = {
    "d1_label_outside_vocab": valid_line(targets=[{"label": "bogus-label", "mode": "m"}]),
    "d2_unclassified_no_mode": valid_line(targets=[{"label": "unclassified"}]),
    "d3_empty_evidence": valid_line(evidence=[]),
    "d4_evidence_missing_field": valid_line(evidence=[{"kind": "distill", "session": "s1"}]),
    "d5_added_at_not_full_utc": valid_line(added={"repo": "acme/widgets", "pr": 99, "at": "2026-01-02"}),
    "d6_non_integer_pr": valid_line(added={"repo": "acme/widgets", "pr": "99", "at": "2026-01-02T00:00:00Z"}),
    "d8_gates_jsonl_kind_skill_guard": valid_line(kind="skill-guard"),
    "d10_missing_repo": valid_line(added={"pr": 99, "at": "2026-01-02T00:00:00Z"}),
    "d11_repo_not_owner_slash_name": valid_line(added={"repo": "acme", "pr": 99, "at": "2026-01-02T00:00:00Z"}),
    "d12_schema_version_not_1": valid_line(schema_version=2),
    "d13_added_at_naive": valid_line(added={"repo": "acme/widgets", "pr": 99, "at": "2026-01-02T00:00:00"}),
}
for name, obj in d_cases.items():
    w(f"reg_{name}/skill-guards.json", guards_doc())
    w(f"reg_{name}/gates.jsonl", json.dumps(obj) + "\n")

# D7: duplicate id -- reuses the skill-guard's own derived id "demo-skill/demo-guard"
w("reg_d7_duplicate_id/skill-guards.json", guards_doc())
w("reg_d7_duplicate_id/gates.jsonl", json.dumps(valid_line(id="demo-skill/demo-guard")) + "\n")

# D9: unknown top-level key (typo'd "evidence" -> "evidnce")
d9 = valid_line()
del d9["evidence"]
d9["evidnce"] = [{"kind": "pr", "repo": "acme/widgets", "number": 99}]
w("reg_d9_unknown_key/skill-guards.json", guards_doc())
w("reg_d9_unknown_key/gates.jsonl", json.dumps(d9) + "\n")

# A guard-embedded gate with an unknown key too (id/kind excluded there, so a
# stray "id" key on the embedded object is itself an unknown key).
guards_bad_key = guards_doc()
guards_bad_key["demo-skill"][2]["gate"]["id"] = "should-not-be-here"
w("reg_guard_unknown_key/skill-guards.json", guards_bad_key)

# Nitpick: "gate": null is invalid, NOT legacy (the key is present).
guards_null_gate = guards_doc()
guards_null_gate["demo-skill"].append({"label": "demo-guard-null", "anyOf": ["q"], "gate": None})
w("reg_gate_null/skill-guards.json", guards_null_gate)

# =========================================================================
# report fixtures: gates + distill docs
# =========================================================================

def dist_doc(session, records, **kw):
    d = {"kind": "session-distill-document", "schema_version": 1, "session": session, "records": records}
    d.update(kw)
    return d

def rec(run_id, started_at, classified_as, **kw):
    r = {"run": {"id": run_id, "kind": "subagent", "started_at": started_at},
         "classified_as": classified_as,
         "distilled": {"passes": ["distill", "chain"]}}
    r.update(kw)
    return r

# G1 untraced -- only asserted (issue/pr) evidence
g1 = {
    "id": "hooks/g1", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 31, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "issue", "repo": "acme/widgets", "number": 31},
                 {"kind": "pr", "repo": "acme/widgets", "number": 31}],
}
# G2 evidence-unverified -- distill evidence naming a run no loaded file carries
g2 = {
    "id": "hooks/g2", "kind": "hook",
    "targets": [{"label": "proxy-as-thing", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 32, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "sess-A", "run": "run-A1"}],
}
# G3 mislabelled -- the #263/#264 shape: targets a label the trace does not carry
g3 = {
    "id": "hooks/g3", "kind": "hook",
    "targets": [{"label": "proxy-as-thing", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 33, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "sess-C", "run": "run-C1"}],
}
# G3b mislabelled via claim-scoped mismatch -- label matches, claim does not
g3b = {
    "id": "hooks/g3b", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 34, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "sess-D", "run": "run-D1", "claim": "c1"}],
}
# G4 not-joinable + trace-unverified -- all targets unclassified, trace evidence
g4 = {
    "id": "hooks/g4", "kind": "hook",
    "targets": [{"label": "unclassified", "mode": "a sensor defect, not a checklist mode"}],
    "added": {"repo": "acme/widgets", "pr": 35, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "sess-E", "run": "run-E1", "at": "2026-01-05T00:00:00Z"}],
}

w("reg_g1234/skill-guards.json", guards_doc())
w("reg_g1234/gates.jsonl", "\n".join(json.dumps(x) for x in (g1, g2, g3, g3b, g4)) + "\n")

w("reg_g12/skill-guards.json", guards_doc())
w("reg_g12/gates.jsonl", "\n".join(json.dumps(x) for x in (g1, g2)) + "\n")

w("distill/sess-C.json", dist_doc("sess-C", [
    rec("run-C1", "2025-12-01T00:00:00Z", [{"label": "absence-without-second-search", "supports": ["c1"]}]),
]))
w("distill/sess-D.json", dist_doc("sess-D", [
    rec("run-D1", "2025-12-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c2"]}]),
]))

# G5 unobserved (--min-sessions 2, only 1 distinct after-session)
g5 = {
    "id": "hooks/g5", "kind": "hook",
    "targets": [{"label": "consumers-unfound", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 36, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "sess-F", "run": "run-F1", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_g5/skill-guards.json", guards_doc())
w("reg_g5/gates.jsonl", json.dumps(g5) + "\n")
w("distill/sess-G-only.json", dist_doc("sess-G", [rec("run-G1", "2026-02-01T00:00:00Z", [])]))

# G6 recurring (--min-sessions 2, 2 after-sessions, one carries the label)
g6 = {
    "id": "hooks/g6", "kind": "hook",
    "targets": [{"label": "consumers-unfound", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 37, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "sess-H", "run": "run-H1", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_g6/skill-guards.json", guards_doc())
w("reg_g6/gates.jsonl", json.dumps(g6) + "\n")
w("distill/sess-I.json", dist_doc("sess-I", [
    rec("run-I1", "2026-02-01T00:00:00Z", [{"label": "consumers-unfound", "supports": ["c1"]}]),
]))
w("distill/sess-J.json", dist_doc("sess-J", [rec("run-J1", "2026-02-02T00:00:00Z", [])]))

# G7 suspect (--min-sessions 2, 2 after-sessions, label never observed at all)
g7 = {
    "id": "hooks/g7", "kind": "hook",
    "targets": [{"label": "letter-not-goal", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 38, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "sess-K", "run": "run-K1", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_g7/skill-guards.json", guards_doc())
w("reg_g7/gates.jsonl", json.dumps(g7) + "\n")
w("distill/sess-L.json", dist_doc("sess-L", [
    rec("run-L1", "2026-02-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))
w("distill/sess-M.json", dist_doc("sess-M", [rec("run-M1", "2026-02-02T00:00:00Z", [])]))

# G8 quiet (--min-sessions 2, 2 after-sessions no recurrence, label seen BEFORE the gate)
g8 = {
    "id": "hooks/g8", "kind": "hook",
    "targets": [{"label": "outcome-not-reason", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 39, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "sess-N", "run": "run-N1", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_g8/skill-guards.json", guards_doc())
w("reg_g8/gates.jsonl", json.dumps(g8) + "\n")
w("distill/sess-O.json", dist_doc("sess-O", [
    rec("run-O1", "2025-11-01T00:00:00Z", [{"label": "outcome-not-reason", "supports": ["c1"]}]),
]))
w("distill/sess-P.json", dist_doc("sess-P", [rec("run-P1", "2026-02-01T00:00:00Z", [])]))
w("distill/sess-Q.json", dist_doc("sess-Q", [rec("run-Q1", "2026-02-02T00:00:00Z", [])]))

# exit-2 --distill fixtures
w("distill/wrong-kind.json", {"kind": "not-a-session-distill-document"})
w("distill/garbage.json", "{not json\n")
w("distill/records-not-list.json", {"kind": "session-distill-document", "session": "X", "records": {"R": {}}})

# pr-records ledger fixture: found for pr 31 (G1), nothing for pr 35 (G4)
w("pr-records.jsonl", json.dumps({
    "kind": "pr-record", "schema_version": 1, "repo": "acme/widgets", "pr": 31,
    "recorded_at": "2026-01-03T00:00:00Z",
}) + "\n")

# =========================================================================
# K. report: `invalid` verdict -- a malformed record is scored, never crashes
# =========================================================================
w("reg_invalid/skill-guards.json", guards_doc())
w("reg_invalid/gates.jsonl", "\n".join(json.dumps(x) for x in (
    {  # r8-shape: bad label, empty added, wrong-case evidence kind
        "id": "hooks/bad1", "kind": "hook",
        "targets": [{"label": "bogus", "mode": "m"}],
        "added": {},
        "evidence": [{"kind": "Distill", "session": "S", "run": "R"}],
    },
    {  # r9-shape: added missing repo/pr, bad schema_version -- still valid otherwise
        "id": "hooks/bad2", "kind": "hook",
        "targets": [{"label": "green-as-done", "mode": "m"}],
        "added": {"at": "2026-01-01T00:00:00Z"},
        "evidence": [{"kind": "issue", "repo": "acme/widgets", "number": 1}],
        "schema_version": 99,
    },
    {  # a perfectly good record alongside the bad ones -- report must still process it
        "id": "hooks/ok3", "kind": "hook",
        "targets": [{"label": "green-as-done", "mode": "m"}],
        "added": {"repo": "acme/widgets", "pr": 40, "at": "2026-01-01T00:00:00Z"},
        "evidence": [{"kind": "issue", "repo": "acme/widgets", "number": 40}],
    },
)) + "\n")

# =========================================================================
# L. report: `incomplete` verdict
# =========================================================================
# L1: doc-level stopped + unreadable -- a trace-evidence gate unrelated to
# either doc's own sessions must still read incomplete, never suspect.
g_l1 = {
    "id": "hooks/g-l1", "kind": "hook",
    "targets": [{"label": "letter-not-goal", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 41, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_L1/skill-guards.json", guards_doc())
w("reg_L1/gates.jsonl", json.dumps(g_l1) + "\n")
w("distill/L1-stopped.json", dist_doc(
    "A", [rec("A1", "2026-02-01T00:00:00Z", [])],
    runs_total=160, runs_selected=160, stopped={"reason": "max-cost-usd", "at_run": "A2"}))
w("distill/L1-unreadable.json", dist_doc(
    "B", [rec("B1", "2026-02-01T00:00:00Z", [])],
    unreadable=["main transcript x (EACCES)"]))

# L2: a label-carrying run with started_at null -> incomplete (missing timestamp)
g_l2 = {
    "id": "hooks/g-l2", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 42, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_L2/skill-guards.json", guards_doc())
w("reg_L2/gates.jsonl", json.dumps(g_l2) + "\n")
w("distill/L2-a.json", dist_doc("A", [
    rec("A1", "2025-11-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))
w("distill/L2-b.json", dist_doc("B", [
    {"run": {"id": "B1", "kind": "subagent", "started_at": None},
     "classified_as": [{"label": "green-as-done", "supports": ["c1"]}],
     "distilled": {"passes": ["distill", "chain"]}},
    rec("B2", "2026-02-01T00:00:00Z", []),
]))
w("distill/L2-c.json", dist_doc("C", [rec("C1", "2026-02-02T00:00:00Z", [])]))

# L3: a label-carrying run with NO run.id -> incomplete (missing run.id)
g_l3 = dict(g_l2); g_l3["id"] = "hooks/g-l3"; g_l3["added"] = dict(g_l2["added"], pr=43)
w("reg_L3/skill-guards.json", guards_doc())
w("reg_L3/gates.jsonl", json.dumps(g_l3) + "\n")
w("distill/L3-b.json", dist_doc("B", [
    {"run": {"started_at": "2026-02-01T00:00:00Z"},
     "classified_as": [{"label": "green-as-done", "supports": ["c1"]}],
     "distilled": {"passes": ["distill", "chain"]}},
]))

# L4: recurring survives incompleteness elsewhere -- a CLEAN recurring run in
# one doc, a stopped/incomplete doc alongside it -- verdict must be
# `recurring`, never `incomplete`.
g_l4 = {
    "id": "hooks/g-l4", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 44, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_L4/skill-guards.json", guards_doc())
w("reg_L4/gates.jsonl", json.dumps(g_l4) + "\n")
w("distill/L4-clean.json", dist_doc("CLEAN", [
    rec("CLEAN1", "2026-02-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))
w("distill/L4-stopped.json", dist_doc(
    "STOPPED", [rec("S1", "2026-02-01T00:00:00Z", [])],
    stopped={"reason": "max-cost-usd", "at_run": "S2"}))

# =========================================================================
# M. report: C1 -- distill evidence whose chain pass never ran, or whose run
#    is named in failures[], is NOT a loaded classification
# =========================================================================
g_m1 = {
    "id": "hooks/g-m1", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 45, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "S1", "run": "R1"}],
}
w("reg_M1/skill-guards.json", guards_doc())
w("reg_M1/gates.jsonl", json.dumps(g_m1) + "\n")
# chain pass never ran (passes == ["distill"] only) AND the run is named in
# failures[] -- classified_as is empty, which an old, naive join would read
# straight through as "mislabelled" (no matching label) instead of
# "evidence-unverified" (not loaded at all).
w("distill/M1.json", dist_doc("S1", [
    {"run": {"id": "R1", "kind": "subagent", "started_at": "2025-12-01T00:00:00Z"},
     "classified_as": [], "distilled": {"passes": ["distill"]}},
], failures=[{"run": "R1", "phase": "chain", "error": "timeout"}]))

# =========================================================================
# N. report: C4/C5 join/session/timing fixtures
# =========================================================================
# N1: same run id under two different sessions -- the join must use session,
# not run id alone.
g_n1 = {
    "id": "hooks/g-n1", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 46, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "SX", "run": "RID"}],
}
w("reg_N1/skill-guards.json", guards_doc())
w("reg_N1/gates.jsonl", json.dumps(g_n1) + "\n")
w("distill/N1-sx.json", dist_doc("SX", [
    rec("RID", "2026-02-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))
w("distill/N1-sy.json", dist_doc("SY", [
    rec("RID", "2026-02-01T00:00:00Z", []),
]))

# N2: same PR number under two repos -- the pr join must use repo, not pr
# alone.
g_n2a = {
    "id": "hooks/g-n2a", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "repoA/x", "pr": 50, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "issue", "repo": "repoA/x", "number": 50}],
}
g_n2b = {
    "id": "hooks/g-n2b", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "repoC/z", "pr": 50, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "issue", "repo": "repoC/z", "number": 50}],
}
w("reg_N2/skill-guards.json", guards_doc())
w("reg_N2/gates.jsonl", "\n".join(json.dumps(x) for x in (g_n2a, g_n2b)) + "\n")
w("pr-records-n2.jsonl", "\n".join(json.dumps(x) for x in (
    {"kind": "pr-record", "repo": "repoA/x", "pr": 50},
    {"kind": "pr-record", "repo": "repoB/y", "pr": 50},
)) + "\n")

# N3: a run before added.at is not counted as a session-after.
g_n3 = {
    "id": "hooks/g-n3", "kind": "hook",
    "targets": [{"label": "consumers-unfound", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 51, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_N3/skill-guards.json", guards_doc())
w("reg_N3/gates.jsonl", json.dumps(g_n3) + "\n")
w("distill/N3-before.json", dist_doc("A", [rec("A1", "2025-11-01T00:00:00Z", [])]))

# N4: sessions are counted by distinct SESSION, not run -- two runs, one
# session, both after the gate.
g_n4 = dict(g_n3); g_n4["id"] = "hooks/g-n4"; g_n4["added"] = dict(g_n3["added"], pr=52)
w("reg_N4/skill-guards.json", guards_doc())
w("reg_N4/gates.jsonl", json.dumps(g_n4) + "\n")
w("distill/N4.json", dist_doc("A", [
    rec("A1", "2026-02-01T00:00:00Z", []),
    rec("A2", "2026-02-02T00:00:00Z", []),
]))

# N5: mislabelled must NOT fire when only SOME distill evidence resolves --
# the whole gate reads evidence-unverified.
g_n5 = {
    "id": "hooks/g-n5", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 53, "at": "2026-01-01T00:00:00Z"},
    "evidence": [
        {"kind": "distill", "session": "sess-D", "run": "run-D1"},   # resolves, WRONG label
        {"kind": "distill", "session": "sess-Z", "run": "run-Z1"},   # never loaded
    ],
}
w("reg_N5/skill-guards.json", guards_doc())
w("reg_N5/gates.jsonl", json.dumps(g_n5) + "\n")

# N6: a run starting EXACTLY at added.at is not a recurrence (strict >).
g_n6 = {
    "id": "hooks/g-n6", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 54, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_N6/skill-guards.json", guards_doc())
w("reg_N6/gates.jsonl", json.dumps(g_n6) + "\n")
w("distill/N6-exact.json", dist_doc("A", [
    rec("A1", "2026-01-01T00:00:00Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))

# =========================================================================
# O. report: S1 -- timestamp parsing (fractional/offset valid, naive invalid)
# =========================================================================
g_o = {
    "id": "hooks/g-o", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 55, "at": "2026-01-01T12:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_O/skill-guards.json", guards_doc())
w("reg_O/gates.jsonl", json.dumps(g_o) + "\n")
w("distill/O-a.json", dist_doc("A", [
    rec("A1", "2026-01-01T12:00:00.500Z", [{"label": "green-as-done", "supports": ["c1"]}]),
]))
w("distill/O-b.json", dist_doc("B", [rec("B1", "2026-01-01 13:00:00", [])]))       # naive, no label
w("distill/O-c.json", dist_doc("C", [rec("C1", "2026-01-01T13:00:00+00:00", [])]))  # explicit offset, no label

# =========================================================================
# S. S5 -- non-UTF-8 input
# =========================================================================
w("reg_s5/skill-guards.json", guards_doc())
os.makedirs(os.path.join(TMP, "reg_s5"), exist_ok=True)
wb("reg_s5/gates.jsonl", b'{"id": "hooks/\xff\xfe", "kind": "hook"}\n')
wb("distill/s5-garbage-utf8.json", b'\xff\xfe{"kind": "session-distill-document"}')
w("s5-guards-only/skill-guards.json", guards_doc())
wb("s5-guards-only/gates.jsonl", b'')  # empty is fine, unrelated control
wb("s5-guards-bad.json", b'')
# non-UTF-8 skill-guards.json
os.makedirs(os.path.join(TMP, "reg_s5_guards"), exist_ok=True)
wb("reg_s5_guards/skill-guards.json", b'{"_comment": "\xff\xfe"}')
# non-UTF-8 pr-records ledger
wb("pr-records-badutf8.jsonl", b'{"kind": "pr-record", "repo": "a/b", "pr": 1, "x": "\xff\xfe"}\n')

# =========================================================================
# R. S4 -- pr ledger: garbage line -> exit 2; non-pr-record kind is ignored
# =========================================================================
w("pr-records-garbage.jsonl", '{"kind": "pr-record", "repo": "a/b", "pr": 1, TRUNCATED\nnot json at all\n')
w("pr-records-other-kind.jsonl", json.dumps({"kind": "something-else", "repo": "acme/widgets", "pr": 31}) + "\n")

# =========================================================================
# T. S6 -- HOME/$CLAUDE_PR_LEDGER hermeticity proof
# =========================================================================
# A "poisoned" ledger at the DEFAULT resolved path under a fake HOME.
wb("fakehome_poisoned/Obsidian/no-it-all/ledgers/pr-records.jsonl", b"not json at all\n")
os.makedirs(os.path.join(TMP, "fakehome_poisoned_empty"), exist_ok=True)  # no Obsidian dir at all

# =========================================================================
# U. S7 -- record-level session fallback; records-not-a-list
# =========================================================================
g_u1 = {
    "id": "hooks/g-u1", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 60, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "distill", "session": "A", "run": "A1"}],
}
w("reg_U1/skill-guards.json", guards_doc())
w("reg_U1/gates.jsonl", json.dumps(g_u1) + "\n")
# doc-level session is null; the RECORD carries its own "session" -- the
# real session-distill-record schema puts "session" on every record, not
# only on the document.
w("distill/U1.json", {
    "kind": "session-distill-document", "schema_version": 1, "session": None,
    "records": [{
        "session": "A",
        "run": {"id": "A1", "kind": "subagent", "started_at": "2025-12-01T00:00:00Z"},
        "classified_as": [{"label": "green-as-done", "supports": ["c1"]}],
        "distilled": {"passes": ["distill", "chain"]},
    }],
})

# U2: neither doc.session nor record.session present, but the run carries a
# target label -> incomplete.
g_u2 = {
    "id": "hooks/g-u2", "kind": "hook",
    "targets": [{"label": "green-as-done", "mode": "m"}],
    "added": {"repo": "acme/widgets", "pr": 61, "at": "2026-01-01T00:00:00Z"},
    "evidence": [{"kind": "trace", "session": "s", "run": "r", "at": "2026-01-05T00:00:00Z"}],
}
w("reg_U2/skill-guards.json", guards_doc())
w("reg_U2/gates.jsonl", json.dumps(g_u2) + "\n")
w("distill/U2.json", {
    "kind": "session-distill-document", "schema_version": 1, "session": None,
    "records": [{
        "run": {"id": "Z1", "kind": "subagent", "started_at": "2025-12-01T00:00:00Z"},
        "classified_as": [{"label": "green-as-done", "supports": ["c1"]}],
        "distilled": {"passes": ["distill", "chain"]},
    }],
})

# =========================================================================
# W. nitpick -- duplicate (session, run) across two --distill files
# =========================================================================
w("distill/dup-a.json", dist_doc("DUP", [rec("R1", "2026-02-01T00:00:00Z", [])]))
w("distill/dup-b.json", dist_doc("DUP", [rec("R1", "2026-02-02T00:00:00Z", [])]))

print("fixtures written")
PYEOF

if [ $? -ne 0 ]; then
  echo "fixture generation failed" >&2
  exit 1
fi

run() { "$PY" "$SUT" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

# =========================================================================
# A. schema
# =========================================================================
echo; echo "A. schema"
rc=$(run schema)
assert_eq "schema exits 0" "$rc" "0"
out=$(cat "$TMP/out")
assert_contains "schema lists the 9 labels" "$out" "\"unclassified\""
assert_contains "schema lists green-as-done" "$out" "\"green-as-done\""
assert_contains "schema lists all verdicts incl. invalid/incomplete" "$out" "\"incomplete\""
assert_contains "schema lists invalid first" "$out" "\"invalid\""
"$PY" -c "import json,sys; json.load(open('$TMP/out'))" && ok "schema output is valid JSON" || bad "schema output is valid JSON"

# =========================================================================
# B. check -- happy path
# =========================================================================
echo; echo "B. check: happy path"
rc=$(run check --registry "$TMP/reg_happy")
assert_eq "happy registry: exit 0" "$rc" "0"
assert_contains "happy registry: invalid 0" "$(cat "$TMP/out")" "invalid: 0"
assert_contains "happy registry: counts both sources" "$(cat "$TMP/out")" "1 skill-guard, 1 gates.jsonl"
assert_contains "happy registry: legacy guards counted, not failed" "$(cat "$TMP/out")" "legacy guards without a gate field: 2"

# =========================================================================
# C. absent vs broken gates.jsonl -- must never read the same (#278-style)
# =========================================================================
echo; echo "C. absent vs broken gates.jsonl"
rc=$(run check --registry "$TMP/reg_base")
assert_eq "absent gates.jsonl: exit 0" "$rc" "0"
absent_out=$(cat "$TMP/out")
assert_contains "absent gates.jsonl: 0 gates.jsonl records" "$absent_out" "0 gates.jsonl"

chmod 000 "$TMP/reg_chmod/gates.jsonl"
rc=$(run check --registry "$TMP/reg_chmod")
assert_eq "chmod-000 gates.jsonl: exit 2" "$rc" "2"
chmod_err=$(cat "$TMP/err")
assert_contains "chmod-000 gates.jsonl: REFUSE names the path" "$chmod_err" "reg_chmod/gates.jsonl"
assert_not_contains "chmod-000 output is not the absent-file output" "$(cat "$TMP/out")" "0 gates.jsonl"
chmod 644 "$TMP/reg_chmod/gates.jsonl" 2>/dev/null || true

rc=$(run check --registry "$TMP/reg_garbage_line")
assert_eq "garbage jsonl line: exit 2" "$rc" "2"
assert_contains "garbage jsonl line: names file and line 2" "$(cat "$TMP/err")" "gates.jsonl:2"

rc=$(run check --registry "$TMP/reg_nonobj_line")
assert_eq "non-object jsonl line: exit 2" "$rc" "2"
assert_contains "non-object jsonl line: names file and line" "$(cat "$TMP/err")" "gates.jsonl:1"

# =========================================================================
# D. check rejections, one per case
# =========================================================================
echo; echo "D. check rejections"
check_rejects() {  # check_rejects NAME REGDIR NEEDLE
  rc=$(run check --registry "$2")
  if [ "$rc" != "1" ]; then bad "$1: exit 1" "got exit $rc"; return; fi
  ok "$1: exit 1"
  assert_contains "$1: reason mentions expected text" "$(cat "$TMP/out")" "$3"
}
check_rejects "D1 label outside vocabulary" "$TMP/reg_d1_label_outside_vocab" "outside the vocabulary"
check_rejects "D2 unclassified with no mode" "$TMP/reg_d2_unclassified_no_mode" "unclassified with no non-empty mode"
check_rejects "D3 empty evidence" "$TMP/reg_d3_empty_evidence" "evidence must be non-empty"
check_rejects "D4 evidence missing required field" "$TMP/reg_d4_evidence_missing_field" "missing \`run\`"
check_rejects "D5 added.at not full UTC" "$TMP/reg_d5_added_at_not_full_utc" "not a full UTC timestamp"
check_rejects "D6 non-integer pr" "$TMP/reg_d6_non_integer_pr" "added.pr must be an integer"
check_rejects "D7 duplicate id across sources" "$TMP/reg_d7_duplicate_id" "duplicate id"
check_rejects "D8 gates.jsonl kind skill-guard" "$TMP/reg_d8_gates_jsonl_kind_skill_guard" "belongs on the guard"
check_rejects "D9 unknown top-level key" "$TMP/reg_d9_unknown_key" "unknown top-level key"
check_rejects "guard-embedded gate with unknown key (id)" "$TMP/reg_guard_unknown_key" "unknown top-level key"
check_rejects "D10 (S2) missing added.repo" "$TMP/reg_d10_missing_repo" "added.repo must be an OWNER/NAME string"
check_rejects "D11 (S2) added.repo not owner/name" "$TMP/reg_d11_repo_not_owner_slash_name" "added.repo must be an OWNER/NAME string"
check_rejects "D12 (S2) schema_version != 1" "$TMP/reg_d12_schema_version_not_1" "schema_version must be 1"
check_rejects "D13 (S1) added.at naive timestamp" "$TMP/reg_d13_added_at_naive" "not a full UTC timestamp"
check_rejects "nitpick: gate: null is invalid, not legacy" "$TMP/reg_gate_null" "gate value is not a JSON object"

rc=$(run check --registry "$TMP/reg_gate_null")
assert_contains "gate: null counted among records, not legacy" "$(cat "$TMP/out")" "records: 2 (2 skill-guard, 0 gates.jsonl)"

# =========================================================================
# E. list
# =========================================================================
echo; echo "E. list"
rc=$(run list --registry "$TMP/reg_happy")
assert_eq "list: exit 0" "$rc" "0"
assert_contains "list: shows the skill-guard id" "$(cat "$TMP/out")" "demo-skill/demo-guard"
assert_contains "list: shows the gates.jsonl id" "$(cat "$TMP/out")" "hooks/valid"

rc=$(run list --registry "$TMP/reg_happy" --json)
assert_eq "list --json: exit 0" "$rc" "0"
"$PY" -c "
import json
d = json.load(open('$TMP/out'))
assert isinstance(d, list) and len(d) == 2, d
ids = sorted(x['id'] for x in d)
assert ids == ['demo-skill/demo-guard', 'hooks/valid'], ids
" && ok "list --json: exactly the 2 gate records, correct ids" || bad "list --json: exactly the 2 gate records, correct ids"

# =========================================================================
# F. report -- untraced / evidence-unverified / mislabelled / not-joinable
# =========================================================================
echo; echo "F. report: verdicts (combined registry)"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_g1234" \
    --distill "$TMP/distill/sess-C.json" --distill "$TMP/distill/sess-D.json" \
    >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "combined report: exit 0" "$rc" "0"
g1_line=$(grep 'hooks/g1 ' "$TMP/out" || true)
g2_line=$(grep 'hooks/g2 ' "$TMP/out" || true)
g3_line=$(grep 'hooks/g3 ' "$TMP/out" || true)
g3b_line=$(grep 'hooks/g3b ' "$TMP/out" || true)
g4_line=$(grep 'hooks/g4 ' "$TMP/out" || true)
assert_contains "G1 untraced" "$g1_line" "untraced"
assert_contains "G2 evidence-unverified (run not in loaded files)" "$g2_line" "evidence-unverified"
assert_contains "G3 mislabelled (#263/#264 shape: label mismatch)" "$g3_line" "mislabelled"
assert_contains "G3b mislabelled (claim-scoped: label matches, claim does not)" "$g3b_line" "mislabelled"
assert_contains "G4 not-joinable (all targets unclassified)" "$g4_line" "not-joinable"
assert_contains "G4 also carries trace-unverified" "$g4_line" "trace-unverified"
assert_not_contains "G1 (no trace evidence) is not marked trace-unverified" "$g1_line" "trace-unverified"

# --distill is optional: zero files given is legal, and a distill-evidence
# gate then reads evidence-unverified, never a silent pass.
rc=$("$PY" "$SUT" report --registry "$TMP/reg_g12" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "report with zero --distill files: exit 0" "$rc" "0"
assert_contains "zero-file report: G1 still untraced" "$(grep 'hooks/g1 ' "$TMP/out" || true)" "untraced"
assert_contains "zero-file report: G2 evidence-unverified (nothing loaded)" "$(grep 'hooks/g2 ' "$TMP/out" || true)" "evidence-unverified"

# =========================================================================
# G. report -- recurrence verdicts, each in its own scoped invocation (the
#    "distinct sessions after added.at" count is GLOBAL to one invocation's
#    --distill set, so these must not share a report call)
# =========================================================================
echo; echo "G. report: recurrence verdicts"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_g5" --distill "$TMP/distill/sess-G-only.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "G5 unobserved: exit 0" "$rc" "0"
assert_contains "G5 unobserved (1 after-session < min-sessions 2)" "$(cat "$TMP/out")" "unobserved"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_g6" --distill "$TMP/distill/sess-I.json" --distill "$TMP/distill/sess-J.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "G6 recurring: exit 0" "$rc" "0"
g6out=$(cat "$TMP/out")
assert_contains "G6 recurring (label seen in an after-gate run)" "$g6out" "recurring"
assert_contains "G6 recurring lists the run id" "$g6out" "run-I1"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_g7" --distill "$TMP/distill/sess-L.json" --distill "$TMP/distill/sess-M.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "G7 suspect: exit 0" "$rc" "0"
assert_contains "G7 suspect (label never observed anywhere)" "$(cat "$TMP/out")" "suspect"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_g8" --distill "$TMP/distill/sess-O.json" --distill "$TMP/distill/sess-P.json" --distill "$TMP/distill/sess-Q.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "G8 quiet: exit 0" "$rc" "0"
assert_contains "G8 quiet (label observed only before the gate)" "$(cat "$TMP/out")" "quiet"

# =========================================================================
# H. report -- pr_record join: found / missing / no-ledger
# =========================================================================
echo; echo "H. report: pr_record join"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_g1234" --pr-records "$TMP/pr-records.jsonl" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "explicit --pr-records: exit 0" "$rc" "0"
assert_contains "pr_record found (G1, pr 31, in the ledger)" "$(grep 'hooks/g1 ' "$TMP/out" || true)" "pr_record=found"
assert_contains "pr_record missing (G4, pr 35, not in the ledger)" "$(grep 'hooks/g4 ' "$TMP/out" || true)" "pr_record=missing"

CLAUDE_PR_LEDGER="$TMP/pr-records.jsonl" "$PY" "$SUT" report --registry "$TMP/reg_g1234" >"$TMP/out" 2>"$TMP/err"; rc=$?
assert_eq "\$CLAUDE_PR_LEDGER precedence reused from pr-record.py: exit 0" "$rc" "0"
assert_contains "\$CLAUDE_PR_LEDGER honored: pr_record found" "$(grep 'hooks/g1 ' "$TMP/out" || true)" "pr_record=found"

CLAUDE_PR_LEDGER="$TMP/no-such-ledger.jsonl" "$PY" "$SUT" report --registry "$TMP/reg_g1234" >"$TMP/out" 2>"$TMP/err"; rc=$?
assert_eq "default ledger absent: exit 0" "$rc" "0"
assert_contains "default ledger absent -> no-ledger, every gate" "$(cat "$TMP/out")" "pr_record=no-ledger"

# =========================================================================
# I. exit-2 paths
# =========================================================================
echo; echo "I. exit-2 paths"
rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/does-not-exist.json")
assert_eq "--distill missing file: exit 2" "$rc" "2"
assert_contains "--distill missing file: names the path" "$(cat "$TMP/err")" "does-not-exist.json"

rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/garbage.json")
assert_eq "--distill garbage JSON: exit 2" "$rc" "2"
assert_contains "--distill garbage JSON: names the path" "$(cat "$TMP/err")" "garbage.json"

rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/wrong-kind.json")
assert_eq "--distill wrong kind: exit 2" "$rc" "2"
assert_contains "--distill wrong kind: names the path" "$(cat "$TMP/err")" "wrong-kind.json"

rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/records-not-list.json")
assert_eq "--distill records not a list: exit 2 (S7)" "$rc" "2"
assert_contains "--distill records not a list: names the path" "$(cat "$TMP/err")" "records-not-list.json"

rc=$(run report --registry "$TMP/reg_g1234" --pr-records "$TMP/no-such-ledger.jsonl")
assert_eq "explicit --pr-records missing: exit 2" "$rc" "2"
assert_contains "explicit --pr-records missing: names the path" "$(cat "$TMP/err")" "no-such-ledger.jsonl"

rc=$(run check --registry "$TMP/reg_missing_guards")
assert_eq "missing skill-guards.json: exit 2 (check)" "$rc" "2"
assert_contains "missing skill-guards.json: names the path" "$(cat "$TMP/err")" "skill-guards.json"

chmod 000 "$TMP/reg_guards_chmod/skill-guards.json"
rc=$(run check --registry "$TMP/reg_guards_chmod")
assert_eq "chmod-000 skill-guards.json: exit 2 (check)" "$rc" "2"
rc=$(run list --registry "$TMP/reg_guards_chmod")
assert_eq "chmod-000 skill-guards.json: exit 2 (list)" "$rc" "2"
rc=$(run report --registry "$TMP/reg_guards_chmod")
assert_eq "chmod-000 skill-guards.json: exit 2 (report)" "$rc" "2"
chmod 644 "$TMP/reg_guards_chmod/skill-guards.json" 2>/dev/null || true

rc=$(run check --registry "$TMP/no-such-dir-at-all")
assert_eq "--registry not a directory: exit 2" "$rc" "2"

( cd "$TMP" && "$PY" "$SUT" check >"$TMP/out" 2>"$TMP/err" ); rc=$?
if git -C "$TMP" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "  skip  --registry omitted outside any git repo (mktemp dir is unexpectedly inside one)"
else
  assert_eq "--registry omitted outside any git repo: exit 2" "$rc" "2"
fi

# =========================================================================
# K. report -- `invalid` verdict: scored, not crashed, siblings still process
# =========================================================================
echo; echo "K. report: invalid verdict (S3)"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_invalid" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "invalid-record report: exit 0 (a per-gate verdict, not a REFUSE)" "$rc" "0"
bad1=$(grep 'hooks/bad1 ' "$TMP/out" || true)
bad2=$(grep 'hooks/bad2 ' "$TMP/out" || true)
ok3=$(grep 'hooks/ok3 ' "$TMP/out" || true)
assert_contains "bad1 (r8 shape) scored invalid" "$bad1" "invalid"
assert_contains "bad2 (r9 shape) scored invalid" "$bad2" "invalid"
assert_contains "ok3 still processed normally alongside invalid gates" "$ok3" "untraced"
assert_contains "invalid detail lists a reason" "$(cat "$TMP/out")" "invalid:"

# =========================================================================
# L. report -- `incomplete` verdict
# =========================================================================
echo; echo "L. report: incomplete verdict"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_L1" --distill "$TMP/distill/L1-stopped.json" --distill "$TMP/distill/L1-unreadable.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "L1 doc-level stopped+unreadable: exit 0" "$rc" "0"
l1out=$(cat "$TMP/out")
assert_contains "L1 incomplete (never suspect, from a compromised corpus)" "$l1out" "incomplete"
assert_not_contains "L1 is never suspect" "$l1out" " suspect"
assert_contains "L1 names the stopped reason" "$l1out" "stopped"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_L2" --distill "$TMP/distill/L2-a.json" --distill "$TMP/distill/L2-b.json" --distill "$TMP/distill/L2-c.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "L2 label-carrying run with null started_at: exit 0" "$rc" "0"
assert_contains "L2 incomplete (missing started_at on a labeled run)" "$(cat "$TMP/out")" "incomplete"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_L3" --distill "$TMP/distill/L3-b.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "L3 label-carrying run with no run.id: exit 0" "$rc" "0"
assert_contains "L3 incomplete (missing run.id on a labeled run)" "$(cat "$TMP/out")" "incomplete"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_L4" --distill "$TMP/distill/L4-clean.json" --distill "$TMP/distill/L4-stopped.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "L4 recurring survives incompleteness elsewhere: exit 0" "$rc" "0"
assert_contains "L4 recurring (positive evidence beats incomplete)" "$(cat "$TMP/out")" "recurring"

# =========================================================================
# M. report -- C1: chain-pass-not-run / failures[]-listed is not a load
# =========================================================================
echo; echo "M. report: C1 (evidence-unverified, never mislabelled, on an unrun/failed chain pass)"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_M1" --distill "$TMP/distill/M1.json" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "M1: exit 0" "$rc" "0"
m1out=$(cat "$TMP/out")
assert_contains "M1 evidence-unverified (chain never ran + failures[]-listed)" "$m1out" "evidence-unverified"
assert_not_contains "M1 is never mislabelled" "$m1out" "mislabelled"

# =========================================================================
# N. report -- C4/C5 join/session/timing fixtures
# =========================================================================
echo; echo "N. report: C4/C5 join and timing rules"
# N1-sy loaded FIRST on purpose: a join that (incorrectly) ignored session and
# searched run_index by run id alone would land on whichever entry was
# inserted first -- loading the WRONG (sy) file first is what makes that bug
# observable; a correct (session, run) tuple lookup is unaffected by order.
rc=$("$PY" "$SUT" report --registry "$TMP/reg_N1" --distill "$TMP/distill/N1-sy.json" --distill "$TMP/distill/N1-sx.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N1 same run id, two sessions: exit 0" "$rc" "0"
assert_contains "N1 join uses session, not run id alone (recurring from SX, not SY)" "$(cat "$TMP/out")" "recurring"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_N2" --pr-records "$TMP/pr-records-n2.jsonl" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N2 same pr number, two repos: exit 0" "$rc" "0"
assert_contains "N2a (repoA, in ledger) found" "$(grep 'hooks/g-n2a ' "$TMP/out" || true)" "pr_record=found"
assert_contains "N2b (repoC, not in ledger despite matching pr) missing" "$(grep 'hooks/g-n2b ' "$TMP/out" || true)" "pr_record=missing"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_N3" --distill "$TMP/distill/N3-before.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N3 run before added.at: exit 0" "$rc" "0"
assert_contains "N3 unobserved (before-gate run not counted as after)" "$(cat "$TMP/out")" "unobserved"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_N4" --distill "$TMP/distill/N4.json" --min-sessions 2 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N4 two runs one session: exit 0" "$rc" "0"
assert_contains "N4 unobserved (1 distinct session, not 2 runs)" "$(cat "$TMP/out")" "unobserved"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_N5" --distill "$TMP/distill/sess-D.json" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N5 partial distill resolution: exit 0" "$rc" "0"
n5out=$(cat "$TMP/out")
assert_contains "N5 evidence-unverified (one resolves, one does not)" "$n5out" "evidence-unverified"
assert_not_contains "N5 is never mislabelled from partial resolution" "$n5out" "mislabelled"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_N6" --distill "$TMP/distill/N6-exact.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "N6 run exactly at added.at: exit 0" "$rc" "0"
assert_contains "N6 unobserved (strict > required, not >=)" "$(cat "$TMP/out")" "unobserved"

# =========================================================================
# O. report -- S1: timestamp parsing
# =========================================================================
echo; echo "O. report: S1 timestamp parsing"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_O" --distill "$TMP/distill/O-a.json" --distill "$TMP/distill/O-b.json" --distill "$TMP/distill/O-c.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "O: exit 0" "$rc" "0"
oout=$(cat "$TMP/out")
assert_contains "O recurring (fractional-second Z timestamp correctly ordered after added.at)" "$oout" "recurring"
assert_contains "O recurring run id A1" "$oout" "A1"

# =========================================================================
# S. S5 -- non-UTF-8 input everywhere
# =========================================================================
echo; echo "S. S5: non-UTF-8 input"
rc=$(run check --registry "$TMP/reg_s5")
assert_eq "non-UTF-8 gates.jsonl: exit 2" "$rc" "2"
assert_contains "non-UTF-8 gates.jsonl: names the path" "$(cat "$TMP/err")" "reg_s5/gates.jsonl"

rc=$(run check --registry "$TMP/reg_s5_guards")
assert_eq "non-UTF-8 skill-guards.json: exit 2" "$rc" "2"
assert_contains "non-UTF-8 skill-guards.json: names the path" "$(cat "$TMP/err")" "reg_s5_guards/skill-guards.json"

rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/s5-garbage-utf8.json")
assert_eq "non-UTF-8 --distill file: exit 2" "$rc" "2"
assert_contains "non-UTF-8 --distill file: names the path" "$(cat "$TMP/err")" "s5-garbage-utf8.json"

rc=$(run report --registry "$TMP/reg_g1234" --pr-records "$TMP/pr-records-badutf8.jsonl")
assert_eq "non-UTF-8 pr-records ledger: exit 2" "$rc" "2"
assert_contains "non-UTF-8 pr-records ledger: names the path" "$(cat "$TMP/err")" "pr-records-badutf8.jsonl"

# =========================================================================
# R. report -- S4: pr ledger garbage line / non-pr-record kind
# =========================================================================
echo; echo "R. report: S4 pr-ledger classification"
rc=$(run report --registry "$TMP/reg_g1234" --pr-records "$TMP/pr-records-garbage.jsonl")
assert_eq "garbage pr-records line: exit 2" "$rc" "2"
assert_contains "garbage pr-records line: names path and line" "$(cat "$TMP/err")" "pr-records-garbage.jsonl:1"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_g1234" --pr-records "$TMP/pr-records-other-kind.jsonl" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "non-pr-record-kind line: exit 0 (ignored, not an error)" "$rc" "0"
assert_contains "non-pr-record-kind line: gate still reads missing" "$(grep 'hooks/g1 ' "$TMP/out" || true)" "pr_record=missing"

# =========================================================================
# T. report -- S6: HOME/$CLAUDE_PR_LEDGER hermeticity
# =========================================================================
echo; echo "T. report: S6 hermeticity (poisoned default ledger)"
out=$(HOME="$TMP/fakehome_poisoned" CLAUDE_PR_LEDGER="$TMP/pr-records.jsonl" "$PY" "$SUT" report --registry "$TMP/reg_g1234" 2>"$TMP/err"); rc=$?
assert_eq "explicit \$CLAUDE_PR_LEDGER wins over a poisoned default ledger: exit 0 (stays green)" "$rc" "0"
assert_contains "poisoned-default proof: pr_record still resolves via the clean override" "$out" "pr_record=found"

rc=$(HOME="$TMP/fakehome_poisoned" "$PY" "$SUT" report --registry "$TMP/reg_g1234" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "poisoned default ledger IS read when nothing overrides it: exit 2 (proves the control is real)" "$rc" "2"

rc=$(HOME="$TMP/fakehome_poisoned_empty" "$PY" "$SUT" report --registry "$TMP/reg_g1234" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "no Obsidian dir under fake HOME: exit 0, no-ledger" "$rc" "0"
assert_contains "no Obsidian dir under fake HOME: pr_record=no-ledger" "$(cat "$TMP/out")" "pr_record=no-ledger"

# =========================================================================
# U. report -- S7: record-level session fallback; records-not-a-list
# =========================================================================
echo; echo "U. report: S7 session fallback"
rc=$("$PY" "$SUT" report --registry "$TMP/reg_U1" --distill "$TMP/distill/U1.json" >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "U1 record-level session used when doc-level is null: exit 0" "$rc" "0"
u1out=$(cat "$TMP/out")
assert_not_contains "U1 evidence resolves (not evidence-unverified)" "$u1out" "evidence-unverified"
assert_not_contains "U1 label matches (not mislabelled)" "$u1out" "mislabelled"

rc=$("$PY" "$SUT" report --registry "$TMP/reg_U2" --distill "$TMP/distill/U2.json" --min-sessions 1 >"$TMP/out" 2>"$TMP/err"; echo $?)
assert_eq "U2 neither doc nor record session present: exit 0" "$rc" "0"
assert_contains "U2 incomplete (no resolvable session on a labeled run)" "$(cat "$TMP/out")" "incomplete"

# =========================================================================
# V. S8 -- --min-sessions must be >= 1
# =========================================================================
echo; echo "V. S8: --min-sessions >= 1"
"$PY" "$SUT" report --registry "$TMP/reg_g1234" --min-sessions 0 >"$TMP/out" 2>"$TMP/err"; rc=$?
assert_eq "--min-sessions 0: argparse error" "$rc" "2"
assert_contains "--min-sessions 0: error names the constraint" "$(cat "$TMP/err")" ">= 1"

# =========================================================================
# W. nitpick -- duplicate (session, run) across two --distill files
# =========================================================================
echo; echo "W. duplicate (session, run) across docs"
rc=$(run report --registry "$TMP/reg_g1234" --distill "$TMP/distill/dup-a.json" --distill "$TMP/distill/dup-b.json")
assert_eq "duplicate (session,run) across two files: exit 2" "$rc" "2"
dup_err=$(cat "$TMP/err")
assert_contains "duplicate: names the first path" "$dup_err" "dup-a.json"
assert_contains "duplicate: names the second path" "$dup_err" "dup-b.json"

# =========================================================================
# X. CI-equivalent: the worked example reports untraced against the real registry
# =========================================================================
echo; echo "X. worked example (real registry) reports untraced"
REPO_ROOT=$(cd "$HERE/../.." && pwd)
out=$(cd "$REPO_ROOT" && CLAUDE_PR_LEDGER="$TMP/no-such-ledger.jsonl" "$PY" "$SUT" report --registry . 2>"$TMP/err"); rc=$?
assert_eq "real registry report: exit 0" "$rc" "0"
assert_contains "real registry: worked example id present" "$out" "agent-review/structured-review-result"
worked_line=$(echo "$out" | grep 'agent-review/structured-review-result' || true)
assert_contains "real registry: worked example reads untraced" "$worked_line" "untraced"

# =========================================================================
# Y. a malformed record with a non-string label must not crash list/report
# =========================================================================
echo; echo "Y. non-string label does not crash list/report"
mkdir -p "$TMP/reg_intlabel"
echo '{"agent-review":[]}' > "$TMP/reg_intlabel/skill-guards.json"
printf '%s\n' '{"schema_version":1,"id":"h/a","kind":"hook","where":"x","targets":[{"label":5,"mode":"m"},{"label":"green-as-done","mode":"m"}],"added":{"repo":"a/b","pr":1,"at":"2026-01-01T00:00:00Z"},"evidence":[{"kind":"issue","repo":"a/b","number":1}]}' > "$TMP/reg_intlabel/gates.jsonl"
rc=$(run list --registry "$TMP/reg_intlabel")
assert_eq "list with int label: exit 0" "$rc" "0"
assert_not_contains "list with int label: no traceback" "$(cat "$TMP/err")" "Traceback"
rc=$(CLAUDE_PR_LEDGER="$TMP/no-such-ledger.jsonl" run report --registry "$TMP/reg_intlabel")
assert_not_contains "report with int label: no traceback" "$(cat "$TMP/err")" "Traceback"
assert_contains "report with int label: scored invalid" "$(cat "$TMP/out")" "invalid"

# =========================================================================
# no __pycache__ left behind anywhere in assets/scripts/
# =========================================================================
echo; echo "Z. no __pycache__"
found=$(find "$HERE" -maxdepth 1 -name '__pycache__' 2>/dev/null)
if [ -z "$found" ]; then ok "no __pycache__ under assets/scripts/"; else bad "__pycache__ present" "$found"; fi

echo
echo "gate-ledger.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
