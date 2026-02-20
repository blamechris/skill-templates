#!/usr/bin/env bash
# skill-check.sh — SessionStart hook for managed repos
# Detects if the current project is a managed repo and reports missing/drifted skills.
# Output goes to stdout, which SessionStart hooks inject as agent context.
# Silent (no output) when everything is OK or repo isn't managed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERIC_DIR="$SCRIPT_DIR/generic"
DEPLOY_CONF="$SCRIPT_DIR/deploy.conf"
SKILLS_DIR=".claude/commands"

# --- Detect repo from cwd ---
# SessionStart receives JSON on stdin with cwd, but we also accept CWD from env
if [ -t 0 ]; then
    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
else
    # Read JSON from stdin, extract cwd
    INPUT=$(cat)
    PROJECT_DIR=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")
    if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    fi
fi

# Get repo name from git root
REPO_NAME=""
if command -v git &>/dev/null; then
    GIT_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$GIT_ROOT" ]; then
        REPO_NAME=$(basename "$GIT_ROOT")
    fi
fi

[ -z "$REPO_NAME" ] && exit 0

# --- Load deploy.conf ---
[ ! -f "$DEPLOY_CONF" ] && exit 0

declare -a CONF_NAMES=()
declare -a CONF_PATHS=()
declare -a CONF_SKILLS=()

while IFS='|' read -r name _slug local_suffix skills; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    CONF_NAMES+=("$name")
    CONF_PATHS+=("$HOME/$local_suffix")
    CONF_SKILLS+=("$skills")
done < "$DEPLOY_CONF"

# Find this repo in config
IDX="-1"
for i in "${!CONF_NAMES[@]}"; do
    if [ "${CONF_NAMES[$i]}" = "$REPO_NAME" ]; then
        IDX="$i"
        break
    fi
done

# Not a managed repo — exit silently
[ "$IDX" = "-1" ] && exit 0

REPO_PATH="${CONF_PATHS[$IDX]}"
SKILLS_CSV="${CONF_SKILLS[$IDX]}"

[ ! -d "$REPO_PATH" ] && exit 0

# --- Check each skill ---
declare -a MISSING=()
declare -a DRIFTED=()

IFS=',' read -ra SKILL_NAMES <<< "$SKILLS_CSV"
for skill_name in "${SKILL_NAMES[@]}"; do
    skill="${skill_name}.md"
    generic="$GENERIC_DIR/$skill"
    local_skill="$REPO_PATH/$SKILLS_DIR/$skill"

    if [ ! -f "$local_skill" ]; then
        MISSING+=("$skill_name")
        continue
    fi

    [ ! -f "$generic" ] && continue

    # Pattern checks (same as sync.sh)
    drift=""

    if [ "$skill" = "check-pr.md" ]; then
        grep -q "in_reply_to_id" "$local_skill" 2>/dev/null || drift="${drift} idempotency"
        grep -q "FOLLOW-UP ISSUE" "$local_skill" 2>/dev/null || drift="${drift} mandatory-issues"
        grep -q "THREE.*valid\|ONLY THREE\|3 valid" "$local_skill" 2>/dev/null || drift="${drift} 3-outcomes"
    fi

    if [ "$skill" = "agent-review.md" ]; then
        grep -q "MANDATORY\|mandatory\|MUST.*issue" "$local_skill" 2>/dev/null || drift="${drift} mandatory-issues"
        grep -q "issue create" "$local_skill" 2>/dev/null || drift="${drift} issue-creation-code"
    fi

    if [ "$skill" = "learn.md" ]; then
        grep -q "Gate Check\|gate check\|Nothing to persist" "$local_skill" 2>/dev/null || drift="${drift} gate-check"
        grep -q "Behavioral Test\|do X instead of Y" "$local_skill" 2>/dev/null || drift="${drift} behavioral-test"
        grep -q "self-referential\|Self-referential" "$local_skill" 2>/dev/null || drift="${drift} self-ref-guard"
    fi

    if [ -n "$drift" ]; then
        DRIFTED+=("${skill_name}:${drift}")
    fi
done

# --- Output only if there are problems ---
if [ ${#MISSING[@]} -eq 0 ] && [ ${#DRIFTED[@]} -eq 0 ]; then
    exit 0
fi

echo "[skill-templates] Skills need attention in ${REPO_NAME}:"
echo ""

for skill in "${MISSING[@]:-}"; do
    [ -z "$skill" ] && continue
    echo "  MISSING: ${skill}.md — deploy with: ~/Projects/skill-templates/deploy.sh --local --repo ${REPO_NAME} --skill ${skill}"
done

for entry in "${DRIFTED[@]:-}"; do
    [ -z "$entry" ] && continue
    skill="${entry%%:*}"
    issues="${entry#*:}"
    echo "  DRIFTED: ${skill}.md — missing patterns:${issues}"
done

echo ""
echo "Run ~/Projects/skill-templates/sync.sh ${REPO_NAME} for full details."
