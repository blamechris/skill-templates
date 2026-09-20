# /create-issue

Create a standardized GitHub issue with labels and traceability.

## Arguments

- `$ARGUMENTS` - Issue title (required). Optionally followed by flags:
  - `--from-pr N` — Link to source PR
  - `--from-issue N` — Link to source issue (e.g. a decomposition parent)
  - `--comment-url URL` — Link to specific review comment
  - `--complexity low|medium|high` — Set complexity label
  - `--label NAME` — Additional label (repeatable)
  - `--standalone` — This issue genuinely has no source; if nothing else resolves one, forces `Filed from: none` instead of the refusal below

## Instructions

### 1. Parse Arguments and Gather Context

Extract the title and any flags from `$ARGUMENTS`. **Resolve `FILED_FROM` — the source for the required `Filed from:` line (#268) — in this order, first match wins:**

1. `--from-pr N` or `--from-issue N` (explicit flag) → `#N`, plus `--comment-url` in parentheses if given
2. Not explicit, but on a PR branch → the current PR, auto-detected
3. Not explicit, not on a PR branch, but a session id is available → `session ${CLAUDE_CODE_SESSION_ID}`
4. `--standalone` → `none`; nothing resolved (no flag, no PR, no session, no `--standalone`) → REFUSE and ask the user rather than silently defaulting to `none` — the whole point of Critical Rule 7 is that `none` is a deliberate choice, never a fallback for "didn't figure it out"

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Check if we're on a PR branch (auto-detect source PR)
CURRENT_PR=$(gh pr view --json number -q .number 2>/dev/null || echo "")

# Flag values from $ARGUMENTS, empty if the flag was not given:
FROM_PR="${FROM_PR:-}"           # --from-pr N
FROM_ISSUE="${FROM_ISSUE:-}"     # --from-issue N
COMMENT_URL="${COMMENT_URL:-}"   # --comment-url URL
STANDALONE="${STANDALONE:-}"     # --standalone

# FILED_FROM per the resolution order above:
if [ -n "$FROM_PR" ]; then
  FILED_FROM="#${FROM_PR}"
elif [ -n "$FROM_ISSUE" ]; then
  FILED_FROM="#${FROM_ISSUE}"
elif [ -n "$CURRENT_PR" ]; then
  FILED_FROM="#${CURRENT_PR}"
elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  FILED_FROM="session ${CLAUDE_CODE_SESSION_ID}"
elif [ -n "$STANDALONE" ]; then
  FILED_FROM="none"
else
  echo "REFUSE: no source resolved — pass --from-pr N, --from-issue N, or --standalone" >&2
  exit 1
fi
if [ -n "$COMMENT_URL" ] && [[ "$FILED_FROM" == \#* ]]; then
  FILED_FROM="${FILED_FROM} (${COMMENT_URL})"
fi
```

### 2. Check for Duplicates

Before creating, scan for existing issues with similar titles:

```bash
# Search open issues for potential duplicates
gh issue list --state open --search "${ISSUE_TITLE}" --json number,title --limit 5
```

If a close match exists, show it to the user and ask whether to proceed or reference the existing issue instead.

### 3. Build Issue Body

Construct the issue body based on available context.

#### From-Review Issue (has source PR or comment URL)

```markdown
## Context

Filed from: ${FILED_FROM}

{{CUSTOMIZE: origin line — e.g., "Found during review of PR #N"}}
Identified during review of PR #${SOURCE_PR}.

{{If comment URL provided and not already folded into Filed from: above:}}
**Review comment:** ${COMMENT_URL}

{{If file/line can be extracted from comment:}}
**Location:** \`${FILE_PATH}:${LINE_NUMBER}\`

## Description

What needs to be done and why. Be specific — another developer should be able to pick this up without reading the original review thread.

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
```

#### Standalone Issue (no review context)

```markdown
## Context

Filed from: ${FILED_FROM}

## Description

What needs to be done and why.

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
```

The `## Context` section, and its `Filed from:` first line, is present in **every** issue this
skill files — including the standalone template. `${FILED_FROM}` is never left as a
placeholder: it is one of the four resolved forms from step 1 (`#N`, `#N (<url>)`,
`session <id>`, or the literal `none`).

### 4. Determine Labels

Build the label set:

```bash
LABELS="enhancement"

# Always add from-review if this came from a PR review
if [ -n "$SOURCE_PR" ] || [ -n "$COMMENT_URL" ]; then
  LABELS="$LABELS,from-review"
fi

# Add complexity label if specified
# {{CUSTOMIZE: Some repos use complexity:low/medium/high, others don't}}
if [ -n "$COMPLEXITY" ]; then
  LABELS="$LABELS,complexity:$COMPLEXITY"
fi

# Add any extra --label flags
for extra in "${EXTRA_LABELS[@]}"; do
  LABELS="$LABELS,$extra"
done
```

**Verify labels exist** before using them. If a label doesn't exist in the repo, skip it rather than failing:

```bash
# Check if label exists
gh label list --json name -q '.[].name' | grep -q "^from-review$" || echo "Warning: 'from-review' label not found in repo"
```

### 5. Create the Issue

```bash
ISSUE_URL=$(gh issue create \
  --title "${ISSUE_TITLE}" \
  --label "${LABELS}" \
  --body "$(cat <<'EOF'
${ISSUE_BODY}
EOF
)")
```

### 6. Extract Issue Number

```bash
ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
```

### 7. Report to User

Output a **summary table** — this is the PRIMARY output:

```markdown
| Issue | Title | Labels | Source |
|-------|-------|--------|--------|
| #${ISSUE_NUM} | ${ISSUE_TITLE} | from-review, complexity:low | PR #${SOURCE_PR} |
```

Then below the table:
- Issue URL (clickable)
- Labels applied
- Source PR link (if applicable)
- Review comment link (if applicable)

## Critical Rules

1. **NO attribution** — Follow Zero Attribution Policy.
2. **Check for duplicates** — Always search before creating. Don't create duplicate issues.
3. **Labels must exist** — Verify labels exist in the repo. Skip missing labels gracefully.
4. **Be specific** — The issue description must be self-contained. Another developer should understand it without reading the review thread.
5. **Always include acceptance criteria** — Even if just one checkbox. Issues without criteria are hard to close confidently.
6. **Link to source** — If from a review, always include the PR number and comment URL in the body.
7. **The `Filed from:` line is required and machine-read — the four forms, and never omitted** (#268). Every issue this skill files opens `## Context` with exactly one of: `Filed from: #NNN`, `Filed from: #NNN (<url>)`, `Filed from: session <id>`, or `Filed from: none`. It is what `assets/scripts/filed-from.py check` and `chain` read to compute whether a PR spawned follow-on work and to walk a rework chain without a human re-reading every body — an issue filed without it is invisible to both. `none` is a real, deliberate choice for a genuinely standalone issue, never a default reached by skipping the resolution order in step 1.

## Customization Points

- Default labels (some repos use `complexity:` and `testing:` labels, others just `enhancement` + `from-review`)
- Issue body template sections
- Label verification behavior (skip vs create missing labels)
