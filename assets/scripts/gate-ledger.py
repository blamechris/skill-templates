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
      [--distill P ...] [--pr-records P] [--min-sessions N] [--json]

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
restated; the PR-records ledger's default path, its $CLAUDE_PR_LEDGER/
--ledger precedence, its garbage-line classifier and its timestamp parser
are pr-record.py's, imported and reused (`DEFAULT_LEDGER`, `ledger_path_for`,
`_classify_ledger_line`, `parse_iso`) rather than second copies. Each
sibling is imported the same way rework-lag.py imports filed-from.py:
`importlib.util.spec_from_file_location`, with `sys.dont_write_bytecode`
toggled around the import so no stray `__pycache__/` appears in the
checkout. A missing sibling REFUSES (exit 2, naming it) rather than growing
a second copy of what it owns.

THE RECORD (schema_version 1) -- see docs/gate-ledger-shape.md for the full
shape and the illustrative JSON. In brief: `targets[]` ({label, mode}),
`added` ({repo, pr, at}), `evidence[]` (kind `distill`/`trace`/`issue`/`pr`,
each with its own required fields), optional `note`. A `gate` field embedded
on a skill-guards.json guard carries `targets`, `added`, `evidence` and an
optional `note`; its `id` and `kind` are derived from the guard
(`<skill>/<label>` and `skill-guard`), `where` is the guard's own location,
and `schema_version` defaults to `1` -- all four are optional there. A
`gates.jsonl` line still requires `id` and `kind` explicitly (nothing there
is derivable), and `schema_version`, when present anywhere, must be `1` --
there is only ever one schema version, so a stray `2` is a typo or a version
this script cannot read, never a silent pass.

VERDICTS (`report`, first match wins -- see the table in
docs/gate-ledger-shape.md): `invalid` (the record itself fails the same
checks `check` runs -- `report` never crashes on a malformed record, and
never silently scores one as if it were clean), `untraced` (no
`distill`/`trace` evidence), `evidence-unverified` (has `distill` evidence
but a given `--distill` file set does not resolve every one of it to a
LOADED classification -- a record whose chain pass never ran or that is
named in the doc's own `failures[]` does not count as loaded, so it reads
`evidence-unverified` rather than a false `mislabelled` -- never a silent
pass), `mislabelled` (every `distill` evidence record resolved to a loaded
classification, and none of them carries a `classified_as` label in the
gate's own `targets` -- claim-scoped when the evidence names a `claim`),
`not-joinable` (traced, and every target is `unclassified`), `incomplete`
(the distilled data available is not enough to trust an ABSENCE-based
verdict -- see INCOMPLETE below; checked after a possible `recurring`, since
recurrence is positive evidence and survives incomplete data elsewhere),
`unobserved` (fewer than `--min-sessions` distinct distilled SESSIONS -- not
runs -- have any run strictly after `added.at`), `recurring` (at least one
distilled run strictly after `added.at`, with a resolvable session, a
`run.id` and a parseable timestamp, carries a target label), `suspect`
(enough sessions after, no recurrence, and the target label appears in no
distilled run at all, before or after), `quiet` (enough sessions after, no
recurrence, but the mode WAS observed before the gate). `trace` evidence
counts as traced but cannot be machine-checked, so any verdict on a gate
that carries `trace` evidence is printed with `trace-unverified` alongside
it.

INCOMPLETE: a run that carries a target label but whose `started_at` is
missing/unparseable, whose `run.id` is missing, or whose session identity
(the record's own `session`, falling back to the document's `session`) is
unresolvable, cannot safely support an ABSENCE claim (`unobserved`,
`suspect`, `quiet`) -- it might be the very recurrence those verdicts assert
never happened. The same is true when the CORPUS itself is suspect: any
loaded `--distill` document with `stopped` set, a non-empty `unreadable[]`,
a non-empty `failures[]`, or `runs_selected` < `runs_total` means the
distill run that produced it did not see everything, so a clean absence
cannot be certified from it either. `report` prints every contributing
reason. The one exception is `recurring`: a properly-dated, fully-identified
recurrence is POSITIVE evidence, unaffected by incompleteness elsewhere in
the corpus, and is issued even when other documents/runs are incomplete --
which is why `recurring` is evaluated before `incomplete` is issued, despite
sitting after it in the table above. `suspect`, `quiet` and `unobserved`
(all absence claims) are NEVER issued from incomplete data.

TIMESTAMPS are parsed with pr-record.py's own `parse_iso` (imported, not
re-implemented) with one added policy pr-record.py does not need: a NAIVE
timestamp (no trailing `Z` and no explicit `+HH:MM`/`-HH:MM` offset) is
treated as unparseable here, never silently assumed to be UTC -- a session
transcript's timestamp format is not a fact this script gets to guess at.
`check` applies the same rule to `added.at` and a `trace` evidence entry's
`at`.

INPUTS, AND HOW THEY FAIL (see docs/gate-ledger-shape.md "Inputs" for the
full contract): `--registry DIR` defaults to `git rev-parse --show-toplevel`
of the cwd; an absent `gates.jsonl` under it is zero records, but an
unreadable, non-UTF-8 or unparseable one is exit 2 naming the file (and the
line, for a bad JSONL line) -- absent and broken must never print the same
output. Each `--distill PATH` must be a readable, UTF-8, `session-distill.json`
document of kind `session-distill-document` whose `records` field, when
present, is a list; anything else is exit 2 naming the path. `--distill` is
repeatable and OPTIONAL: zero files is legal, and a gate with `distill`
evidence then reads `evidence-unverified` (never a silent `untraced` or a
silent pass). The SAME `(session, run)` pair loaded from two DIFFERENT
`--distill` files is exit 2, naming both paths -- silently letting the
second file win would hide a data problem behind whichever file happened to
load last. `--pr-records PATH` defaults to pr-record.py's own ledger path
(`DEFAULT_LEDGER`, then $CLAUDE_PR_LEDGER, then the flag -- pr-record.py's
own `ledger_path_for` resolves this, reused here rather than
re-implemented); if that default path is absent every gate reports
`pr_record: no-ledger`, but a PATH GIVEN EXPLICITLY that is absent is exit 2
-- naming a ledger by hand is a claim it exists. Every line of a resolved
ledger is validated as JSON up front (a garbage line is exit 2 naming the
path and line, never silently read as "missing" for whatever gate happens
to ask), then joined per gate with pr-record.py's own `_classify_ledger_line`
rather than a second copy of its kind/repo/pr checks.

Exit codes:
  schema  always 0.
  check   0 ok, 1 if any record is invalid (reasons printed per record;
          legacy guards with no `gate` field are counted, never failed on),
          2 for an unreadable/non-UTF-8/unparseable/wrong-kind input or a
          usage error (missing `skill-guards.json`, an unresolvable
          `--registry`, a missing sibling script), always naming the path
          (and the line, for a bad `gates.jsonl` line).
  list    0, or 2 for the same unreadable/unparseable registry inputs.
  report  0 (a per-gate `invalid` verdict is not a REFUSE -- see VERDICTS),
          or 2 for the same registry-input failures, or for a missing/
          non-UTF-8/unparseable/wrong-kind `--distill` file, a duplicate
          `(session, run)` across two `--distill` files, an explicitly-given
          `--pr-records` path that does not exist, or a garbage line in a
          resolved pr-records ledger.
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
# A timestamp counts as parseable only with an EXPLICIT timezone marker --
# `Z` or a `+HH:MM`/`-HH:MM` offset. A naive string might still satisfy
# pr-record.py's own `parse_iso` (which defaults a naive result to UTC),
# but this script does not inherit that default -- see the module
# docstring's TIMESTAMPS section.
TZ_SUFFIX_RE = re.compile(r"(Z|[+-]\d{2}:\d{2})$")
ADDED_REPO_RE = re.compile(r"^[^/\s]+/[^/\s]+$")

EVIDENCE_KINDS = ("distill", "trace", "issue", "pr")

# The embedded gate on a skill-guards.json guard omits id/kind (derived from
# the guard); `where`/`schema_version` are allowed but not required there --
# see the module docstring's THE RECORD section.
ALLOWED_KEYS_GUARD = {"schema_version", "where", "targets", "added", "evidence", "note"}
ALLOWED_KEYS_JSONL = {"schema_version", "id", "kind", "where", "targets", "added", "evidence", "note"}

DEFAULT_MIN_SESSIONS = 5


def die(msg, code=2):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(code)


def positive_int(s):
    try:
        v = int(s)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"{s!r} is not an integer")
    if v < 1:
        raise argparse.ArgumentTypeError(f"--min-sessions must be >= 1 (got {v})")
    return v


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


def parse_ts_strict(s, pr_mod):
    """A tz-aware `datetime`, or None when S is not a string, carries no
    explicit timezone marker (a naive timestamp -- see the module
    docstring's TIMESTAMPS section), or fails pr-record.py's own
    `parse_iso`. The actual ISO parsing is pr-record.py's; this only adds
    the naive-rejection policy on top of it."""
    if not isinstance(s, str) or not s.strip():
        return None
    if not TZ_SUFFIX_RE.search(s.strip()):
        return None
    try:
        return pr_mod.parse_iso(s)
    except (ValueError, TypeError):
        return None


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
    """(entries, total_guard_count). entries carries one dict per guard
    whose `gate` KEY IS PRESENT -- a guard with the key entirely absent is
    legacy, not invalid, and is only reflected in total_guard_count (see
    docs/gate-ledger-shape.md). `"gate": null` is NOT the same as an absent
    key: it is a record whose value fails to be an object, caught below by
    `raw_is_dict`, and check()/report() score it invalid rather than
    silently treating it as legacy."""
    if not os.path.isfile(path):
        die(f"{path} is missing -- skill-guards.json is required")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except UnicodeDecodeError as e:
        die(f"{path} is not valid UTF-8 ({e})")
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
            if "gate" not in guard:
                continue
            gate = guard["gate"]
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
    """[] when PATH is absent (a real, confidently-known zero). An
    unreadable, non-UTF-8 or unparseable file/line REFUSEs (exit 2, naming
    the file and, for a bad line, the line number) -- absent and broken are
    different states and must never print the same output (#278-style
    silent-zero, applied here)."""
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except UnicodeDecodeError as e:
        die(f"{path} is not valid UTF-8 ({e})")
    except OSError as e:
        die(f"cannot read {path} ({e})")

    entries = []
    for i, line in enumerate(lines, 1):
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
    return entries


def load_registry(registry_dir):
    guards_path = os.path.join(registry_dir, "skill-guards.json")
    gates_path = os.path.join(registry_dir, "gates.jsonl")
    guard_entries, total_guards = load_skill_guards(guards_path)
    jsonl_entries = load_gates_jsonl(gates_path)
    return guard_entries, jsonl_entries, total_guards, guards_path, gates_path


# ------------------------------------------------------------------ commands

VERDICTS = (
    "invalid", "untraced", "evidence-unverified", "mislabelled", "not-joinable",
    "incomplete", "unobserved", "recurring", "suspect", "quiet",
)


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
        "verdicts": list(VERDICTS),
    }, indent=2))
    return 0


def _validate_entry(e, sd_mod, pr_mod):
    """[reasons] -- empty when the entry's `gate` value is a fully valid
    record. See the module docstring / docs/gate-ledger-shape.md's `check`
    rejection list; a handful of structural requirements not spelled out as
    their own bullet there (non-empty `targets`, a present/pattern-valid
    `id` on a gates.jsonl record) are enforced too, since a record missing
    them has nothing a verdict could be computed from."""
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

    sv = raw.get("schema_version")
    if sv is not None and sv != SCHEMA_VERSION:
        reasons.append("schema_version must be %d when present (got %r)" % (SCHEMA_VERSION, sv))

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
    repo = added.get("repo")
    if not (isinstance(repo, str) and ADDED_REPO_RE.match(repo)):
        reasons.append("added.repo must be an OWNER/NAME string")
    pr = added.get("pr")
    if isinstance(pr, bool) or not isinstance(pr, int):
        reasons.append("added.pr must be an integer")
    at = added.get("at")
    if parse_ts_strict(at, pr_mod) is None:
        reasons.append(
            "added.at is not a full UTC timestamp (an explicit Z or "
            "+HH:MM/-HH:MM offset is required; a naive timestamp is invalid)"
        )

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
            if parse_ts_strict(ev.get("at"), pr_mod) is None:
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
    pr_mod = load_pr_record()
    registry_dir = resolve_registry(a.registry)
    guard_entries, jsonl_entries, total_guards, guards_path, gates_path = load_registry(registry_dir)
    all_entries = guard_entries + jsonl_entries

    problems = []
    ids_seen = {}
    for e in all_entries:
        reasons = _validate_entry(e, sd_mod, pr_mod)
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
        labels = ",".join(sorted({str(t.get("label")) for t in targets if isinstance(t, dict) and t.get("label")}))
        added = raw.get("added") if isinstance(raw.get("added"), dict) else {}
        added_disp = "%s#%s" % (added.get("repo"), added.get("pr")) if added.get("repo") is not None else "-"
        print("  %-40s %-12s targets=%-30s added=%s" % (e["id"] or "?", e["kind"], labels or "-", added_disp))
    return 0


def coerce_gate(raw):
    """Best-effort normalization for `report`. `report` validates every
    record up front (an invalid one scores the `invalid` verdict and never
    reaches this function), but this stays defensive so a future caller
    cannot crash it on a structurally incomplete dict."""
    targets = raw.get("targets")
    targets = [t for t in targets if isinstance(t, dict)] if isinstance(targets, list) else []
    added = raw.get("added")
    added = added if isinstance(added, dict) else {}
    evidence = raw.get("evidence")
    evidence = [ev for ev in evidence if isinstance(ev, dict)] if isinstance(evidence, list) else []
    return {"targets": targets, "added": added, "evidence": evidence}


def is_distill_record_usable(rec, doc):
    """False when REC's own chain pass never ran (C1: `"chain"` missing
    from `distilled.passes`) or when REC's run id is named in the DOC's own
    `failures[]` -- either way, `classified_as` on this record is not a
    LOADED classification and must never resolve a `distill` evidence
    pointer (which would otherwise misreport as `mislabelled` on an
    untested run instead of `evidence-unverified` on an unloaded one)."""
    passes = ((rec.get("distilled") or {}).get("passes")) or []
    if "chain" not in passes:
        return False
    run_id = (rec.get("run") or {}).get("id")
    for f in doc.get("failures") or []:
        if isinstance(f, dict) and f.get("run") == run_id:
            return False
    return True


def doc_incompleteness_reasons(doc, path):
    """Reasons this loaded --distill document cannot certify an ABSENCE
    verdict for anything -- see the module docstring's INCOMPLETE
    section."""
    reasons = []
    if doc.get("stopped"):
        reasons.append("%s: distill run stopped early (%r)" % (path, doc["stopped"]))
    if doc.get("unreadable"):
        reasons.append("%s: unreadable[] is non-empty (%d entr%s)" % (
            path, len(doc["unreadable"]), "y" if len(doc["unreadable"]) == 1 else "ies"))
    if doc.get("failures"):
        reasons.append("%s: failures[] is non-empty (%d entr%s)" % (
            path, len(doc["failures"]), "y" if len(doc["failures"]) == 1 else "ies"))
    rt, rs = doc.get("runs_total"), doc.get("runs_selected")
    if isinstance(rt, int) and isinstance(rs, int) and rs < rt:
        reasons.append("%s: runs_selected %d < runs_total %d" % (path, rs, rt))
    return reasons


def run_label_reasons(non_unclass, all_records, pr_mod):
    """Reasons any run CARRYING one of NON_UNCLASS's labels cannot safely
    support an absence verdict: a missing/unparseable started_at, a missing
    run.id, or an unresolvable session (record session, falling back to
    document session -- S7)."""
    reasons = []
    for sid, rec, path in all_records:
        labels_here = {
            ca.get("label") for ca in (rec.get("classified_as") or [])
            if isinstance(ca, dict)
        } & non_unclass
        if not labels_here:
            continue
        run = rec.get("run") or {}
        rid = run.get("id")
        if not (isinstance(rid, str) and rid):
            reasons.append("%s: a run carrying %s has no run.id" % (path, sorted(labels_here)))
        if sid is None:
            reasons.append(
                "%s: a run carrying %s has no resolvable session "
                "(neither the record's own `session` nor the document's)" % (path, sorted(labels_here))
            )
        if parse_ts_strict(run.get("started_at"), pr_mod) is None:
            reasons.append(
                "%s: run %s carrying %s has a missing/unparseable started_at"
                % (path, rid or "?", sorted(labels_here))
            )
    return reasons


def compute_verdict(gate, run_index, all_records, min_sessions, doc_reasons, pr_mod):
    """(verdict, detail, trace_unverified) -- see the module docstring's
    VERDICTS section and docs/gate-ledger-shape.md's table (first match
    wins, except that a clean `recurring` match is checked before
    `incomplete` is issued -- see INCOMPLETE)."""
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

    added_at = parse_ts_strict(gate["added"].get("at"), pr_mod)

    # A clean recurring match is POSITIVE evidence, checked before
    # `incomplete` is issued (see INCOMPLETE) -- only a run with a
    # resolvable session, a real run.id and a parseable started_at counts.
    recurring_runs = []
    for sid, rec, path in all_records:
        run = rec.get("run") or {}
        rid = run.get("id")
        if not (isinstance(rid, str) and rid) or sid is None:
            continue
        started = parse_ts_strict(run.get("started_at"), pr_mod)
        if started is None or added_at is None or not (started > added_at):
            continue
        labels_here = {
            ca.get("label") for ca in (rec.get("classified_as") or [])
            if isinstance(ca, dict)
        } & non_unclass
        if labels_here:
            recurring_runs.append(rid)
    if recurring_runs:
        return "recurring", {"runs": recurring_runs}, has_trace

    reasons = list(doc_reasons) + run_label_reasons(non_unclass, all_records, pr_mod)
    if reasons:
        return "incomplete", {"reasons": reasons}, has_trace

    sessions_after = set()
    for sid, rec, path in all_records:
        if sid is None:
            continue
        started = parse_ts_strict((rec.get("run") or {}).get("started_at"), pr_mod)
        if started is not None and added_at is not None and started > added_at:
            sessions_after.add(sid)

    if len(sessions_after) < min_sessions:
        return "unobserved", {"distinct_sessions_after": len(sessions_after)}, has_trace

    observed_anywhere = any(
        ({ca.get("label") for ca in (rec.get("classified_as") or []) if isinstance(ca, dict)} & non_unclass)
        for sid, rec, path in all_records
    )
    if not observed_anywhere:
        return "suspect", {}, has_trace
    return "quiet", {}, has_trace


def read_pr_ledger_lines(path):
    """The raw lines of a pr-record.py ledger, validated up front: every
    non-blank line MUST parse as JSON, or this REFUSEs (exit 2, naming the
    path and line) -- a garbage line must never silently read as "missing"
    for whatever gate happens to ask (S4). Once validated, each gate's own
    lookup is pr-record.py's own `_classify_ledger_line`, reused rather than
    a second kind/repo/pr check."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except UnicodeDecodeError as e:
        die(f"{path} is not valid UTF-8 ({e})")
    except OSError as e:
        die(f"cannot read --pr-records {path} ({e})")
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if not s:
            continue
        try:
            json.loads(s)
        except json.JSONDecodeError as e:
            die(f"{path}:{i}: not valid JSON ({e})")
    return lines


def cmd_report(a):
    sd_mod = load_session_distill()
    pr_mod = load_pr_record()
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
        except UnicodeDecodeError as e:
            die(f"--distill {p} is not valid UTF-8 ({e})")
        except OSError as e:
            die(f"--distill {p} could not be read ({e})")
        except json.JSONDecodeError as e:
            die(f"--distill {p} is not valid JSON ({e})")
        if not isinstance(doc, dict) or doc.get("kind") != "session-distill-document":
            got = doc.get("kind") if isinstance(doc, dict) else type(doc).__name__
            die(f"--distill {p} is not a session-distill-document (kind={got!r})")
        records = doc.get("records")
        if records is not None and not isinstance(records, list):
            die(f"--distill {p}: 'records' is not a list")
        distill_docs.append((doc, p))

    doc_reasons = []
    run_index = {}
    run_seen_at = {}
    all_records = []
    for doc, path in distill_docs:
        doc_reasons.extend(doc_incompleteness_reasons(doc, path))
        doc_session = doc.get("session") if isinstance(doc.get("session"), str) and doc.get("session") else None
        for rec in doc.get("records") or []:
            if not isinstance(rec, dict):
                continue
            run = rec.get("run") or {}
            rid = run.get("id")
            rec_session = rec.get("session") if isinstance(rec.get("session"), str) and rec.get("session") else None
            sid = rec_session or doc_session
            if isinstance(rid, str) and rid and sid is not None:
                key = (sid, rid)
                if key in run_seen_at and run_seen_at[key] != path:
                    die(
                        f"duplicate (session, run) {key!r} found in both "
                        f"{run_seen_at[key]} and {path}"
                    )
                run_seen_at[key] = path
                if is_distill_record_usable(rec, doc):
                    run_index[key] = rec
            all_records.append((sid, rec, path))

    if a.pr_records:
        ledger_path = a.pr_records
        if not os.path.isfile(ledger_path):
            die(f"--pr-records {ledger_path} does not exist")
        ledger_lines = read_pr_ledger_lines(ledger_path)
        ledger_available = True
    else:
        ledger_path = pr_mod.ledger_path_for(argparse.Namespace(ledger=None))
        if os.path.isfile(ledger_path):
            ledger_lines = read_pr_ledger_lines(ledger_path)
            ledger_available = True
        else:
            ledger_lines = []
            ledger_available = False

    results = []
    for e in all_entries:
        raw = e["raw"] if e.get("raw_is_dict", True) else {}
        reasons = _validate_entry(e, sd_mod, pr_mod)
        gate = coerce_gate(raw)
        added = gate["added"]

        if reasons:
            verdict, detail, has_trace = "invalid", {"reasons": reasons}, False
        else:
            verdict, detail, has_trace = compute_verdict(
                gate, run_index, all_records, a.min_sessions, doc_reasons, pr_mod)

        if not ledger_available:
            pr_status = "no-ledger"
        elif not (isinstance(added.get("repo"), str) and isinstance(added.get("pr"), int)
                  and not isinstance(added.get("pr"), bool)):
            pr_status = "missing"
        else:
            repo, pr = added["repo"], added["pr"]
            found = any(pr_mod._classify_ledger_line(line, repo, pr) == "exact" for line in ledger_lines)
            pr_status = "found" if found else "missing"

        results.append({
            "id": e["id"],
            "kind": e["kind"],
            "source": e["source"],
            "targets": sorted({str(t.get("label")) for t in gate["targets"] if isinstance(t, dict) and t.get("label")}),
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
        if r["verdict"] == "incomplete" and r["detail"].get("reasons"):
            for reason in r["detail"]["reasons"]:
                print("      incomplete: %s" % reason)
        if r["verdict"] == "invalid" and r["detail"].get("reasons"):
            for reason in r["detail"]["reasons"]:
                print("      invalid: %s" % reason)
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
    r.add_argument("--min-sessions", type=positive_int, default=DEFAULT_MIN_SESSIONS)
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_report)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
