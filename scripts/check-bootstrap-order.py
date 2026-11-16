#!/usr/bin/env python3
"""check-bootstrap-order.py — the machine bootstrap in generic/session-lifecycle.md
must copy the shared usage engine before any script that imports it (#398).

`usage_accounting.py` is imported from their own directory by the usage scripts
in assets/scripts/. A new caller beside an old engine fails: an ImportError for
the row and checkpoint scripts, a KeyError at scan time for the trend. The
bootstrap block also copies callers into ~/.claude/scripts/, where
usage-trend.py may be a symlink into ~/.claude/usage-history/, so a caller copy
can land in either directory. The rule is therefore:

  1. Every directory that a fenced `cp` delivers an importer to also receives
     the engine from a fenced `cp`.
  2. Every engine copy happens in a command BEFORE the first command that
     copies any importer. A command copying both counts as a violation, since
     it cannot finish the other directory first.
  3. The prose says the two engine copies must be the same file version.

Importers are found structurally (a top-level `import usage_accounting` or
`from usage_accounting import` in assets/scripts/*.py, test files excluded),
so a new caller is covered the day it lands.

Limits: this reads `cp` commands inside code fences, in document order, with
backslash continuations joined. It does not run them, resolve shell variables
or follow `cd`. Rule 3 is a text-presence test, so a sentence that negates it
still passes (the inversion class of #226).

Usage: check-bootstrap-order.py [--root DIR]
Exit:  0 the block copies the engine first, everywhere a caller goes
       1 at least one violation (every violation is reported)
       2 cannot check: the template or assets/scripts is missing, no importer
         was found, or no fenced `cp` copies an importer (a check over zero
         cases must not report success)
"""
import argparse
import re
import shlex
import sys
from pathlib import Path

ENGINE = "usage_accounting.py"
TEMPLATE = "generic/session-lifecycle.md"
IMPORTS = re.compile(r"^(?:import usage_accounting\b|from usage_accounting import\b)", re.M)
SAME_VERSION = re.compile(
    r"usage_accounting\.py`?[^\n]{0,120}\bsame (?:file )?version"
    r"|\bsame (?:file )?version[^\n]{0,120}usage_accounting\.py",
    re.S,
)


def fenced_commands(text):
    """Logical shell lines inside ``` fences, continuations joined, in order."""
    out, in_fence, buf = [], False, ""
    for ln in text.splitlines():
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            if buf:
                out.append(buf)
                buf = ""
            continue
        if not in_fence:
            continue
        stripped = ln.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        out.append(buf + stripped)
        buf = ""
    if buf:
        out.append(buf)
    return out


def cp_commands(lines):
    """(sources, destination) for each plain `cp` command, one per `;`/`&&` part."""
    out = []
    for line in lines:
        for part in re.split(r"&&|;|\|\|", line):
            try:
                toks = shlex.split(part, comments=True)
            except ValueError:
                continue
            if not toks or toks[0] != "cp":
                continue
            args = [t for t in toks[1:] if not t.startswith("-")]
            if len(args) < 2:
                continue
            dest = args[-1].rstrip("/") + "/"
            out.append(([Path(a).name for a in args[:-1]], dest))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    root = Path(ap.parse_args().root)

    tpl, scripts = root / TEMPLATE, root / "assets" / "scripts"
    try:
        text = tpl.read_text(encoding="utf-8")
    except OSError as e:
        print(f"cannot check: {TEMPLATE} unreadable ({e})")
        return 2
    if not scripts.is_dir():
        print("cannot check: assets/scripts/ is missing")
        return 2
    importers = set()
    for p in sorted(scripts.glob("*.py")):
        if p.name == ENGINE or p.stem.endswith("_test") or p.stem.endswith(".test"):
            continue
        try:
            if IMPORTS.search(p.read_text(encoding="utf-8")):
                importers.add(p.name)
        except OSError as e:
            print(f"cannot check: {p} unreadable ({e})")
            return 2
    if not importers:
        print(f"cannot check: no script in assets/scripts imports {ENGINE}")
        return 2

    cmds = cp_commands(fenced_commands(text))
    first_caller = next((i for i, (srcs, _) in enumerate(cmds) if importers & set(srcs)), None)
    if first_caller is None:
        print(f"cannot check: no fenced `cp` in {TEMPLATE} copies a script that imports {ENGINE}")
        return 2

    errors = []
    caller_dests = {d for srcs, d in cmds if importers & set(srcs)}
    engine_at = {}  # dest -> index of the first command delivering the engine there
    for i, (srcs, d) in enumerate(cmds):
        if ENGINE in srcs:
            engine_at.setdefault(d, i)
    for d in sorted(caller_dests - set(engine_at)):
        errors.append(f"a caller is copied to {d} but {ENGINE} never is")
    for d, i in sorted(engine_at.items(), key=lambda kv: kv[1]):
        if i >= first_caller:
            srcs = cmds[first_caller][0]
            who = ", ".join(sorted(importers & set(srcs)))
            errors.append(
                f"{ENGINE} reaches {d} in copy command {i + 1}, not before copy command "
                f"{first_caller + 1}, which already copies its caller(s) {who}"
            )
    if not SAME_VERSION.search(text):
        errors.append(
            f"{TEMPLATE} no longer says the two copies of {ENGINE} must be the same file version"
        )

    for e in errors:
        print(f"::error file={TEMPLATE}::{e}")
    if errors:
        return 1
    print(
        f"OK: {ENGINE} reaches {', '.join(sorted(engine_at))} before any of "
        f"{len(importers)} importer(s) is copied"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
