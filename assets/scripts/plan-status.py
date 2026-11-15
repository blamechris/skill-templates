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
import hashlib
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
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")


class Refuse(Exception):
    pass


LIFECYCLE = ("status", "status_updated", "superseded_by", "decisions")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?=\s|$)(.*)$")
CONT_RE = re.compile(r"^(\s+\S|-(\s|$))")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
DQ_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"(\s+#.*|\s*)$')
SQ_RE = re.compile(r"^'((?:[^']|'')*)'(\s+#.*|\s*)$")


def read_bytes_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw.decode("utf-8", "surrogateescape"), raw


def read_text(path):
    return read_bytes_text(path)[0]


def split_lines(text):
    """List of (content, terminator); terminator is '\\n', '\\r\\n' or ''."""
    out = []
    for raw in re.findall(r"[^\n]*\n|[^\n]+", text):
        if raw.endswith("\r\n"):
            out.append((raw[:-2], "\r\n"))
        elif raw.endswith("\n"):
            out.append((raw[:-1], "\n"))
        else:
            out.append((raw, ""))
    return out


def frontmatter_span(lines):
    """(open_idx, close_idx) of the `---` fences, or None. A BOM before the
    opening fence means there is no frontmatter (documented, refused)."""
    if not lines or lines[0][0].rstrip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i][0].rstrip() == "---":
            return 0, i
    return None


def split_value(rest):
    """Text after `key:` -> (value, comment_suffix). The suffix is the original
    bytes from the whitespace before an unquoted `#` to the end of the line."""
    body = rest.lstrip()
    lead = rest[:len(rest) - len(body)]
    if body.startswith("#"):
        return "", rest
    for rx in (DQ_RE, SQ_RE):
        m = rx.match(body)
        if m:
            v = m.group(1)
            v = v.replace('\\"', '"') if rx is DQ_RE else v.replace("''", "'")
            return v, m.group(2) if m.group(2).strip() else ""
    m = re.search(r"\s+#", body)
    if m:
        return body[:m.start()].strip(), body[m.start():]
    return body.strip(), ""


def key_lines(lines, span):
    """[(idx, key, value, suffix)] for every top-level key line."""
    out = []
    for i in range(span[0] + 1, span[1]):
        m = KEY_RE.match(lines[i][0])
        if m:
            v, suf = split_value(m.group(2))
            out.append((i, m.group(1), v, suf))
    return out


def parse_fm(lines, span):
    out = {}
    for _i, k, v, _s in key_lines(lines, span):
        out.setdefault(k, v)
    return out


def duplicates(lines, span):
    seen, dup = set(), []
    for _i, k, _v, _s in key_lines(lines, span):
        if k in LIFECYCLE and k in seen and k not in dup:
            dup.append(k)
        seen.add(k)
    return dup


def key_run(lines, span, kidx):
    """End index of the key's owned continuation lines. Refuses comment lines
    inside the run and any continuation-looking line separated from it."""
    end = span[1]
    for j in range(kidx + 1, span[1]):
        if KEY_RE.match(lines[j][0]):
            end = j
            break
    run_end = kidx + 1
    while run_end < end and CONT_RE.match(lines[run_end][0]):
        run_end += 1
    for j in range(kidx + 1, run_end):
        if lines[j][0].lstrip().startswith("#"):
            raise Refuse("comment line inside the span of '%s'" % KEY_RE.match(lines[kidx][0]).group(1))
    for j in range(run_end, end):
        if CONT_RE.match(lines[j][0]):
            raise Refuse("blank or comment line splits the span of '%s'" % KEY_RE.match(lines[kidx][0]).group(1))
    return run_end


def check_ids(items):
    for it in items:
        if not ID_RE.match(it):
            raise Refuse("unsupported decisions entry '%s'" % it)
    return items


def parse_decisions(lines, span):
    """(ids, form, kidx, run_end, suffix) for the decisions key; form is one of
    'absent', 'empty', 'flow', 'block'. Refuses every other shape."""
    for i, k, v, suf in key_lines(lines, span):
        if k != "decisions":
            continue
        run_end = key_run(lines, span, i)
        if not v:
            if run_end == i + 1:
                return [], "empty", i, run_end, suf
            if suf and not suf.strip().startswith("#"):
                raise Refuse("unsupported decisions value")
            items = []
            for j in range(i + 1, run_end):
                m = re.match(r"^\s*-\s+(\S.*?)\s*$", lines[j][0])
                if not m:
                    raise Refuse("unsupported decisions block entry")
                items.append(unquote(m.group(1)))
            return check_ids(items), "block", i, run_end, suf
        if run_end != i + 1:
            raise Refuse("decisions mixes an inline value with continuation lines")
        if not (v.startswith("[") and v.endswith("]")):
            raise Refuse("decisions must be a one-line [a, b] list or a '- item' block")
        inner = v[1:-1]
        if re.search(r"[\[\]{}]", inner):
            raise Refuse("nested brackets in decisions are not supported")
        items = [unquote(x.strip()) for x in inner.split(",") if x.strip()]
        return check_ids(items), "flow", i, run_end, suf
    return [], "absent", None, None, ""


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def parse_ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%MZ")


def stale_stamps(lines, span, su_dt):
    """Valid body update stamps newer than status_updated, newest first as
    strings. Malformed stamps are ignored. Fenced code is skipped (CommonMark
    style: the closer must repeat the opener's character, at least as long)."""
    found = []
    fence = None
    for i in range(span[1] + 1, len(lines)):
        line = lines[i][0]
        fm = FENCE_RE.match(line)
        if fence is None:
            if fm:
                fence = (fm.group(1)[0], len(fm.group(1)))
                continue
        else:
            if fm and fm.group(1)[0] == fence[0] and len(fm.group(1)) >= fence[1] \
                    and not line.strip().strip(fence[0]):
                fence = None
            continue
        m = STAMP_RE.match(line)
        if not m:
            continue
        d, t = m.group(1), m.group(2)
        try:
            if t:
                dt = datetime.datetime.strptime(d + "T" + t, "%Y-%m-%dT%H:%M")
                stale = dt > su_dt
            else:
                datetime.datetime.strptime(d, "%Y-%m-%d")
                stale = d > su_dt.strftime("%Y-%m-%d")
        except ValueError:
            continue
        if stale:
            found.append(d + ("T" + t if t else ""))
    return sorted(found, reverse=True)


def lint(text):
    """List of WARN reasons for one plan's text."""
    lines = split_lines(text)
    span = frontmatter_span(lines)
    if not span:
        if text.startswith("\ufeff"):
            return ["no frontmatter block (a UTF-8 BOM before --- is not supported)"]
        return ["no frontmatter block"]
    fm = parse_fm(lines, span)
    warns = []
    for k in duplicates(lines, span):
        warns.append("duplicate key '%s'" % k)
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
        stale = stale_stamps(lines, span, su_dt)
        if stale:
            warns.append("status_updated %s is older than the newest body update %s" % (su, stale[0]))
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
    try:
        names = sorted(os.listdir(d))
    except OSError as e:
        print("ERROR %s: %s" % (d, e.strerror or e), file=sys.stderr)
        return 2
    checked = skipped = warned = 0
    rc = 0
    for name in names:
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


def others(lines, span):
    return [(k, v) for _i, k, v, _s in key_lines(lines, span) if k not in LIFECYCLE]


def plan_set(path, status, superseded_by, decisions, now):
    """Return (new_text, old_status, snapshot). Raises Refuse. Does not write.

    Supported subset: top-level `key: value` lines; scalar lifecycle keys have a
    single-line value with an optional trailing `# comment` (kept verbatim);
    `decisions` is absent, empty, a one-line [a, b] list or a contiguous
    `- item` block. Anything else (duplicate keys, multi-line values, comment or
    blank lines inside an edited key's span, a BOM) is refused, file untouched."""
    real = os.path.realpath(path)
    if not os.path.isfile(real):
        raise Refuse("no such file: %s" % path)
    if not os.access(real, os.W_OK):
        raise Refuse("%s is not writable (a read-only plan is a deliberate lock)" % path)
    try:
        st = os.stat(real)
        text, raw = read_bytes_text(real)
    except OSError as e:
        raise Refuse("cannot read %s: %s" % (path, e.strerror or e))
    snap = (st.st_mtime_ns, st.st_size, hashlib.sha256(raw).hexdigest())
    lines = split_lines(text)
    span = frontmatter_span(lines)
    if not span:
        raise Refuse("%s has no frontmatter block (--- ... ---; a UTF-8 BOM before --- is not supported)" % path)
    dup = duplicates(lines, span)
    if dup:
        raise Refuse("duplicate lifecycle key(s): %s" % ", ".join(dup))
    fm = parse_fm(lines, span)
    old = fm.get("status", "")
    if status not in STATUSES:
        raise Refuse("unknown status '%s'" % status)
    if old in STATUSES and status != old and status not in TRANSITIONS[old]:
        raise Refuse("illegal transition %s -> %s (allowed from %s: %s)" %
                     (old, status, old, ", ".join(TRANSITIONS[old])))
    if superseded_by is not None:
        superseded_by = superseded_by.strip()
        if not superseded_by or re.search(r"[\r\n]", superseded_by):
            raise Refuse("--superseded-by must be a non-empty single line")
    if status == "superseded":
        if not (superseded_by or fm.get("superseded_by")):
            raise Refuse("status superseded requires --superseded-by")
    elif superseded_by:
        raise Refuse("--superseded-by is only valid with --status superseded")
    for d in decisions:
        if not ID_RE.match(d):
            raise Refuse("invalid decision id '%s'" % d)
    if not TS_RE.match(now):
        raise Refuse("--now '%s' is not YYYY-MM-DDTHH:MMZ" % now)
    try:
        parse_ts(now)
    except ValueError:
        raise Refuse("--now '%s' is not a valid timestamp" % now)

    nl = lines[0][1] or "\n"
    edits = []  # (old_start, old_end, [(content, term)], appends_to_a_block)
    scalars = [("status", status), ("status_updated", now)]
    if superseded_by:
        scalars.append(("superseded_by", fmt_value(superseded_by)))
    kl = key_lines(lines, span)
    for key, val in scalars:
        hit = [x for x in kl if x[1] == key]
        if hit:
            i, _k, _v, suf = hit[0]
            if key_run(lines, span, i) != i + 1:
                raise Refuse("'%s' has a multi-line value" % key)
            edits.append((i, i + 1, [("%s: %s%s" % (key, val, suf), lines[i][1])], False))
        else:
            edits.append((span[1], span[1], [("%s: %s" % (key, val), nl)], False))
    want_ids = list(decisions)
    old_ids = []
    if want_ids:
        old_ids, form, di, run_end, suf = parse_decisions(lines, span)
        add = [d for d in want_ids if d not in old_ids]
        for d in list(add):
            if add.count(d) > 1:
                add.remove(d)
        if add:
            if form == "absent":
                edits.append((span[1], span[1], [("decisions: [%s]" % ", ".join(add), nl)], False))
            elif form == "empty":
                edits.append((di, di + 1, [("decisions: [%s]%s" % (", ".join(add), suf), lines[di][1])], False))
            elif form == "flow":
                merged = old_ids + add
                edits.append((di, di + 1, [("decisions: [%s]%s" % (", ".join(merged), suf), lines[di][1])], False))
            else:
                prefix = re.match(r"^(\s*-\s+)", lines[di + 1][0]).group(1)
                edits.append((run_end, run_end, [(prefix + d, lines[di][1]) for d in add], True))

    # apply ascending (stable), tracking the output ranges of edited lines
    out, new_ranges, old_ranges, pos = [], [], [], 0
    for start, end, repl, _blk in sorted(edits, key=lambda e: (e[0], 0 if e[3] else 1)):
        out.extend(lines[pos:start])
        new_ranges.append((len(out), len(out) + len(repl)))
        out.extend(repl)
        old_ranges.append((start, end))
        pos = end
    out.extend(lines[pos:])
    new_text = "".join(c + t for c, t in out)

    # self-verification: re-parse the result and prove nothing else moved
    nlines = split_lines(new_text)
    nspan = frontmatter_span(nlines)
    if not nspan or duplicates(nlines, nspan):
        raise Refuse("internal check failed: result frontmatter is malformed")
    nfm = parse_fm(nlines, nspan)
    if nfm.get("status") != status or nfm.get("status_updated") != now:
        raise Refuse("internal check failed: status keys were not written as asked")
    if superseded_by and nfm.get("superseded_by") != superseded_by:
        raise Refuse("internal check failed: superseded_by was not written as asked")
    if others(lines, span) != others(nlines, nspan):
        raise Refuse("internal check failed: another key changed")
    if want_ids:
        got = parse_decisions(nlines, nspan)[0]
        if any(i not in got for i in old_ids + want_ids):
            raise Refuse("internal check failed: a decision id is missing from the result")

    def outside(ls, ranges):
        keep = [True] * len(ls)
        for a, b in ranges:
            for k in range(a, b):
                keep[k] = False
        return "".join(c + t for (c, t), kp in zip(ls, keep) if kp)
    if outside(lines, old_ranges) != outside(nlines, new_ranges):
        raise Refuse("internal check failed: bytes outside the edited keys changed")
    return new_text, old, snap


def atomic_write(path, text, snap):
    real = os.path.realpath(path)
    d = os.path.dirname(real)
    fd, tmp = tempfile.mkstemp(prefix=".plan-status.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, os.stat(real).st_mode & 0o7777)
        # Best-effort lost-update guard: refuse if the file changed since it was
        # read. This narrows, but cannot close, the window before the rename.
        st = os.stat(real)
        with open(real, "rb") as f:
            cur = (st.st_mtime_ns, st.st_size, hashlib.sha256(f.read()).hexdigest())
        if cur != snap:
            raise Refuse("%s changed while it was being updated; re-run" % path)
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
        new, old, snap = plan_set(args.file, args.status, args.superseded_by, args.decision or [], now)
        atomic_write(args.file, new, snap)
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
        try:
            datetime.datetime.strptime(args.since, "%Y-%m-%d")
        except ValueError:
            ap.error("--since must be a real calendar date YYYY-MM-DD")
        return cmd_scan(args.dir, args.since)
    return cmd_set(args)


if __name__ == "__main__":
    sys.exit(main())
