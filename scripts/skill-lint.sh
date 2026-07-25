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
#   3. a well-formed version stamp that IS the last line, nothing after it,
#   4. every registry `guard` for the skill is satisfied (reads registry.json).
#
# Usage: scripts/skill-lint.sh <skill-name> <path/to/installed/skill.md> [registry.json]
# Exit:  0 clean · 1 lint failures (printed) · 2 usage/environment error
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

# 3) well-formed version stamp as the last non-empty line, naming this skill
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
    fails.append("missing/malformed version stamp "
                 "(expected '<!-- skill-templates: <name> <hash> <date> -->' as the last line, "
                 "with nothing after it)")
elif m.group(1) != name:
    fails.append(f"stamp names '{m.group(1)}', expected '{name}'")

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
    print(f"ERROR: '{name}' is not in the registry index ({reg_path}) — "
          f"stale index, or not a registry skill. Cannot verify guards.", file=sys.stderr)
    sys.exit(2)
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
