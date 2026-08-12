#!/usr/bin/env python3
"""Compare the machine's ~/.claude/CLAUDE.md against the registry copy, by rule class.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/fleet-check.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/fleet-check.py [--machine PATH] [--repo PATH]
                                           [--ref REF] [--verbose]

`~/.claude/CLAUDE.md` is AUTHORED, not generated: it is edited in place on the
machine, and `assets/global-CLAUDE.md` in the registry is the copy a new machine
bootstraps from. Two authored nodes drift in both directions at once (#208), and
"the registry wins" silently deletes conventions in active use. So drift is not
one verdict — it is two, split by rule class:

  FLOOR    the five rules the whole fleet depends on. A floor difference is a
           broken fleet: exit 1, reconcile before long work.
  DEFAULT  everything else. Difference is information, not an error: exit 0,
           naming the DIRECTION so the reconciliation is obvious.

Class comes from a token on the RULE — `<!--floor:id-->` / `<!--default:id-->`
immediately above the rule's paragraph — never from the H2 it sits under.
Section granularity cannot express this floor: "the seed is written outside any
worktree" lives inside a section that is otherwise all defaults, and headings get
renamed, which is why heading lines are dropped from every block before comparing.

`git fetch` is a HARD PRECONDITION, never softened with `|| true`. Comparing
against a stale clone is exactly how the previous detector (a `diff -q` against
whatever the working copy happened to hold) produced confident wrong answers. If
the fetch cannot run, this exits 2 and reports nothing about drift.

Exit codes:
  0  no FLOOR difference. DEFAULT differences, if any, are listed with a direction.
  1  a FLOOR rule differs, is missing from one node, is duplicated, or the declared
     floor set is no longer the five rules this script knows about.
  2  the comparison could not be made honestly — fetch failed, a path is missing, the
     ref does not exist. Never 0: a check that cannot see the registry copy must not
     report agreement.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

# The floor is exactly these five rules. Widening or narrowing it is a deliberate
# fleet-wide act: change this tuple and assets/global-CLAUDE.md's tokens in one
# commit, or the check below fails on purpose.
FLOOR_IDS = (
    "no-agent-attribution",
    "explicit-path-staging",
    "worktree-by-default",
    "no-secrets-in-committed-files",
    "seed-written-outside-any-worktree",
)

REGISTRY_PATH = "assets/global-CLAUDE.md"

TOKEN = re.compile(r"^\s*<!--\s*(floor|default)\s*:\s*([a-z0-9][a-z0-9._-]*)\s*-->\s*$")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")

EXIT_OK, EXIT_FLOOR, EXIT_CANNOT_VERIFY = 0, 1, 2


def die(msg):
    print(f"fleet-check: cannot verify — {msg}", file=sys.stderr)
    print("fleet-check: NO drift verdict was produced (this is not agreement).", file=sys.stderr)
    sys.exit(EXIT_CANNOT_VERIFY)


def normalize(lines):
    """Whitespace and headings must never be able to fire this check.

    Trailing whitespace is stripped, runs of blank lines collapse to one, leading and
    trailing blanks go, and heading lines are dropped entirely — a renamed H2 is not a
    changed rule, and pinning rules to headings is the failure mode the tokens exist to
    avoid.
    """
    out = []
    for ln in lines:
        if HEADING.match(ln):
            continue
        ln = ln.rstrip()
        if not ln and (not out or not out[-1]):
            continue
        out.append(ln)
    while out and not out[-1]:
        out.pop()
    return out


def parse(text, where):
    """text -> ({id: (cls, [lines])}, [duplicate ids]).

    A token opens a block and closes the previous one; the block runs to the next
    token or EOF. Text before the first token is the '(preamble)' default rule.
    """
    rules, dups, order = {}, [], []
    cur_cls, cur_id, buf = "default", "(preamble)", []

    def flush():
        body = normalize(buf)
        if not body and cur_id == "(preamble)":
            return
        if cur_id in rules:
            dups.append(cur_id)
            return
        rules[cur_id] = (cur_cls, body)
        order.append(cur_id)

    for ln in text.splitlines():
        m = TOKEN.match(ln)
        if not m:
            buf.append(ln)
            continue
        flush()
        cur_cls, cur_id, buf = m.group(1), m.group(2), []
    flush()

    if not order or order == ["(preamble)"]:
        print(
            f"fleet-check: warning — {where} carries no rule-class tokens; every rule in it "
            f"is being compared as one undivided DEFAULT block.",
            file=sys.stderr,
        )
    return rules, dups, order


def direction(mach, reg):
    """Which node moved. Line-set based: mechanical, and it never guesses intent."""
    mset, rset = set(mach), set(reg)
    only_m = [l for l in mach if l and l not in rset]
    only_r = [l for l in reg if l and l not in mset]
    if only_m and not only_r:
        return "machine-ahead", len(only_m), len(only_r)
    if only_r and not only_m:
        return "registry-ahead", len(only_m), len(only_r)
    return "both", len(only_m), len(only_r)


def read_registry(repo, ref):
    if not os.path.isdir(repo):
        die(f"registry checkout {repo!r} does not exist (pass --repo)")
    probe = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--git-dir"], capture_output=True, text=True
    )
    if probe.returncode != 0:
        die(f"{repo!r} is not a git repository: {probe.stderr.strip()}")

    # HARD precondition. Never `|| true`, never `check=False` with the result ignored:
    # a comparison against a clone that has not seen origin in a week is a wrong answer
    # delivered confidently, which is worse than no answer at all.
    fetched = subprocess.run(
        ["git", "-C", repo, "fetch", "origin", "--quiet"], capture_output=True, text=True
    )
    if fetched.returncode != 0:
        die(
            "git fetch origin failed in "
            f"{repo!r} ({fetched.stderr.strip() or 'no stderr'}) — refusing to compare "
            "against a possibly stale clone"
        )

    shown = subprocess.run(
        ["git", "-C", repo, "show", f"{ref}:{REGISTRY_PATH}"], capture_output=True, text=True
    )
    if shown.returncode != 0:
        die(f"git show {ref}:{REGISTRY_PATH} failed ({shown.stderr.strip()})")
    return shown.stdout


def main():
    ap = argparse.ArgumentParser(description="Class-split drift check for the global conventions.")
    ap.add_argument("--machine", default=os.path.expanduser("~/.claude/CLAUDE.md"))
    ap.add_argument("--repo", default=os.path.expanduser("~/Projects/skill-templates"))
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--verbose", action="store_true", help="print a unified diff per differing rule")
    args = ap.parse_args()

    if not os.path.isfile(args.machine):
        die(f"machine copy {args.machine!r} does not exist")
    with open(args.machine, encoding="utf-8") as f:
        machine_text = f.read()
    registry_text = read_registry(args.repo, args.ref)

    mach, mdups, _ = parse(machine_text, args.machine)
    reg, rdups, rorder = parse(registry_text, f"{args.ref}:{REGISTRY_PATH}")

    floor_broken, defaults, report = [], [], []
    default_dirs = []

    # The floor set itself is a fleet invariant. If the registry declares a different
    # set of floor rules than this script knows, the floor moved without this script
    # moving with it — every verdict below would be about the wrong five rules.
    declared = {i for i, (c, _) in reg.items() if c == "floor"}
    if declared != set(FLOOR_IDS):
        added, dropped = sorted(declared - set(FLOOR_IDS)), sorted(set(FLOOR_IDS) - declared)
        report.append(
            "FLOOR-SET  the registry's floor is not the five rules this script knows"
            + (f"; added: {', '.join(added)}" if added else "")
            + (f"; missing: {', '.join(dropped)}" if dropped else "")
        )
        report.append(
            "           → update FLOOR_IDS in fleet-check.py in the same commit that "
            "moves the floor."
        )
        floor_broken.append("(floor set)")

    for dup_list, where in ((mdups, args.machine), (rdups, f"{args.ref}:{REGISTRY_PATH}")):
        for d in sorted(set(dup_list)):
            cls = "floor" if d in FLOOR_IDS else "default"
            report.append(f"DUPLICATE  {d} appears more than once in {where} — class {cls}")
            if cls == "floor":
                floor_broken.append(d)

    for rid in sorted(set(mach) | set(reg)):
        mcls, mbody = mach.get(rid, (None, None))
        rcls, rbody = reg.get(rid, (None, None))
        # Effective class: floor if this script says so, or if EITHER node declares it.
        is_floor = rid in FLOOR_IDS or "floor" in (mcls, rcls)
        label = "FLOOR  " if is_floor else "DEFAULT"

        if mbody is None or rbody is None:
            missing = "machine" if mbody is None else "registry"
            dirn = "registry-ahead" if mbody is None else "machine-ahead"
            report.append(f"{label}    {rid}: missing from the {missing} copy ({dirn})")
            (floor_broken if is_floor else defaults).append(rid)
            if not is_floor:
                default_dirs.append(dirn)
            continue
        if mbody == rbody:
            if mcls != rcls:
                report.append(
                    f"{label}    {rid}: identical text but classed {mcls} on the machine and "
                    f"{rcls} in the registry"
                )
                (floor_broken if is_floor else defaults).append(rid)
            continue

        dirn, n_m, n_r = direction(mbody, rbody)
        report.append(f"{label}    {rid}: differs — {dirn} (+{n_m} machine-only/-{n_r} registry-only)")
        (floor_broken if is_floor else defaults).append(rid)
        if not is_floor:
            default_dirs.append(dirn)
        if args.verbose:
            for line in difflib.unified_diff(
                rbody, mbody, fromfile=f"registry:{rid}", tofile=f"machine:{rid}", lineterm=""
            ):
                report.append("           " + line)

    for line in report:
        print(line)

    if floor_broken:
        print(
            f"\nFLOOR DRIFT: {len(set(floor_broken))} rule(s) — "
            f"{', '.join(sorted(set(floor_broken)))}. Reconcile before long work: land the "
            f"machine's delta in the registry (PR), then copy out once."
        )
        return EXIT_FLOOR

    if defaults:
        dirs = sorted(set(default_dirs))
        print(
            f"\nDEFAULT drift only: {len(defaults)} rule(s) ({', '.join(dirs) or 'class-mismatch'}). "
            f"Not a blocker. Where the machine is ahead, land it in the registry; where the "
            f"registry is ahead, copy out. The floor is intact."
        )
        return EXIT_OK

    print("OK: machine and registry agree on every classified rule (floor and default).")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
