#!/usr/bin/env python3
"""Own the structured review-result: the one schema, and how it is validated,
recorded, harvested and listed beside the subagent sidecar.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/review-result.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/review-result.py schema
  python3 ~/.claude/scripts/review-result.py validate [FILE]
  python3 ~/.claude/scripts/review-result.py record --agent ID --skill NAME
      [--pr N] [--session SID] [--force] [FILE]
  python3 ~/.claude/scripts/review-result.py harvest [--session SID] [--dry-run]
  python3 ~/.claude/scripts/review-result.py list [--session SID] [--json]

THE PROBLEM (#267): a review agent's verdict and findings exist only as prose
in its final report. The subagent sidecar (`<session-dir>/subagents/agent-
<hex>.meta.json`) carries agentType, model, description, worktree — no
result. A Workflow run DOES persist a `result` in `<session-dir>/workflows/
wf_*.json`, but in whatever shape the script returned, so nothing is
queryable across runs. This script is the one schema, and the four commands
that produce, validate and read documents shaped by it.

THE SCHEMA (`schema` prints it; this is also the field-by-field reference the
skill text points at):

  verdict            required, enum: approve | request_changes | comment.
                      The reviewer's overall disposition.
  body_matches_tree   required, bool or null. True ONLY after the reviewer
                      compared the PR body's claims against the actual diff —
                      not merely read the body and found it plausible.
  findings            required, array. Every finding, in any order. Each:
    severity            required, enum: critical | suggestion | nitpick.
    title                required, string.
    file                 string or null.
    line                 integer or null.
    evidence             required, string — the command output or quoted
                          lines that support the finding. Not a restatement
                          of the title.
    mutation_ran         required, bool. True ONLY if the reviewer actually
                          RE-RAN the cited check or mutation in this review —
                          never true for a finding asserted from reading the
                          diff alone.
    red_line             required, bool. True when the finding is a hard
                          rule violation that no severity downgrade can
                          waive — a secret, missing/incorrect attribution
                          handling, a protected-branch bypass. Independent of
                          severity: a red_line finding can be filed at any
                          severity and still block.
  pr                  integer or null.
  repo                string or null.
  skill               string — which skill produced this (agent-review,
                      full-review, check-pr, …).
  round               integer or null — which review round this is, for a
                      skill that iterates (fix -> re-review).

Nothing here is enforced as a closed schema (unknown top-level keys are
tolerated); the required/typed fields above are what `validate` checks, and
every failure names its own path (`findings[2].severity: 'high' is not one
of [...]`).

WHERE A DOCUMENT COMES FROM: `validate`, `record` and `harvest` all accept
either a bare JSON document, or any text — typically a full agent report —
containing a fenced block that opens with the literal line
```json review-result
and closes with a bare ```. The fenced form is what a reviewing agent's
final report carries; the bare form is what a script or a re-piped
`.result.json`'s `result` value looks like.

WHAT `record` REFUSES TO GUESS
  * The session id comes from --session or $CLAUDE_CODE_SESSION_ID, in that
    order, and from nothing else — same discipline as session-seed.py's
    session-id resolution, for the same reason: a result attributed to no
    session, or to a scan's best guess, is worse than no result.
  * The session directory is resolved by globbing
    `~/.claude/projects/*/<sid>/`; anything other than exactly one match is a
    REFUSE, not a pick of the first (or newest) hit.
  * The agent must be real: neither `agent-<hex>.meta.json` nor
    `agent-<hex>.jsonl` existing under `<session-dir>/subagents/` is a
    REFUSE — a result must belong to an agent the harness actually spawned.
  * An existing `.result.json` is never silently overwritten; `--force` is
    required.
No REFUSE case writes anything — every check that can fail runs before the
file is opened for writing.

`harvest` is the fallback for agents whose orchestrator never ran `record`:
it scans `<session-dir>/subagents/agent-*.jsonl` transcripts that have no
`.result.json` yet, reads each one's LAST assistant message (transcript
lines also include `user` and `attachment` entries — ignored), looks for the
fenced block, and records what validates. It reports rather than crashes on
an invalid block, and keeps going.

`list` reads two sources IN PLACE and never copies either: every
`subagents/*.result.json` (written by `record` or `harvest`), and every
`workflows/wf_*.json` — the harness already persists a Workflow's `result`
there, in whatever shape the workflow script returned, so `list` walks that
value recursively (through dicts and lists alike) and reports every nested
dict that validates against the schema above, labelled `wf_<runId>` with a
path like `result[0].delta`. A Workflow-spawned agent does not get a
`subagents/` entry at all, which is why this recursive walk exists rather
than only globbing `.result.json` files.

Exit codes:
  schema            always 0.
  validate, record  0 the document is valid (record: and was written).
                     1 the document parsed but failed validation, OR (record
                       only) a REFUSE — session id unset, ambiguous/missing
                       session directory, unknown agent, or an existing
                       `.result.json` without --force. REFUSE lines are
                       prefixed `REFUSE: ` on stderr; nothing is written.
                     2 no fenced block was found and the input is not itself
                       valid JSON either (also: FILE could not be read).
  harvest, list     0 unless session-id/session-directory resolution REFUSEs
                     (1); harvest reports invalid blocks by agent id in its
                     summary line rather than failing the whole run.
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

VERDICTS = ("approve", "request_changes", "comment")
SEVERITIES = ("critical", "suggestion", "nitpick")

SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "review-result",
    "type": "object",
    "required": ["verdict", "body_matches_tree", "findings"],
    "properties": {
        "verdict": {
            "type": "string",
            "enum": list(VERDICTS),
            "description": "The reviewer's overall disposition.",
        },
        "body_matches_tree": {
            "type": ["boolean", "null"],
            "description": (
                "True only after comparing the PR body's claims against the "
                "actual diff, not merely reading the body and finding it "
                "plausible. Null when there was no PR body to check."
            ),
        },
        "findings": {
            "type": "array",
            "description": "Every finding the review produced, in any order.",
            "items": {
                "type": "object",
                "required": ["severity", "title", "evidence", "mutation_ran", "red_line"],
                "properties": {
                    "severity": {"type": "string", "enum": list(SEVERITIES)},
                    "title": {"type": "string"},
                    "file": {"type": ["string", "null"]},
                    "line": {"type": ["integer", "null"]},
                    "evidence": {
                        "type": "string",
                        "description": (
                            "The command output or quoted lines that support "
                            "this finding — not a restatement of the title."
                        ),
                    },
                    "mutation_ran": {
                        "type": "boolean",
                        "description": (
                            "True only if the reviewer actually re-ran the "
                            "cited check/mutation in this review, rather "
                            "than asserting it from reading."
                        ),
                    },
                    "red_line": {
                        "type": "boolean",
                        "description": (
                            "True when the finding is a hard rule violation "
                            "no severity downgrade can waive — a secret, "
                            "attribution, a protected-branch bypass."
                        ),
                    },
                },
            },
        },
        "pr": {"type": ["integer", "null"]},
        "repo": {"type": ["string", "null"]},
        "skill": {"type": "string"},
        "round": {"type": ["integer", "null"]},
    },
}

FENCE_RE = re.compile(r"```json review-result[ \t]*\r?\n(.*?)\r?\n```", re.DOTALL)
AGENT_HEX = re.compile(r"\A[0-9a-fA-F]+\Z")


def die(msg, code=1):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(code)


# ------------------------------------------------------------------ parsing

class ExtractError(Exception):
    def __init__(self, msg, code):
        super().__init__(msg)
        self.code = code


def extract_block(text):
    """The text inside the LAST ```json review-result fenced block, or None.

    The last one, not the first: a report that revises its own verdict
    mid-message (a draft block superseded by a final one) means the final
    block is the one that counts.
    """
    matches = FENCE_RE.findall(text)
    return matches[-1] if matches else None


def load_document(text):
    """A dict from TEXT: prefer a fenced review-result block, else treat the
    whole text as a bare JSON document. Raises ExtractError(code=2) when
    neither yields parseable JSON."""
    block = extract_block(text)
    if block is not None:
        try:
            return json.loads(block)
        except json.JSONDecodeError as e:
            raise ExtractError(
                "the fenced ```json review-result block is not valid JSON: %s" % e, 2)
    stripped = text.strip()
    if not stripped:
        raise ExtractError(
            "no ```json review-result block found, and the input is empty", 2)
    try:
        return json.loads(stripped)
    except json.JSONDecodeError as e:
        raise ExtractError(
            "no ```json review-result block found, and the whole input is "
            "not valid JSON either: %s" % e, 2)


def read_input(path):
    if not path or path == "-":
        return sys.stdin.read()
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        print("cannot read %s (%s)" % (path, e), file=sys.stderr)
        sys.exit(2)


# --------------------------------------------------------------- validation

def _type_name(v):
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    if v is None:
        return "null"
    return type(v).__name__


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _err(errors, path, msg):
    errors.append("%s: %s" % (path, msg))


def _validate_finding(item, i):
    errors = []
    path = "findings[%d]" % i
    if not isinstance(item, dict):
        _err(errors, path, "is a %s, not an object" % _type_name(item))
        return errors

    if "severity" not in item:
        _err(errors, path + ".severity", "is required")
    else:
        s = item["severity"]
        if not isinstance(s, str) or s not in SEVERITIES:
            _err(errors, path + ".severity", "%r is not one of %s" % (s, list(SEVERITIES)))

    if "title" not in item:
        _err(errors, path + ".title", "is required")
    elif not isinstance(item["title"], str):
        _err(errors, path + ".title", "%r is not a string" % (item["title"],))

    if "file" in item and item["file"] is not None and not isinstance(item["file"], str):
        _err(errors, path + ".file", "%r is not a string or null" % (item["file"],))

    if "line" in item and item["line"] is not None and not _is_int(item["line"]):
        _err(errors, path + ".line", "%r is not an integer or null" % (item["line"],))

    if "evidence" not in item:
        _err(errors, path + ".evidence", "is required")
    elif not isinstance(item["evidence"], str):
        _err(errors, path + ".evidence", "%r is not a string" % (item["evidence"],))

    if "mutation_ran" not in item:
        _err(errors, path + ".mutation_ran", "is required")
    elif not isinstance(item["mutation_ran"], bool):
        _err(errors, path + ".mutation_ran", "%r is not a boolean" % (item["mutation_ran"],))

    if "red_line" not in item:
        _err(errors, path + ".red_line", "is required")
    elif not isinstance(item["red_line"], bool):
        _err(errors, path + ".red_line", "%r is not a boolean" % (item["red_line"],))

    return errors


def validate_document(doc):
    """Every violation of SCHEMA, named by path. Empty list == valid."""
    errors = []
    if not isinstance(doc, dict):
        return ["$: document is a %s, not an object" % _type_name(doc)]

    if "verdict" not in doc:
        _err(errors, "verdict", "is required")
    else:
        v = doc["verdict"]
        if not isinstance(v, str) or v not in VERDICTS:
            _err(errors, "verdict", "%r is not one of %s" % (v, list(VERDICTS)))

    if "body_matches_tree" not in doc:
        _err(errors, "body_matches_tree", "is required")
    else:
        b = doc["body_matches_tree"]
        if not (b is None or isinstance(b, bool)):
            _err(errors, "body_matches_tree", "%r is not a boolean or null" % (b,))

    if "findings" not in doc:
        _err(errors, "findings", "is required")
    else:
        f = doc["findings"]
        if not isinstance(f, list):
            _err(errors, "findings", "%r is not an array" % (f,))
        else:
            for i, item in enumerate(f):
                errors.extend(_validate_finding(item, i))

    if "pr" in doc and doc["pr"] is not None and not _is_int(doc["pr"]):
        _err(errors, "pr", "%r is not an integer or null" % (doc["pr"],))
    if "repo" in doc and doc["repo"] is not None and not isinstance(doc["repo"], str):
        _err(errors, "repo", "%r is not a string or null" % (doc["repo"],))
    if "skill" in doc and doc["skill"] is not None and not isinstance(doc["skill"], str):
        _err(errors, "skill", "%r is not a string" % (doc["skill"],))
    if "round" in doc and doc["round"] is not None and not _is_int(doc["round"]):
        _err(errors, "round", "%r is not an integer or null" % (doc["round"],))

    return errors


def print_errors(errors):
    print("INVALID: %d error(s)" % len(errors), file=sys.stderr)
    for e in errors:
        print("  " + e, file=sys.stderr)


# --------------------------------------------------------- session / agent

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_session_id(explicit):
    """--session, then $CLAUDE_CODE_SESSION_ID, then REFUSE.

    Unlike session-seed.py's slug this is never truncated: it is used
    verbatim as the directory name under ~/.claude/projects/*/, and that
    directory is named with the harness's full session id.
    """
    sid = explicit if explicit else os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid or not sid.strip():
        die("this session has no id. Pass --session <id>, or run where the "
            "harness sets $CLAUDE_CODE_SESSION_ID. Nothing is written: a "
            "result attributed to no session cannot be filed under a "
            "session directory.")
    return sid.strip()


def resolve_session_dir(sid):
    pattern = os.path.join(os.path.expanduser("~/.claude/projects"), "*", glob.escape(sid))
    matches = sorted(p for p in glob.glob(pattern) if os.path.isdir(p))
    if len(matches) != 1:
        die("session directory for %r is not exactly one match under "
            "~/.claude/projects/*/%s (found %d) — cannot resolve where "
            "subagent results live" % (sid, sid, len(matches)))
    return matches[0]


def normalize_agent(raw):
    s = (raw or "").strip()
    hexpart = s[len("agent-"):] if s.startswith("agent-") else s
    if not hexpart or not AGENT_HEX.match(hexpart):
        die("--agent %r is not `agent-<hex>` or bare `<hex>`" % (raw,))
    return "agent-" + hexpart.lower()


def agent_exists(session_dir, agent_name):
    base = os.path.join(session_dir, "subagents", agent_name)
    return os.path.exists(base + ".meta.json") or os.path.exists(base + ".jsonl")


def atomic_write(path, text):
    """Write via a sibling temp file so a failure never leaves a truncated
    or half-written .result.json — same pattern as session-seed.py's."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die("could not write %s (%s)" % (path, e))


def build_wrapper(source, sid, agent_name, doc):
    return {
        "schema": 1,
        "source": source,
        "recorded_at": now_iso(),
        "session": sid,
        "agent": agent_name,
        "skill": doc.get("skill"),
        "pr": doc.get("pr"),
        "result": doc,
    }


# -------------------------------------------------------------- commands

def cmd_schema(a):
    print(json.dumps(SCHEMA, indent=2, sort_keys=False))
    return 0


def cmd_validate(a):
    text = read_input(a.file)
    try:
        doc = load_document(text)
    except ExtractError as e:
        print(str(e), file=sys.stderr)
        return e.code
    errors = validate_document(doc)
    if errors:
        print_errors(errors)
        return 1
    print("OK: review-result document is valid")
    return 0


def cmd_record(a):
    text = read_input(a.file)
    try:
        doc = load_document(text)
    except ExtractError as e:
        print(str(e), file=sys.stderr)
        return e.code
    errors = validate_document(doc)
    if errors:
        print_errors(errors)
        return 1

    agent_name = normalize_agent(a.agent)
    sid = resolve_session_id(a.session)
    session_dir = resolve_session_dir(sid)
    if not agent_exists(session_dir, agent_name):
        die("no %s.meta.json or .jsonl under %s/subagents/ — a result must "
            "belong to an agent the harness actually spawned"
            % (agent_name, session_dir))

    if a.pr is not None:
        doc["pr"] = a.pr
    if a.skill:
        doc["skill"] = a.skill

    result_path = os.path.join(session_dir, "subagents", "%s.result.json" % agent_name)
    if os.path.exists(result_path) and not a.force:
        die("%s already exists — pass --force to overwrite" % result_path)

    wrapper = build_wrapper("record", sid, agent_name, doc)
    atomic_write(result_path, json.dumps(wrapper, indent=2, ensure_ascii=False) + "\n")
    print("result: %s" % os.path.abspath(result_path))
    return 0


def last_assistant_text(jsonl_path):
    """The concatenated text blocks of the LAST `type == "assistant"` line in
    a subagent transcript, or None. Streamed line by line — only the most
    recent matching object is ever held in memory, never the whole file."""
    last = None
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict) and obj.get("type") == "assistant":
                    last = obj
    except OSError:
        return None
    if last is None:
        return None
    content = (last.get("message") or {}).get("content") or []
    if not isinstance(content, list):
        return None
    parts = [b.get("text", "") for b in content
             if isinstance(b, dict) and b.get("type") == "text"]
    text = "\n".join(p for p in parts if p)
    return text or None


def cmd_harvest(a):
    sid = resolve_session_id(a.session)
    session_dir = resolve_session_dir(sid)
    recorded = skipped = noblock = invalid = 0

    for jsonl_path in sorted(glob.glob(os.path.join(session_dir, "subagents", "agent-*.jsonl"))):
        base = jsonl_path[:-len(".jsonl")]
        agent_name = os.path.basename(base)
        result_path = base + ".result.json"
        if os.path.exists(result_path):
            skipped += 1
            continue

        text = last_assistant_text(jsonl_path)
        block = extract_block(text) if text else None
        if block is None:
            noblock += 1
            continue

        try:
            doc = json.loads(block)
        except json.JSONDecodeError as e:
            print("invalid: %s: block is not valid JSON (%s)" % (agent_name, e), file=sys.stderr)
            invalid += 1
            continue

        errors = validate_document(doc)
        if errors:
            print("invalid: %s:" % agent_name, file=sys.stderr)
            for e in errors:
                print("  " + e, file=sys.stderr)
            invalid += 1
            continue

        wrapper = build_wrapper("harvest", sid, agent_name, doc)
        if a.dry_run:
            print("would record: %s" % result_path)
        else:
            atomic_write(result_path, json.dumps(wrapper, indent=2, ensure_ascii=False) + "\n")
            print("result: %s" % os.path.abspath(result_path))
        recorded += 1

    print("recorded %d, skipped-existing %d, no-block %d, invalid %d"
          % (recorded, skipped, noblock, invalid))
    return 0


def _walk_for_results(value, path, hits):
    """Every dict reachable from VALUE (through dicts and lists alike) that
    validates against the schema, labelled with its access path. Does not
    descend further into a dict once it has matched — a finding is a dict
    too, but it can never independently match the top-level required set
    (verdict/body_matches_tree/findings), so this is a safety margin, not
    something load-bearing."""
    if isinstance(value, dict):
        if not validate_document(value):
            hits.append((path, value))
            return
        for k, v in value.items():
            _walk_for_results(v, "%s.%s" % (path, k), hits)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _walk_for_results(v, "%s[%d]" % (path, i), hits)


def build_row(id_, skill, pr, result, source):
    findings = result.get("findings") or []
    counts = {"critical": 0, "suggestion": 0, "nitpick": 0}
    mutated = 0
    for f in findings:
        if isinstance(f, dict):
            if f.get("severity") in counts:
                counts[f.get("severity")] += 1
            if f.get("mutation_ran") is True:
                mutated += 1
    return {
        "id": id_,
        "skill": skill,
        "pr": pr,
        "verdict": result.get("verdict"),
        "critical": counts["critical"],
        "suggestion": counts["suggestion"],
        "nitpick": counts["nitpick"],
        "mutation_ran": mutated,
        "findings_total": len(findings),
        "body_matches_tree": result.get("body_matches_tree"),
        "source": source,
    }


def print_table(rows):
    headers = ["AGENT/RUN", "SKILL", "PR", "VERDICT", "CRIT", "SUGG", "NIT", "MUT/TOTAL", "BODY", "SOURCE"]

    def fmt(r):
        body = "—" if r["body_matches_tree"] is None else str(r["body_matches_tree"]).lower()
        return [
            str(r["id"]),
            str(r["skill"]) if r["skill"] else "—",
            str(r["pr"]) if r["pr"] is not None else "—",
            str(r["verdict"]) if r["verdict"] else "—",
            str(r["critical"]),
            str(r["suggestion"]),
            str(r["nitpick"]),
            "%d/%d" % (r["mutation_ran"], r["findings_total"]),
            body,
            str(r["source"]),
        ]

    table = [headers] + [fmt(r) for r in rows]
    if len(table) == 1:
        print("(no results)")
        return
    widths = [max(len(row[i]) for row in table) for i in range(len(headers))]
    for row in table:
        print("  ".join(cell.ljust(w) for cell, w in zip(row, widths)))


def cmd_list(a):
    sid = resolve_session_id(a.session)
    session_dir = resolve_session_dir(sid)
    rows = []

    for path in sorted(glob.glob(os.path.join(session_dir, "subagents", "*.result.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                wrapper = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            print("warning: skipping unreadable %s (%s)" % (path, e), file=sys.stderr)
            continue
        result = wrapper.get("result") if isinstance(wrapper, dict) else None
        if not isinstance(result, dict) or validate_document(result):
            print("warning: %s does not carry a valid review-result — skipped" % path, file=sys.stderr)
            continue
        pr = wrapper.get("pr") if wrapper.get("pr") is not None else result.get("pr")
        skill = wrapper.get("skill") or result.get("skill")
        rows.append(build_row(
            wrapper.get("agent") or os.path.basename(path), skill, pr, result,
            wrapper.get("source", "record")))

    for path in sorted(glob.glob(os.path.join(session_dir, "workflows", "wf_*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                wf = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            print("warning: skipping unreadable %s (%s)" % (path, e), file=sys.stderr)
            continue
        run_id = wf.get("runId") if isinstance(wf, dict) else None
        run_id = run_id or os.path.splitext(os.path.basename(path))[0]
        hits = []
        _walk_for_results(wf.get("result") if isinstance(wf, dict) else None, "result", hits)
        for wpath, result in hits:
            rows.append(build_row(
                "%s %s" % (run_id, wpath), result.get("skill"), result.get("pr"),
                result, "workflow"))

    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        print_table(rows)
    return 0


# ------------------------------------------------------------------ main

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="review-result.py", description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("schema", help="print the review-result JSON schema").set_defaults(fn=cmd_schema)

    v = sub.add_parser("validate", help="validate a document or a fenced review-result block")
    v.add_argument("file", nargs="?", help="path to read, or omit/`-` for stdin")
    v.set_defaults(fn=cmd_validate)

    r = sub.add_parser("record", help="validate and write <session-dir>/subagents/agent-<hex>.result.json")
    r.add_argument("file", nargs="?", help="path to read, or omit/`-` for stdin")
    r.add_argument("--agent", required=True, help="agent-<hex> or bare <hex>")
    r.add_argument("--skill", required=True, help="skill name; overrides the document's own `skill`")
    r.add_argument("--pr", type=int, help="PR number; overrides the document's own `pr`")
    r.add_argument("--session", help="this session's id (default: $CLAUDE_CODE_SESSION_ID)")
    r.add_argument("--force", action="store_true", help="overwrite an existing .result.json")
    r.set_defaults(fn=cmd_record)

    h = sub.add_parser("harvest", help="fallback capture from subagent transcripts missing a .result.json")
    h.add_argument("--session", help="this session's id (default: $CLAUDE_CODE_SESSION_ID)")
    h.add_argument("--dry-run", action="store_true", help="report what would be recorded; write nothing")
    h.set_defaults(fn=cmd_harvest)

    l = sub.add_parser("list", help="one row per recorded, harvested, or workflow-embedded result")
    l.add_argument("--session", help="this session's id (default: $CLAUDE_CODE_SESSION_ID)")
    l.add_argument("--json", action="store_true", help="emit the rows as JSON instead of a table")
    l.set_defaults(fn=cmd_list)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
