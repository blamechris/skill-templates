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

    # Deduplicate (skip when empty — bash 3.2 set -u crashes on "${EMPTY[@]}")
    if [ ${#DEPLOY_PAIRS[@]} -gt 0 ]; then
        local -a unique=()
        local seen=""
        for pair in "${DEPLOY_PAIRS[@]}"; do
            if [[ "$seen" != *"|$pair|"* ]]; then
                unique+=("$pair")
                seen="${seen}|$pair|"
            fi
        done
        DEPLOY_PAIRS=("${unique[@]}")
    fi
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
8. Do NOT invent example content. If a {{CUSTOMIZE: ...}} marker asks for examples (bug rows, agent rosters, label sets, command snippets, file:line citations) and the customization notes do not explicitly provide them, use placeholder syntax instead of fabricating specifics:
   - Bug examples: `bug(scope): concise title` for the title and `path/to/file:<line>` for the location. Never guess a real file or line number — placeholders are better than fabricated specifics.
   - Agent rosters: include ONLY agents the customization notes name. Do not invent nicknames, lenses, or when-to-include rules.
   - Label sets: use only labels the customization notes provide. Do not invent label names.
   - Command examples: copy the shape from the template; do not synthesize new commands with parameters the notes did not specify.
   - When uncertain whether something is real or invented, prefer omitting it over fabricating it.
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

# --- Validate Haiku's output before writing to disk ---
# Catches the four PR #17 defect classes (see docs/audit-results/customization-pipeline):
#   - residual {{CUSTOMIZE markers (Haiku didn't fill or remove)
#   - attribution footers (zero-attribution policy violation)
#   - heading-count drift (major section dropped or hallucinated)
#   - length bounds (truncation or runaway expansion)
# Returns 0 if output passes, 1 with diagnostics on stderr if it fails.
# Arguments: output_text template_text skill_name repo_name
validate_output() {
    local output="$1"
    local template="$2"
    local skill="$3"
    local repo="$4"
    local errors=()

    # 1. Residual {{CUSTOMIZE markers — Haiku failed to fill or remove.
    # Match {{CUSTOMIZE that is at line start OR preceded by a non-backtick
    # character. Excludes inline-code prose mentions like `{{CUSTOMIZE: ...}}`
    # (the backtick before the marker disqualifies it) without missing real
    # markers that follow markdown prefixes such as `# {{CUSTOMIZE: ...}}`
    # (batch-merge.md:54) or appear mid-sentence (autonomous-dev-flow.md:66).
    if printf '%s' "$output" | grep -qE '(^|[^`])\{\{CUSTOMIZE'; then
        local marker_count
        marker_count=$(printf '%s' "$output" | grep -cE '(^|[^`])\{\{CUSTOMIZE' || true)
        errors+=("Residual {{CUSTOMIZE marker(s) ($marker_count) — Haiku left them unfilled")
    fi

    # 2. Attribution footer — violates zero-attribution policy across all repos.
    # Match only at LINE START in the LAST 15 LINES of output. Real attribution
    # footers always live at the bottom on their own lines (the standard
    # `🤖 Generated with [Claude Code](...)` + `Co-Authored-By: Claude <email>`
    # block). Without the line-start anchor + tail bound, this false-positives
    # on rule text inside templates that *describes* what NOT to do — e.g.,
    # autonomous-dev-flow.md:423 says `No Co-Authored-By, no "Generated with
    # Claude"`, which Haiku faithfully preserves per system-prompt rule #3,
    # and the unfiltered regex would then reject the legit preserved rule.
    if printf '%s' "$output" | tail -n 15 | grep -qE '^(🤖[[:space:]]+)?Generated with[[:space:]]+(\[?Claude|Claude Code)|^Co-Authored-By:[[:space:]]+Claude'; then
        errors+=("Attribution footer detected (Co-Authored-By: Claude or Generated with Claude)")
    fi

    # 3. Heading-count parity — coarse check that no major section was dropped
    # or hallucinated. Tolerance is ±5: Rule 4 strips the Customization Points
    # section and customizations may add a couple of headings legitimately.
    #
    # Count only REAL markdown headings, not bash comments inside fenced code
    # blocks. Templates contain `# {{CUSTOMIZE: ...}}` comment lines inside
    # ```bash blocks that look like headings to a naive `^#{1,6}` regex. When
    # Haiku correctly strips unfilled markers (system-prompt rule #2), those
    # code-block comments disappear too, producing a large false drift count.
    # The awk script toggles state on ``` fences and only counts # lines while
    # OUTSIDE a fenced block — which is where real markdown headings live.
    local heading_awk='/^```/ { in_code = !in_code; next } !in_code && /^#{1,6}[[:space:]]/ { count++ } END { print count+0 }'
    local tmpl_headings out_headings diff
    tmpl_headings=$(printf '%s' "$template" | awk "$heading_awk")
    out_headings=$(printf '%s' "$output" | awk "$heading_awk")
    diff=$((tmpl_headings - out_headings))
    if [ "$diff" -gt 5 ] || [ "$diff" -lt -5 ]; then
        errors+=("Heading count drift: template=$tmpl_headings output=$out_headings (diff $diff, expected ±5)")
    fi

    # 4. Length bounds — output should be 50%-200% of template length.
    # Tighter than this would false-positive on heavy customization;
    # looser would miss truncation or runaway.
    local tmpl_len out_len
    tmpl_len=${#template}
    out_len=${#output}
    if [ "$out_len" -lt $((tmpl_len / 2)) ]; then
        errors+=("Output length $out_len < 50% of template $tmpl_len — likely truncated")
    fi
    if [ "$out_len" -gt $((tmpl_len * 2)) ]; then
        errors+=("Output length $out_len > 200% of template $tmpl_len — likely runaway expansion")
    fi

    if [ "${#errors[@]}" -gt 0 ]; then
        echo "    ❌ Output validation failed for ${repo} ← ${skill}.md:" >&2
        local e
        for e in "${errors[@]}"; do
            echo "       - $e" >&2
        done
        return 1
    fi

    return 0
}

# --- Deploy a single pair ---
declare -a FAILURES=()

# Telemetry counters for Haiku validation-retry observability (#43). Tracks
# how often the 1-shot retry in deploy_pair fires so chronic over-elaboration
# (a borderline customization sneaking through via re-sample) is visible.
PAIRS_ATTEMPTED=0
PAIRS_RETRIED=0
PAIRS_FAILED_AFTER_RETRY=0

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
    PAIRS_ATTEMPTED=$((PAIRS_ATTEMPTED + 1))

    local template_content custom_content
    template_content=$(<"$template")
    custom_content=$(<"$custom")

    # Call Claude and validate the output before writing to disk. Validation
    # failure is a hard stop — never write defective customization.
    #
    # Retry once on validation failure: Haiku produces stochastic outputs even
    # at temperature=0 (sovereign-storm:check-pr in run 26554429712 produced
    # 32 headings on a 23-heading template, then 22 headings on the very next
    # local re-run — same inputs, same model). Re-sampling typically clears
    # transient drift without changing the customization or relaxing the
    # validator bounds.
    local result
    local v_attempt
    for v_attempt in 1 2; do
        # API errors: do NOT retry here — call_claude already has its own HTTP
        # retry (3x exponential backoff on 429/5xx, fail-fast on 400/401/403/404).
        # Re-trying here would double up on transients and obscure the real
        # 4xx auth/quota failures that should fail loudly. This loop only
        # re-samples on validation failure.
        if ! result=$(call_claude "$template_content" "$custom_content" "$repo" "$skill"); then
            FAILURES+=("${repo}:${skill} — API error")
            return
        fi
        if validate_output "$result" "$template_content" "$skill" "$repo"; then
            break
        fi
        if [ "$v_attempt" = "1" ]; then
            echo "    ↻  Validation failed on attempt 1 — re-sampling Haiku (output variance)" >&2
            PAIRS_RETRIED=$((PAIRS_RETRIED + 1))
        else
            PAIRS_FAILED_AFTER_RETRY=$((PAIRS_FAILED_AFTER_RETRY + 1))
            FAILURES+=("${repo}:${skill} — output validation failed after retry")
            return
        fi
    done

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

    # Skip if already set up. Note: ${arr[@]:-} on bash 3.2 expands an empty
    # array to a single empty-string element, causing a spurious loop iteration.
    # Guard with the array length instead.
    if [ ${#CI_CLONED_REPOS[@]} -gt 0 ]; then
        for r in "${CI_CLONED_REPOS[@]}"; do
            [ "$r" = "$repo" ] && return 0
        done
    fi

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
    # `git fetch origin <branch>` only updates FETCH_HEAD — it does not create a
    # local branch or remote-tracking ref, so a plain `git checkout <branch>`
    # afterward fails with "pathspec did not match". Use `checkout -B <branch>
    # FETCH_HEAD` to (re)create the local branch pointing at what we just
    # fetched. This is idempotent across reruns of the same day.
    if git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
        git fetch origin "$BRANCH_NAME"
        git checkout -B "$BRANCH_NAME" FETCH_HEAD
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
    # Defensive: empty/unknown repo (e.g., from a bad caller) would index
    # CONF_SLUGS[-1] and bash errors with "bad array subscript".
    if [ "$idx" = "-1" ]; then
        echo "    ⚠️  Skipping ci_push_and_pr for unknown repo: '$repo'"
        return
    fi
    local slug="${CONF_SLUGS[$idx]}"
    local clone_dir="/tmp/skill-deploy/${repo}"

    cd "$clone_dir"

    # Stage first, then check the staged diff. `git diff --quiet` alone misses
    # NEW untracked files (e.g., a brand-new skill being deployed for the first
    # time to a repo that never had it), causing the function to silently
    # no-op when the only change is a new file. Staging makes git see all
    # additions, modifications, and deletions in the staged tree.
    #
    # Guard the `git add`: if SKILLS_DIR doesn't exist in the clone (e.g., a
    # repo that's never had a `.claude/commands/` dir), `git add` errors out
    # under `set -e`. In that case there's nothing to deploy by definition.
    if [ ! -d "$SKILLS_DIR" ]; then
        echo "  ℹ️  $repo: no changes to deploy (no $SKILLS_DIR/ in clone)"
        cd "$SCRIPT_DIR"
        return
    fi
    git add "$SKILLS_DIR/"
    if git diff --cached --quiet; then
        echo "  ℹ️  $repo: no changes to deploy"
        cd "$SCRIPT_DIR"
        return
    fi

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
        local pr_body
        pr_body="Automated skill template deployment from \`skill-templates\`.

## Updated Skills
$(git log origin/main..HEAD --format="" --name-only | sort -u | sed 's/^/- /')

## Review
These skills were customized from generic templates using the Claude API. Please review the customized content before merging."

        # Retry once with backoff — `gh pr create` failures are usually transient
        # (GitHub API consistency window after the branch push, brief 5xx, etc.).
        # Capture stderr to a tempfile (bash 3.2 friendly) so the success log
        # contains only the PR URL, while failure stderr is still available for
        # diagnostics. 2>&1 would pollute the success URL line if gh emitted a
        # deprecation or self-update notice.
        local attempt
        local pr_stderr_file
        pr_stderr_file=$(mktemp)
        local pr_stderr=""
        for attempt in 1 2; do
            if pr_url=$(gh pr create --repo "$slug" \
                --title "chore(skills): update skill templates (${BRANCH_DATE})" \
                --body "$pr_body" \
                --head "$BRANCH_NAME" 2>"$pr_stderr_file"); then
                echo "    🔗 Created PR: $pr_url"
                rm -f "$pr_stderr_file"
                break
            fi
            pr_stderr=$(cat "$pr_stderr_file")
            if [ "$attempt" = "1" ]; then
                echo "    ⚠️  gh pr create failed (attempt 1/2) — retrying in 8s. Error:"
                printf '%s\n' "$pr_stderr" | sed 's/^/       /'
                sleep 8
            else
                # Partial-success recovery: attempt 1 may have created the PR
                # server-side but lost the response (TCP reset, proxy 502, etc.).
                # In that case attempt 2 returns "a pull request for branch ...
                # already exists". Re-query the PR list — if it's there, treat
                # the deploy as successful instead of double-counting it.
                if printf '%s' "$pr_stderr" | grep -qE 'already exists|a pull request for branch'; then
                    local recovered_url
                    recovered_url=$(gh pr list --repo "$slug" --head "$BRANCH_NAME" --json url -q '.[0].url // empty' 2>/dev/null || true)
                    if [ -n "$recovered_url" ]; then
                        echo "    🔗 PR existed after retry: $recovered_url (recovered from attempt 1 partial success)"
                        rm -f "$pr_stderr_file"
                        break
                    fi
                fi
                echo "    ❌ Failed to create PR for $slug after 2 attempts. Error:"
                printf '%s\n' "$pr_stderr" | sed 's/^/       /'
                rm -f "$pr_stderr_file"
                FAILURES+=("${repo}: gh pr create failed")
                cd "$SCRIPT_DIR"
                return
            fi
        done
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
if [ "$LOCAL_MODE" = false ] && [ ${#CI_CLONED_REPOS[@]} -gt 0 ]; then
    echo ""
    echo "Pushing and creating PRs..."
    for repo in "${CI_CLONED_REPOS[@]}"; do
        ci_push_and_pr "$repo"
    done
fi

# --- Summary ---
echo ""
echo "=== Deployment Summary ==="
echo "  Pairs attempted: ${#DEPLOY_PAIRS[@]}"
echo "  Failures: ${#FAILURES[@]}"

# Haiku validation-retry telemetry (#43). Surface the rate so chronic
# borderline customizations are visible; warn above 3% sustained (the alarm
# threshold from the issue) when the sample is large enough (>30 pairs) to
# avoid noise on small filtered deploys.
if [ "$PAIRS_RETRIED" -gt 0 ] || [ "$PAIRS_FAILED_AFTER_RETRY" -gt 0 ]; then
    if [ "$PAIRS_ATTEMPTED" -gt 0 ]; then
        retry_rate=$(awk "BEGIN { printf \"%.1f\", $PAIRS_RETRIED * 100 / $PAIRS_ATTEMPTED }")
        echo "  Haiku validation retries: $PAIRS_RETRIED/$PAIRS_ATTEMPTED ($retry_rate%) — of which failed after retry: $PAIRS_FAILED_AFTER_RETRY"
        if [ "$PAIRS_ATTEMPTED" -gt 30 ] && awk "BEGIN { exit !($PAIRS_RETRIED * 100 / $PAIRS_ATTEMPTED > 3) }"; then
            echo "  ⚠️  Retry rate exceeds 3% — investigate (degraded Haiku output or over-elaborated customization)"
        fi
    fi
fi

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
