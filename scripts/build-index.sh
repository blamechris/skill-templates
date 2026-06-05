#!/usr/bin/env bash
# build-index.sh — regenerate registry.json, the manifest the pull-based /skill
# client resolves against. One entry per generic/<skill>.md with its current
# template git hash (the version a consumer pins in .claude/skills.lock) and a
# one-line description lifted from the template's opening paragraph.
#
# Run from the repo root after adding/editing a template:
#   ./scripts/build-index.sh && git add registry.json
#
# Output is deterministic (skills sorted by name, fixed 7-char hashes) so re-runs
# produce clean diffs. The file is written atomically — a failure leaves the old
# registry.json untouched rather than truncating it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d generic ]; then
  echo "ERROR: run from the skill-templates root (no generic/ dir found)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found on PATH" >&2
  exit 1
fi

# Fixed-length (7) abbreviation so the index hash always matches what consumers
# record. --short alone yields a repo-dependent variable length.
GEN_HASH="$(git rev-parse --short=7 HEAD)"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

python3 - "$GEN_HASH" <<'PY' > "$TMP"
import json, subprocess, sys, glob, os

generated_from = sys.argv[1]

def short_hash(path):
    # Latest commit that touched this template, fixed to 7 chars (matches the
    # consumer's lockfile pin and `skill outdated` comparison).
    out = subprocess.run(
        ["git", "log", "-1", "--abbrev=7", "--format=%h", "--", path],
        capture_output=True, text=True,
    ).stdout.strip()
    if not out:
        # No commit touches this template (e.g. staged-but-uncommitted new file).
        # Fail loudly rather than emitting a null hash the client can't resolve.
        sys.stderr.write(
            f"ERROR: no commit found for {path} — commit the template before "
            f"building the index.\n"
        )
        sys.exit(1)
    return out

def describe(path):
    # First paragraph after the leading `# /name` H1: join wrapped lines until a
    # blank line so multi-line opening paragraphs aren't truncated mid-sentence.
    saw_h1 = False
    para = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not saw_h1:
                if s.startswith("#"):
                    saw_h1 = True
                continue
            if not s:
                if para:
                    break          # blank line ends the first paragraph
                continue           # skip blanks before the paragraph starts
            if s.startswith("#") or s.startswith("<!--"):
                if para:
                    break
                continue
            para.append(s)
    return " ".join(para)

# Per-skill content guards (load-bearing markers that must survive customization).
# Carried into the index so consumers can check corruption-drift without sync.sh.
guards_all = {}
if os.path.exists("skill-guards.json"):
    raw = json.load(open("skill-guards.json", encoding="utf-8"))
    guards_all = {k: v for k, v in raw.items() if not k.startswith("_")}

skills = []
for path in sorted(glob.glob("generic/*.md")):
    slug = os.path.splitext(os.path.basename(path))[0]
    with open(path, encoding="utf-8") as f:
        lines = sum(1 for _ in f)
    entry = {
        "name": slug,
        "hash": short_hash(path),
        "lines": lines,
        "description": describe(path),
    }
    if slug in guards_all:
        entry["guards"] = guards_all[slug]
    skills.append(entry)

doc = {
    "registry": "blamechris/skill-templates",
    "generatedFromCommit": generated_from,
    "skillCount": len(skills),
    "skills": skills,
}
print(json.dumps(doc, indent=2, ensure_ascii=False))
PY

mv "$TMP" registry.json
trap - EXIT
echo "Wrote registry.json — $(python3 -c 'import json;print(json.load(open("registry.json"))["skillCount"])') skills (generated from ${GEN_HASH})." >&2
