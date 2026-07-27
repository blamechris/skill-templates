#!/usr/bin/env bash
# skill-lint.sh — deterministic validation of an INSTALLED skill against the registry.
#
# The pull model moved render-safety from a CI gate (deploy.sh validate_output) to the
# installing agent's self-checks. This restores a MECHANICAL gate the agent runs after
# `skill add`, and that a consumer pre-commit hook or CI can run too. It checks:
#   1. no residual {{CUSTOMIZE markers (outside backticked mentions),
#   2. no attribution footer in the tail — a line that OPENS with "Generated with
#      …Claude" / "🤖 …generated" / a real "Co-Authored-By: <value>" trailer.
#      Prose that forbids those strings (create-pr's Critical Rules) is not a footer,
#      so the match is line-anchored; see the note in check 2 below.
#   3. a well-formed version stamp alone on the last non-blank line,
#   4. every registry `guard` for the skill is satisfied (reads registry.json).
#
# Checks 1-2 need no registry, so they also run for a REPO-ONLY skill (one kept in
# a repo's .claude/commands and absent from the index). Checks 3-4 cannot: a stamp
# is proof of a registry install and a guard comes from the index. Such a file is
# reported on what could be checked and exits 2 — never 0, so "not verified" can
# never be read as "passed".
#
# "Absent from the index" is two conditions, not one, and the STAMP tells them apart:
#   - unstamped — a genuine repo-only skill. There is nothing to verify and nothing
#     wrong. Exit 2 (`~`).
#   - stamped — the file claims a registry install that this index does not know
#     about: a stale clone, a renamed or retired skill, a typo'd <skill-name>, or
#     the wrong registry.json. Its guards exist and were skipped. Exit 1 (`✗`).
# Both exited 2 before, so the documented "fail on 1, tolerate 2" tolerated the
# second — and with it every guard miss hiding behind a stale index. The exit code
# carries the split (not just the wording) so that contract needs no amendment: a
# consumer that already fails on 1 is fixed without touching its hook.
#
# Usage: scripts/skill-lint.sh <skill-name> <path/to/installed/skill.md> [registry.json]
# Exit:  0 clean · 1 lint failures (printed) · 2 not verifiable — a repo-only skill,
#        or a usage/environment error
set -euo pipefail

NAME="${1:-}"; FILE="${2:-}"
if [ -z "$NAME" ] || [ -z "$FILE" ]; then
  echo "usage: skill-lint.sh <skill-name> <skill-file> [registry.json]" >&2; exit 2
fi
REG="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/registry.json}"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 2; }
[ -f "$FILE" ] || { echo "ERROR: skill file not found: $FILE" >&2; exit 2; }

python3 - "$NAME" "$FILE" "$REG" <<'PY'
import json, re, sys

name, path, reg_path = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
fails = []

# 1) residual {{CUSTOMIZE markers — a marker is "real" unless the char immediately
#    before it is a backtick (matches deploy.sh's (^|[^`])\{\{CUSTOMIZE semantics).
for i, ln in enumerate(lines, 1):
    for m in re.finditer(r'\{\{CUSTOMIZE', ln):
        before = ln[m.start() - 1] if m.start() > 0 else ''
        if before != '`':
            # %-format avoids confusion over the literal "{{" in an f-string.
            fails.append("residual {{CUSTOMIZE marker at line %d: %s" % (i, ln.strip()[:70]))
            break

# 2) attribution footer in the last ~15 lines. Catches the git trailer
#    ("Co-Authored-By: Claude <…>") and the Claude Code footer
#    ("🤖 Generated with [Claude Code](…)").
#
#    A footer is a LINE, not a phrase — it opens its own line, at column 0, in a
#    fixed form. Prose that FORBIDS those strings mentions them mid-sentence and
#    quoted, e.g. create-pr's load-bearing first Critical Rule:
#        1. **NO attribution** — No Co-Authored-By, no "Generated with Claude", …
#    The old patterns matched anywhere on the line, so they flagged that
#    prohibition as the violation. `skill add` strips the trailing
#    "## Customization Points" section, which pulls the rule inside this 15-line
#    tail window — so every consumer repo failed on the rule that exists to
#    prevent the very thing being checked for.
#
#    Two narrowings kill the false positive without weakening the gate:
#      a. anchor to the start of the line's CONTENT — not column 0; see the
#         note below the negation paragraph for what that means and why.
#         A real footer is never mid-sentence, never behind a "No " or a
#         quote mark — which also subsumes the "skip lines quoting the
#         string" heuristic, since an opening quote is not a footer.
#      b. require the trailer form to LOOK like a trailer: `Co-Authored-By:`
#         followed by a value. The bare phrase ("no Co-Authored-By trailers")
#         is description; the colon-plus-value form is attribution. Any
#         co-author counts, not just Claude — the policy is zero attribution.
#
#    Deliberately NOT added: a keyword-based "this line is describing a footer"
#    escape hatch. Scanning for negations ("no", "never") risks the opposite,
#    worse failure — `\bno\b` matches inside `<no-reply@anthropic.com>`, which
#    would silence a genuine trailer. Anchoring has no such false-negative edge.
#    Anchor to the start of the line's CONTENT, not to column 0. These are
#    markdown files, so a footer routinely arrives wearing decoration: a list
#    bullet, a blockquote marker, emphasis, an HTML comment (the version stamp
#    is one), an em-dash, an emoji. A column-0 anchor lets every one of those
#    through — and `- 🤖 Generated with [Claude Code](…)` is simply the real
#    footer inside a list.
#
#    The lead therefore skips any run of NON-WORD characters, plus an optional
#    ordered-list marker (`1.` / `1)` — a digit is a word character, so it has
#    to be named explicitly).
#
#    Quote marks are deliberately NOT skippable, and that is what keeps the
#    prose case dead: a footer never opens with a quote, while a line describing
#    one quotes it. Word characters are not skippable either, so "No
#    Co-Authored-By" and `no "Generated with Claude"` stay unmatched — the
#    phrase sits behind prose the anchor cannot cross.
_LEAD = r'^[^\w"\']*(?:\d+[.)][^\w"\']*)?'
attribution_res = (
    # 🤖 Generated with [Claude Code](…) — emoji optional, "claude" required.
    re.compile(_LEAD + r'(?:🤖[ \t]*)?generated with\b.*\bclaude', re.I),
    # 🤖 <anything> generated … — the emoji alone is attribution decoration.
    re.compile(_LEAD + r'🤖.*\bgenerated\b', re.I),
    # Co-Authored-By: <value> — a real trailer, not the phrase.
    re.compile(_LEAD + r'co-authored-by:[ \t]*\S', re.I),
)
for ln in lines[-15:]:
    if any(r.search(ln) for r in attribution_res):
        fails.append(f"attribution footer: {ln.strip()[:70]}")

# 3) well-formed version stamp as the last non-empty line, naming this skill.
#    Collected separately from checks 1-2: the stamp is proof of a registry
#    INSTALL, so a repo-only skill has none by definition and demanding one would
#    fail every such file. Merged into `fails` below only once the skill is known
#    to be a registry skill.
stamp_fails = []
stamp_re = re.compile(
    r'<!--\s*skill-templates:\s+(\S+)\s+([0-9a-f]{7,40})\s+(\d{4}-\d{2}-\d{2})\s*-->'
)
nonempty = [l for l in lines if l.strip()]
# fullmatch, not search: the stamp must BE the last line, not merely appear in
# it. With a substring match, anything riding along after the stamp was invisible
# to every check — check 2 is line-anchored, so a footer sharing the stamp's line
# does not start its line and is skipped, while check 3 was satisfied by finding
# the stamp somewhere in it. Both `… --> Co-Authored-By: Claude <…>` and
# `… --> 🤖 Generated with Claude Code` linted clean before this. Closing it here
# rather than loosening check 2's anchor rejects trailing junk of every kind.
m = stamp_re.fullmatch(nonempty[-1].strip()) if nonempty else None
if not m:
    # Show the line, escaped. `.strip()` removes Unicode whitespace, so the
    # survivors that fail here are the ones that render as nothing — a zero-width
    # space or a BOM mid-line leaves a stamp that looks pixel-identical to a valid
    # one, and a message without the bytes is undebuggable.
    saw = repr(nonempty[-1]) if nonempty else "(no non-blank lines)"
    stamp_fails.append("missing/malformed version stamp "
                 "(expected '<!-- skill-templates: <name> <hash> <date> -->' as the last "
                 "non-blank line, alone on it — trailing blank lines and surrounding "
                 f"whitespace are fine, anything else on the line is not). Last line was: {saw}")
elif m.group(1) != name:
    # repr() here too: an invisible character inside the NAME renders the two
    # strings identically, so a bare interpolation reads "stamp names 'demo',
    # expected 'demo'" and tells the reader nothing.
    stamp_fails.append(f"stamp names {m.group(1)!r}, expected {name!r}")

# 3b) PROVENANCE — does the file bear a stamp marker at all? A different question
#     from check 3's "is the stamp well formed", and deliberately looser, because
#     the unregistered path below asks only "was this file ever installed from the
#     registry". A mangled, misnamed, truncated or hand-forged stamp answers yes
#     just as loudly as a good one — louder, in fact: those are the files that
#     most need looking at, and keying on `not stamp_fails` would route exactly
#     them back into the tolerated bucket.
#
#     Anchored to the start of the line's content, so prose quoting the format
#     is not provenance — skill.md's own step 5 says to end the file with
#     `<!-- skill-templates: <name> <hash> <date> -->` inside backticks, and a
#     skill that documents skills must not be read as one that was installed.
#     A raw stamp line at the head of a fenced example would count; that is the
#     conservative direction (it asks for a look), and no file among the 337
#     installed under ~/Projects carries a second marker or a marker anywhere
#     but the last non-blank line.
stamped = any(re.match(r'\s*<!--\s*skill-templates:', ln) for ln in lines)

# 4) registry guards — each guard passes if ANY of its anyOf regexes matches.
#    A missing registry or an unknown skill is an ENVIRONMENT error (exit 2), not a
#    silent pass — otherwise the "deterministic gate" could green-light unchecked.
try:
    with open(reg_path, encoding="utf-8") as f:
        reg = json.load(f)
except FileNotFoundError:
    print(f"ERROR: registry not found at {reg_path} — cannot verify guards. "
          f"Pass the registry path or run scripts/build-index.sh.", file=sys.stderr)
    sys.exit(2)

entry = next((s for s in reg.get("skills", []) if s.get("name") == name), None)
if entry is None:
    # Two very different files land here, and `stamped` is what separates them.
    #
    # STAMPED — not a repo-only skill at all. The file was installed from a
    # registry; this index just does not know it (stale clone, renamed or retired
    # skill, typo'd <skill-name>, wrong registry.json). Its guards are real and
    # went unapplied, so the SAME corruption that reports `✗ guard miss` against
    # a current index reported `~ clean` against a stale one — and the documented
    # "tolerate 2" swallowed it. That is a finding about the file, so it is
    # reported as one, at exit 1, with the stamp checks folded back in: a file
    # claiming a registry install is held to the stamp's shape.
    if stamped:
        fails.insert(0, f"stamped as a registry install but absent from the index "
                        f"({reg_path}) — stale index, a renamed/retired skill, a "
                        f"typo'd skill name, or the wrong registry")
        fails.extend(stamp_fails)
        print(f"ERROR: '{name}' is not in the registry index ({reg_path}), yet the file "
              f"carries a stamp marker — a registry install the index does not know, "
              f"not a repo-only skill. Cannot verify guards.", file=sys.stderr)
        print(f"✗ {name}: {len(fails)} issue(s); guards NOT verified "
              f"(the skill is absent from the index)")
        for f in fails:
            print(f"  - {f}")
        sys.exit(1)

    # UNSTAMPED — a repo-only skill (CLAUDE.md names `commit`, `qa-update`,
    # `tdd-feature` …), maintained directly in a repo's .claude/commands and
    # legitimately absent from the index. Checks 1-2 are registry-independent and
    # apply to them perfectly well, so report those before bailing out (check 3
    # does NOT: a stamp is proof of a registry install, so requiring one would
    # fail every repo-only file) — `commit.md` is a
    # skill about writing commits, which is exactly where an attribution footer
    # would do damage, and it was the one class the linter refused to inspect.
    #
    # The exit code still distinguishes "found problems" (1) from "could not
    # verify guards" (2), so nothing here can green-light an unchecked skill.
    print(f"ERROR: '{name}' is not in the registry index ({reg_path}) — "
          f"stale index, or not a registry skill. Cannot verify guards.", file=sys.stderr)
    if fails:
        print(f"✗ {name}: {len(fails)} issue(s) from the registry-independent checks "
              f"(markers, attribution); guards and version stamp NOT verified")
        for f in fails:
            print(f"  - {f}")
        sys.exit(1)
    print(f"~ {name}: clean on markers and attribution; guards and version stamp "
          f"NOT verified (unstamped and absent from the index — a repo-only skill)")
    sys.exit(2)
fails.extend(stamp_fails)   # a registry skill: the stamp is required after all
guards = entry.get("guards", [])

for g in guards:
    if not any(re.search(p, text) for p in g.get("anyOf", [])):
        fails.append(f"guard miss: {g.get('label')} (none of {g.get('anyOf')} present)")

if fails:
    print(f"✗ {name}: {len(fails)} issue(s)")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print(f"✓ {name}: clean ({len(guards)} guard(s) ok, stamp ok)")
PY
