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

# Skills deployed DETERMINISTICALLY (no Claude API) — see issue #64. Their
# {{CUSTOMIZE}} markers are guidance comments and the functional code ships
# working defaults, so running them through Haiku adds only non-determinism and
# section-drop risk (batch-merge's entire Copilot gate was repeatably deleted).
# render_deterministic emits the template skeleton; validate_output still runs
# as a safety net.
#
# DORMANT by default (empty): emitting the skeleton uses TEMPLATE defaults for
# every marker, but some markers are genuinely per-repo — notably batch-merge's
# REQUIRED_CHECKS (rah6="Build, lint, test", sovereign-storm=()), which the
# default ("Run Tests"/"Validate Project") would wrongly overwrite and mis-gate.
# Enabling a skill here is safe only once Phase 3 (#64) substitutes those values
# per repo. Until then, opt in explicitly via env (e.g. DETERMINISTIC_SKILLS=...)
# for a repo you've checked. Space-delimited.
DETERMINISTIC_SKILLS="${DETERMINISTIC_SKILLS:-}"
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
    # Defense in depth: every current caller passes a validated idx, but a
    # future caller bypassing the upstream check would crash on
    # ${CONF_SKILLS[-1]} under bash 3.2 + set -u. Returning 1 (skill not in
    # repo) is the right semantic for an unknown repo.
    [ "$idx" = "-1" ] && return 1
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

    # 5. Skeleton preservation — EXACT guards for what checks 3 and 4 miss.
    # Check 3 (heading count ±5) and 4 (length 50-200%) are fuzzy: a render once
    # silently deleted batch-merge's entire Copilot review gate (Step 2b/2c, -81
    # lines, -2 headings) for one repo and slipped through BOTH tolerances. Rule
    # #3 of the system prompt requires every non-marker line be preserved
    # verbatim — this enforces it. The "skeleton" is the template minus the
    # trailing "## Customization*" section (stripped by rule #4) and minus
    # {{CUSTOMIZE}} marker lines (filled or removed by design).
    #
    # Uses temp files, NOT `grep -f <(...)`: process substitution as a grep
    # pattern file silently returns no matches on bash 3.2 / macOS (the runner),
    # which would make this check a no-op. Real files are reliable.
    #
    # One awk pass: stop at the first "## Customization*" heading (rule #4) and
    # skip {{CUSTOMIZE}} marker lines (filled/removed by design); sed right-trims
    # (the LLM may alter trailing whitespace). awk does the filtering — NOT
    # `grep -v` — so an all-marker template still exits 0 under `set -euo
    # pipefail`; grep returns 1 when it selects nothing, which pipefail would
    # propagate and abort the deploy (Copilot #63).
    local vo_skel vo_out vo_skel_h vo_out_h vo_body
    vo_skel=$(mktemp); vo_out=$(mktemp); vo_skel_h=$(mktemp); vo_out_h=$(mktemp); vo_body=$(mktemp)
    printf '%s\n' "$template" \
        | awk '
            /^#{2,}[[:space:]]+Customization([[:space:]]|$)/ { exit }
            /(^|[^`])[{][{]CUSTOMIZE/ { next }
            { print }' \
        | sed 's/[[:space:]]*$//' > "$vo_skel"
    printf '%s\n' "$output" | sed 's/[[:space:]]*$//' > "$vo_out"

    # 5a. Heading preservation — ZERO tolerance. Every real markdown heading
    # (outside code fences) in the skeleton must appear verbatim in the output.
    # Dropping a section means dropping its heading, so this pins section drops
    # precisely without the false positives a full-body line match would hit on
    # legitimate dangling-label cleanup. Reuses the fence-toggle from check 3.
    local heading_extract='/^```/ { in_code = !in_code; next } !in_code && /^#{1,6}[[:space:]]/ { print }'
    awk "$heading_extract" "$vo_skel" > "$vo_skel_h"
    awk "$heading_extract" "$vo_out" > "$vo_out_h"
    local missing_heads mh n_heads
    missing_heads=$(grep -Fxvf "$vo_out_h" "$vo_skel_h" || true)
    if [ -n "$missing_heads" ]; then
        n_heads=$(printf '%s\n' "$missing_heads" | grep -cE '.' || true)
        errors+=("Section drop: $n_heads template heading(s) missing from output — a section was deleted, not customized:")
        while IFS= read -r mh; do
            [ -n "$mh" ] || continue
            errors+=("         missing heading: ${mh}")
        done <<MH
$(printf '%s\n' "$missing_heads" | head -8)
MH
    fi

    # 5b. Body-line drift — bounded. Counts non-heading, non-blank skeleton lines
    # absent from the output. Tolerance 8 absorbs the occasional legit removal of
    # a label/intro line left dangling when its marker is dropped, while still
    # catching a large body deletion (the gate-drop's body alone was ~70 lines).
    # Body lines = skeleton minus blank and heading lines, via awk so an
    # all-heading/all-blank skeleton still exits 0 (grep -v would return 1 and,
    # under set -euo pipefail in this $(...), abort the deploy — Copilot #63).
    local missing_body n_body
    awk 'NF > 0 && $0 !~ /^#{1,6}[[:space:]]/ { print }' "$vo_skel" > "$vo_body"
    missing_body=$(grep -Fxvf "$vo_out" "$vo_body" || true)
    n_body=$(printf '%s\n' "$missing_body" | grep -cE '.' || true)
    if [ "$n_body" -gt 8 ]; then
        errors+=("Body drift: $n_body non-marker template line(s) missing from output (>8) — content dropped or rewritten, not just customized")
    fi
    rm -f "$vo_skel" "$vo_out" "$vo_skel_h" "$vo_out_h" "$vo_body"

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

# --- Deterministic render (no Claude API) ---
# is_deterministic_skill <skill> — true if the skill is in DETERMINISTIC_SKILLS.
is_deterministic_skill() {
    case " $DETERMINISTIC_SKILLS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# render_deterministic <template_content> — emit the template skeleton:
# stop at the first "## Customization*" heading (rule #4) and drop {{CUSTOMIZE}}
# marker lines (rule #2 fallback). Same awk as validate_output's skeleton, so a
# deterministic render passes check #5 by construction. awk does the filtering
# (not grep -v) so it exits 0 even when it emits nothing — set -euo pipefail safe.
render_deterministic() {
    printf '%s\n' "$1" | awk '
        /^#{2,}[[:space:]]+Customization([[:space:]]|$)/ { exit }
        /(^|[^`])[{][{]CUSTOMIZE/ { next }
        { print }'
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
    if is_deterministic_skill "$skill"; then
        # Deterministic path — no API, no retry. validate_output still runs as a
        # safety net (skeleton preservation passes by construction; it would
        # still catch a malformed template, e.g. an unterminated code fence).
        echo "    ⚙️  Deterministic render (no Claude API)"
        result=$(render_deterministic "$template_content")
        if ! validate_output "$result" "$template_content" "$skill" "$repo"; then
            FAILURES+=("${repo}:${skill} — deterministic render failed validation (template bug?)")
            return
        fi
    else
        # Call Claude and validate before writing — never write defective output.
        # Retry once on validation failure: Haiku is stochastic even at
        # temperature=0, so re-sampling typically clears transient drift without
        # changing the customization or relaxing the validator bounds.
        local v_attempt
        for v_attempt in 1 2; do
            # API errors: do NOT retry here — call_claude already has its own HTTP
            # retry (3x exponential backoff on 429/5xx, fail-fast on 4xx).
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
    # Defense in depth: caller validates idx upstream, but ${CONF_PATHS[-1]}
    # under bash 3.2 + set -u would crash. Matches the pattern in
    # ci_setup_repo and ci_push_and_pr.
    if [ "$idx" = "-1" ]; then
        echo "    ⚠️  Skipping deploy_local for unknown repo: '$repo'"
        FAILURES+=("${repo}:${skill} — unknown repo (idx=-1)")
        return
    fi
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
    # Defense in depth: deploy_pair already validates idx via conf_index, but
    # an unguarded ${CONF_SLUGS[-1]} would crash with "bad array subscript"
    # under bash 3.2 + set -u if a future caller bypasses the upstream check.
    # Matches the pattern used in ci_push_and_pr.
    if [ "$idx" = "-1" ]; then
        echo "    ⚠️  Skipping ci_setup_repo for unknown repo: '$repo'"
        return
    fi
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

    # Supersede older deploy PRs. Each deploy opens a fresh `skill-deploy/<date>`
    # branch off main; older ones are never closed, so they pile up and conflict
    # (every branch overlaps the same `.claude/commands/*` files). The newest
    # render is authoritative, so close any OTHER open skill-deploy PR in this
    # repo and link it here. Best-effort: never fail the deploy on a close error.
    #
    # NOTE: this assumes the newest render is correct. Renders are non-
    # deterministic (Claude API), so a bad newer render can supersede a good
    # older one — the standing guidance is to DIFF a skill-deploy PR before
    # merging it regardless.
    # --limit 100 (not the default 30): this is the only unbounded `gh pr list`
    # in the file; without it a repo with >30 open PRs could silently skip
    # older deploy PRs and defeat the supersede.
    local stale_prs old branch
    stale_prs=$(gh pr list --repo "$slug" --state open --limit 100 \
        --json number,headRefName \
        -q ".[] | select(.headRefName | startswith(\"skill-deploy/\")) | select(.headRefName != \"$BRANCH_NAME\") | \"\(.number) \(.headRefName)\"" \
        2>/dev/null || true)
    while read -r old branch; do
        [ -n "$old" ] || continue
        # Close FIRST (no --delete-branch). Closing is what stops the pile-up.
        # Keeping branch deletion separate means a protected branch or a token
        # without delete scope can't make the whole call fail and leave the PR
        # open — which would re-list and re-comment on every later run (spam).
        if gh pr close "$old" --repo "$slug" \
            --comment "Superseded by the newer skill deploy on \`$BRANCH_NAME\`. Closing to avoid stacked, conflicting skill-deploy PRs — review/merge the newest one instead." \
            >/dev/null 2>&1; then
            echo "    🧹 Superseded older deploy PR #$old in $slug"
            # Best-effort branch cleanup; never affects the close above.
            gh api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1 \
                && echo "       🧽 deleted branch $branch" || true
        else
            echo "    ⚠️  Could not close older deploy PR #$old in $slug (left open)"
        fi
    done <<EOF
$stale_prs
EOF

    cd "$SCRIPT_DIR"
}

# --- Execute deployment ---
echo "Deploying..."
echo ""

# Defense in depth: the early-exit guard at line 206 already prevents reaching
# here with empty DEPLOY_PAIRS, but a co-located length check makes the local
# safety story explicit and lets static analysis verify it without reasoning
# about a 500-line interval. Matches the pattern at line 191.
if [ ${#DEPLOY_PAIRS[@]} -gt 0 ]; then
    for pair in "${DEPLOY_PAIRS[@]}"; do
        repo="${pair%%:*}"
        skill="${pair##*:}"
        deploy_pair "$repo" "$skill"
    done
fi

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
