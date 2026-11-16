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

Importers are found structurally: any `import usage_accounting` or
`from usage_accounting import` statement anywhere in assets/scripts/*.py
(parsed with `ast`, so indented and comma-listed imports count and docstrings
do not), test files excluded. A new caller is covered the day it lands.

Limits: this reads `cp` commands inside code fences, in document order, with
backslash continuations joined and `&&`/`;`/`||` split. It does not run them,
follow `cd`, or resolve shell variables beyond spelling `$HOME`/`${HOME}` as
`~`. A `cp` that names assets/scripts but cannot be read as plain sources and
one destination (a glob, an unparseable quote) makes the check exit 2 rather
than guess. Rule 3 is a text-presence test, so a sentence that negates it
still passes (the inversion class of #226).

Usage: check-bootstrap-order.py [--root DIR]
Exit:  0 the block copies the engine first, everywhere a caller goes
       1 at least one violation (every violation is reported)
       2 cannot check: the template or assets/scripts is missing, no importer
         was found, or no fenced `cp` copies an importer (a check over zero
         cases must not report success)
"""
import argparse
import ast
import re
import shlex
import sys
from pathlib import Path

ENGINE = "usage_accounting.py"
TEMPLATE = "generic/session-lifecycle.md"
ENGINE_MOD = "usage_accounting"
SAME_VERSION = re.compile(
    r"usage_accounting\.py`?[\s\S]{0,160}?\bsame\s+(?:file\s+)?version"
    r"|\bsame\s+(?:file\s+)?version[\s\S]{0,160}?usage_accounting\.py"
)


class Unparseable(Exception):
    pass


def imports_engine(source):
    """True if any import statement in `source` names the engine module."""
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import) and any(a.name == ENGINE_MOD for a in node.names):
            return True
        if isinstance(node, ast.ImportFrom) and node.module == ENGINE_MOD and not node.level:
            return True
    return False


def norm_dest(d):
    for home in ("${HOME}", "$HOME"):
        if d == home or d.startswith(home + "/"):
            d = "~" + d[len(home):]
    return d.rstrip("/") + "/"


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
    """(sources, destination) for each `cp` command, one per `;`/`&&`/`||` part.

    Raises Unparseable for a `cp` that names assets/scripts but is not plain
    sources and one destination, so the caller fails closed instead of guessing.
    """
    out = []
    for line in lines:
        for part in re.split(r"&&|;|\|\|", line):
            try:
                toks = shlex.split(part, comments=True)
            except ValueError:
                if re.search(r"\bcp\b", part) and "assets/scripts" in part:
                    raise Unparseable(part.strip())
                continue
            while toks and toks[0] in ("sudo", "command"):
                toks = toks[1:]
            if not toks or toks[0] != "cp":
                continue
            dest, args, it = None, [], iter(toks[1:])
            for t in it:
                if t in ("-t", "--target-directory"):
                    dest = next(it, None)
                elif t.startswith("--target-directory="):
                    dest = t.split("=", 1)[1]
                elif t.startswith("-"):
                    continue
                else:
                    args.append(t)
            if dest is None and len(args) >= 2:
                dest, args = args[-1], args[:-1]
            if dest is None or not args or any(c in a for a in args for c in "*?[$"):
                if "assets/scripts" in part:
                    raise Unparseable(part.strip())
                continue
            out.append(([Path(a).name for a in args], norm_dest(dest)))
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
            if imports_engine(p.read_text(encoding="utf-8")):
                importers.add(p.name)
        except (OSError, SyntaxError, ValueError) as e:
            print(f"cannot check: {p} unreadable or not parseable ({e})")
            return 2
    if not importers:
        print(f"cannot check: no script in assets/scripts imports {ENGINE}")
        return 2

    try:
        cmds = cp_commands(fenced_commands(text))
    except Unparseable as e:
        print(f"cannot check: a fenced `cp` in {TEMPLATE} names assets/scripts but is not "
              f"plain sources and one destination: {e}")
        return 2
    first_caller = next((i for i, (srcs, _) in enumerate(cmds) if importers & set(srcs)), None)
    if first_caller is None:
        print(f"cannot check: no fenced `cp` in {TEMPLATE} copies a script that imports {ENGINE}")
        return 2

    errors = []
    caller_dests = {d for srcs, d in cmds if importers & set(srcs)}
    engine_at = {}  # dest -> index of the first command delivering the engine there
    for i, (srcs, d) in enumerate(cmds):
        if ENGINE in srcs and d in caller_dests:
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
