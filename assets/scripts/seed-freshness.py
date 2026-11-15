#!/usr/bin/env python3
"""Report-only check: is a handoff seed older than something that happened after it?

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/seed-freshness.py ~/.claude/scripts/
# Needs session-seed.py beside it; the seed grammar is loaded from there, never restated.

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

Exit 0 on a completed check, whatever it found. Exit 2 on a usage error or an
unreadable input (a seed, a ledger line, a missing date); verdicts that could
be computed are still printed. It never writes, renames or commits anything.
"""
import argparse
import json
import os
import runpy
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DECISIONS = "~/Obsidian/no-it-all/ledgers/decisions.jsonl"
DEFAULT_PRS = "~/Obsidian/no-it-all/ledgers/pr-records.jsonl"


class Usage(Exception):
    pass


def load_seed_module():
    path = os.path.join(HERE, "session-seed.py")
    if not os.path.isfile(path):
        raise Usage("session-seed.py not found beside %s" % __file__)
    return runpy.run_path(path)


def parse_ts(value):
    if not isinstance(value, str):
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    try:
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def read_jsonl(path, kind, errors):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    errors.append("%s line %d is not JSON" % (path, n))
                    continue
                if isinstance(obj, dict) and obj.get("kind") == kind:
                    rows.append(obj)
    except FileNotFoundError:
        pass
    except OSError as e:
        errors.append("cannot read %s: %s" % (path, e))
    return rows


def check_seed(scope, fm, decisions, prs):
    seed_date = parse_ts(fm.get("date", ""))
    if seed_date is None:
        raise Usage("seed for %s has no parseable date: %r" % (scope, fm.get("date")))
    reasons = []
    later = [d for d in decisions if d.get("scope") == scope
             and (parse_ts(d.get("received_at")) or seed_date) > seed_date]
    if later:
        ids = ", ".join(str(d.get("id")) for d in later)
        reasons.append({"code": "decision", "detail":
                        "decision received after the seed was written (%s)" % ids})
    sid = (fm.get("session") or "").strip()
    for r in prs:
        repo = str(r.get("repo") or "")
        rsid = str(((r.get("session") or {}).get("id")) or "")
        if repo.split("/")[-1] != scope and not (sid and sid != "unknown" and rsid.startswith(sid)):
            continue
        stamps = [parse_ts(r.get("recorded_at")), parse_ts((r.get("pr_meta") or {}).get("merged_at"))]
        if any(t and t > seed_date for t in stamps):
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
        mod = load_seed_module()
        directory = mod["handoff_dir"]()
    except SystemExit:
        print("error: cannot resolve the handoff dir", file=sys.stderr)
        return 2
    except Usage as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
    dpath = os.path.expanduser(a.decision_ledger or os.environ.get("CLAUDE_DECISION_LEDGER") or DEFAULT_DECISIONS)
    ppath = os.path.expanduser(a.pr_ledger or os.environ.get("CLAUDE_PR_LEDGER") or DEFAULT_PRS)
    decisions = read_jsonl(dpath, "decision-record", errors)
    prs = read_jsonl(ppath, "pr-record", errors)

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
            reasons = check_seed(scope, fm, decisions, prs)
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
