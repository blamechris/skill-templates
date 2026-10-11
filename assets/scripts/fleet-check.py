#!/usr/bin/env python3
"""Check the shared fleet root and provider adapters against the registry.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/fleet-check.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/fleet-check.py [--machine PATH] [--claude PATH]
      [--codex PATH] [--gemini PATH] [--codex-config PATH]
      [--project-dir PATH] [--repo PATH] [--ref REF] [--verbose]

`~/.fleet/AGENTS.md` is AUTHORED, not generated: it is edited in place on the
machine, and `assets/AGENTS.md` in the registry is the copy a new machine
bootstraps from. Claude imports the root; Codex and Gemini carry full copies.
These authored nodes can drift in both directions at once (#208), and
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
  2  the comparison could not be made honestly — fetch failed, a path is missing,
     an adapter cannot be read, or Codex's instruction size cap prevents a full
     load. Never 0: an incomplete check must not report agreement.
"""
import argparse
import ast
import difflib
import os
from pathlib import Path
import re
import subprocess
import sys
try:
    import tomllib
except ModuleNotFoundError:  # macOS still ships Python 3.9
    tomllib = None

# The floor is exactly these five rules. Widening or narrowing it is a deliberate
# fleet-wide act: change this tuple and assets/AGENTS.md's tokens in one
# commit, or the check below fails on purpose.
FLOOR_IDS = (
    "no-agent-attribution",
    "explicit-path-staging",
    "worktree-by-default",
    "no-secrets-in-committed-files",
    "seed-written-outside-any-worktree",
)

REGISTRY_PATH = "assets/AGENTS.md"
MIN_CODEX_DOC_MAX_BYTES = 65536

TOKEN = re.compile(r"^\s*<!--\s*(floor|default)\s*:\s*([a-z0-9][a-z0-9._-]*)\s*-->\s*$")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
IMPORT = re.compile(r"(?<![\w@])@(?:[~./A-Za-z0-9_-])[^\s`<>()\[\]]*")

EXIT_OK, EXIT_FLOOR, EXIT_CANNOT_VERIFY = 0, 1, 2


def die(msg):
    print(f"fleet-check: cannot verify — {msg}", file=sys.stderr)
    print("fleet-check: NO drift verdict was produced (this is not agreement).", file=sys.stderr)
    sys.exit(EXIT_CANNOT_VERIFY)


def read_text(path, label):
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        die(f"{label} {str(path)!r} is missing, unreadable, or invalid UTF-8 ({exc})")


def read_bytes(path, label):
    try:
        return Path(path).read_bytes()
    except OSError as exc:
        die(f"{label} {str(path)!r} is missing or unreadable ({exc})")


def active_markdown(text):
    """Remove fenced code and prose HTML comments, retaining rule-class tokens.

    Claude imports in fences or comments are examples, not instructions. Rule-class
    tokens are themselves HTML comments, so a standalone token is kept for the
    adapter's floor comparison.
    """
    out, in_comment, fence = [], False, None
    for line in text.splitlines():
        if fence:
            if re.fullmatch(r"\s{0,3}" + re.escape(fence[0]) +
                            "{" + str(len(fence)) + r",}\s*", line):
                fence = None
            out.append("")
            continue
        if not in_comment and TOKEN.match(line):
            cleaned = line
        else:
            pieces, rest = [], line
            while rest:
                if in_comment:
                    end = rest.find("-->")
                    if end < 0:
                        rest = ""
                    else:
                        rest, in_comment = rest[end + 3:], False
                else:
                    start = rest.find("<!--")
                    if start < 0:
                        pieces.append(rest)
                        rest = ""
                    else:
                        pieces.append(rest[:start])
                        rest, in_comment = rest[start + 4:], True
            cleaned = "".join(pieces)
        opener = FENCE.match(cleaned)
        if opener:
            fence = opener.group(1)
            out.append("")
            continue
        out.append(cleaned)
    return "\n".join(out)


def claude_extra_rules(text, where):
    """Require one active root import and return the adapter's own active text."""
    active = active_markdown(text)
    extras, found = [], 0
    for line in active.splitlines():
        # An inline code example is not an import. A path-like @ reference outside
        # code is conservatively treated as an additional import.
        scan = re.sub(r"(`+).*?\1", "", line)
        imports = IMPORT.findall(scan)
        if not imports:
            extras.append(line)
        elif line.strip() == "@~/.fleet/AGENTS.md" and imports == ["@~/.fleet/AGENTS.md"]:
            found += 1
        else:
            die(f"Claude adapter {where!r} has an additional or non-standalone import: {line.strip()!r}")
    if found != 1:
        die(f"Claude adapter {where!r} must contain exactly one active standalone "
            "@~/.fleet/AGENTS.md import")
    return "\n".join(extras)


def codex_config(path):
    text = read_text(path, "Codex config")
    if tomllib is not None:
        try:
            return tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            die(f"Codex config {path!r} is malformed TOML ({exc})")

    # Python 3.9 fallback: only these two top-level keys affect this check.
    # Refuse unsupported forms for either key, rather than guessing a byte cap.
    result, top_level = {}, True
    keys = ("project_doc_max_bytes", "project_doc_fallback_filenames")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("["):
            if not re.fullmatch(r"\[\[?.+\]\]?(?:\s*#.*)?", stripped):
                die(f"Codex config {path!r} has an unsupported section header")
            top_level = False
            continue
        if not top_level:
            continue
        match = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.*)$", stripped)
        if not match:
            die(f"Codex config {path!r} has malformed top-level syntax")
        key, value = match.groups()
        if key not in keys:
            continue
        if key in result:
            die(f"Codex config {path!r} repeats {key}")
        value = value.split("#", 1)[0].strip()
        if key == "project_doc_max_bytes":
            if not re.fullmatch(r"[0-9][0-9_]*", value):
                die(f"Codex config {path!r} has an invalid {key}")
            result[key] = int(value.replace("_", ""))
        else:
            try:
                result[key] = ast.literal_eval(value)
            except (SyntaxError, ValueError):
                die(f"Codex config {path!r} has an invalid {key}")
    return result


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
    """text -> ({id: (cls, [lines])}, [(duplicate id, declared class)]).

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
            dups.append((cur_id, cur_cls))
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


def codex_load_plan(args):
    """Return Codex's selected instruction files and its configured byte limit.

    Codex selects the first nonempty file per project directory: override, AGENTS,
    then configured fallback names. The sum is deliberately conservative, counting the global copy
    too. An over-limit result is inconclusive even if a particular Codex release
    might apply its limit only to the project chain.
    """
    config = codex_config(args.codex_config)
    cap = config.get("project_doc_max_bytes", 32768)
    if isinstance(cap, bool) or not isinstance(cap, int) or cap < MIN_CODEX_DOC_MAX_BYTES:
        die(
            f"Codex project_doc_max_bytes must be at least {MIN_CODEX_DOC_MAX_BYTES}; "
            f"{args.codex_config!r} sets {cap!r} (or uses Codex's 32768-byte default)"
        )
    fallback = config.get("project_doc_fallback_filenames", [])
    if not isinstance(fallback, list) or any(
        not isinstance(name, str) or not name or name in (".", "..")
        or Path(name).name != name for name in fallback
    ):
        die("Codex project_doc_fallback_filenames must be a list of plain file names")

    global_override = Path(args.codex).with_name("AGENTS.override.md")
    if os.path.lexists(global_override):
        if read_bytes(global_override, "Codex global override"):
            die(f"nonempty Codex global override {str(global_override)!r} shadows {args.codex!r}")

    try:
        project_dir = Path(args.project_dir).resolve(strict=True)
    except OSError as exc:
        die(f"project directory {args.project_dir!r} cannot be resolved ({exc})")
    if not project_dir.is_dir():
        die(f"project directory {args.project_dir!r} is not a directory")
    try:
        root_probe = subprocess.run(
            ["git", "-C", str(project_dir), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True,
        )
    except OSError as exc:
        die(f"Git root probe failed in {str(project_dir)!r} ({exc})")
    if root_probe.returncode == 0:
        if not root_probe.stdout.strip():
            die(f"Git root probe returned no path in {str(project_dir)!r}")
        project_root = Path(root_probe.stdout.strip()).resolve()
    elif "not a git repository (or any of the parent directories)" in root_probe.stderr:
        project_root = project_dir
    else:
        die(f"Git root probe failed in {str(project_dir)!r} "
            f"({root_probe.stderr.strip() or 'no stderr'})")
    if project_root not in (project_dir, *project_dir.parents):
        die(f"Git root {str(project_root)!r} is not an ancestor of {str(project_dir)!r}")
    chain = [project_dir]
    while chain[-1] != project_root:
        chain.append(chain[-1].parent)
    chain.reverse()

    selected = [Path(args.codex)]
    for directory in chain:
        for name in ("AGENTS.override.md", "AGENTS.md", *fallback):
            candidate = directory / name
            if os.path.lexists(candidate):
                data = read_bytes(candidate, "Codex instruction file")
                if data:
                    selected.append(candidate)
                    break
    total = 0
    for path in selected:
        total += len(read_bytes(path, "Codex instruction file"))
    if total > cap:
        die(
            f"Codex instruction chain is {total} bytes across {len(selected)} file(s), "
            f"above project_doc_max_bytes={cap}; full loading cannot be verified"
        )
    return selected, total, cap


def verify_adapters(args):
    claude = read_text(args.claude, "Claude adapter")
    extra = claude_extra_rules(claude, args.claude)
    codex = read_text(args.codex, "Codex adapter")
    gemini = read_text(args.gemini, "Gemini adapter")
    selected, total, cap = codex_load_plan(args)
    print(f"ADAPTER  Claude imports the fleet root; Codex load plan {total}/{cap} bytes "
          f"across {len(selected)} file(s).")
    return extra, codex, gemini, cap


def main():
    ap = argparse.ArgumentParser(description="Class-split drift check for the fleet root and adapters.")
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    ap.add_argument("--machine", default=os.path.expanduser("~/.fleet/AGENTS.md"),
                    help="authored machine fleet root")
    ap.add_argument("--claude", default=os.path.expanduser("~/.claude/CLAUDE.md"))
    ap.add_argument("--codex", default=os.path.join(codex_home, "AGENTS.md"))
    ap.add_argument("--gemini", default=os.path.expanduser("~/.gemini/GEMINI.md"))
    ap.add_argument("--codex-config", default=os.path.join(codex_home, "config.toml"))
    ap.add_argument("--project-dir", default=os.getcwd(),
                    help="current Codex project directory for instruction-chain sizing")
    ap.add_argument("--repo", default=os.path.expanduser("~/Projects/skill-templates"))
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--verbose", action="store_true", help="print a unified diff per differing rule")
    args = ap.parse_args()

    machine_text = read_text(args.machine, "machine fleet root")
    registry_text = read_registry(args.repo, args.ref)
    claude_extra, codex_text, gemini_text, cap = verify_adapters(args)
    for where, text in ((args.machine, machine_text), (f"{args.ref}:{REGISTRY_PATH}", registry_text)):
        if len(text.encode("utf-8")) > cap:
            die(f"fleet root {where!r} exceeds Codex project_doc_max_bytes={cap}")

    reg, rdups, _ = parse(registry_text, f"{args.ref}:{REGISTRY_PATH}")
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

    for d, duplicate_class in sorted(set(rdups)):
        cls = "floor" if d in FLOOR_IDS or "floor" in (duplicate_class, reg[d][0]) else "default"
        report.append(f"DUPLICATE  {d} appears more than once in {args.ref}:{REGISTRY_PATH} — class {cls}")
        if cls == "floor":
            floor_broken.append(d)

    claude_effective = machine_text
    if normalize(claude_extra.splitlines()):
        claude_effective += "\n<!--default:claude-adapter-local-->\n" + claude_extra
    for where, node_text in ((args.machine, machine_text), (args.claude, claude_effective),
                             (args.codex, codex_text),
                             (args.gemini, gemini_text)):
        mach, mdups, _ = parse(node_text, where)
        for d, duplicate_class in sorted(set(mdups)):
            cls = "floor" if d in FLOOR_IDS or "floor" in (duplicate_class, mach[d][0]) else "default"
            report.append(f"DUPLICATE  {d} appears more than once in {where} — class {cls}")
            if cls == "floor":
                floor_broken.append(f"{where}:{d}")

        for rid in sorted(set(mach) | set(reg)):
            mcls, mbody = mach.get(rid, (None, None))
            rcls, rbody = reg.get(rid, (None, None))
            # Effective class: floor if this script says so, or if EITHER node declares it.
            is_floor = rid in FLOOR_IDS or "floor" in (mcls, rcls)
            label = "FLOOR  " if is_floor else "DEFAULT"

            if mbody is None or rbody is None:
                missing = where if mbody is None else "registry"
                dirn = "registry-ahead" if mbody is None else "machine-ahead"
                report.append(f"{label}    {where}: {rid}: missing from {missing} ({dirn})")
                (floor_broken if is_floor else defaults).append(f"{where}:{rid}")
                if not is_floor:
                    default_dirs.append(dirn)
                continue
            if mbody == rbody:
                if mcls != rcls:
                    report.append(
                        f"{label}    {where}: {rid}: identical text but classed {mcls} "
                        f"locally and {rcls} in the registry"
                    )
                    (floor_broken if is_floor else defaults).append(f"{where}:{rid}")
                continue

            dirn, n_m, n_r = direction(mbody, rbody)
            report.append(f"{label}    {where}: {rid}: differs — {dirn} "
                          f"(+{n_m} machine-only/-{n_r} registry-only)")
            (floor_broken if is_floor else defaults).append(f"{where}:{rid}")
            if not is_floor:
                default_dirs.append(dirn)
            if args.verbose:
                for line in difflib.unified_diff(
                    rbody, mbody, fromfile=f"registry:{rid}", tofile=f"{where}:{rid}", lineterm=""
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

    print("OK: machine and registry agree on every classified rule (floor and default); "
          "Claude import and Codex load plan verified.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
