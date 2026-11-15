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

REFUSALS (exit 2, nothing written): no session id (--session, then
$CLAUDE_CODE_SESSION_ID, never guessed); channel=relay without --relay-via;
relay_via given with channel=direct; a control character or newline in any
field; a credential-shaped value anywhere; a malformed timestamp or pin; a
duplicate id; a --supersedes naming an id not in the ledger.

This script runs no git. Committing stays the writer's job: after a write it
prints the exact `git -C <vault> add -- <p>` and `commit -m <m> -- <p>` lines.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_LEDGER = "~/Obsidian/no-it-all/ledgers/decisions.jsonl"
TS_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
PIN_KEY = re.compile(r"\A[A-Za-z_][A-Za-z0-9_.-]*\Z")
SECRET = re.compile(
    r"(?:\bgh[pousr]_[A-Za-z0-9]{16,}"
    r"|\bgithub_pat_[A-Za-z0-9_]{16,}"
    r"|\bsk-[A-Za-z0-9_-]{16,}"
    r"|\bxox[abprso]-[A-Za-z0-9-]{8,}"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\bBearer\s+[A-Za-z0-9._~+/=-]{20,})"
)


def die(msg):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(2)


def now_utc():
    return datetime.now(timezone.utc).strftime(TS_FORMAT)


def check_ts(value, field):
    try:
        datetime.strptime(value, TS_FORMAT)
    except ValueError:
        die("%s %r is not a UTC timestamp of the form YYYY-MM-DDTHH:MM:SSZ" % (field, value))
    return value


def clean(value, field):
    if CONTROL.search(value):
        die("%s contains a newline or control character; single-line fields only" % field)
    if SECRET.search(value):
        die("%s looks like a credential; a decision record never carries one" % field)
    return value


def resolve_session(explicit):
    sid = explicit if explicit is not None else os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid is None or not sid.strip():
        die("this session has no id. Pass --session <id>, or run where the harness sets "
            "$CLAUDE_CODE_SESSION_ID. Nothing is written: an unattributed decision is not a record.")
    return clean(sid.strip(), "session")


def resolve_scope(explicit):
    if explicit:
        return clean(explicit, "scope")
    seed = os.path.join(os.path.dirname(os.path.abspath(__file__)), "session-seed.py")
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


def read_ledger(path):
    """Every decision record in the ledger. Missing file is empty; a bad line is a REFUSE."""
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    die("%s line %d is not JSON; refusing to read past a corrupted ledger" % (path, n))
                if isinstance(obj, dict) and obj.get("kind") == "decision-record":
                    out.append(obj)
    except FileNotFoundError:
        return []
    except OSError as e:
        die("cannot read %s: %s" % (path, e))
    return out


def decision_id(scope, received_at, decided_by, question, answer):
    canon = json.dumps([scope, received_at, decided_by, question, answer], ensure_ascii=False)
    return "dec-" + hashlib.sha256(canon.encode("utf-8")).hexdigest()[:12]


def build_record(a):
    sid = resolve_session(a.session)
    scope = resolve_scope(a.scope)
    received = check_ts(a.received_at, "received_at") if a.received_at else now_utc()
    decided_by = clean(a.decided_by, "decided_by")
    channel = a.channel
    relay_via = clean(a.relay_via, "relay_via") if a.relay_via else None
    if channel == "relay" and not relay_via:
        die("channel=relay requires --relay-via (who carried the answer)")
    if channel == "direct" and relay_via:
        die("--relay-via given with channel=direct")
    question = clean(a.question, "question")
    answer = clean(a.answer_verbatim, "answer_verbatim")
    if not question.strip() or not answer.strip():
        die("question and answer_verbatim must not be empty")
    pins = {}
    for p in a.pin:
        clean(p, "pin")
        k, sep, v = p.partition("=")
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
        "supersedes": clean(a.supersedes, "supersedes") if a.supersedes else None,
        "session": sid,
        "recorded_at": now_utc(),
    }


def append_locked(path, record):
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    lock = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing = read_ledger(path)
        if any(r.get("id") == record["id"] for r in existing):
            die("decision %s is already in %s" % (record["id"], path))
        sup = record["supersedes"]
        if sup and not any(r.get("id") == sup for r in existing):
            die("--supersedes %s is not in %s" % (sup, path))
        line = (json.dumps(record, ensure_ascii=False, sort_keys=False) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)


def cmd_add(a):
    record = build_record(a)
    path = ledger_path(a)
    append_locked(path, record)
    print("decision: %s %s" % (record["id"], path))
    d = os.path.dirname(os.path.abspath(path))
    p = os.path.basename(path)
    print("commit this in the vault repo that holds the ledger, if it is one:")
    print("  git -C %s add -- %s" % (d, p))
    print("  git -C %s commit -m 'chore(decisions): record %s' -- %s" % (d, record["id"], p))


def cmd_list(a):
    since = check_ts(a.since, "--since") if a.since else None
    rows = read_ledger(ledger_path(a))
    if a.scope:
        rows = [r for r in rows if r.get("scope") == a.scope]
    if since:
        rows = [r for r in rows if str(r.get("received_at", "")) >= since]
    if a.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    for r in rows:
        via = " via %s" % r["relay_via"] if r.get("relay_via") else ""
        print("%s  %s  %s  %s%s  %s" % (r.get("id"), r.get("received_at"), r.get("scope"),
                                       r.get("channel"), via, r.get("answer_verbatim")))


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
