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
#   4. every registry `guard` for the skill is satisfied (reads registry.json),
#   5. the installed self-merge posture matches the one the repo's
#      `.claude/skill-profile.md` PINS for this skill (reads the profile).
#
# Checks 1-2 need no registry, so they also run for a REPO-ONLY skill (one kept in
# a repo's .claude/commands and absent from the index). Checks 3-4 cannot: a stamp
# is proof of a registry install and a guard comes from the index. Such a file is
# reported on what could be checked and exits 2 — never 0, so "not verified" can
# never be read as "passed". Check 5 needs the profile, not the registry, so it
# runs alongside 1-2 in every branch.
#
# Check 5 exists because check 4 structurally cannot cover it (#172). The
# `self-merge-posture` guard is `anyOf: [<gated wording>, <withheld wording>, …]`,
# which is deliberate — both postures are legitimate and repo-specific, so the guard
# fires when Critical Rule 5 is DELETED, not when a repo picks the other one. The
# consequence was that the one transition anyone cares about — withheld → gated —
# passed every mechanical check: `skill-lint` clean, `skill outdated` clean, and a
# diff that reads as a routine skill refresh. A repo that deliberately withholds
# unattended merge authority could have it granted back with nothing flagging it.
# A per-file guard cannot close that: the pinned intent lives in a DIFFERENT file.
# So the linter reads that file. The profile is the pin (it survives `skill update`);
# `.claude/commands/` is regenerated, so the installed file is the thing that drifts.
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
# Usage: scripts/skill-lint.sh <skill-name> <path/to/installed/skill.md> [registry.json] [skill-profile.md]
#
# The 4th argument is optional and rarely needed: when the linted file sits at the
# canonical <root>/.claude/commands/<name>.md, the profile is auto-discovered at
# <root>/.claude/skill-profile.md. Pass it explicitly when linting a file staged
# somewhere else (a temp dir, a pre-commit staging area). An explicitly passed path
# that does not exist is an environment error (exit 2) — the caller asked for a check
# that cannot run. An auto-discovered path that does not exist is simply an absence:
# most repos have no profile, and that must never be a failure.
#
# Exit:  0 clean · 1 lint failures (printed) · 2 not verifiable — a repo-only skill,
#        or a usage/environment error
set -euo pipefail

NAME="${1:-}"; FILE="${2:-}"
if [ -z "$NAME" ] || [ -z "$FILE" ]; then
  echo "usage: skill-lint.sh <skill-name> <skill-file> [registry.json] [skill-profile.md]" >&2
  exit 2
fi
REG="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/registry.json}"
PROFILE="${4:-}"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 2; }
[ -f "$FILE" ] || { echo "ERROR: skill file not found: $FILE" >&2; exit 2; }
if [ -n "$PROFILE" ] && [ ! -f "$PROFILE" ]; then
  echo "ERROR: skill profile not found: $PROFILE" >&2; exit 2
fi

python3 - "$NAME" "$FILE" "$REG" "$PROFILE" <<'PY'
import json, os, re, sys

name, path, reg_path = sys.argv[1], sys.argv[2], sys.argv[3]
profile_arg = sys.argv[4] if len(sys.argv) > 4 else ""
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

# 5) SELF-MERGE POSTURE — the installed Critical Rule 5 vs the posture the repo's
#    profile pins. Numbered 5 as the newest check but placed BEFORE 4: it reads the
#    profile, not the index, so like checks 1-2 it must run whether or not the registry
#    read below succeeds, and its findings must reach every reporting branch.
#
#    Scoped to the skills that HAVE the concept. Critical Rule 5 exists only in
#    autonomous-dev-flow and tackle-issues; no other skill has a posture to check and
#    none is invented for it.
POSTURE_SKILLS = ("autonomous-dev-flow", "tackle-issues")

#    The anchors are the `self-merge-posture` guard's `anyOf` alternates, split by
#    which posture each one belongs to — the mapping the guard itself cannot express,
#    which is exactly why the flip was invisible to it. skill-lint.test.sh asserts
#    every alternate in skill-guards.json appears here, so adding one there without
#    teaching this table fails the suite rather than silently going unclassified.
POSTURE_ANCHORS = {
    "gated": ("Merge only through the Unattended Merge Gate",),
    "withheld": ("NEVER merge, however clean the PR is",
                 "does not grant unattended merge authority"),
}


def discover_profile(skill_path):
    """<root>/.claude/commands/<name>.md → <root>/.claude/skill-profile.md, or ''.

    Deliberately narrow: only the canonical install location, and only when the
    profile actually exists. Auto-discovery must never turn a previously-passing
    invocation into a failure, and most repos have no profile at all.
    """
    cmds = os.path.dirname(os.path.abspath(skill_path))
    if os.path.basename(cmds) != "commands":
        return ""
    claude = os.path.dirname(cmds)
    if os.path.basename(claude) != ".claude":
        return ""
    cand = os.path.join(claude, "skill-profile.md")
    return cand if os.path.isfile(cand) else ""


def profile_posture(profile_text, skill):
    """The posture the profile PINS for `skill`: 'gated', 'withheld', or None.

    None means "the profile does not say", which is the common case and never a
    finding — a repo that has no opinion gets the template default by design.
    """
    # The `## <skill> Customizations` section, up to the next H1/H2. `#{1,2}[ \t]`
    # cannot match a `###` line (the third # is not whitespace), so the H3 blocks
    # inside the section do not terminate it.
    sec = re.search(
        r'^##[ \t]+' + re.escape(skill) + r'[ \t]+Customizations\b[^\n]*$'
        r'(.*?)(?=^#{1,2}[ \t]|\Z)',
        profile_text, re.M | re.S)
    if not sec:
        return None
    body = sec.group(1)

    # The `### Self-merge posture` block, up to the next heading of any level.
    blk = re.search(r'^#{3,4}[ \t]+Self-merge posture[ \t]*$(.*?)(?=^#{1,6}[ \t]|\Z)',
                    body, re.M | re.S | re.I)
    if blk:
        # The declaration is the block's BOLD LEAD — `**Withheld.**` / `**Gated.**`,
        # optionally as a list item. Matching a bare "withheld"/"gated" anywhere in
        # the block would invert half the fleet: every profile written in #144's pass
        # explains itself with "…the next update takes the template default — gated
        # self-merge", so a substring search reads a WITHHELD block as declaring
        # gated. The first bold lead wins; the rest of the block is rationale.
        m = re.search(r'^[ \t]*(?:[-*+][ \t]+)?\*\*[ \t]*(Withheld|Gated)\b',
                      blk.group(1), re.M | re.I)
        if m:
            return m.group(1).lower()

    # The one-line shorthand documented in docs/skill-profile-schema.md.
    m = re.search(r'^[ \t]*(?:[-*+][ \t]+)?(?:\*\*)?Self-merge posture(?:\*\*)?[ \t]*:'
                  r'[ \t]*(?:\*\*)?[ \t]*(withheld|gated)\b', body, re.M | re.I)
    return m.group(1).lower() if m else None


posture_note = ""   # appended to the clean line, so a pass says the pin was compared
profile_path = (profile_arg or discover_profile(path)) if name in POSTURE_SKILLS else ""
if profile_path:
    try:
        ptext = open(profile_path, encoding="utf-8").read()
    except OSError as e:
        # An AUTO-DISCOVERED profile that cannot be read is an absence — most repos have
        # none and that is correct. An EXPLICITLY passed one is different: the caller asked
        # for a check that then could not run, so reporting clean at exit 0 would let "not
        # verified" read as "passed", which is the whole reason exit 2 exists.
        if profile_arg:
            print(f"ERROR: skill profile '{profile_path}' could not be read: {e}", file=sys.stderr)
            sys.exit(2)
        ptext = ""
    declared = profile_posture(ptext, name)
    if declared:
        found = {p for p, anchors in POSTURE_ANCHORS.items()
                 if any(a in text for a in anchors)}
        if found == {declared}:
            posture_note = ", posture %s matches the profile" % declared
        elif found:
            # The finding this check exists for: Critical Rule 5 is present and states
            # the OTHER posture (or, mixed, states both). `found` empty is the DELETION
            # case, which is guard 4's job — reporting it here too would only double up
            # on a file that already fails loudly, so it falls through silently.
            says = " and ".join(p.upper() for p in sorted(found))
            quoted = "; ".join(
                '"%s"' % a for p in sorted(found) for a in POSTURE_ANCHORS[p] if a in text)
            fails.append(
                "self-merge posture mismatch: %s pins %s for %s, but the installed "
                "file states %s (%s). The profile is the pin and .claude/commands/ is "
                "regenerated on every `skill update` — re-apply the %s wording of "
                "Critical Rule 5, or change the profile if the posture really did move."
                % (profile_path, declared.upper(), name, says, quoted, declared.upper()))

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
              f"(markers, attribution, profile posture); guards and version stamp "
              f"NOT verified")
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
print(f"✓ {name}: clean ({len(guards)} guard(s) ok, stamp ok{posture_note})")
PY
