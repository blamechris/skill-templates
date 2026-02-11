#!/usr/bin/env bash
# sync.sh — Compare repo skills against generic templates
# Usage: ./sync.sh [repo-name]
# Without args: checks all repos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERIC_DIR="$SCRIPT_DIR/generic"

# Repo paths — most live in ~/Projects, exceptions listed here
repo_path() {
    case "$1" in
        archery-apprentice) echo "$HOME/StudioProjects/archery-apprentice" ;;
        *)                  echo "$HOME/Projects/$1" ;;
    esac
}
REPO_NAMES=("chroxy" "exodus-loop" "archery-apprentice" "repo-relay")
SKILLS_DIR=".claude/commands"

SKILLS=("check-pr.md" "agent-review.md" "swarm-audit.md" "full-review.md")

check_repo() {
    local repo="$1"
    local skills_dir="$SKILLS_DIR"
    local repo_path=$(repo_path "$repo")

    if [ ! -d "$repo_path" ]; then
        echo "  ⚠️  Not cloned locally: $repo_path"
        return
    fi

    echo "📦 $repo ($skills_dir/)"
    echo "   ──────────────────────────"

    for skill in "${SKILLS[@]}"; do
        local generic="$GENERIC_DIR/$skill"
        local local_skill="$repo_path/$skills_dir/$skill"

        if [ ! -f "$local_skill" ]; then
            echo "   ❌ $skill — MISSING"
            continue
        fi

        if [ ! -f "$generic" ]; then
            echo "   ⚠️  $skill — no generic template to compare"
            continue
        fi

        # Count lines in each
        local generic_lines=$(wc -l < "$generic" | tr -d ' ')
        local local_lines=$(wc -l < "$local_skill" | tr -d ' ')

        # Check for key patterns that should exist
        local missing=""

        # check-pr patterns
        if [ "$skill" = "check-pr.md" ]; then
            grep -q "in_reply_to_id" "$local_skill" 2>/dev/null || missing="${missing} idempotency"
            grep -q "FOLLOW-UP ISSUE" "$local_skill" 2>/dev/null || missing="${missing} mandatory-issues"
            grep -q "commit.*SHA\|COMMIT_SHA\|commit hash" "$local_skill" 2>/dev/null || missing="${missing} commit-links"
            grep -q "THREE.*valid\|ONLY THREE\|3 valid" "$local_skill" 2>/dev/null || missing="${missing} 3-outcomes"
            grep -q "from-review.*issue\|Cross-Reference\|cross-reference\|Reconcile" "$local_skill" 2>/dev/null || missing="${missing} issue-reconciliation"
        fi

        # agent-review patterns
        if [ "$skill" = "agent-review.md" ]; then
            grep -q "MANDATORY\|mandatory\|MUST.*issue" "$local_skill" 2>/dev/null || missing="${missing} mandatory-issues"
            grep -q "issue create" "$local_skill" 2>/dev/null || missing="${missing} issue-creation-code"
            grep -q "from-review.*issue\|Reconcile\|reconcile\|cross-reference" "$local_skill" 2>/dev/null || missing="${missing} issue-reconciliation"
        fi

        # swarm-audit patterns
        if [ "$skill" = "swarm-audit.md" ]; then
            grep -q "Core Panel" "$local_skill" 2>/dev/null || missing="${missing} core-panel"
            grep -q "master-assessment" "$local_skill" 2>/dev/null || missing="${missing} master-assessment"
            grep -q "file:line" "$local_skill" 2>/dev/null || missing="${missing} file-line-refs"
            grep -q "Consensus Findings" "$local_skill" 2>/dev/null || missing="${missing} consensus-section"
        fi

        # full-review patterns
        if [ "$skill" = "full-review.md" ]; then
            grep -q "Phase 1.*Agent Review\|agent-review" "$local_skill" 2>/dev/null || missing="${missing} agent-review-phase"
            grep -q "Phase 2.*Check-PR\|check-pr" "$local_skill" 2>/dev/null || missing="${missing} check-pr-phase"
            grep -q "Combined Summary\|combined.*table\|summary table" "$local_skill" 2>/dev/null || missing="${missing} combined-summary"
            grep -q "Sequential.*not parallel\|MUST complete before" "$local_skill" 2>/dev/null || missing="${missing} sequential-execution"
        fi

        if [ -z "$missing" ]; then
            echo "   ✅ $skill — OK (${local_lines}L vs ${generic_lines}L template)"
        else
            echo "   🔧 $skill — DRIFT (${local_lines}L) — missing:${missing}"
        fi
    done
    echo ""
}

echo ""
echo "🔍 Skill Template Sync Check"
echo "   Template source: $GENERIC_DIR"
echo "   $(date '+%Y-%m-%d %H:%M')"
echo ""

if [ $# -gt 0 ]; then
    check_repo "$1"
else
    for repo in "${REPO_NAMES[@]}"; do
        check_repo "$repo"
    done
fi
