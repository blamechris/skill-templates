#!/usr/bin/env python3
"""Report-only check: is a handoff seed older than something that happened after it?

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/seed-freshness.py ~/.claude/scripts/
# Needs session-seed.py and decision-record.py beside it; the seed grammar and timestamp parsing
# are loaded from them by path, never restated.

Usage:
  seed-freshness.py [--scope S] [--json] [--decision-ledger PATH] [--pr-ledger PATH]

For each canonical seed `NEXT-<scope>.md` in $CLAUDE_HANDOFF_DIR (default dir
from session-seed.py), or the single --scope, prints `FRESH <scope>` or
`STALE <scope> <reason>`. A seed is STALE when, after its `date`:
  decision      a decision record for that scope was received
                (decision-record.py ledger: --decision-ledger, then
                $CLAUDE_DECISION_LEDGER, then its default);
  pr-record     a pr-record whose repo basename equals the scope, or whose
                session.id starts with the seed's `session`, was recorded or
                merged (--pr-ledger, then $CLAUDE_PR_LEDGER, then default);
  owner-ask     its `picks_up_at` contains `OWNER:` and a decision above
                holds: the seed asks the owner for something a later
                decision may have answered.

SEED DATE RESOLUTION: session-seed.py writes `date` at minute resolution. When
the seed file's mtime falls inside that same UTC minute it is the exact write
instant. Otherwise a date without seconds is treated as ending at the END of
that minute, so an event earlier in the same minute (the normal flow: record
the decision, then write the seed) is not STALE; tradeoff: an event in that
minute after the write is then missed, a false-FRESH window of under 60
seconds. A date that carries seconds is used exactly. Comparisons keep full
(microsecond) precision.

Session ids: only UUID-shaped ids (full, or the canonical 8-character prefix)
are lowercased; any other id is compared case-sensitively, and a seed session
shorter than 8 characters must match exactly, never as a prefix.

CORRUPTION POLICY (same as decision-record.py): a malformed ledger line,
invalid UTF-8, a non-object row, a pr_meta/session that is not an object, or
an event that cannot be dated is skipped and reported with its line number on
stderr; every computable verdict is still printed; the exit is 2 at the end.

Exit 0 on a completed check with no input errors, whatever it found. Exit 2 on
a usage error or any unreadable input. It never writes, renames or commits
anything.
"""
import argparse
import json
import os
import re
import runpy
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DECISIONS = "~/Obsidian/no-it-all/ledgers/decisions.jsonl"
DEFAULT_PRS = "~/Obsidian/no-it-all/ledgers/pr-records.jsonl"
UUID_SHAPED = re.compile(r"\A[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?\Z")


class Usage(Exception):
    pass


def load(name):
    path = os.path.join(HERE, name)
    if not os.path.isfile(path):
        raise Usage("%s not found beside %s" % (name, os.path.basename(__file__)))
    return runpy.run_path(path)


def read_prs(dr, path):
    """Usable pr-records: dict pr_meta/session (or null) and a datable stamp."""
    rows, errors = dr["read_jsonl"](path, "pr-record")
    good = []
    for n, r in rows:
        meta, sess = r.get("pr_meta"), r.get("session")
        bad = None
        if meta is not None and not isinstance(meta, dict):
            bad = "pr_meta is not an object"
        elif sess is not None and not isinstance(sess, dict):
            bad = "session is not an object"
        else:
            stamps = [dr["parse_ts"](r.get("recorded_at"))]
            if meta and meta.get("merged_at") is not None:
                stamps.append(dr["parse_ts"](meta.get("merged_at")))
            if any(t is None for t in stamps):
                bad = "recorded_at or merged_at is missing or not a timestamp"
        if bad:
            errors.append("%s line %d: pr-record %s: %s" % (path, n, r.get("pr"), bad))
        else:
            good.append(r)
    return good, errors


def norm_sid(sid):
    """Lowercase only UUID-shaped ids (full, or the canonical 8-character prefix);
    any other id is compared case-sensitively."""
    sid = str(sid or "").strip()
    return sid.lower() if UUID_SHAPED.match(sid) else sid


def same_session(seed_sid, record_sid):
    """The seed names a session by its id or by a UUID's 8-character prefix. A seed id
    shorter than 8 characters must match exactly, never as a prefix."""
    if not seed_sid or seed_sid == "unknown":
        return False
    if len(seed_sid) < 8:
        return record_sid == seed_sid
    return record_sid.startswith(seed_sid)


def check_seed(dr, scope, fm, decisions, prs, mtime=None):
    parse = dr["parse_ts"]
    seed_date, has_seconds = parse(fm.get("date", ""), with_precision=True)
    if seed_date is None:
        raise Usage("seed for %s has no parseable date: %r" % (scope, fm.get("date")))
    if has_seconds:
        wrote, exact = seed_date, True
    else:
        try:
            end = seed_date + timedelta(minutes=1)
        except OverflowError:
            raise Usage("seed for %s has an out-of-range date: %r" % (scope, fm.get("date")))
        # The file's mtime is the real write instant when it falls inside the seed's
        # own minute; otherwise fall back to the end of that minute.
        if mtime is not None and seed_date <= mtime < end:
            wrote, exact = mtime, True
        else:
            wrote, exact = end, False

    def after(t):
        return t > wrote if exact else t >= wrote

    reasons = []
    later = [d for d in decisions if d["scope"] == scope and after(parse(d["received_at"]))]
    if later:
        reasons.append({"code": "decision", "detail":
                        "decision received after the seed was written (%s)" % ", ".join(d["id"] for d in later)})
    sid = norm_sid(fm.get("session"))
    for r in prs:
        repo = str(r.get("repo") or "")
        rsid = norm_sid((r.get("session") or {}).get("id"))
        if repo.split("/")[-1] != scope and not same_session(sid, rsid):
            continue
        stamps = [parse(r.get("recorded_at")), parse((r.get("pr_meta") or {}).get("merged_at"))]
        if any(t and after(t) for t in stamps):
            reasons.append({"code": "pr-record", "detail":
                            "PR %s of %s recorded or merged after the seed was written" % (r.get("pr"), repo)})
    if "OWNER:" in (fm.get("picks_up_at") or "") and later:
        reasons.append({"code": "owner-ask", "detail":
                        "seed asks the owner for something a later decision may have answered"})
    return reasons


def main(argv=None):
    p = argparse.ArgumentParser(prog="seed-freshness.py", description=__doc__.split("\n")[0])
    p.add_argument("--scope")
    p.add_argument("--json", action="store_true")
    p.add_argument("--decision-ledger")
    p.add_argument("--pr-ledger")
    try:
        a = p.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    errors = []
    try:
        mod = load("session-seed.py")
        dr = load("decision-record.py")
        directory = mod["handoff_dir"]()
    except SystemExit:
        print("error: cannot resolve the handoff dir", file=sys.stderr)
        return 2
    except Usage as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
    dpath = os.path.expanduser(a.decision_ledger or os.environ.get("CLAUDE_DECISION_LEDGER") or DEFAULT_DECISIONS)
    ppath = os.path.expanduser(a.pr_ledger or os.environ.get("CLAUDE_PR_LEDGER") or DEFAULT_PRS)
    decisions, e1 = dr["read_decisions"](dpath)
    prs, e2 = read_prs(dr, ppath)
    errors += e1 + e2

    if a.scope:
        names = ["NEXT-%s.md" % a.scope]
        if not os.path.isfile(os.path.join(directory, names[0])):
            print("error: no seed %s" % os.path.join(directory, names[0]), file=sys.stderr)
            return 2
    else:
        try:
            names = sorted(n for n in os.listdir(directory)
                           if n.startswith("NEXT-") and n.endswith(".md")
                           and not mod["ARCHIVE_SUFFIX"].search(n))
        except FileNotFoundError:
            names = []
        except OSError as e:
            print("error: cannot read %s: %s" % (directory, e), file=sys.stderr)
            return 2

    results = []
    for n in names:
        scope = n[len("NEXT-"):-len(".md")]
        path = os.path.join(directory, n)
        try:
            with open(path, encoding="utf-8") as f:
                fm = mod["parse_frontmatter"](f.read())
            mtime = datetime.fromtimestamp(os.stat(path).st_mtime, timezone.utc)
            reasons = check_seed(dr, scope, fm, decisions, prs, mtime)
        except (OSError, UnicodeDecodeError, Usage) as e:
            errors.append("%s: %s" % (path, e))
            continue
        results.append({"scope": scope, "status": "STALE" if reasons else "FRESH", "reasons": reasons})

    if a.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            if r["status"] == "FRESH":
                print("FRESH %s" % r["scope"])
            else:
                print("STALE %s %s" % (r["scope"], "; ".join(x["detail"] for x in r["reasons"])))
    for e in errors:
        print("error: %s" % e, file=sys.stderr)
    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
