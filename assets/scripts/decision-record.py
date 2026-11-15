#!/usr/bin/env python3
"""Durable record of owner decisions: one JSON line per decision.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/decision-record.py ~/.claude/scripts/

Usage:
  decision-record.py add --question Q --answer-verbatim A
      [--scope S] [--session SID] [--received-at UTC] [--decided-by NAME]
      [--channel direct|relay] [--relay-via NAME] [--authorizes ITEM ...]
      [--limit ITEM ...] [--pin KEY=VALUE ...] [--ref URL ...]
      [--supersedes ID] [--ledger PATH]
  decision-record.py list [--scope S] [--since UTC] [--json] [--ledger PATH]

THE PROBLEM: an owner decision arrives in chat mid-package, direct or relayed
by another agent, and nothing writes it down. The plan, the seed and the
decision fields then lag what was approved, and a seed can go on asking for a
choice that was already made. Merges already have a ledger (pr-record.py);
decisions had no equivalent. Read docs/decision-record-shape.md for the design.

THE RECORD (schema_version 1): kind, schema_version, id, scope, received_at,
decided_by, channel, relay_via, question, answer_verbatim, authorizes[],
limits[], pins{}, refs[], supersedes, session, recorded_at.

LEDGER: default ~/Obsidian/no-it-all/ledgers/decisions.jsonl; --ledger, then
$CLAUDE_DECISION_LEDGER, then the default. The parent directory is created.
The append runs under an exclusive fcntl.flock on a sidecar `<ledger>.lock`
file and is one O_APPEND write of one line, so racing writers never interleave.

REFUSALS (exit 2, nothing written, ledger bytes unchanged): no session id
(--session, then $CLAUDE_CODE_SESSION_ID, never guessed); channel=relay
without --relay-via; relay_via given with channel=direct; an empty or
whitespace-only required field; a control character, newline, U+2028, U+2029
or U+0085 in any field (checked on the RAW value, before trimming); a
credential-shaped value anywhere (a HEURISTIC backstop, not a guarantee and
not a license to paste secrets); a malformed timestamp or pin; a duplicate id;
a --supersedes naming an id not in the ledger; a ledger path inside one of
this session's repo worktrees (the ledger is private and lives in the vault).

TIMESTAMPS: every accepted timestamp (offsets included) is normalized to
canonical UTC `YYYY-MM-DDTHH:MM:SSZ` before it is stored and hashed.

CORRUPTION POLICY (shared with seed-freshness.py): a malformed ledger line,
invalid UTF-8, or a row that cannot be dated is skipped and reported with its
line number on stderr; every computable result is still produced; `list` then
exits 2. `add` repairs a missing final newline, appends safely, warns about
the bad lines it saw and exits 0. One bad line never bricks list or add.

This script runs no git. Committing stays the writer's job: after a write it
prints the exact `git -C <vault> add -- <p>` and `commit -m <m> -- <p>` lines.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import runpy
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_LEDGER = "~/Obsidian/no-it-all/ledgers/decisions.jsonl"
TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
CONTROL = re.compile("[\x00-\x1f\x7f\u0085\u2028\u2029]")
PIN_KEY = re.compile(r"\A[A-Za-z_][A-Za-z0-9_.-]*\Z")
TS_LOOSE = re.compile(
    r"\A(\d{4})-(\d{1,2})-(\d{1,2})[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.\d+)?)?"
    r"(Z|[+-]\d{2}:?\d{2})\Z")
SECRET = re.compile(
    r"(?:\bgh[pousr]_[A-Za-z0-9]{16,}"
    r"|\bgithub_pat_[A-Za-z0-9_]{16,}"
    r"|\bsk-[A-Za-z0-9_-]{16,}"
    r"|\b[sr]k_(?:live|test)_[A-Za-z0-9]{8,}"
    r"|\bpk_live_[A-Za-z0-9]{8,}"
    r"|\bxox[abprso]-[A-Za-z0-9-]{8,}"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"
    r"|\b(?:password|secret|token|api[_-]?key)\s*[:=]\s*\S+)",
    re.IGNORECASE,
)
HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(2)


def now_utc():
    return datetime.now(timezone.utc).strftime(TS_FORMAT)


def parse_ts(value, with_precision=False):
    """A timestamp as an aware UTC datetime, or None. Accepts a trailing Z or an
    offset, optional seconds, unpadded fields. With with_precision, returns
    (datetime, had_seconds) so a minute-resolution value can be told apart."""
    m = TS_LOOSE.match(value) if isinstance(value, str) else None
    if not m:
        return (None, False) if with_precision else None
    y, mo, d, h, mi, sec, tz = m.groups()
    try:
        dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(sec or 0), tzinfo=timezone.utc)
        if tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            digits = tz[1:].replace(":", "")
            dt -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    except (ValueError, OverflowError):
        return (None, False) if with_precision else None
    return (dt, sec is not None) if with_precision else dt


def canon_ts(value, field):
    dt = parse_ts(value)
    if dt is None:
        die("%s %r is not a UTC timestamp (YYYY-MM-DDTHH:MM[:SS]Z or with an offset)" % (field, value))
    return dt.strftime(TS_FORMAT)


def clean(value, field, required=True):
    """Validate the RAW value (before any trimming), then return it stripped."""
    if CONTROL.search(value):
        die("%s contains a newline or control character; single-line fields only" % field)
    if SECRET.search(value):
        die("%s looks like a credential; a decision record never carries one" % field)
    value = value.strip()
    if required and not value:
        die("%s must not be empty" % field)
    return value


def resolve_session(explicit):
    sid = explicit if explicit is not None else os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid is None or not sid.strip():
        die("this session has no id. Pass --session <id>, or run where the harness sets "
            "$CLAUDE_CODE_SESSION_ID. Nothing is written: an unattributed decision is not a record.")
    return clean(sid, "session")


def resolve_scope(explicit):
    if explicit:
        return clean(explicit, "scope")
    seed = os.path.join(HERE, "session-seed.py")
    try:
        out = subprocess.run([sys.executable, seed, "scope"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        die("cannot derive the scope (%s); pass --scope" % e)
    scope = out.stdout.strip()
    if out.returncode != 0 or not scope:
        die("session-seed.py scope failed; pass --scope. %s" % out.stderr.strip())
    return clean(scope, "scope")


def ledger_path(args):
    return os.path.expanduser(args.ledger or os.environ.get("CLAUDE_DECISION_LEDGER") or DEFAULT_LEDGER)


def refuse_in_worktree(path):
    """The ledger is private. Reuse session-seed.py's worktree-roots logic, loaded
    by path, rather than restating it."""
    seed = os.path.join(HERE, "session-seed.py")
    if not os.path.isfile(seed):
        die("session-seed.py not found beside this script; cannot prove the ledger is outside the worktrees")
    mod = runpy.run_path(seed)
    for root in mod["_worktree_roots"]():
        if mod["_is_under"](path, root):
            die("ledger %s is inside the worktree %s; the ledger is private and belongs in the vault" % (path, root))


def read_jsonl(path, kind):
    """(rows, errors): rows are (line_number, dict) of the given kind; errors are
    line-numbered strings. Never raises on content: invalid UTF-8 and malformed
    JSON are per-line errors. A missing file is empty."""
    rows, errors = [], []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return rows, errors
    except OSError as e:
        return rows, ["%s: cannot read: %s" % (path, e)]
    for n, bline in enumerate(raw.split(b"\n"), 1):
        if not bline.strip():
            continue
        try:
            obj = json.loads(bline.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            errors.append("%s line %d: unreadable (%s)" % (path, n, type(e).__name__))
            continue
        if not isinstance(obj, dict):
            errors.append("%s line %d: not a JSON object" % (path, n))
        elif obj.get("kind") == kind:
            rows.append((n, obj))
    return rows, errors


def read_decisions(path):
    """Decision records that are usable: an id, a scope and a datable received_at.
    A row that cannot be dated is an error, never silently 'nothing happened'."""
    rows, errors = read_jsonl(path, "decision-record")
    good = []
    for n, r in rows:
        if not isinstance(r.get("id"), str) or not isinstance(r.get("scope"), str):
            errors.append("%s line %d: decision record without a text id and scope" % (path, n))
        elif parse_ts(r.get("received_at")) is None:
            errors.append("%s line %d: decision record %s has no parseable received_at" % (path, n, r["id"]))
        else:
            good.append(r)
    return good, errors


def decision_id(scope, received_at, decided_by, question, answer):
    canon = json.dumps([scope, received_at, decided_by, question, answer], ensure_ascii=False)
    return "dec-" + hashlib.sha256(canon.encode("utf-8")).hexdigest()[:12]


def build_record(a):
    sid = resolve_session(a.session)
    scope = resolve_scope(a.scope)
    received = canon_ts(a.received_at, "received_at") if a.received_at else now_utc()
    decided_by = clean(a.decided_by, "decided_by")
    channel = a.channel
    relay_via = clean(a.relay_via, "relay_via") if a.relay_via is not None else None
    if channel == "relay" and not relay_via:
        die("channel=relay requires --relay-via (who carried the answer)")
    if channel == "direct" and relay_via:
        die("--relay-via given with channel=direct")
    question = clean(a.question, "question")
    answer = clean(a.answer_verbatim, "answer_verbatim")
    pins = {}
    for p in a.pin:
        k, sep, v = clean(p, "pin").partition("=")
        if not sep or not PIN_KEY.match(k) or not v:
            die("pin %r is not key=value" % p)
        pins[k] = v
    return {
        "kind": "decision-record",
        "schema_version": 1,
        "id": decision_id(scope, received, decided_by, question, answer),
        "scope": scope,
        "received_at": received,
        "decided_by": decided_by,
        "channel": channel,
        "relay_via": relay_via,
        "question": question,
        "answer_verbatim": answer,
        "authorizes": [clean(x, "authorizes") for x in a.authorizes],
        "limits": [clean(x, "limits") for x in a.limit],
        "pins": pins,
        "refs": [clean(x, "refs") for x in a.ref],
        "supersedes": clean(a.supersedes, "supersedes") if a.supersedes is not None else None,
        "session": sid,
        "recorded_at": now_utc(),
    }


def append_locked(path, record):
    """Append one whole line under an exclusive lock. A last record missing its
    newline is preserved by prepending one; a short write is continued until the
    whole line is down; any write error truncates back to the pre-append size."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lock = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing, errors = read_decisions(path)
        for e in errors:
            print("warning: %s" % e, file=sys.stderr)
        if any(r.get("id") == record["id"] for r in existing):
            die("decision %s is already in %s" % (record["id"], path))
        sup = record["supersedes"]
        if sup and not any(r.get("id") == sup for r in existing):
            die("--supersedes %s is not in %s" % (sup, path))
        data = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            size = os.fstat(fd).st_size
            try:
                if size and os.pread(fd, 1, size - 1) != b"\n":
                    data = b"\n" + data
                done = 0
                while done < len(data):
                    n = os.write(fd, data[done:])
                    if n <= 0:
                        raise OSError("write returned %d" % n)
                    done += n
                os.fsync(fd)
            except OSError as e:
                try:
                    os.ftruncate(fd, size)
                except OSError:
                    pass
                die("write to %s failed (%s); the ledger was restored" % (path, e))
        finally:
            os.close(fd)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)


def cmd_add(a):
    record = build_record(a)
    path = ledger_path(a)
    refuse_in_worktree(os.path.abspath(path))
    append_locked(path, record)
    print("decision: %s %s" % (record["id"], path))
    d = os.path.dirname(os.path.abspath(path))
    p = os.path.basename(path)
    print("commit this in the vault repo that holds the ledger, if it is one:")
    print("  " + shlex.join(["git", "-C", d, "add", "--", p]))
    print("  " + shlex.join(["git", "-C", d, "commit", "-m", "chore(decisions): record %s" % record["id"], "--", p]))


def cmd_list(a):
    since = None
    if a.since:
        since = parse_ts(a.since)
        if since is None:
            die("--since %r is not a UTC timestamp" % a.since)
    rows, errors = read_decisions(ledger_path(a))
    if a.scope:
        rows = [r for r in rows if r.get("scope") == a.scope]
    if since:
        rows = [r for r in rows if parse_ts(r["received_at"]) >= since]
    if a.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
    else:
        for r in rows:
            via = " via %s" % r["relay_via"] if r.get("relay_via") else ""
            print("%s  %s  %s  %s%s  %s" % (r.get("id"), r.get("received_at"), r.get("scope"),
                                           r.get("channel"), via, r.get("answer_verbatim")))
    for e in errors:
        print("error: %s" % e, file=sys.stderr)
    if errors:
        sys.exit(2)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print("REFUSE: " + message, file=sys.stderr)
        sys.exit(2)


def main(argv=None):
    p = Parser(prog="decision-record.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    add = sub.add_parser("add")
    add.add_argument("--question", required=True)
    add.add_argument("--answer-verbatim", required=True)
    add.add_argument("--scope")
    add.add_argument("--session")
    add.add_argument("--received-at")
    add.add_argument("--decided-by", default="Chris")
    add.add_argument("--channel", choices=("direct", "relay"), default="direct")
    add.add_argument("--relay-via")
    add.add_argument("--authorizes", action="append", default=[])
    add.add_argument("--limit", action="append", default=[])
    add.add_argument("--pin", action="append", default=[])
    add.add_argument("--ref", action="append", default=[])
    add.add_argument("--supersedes")
    add.add_argument("--ledger")
    add.set_defaults(fn=cmd_add)
    ls = sub.add_parser("list")
    ls.add_argument("--scope")
    ls.add_argument("--since")
    ls.add_argument("--json", action="store_true")
    ls.add_argument("--ledger")
    ls.set_defaults(fn=cmd_list)
    a = p.parse_args(argv)
    a.fn(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
