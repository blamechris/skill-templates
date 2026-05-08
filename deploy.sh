#!/usr/bin/env bash
# deploy.sh — Deploy customized skill templates to managed repos
#
# Usage:
#   ./deploy.sh --dry-run                         # Show what would be deployed
#   ./deploy.sh --local --repo chroxy              # Deploy all skills for chroxy locally
#   ./deploy.sh --local --skill learn              # Deploy learn to all repos locally
#   ./deploy.sh --local --repo chroxy --skill agent-review  # Deploy one skill to one repo
#   ./deploy.sh --changed-templates                # Deploy skills whose templates changed (CI)
#   ./deploy.sh --changed-customs                  # Deploy skills for repos whose customizations changed (CI)
#
# Environment:
#   ANTHROPIC_API_KEY  — Required for Claude API calls
#   DEPLOY_PAT         — Required for CI mode (pushing to target repos)
#   GITHUB_OWNER       — Override GitHub owner (default: blamechris)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERIC_DIR="$SCRIPT_DIR/generic"
CUSTOMS_DIR="$SCRIPT_DIR/customizations"
DEPLOY_CONF="$SCRIPT_DIR/deploy.conf"
SKILLS_DIR=".claude/commands"

# Defaults
DRY_RUN=false
LOCAL_MODE=false
FILTER_REPO=""
FILTER_SKILL=""
CHANGED_TEMPLATES=false
CHANGED_CUSTOMS=false
API_MODEL="claude-haiku-4-5-20251001"
BRANCH_DATE=$(date '+%Y-%m-%d')
BRANCH_NAME="skill-deploy/${BRANCH_DATE}"

# --- Argument parsing ---
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)          DRY_RUN=true ;;
        --local)            LOCAL_MODE=true ;;
        --repo)             FILTER_REPO="$2"; shift ;;
        --skill)            FILTER_SKILL="$2"; shift ;;
        --changed-templates) CHANGED_TEMPLATES=true ;;
        --changed-customs)  CHANGED_CUSTOMS=true ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--dry-run] [--local] [--repo NAME] [--skill NAME] [--changed-templates] [--changed-customs]" >&2
            exit 1
            ;;
    esac
    shift
done

# --- Config loader (shared with sync.sh logic) ---
declare -a CONF_NAMES=()
declare -a CONF_SLUGS=()
declare -a CONF_PATHS=()
declare -a CONF_SKILLS=()

load_config() {
    if [ ! -f "$DEPLOY_CONF" ]; then
        echo "ERROR: deploy.conf not found" >&2
        exit 1
    fi
    while IFS='|' read -r name slug local_suffix skills; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        CONF_NAMES+=("$name")
        CONF_SLUGS+=("$slug")
        CONF_PATHS+=("$HOME/$local_suffix")
        CONF_SKILLS+=("$skills")
    done < "$DEPLOY_CONF"
}

conf_index() {
    local target="$1"
    for i in "${!CONF_NAMES[@]}"; do
        [ "${CONF_NAMES[$i]}" = "$target" ] && echo "$i" && return
    done
    echo "-1"
}

repo_has_skill() {
    local idx="$1" skill="$2"
    local skills_csv="${CONF_SKILLS[$idx]}"
    [[ ",$skills_csv," == *",$skill,"* ]]
}

load_config

# --- Change detection ---
detect_changed_templates() {
    local changed=()
    while IFS= read -r file; do
        local base
        base=$(basename "$file" .md)
        changed+=("$base")
    done < <(git -C "$SCRIPT_DIR" diff HEAD~1 --name-only -- 'generic/*.md' 2>/dev/null || true)
    echo "${changed[*]:-}"
}

detect_changed_customs() {
    local changed=()
    while IFS= read -r file; do
        local base
        base=$(basename "$file" .md)
        changed+=("$base")
    done < <(git -C "$SCRIPT_DIR" diff HEAD~1 --name-only -- 'customizations/*.md' 2>/dev/null || true)
    echo "${changed[*]:-}"
}

# --- Build deployment pairs ---
declare -a DEPLOY_PAIRS=()  # "repo:skill" entries

build_pairs() {
    # If --changed-templates: deploy changed templates to all repos that use them
    if [ "$CHANGED_TEMPLATES" = true ]; then
        local templates
        templates=$(detect_changed_templates)
        for skill in $templates; do
            for i in "${!CONF_NAMES[@]}"; do
                if repo_has_skill "$i" "$skill"; then
                    DEPLOY_PAIRS+=("${CONF_NAMES[$i]}:$skill")
                fi
            done
        done
    fi

    # If --changed-customs: deploy all skills for repos whose customizations changed
    if [ "$CHANGED_CUSTOMS" = true ]; then
        local customs
        customs=$(detect_changed_customs)
        for repo in $customs; do
            local idx
            idx=$(conf_index "$repo")
            [ "$idx" = "-1" ] && continue
            IFS=',' read -ra skills <<< "${CONF_SKILLS[$idx]}"
            for skill in "${skills[@]}"; do
                DEPLOY_PAIRS+=("${repo}:${skill}")
            done
        done
    fi

    # If --repo and/or --skill specified (manual mode)
    if [ -n "$FILTER_REPO" ] || [ -n "$FILTER_SKILL" ]; then
        if [ -n "$FILTER_REPO" ] && [ -n "$FILTER_SKILL" ]; then
            # Specific repo + skill — validate combination
            local idx
            idx=$(conf_index "$FILTER_REPO")
            if [ "$idx" = "-1" ]; then
                echo "ERROR: repo '$FILTER_REPO' not in deploy.conf" >&2
                exit 1
            fi
            if ! repo_has_skill "$idx" "$FILTER_SKILL"; then
                echo "ERROR: repo '$FILTER_REPO' does not have skill '$FILTER_SKILL' in deploy.conf" >&2
                exit 1
            fi
            DEPLOY_PAIRS+=("${FILTER_REPO}:${FILTER_SKILL}")
        elif [ -n "$FILTER_REPO" ]; then
            # All skills for one repo
            local idx
            idx=$(conf_index "$FILTER_REPO")
            if [ "$idx" = "-1" ]; then
                echo "ERROR: repo '$FILTER_REPO' not in deploy.conf" >&2
                exit 1
            fi
            IFS=',' read -ra skills <<< "${CONF_SKILLS[$idx]}"
            for skill in "${skills[@]}"; do
                DEPLOY_PAIRS+=("${FILTER_REPO}:${skill}")
            done
        elif [ -n "$FILTER_SKILL" ]; then
            # One skill to all repos that use it
            for i in "${!CONF_NAMES[@]}"; do
                if repo_has_skill "$i" "$FILTER_SKILL"; then
                    DEPLOY_PAIRS+=("${CONF_NAMES[$i]}:${FILTER_SKILL}")
                fi
            done
        fi
    fi

    # If no filters at all and no change detection, deploy everything
    if [ ${#DEPLOY_PAIRS[@]} -eq 0 ] && [ "$CHANGED_TEMPLATES" = false ] && [ "$CHANGED_CUSTOMS" = false ]; then
        for i in "${!CONF_NAMES[@]}"; do
            IFS=',' read -ra skills <<< "${CONF_SKILLS[$i]}"
            for skill in "${skills[@]}"; do
                DEPLOY_PAIRS+=("${CONF_NAMES[$i]}:${skill}")
            done
        done
    fi

    # Deduplicate
    local -a unique=()
    local seen=""
    for pair in "${DEPLOY_PAIRS[@]}"; do
        if [[ "$seen" != *"|$pair|"* ]]; then
            unique+=("$pair")
            seen="${seen}|$pair|"
        fi
    done
    DEPLOY_PAIRS=("${unique[@]}")
}

build_pairs

if [ ${#DEPLOY_PAIRS[@]} -eq 0 ]; then
    echo "No deployment pairs matched. Nothing to do."
    exit 0
fi

# --- Show deployment plan ---
echo ""
echo "=== Skill Deployment ==="
echo "    Date: $BRANCH_DATE"
echo "    Mode: $([ "$LOCAL_MODE" = true ] && echo "local" || echo "CI (PR)")"
echo "    Dry run: $DRY_RUN"
echo ""
echo "Deployment pairs (${#DEPLOY_PAIRS[@]}):"
for pair in "${DEPLOY_PAIRS[@]}"; do
    echo "  - ${pair%%:*} ← ${pair##*:}.md"
done
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "Dry run — no changes made."
    exit 0
fi

# --- Validate prerequisites ---
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ERROR: ANTHROPIC_API_KEY not set" >&2
    exit 1
fi

if [ "$LOCAL_MODE" = false ] && [ -z "${DEPLOY_PAT:-}" ]; then
    echo "ERROR: DEPLOY_PAT required for CI mode (use --local for local deployment)" >&2
    exit 1
fi

# Check for required tools
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not found" >&2
        exit 1
    fi
done

if [ "$LOCAL_MODE" = false ] && ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI required for CI mode" >&2
    exit 1
fi

# Set GH_TOKEN so gh CLI uses the same PAT as git operations
if [ "$LOCAL_MODE" = false ] && [ -n "${DEPLOY_PAT:-}" ]; then
    export GH_TOKEN="$DEPLOY_PAT"
fi

# --- Claude API call ---
call_claude() {
    local template_content="$1"
    local custom_content="$2"
    local repo_name="$3"
    local skill_name="$4"

    local system_prompt
    read -r -d '' system_prompt <<'SYSPROMPT' || true
You are a skill template customizer. Your ONLY job is to take a generic skill template and a repo's customization notes, then output the final customized skill markdown.

Rules:
1. Replace every {{CUSTOMIZE: ...}} marker with content derived from the customization notes. The marker text describes what kind of content is needed. Use the customization notes to fill it in appropriately.
2. If the customization notes don't have relevant content for a marker, remove the marker line entirely (don't leave a blank {{CUSTOMIZE}} or placeholder).
3. Preserve ALL non-customizable sections EXACTLY as-is. Do not rephrase, reorder, or "improve" any text that isn't a {{CUSTOMIZE}} marker.
4. Remove the entire "Customization Points" section at the end of the template (the section that lists what {{CUSTOMIZE}} markers exist). This is meta-documentation for template maintainers, not part of the deployed skill.
5. Output ONLY the final markdown. No preamble, no explanation, no code fences wrapping the output.
6. Never add attribution (no "Generated with", no "Co-Authored-By", no AI mentions).
7. Preserve all code blocks, bash examples, and formatting exactly as they appear in the template.
SYSPROMPT

    local user_prompt
    user_prompt="Customize this skill template for the ${repo_name} repository.

--- GENERIC TEMPLATE (${skill_name}.md) ---
${template_content}
--- END TEMPLATE ---

--- CUSTOMIZATION NOTES (${repo_name}.md) ---
${custom_content}
--- END CUSTOMIZATION NOTES ---

Output the fully customized skill markdown now."

    # Build JSON payload with jq to handle escaping
    local payload
    payload=$(jq -n \
        --arg model "$API_MODEL" \
        --arg system "$system_prompt" \
        --arg user "$user_prompt" \
        '{
            model: $model,
            max_tokens: 8192,
            temperature: 0,
            system: $system,
            messages: [{role: "user", content: $user}]
        }')

    local response
    local http_code
    local tmpfile
    tmpfile=$(mktemp)

    local max_retries=3
    local attempt=1
    local backoff=5

    while [ "$attempt" -le "$max_retries" ]; do
        http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
            "https://api.anthropic.com/v1/messages" \
            -H "content-type: application/json" \
            -H "x-api-key: ${ANTHROPIC_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            -d "$payload")

        if [ "$http_code" = "200" ]; then
            break
        fi

        # Permanent errors — fail immediately, no retry
        case "$http_code" in
            400|401|403|404)
                echo "    ❌ API returned $http_code (permanent error, not retrying)" >&2
                cat "$tmpfile" >&2
                rm -f "$tmpfile"
                return 1
                ;;
        esac

        # Transient errors (429, 500, 502, 503, etc.) — retry with backoff
        if [ "$attempt" -lt "$max_retries" ]; then
            echo "    ⚠️  API returned $http_code, retrying in ${backoff}s (attempt $attempt/$max_retries)..." >&2
            sleep "$backoff"
            backoff=$((backoff * 3))
            attempt=$((attempt + 1))
        else
            echo "    ❌ API failed with $http_code after $max_retries attempts" >&2
            cat "$tmpfile" >&2
            rm -f "$tmpfile"
            return 1
        fi
    done

    # Check for error response before extracting content
    if jq -e '.error' "$tmpfile" >/dev/null 2>&1; then
        echo "    ❌ API returned error:" >&2
        jq -r '.error.message' "$tmpfile" >&2
        rm -f "$tmpfile"
        return 1
    fi

    # Extract text content from response
    response=$(jq -r '.content[0].text // empty' "$tmpfile")
    rm -f "$tmpfile"

    if [ -z "$response" ]; then
        echo "    ❌ Empty response from API" >&2
        return 1
    fi

    echo "$response"
}

# --- Deploy a single pair ---
declare -a FAILURES=()

deploy_pair() {
    local repo="$1"
    local skill="$2"

    local idx
    idx=$(conf_index "$repo")
    if [ "$idx" = "-1" ]; then
        echo "  ⚠️  $repo not in deploy.conf, skipping"
        FAILURES+=("${repo}:${skill} — not in config")
        return
    fi

    local template="$GENERIC_DIR/${skill}.md"
    local custom="$CUSTOMS_DIR/${repo}.md"

    if [ ! -f "$template" ]; then
        echo "  ⚠️  No generic template: ${skill}.md"
        FAILURES+=("${repo}:${skill} — no template")
        return
    fi

    if [ ! -f "$custom" ]; then
        echo "  ⚠️  No customization notes: ${repo}.md"
        FAILURES+=("${repo}:${skill} — no customization notes")
        return
    fi

    echo "  🔄 ${repo} ← ${skill}.md"

    local template_content custom_content
    template_content=$(<"$template")
    custom_content=$(<"$custom")

    local result
    if ! result=$(call_claude "$template_content" "$custom_content" "$repo" "$skill"); then
        FAILURES+=("${repo}:${skill} — API error")
        return
    fi

    # Append version stamp so sync.sh can detect outdated deployments
    local template_hash
    template_hash=$(git -C "$SCRIPT_DIR" log -1 --format=%h -- "generic/${skill}.md")
    local stamp="<!-- skill-templates: ${skill} ${template_hash} $(date '+%Y-%m-%d') -->"
    result="${result}
${stamp}"

    if [ "$LOCAL_MODE" = true ]; then
        deploy_local "$repo" "$skill" "$result" "$idx"
    else
        deploy_ci "$repo" "$skill" "$result" "$idx"
    fi
}

deploy_local() {
    local repo="$1" skill="$2" content="$3" idx="$4"
    local repo_path="${CONF_PATHS[$idx]}"
    local target_dir="$repo_path/$SKILLS_DIR"
    local target_file="$target_dir/${skill}.md"

    if [ ! -d "$repo_path" ]; then
        echo "    ⚠️  Repo not cloned: $repo_path"
        FAILURES+=("${repo}:${skill} — not cloned locally")
        return
    fi

    mkdir -p "$target_dir"
    echo "$content" > "$target_file"
    echo "    ✅ Written to $target_file"
}

# --- CI mode: clone, branch, commit, push, PR ---
# Track which repos already have clones/branches set up
declare -a CI_CLONED_REPOS=()

ci_setup_repo() {
    local repo="$1" idx="$2"
    local slug="${CONF_SLUGS[$idx]}"
    local clone_dir="/tmp/skill-deploy/${repo}"

    # Skip if already set up
    for r in "${CI_CLONED_REPOS[@]:-}"; do
        [ "$r" = "$repo" ] && return 0
    done

    echo "    📥 Cloning $slug..."
    rm -rf "$clone_dir"

    # PAT health check (#15) — hit the lightweight /user endpoint before
    # any git op so an expired/mis-scoped/stale token surfaces a friendly
    # error in the workflow log instead of an opaque `exit 128`.
    if ! curl -sf -H "Authorization: token ${DEPLOY_PAT}" \
            -H "User-Agent: skill-templates-deploy" \
            https://api.github.com/user > /dev/null; then
        echo "    ❌ DEPLOY_PAT health check failed — token cannot authenticate to GitHub API."
        echo "       Likely causes: expired PAT, missing scope, or secret value out of sync"
        echo "       with the actual token. Verify https://github.com/settings/tokens?type=beta"
        echo "       and re-set the secret: gh secret set DEPLOY_PAT --repo blamechris/skill-templates"
        exit 1
    fi

    # Clone with two defenses against macOS keychain interference (#15):
    #   1. -c credential.helper="" — disable any inherited credential
    #      helpers on the runner (osxkeychain in particular intercepts
    #      x-access-token:... URLs and substitutes cached user creds).
    #   2. GIT_TERMINAL_PROMPT=0 — fail rather than prompt if creds
    #      somehow miss; we always want fail-fast in CI.
    # stderr unsuppressed so the actual git error is visible.
    if ! GIT_TERMINAL_PROMPT=0 \
            git -c credential.helper="" \
                clone --depth 1 \
                "https://x-access-token:${DEPLOY_PAT}@github.com/${slug}.git" \
                "$clone_dir"; then
        echo "    ❌ git clone failed for $slug — see error above."
        echo "       PAT API health check passed (token authenticates to /user) but"
        echo "       this repo's clone returned non-zero. Common causes:"
        echo "       • The secret value is an older/different PAT than what's in"
        echo "         your settings page. Re-set with the current PAT:"
        echo "           gh secret set DEPLOY_PAT --repo blamechris/skill-templates"
        echo "       • Self-hosted runner credential helper interference (mitigated"
        echo "         by -c credential.helper above; if you still see 403, the PAT"
        echo "         genuinely lacks Contents:R/W on this repo)."
        exit 1
    fi

    cd "$clone_dir"

    # Same credential-helper defense for fetch/push operations downstream
    # via a per-repo git config that pins the helper to empty.
    git config --local credential.helper ""

    # Check if branch already exists on remote (idempotent).
    if git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
        git fetch origin "$BRANCH_NAME"
        git checkout "$BRANCH_NAME"
    else
        git checkout -b "$BRANCH_NAME"
    fi

    cd "$SCRIPT_DIR"
    CI_CLONED_REPOS+=("$repo")
}

deploy_ci() {
    local repo="$1" skill="$2" content="$3" idx="$4"
    local clone_dir="/tmp/skill-deploy/${repo}"
    local target_dir="$clone_dir/$SKILLS_DIR"
    local target_file="$target_dir/${skill}.md"

    ci_setup_repo "$repo" "$idx"

    mkdir -p "$target_dir"
    echo "$content" > "$target_file"
    echo "    ✅ Staged ${skill}.md"
}

ci_push_and_pr() {
    local repo="$1"
    local idx
    idx=$(conf_index "$repo")
    local slug="${CONF_SLUGS[$idx]}"
    local clone_dir="/tmp/skill-deploy/${repo}"

    cd "$clone_dir"

    # Check if there are changes
    if git diff --quiet && git diff --cached --quiet; then
        echo "  ℹ️  $repo: no changes to deploy"
        cd "$SCRIPT_DIR"
        return
    fi

    git add "$SKILLS_DIR/"
    git commit -m "chore(skills): update deployed skill templates

Automated deployment from skill-templates on ${BRANCH_DATE}." 2>/dev/null

    if ! git push -u origin "$BRANCH_NAME" 2>&1; then
        echo "    ❌ Failed to push $BRANCH_NAME to $slug"
        FAILURES+=("${repo}: git push failed")
        cd "$SCRIPT_DIR"
        return
    fi
    echo "    📤 Pushed $BRANCH_NAME to $slug"

    # Check for existing PR on this branch
    local existing_pr
    existing_pr=$(gh pr list --repo "$slug" --head "$BRANCH_NAME" --json number -q '.[0].number // empty' 2>/dev/null || true)

    if [ -n "$existing_pr" ]; then
        echo "    ℹ️  PR #${existing_pr} already exists — updated with new commits"
    else
        local pr_url
        if ! pr_url=$(gh pr create --repo "$slug" \
            --title "chore(skills): update skill templates (${BRANCH_DATE})" \
            --body "Automated skill template deployment from \`skill-templates\`.

## Updated Skills
$(git log origin/main..HEAD --format="" --name-only | sort -u | sed 's/^/- /')

## Review
These skills were customized from generic templates using the Claude API. Please review the customized content before merging." \
            --head "$BRANCH_NAME" 2>&1); then
            echo "    ❌ Failed to create PR for $slug"
            FAILURES+=("${repo}: gh pr create failed")
            cd "$SCRIPT_DIR"
            return
        fi
        echo "    🔗 Created PR: $pr_url"
    fi

    cd "$SCRIPT_DIR"
}

# --- Execute deployment ---
echo "Deploying..."
echo ""

for pair in "${DEPLOY_PAIRS[@]}"; do
    repo="${pair%%:*}"
    skill="${pair##*:}"
    deploy_pair "$repo" "$skill"
done

# CI mode: push and create PRs for each repo that had changes
if [ "$LOCAL_MODE" = false ]; then
    echo ""
    echo "Pushing and creating PRs..."
    for repo in "${CI_CLONED_REPOS[@]:-}"; do
        ci_push_and_pr "$repo"
    done
fi

# --- Summary ---
echo ""
echo "=== Deployment Summary ==="
echo "  Pairs attempted: ${#DEPLOY_PAIRS[@]}"
echo "  Failures: ${#FAILURES[@]}"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo "  Failed:"
    for f in "${FAILURES[@]}"; do
        echo "    ❌ $f"
    done
    exit 1
fi

echo ""
echo "Done."
