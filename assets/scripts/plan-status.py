#!/usr/bin/env python3
"""plan-status.py -- lint and update the lifecycle frontmatter of plan notes.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/plan-status.py ~/.claude/scripts/

Contract: docs/plan-lifecycle.md (read it first; this docstring is only a reference).

Usage:
  python3 ~/.claude/scripts/plan-status.py check <file>...
  python3 ~/.claude/scripts/plan-status.py scan [--dir D] [--since YYYY-MM-DD]
  python3 ~/.claude/scripts/plan-status.py set <file> --status S [--superseded-by X]
      [--decision ID ...] [--now YYYY-MM-DDTHH:MMZ]

check  Report-only lint. Prints `OK <file>` or one `WARN <file> <reason>` per problem.
scan   `check` over *.md in --dir ($CLAUDE_PLAN_DIR, else ~/Obsidian/no-it-all/plans)
       for plans whose mtime date (or `date:` frontmatter, whichever is later) is on
       or after --since (default: the rule's effective date, so legacy plans are never
       flagged).
set    Rewrite only status, status_updated and, when given, superseded_by / decisions.
       Every other byte is preserved; the write is atomic (temp file in the same dir,
       then rename). Never runs git: it prints the add/commit lines for the writer.

Exit codes: check/scan 0 after a completed report whatever it found, 2 on a usage error
or unreadable input. set 0 on success, 1 on a refusal, 2 on a usage error.

Body-stamp heuristic (check): a line outside a code fence that starts with
`> **Update YYYY-MM-DD` optionally followed by `THH:MM` or `THH:MMZ` (a space instead
of T is accepted). A stamp with a time is stale-making when it is later than
status_updated; a date-only stamp only when its date is after status_updated's date.
"""
import argparse
import datetime
import os
import re
import shlex
import sys
import tempfile

EFFECTIVE_DATE = "2026-11-15"

STATUSES = ("proposal", "accepted", "in-delivery", "delivered", "superseded", "abandoned")
TERMINAL = ("delivered", "superseded", "abandoned")
TRANSITIONS = {
    "proposal": ("accepted", "abandoned"),
    "accepted": ("in-delivery", "superseded", "abandoned"),
    "in-delivery": ("delivered", "superseded", "abandoned"),
    "delivered": ("superseded",),
    "superseded": ("superseded",),
    "abandoned": ("superseded",),
}

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z$")
STAMP_RE = re.compile(r"^>\s*\*\*Update\s+(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]|$)")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")


class Refuse(Exception):
    pass


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "surrogateescape")


def split_lines(text):
    return re.findall(r"[^\n]*\n|[^\n]+", text)


def frontmatter_span(lines):
    """Return (open_idx, close_idx) of the `---` fences, or None."""
    if not lines or lines[0].rstrip("\r\n").rstrip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n").rstrip() == "---":
            return 0, i
    return None


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def parse_fm(lines, span):
    """Top-level scalar keys -> value (first occurrence wins)."""
    out = {}
    for i in range(span[0] + 1, span[1]):
        m = KEY_RE.match(lines[i])
        if m and m.group(1) not in out:
            out[m.group(1)] = unquote(lines[i][m.end():])
    return out


def key_block(lines, span, key):
    """(start, end) line indexes of `key` and its continuation lines, or None."""
    for i in range(span[0] + 1, span[1]):
        m = KEY_RE.match(lines[i])
        if m and m.group(1) == key:
            j = i + 1
            while j < span[1] and re.match(r"^(\s+\S|-\s)", lines[j]):
                j += 1
            return i, j
    return None


def parse_list(lines, span, key):
    blk = key_block(lines, span, key)
    if not blk:
        return []
    first = lines[blk[0]].split(":", 1)[1].strip()
    items = []
    if first.startswith("["):
        items = [unquote(x) for x in first.strip("[] \t\r\n").split(",")]
    elif first:
        items = [unquote(first)]
    for j in range(blk[0] + 1, blk[1]):
        s = lines[j].strip()
        if s.startswith("-"):
            items.append(unquote(s[1:]))
    return [x for x in items if x]


def parse_ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%MZ")


def newest_stamp(lines, span):
    """Newest body update stamp as (date, time-or-None), or None."""
    best = None
    fence = False
    for i in range(span[1] + 1, len(lines)):
        line = lines[i]
        if line.lstrip().startswith("```") or line.lstrip().startswith("~~~"):
            fence = not fence
            continue
        if fence:
            continue
        m = STAMP_RE.match(line)
        if not m:
            continue
        cand = (m.group(1), m.group(2))
        if best is None or (cand[0], cand[1] or "") > (best[0], best[1] or ""):
            best = cand
    return best


def lint(text):
    """List of WARN reasons for one plan's text."""
    lines = split_lines(text)
    span = frontmatter_span(lines)
    if not span:
        return ["no frontmatter block"]
    fm = parse_fm(lines, span)
    warns = []
    status = fm.get("status", "")
    if not status:
        warns.append("missing status")
    elif status not in STATUSES:
        warns.append("unknown status '%s' (expected one of %s)" % (status, ", ".join(STATUSES)))
    su = fm.get("status_updated", "")
    su_dt = None
    if not su:
        warns.append("missing status_updated")
    elif not TS_RE.match(su):
        warns.append("status_updated '%s' is not YYYY-MM-DDTHH:MMZ" % su)
    else:
        try:
            su_dt = parse_ts(su)
        except ValueError:
            warns.append("status_updated '%s' is not a valid timestamp" % su)
    if status == "superseded" and not fm.get("superseded_by", ""):
        warns.append("status is superseded but superseded_by is missing")
    if su_dt is not None:
        st = newest_stamp(lines, span)
        if st:
            d, t = st
            if t:
                try:
                    stale = datetime.datetime.strptime(d + "T" + t, "%Y-%m-%dT%H:%M") > su_dt
                except ValueError:
                    stale = False
            else:
                stale = d > su_dt.strftime("%Y-%m-%d")
            if stale:
                warns.append("status_updated %s is older than the newest body update %s" %
                             (su, d + ("T" + t if t else "")))
    return warns


def cmd_check(files):
    rc = 0
    for f in files:
        try:
            text = read_text(f)
        except OSError as e:
            print("ERROR %s: %s" % (f, e.strerror or e), file=sys.stderr)
            rc = 2
            continue
        warns = lint(text)
        if warns:
            for w in warns:
                print("WARN %s %s" % (f, w))
        else:
            print("OK %s" % f)
    return rc


def file_date(path, text):
    mt = datetime.datetime.fromtimestamp(os.stat(path).st_mtime, datetime.timezone.utc).strftime("%Y-%m-%d")
    lines = split_lines(text)
    span = frontmatter_span(lines)
    d = ""
    if span:
        m = re.match(r"^(\d{4}-\d{2}-\d{2})", parse_fm(lines, span).get("date", ""))
        if m:
            d = m.group(1)
    return max(mt, d)


def cmd_scan(dirpath, since):
    d = dirpath or os.environ.get("CLAUDE_PLAN_DIR") or os.path.expanduser("~/Obsidian/no-it-all/plans")
    if not os.path.isdir(d):
        print("ERROR plans directory not found: %s" % d, file=sys.stderr)
        return 2
    checked = skipped = warned = 0
    rc = 0
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if not name.endswith(".md") or not os.path.isfile(p):
            continue
        try:
            text = read_text(p)
            fdate = file_date(p, text)
        except OSError as e:
            print("ERROR %s: %s" % (p, e.strerror or e), file=sys.stderr)
            rc = 2
            continue
        if fdate < since:
            skipped += 1
            continue
        checked += 1
        warns = lint(text)
        if warns:
            warned += 1
            for w in warns:
                print("WARN %s %s" % (p, w))
        else:
            print("OK %s" % p)
    print("SCAN %s: %d checked, %d with warnings, %d before %s skipped" % (d, checked, warned, skipped, since))
    return rc


def fmt_value(v):
    if re.search(r"(^[\s\-?:,\[\]{}#&*!|>'\"%@`])|(: )|( #)|(\s$)", v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return v


def plan_set(path, status, superseded_by, decisions, now):
    """Return (new_text, old_status). Raises Refuse. Does not write."""
    if not os.path.isfile(path):
        raise Refuse("no such file: %s" % path)
    try:
        text = read_text(path)
    except OSError as e:
        raise Refuse("cannot read %s: %s" % (path, e.strerror or e))
    lines = split_lines(text)
    span = frontmatter_span(lines)
    if not span:
        raise Refuse("%s has no frontmatter block (--- ... ---)" % path)
    fm = parse_fm(lines, span)
    old = fm.get("status", "")
    if status not in STATUSES:
        raise Refuse("unknown status '%s'" % status)
    if old in STATUSES and status != old and status not in TRANSITIONS[old]:
        raise Refuse("illegal transition %s -> %s (allowed from %s: %s)" %
                     (old, status, old, ", ".join(TRANSITIONS[old])))
    if status == "superseded":
        if not (superseded_by or fm.get("superseded_by")):
            raise Refuse("status superseded requires --superseded-by")
    elif superseded_by:
        raise Refuse("--superseded-by is only valid with --status superseded")
    for d in decisions:
        if not ID_RE.match(d):
            raise Refuse("invalid decision id '%s'" % d)
    if superseded_by and re.search(r"[\r\n]", superseded_by):
        raise Refuse("--superseded-by must be one line")
    if not TS_RE.match(now):
        raise Refuse("--now '%s' is not YYYY-MM-DDTHH:MMZ" % now)
    try:
        parse_ts(now)
    except ValueError:
        raise Refuse("--now '%s' is not a valid timestamp" % now)

    nl = "\r\n" if lines[0].endswith("\r\n") else "\n"
    updates = [("status", [status]), ("status_updated", [now])]
    if superseded_by:
        updates.append(("superseded_by", [fmt_value(superseded_by)]))
    if decisions:
        merged = parse_list(lines, span, "decisions")
        for d in decisions:
            if d not in merged:
                merged.append(d)
        updates.append(("decisions", ["[" + ", ".join(merged) + "]"]))
    for key, (val,) in updates:
        new = "%s: %s%s" % (key, val, nl)
        blk = key_block(lines, span, key)
        if blk:
            lines[blk[0]:blk[1]] = [new]
            span = (span[0], span[1] - (blk[1] - blk[0]) + 1)
        else:
            if span[1] > 0 and not lines[span[1] - 1].endswith("\n"):
                lines[span[1] - 1] += nl
            lines.insert(span[1], new)
            span = (span[0], span[1] + 1)
    return "".join(lines), old


def atomic_write(path, text):
    real = os.path.realpath(path)
    d = os.path.dirname(real)
    fd, tmp = tempfile.mkstemp(prefix=".plan-status.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, os.stat(real).st_mode & 0o7777)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_set(args):
    now = args.now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    try:
        new, old = plan_set(args.file, args.status, args.superseded_by, args.decision or [], now)
        atomic_write(args.file, new)
    except Refuse as e:
        print("REFUSE: %s" % e, file=sys.stderr)
        return 1
    except OSError as e:
        print("REFUSE: write failed for %s: %s" % (args.file, e.strerror or e), file=sys.stderr)
        return 1
    real = os.path.realpath(args.file)
    d, base = os.path.dirname(real), os.path.basename(real)
    print("set %s: status %s -> %s (status_updated %s)" % (args.file, old or "(none)", args.status, now))
    print("Commit it (the writer commits; this script never runs git):")
    print("  git -C %s add -- %s" % (shlex.quote(d), shlex.quote(base)))
    print("  git -C %s commit -m %s -- %s" % (
        shlex.quote(d), shlex.quote("docs(plans): %s status %s" % (base, args.status)), shlex.quote(base)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="plan-status.py", description="Lint and update plan lifecycle frontmatter.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="report-only lint")
    c.add_argument("files", nargs="+")
    s = sub.add_parser("scan", help="check plans on or after --since")
    s.add_argument("--dir")
    s.add_argument("--since", default=EFFECTIVE_DATE)
    t = sub.add_parser("set", help="change status and related keys")
    t.add_argument("file")
    t.add_argument("--status", required=True)
    t.add_argument("--superseded-by")
    t.add_argument("--decision", action="append")
    t.add_argument("--now")
    args = ap.parse_args(argv)
    if args.cmd == "check":
        return cmd_check(args.files)
    if args.cmd == "scan":
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", args.since):
            ap.error("--since must be YYYY-MM-DD")
        return cmd_scan(args.dir, args.since)
    return cmd_set(args)


if __name__ == "__main__":
    sys.exit(main())
