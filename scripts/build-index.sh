#!/usr/bin/env bash
# build-index.sh — regenerate registry.json, the manifest the pull-based /skill
# client resolves against. One entry per generic/<skill>.md with its current
# template git hash (the version a consumer pins in .claude/skills.lock) and a
# one-line description lifted from the template's opening paragraph.
#
# Run from the repo root after adding/editing a template:
#   ./scripts/build-index.sh && git add registry.json
#
# Output is deterministic (skills sorted by name) so re-runs produce clean diffs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d generic ]; then
  echo "ERROR: run from the skill-templates root (no generic/ dir found)" >&2
  exit 1
fi

GEN_HASH="$(git rev-parse --short HEAD)"

python3 - "$GEN_HASH" <<'PY' > registry.json
import json, subprocess, sys, glob, os

generated_from = sys.argv[1]

def short_hash(path):
    # Latest commit that touched this template — this is the version a consumer
    # records in its lockfile, and what `skill outdated` diffs against.
    out = subprocess.run(
        ["git", "log", "-1", "--format=%h", "--", path],
        capture_output=True, text=True,
    ).stdout.strip()
    return out or None

def describe(path):
    # First non-empty, non-heading line after the leading `# /name` H1.
    name = None
    desc = ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if name is None and s.startswith("#"):
                name = s.lstrip("# ").lstrip("/").strip()
                continue
            if s.startswith("#") or s.startswith("<!--"):
                continue
            desc = s
            break
    return name, desc

skills = []
for path in sorted(glob.glob("generic/*.md")):
    slug = os.path.splitext(os.path.basename(path))[0]
    h1name, desc = describe(path)
    with open(path, encoding="utf-8") as f:
        lines = sum(1 for _ in f)
    skills.append({
        "name": slug,
        "hash": short_hash(path),
        "lines": lines,
        "description": desc,
    })

doc = {
    "registry": "blamechris/skill-templates",
    "generatedFromCommit": generated_from,
    "skillCount": len(skills),
    "skills": skills,
}
print(json.dumps(doc, indent=2, ensure_ascii=False))
PY

echo "Wrote registry.json — $(python3 -c 'import json;print(json.load(open("registry.json"))["skillCount"])') skills (generated from ${GEN_HASH})." >&2
