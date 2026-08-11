#!/usr/bin/env python3
"""Regenerate the vault handoff INDEX (handoffs/NEXT.md) from the directory listing.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/handoff-index.py ~/.claude/scripts/

Usage:
    python3 ~/.claude/scripts/handoff-index.py            # print the index to stdout
    python3 ~/.claude/scripts/handoff-index.py --write     # write it to <dir>/NEXT.md

Why this exists
---------------
Session end used to overwrite a single shared seed at handoffs/NEXT.md. Chris runs
several projects concurrently, so two sessions ending near each other raced for one
path and the later write destroyed the earlier seed — three times in three days. The
seed is now PER PROJECT (`NEXT-<project>.md`), which removes the shared path, and
NEXT.md demotes to an index over those files.

The index is DERIVED, never authored: every field below is read off the directory, so
two sessions regenerating it concurrently converge on the same bytes instead of
clobbering each other's prose. Nothing here is a seed — losing NEXT.md costs one
command, not a session's state.

What counts as a seed
---------------------
  NEXT-<project>.md                     the canonical per-project seed (preferred)
  <project>-<date>-handoff.md           a dated handoff; used only for a project with
                                        no NEXT-<project>.md yet, most recent wins

NEXT.md itself is skipped (it is the output). Vault notes that are not handoffs — a
scoping doc, a .patch, a subdirectory — do not match either shape and are ignored.

Seed text is treated as opaque data: only the first `# ` heading is read, for the
state column, and it is emitted escaped into a table cell.
"""
import argparse
import os
import re
import sys
from datetime import datetime, timezone

DEFAULT_DIR = os.environ.get(
    "CLAUDE_HANDOFF_DIR", os.path.expanduser("~/Obsidian/no-it-all/handoffs")
)

SEED_RE = re.compile(r"^NEXT-(?P<project>.+)\.md$")
DATED_RE = re.compile(r"^(?P<project>.+)-(?P<date>\d{4}-\d{2}-\d{2})-handoff\.md$")

STATE_MAX = 90


def headline(path):
    """First `# ` heading in the file, as the row's one-line state. Data, not markup."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("# "):
                    text = line[2:].strip()
                    break
            else:
                return ""
    except OSError:
        return ""
    # Collapse to a single table cell: no pipes, no newlines, bounded length.
    text = text.replace("|", "\\|")
    if len(text) > STATE_MAX:
        text = text[: STATE_MAX - 1].rstrip() + "…"
    return text


def collect(directory):
    """Map project -> (filename, mtime, is_canonical). Canonical seeds win outright."""
    found = {}
    try:
        names = os.listdir(directory)
    except OSError as e:
        sys.exit(f"cannot read handoff dir {directory}: {e}")

    for name in sorted(names):
        path = os.path.join(directory, name)
        if not os.path.isfile(path) or name == "NEXT.md":
            continue

        m = SEED_RE.match(name)
        canonical = m is not None
        if not canonical:
            m = DATED_RE.match(name)
        if not m:
            continue

        project = m.group("project")
        mtime = os.path.getmtime(path)
        prev = found.get(project)
        # A canonical NEXT-<project>.md always beats a dated file; among equals the
        # most recently written wins.
        if prev is None or (canonical, mtime) > (prev[2], prev[1]):
            found[project] = (name, mtime, canonical)
    return found


def render(directory, found):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows = sorted(found.items(), key=lambda kv: kv[1][1], reverse=True)

    out = [
        "# Handoff index — one seed per project",
        "",
        f"_Generated {stamp} by `python3 ~/.claude/scripts/handoff-index.py --write`._",
        "_Derived from the directory listing — do not hand-edit; regenerate instead._",
        "",
        "**This file is an INDEX, not a seed.** To resume a project, open its seed file",
        "below — that is the file to paste as the opening message of a fresh session.",
        "Session end writes `NEXT-<project>.md` and regenerates this table; it never",
        "overwrites another project's seed.",
        "",
    ]

    if not rows:
        out += ["_No seeds found._", ""]
    else:
        out += [
            "| Project | Seed file | Updated | State |",
            "|---|---|---|---|",
        ]
        for project, (name, mtime, canonical) in rows:
            date = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
            mark = "" if canonical else " ⚠️"
            out.append(
                f"| **{project}** | [`{name}`]({name}){mark} | {date} | "
                f"{headline(os.path.join(directory, name)) or '—'} |"
            )
        out.append("")
        if any(not c for _, _, c in found.values()):
            out += [
                "⚠️ = a dated handoff standing in for a project that has no `NEXT-<project>.md`",
                "yet. Its next session end will write the canonical seed and the mark clears.",
                "",
            ]

    out += [
        "## Closing protocol (every session, every project)",
        "",
        "1. Append the usage-benchmark row —",
        "   `python3 ~/.claude/scripts/usage-benchmark-row.py` → `briefs/usage-benchmark.md`.",
        "2. Write the seed to `NEXT-<project>.md` — **this project's file only**.",
        "3. Regenerate this index — `python3 ~/.claude/scripts/handoff-index.py --write`.",
        "4. Hand Chris one line to paste: the path to `NEXT-<project>.md`.",
        "",
    ]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", default=DEFAULT_DIR, help=f"handoff dir (default: {DEFAULT_DIR})")
    ap.add_argument("--write", action="store_true", help="write <dir>/NEXT.md instead of stdout")
    args = ap.parse_args()

    directory = os.path.expanduser(args.dir)
    text = render(directory, collect(directory))

    if not args.write:
        print(text, end="")
        return

    target = os.path.join(directory, "NEXT.md")
    # Atomic replace: a crash mid-write leaves the previous index intact rather than
    # a truncated one. Same discipline the save-system rules ask for elsewhere.
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, target)
    print(f"wrote {target}", file=sys.stderr)


if __name__ == "__main__":
    main()
