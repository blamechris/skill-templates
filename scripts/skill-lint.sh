#!/usr/bin/env bash
# skill-lint.sh — deterministic validation of an INSTALLED skill against the registry.
#
# The pull model moved render-safety from a CI gate (deploy.sh validate_output) to the
# installing agent's self-checks. This restores a MECHANICAL gate the agent runs after
# `skill add`, and that a consumer pre-commit hook or CI can run too. It checks:
#   1. no residual {{CUSTOMIZE markers (outside backticked mentions),
#   2. no attribution footer (Generated with Claude / Co-Authored-By: Claude in the tail),
#   3. a well-formed version stamp as the last line,
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

# 2) attribution footer in the last ~15 lines. Catches both the trailer
#    ("Co-Authored-By: Claude …") and the Claude Code footer
#    ("🤖 Generated with [Claude Code](…)"), anywhere on the line.
attribution_re = re.compile(
    r'(generated with[^\n]*claude|co-authored-by:[^\n]*claude|🤖[^\n]*generated)', re.I
)
for ln in lines[-15:]:
    if attribution_re.search(ln):
        fails.append(f"attribution footer: {ln.strip()[:70]}")

# 3) well-formed version stamp as the last non-empty line, naming this skill
stamp_re = re.compile(
    r'<!--\s*skill-templates:\s+(\S+)\s+([0-9a-f]{7,40})\s+(\d{4}-\d{2}-\d{2})\s*-->'
)
nonempty = [l for l in lines if l.strip()]
m = stamp_re.search(nonempty[-1]) if nonempty else None
if not m:
    fails.append("missing/malformed version stamp "
                 "(expected '<!-- skill-templates: <name> <hash> <date> -->' as the last line)")
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
