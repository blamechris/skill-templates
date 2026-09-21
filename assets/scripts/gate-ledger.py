#!/usr/bin/env python3
"""gate-ledger.py -- for every gate (a skill-guard, a hook, a CI step, a
script-check, a doctrine rule), record the failure mode it targets and the
evidence chain that justified adding it (#272, epic #266, design at
docs/gate-ledger-shape.md -- read that file first; this docstring is the
field-by-field/exit-code reference, not the design rationale).

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/gate-ledger.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/gate-ledger.py schema
  python3 ~/.claude/scripts/gate-ledger.py check  [--registry D]
  python3 ~/.claude/scripts/gate-ledger.py list   [--registry D] [--json]
  python3 ~/.claude/scripts/gate-ledger.py report [--registry D]
      --distill P [--distill P ...] [--pr-records P] [--min-sessions N] [--json]

THE PROBLEM (#263/#264): a guard was built for a frozen sample file, and the
freeze was never real. The trace showed an idle account plus a genuine plan
reset; the actual failure was the orchestrator's,
`absence-without-second-search`. The guard targeted a sensor defect and the
trace named a reasoning defect. Nothing recorded either fact, so nothing
could compare them. THE UNIT IS ONE GATE: a `gate` field on a guard object in
`skill-guards.json` (kind `skill-guard`, id `<skill>/<label>`, both derived
from the guard rather than stated), or one line in `gates.jsonl` at the
registry root (kind `hook`/`ci-step`/`script-check`/`doctrine`, id given).
The registry is PUBLIC, so a record holds only pointers -- PR/issue numbers,
session ids, run ids, claim ids -- never a transcript quote.

REUSE, NOT RE-DERIVATION: the closed vocabulary of evidence-quality failure
modes (`LABELS`) is session-distill.py's, imported by path rather than
restated; the PR-records ledger's default path and its
$CLAUDE_PR_LEDGER/--ledger precedence are pr-record.py's, imported and
reused (`DEFAULT_LEDGER`, `ledger_path_for`) rather than a second copy of
either. Each sibling is imported the same way rework-lag.py imports
filed-from.py: `importlib.util.spec_from_file_location`, with
`sys.dont_write_bytecode` toggled around the import so no stray
`__pycache__/` appears in the checkout. A missing sibling REFUSES (exit 2,
naming it) rather than growing a second copy of what it owns.

THE RECORD (schema_version 1) -- see docs/gate-ledger-shape.md for the full
shape and the illustrative JSON. In brief: `targets[]` ({label, mode}),
`added` ({repo, pr, at}), `evidence[]` (kind `distill`/`trace`/`issue`/`pr`,
each with its own required fields), optional `note`. A `gate` field embedded
on a skill-guards.json guard carries everything except `id` and `kind`,
which are derived from the guard (`<skill>/<label>` and `skill-guard`); this
script additionally treats `where` and `schema_version` as optional on an
embedded gate for the same reason -- see the deviation note in this repo's
PR description for #272: the doc states the embedded gate "carries
everything except id and kind", but its own worked example in
docs/gate-ledger-shape.md and the concrete worked example this issue asks
for both omit `where` and `schema_version`, so this script does not require
either to be present on a `skill-guard`-kind gate. A `gates.jsonl` line
requires `id` and `kind` explicitly (nothing there is derivable).

VERDICTS (`report`, first match wins -- see the table in
docs/gate-ledger-shape.md): `untraced` (no `distill`/`trace` evidence),
`evidence-unverified` (has `distill` evidence but a given `--distill` file
set does not resolve every one of it -- never a silent pass), `mislabelled`
(every `distill` evidence record resolved, none of them carries a
`classified_as` label in the gate's own `targets` -- claim-scoped when the
evidence names a `claim`), `not-joinable` (traced, and every target is
`unclassified`), `unobserved` (fewer than `--min-sessions` distinct
distilled sessions have any run after `added.at`), `recurring` (at least one
distilled run after `added.at` carries a target label), `suspect` (enough
sessions after, no recurrence, and the target label appears in no distilled
run at all, before or after), `quiet` (enough sessions after, no recurrence,
but the mode WAS observed before the gate). `trace` evidence counts as
traced but cannot be machine-checked, so any verdict on a gate that carries
`trace` evidence is printed with `trace-unverified` alongside it.

INPUTS, AND HOW THEY FAIL (see docs/gate-ledger-shape.md "Inputs" for the
full contract): `--registry DIR` defaults to `git rev-parse --show-toplevel`
of the cwd; an absent `gates.jsonl` under it is zero records, but an
unreadable or unparseable one is exit 2 naming the file (and the line, for a
bad JSONL line) -- absent and broken must never print the same output. Each
`--distill PATH` must be a readable `session-distill.json` document of kind
`session-distill-document`; anything else is exit 2 naming the path.
`--distill` is repeatable and OPTIONAL: zero files is legal, and a gate with
`distill` evidence then reads `evidence-unverified` (never a silent
`untraced` or a silent pass). `--pr-records PATH` defaults to
pr-record.py's own ledger path (`DEFAULT_LEDGER`, then $CLAUDE_PR_LEDGER,
then the flag -- pr-record.py's own `ledger_path_for` resolves this, reused
here rather than re-implemented); if that default path is absent every gate
reports `pr_record: no-ledger`, but a PATH GIVEN EXPLICITLY that is absent
is exit 2 -- naming a ledger by hand is a claim it exists.

Exit codes:
  schema  always 0.
  check   0 ok, 1 if any record is invalid (reasons printed per record;
          legacy guards with no `gate` field are counted, never failed on),
          2 for an unreadable/unparseable/wrong-kind input or a usage error
          (missing `skill-guards.json`, an unresolvable `--registry`, a
          missing sibling script), always naming the path (and the line,
          for a bad `gates.jsonl` line).
  list    0, or 2 for the same unreadable/unparseable registry inputs.
  report  0, or 2 for the same registry-input failures, or for a missing/
          unparseable/wrong-kind `--distill` file, or an explicitly-given
          `--pr-records` path that does not exist.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = 1

GATE_KINDS_JSONL = ("hook", "ci-step", "script-check", "doctrine")

ID_RE = re.compile(r"^[a-z0-9][a-z0-9./-]*$")
FULL_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

EVIDENCE_KINDS = ("distill", "trace", "issue", "pr")

# The embedded gate on a skill-guards.json guard omits id/kind (derived from
# the guard); this script also treats `where`/`schema_version` as optional
# there -- see the docstring's VERDICTS/RECORD section for why.
ALLOWED_KEYS_GUARD = {"schema_version", "where", "targets", "added", "evidence", "note"}
ALLOWED_KEYS_JSONL = {"schema_version", "id", "kind", "where", "targets", "added", "evidence", "note"}

DEFAULT_MIN_SESSIONS = 5


def die(msg, code=2):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(code)


# --------------------------------------------------------------- sibling reuse

def _load_sibling(filename, modname):
    """Import assets/scripts/<filename> by path -- the same
    importlib.util.spec_from_file_location pattern pr-record.py and
    session-distill.py use for their own sibling reuse. REFUSEs (exit 2) if
    the sibling is missing, and never leaves a __pycache__/ behind."""
    sib = Path(__file__).resolve().parent / filename
    if not sib.exists():
        die(
            f"sibling assets/scripts/{filename} is missing. gate-ledger.py "
            f"reuses its logic rather than re-implementing it, and refuses "
            f"to run without it (expected at {sib})."
        )
    prev = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(modname, str(sib))
        if spec is None or spec.loader is None:
            die(f"sibling {sib} exists but importlib could not build a loader for it")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = prev
    return mod


def load_session_distill():
    return _load_sibling("session-distill.py", "gate_ledger_session_distill")


def load_pr_record():
    return _load_sibling("pr-record.py", "gate_ledger_pr_record")


# -------------------------------------------------------------- registry load

def resolve_registry(explicit):
    if explicit:
        if not os.path.isdir(explicit):
            die(f"--registry {explicit} is not a directory")
        return os.path.abspath(explicit)
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
    except OSError as e:
        die(f"--registry not given and git could not be invoked ({e})")
    if proc.returncode != 0:
        die(
            "--registry not given and the cwd is not inside a git repository "
            "-- pass --registry explicitly"
        )
    return proc.stdout.strip()


def load_skill_guards(path):
    """(entries, total_guard_count). entries carries one dict per guard that
    HAS a `gate` field -- a guard with none is legacy, not invalid, and is
    only reflected in total_guard_count (see docs/gate-ledger-shape.md)."""
    if not os.path.isfile(path):
        die(f"{path} is missing -- skill-guards.json is required")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        die(f"cannot read {path} ({e})")
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        die(f"{path} is not valid JSON ({e})")
    if not isinstance(doc, dict):
        die(f"{path} did not parse to a JSON object")

    entries = []
    total_guards = 0
    for skill, guards in doc.items():
        if skill == "_comment" or not isinstance(guards, list):
            continue
        for guard in guards:
            if not isinstance(guard, dict):
                continue
            total_guards += 1
            gate = guard.get("gate")
            if gate is None:
                continue
            label = guard.get("label")
            is_dict = isinstance(gate, dict)
            gid = "%s/%s" % (skill, label) if isinstance(label, str) and label else None
            entries.append({
                "raw": gate if is_dict else {},
                "raw_is_dict": is_dict,
                "id": gid,
                "kind": "skill-guard",
                "is_guard": True,
                "source": "%s guard %s/%s" % (path, skill, label),
            })
    return entries, total_guards


def load_gates_jsonl(path):
    """[] when PATH is absent (a real, confidently-known zero). An unreadable
    or unparseable file/line REFUSEs (exit 2, naming the file and, for a bad
    line, the line number) -- absent and broken are different states and
    must never print the same output (#278-style silent-zero, applied
    here)."""
    if not os.path.exists(path):
        return []
    try:
        f = open(path, encoding="utf-8")
    except OSError as e:
        die(f"cannot read {path} ({e})")
    entries = []
    try:
        for i, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            try:
                obj = json.loads(s)
            except json.JSONDecodeError as e:
                die(f"{path}:{i}: not valid JSON ({e})")
            if not isinstance(obj, dict):
                die(f"{path}:{i}: did not parse to a JSON object")
            rid = obj.get("id") if isinstance(obj.get("id"), str) else None
            entries.append({
                "raw": obj,
                "raw_is_dict": True,
                "id": rid,
                "kind": obj.get("kind"),
                "is_guard": False,
                "source": "%s:%d" % (path, i),
            })
    except OSError as e:
        die(f"error reading {path} ({e})")
    finally:
        f.close()
    return entries


def load_registry(registry_dir):
    guards_path = os.path.join(registry_dir, "skill-guards.json")
    gates_path = os.path.join(registry_dir, "gates.jsonl")
    guard_entries, total_guards = load_skill_guards(guards_path)
    jsonl_entries = load_gates_jsonl(gates_path)
    return guard_entries, jsonl_entries, total_guards, guards_path, gates_path


# ------------------------------------------------------------------ commands

def cmd_schema(a):
    sd_mod = load_session_distill()
    print(json.dumps({
        "record_schema_version": SCHEMA_VERSION,
        "labels": list(sd_mod.LABELS),
        "gate_kinds": ["skill-guard"] + list(GATE_KINDS_JSONL),
        "evidence_kinds": {
            "distill": {"required": ["session", "run"], "optional": ["claim"]},
            "trace": {"required": ["session", "run", "at"]},
            "issue": {"required": ["repo", "number"]},
            "pr": {"required": ["repo", "number"]},
        },
        "verdicts": [
            "untraced", "evidence-unverified", "mislabelled", "not-joinable",
            "unobserved", "recurring", "suspect", "quiet",
        ],
    }, indent=2))
    return 0


def _validate_entry(e, sd_mod):
    """[reasons] -- empty when the entry's `gate` value is a fully valid
    record. See the module docstring / docs/gate-ledger-shape.md's `check`
    rejection list; a handful of structural requirements not explicitly
    named there (non-empty `targets`, a present/pattern-valid `id` on a
    gates.jsonl record) are enforced too, since a record missing them has
    nothing a verdict could be computed from -- see the PR description's
    deviation note."""
    reasons = []
    raw = e["raw"]
    allowed = ALLOWED_KEYS_GUARD if e["is_guard"] else ALLOWED_KEYS_JSONL

    if not e.get("raw_is_dict", True):
        return ["gate value is not a JSON object"]

    unknown = sorted(k for k in raw.keys() if k not in allowed)
    if unknown:
        reasons.append("unknown top-level key(s): %s" % ", ".join(unknown))

    if e["is_guard"]:
        if e["id"] is None:
            reasons.append("guard has no non-empty string `label`, so no id could be derived")
    else:
        rid = e["id"]
        if rid is None:
            reasons.append("missing or non-string `id`")
        elif not ID_RE.match(rid):
            reasons.append("id %r does not match ^[a-z0-9][a-z0-9./-]*$" % rid)
        kind = e["kind"]
        if kind == "skill-guard":
            reasons.append(
                "gates.jsonl record has kind \"skill-guard\" -- that record "
                "belongs on the guard, not in gates.jsonl"
            )
        elif kind not in GATE_KINDS_JSONL:
            reasons.append("kind %r is not one of %s" % (kind, ", ".join(GATE_KINDS_JSONL)))

    targets = raw.get("targets")
    if not isinstance(targets, list) or not targets:
        reasons.append("targets must be a non-empty list")
        targets = []
    for i, t in enumerate(targets):
        if not isinstance(t, dict):
            reasons.append("targets[%d] is not an object" % i)
            continue
        label = t.get("label")
        if label not in sd_mod.LABELS:
            reasons.append("targets[%d].label %r is outside the vocabulary" % (i, label))
        elif label == "unclassified" and not (isinstance(t.get("mode"), str) and t.get("mode").strip()):
            reasons.append("targets[%d] is unclassified with no non-empty mode" % i)

    added = raw.get("added")
    if not isinstance(added, dict):
        reasons.append("added must be an object")
        added = {}
    pr = added.get("pr")
    if pr is not None and (isinstance(pr, bool) or not isinstance(pr, int)):
        reasons.append("added.pr must be an integer")
    at = added.get("at")
    if not (isinstance(at, str) and FULL_UTC_RE.match(at)):
        reasons.append("added.at is not a full UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)")

    evidence = raw.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        reasons.append("evidence must be non-empty")
        evidence = []
    for i, ev in enumerate(evidence):
        if not isinstance(ev, dict):
            reasons.append("evidence[%d] is not an object" % i)
            continue
        ekind = ev.get("kind")
        if ekind == "distill":
            if not (isinstance(ev.get("session"), str) and ev.get("session")):
                reasons.append("evidence[%d] (distill) missing `session`" % i)
            if not (isinstance(ev.get("run"), str) and ev.get("run")):
                reasons.append("evidence[%d] (distill) missing `run`" % i)
        elif ekind == "trace":
            if not (isinstance(ev.get("session"), str) and ev.get("session")):
                reasons.append("evidence[%d] (trace) missing `session`" % i)
            if not (isinstance(ev.get("run"), str) and ev.get("run")):
                reasons.append("evidence[%d] (trace) missing `run`" % i)
            if not (isinstance(ev.get("at"), str) and FULL_UTC_RE.match(ev.get("at"))):
                reasons.append("evidence[%d] (trace) missing/invalid `at`" % i)
        elif ekind in ("issue", "pr"):
            if not (isinstance(ev.get("repo"), str) and ev.get("repo")):
                reasons.append("evidence[%d] (%s) missing `repo`" % (i, ekind))
            num = ev.get("number")
            if num is None or isinstance(num, bool) or not isinstance(num, int):
                reasons.append("evidence[%d] (%s).number must be an integer" % (i, ekind))
        else:
            reasons.append("evidence[%d].kind %r is not one of %s" % (i, ekind, ", ".join(EVIDENCE_KINDS)))

    return reasons


def cmd_check(a):
    sd_mod = load_session_distill()
    registry_dir = resolve_registry(a.registry)
    guard_entries, jsonl_entries, total_guards, guards_path, gates_path = load_registry(registry_dir)
    all_entries = guard_entries + jsonl_entries

    problems = []
    ids_seen = {}
    for e in all_entries:
        reasons = _validate_entry(e, sd_mod)
        if reasons:
            problems.append((e["source"], e["id"], reasons))
        if e["id"] is not None:
            ids_seen.setdefault(e["id"], []).append(e["source"])

    for rid, sources in ids_seen.items():
        if len(sources) > 1:
            problems.append((
                ", ".join(sources), rid,
                ["duplicate id %r across %d record(s): %s" % (rid, len(sources), ", ".join(sources))],
            ))

    legacy = total_guards - len(guard_entries)

    print("gate-ledger check: registry=%s" % registry_dir)
    print("records: %d (%d skill-guard, %d gates.jsonl)   legacy guards without a gate field: %d" % (
        len(all_entries), len(guard_entries), len(jsonl_entries), legacy))
    print("invalid: %d" % len(problems))
    for source, rid, reasons in problems:
        print("  %s (id=%s)" % (source, rid))
        for r in reasons:
            print("    - %s" % r)
    return 1 if problems else 0


def cmd_list(a):
    registry_dir = resolve_registry(a.registry)
    guard_entries, jsonl_entries, total_guards, guards_path, gates_path = load_registry(registry_dir)
    all_entries = guard_entries + jsonl_entries

    if a.json:
        out = [{"id": e["id"], "kind": e["kind"], "source": e["source"], "gate": e["raw"]} for e in all_entries]
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0

    print("registry: %s" % registry_dir)
    print("%d gate record(s) (%d skill-guard, %d gates.jsonl, %d legacy guard(s) without a gate field)" % (
        len(all_entries), len(guard_entries), len(jsonl_entries), total_guards - len(guard_entries)))
    for e in all_entries:
        raw = e["raw"] if e.get("raw_is_dict", True) else {}
        targets = raw.get("targets") if isinstance(raw.get("targets"), list) else []
        labels = ",".join(sorted({t.get("label") for t in targets if isinstance(t, dict) and t.get("label")}))
        added = raw.get("added") if isinstance(raw.get("added"), dict) else {}
        added_disp = "%s#%s" % (added.get("repo"), added.get("pr")) if added.get("repo") is not None else "-"
        print("  %-40s %-12s targets=%-30s added=%s" % (e["id"] or "?", e["kind"], labels or "-", added_disp))
    return 0


def coerce_gate(raw):
    """Best-effort normalization for `report`, which does not itself
    validate (that is `check`'s job) but must never crash on a structurally
    incomplete record."""
    targets = raw.get("targets")
    targets = [t for t in targets if isinstance(t, dict)] if isinstance(targets, list) else []
    added = raw.get("added")
    added = added if isinstance(added, dict) else {}
    evidence = raw.get("evidence")
    evidence = [ev for ev in evidence if isinstance(ev, dict)] if isinstance(evidence, list) else []
    return {"targets": targets, "added": added, "evidence": evidence}


def compute_verdict(gate, run_index, all_records, min_sessions):
    """(verdict, detail, trace_unverified) -- see the module docstring's
    VERDICTS section and docs/gate-ledger-shape.md's table (first match
    wins)."""
    evidence = gate["evidence"]
    distill_ev = [e for e in evidence if e.get("kind") == "distill"]
    trace_ev = [e for e in evidence if e.get("kind") == "trace"]
    has_trace = bool(trace_ev)

    if not distill_ev and not trace_ev:
        return "untraced", {}, False

    if distill_ev:
        resolved = []
        unresolved = []
        for e in distill_ev:
            key = (e.get("session"), e.get("run"))
            rec = run_index.get(key)
            if rec is None:
                unresolved.append("%s/%s" % key)
            resolved.append((e, rec))
        if unresolved:
            return "evidence-unverified", {"unresolved": unresolved}, has_trace

        target_labels = {t.get("label") for t in gate["targets"]}
        matched = False
        observed_labels = set()
        for e, rec in resolved:
            claim = e.get("claim")
            for ca in rec.get("classified_as") or []:
                if not isinstance(ca, dict):
                    continue
                if ca.get("label"):
                    observed_labels.add(ca.get("label"))
                if ca.get("label") not in target_labels:
                    continue
                if claim is not None and claim not in (ca.get("supports") or []):
                    continue
                matched = True
        if not matched:
            return "mislabelled", {"observed_labels": sorted(observed_labels)}, has_trace

    non_unclass = {t.get("label") for t in gate["targets"] if t.get("label") != "unclassified"}
    if not non_unclass:
        return "not-joinable", {}, has_trace

    added_at = gate["added"].get("at")
    added_at = added_at if isinstance(added_at, str) else None

    sessions_after = set()
    for sid, rec in all_records:
        started = (rec.get("run") or {}).get("started_at")
        if added_at and isinstance(started, str) and started > added_at:
            sessions_after.add(sid)

    if len(sessions_after) < min_sessions:
        return "unobserved", {"distinct_sessions_after": len(sessions_after)}, has_trace

    recurring_runs = []
    observed_anywhere = False
    for sid, rec in all_records:
        started = (rec.get("run") or {}).get("started_at")
        labels_here = {
            ca.get("label") for ca in (rec.get("classified_as") or [])
            if isinstance(ca, dict)
        } & non_unclass
        if not labels_here:
            continue
        observed_anywhere = True
        if added_at and isinstance(started, str) and started > added_at:
            rid = (rec.get("run") or {}).get("id")
            if rid:
                recurring_runs.append(rid)

    if recurring_runs:
        return "recurring", {"runs": recurring_runs}, has_trace
    if not observed_anywhere:
        return "suspect", {}, has_trace
    return "quiet", {}, has_trace


def read_pr_ledger(path):
    """{(repo, pr)} found in a pr-record.py ledger -- best-effort: a line
    that fails to parse, or does not look like a pr-record, is skipped
    rather than failing the whole report (this is READING an external
    ledger gate-ledger.py does not own, not validating one of its own
    records)."""
    found = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if not s:
                    continue
                try:
                    obj = json.loads(s)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("kind") != "pr-record":
                    continue
                repo, pr = obj.get("repo"), obj.get("pr")
                if isinstance(repo, str) and isinstance(pr, int) and not isinstance(pr, bool):
                    found.add((repo, pr))
    except OSError as e:
        die(f"cannot read --pr-records {path} ({e})")
    return found


def cmd_report(a):
    load_session_distill()  # unused directly, but REFUSE early if missing -- report joins by label too
    registry_dir = resolve_registry(a.registry)
    guard_entries, jsonl_entries, total_guards, guards_path, gates_path = load_registry(registry_dir)
    all_entries = guard_entries + jsonl_entries

    distill_docs = []
    for p in a.distill:
        if not os.path.isfile(p):
            die(f"--distill {p} is not a readable file")
        try:
            with open(p, encoding="utf-8") as f:
                doc = json.load(f)
        except OSError as e:
            die(f"--distill {p} could not be read ({e})")
        except json.JSONDecodeError as e:
            die(f"--distill {p} is not valid JSON ({e})")
        if not isinstance(doc, dict) or doc.get("kind") != "session-distill-document":
            got = doc.get("kind") if isinstance(doc, dict) else type(doc).__name__
            die(f"--distill {p} is not a session-distill-document (kind={got!r})")
        distill_docs.append(doc)

    run_index = {}
    all_records = []
    for doc in distill_docs:
        sid = doc.get("session")
        for rec in doc.get("records") or []:
            if not isinstance(rec, dict):
                continue
            run = rec.get("run") or {}
            rid = run.get("id")
            if isinstance(rid, str):
                run_index[(sid, rid)] = rec
            all_records.append((sid, rec))

    if a.pr_records:
        ledger_path = a.pr_records
        if not os.path.isfile(ledger_path):
            die(f"--pr-records {ledger_path} does not exist")
        pr_index = read_pr_ledger(ledger_path)
        ledger_available = True
    else:
        pr_mod = load_pr_record()
        ledger_path = pr_mod.ledger_path_for(argparse.Namespace(ledger=None))
        if os.path.isfile(ledger_path):
            pr_index = read_pr_ledger(ledger_path)
            ledger_available = True
        else:
            pr_index = set()
            ledger_available = False

    results = []
    for e in all_entries:
        raw = e["raw"] if e.get("raw_is_dict", True) else {}
        gate = coerce_gate(raw)
        verdict, detail, has_trace = compute_verdict(gate, run_index, all_records, a.min_sessions)
        added = gate["added"]
        if not ledger_available:
            pr_status = "no-ledger"
        else:
            key = (added.get("repo"), added.get("pr"))
            pr_status = "found" if key in pr_index else "missing"
        results.append({
            "id": e["id"],
            "kind": e["kind"],
            "source": e["source"],
            "targets": sorted({t.get("label") for t in gate["targets"] if t.get("label")}),
            "added": added,
            "verdict": verdict,
            "trace_unverified": has_trace,
            "detail": detail,
            "pr_record": pr_status,
        })

    if a.json:
        print(json.dumps({
            "kind": "gate-ledger-report",
            "schema_version": SCHEMA_VERSION,
            "registry": registry_dir,
            "min_sessions": a.min_sessions,
            "distill_files": [os.path.abspath(p) for p in a.distill],
            "pr_records": ledger_path if ledger_available else None,
            "gates": results,
        }, indent=2, ensure_ascii=False))
        return 0

    print("gate-ledger report: registry=%s" % registry_dir)
    print("distill files: %d   pr-records: %s" % (
        len(a.distill), ledger_path if ledger_available else "(none found)"))
    print()
    for r in results:
        vs = r["verdict"] + (" trace-unverified" if r["trace_unverified"] else "")
        added = r["added"]
        added_disp = "%s#%s" % (added.get("repo"), added.get("pr")) if added.get("repo") is not None else "-"
        print("  %-40s %-28s targets=%-30s added=%-30s pr_record=%s" % (
            r["id"] or "?", vs, ",".join(r["targets"]) or "-", added_disp, r["pr_record"]))
        if r["verdict"] == "recurring" and r["detail"].get("runs"):
            print("      recurring runs: %s" % ", ".join(r["detail"]["runs"]))
        if r["verdict"] == "evidence-unverified" and r["detail"].get("unresolved"):
            print("      unresolved: %s" % ", ".join(r["detail"]["unresolved"]))
        if r["verdict"] == "mislabelled" and r["detail"].get("observed_labels"):
            print("      observed instead: %s" % ", ".join(r["detail"]["observed_labels"]))
    return 0


# ------------------------------------------------------------------------ CLI

def build_parser():
    p = argparse.ArgumentParser(
        prog="gate-ledger.py",
        description="One record per gate: the failure mode it targets, and the evidence that justified it.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("schema", help="print the record shape as JSON").set_defaults(fn=cmd_schema)

    c = sub.add_parser("check", help="validate every gate record; exit 1 on any invalid")
    c.add_argument("--registry", default=None, help="registry dir (default: git toplevel of cwd)")
    c.set_defaults(fn=cmd_check)

    l = sub.add_parser("list", help="enumerate every gate record")
    l.add_argument("--registry", default=None, help="registry dir (default: git toplevel of cwd)")
    l.add_argument("--json", action="store_true")
    l.set_defaults(fn=cmd_list)

    r = sub.add_parser("report", help="join gates against session-distill and pr-record output")
    r.add_argument("--registry", default=None, help="registry dir (default: git toplevel of cwd)")
    r.add_argument("--distill", action="append", default=[], metavar="PATH",
                    help="a session-distill.json document (repeatable; optional)")
    r.add_argument("--pr-records", default=None, metavar="PATH",
                    help="pr-record.py ledger path (default: pr-record.py's own default)")
    r.add_argument("--min-sessions", type=int, default=DEFAULT_MIN_SESSIONS)
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_report)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
