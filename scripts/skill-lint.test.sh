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
cat > "$TMP/registry.json" <<'JSON'
{
  "registry": "test",
  "skillCount": 2,
  "skills": [
    { "name": "demo", "hash": "1234abc", "lines": 1, "description": "d",
      "guards": [ { "label": "load-bearing", "anyOf": ["LOAD BEARING MARKER"] } ] },
    { "name": "create-pr", "hash": "1234abc", "lines": 1, "description": "d" }
  ]
}
JSON

PASS=0; FAIL=0

# expect <clean|dirty> <label> <body...>  — body is written as the skill file.
# For "dirty", an optional -m <substring> asserts the reported reason.
expect() {
  local want="$1" label="$2" want_msg=""
  shift 2
  if [ "${1:-}" = "-m" ]; then want_msg="$2"; shift 2; fi
  local body="$1" skill="${2:-demo}"
  local f="$TMP/case.md"
  printf '%s\n' "$body" > "$f"

  local out rc
  out="$($LINT "$skill" "$f" "$TMP/registry.json" 2>&1)"; rc=$?

  local got="clean"; [ "$rc" -ne 0 ] && got="dirty"
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

expect clean 'stamp with surrounding whitespace is still valid' \
  "$(printf '# /demo\n\nLOAD BEARING MARKER\n\n## Rules\n\nstuff\n   %s   \n' "$STAMP")"

expect dirty 'guard miss when a load-bearing section is stripped' -m 'guard miss' \
  "$(printf '# /demo\n\nDoes a thing.\n\n## Rules\n\nCustomization dropped the marker.\n%s' "$STAMP")"

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
