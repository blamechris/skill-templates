#!/usr/bin/env bash
# rollout-pull-model.sh — one-time migration of consumer repos onto the pull model.
#
# For each repo (from deploy.conf, minus no-it-all which is already done) it:
#   1. migrates customizations/<repo>.md  -> <repo>/.claude/skill-profile.md (H1 reframed,
#      with any values/<repo>.values folded into an appendix),
#   2. bootstraps the /skill client       -> <repo>/.claude/commands/skill.md (stamped),
#   3. backfills                            <repo>/.claude/skills.lock from version stamps,
#   4. lints the bootstrapped client (scripts/skill-lint.sh) — abort the repo on failure,
#   5. commits on a branch, pushes, opens a PR.
#
# Usage:
#   scripts/rollout-pull-model.sh --dry-run            # report only, no writes/PRs
#   scripts/rollout-pull-model.sh [repo ...]           # all eligible, or just the named ones
#
# Idempotent: a repo that already has .claude/commands/skill.md is skipped.
set -uo pipefail

REG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATE="$(date '+%Y-%m-%d')"
BRANCH="chore/adopt-pull-skill"
DRY=false
ONLY=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    *) ONLY+=("$a") ;;
  esac
done

SKILL_HASH="$(git -C "$REG" log -1 --abbrev=7 --format=%h -- generic/skill.md)"

eligible() {  # name in ONLY (or ONLY empty) and not no-it-all
  local n="$1"
  [ "$n" = "no-it-all" ] && return 1
  [ "${#ONLY[@]}" -eq 0 ] && return 0
  for o in "${ONLY[@]}"; do [ "$o" = "$n" ] && return 0; done
  return 1
}

bootstrap_skill() {  # $1=dest dir
  awk 'BEGIN{stop=0}
       /^## Customization Points/{stop=1}
       !stop{a[NR]=$0; last=NR}
       END{ while(last>0 && a[last] ~ /^[[:space:]]*$/) last--; for(i=1;i<=last;i++) print a[i] }
      ' "$REG/generic/skill.md" > "$1/.claude/commands/skill.md"
  printf '\n<!-- skill-templates: skill %s %s -->\n' "$SKILL_HASH" "$DATE" >> "$1/.claude/commands/skill.md"
}

backfill_lock() {  # $1=repo dir
  python3 - "$1" <<'PY'
import json, os, re, sys
d = sys.argv[1]
cmd = os.path.join(d, ".claude/commands")
stamp = re.compile(r'<!--\s*skill-templates:\s*(\S+)\s+(\S+)\s+(\S+)\s*-->')
locked = {}
for f in sorted(os.listdir(cmd)):
    if not f.endswith(".md"): continue
    m = None
    for line in open(os.path.join(cmd, f), encoding="utf-8"):
        mm = stamp.search(line)
        if mm: m = mm
    if m: locked[f[:-3]] = {"hash": m.group(2), "installed": m.group(3)}
doc = {"registry": "blamechris/skill-templates", "skills": dict(sorted(locked.items()))}
with open(os.path.join(d, ".claude/skills.lock"), "w") as fh:
    json.dump(doc, fh, indent=2); fh.write("\n")
print(f"  lock: {len(locked)} stamped skill(s)")
PY
}

process() {  # $1=name $2=slug $3=path
  local name="$1" slug="$2" path="$3"
  echo "── $name ($slug)"
  if [ ! -d "$path/.git" ]; then echo "  ✗ not cloned at $path — skip"; return; fi
  if [ -f "$path/.claude/commands/skill.md" ]; then echo "  ↩ already adopted — skip"; return; fi
  local cust="$REG/customizations/${name}.md"
  if [ ! -f "$cust" ]; then echo "  ✗ no customizations/${name}.md — skip"; return; fi

  # repo must be clean and on a normal main
  local dirty; dirty="$(git -C "$path" status --porcelain)"
  if [ -n "$dirty" ]; then echo "  ✗ working tree not clean — skip"; return; fi
  local base; base="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null)"

  if $DRY; then
    echo "  ✓ would adopt (base=$base): profile from customizations/${name}.md, bootstrap skill.md@${SKILL_HASH}, backfill lock, PR on $BRANCH"
    [ -f "$REG/values/${name}.values" ] && echo "    + fold values/${name}.values"
    return
  fi

  git -C "$path" checkout "$base" -q && git -C "$path" pull -q --ff-only 2>/dev/null
  git -C "$path" checkout -b "$BRANCH" -q 2>/dev/null || git -C "$path" checkout "$BRANCH" -q
  mkdir -p "$path/.claude/commands"

  # 1) profile
  sed '1s/^# .*/# '"$name"' skill profile/' "$cust" > "$path/.claude/skill-profile.md"
  if [ -f "$REG/values/${name}.values" ]; then
    {
      echo ""
      echo "## Value overrides (from values/${name}.values)"
      echo "Deterministic per-skill line overrides carried over from the old deploy:"
      echo '```'
      cat "$REG/values/${name}.values"
      echo '```'
    } >> "$path/.claude/skill-profile.md"
  fi

  # 2) bootstrap + 3) lock
  bootstrap_skill "$path"
  backfill_lock "$path"

  # 4) lint the bootstrapped client
  if ! "$REG/scripts/skill-lint.sh" skill "$path/.claude/commands/skill.md" "$REG/registry.json" >/dev/null; then
    echo "  ✗ lint FAILED on bootstrapped skill.md — aborting $name"
    "$REG/scripts/skill-lint.sh" skill "$path/.claude/commands/skill.md" "$REG/registry.json" || true
    git -C "$path" checkout "$base" -q; git -C "$path" branch -D "$BRANCH" -q 2>/dev/null
    return
  fi

  # 5) commit, push, PR
  git -C "$path" add .claude/skill-profile.md .claude/commands/skill.md .claude/skills.lock
  git -C "$path" commit -q -m "chore: adopt pull-based /skill registry

Add .claude/skill-profile.md (from the registry's customizations/${name}.md),
bootstrap the /skill client, and backfill .claude/skills.lock from existing
version stamps. Part of the skill-templates pull-model migration."
  if git -C "$path" push -u origin "$BRANCH" -q 2>/dev/null; then
    local url; url="$(gh pr create -R "$slug" --base "$base" --head "$BRANCH" \
      --title "chore: adopt pull-based /skill registry" \
      --body "Migrates this repo onto the pull-based skill registry (skill-templates).

- \`.claude/skill-profile.md\` — repo profile (from the registry's \`customizations/${name}.md\`), so \`/skill\` can tailor installs here.
- \`.claude/commands/skill.md\` — bootstrapped \`/skill\` client (stamped, lint-clean).
- \`.claude/skills.lock\` — backfilled from existing version stamps.

Additive only (no code touched). Existing un-stamped skills stay locally managed until re-installed via \`skill add\`." 2>/dev/null)"
    echo "  🔗 ${url:-PR create failed}"
  else
    echo "  ✗ push failed"
  fi
}

echo "Rollout (dry-run=$DRY) — skill.md@${SKILL_HASH}, date=${DATE}"
while IFS='|' read -r name slug suffix skills; do
  case "$name" in \#*|"") continue;; esac
  eligible "$name" || continue
  process "$name" "$slug" "$HOME/$suffix"
done < "$REG/deploy.conf"
