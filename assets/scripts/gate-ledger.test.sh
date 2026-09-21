#!/usr/bin/env bash
# Regression tests for assets/scripts/gate-ledger.py (#272, epic #266).
#
# Hermetic: a fixture registry (skill-guards.json + gates.jsonl variants), a
# handful of fixture session-distill.json documents, and a fixture
# pr-record.py ledger, all built once under a mktemp dir. The real siblings
# session-distill.py and pr-record.py are used as-is (they sit next to the
# SUT in this checkout) -- only their INPUT files are fixtures.
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

def guards_doc(extra_agent_review_gate=None):
    doc = {
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
    return doc

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

# ---- D1..D9 check-rejection fixtures --------------------------------------
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

# =========================================================================
# report fixtures: gates + distill docs
# =========================================================================

def dist_doc(session, records):
    return {"kind": "session-distill-document", "schema_version": 1, "session": session, "records": records}

def rec(run_id, started_at, classified_as):
    return {"run": {"id": run_id, "kind": "subagent", "started_at": started_at}, "classified_as": classified_as}

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

# pr-records ledger fixture: found for pr 31 (G1), nothing for pr 35 (G4)
w("pr-records.jsonl", json.dumps({
    "kind": "pr-record", "schema_version": 1, "repo": "acme/widgets", "pr": 31,
    "recorded_at": "2026-01-03T00:00:00Z",
}) + "\n")

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
assert_contains "schema lists all 8 verdicts" "$out" "\"quiet\""
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
out=$(cat "$TMP/out")
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
# J. no __pycache__ left behind anywhere in assets/scripts/
# =========================================================================
echo; echo "J. no __pycache__"
found=$(find "$HERE" -maxdepth 1 -name '__pycache__' 2>/dev/null)
if [ -z "$found" ]; then ok "no __pycache__ under assets/scripts/"; else bad "__pycache__ present" "$found"; fi

echo
echo "gate-ledger.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
