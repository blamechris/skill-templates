#!/usr/bin/env bash
# skill-lint.test.sh — regression tests for scripts/skill-lint.sh.
#
# Run: ./scripts/skill-lint.test.sh
# Exit: 0 all pass · 1 a case failed
#
# Primary case under guard (the reason this file exists): the attribution-footer
# check must distinguish a REAL footer from prose that FORBIDS one. create-pr's
# first Critical Rule is
#     1. **NO attribution** — No Co-Authored-By, no "Generated with Claude", …
# and `skill add` strips the trailing "## Customization Points" section, which
# pulls that rule inside the 15-line tail window the check scans. An unanchored
# regex flagged the prohibition as the violation, failing every consumer repo on
# the rule that exists to prevent attribution. That rule is load-bearing and must
# not be reworded to appease the linter, so the LINTER is what stays fixed here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/skill-lint.sh"
STAMP='<!-- skill-templates: demo 1234abc 2026-06-03 -->'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic registry for the shape cases: one guarded skill ("demo") plus the
# real "create-pr" name, so guard behaviour is exercised without depending on
# whatever guards the committed registry happens to carry today.
#
# autonomous-dev-flow / tackle-issues carry a copy of the real `self-merge-posture`
# guard, because the posture section below needs the guard and the new check to
# disagree in the right way: the guard is satisfied by EITHER wording (that is the
# design, and the reason the flip was invisible), so a posture mismatch has to be
# the only finding on a file the guard is perfectly happy with.
cat > "$TMP/registry.json" <<'JSON'
{
  "registry": "test",
  "skillCount": 4,
  "skills": [
    { "name": "demo", "hash": "1234abc", "lines": 1, "description": "d",
      "guards": [ { "label": "load-bearing", "anyOf": ["LOAD BEARING MARKER"] } ] },
    { "name": "create-pr", "hash": "1234abc", "lines": 1, "description": "d" },
    { "name": "autonomous-dev-flow", "hash": "1234abc", "lines": 1, "description": "d",
      "guards": [ { "label": "self-merge-posture", "anyOf": [
        "Merge only through the Unattended Merge Gate",
        "NEVER merge, however clean the PR is",
        "does not grant unattended merge authority" ] } ] },
    { "name": "tackle-issues", "hash": "1234abc", "lines": 1, "description": "d",
      "guards": [ { "label": "self-merge-posture", "anyOf": [
        "Merge only through the Unattended Merge Gate",
        "NEVER merge, however clean the PR is",
        "does not grant unattended merge authority" ] } ] }
  ]
}
JSON

PASS=0; FAIL=0

# expect <clean|dirty> <label> <body...>  — body is written as the skill file.
# For "dirty", an optional -m <substring> asserts the reported reason.
expect() {
  local want="$1" label="$2" want_msg="" want_rc=""
  shift 2
  while :; do
    case "${1:-}" in
      -m) want_msg="$2"; shift 2 ;;
      -rc) want_rc="$2"; shift 2 ;;   # assert the EXACT code: 1 (findings) vs 2 (unverifiable)
      *) break ;;
    esac
  done
  local body="$1" skill="${2:-demo}"
  local f="$TMP/case.md"
  printf '%s\n' "$body" > "$f"

  local out rc
  out="$($LINT "$skill" "$f" "$TMP/registry.json" 2>&1)"; rc=$?

  local got="clean"; [ "$rc" -ne 0 ] && got="dirty"
  if [ -n "$want_rc" ] && [ "$rc" -ne "$want_rc" ]; then
    printf '  FAIL - %s\n    wanted exit %s, got %s:\n%s\n' \
      "$label" "$want_rc" "$rc" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    FAIL=$((FAIL + 1)); return
  fi
  if [ "$got" != "$want" ]; then
    printf '  FAIL - %s\n    wanted %s, got %s (rc=%d):\n%s\n' \
      "$label" "$want" "$got" "$rc" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$want_msg" ] && ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    printf '  FAIL - %s\n    reason did not mention %q:\n%s\n' \
      "$label" "$want_msg" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    FAIL=$((FAIL + 1)); return
  fi
  printf '  ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

# A minimal clean skill body; $1 is spliced in just above the version stamp so
# it lands well inside the 15-line tail window.
skill_with() {
  printf '# /demo\n\nDoes a thing.\n\nLOAD BEARING MARKER\n\n## Rules\n\n%s\n%s' "$1" "$STAMP"
}

echo "attribution: prose that forbids a footer is not a footer"

expect clean "create-pr's first Critical Rule survives verbatim (the false positive)" \
  "$(skill_with '1. **NO attribution** — No Co-Authored-By, no "Generated with Claude", no AI mentions. Zero Attribution Policy.')"

expect clean 'bare "Co-Authored-By" phrase at line start (no colon, no value)' \
  "$(skill_with 'Co-Authored-By trailers are forbidden in this repo.')"

expect clean 'quoted footer string at line start' \
  "$(skill_with '"Generated with Claude Code" must never appear in a commit.')"

expect clean 'mid-line mention behind a negation' \
  "$(skill_with 'Never append 🤖 Generated with Claude Code to the PR body.')"

expect clean 'trailer named mid-line as an example of what not to write' \
  "$(skill_with 'Strip any Co-Authored-By: Claude line before committing.')"

echo "attribution: real footers still fail"

expect dirty 'Claude Code footer with emoji' -m 'attribution footer' \
  "$(skill_with '🤖 Generated with [Claude Code](https://claude.com/claude-code)')"

expect dirty 'Claude Code footer without emoji' -m 'attribution footer' \
  "$(skill_with 'Generated with [Claude Code](https://claude.com/claude-code)')"

expect dirty 'emoji + generated, no "with"' -m 'attribution footer' \
  "$(skill_with '🤖 This file was generated automatically.')"

expect dirty 'Co-Authored-By trailer' -m 'attribution footer' \
  "$(skill_with 'Co-Authored-By: Claude <noreply@anthropic.com>')"

expect dirty 'co-authored-by trailer, git-canonical lowercase' -m 'attribution footer' \
  "$(skill_with 'Co-authored-by: Claude <noreply@anthropic.com>')"

expect dirty 'trailer crediting a non-Claude co-author (zero attribution, not just Claude)' \
  -m 'attribution footer' \
  "$(skill_with 'Co-Authored-By: Some Bot <bot@example.com>')"

expect dirty 'indented footer (leading whitespace is not cover)' -m 'attribution footer' \
  "$(skill_with '    🤖 Generated with [Claude Code](https://claude.com/claude-code)')"

expect dirty 'indented footer, no emoji (whitespace tolerance of pattern 1)' -m 'attribution footer' \
  "$(skill_with '    Generated with [Claude Code](https://claude.com/claude-code)')"

expect dirty 'indented trailer, no emoji (whitespace tolerance of pattern 3)' -m 'attribution footer' \
  "$(skill_with '  Co-Authored-By: Claude <noreply@anthropic.com>')"

# These are markdown files: decoration is the normal way a footer arrives. An
# anchor at column 0 would treat every one of these prefixes as cover. The
# HTML-comment case matters most — every installed skill ENDS with one, so it is
# the least suspicious place on the page to hide a footer.
echo "attribution: decoration is not cover"

expect dirty 'footer in a list item' -m 'attribution footer' \
  "$(skill_with '- 🤖 Generated with [Claude Code](https://claude.com/claude-code)')"

expect dirty 'footer in a blockquote' -m 'attribution footer' \
  "$(skill_with '> Generated with Claude Code')"

expect dirty 'footer inside an HTML comment' -m 'attribution footer' \
  "$(skill_with '<!-- Generated with Claude Code -->')"

expect dirty 'footer wrapped in emphasis' -m 'attribution footer' \
  "$(skill_with '**Generated with Claude Code**')"

expect dirty 'trailer in an ordered list item' -m 'attribution footer' \
  "$(skill_with '1. Co-Authored-By: Claude <noreply@anthropic.com>')"

expect dirty 'trailer in an ordered list item, paren form' -m 'attribution footer' \
  "$(skill_with '1) Co-Authored-By: Some Bot <bot@example.com>')"

expect dirty 'footer behind stacked decoration' -m 'attribution footer' \
  "$(skill_with '   > - **🤖 Generated with Claude Code**')"

expect dirty 'footer behind a non-robot emoji' -m 'attribution footer' \
  "$(skill_with '✨ Generated with Claude')"

# The flip side of the anchor: a quote mark is NOT skippable, because a footer
# never opens with one and a line describing a footer quotes it.
expect clean 'quoted mention behind prose stays clean' \
  "$(skill_with 'The footer "Generated with Claude Code" is forbidden.')"

expect clean 'single-quoted trailer mention stays clean' \
  "$(skill_with "Do not write 'Co-Authored-By:' anywhere.")"

echo "attribution: the check is scoped to the tail window"

# 20 filler lines push the footer out of the last 15 — documents the scope so a
# future window change is a deliberate edit, not an accident.
expect clean 'footer above the 15-line tail window is out of scope' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n%s\n%s' \
      "$(for i in $(seq 20); do echo "filler line $i"; done)" "$STAMP")"

echo "the other checks still work (guard against a refactor gutting them)"

expect dirty 'residual {{CUSTOMIZE marker' -m 'residual' \
  "$(skill_with '- Repo test command: {{CUSTOMIZE: test command}}')"

expect clean 'backticked {{CUSTOMIZE mention is allowed' \
  "$(skill_with '- Markers look like `{{CUSTOMIZE: ...}}` in the template.')"

expect dirty 'missing version stamp' -m 'version stamp' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nNothing to see.\n')"

expect dirty 'stamp naming the wrong skill' -m "expected 'create-pr'" \
  "$(skill_with 'All good.')" create-pr

# The stamp must BE the last line, not merely appear in it. A footer sharing the
# stamp's line is skipped by check 2 (it does not start its line) and used to
# satisfy check 3 (which searched rather than matched), so it was invisible to
# the whole linter.
expect dirty 'trailer riding the stamp line' -m 'version stamp' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n%s Co-Authored-By: Claude <noreply@anthropic.com>\n' "$STAMP")"

expect dirty 'footer riding the stamp line' -m 'version stamp' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n%s 🤖 Generated with Claude Code\n' "$STAMP")"

expect dirty 'prose riding the stamp line' -m 'version stamp' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n%s and one more thing\n' "$STAMP")"

# Guards the `.strip()` specifically, not the fullmatch: this case stays green on
# a straight revert to `search` and goes red only if the strip is dropped.
expect clean 'stamp with surrounding whitespace is still valid' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n   %s   \n' "$STAMP")"

expect dirty 'guard miss when a load-bearing section is stripped' -m 'guard miss' \
  "$(printf '# /demo\n\nDoes a thing.\n\n## Rules\n\nCustomization dropped the marker.\n%s' "$STAMP")"

# A stamp with an invisible character renders pixel-identical to a valid one, so
# the failure has to show the bytes or it cannot be debugged.
expect dirty 'stamp failure escapes the offending line' -m '\u200b' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n%s\xe2\x80\x8b' "$STAMP")"

echo "repo-only skills (unstamped): registry-independent checks still report"

# Skills maintained directly in a repo (commit, qa-update, tdd-feature …) are
# legitimately absent from the index. Checks 1-2 do not need the registry and
# must still run for them. The stamp and guard verdicts are both
# unavailable: a stamp is proof of a registry install, so a repo-only file has
# none by definition.
expect dirty 'unstamped repo-only skill still reports a residual marker' \
  -m 'residual {{CUSTOMIZE' -rc 1 \
  "$(printf '# /repo-only-demo\n\nRepo test command: {{CUSTOMIZE: test command}}\n')" \
  repo-only-demo

# The realistic shape: a repo-only skill has NO version stamp, because it was
# never installed from the registry. None of the 9 on this machine has one. This
# is the case that pins the decision to skip check 3 for unregistered skills —
# without it, merging stamp findings before the registry read passes the suite
# while failing every real repo-only file.
expect dirty 'unstamped repo-only skill is unverified, NOT a stamp failure' \
  -m 'clean on markers and attribution' -rc 2 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n\n## Usage\n\nRun it.')" \
  repo-only-demo

expect dirty 'unstamped repo-only skill still reports a real footer' \
  -m 'attribution footer' -rc 1 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)')" \
  repo-only-demo

echo "stamped but absent from the index: a stale index is a finding, not a shrug"

# The split this section exists for. "Absent from the index" used to be one exit
# code (2) for two conditions: a genuine repo-only skill, and a REGISTRY skill the
# index does not know — a stale clone, a renamed/retired skill, a typo'd name, the
# wrong registry.json. The documented consumer contract is "fail on 1, tolerate 2",
# so the second was tolerated, and with it every guard miss hiding behind a stale
# index. The stamp separates them: it is proof of a registry install, so a stamped
# file the index has never heard of is a finding (exit 1), not an absence of one.
#
# Every case here asserts -rc explicitly. clean/dirty cannot pin this change: both
# conditions were already "dirty", which is exactly why the ambiguity survived.
expect dirty 'stamped skill absent from the index is a finding (exit 1, not 2)' \
  -m 'stamped as a registry install but absent from the index' -rc 1 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n<!-- skill-templates: repo-only-demo 1234abc 2026-06-03 -->')" \
  repo-only-demo

# The issue's headline reproduction. This file lost its load-bearing marker — a
# `✗ guard miss` at exit 1 when the index knows the skill. Against an index that
# does NOT, the guard cannot run at all; before, that came back `~ clean` at exit 2
# and a "tolerate 2" hook accepted the corruption. It must now match the exit code
# of the same corruption seen with a current index.
expect dirty 'guard-miss corruption behind a stale index is no longer tolerated' \
  -m 'guards NOT verified' -rc 1 \
  "$(printf '# /demo-stale\n\nDoes a thing.\n\n## Rules\n\ncustomization dropped the marker\n<!-- skill-templates: demo-stale 1234abc 2026-06-03 -->')" \
  demo-stale

# The registry-independent findings must still be printed on this branch too —
# the exit code changed, the reporting did not.
expect dirty 'stamped + absent still reports an attribution footer' \
  -m 'attribution footer' -rc 1 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n<!-- skill-templates: repo-only-demo 1234abc 2026-06-03 -->')" \
  repo-only-demo

# A typo'd <skill-name> argument reaches the same branch, and the stamp names the
# skill the file really is — so the stamp checks are folded back in here, and they
# say which. Before, this exited 2 saying only "not a registry skill".
expect dirty "typo'd skill name: the stamp says which skill this really is" \
  -m "stamp names 'demo', expected 'demo-typo'" -rc 1 \
  "$(skill_with 'All good.')" demo-typo

# Provenance is "bears a stamp marker", NOT "bears a VALID stamp" — these two
# cases are the whole reason. Keying on the well-formed stamp would route a
# mangled or displaced stamp back into the tolerated bucket, i.e. hand the
# quietest treatment to the files that look most tampered with. Both exit 2 under
# that reading and 1 under this one.
expect dirty 'a MALFORMED stamp is still proof of a registry install' \
  -m 'stamped as a registry install but absent from the index' -rc 1 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n<!-- skill-templates: repo-only-demo -->')" \
  repo-only-demo

expect dirty 'a stamp that is not the last line is still proof of one' \
  -m 'stamped as a registry install but absent from the index' -rc 1 \
  "$(printf '# /repo-only-demo\n\nDoes a thing.\n<!-- skill-templates: repo-only-demo 1234abc 2026-06-03 -->\nand a note after it\n')" \
  repo-only-demo

# The flip side, and the reason the marker test is anchored to the start of the
# line's content: skill.md's own step 5 tells the agent to end the file with
# `<!-- skill-templates: <name> <hash> <date> -->`, quoted inline. A repo-only
# skill that DOCUMENTS the stamp format has not been installed from the registry,
# and a naive `'skill-templates:' in text` would fail every such file at exit 1.
expect dirty 'prose quoting the stamp format is not proof of an install' \
  -m 'clean on markers and attribution' -rc 2 \
  "$(printf '# /repo-only-demo\n\nEnd the file with `<!-- skill-templates: <name> <hash> <date> -->` on its own line.\n')" \
  repo-only-demo

# An invisible character inside the stamp NAME hits the mismatch branch, which
# must escape too or it reads "stamp names 'demo', expected 'demo'".
expect dirty 'stamp name mismatch escapes both sides' -m '\u200b' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n<!-- skill-templates: de\xe2\x80\x8bmo 1234abc 2026-06-03 -->')"

echo "self-merge posture: installed Critical Rule 5 vs the posture the profile PINS (#172)"

# `self-merge-posture` is `anyOf: [<gated wording>, <withheld wording>, …]` BY DESIGN —
# both postures are legitimate and repo-specific, so the guard fires when Critical
# Rule 5 is DELETED, not when a repo picks the other one. The consequence was that the
# one transition anyone cares about was invisible to every mechanical check: flipping a
# withheld repo to the gated wording linted clean, reported no drift under `skill
# outdated`, and diffed like a routine skill refresh. A per-file guard structurally
# cannot see it, because the pinned intent lives in a different file. So the linter
# reads that file. Every case here is asserted on the EXACT exit code: clean/dirty
# alone cannot pin this, since the pre-fix behaviour was "clean" for the flip.

# Verbatim from generic/autonomous-dev-flow.md's Critical Rule 5 — both branches of its
# {{CUSTOMIZE}} marker. Using the real wording is the point: these strings ARE the
# guard's alternates, so a case that passes here passes against a real installed file.
R5_GATED='Merge only through the Unattended Merge Gate — /full-review clean + ALL checks green on the final commit + ALL review threads resolved.'
R5_WITHHELD='NEVER merge, however clean the PR is. This repo does not grant unattended merge authority and the Unattended Merge Gate does not apply here.'

# Verbatim from the fleet: rah6, medlens, no-it-all, readitation, repo-memory and
# sovereign-storm all carry this exact block after #144's pass. The rationale paragraph
# is load-bearing for these tests, not decoration — it contains the word "gated". A
# parser that searches the block for "gated"/"withheld" reads this WITHHELD declaration
# as GATED and inverts the check on six real repos, so the declaration has to be taken
# from the block's BOLD LEAD and the rest treated as prose.
PROFILE_WITHHELD=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations

### Self-merge posture

**Withheld.** Every merge in this repo is a human act. However clean the review and
the checks are, PRs accumulate for the user rather than self-merging, so Critical
Rule 5 must be written in its WITHHELD form.

Recorded in the profile, not just in the installed skill: `.claude/commands/` is
regenerated on every `skill update`, this file is not. Without this line the next
update takes the template default — gated self-merge — and silently re-enables
unattended merges that were deliberately withheld.

### Branch Prefix
auto/
MD
)

PROFILE_GATED=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations

### Self-merge posture

**Gated.** An autonomous session may merge its own PR once every Unattended Merge Gate
condition is met. Critical Rule 5 must be written in its GATED form. A repo that
withheld merge authority would say so here instead.
MD
)

# The list-item shape carebridge uses. Same declaration, one bullet deeper.
PROFILE_WITHHELD_LIST=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations

### Self-merge posture
- **Withheld.** This repo does NOT grant unattended merge authority. Critical Rule 5
  must be written in its WITHHELD form: the session never merges.
MD
)

# The one-line shorthand documented in docs/skill-profile-schema.md.
PROFILE_WITHHELD_INLINE=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations
Self-merge posture: withheld — every merge in this repo is a human act.
MD
)

# A profile that says plenty and says nothing about posture. The overwhelmingly common
# case, and the one that must never become a failure.
PROFILE_SILENT=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations

### Branch Prefix
auto/

### Test Runner
npm test
MD
)

# Declares WITHHELD, but under a DIFFERENT skill's section.
PROFILE_OTHER_SKILL=$(cat <<'MD'
# demo skill profile

## tackle-issues Customizations

### Self-merge posture

**Withheld.** Every merge in this repo is a human act.

## autonomous-dev-flow Customizations

### Branch Prefix
auto/
MD
)

# Declares a posture for a skill that has no posture concept.
PROFILE_DEMO=$(cat <<'MD'
# demo skill profile

## demo Customizations

### Self-merge posture

**Withheld.** Every merge in this repo is a human act.
MD
)

# make_repo <skill> <rule-5 body> <profile body, or "-" for no profile>
#
# Builds a repo-SHAPED fixture — <root>/.claude/commands/<skill>.md beside
# <root>/.claude/skill-profile.md — so auto-discovery is exercised on the real
# directory layout rather than mocked. Sets $SKILL_FILE and $POSTURE_SKILL.
make_repo() {
  POSTURE_SKILL="$1"
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/.claude/commands"
  SKILL_FILE="$TMP/repo/.claude/commands/$1.md"
  printf '# /%s\n\n## Critical Rules\n\n5. **Self-merge authority for this repo** — %s\n\n<!-- skill-templates: %s 1234abc 2026-06-03 -->\n' \
    "$1" "$2" "$1" > "$SKILL_FILE"
  # An `if`, not `[ … ] && printf` — an and-list as a function's last command exports
  # the failed test's status, so every "no profile" case would return 1.
  if [ "$3" != "-" ]; then
    printf '%s\n' "$3" > "$TMP/repo/.claude/skill-profile.md"
  fi
}

# posture_case <label> <want-rc> <want-msg|-|!want-absent> [extra linter args…]
# Lints the fixture make_repo last built. Extra args land after the registry, i.e. in
# the optional 4th (profile) position. Callable twice on one fixture to assert both
# that something IS reported and that something else is NOT.
posture_case() {
  local label="$1" want_rc="$2" want_msg="$3"; shift 3
  local out rc
  out="$($LINT "$POSTURE_SKILL" "$SKILL_FILE" "$TMP/registry.json" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    printf '  FAIL - %s\n    wanted exit %s, got %s:\n%s\n' \
      "$label" "$want_rc" "$rc" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    FAIL=$((FAIL + 1)); return
  fi
  local why=""
  case "$want_msg" in
    -)  : ;;
    !*) printf '%s' "$out" | grep -qF -- "${want_msg#!}" &&
          why="output must NOT mention $(printf %q "${want_msg#!}")" ;;
    *)  printf '%s' "$out" | grep -qF -- "$want_msg" ||
          why="output did not mention $(printf %q "$want_msg")" ;;
  esac
  if [ -n "$why" ]; then
    printf '  FAIL - %s\n    %s:\n%s\n' \
      "$label" "$why" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    FAIL=$((FAIL + 1)); return
  fi
  printf '  ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

# THE case. This is the verifier's exact mutation from #172: take a withheld repo's
# installed skill and rewrite Critical Rule 5 to the gated wording. Before this check
# the file linted `✓ clean` at exit 0 — the guard is satisfied by the gated alternate,
# which is what it is for. The profile is the only thing that knows better.
make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_WITHHELD"
posture_case 'withheld profile + GATED installed rule 5 is a finding' \
  1 'pins WITHHELD for autonomous-dev-flow, but the installed file states GATED'

# ...and the guard it slipped past is still green on that same file, which is why the
# finding cannot come from the guard: exactly one issue is reported, the posture one.
posture_case 'the flipped file passes its guard — the posture check is the only finding' \
  1 '!guard miss'

# The mirror. A repo that pins GATED and receives the withheld wording has also drifted
# from its stated intent; the check is symmetric, not a one-way withheld defender.
make_repo autonomous-dev-flow "$R5_WITHHELD" "$PROFILE_GATED"
posture_case 'gated profile + WITHHELD installed rule 5 is a finding' \
  1 'pins GATED for autonomous-dev-flow, but the installed file states WITHHELD'

echo "self-merge posture: agreement is silent, and absence is never a failure"

# Agreement. Also the rationale-trap test: PROFILE_WITHHELD's body contains "gated
# self-merge", so a parser that greps the block rather than reading its bold lead
# would call this a mismatch and fail six real repos on their correct configuration.
make_repo autonomous-dev-flow "$R5_WITHHELD" "$PROFILE_WITHHELD"
posture_case 'withheld profile + WITHHELD installed rule 5 is clean' \
  0 'posture withheld matches the profile'

make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_GATED"
posture_case 'gated profile + GATED installed rule 5 is clean' \
  0 'posture gated matches the profile'

# The three shapes that must stay silent. Auto-discovery runs on every invocation, so
# a false positive in any of them breaks repos that never opted into anything — most
# repos have no profile, and having none is correct, not a finding.
make_repo autonomous-dev-flow "$R5_GATED" -
posture_case 'no profile at all: unchanged behaviour, not a failure' 0 '!posture'

make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_SILENT"
posture_case 'profile with no posture block: unchanged behaviour' 0 '!posture'

make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_OTHER_SKILL"
posture_case "a posture pinned under ANOTHER skill's section does not bind this one" \
  0 '!posture'

# Scoped to the skills that HAVE the concept. Critical Rule 5 exists only in
# autonomous-dev-flow and tackle-issues; no posture is invented for anything else, even
# when a profile writes a posture block for it and the file contradicts it outright.
make_repo demo "LOAD BEARING MARKER. $R5_GATED" "$PROFILE_DEMO"
posture_case 'a skill with no posture concept is never posture-checked' 0 '!posture'

echo "self-merge posture: parsing the shapes real profiles are written in"

make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_WITHHELD_LIST"
posture_case 'declaration as a list item (carebridge shape)' \
  1 'pins WITHHELD for autonomous-dev-flow'

make_repo autonomous-dev-flow "$R5_GATED" "$PROFILE_WITHHELD_INLINE"
posture_case 'one-line "Self-merge posture: withheld" shorthand (schema doc shape)' \
  1 'pins WITHHELD for autonomous-dev-flow'

# A file carrying BOTH wordings has no coherent posture, whatever the profile says.
# Naming both is the useful output — it says the rule was edited, not replaced.
make_repo autonomous-dev-flow "$R5_WITHHELD Also: $R5_GATED" "$PROFILE_WITHHELD"
posture_case 'a file stating BOTH postures is a mismatch naming both' \
  1 'the installed file states GATED and WITHHELD'

echo "self-merge posture: deletion stays the guard's job, not this check's"

# The division of labour. Rule 5 deleted outright is what `self-merge-posture` was
# built for and it fires; this check adds nothing there, because a second finding on
# an already-loud file is noise. So: guard miss reported, posture mismatch not.
make_repo autonomous-dev-flow "see the merge phase for details." "$PROFILE_WITHHELD"
posture_case 'a DELETED rule 5 is reported by the guard' 1 'guard miss: self-merge-posture'
posture_case 'a DELETED rule 5 does not also raise a posture mismatch' 1 '!posture mismatch'

# An EXPLICITLY passed profile that exists but cannot be read must be exit 2, never a
# clean 0. The caller asked for a check that then could not run, and "not verified"
# reported as "passed" is exactly what the three-outcome contract exists to prevent.
# The auto-discovered path stays an absence — most repos have no profile, correctly.
make_repo autonomous-dev-flow "NEVER merge, however clean the PR is." "$PROFILE_WITHHELD"
chmod 000 "$TMP/repo/.claude/skill-profile.md"
posture_case 'an unreadable EXPLICIT profile is exit 2, not clean' 2 'could not be read' \
  "$TMP/repo/.claude/skill-profile.md"
chmod 644 "$TMP/repo/.claude/skill-profile.md"

# ...but an unreadable AUTO-DISCOVERED profile is still just an absence: no finding.
make_repo autonomous-dev-flow "NEVER merge, however clean the PR is." "$PROFILE_WITHHELD"
chmod 000 "$TMP/repo/.claude/skill-profile.md"
posture_case 'an unreadable auto-discovered profile stays an absence' 0 '-'

# The block terminator must stop at ANY heading level. It matched only #{1,4}, so a
# ##### or ###### heading after the posture block was swallowed INTO it — and a later
# "**Gated.**" under such a heading would be read as this skill's posture.
PROFILE_DEEP_HEADING=$(cat <<'MD'
# demo skill profile

## autonomous-dev-flow Customizations

### Self-merge posture

The posture for this repo is recorded in the subsection below.

##### Historical note

**Gated.** This repo allowed self-merge before 2026-07; it does not now.
MD
)
make_repo autonomous-dev-flow "NEVER merge, however clean the PR is." "$PROFILE_DEEP_HEADING"
posture_case 'a ##### heading terminates the posture block' 0 '-'
posture_case 'prose under a deeper heading is not read as the posture' 0 '!posture mismatch'
chmod 644 "$TMP/repo/.claude/skill-profile.md"

echo "self-merge posture: how the profile is located"

# The 4th argument, for a file linted somewhere other than its repo (a temp dir, a
# pre-commit staging area) where auto-discovery has nothing to find.
make_repo autonomous-dev-flow "$R5_GATED" -
printf '%s\n' "$PROFILE_WITHHELD" > "$TMP/external-profile.md"
posture_case 'explicit 4th argument supplies a profile auto-discovery cannot find' \
  1 'pins WITHHELD for autonomous-dev-flow' "$TMP/external-profile.md"

# An explicitly requested check that cannot run is an environment error, never a pass.
posture_case 'an explicit profile path that does not exist exits 2' \
  2 'ERROR: skill profile not found' "$TMP/no-such-profile.md"

# Auto-discovery is deliberately narrow: <root>/.claude/commands/<name>.md only. A
# skill file sitting beside a skill-profile.md in some other layout is NOT a repo
# install, and guessing there would invent findings for files that never opted in.
mkdir -p "$TMP/flat"
POSTURE_SKILL=autonomous-dev-flow
SKILL_FILE="$TMP/flat/autonomous-dev-flow.md"
printf '# /autonomous-dev-flow\n\n5. **Self-merge authority for this repo** — %s\n\n<!-- skill-templates: autonomous-dev-flow 1234abc 2026-06-03 -->\n' \
  "$R5_GATED" > "$SKILL_FILE"
printf '%s\n' "$PROFILE_WITHHELD" > "$TMP/flat/skill-profile.md"
posture_case 'a profile outside .claude/ is not auto-discovered' 0 '!posture'

echo "self-merge posture: the anchor table stays in sync with skill-guards.json"

# POSTURE_ANCHORS in skill-lint.sh splits the guard's alternates by which posture each
# one belongs to — the mapping the guard JSON has no way to express, and the whole
# reason the flip was undetectable. Two files, one fact. If an alternate is added to
# skill-guards.json and not classified in the linter, a file carrying only that new
# wording becomes unclassifiable and the flip is invisible again, silently.
sync_missing=""; sync_seen=0
while IFS= read -r alt; do
  sync_seen=$((sync_seen + 1))
  grep -qF -- "$alt" "$LINT" || sync_missing="$sync_missing$alt"$'\n'
done < <(python3 - "$ROOT/skill-guards.json" <<'PY'
import json, sys
guards = json.load(open(sys.argv[1], encoding="utf-8"))
seen = set()
for skill in ("autonomous-dev-flow", "tackle-issues"):
    for g in guards.get(skill, []):
        if g.get("label") == "self-merge-posture":
            for alt in g.get("anyOf", []):
                if alt not in seen:
                    seen.add(alt)
                    print(alt)
PY
)
if [ "$sync_seen" -eq 0 ]; then
  # Vacuous success is the failure mode a set-comparison test is most prone to.
  printf '  FAIL - every self-merge-posture alternate is classified in skill-lint.sh\n    found NO alternates in skill-guards.json — the test would pass on an empty set\n'
  FAIL=$((FAIL + 1))
elif [ -n "$sync_missing" ]; then
  printf '  FAIL - every self-merge-posture alternate is classified in skill-lint.sh\n    unclassified in POSTURE_ANCHORS:\n%s\n' \
    "$(printf '%s' "$sync_missing" | sed 's/^/      /')"
  FAIL=$((FAIL + 1))
else
  printf '  ok - all %d self-merge-posture alternate(s) are classified in skill-lint.sh\n' "$sync_seen"
  PASS=$((PASS + 1))
fi

echo "network-only install path: the linter run as a fetched copy outside the repo"

# `skill add` source 3 has no clone on disk, so the gate can only run by fetching
# scripts/skill-lint.sh to a temp dir and running THAT copy. Two things differ
# from the in-repo run and both are pinned here: the fetched file is not
# executable, and its DEFAULT registry — "$(dirname "$0")/../registry.json" —
# points at the temp dir's parent, not at this registry.
#
# The copy sits one level below $FETCHED so the default resolves to
# $FETCHED/registry.json, which does not exist: the same shape as a real
# `mktemp -d`, and hermetic. Putting it directly under $TMP would NOT work —
# $TMP/registry.json is the hermetic index above, so the omitted-argument cases
# would pass for the wrong reason.
FETCHED="$TMP/fetched"; mkdir -p "$FETCHED/bin"
COPY="$FETCHED/bin/skill-lint.sh"
cp "$LINT" "$COPY"
chmod 644 "$COPY"          # a redirected fetch lands non-executable (mode is
                           # umask-dependent; the invariant is no execute bit)

printf '# /demo\n\nDoes a thing.\n\nLOAD BEARING MARKER\n\n## Rules\n\nfine\n%s\n' \
  "$STAMP" > "$TMP/copy-clean.md"
# Only fault is a guard miss: the ONE check that cannot run without the registry,
# so it proves the third argument actually reaches the guard pass.
printf '# /demo\n\nDoes a thing.\n\n## Rules\n\ncustomization dropped the marker\n%s\n' \
  "$STAMP" > "$TMP/copy-guardmiss.md"

# copy_case <label> <want-rc> <want-stdout|-> <want-stderr|-> <file> [registry]
# Each stream assertion is "-" (must be empty), "!<s>" (must NOT contain <s>) or
# "<s>" (must contain). Both streams are asserted because the whole hazard here
# is a run that says nothing on stdout while failing on stderr.
copy_case() {
  local label="$1" want_rc="$2" want_out="$3" want_err="$4" file="$5" reg="${6:-}"
  local o="$TMP/copy.out" e="$TMP/copy.err" rc
  if [ -n "$reg" ]; then
    bash "$COPY" demo "$file" "$reg" >"$o" 2>"$e"
  else
    bash "$COPY" demo "$file" >"$o" 2>"$e"
  fi
  rc=$?
  local why=""
  [ "$rc" -ne "$want_rc" ] && why="wanted exit $want_rc, got $rc"
  local stream want
  for stream in out err; do
    [ -n "$why" ] && break
    eval "want=\$want_$stream"
    local f="$TMP/copy.$stream"
    case "$want" in
      -)  [ -s "$f" ] && why="wanted an empty std$stream, got: $(cat "$f")" ;;
      !*) grep -qF -- "${want#!}" "$f" &&
            why="std$stream must not mention $(printf %q "${want#!}")" ;;
      *)  grep -qF -- "$want" "$f" ||
            why="std$stream did not mention $(printf %q "$want")" ;;
    esac
  done
  if [ -n "$why" ]; then
    printf '  FAIL - %s\n    %s\n    stdout: %s\n    stderr: %s\n' \
      "$label" "$why" "$(cat "$o")" "$(cat "$e")"
    FAIL=$((FAIL + 1)); return
  fi
  printf '  ok - %s\n' "$label"
  PASS=$((PASS + 1))
}

copy_case 'copy + explicit registry: clean file passes, guards applied' \
  0 '✓ demo: clean (1 guard(s) ok' - "$TMP/copy-clean.md" "$TMP/registry.json"

copy_case 'copy + explicit registry: guard miss is caught from outside the repo' \
  1 'guard miss: load-bearing' - "$TMP/copy-guardmiss.md" "$TMP/registry.json"

# The reason the third argument is mandatory rather than nice-to-have. Omitting
# it does not degrade to "guards unchecked, rest reported": the registry read
# happens after checks 1-3 have collected their findings and exits before any of
# them is printed, so today the run is loud on the exit code and on stderr and
# says nothing at all on stdout. The invariant pinned is the one that must hold
# however that is later reworded — it must NEVER exit 0 and NEVER print the clean
# marker, because to a caller reading the output that is what a pass looks like.
copy_case 'copy without the registry argument fails loudly, never clean (guard-miss file)' \
  2 '!✓' 'ERROR: registry not found' "$TMP/copy-guardmiss.md"

copy_case 'copy without the registry argument cannot pass a clean file either' \
  2 '!✓' 'ERROR: registry not found' "$TMP/copy-clean.md"

# Worse than mute: the default is a PATH, not "no registry", so an unrelated
# registry.json living next to the temp dir is loaded as if it were this one. It
# names "demo" but carries no guards, so the file that just failed on a guard
# miss now lints clean at exit 0 with 0 guards applied — literally "no problems
# found" from a gate that checked nothing. Characterization, not endorsement: if
# the linter is ever hardened to reject a registry it was not handed, update this
# case deliberately. Runs last and cleans up — the file it plants is exactly what
# the two cases above rely on being absent.
cat > "$FETCHED/registry.json" <<'JSON'
{ "registry": "someone-elses", "skillCount": 1,
  "skills": [ { "name": "demo", "hash": "0000000", "lines": 1, "description": "d" } ] }
JSON
copy_case 'copy without the registry argument silently adopts a foreign registry.json' \
  0 '✓ demo: clean (0 guard(s) ok' - "$TMP/copy-guardmiss.md"
rm -f "$FETCHED/registry.json"

echo "end-to-end: the real template, stripped the way \`skill add\` strips it"

# Faithful reproduction of the install path: remove the trailing
# "## Customization Points" section, append the stamp, lint against the REAL
# committed registry (guards included). This is the exact artifact that was
# failing in carebridge / ltl / medlens / DockKeeper.
python3 - "$ROOT" "$TMP/installed-create-pr.md" <<'PY'
import re, sys
root, out = sys.argv[1], sys.argv[2]
text = open(f"{root}/generic/create-pr.md", encoding="utf-8").read()
body = re.split(r'\n## Customization Points\b', text)[0].rstrip()
open(out, "w", encoding="utf-8").write(
    body + "\n<!-- skill-templates: create-pr 12b011f 2026-06-03 -->\n"
)
PY

if out="$($LINT create-pr "$TMP/installed-create-pr.md" "$ROOT/registry.json" 2>&1)"; then
  printf '  ok - installed generic/create-pr.md lints clean\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL - installed generic/create-pr.md lints clean\n%s\n' \
    "$(printf '%s\n' "$out" | sed 's/^/      /')"
  FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "skill-lint.test: $FAIL FAILED, $PASS passed"
  exit 1
fi
echo "skill-lint.test: ALL PASS ($PASS tests)"
