# /autonomous-dev-flow

Orchestrate long-running autonomous dev sessions — work through GitHub issues sequentially with TDD, create PRs, run /full-review, and continue to the next issue. The user checks in to merge completed PRs while work continues.

## Arguments

- `$ARGUMENTS` - Issue source and options. Examples:
  - `label:ready-to-build` (all open issues with this label)
  - `milestone:"v1.2"` (all open issues in milestone)
  - `#12 #15 #18` (specific issues by number)
  - `label:ready-to-build max:5 sort:created-asc` (with options)
  - Options: `max:N` (default 10, hard cap 15), `sort:created-asc` (default) or `sort:priority`

## Instructions

### 0. Parse Arguments and Build Work Queue

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

Parse `$ARGUMENTS` to determine the issue source:

- **Label**: `gh issue list --label "${LABEL}" --state open --json number,title,labels --limit ${MAX}`
- **Milestone**: `gh issue list --milestone "${MILESTONE}" --state open --json number,title,labels --limit ${MAX}`
- **Explicit list**: `gh issue view ${NUM} --json number,title,state` for each `#N`

Apply sort order and cap to `max` (hard cap 15 — sessions beyond this rarely maintain quality).

**Validate the queue before starting:**
- At least 1 issue must be open and unassigned
- If 0 issues match, report and stop — don't start an empty session
- Show the user the queue and get confirmation before entering the loop

```markdown
## Work Queue ({N} issues)

| # | Issue | Labels |
|---|-------|--------|
| 1 | #12 — Add retry logic to API client | enhancement |
| 2 | #15 — Fix race condition in session cleanup | bug |
| 3 | #18 — Add integration tests for auth flow | testing |

Start autonomous dev session?
```

Wait for user confirmation. This is the ONLY confirmation point — everything after is autonomous.

### 0.5. Auto-Decompose High-Complexity Issues

When the queue contains issues that are too large to implement directly (e.g., labeled `complexity: high` or equivalent), decompose them into smaller, independently implementable sub-issues BEFORE entering the core loop.

For each high-complexity issue:

1. Read the full issue body and understand the complete scope
2. Break into 2-5 sub-issues, each low or medium complexity
3. Create sub-issues via `gh issue create` with:
   - Title: `type(scope): Sub-task description`
   - Body: implementation plan, files to modify, test strategy
   - Labels: appropriate complexity and category labels
   - Reference: `Part of #parent` in body
4. Insert sub-issues at FRONT of queue (context is fresh from reading the parent)
5. Comment on parent issue: `gh issue comment ${PARENT} --body "Decomposed into #A, #B, #C"`
6. Parent stays open until all sub-issues merge — do NOT close it

**Skip criteria** — auto-skip these issues (log reason in progress table):
- No code path (manual testing, design docs, decisions needed)
- Requires user input not present in the description
- Deployment/release tasks
- Issues labeled `blocked` or `wontfix`
- Issues requiring design decisions with multiple valid approaches not specified

If skipping, comment on the issue: `gh issue comment ${NUM} --body "Skipped during autonomous dev session — [reason]. Needs manual attention."`

### 1. Session Setup

Create a task list to track progress across the session:

```
For each issue in the work queue:
  TaskCreate: "Issue #N — <title>" with status pending
```

Check for any existing `auto/*` branches or open PRs from a previous session:

```bash
# Check for existing auto/ branches with open PRs
gh pr list --json number,title,headRefName --limit 50 \
  | jq '[.[] | select(.headRefName | startswith("auto/"))]'

# Check for local auto/ branches
git branch --list "auto/*"
```

If previous session PRs exist:
- Already merged → note as completed, skip those issues
- Still open → note their status, skip those issues (user can re-queue if needed)
- No PR yet but branch exists → delete stale branch, re-process the issue

### 2. Core Loop — For Each Issue

Process each issue sequentially. For each issue:

#### 2a. Prepare Branch

```bash
# Always start from latest main
git checkout main
git pull origin main

# Create branch from issue number + slugified title
# {{CUSTOMIZE: Branch naming convention — e.g., auto/<number>-<slug> vs feat/<number>-<slug>}}
BRANCH="auto/${ISSUE_NUM}-${SLUG}"
git checkout -b "${BRANCH}"
```

**CRITICAL: Always branch from main, never from a previous issue's branch.** This ensures PRs are independently mergeable in any order — no cascade rebases.

#### 2b. Understand the Issue

```bash
# Read full issue details
gh issue view ${ISSUE_NUM} --json title,body,labels,comments
```

Read the issue body, comments, and acceptance criteria. Identify:
- What needs to change
- Which files are likely involved
- What the acceptance criteria are

Explore the codebase to understand the relevant code before writing anything:

```bash
# Read CLAUDE.md for project conventions
cat CLAUDE.md 2>/dev/null

# Explore relevant files based on issue description
```

#### 2c. TDD Cycle: RED → GREEN → REFACTOR

**This is the core development methodology. Follow it strictly.**

##### RED — Write Failing Tests First

Based on the issue's acceptance criteria, write tests that describe the desired behavior. Tests MUST fail before any implementation.

```bash
# {{CUSTOMIZE: Test runner command — e.g., npm test, pytest, godot --headless --script}}
# {{CUSTOMIZE: Test file conventions — e.g., __tests__/*.test.ts, *_test.gd, *.spec.js}}

# Run tests to confirm they fail
${TEST_COMMAND}
```

If tests pass immediately, the behavior already exists — investigate before proceeding. Either the issue is already resolved or the tests don't capture the right behavior.

##### GREEN — Make Tests Pass

Write the minimum implementation to make all new tests pass. Don't over-engineer — just satisfy the tests.

```bash
# Run tests to confirm they pass
${TEST_COMMAND}
```

If tests still fail, iterate on the implementation until they pass. Do NOT move to REFACTOR until all tests are green.

##### REFACTOR — Clean Up

With green tests as a safety net:
- Remove duplication
- Improve naming
- Simplify logic
- Ensure the code follows project conventions (per CLAUDE.md)

```bash
# Run tests again to confirm refactoring didn't break anything
${TEST_COMMAND}

# {{CUSTOMIZE: Lint/typecheck commands — e.g., npm run lint, npm run typecheck, mypy .}}
${LINT_COMMAND}
```

#### 2d. Commit and Push

Commit with a conventional commit message referencing the issue:

```bash
# Stage relevant files (never git add -A)
git add <specific-files>

# Commit with issue reference — NO attribution
git commit -m "$(cat <<'EOF'
type(scope): description

Implements the core change described in the issue.

Refs #${ISSUE_NUM}
EOF
)"

# {{CUSTOMIZE: Commit scope conventions — e.g., server, app, core, ui}}

git push -u origin ${BRANCH}
```

#### 2e. Check for Merged PRs Mid-Session

Before creating the next PR, check if the user has merged any PRs from this session:

```bash
# Check which auto/ PRs have been merged since session start
gh pr list --state merged --json number,headRefName,mergedAt --limit 20 \
  | jq '[.[] | select(.headRefName | startswith("auto/"))]'
```

If PRs were merged, update main awareness:
```bash
git checkout main
git pull origin main
git checkout ${BRANCH}
# Only rebase if main moved AND it affects this branch's files
```

#### 2f. Create PR (Autonomous — No Confirmation)

**This is an intentional departure from /create-pr which requires user confirmation.** In autonomous mode, PRs ARE the checkpoints — the user reviews and merges them asynchronously.

```bash
# Detect closable issues (same logic as /create-pr step 2)
# Scan commits for #NNN references, check branch name for issue numbers

PR_URL=$(gh pr create \
  --title "${PR_TITLE}" \
  --body "$(cat <<'EOF'
## Summary

- Change 1
- Change 2

Closes #${ISSUE_NUM}

## Test Plan

- [ ] All new tests pass
- [ ] Existing tests unbroken
{{CUSTOMIZE: PR test plan items — e.g., "- [ ] App type-checks clean", "- [ ] Manual smoke test"}}
EOF
)")

PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
```

#### 2g. Run /full-review

Execute the full review pipeline on the newly created PR:

1. **Agent review** — deep expert review against project standards
2. **Check-PR** — process all review comments (Copilot + agent-review findings)

Capture the results: verdict, findings counts, fixes committed, issues created/closed.

#### 2h. Assess and Record Outcome

Based on the /full-review results, classify the PR:

| Verdict | Meaning | Action |
|---------|---------|--------|
| Clean | No critical findings, all comments addressed | Mark issue done, continue |
| Needs attention | Critical findings or unresolved comments | Flag for user, continue to next issue |
| Broken | Tests failing after review fixes, or fundamental problems | Flag for user, continue to next issue |

**CRITICAL: Never block the session on a flagged PR.** The whole point of autonomous mode is continuous progress. The user addresses flagged PRs during check-ins.

Update the task list:

```
TaskUpdate: "Issue #N" → completed (or flagged)
```

#### 2i. Output Progress Table

After each issue, output a cumulative progress table. This is what the user sees during check-ins.

```markdown
## Session Progress ({completed}/{total})

| # | Issue | Branch | PR | Review | Status |
|---|-------|--------|----|--------|--------|
| 1 | #12 — Add retry logic | auto/12-add-retry | #45 | Approve (0 critical) | Done |
| 2 | #15 — Fix race condition | auto/15-fix-race | #46 | Request Changes (1 critical) | Needs attention |
| 3 | #18 — Add auth tests | — | — | — | In progress |
| 4 | #22 — Update error handling | — | — | — | Queued |
```

### 3. Session Summary

After all issues are processed (or the queue is exhausted), output a final session summary:

```markdown
## Autonomous Dev Session Complete

**Duration:** {N} issues processed
**Queue:** {source description}

### Results

| # | Issue | PR | Review Verdict | Status |
|---|-------|----|---------------|--------|
| 1 | #12 — Add retry logic | [#45](url) | Approve | Ready to merge |
| 2 | #15 — Fix race condition | [#46](url) | Request Changes | Needs attention |
| 3 | #18 — Add auth tests | [#47](url) | Approve | Ready to merge |

### Summary
- **Ready to merge:** N PRs
- **Needs attention:** M PRs (details below)
- **Issues created during reviews:** #A, #B, #C
- **PRs merged by user during session:** #X, #Y

### Needs Attention
- **PR #46** (#15 — Fix race condition): 1 critical finding — race condition in cleanup handler not fully addressed. See review comment.

### Next Steps
- Merge ready PRs
- Address flagged PRs
- Review created issues for follow-up work
```

## Resume Strategy

This skill uses **GitHub state** for resume — no local state files.

If a session is interrupted (crash, timeout, user stops it), re-running the skill with the same arguments will:

1. Query GitHub for existing `auto/*` branches and PRs
2. Skip issues that already have merged or open PRs
3. Resume from the first issue without a PR

This means the skill is **idempotent** — safe to re-run without duplicating work.

## Critical Rules

1. **NO attribution** — No Co-Authored-By, no "Generated with Claude", no AI mentions. Zero Attribution Policy.
2. **TDD is mandatory** — RED → GREEN → REFACTOR for every issue. No skipping tests. If the issue is pure docs or config, tests may be N/A — note why.
3. **Branch from main every time** — Never stack branches. Each PR must be independently mergeable.
4. **One confirmation point** — The initial queue approval. Everything after is autonomous.
5. **Never block on review findings** — Flag and move on. The user handles flagged PRs.
6. **Progress table after every issue** — The user may check in at any time. The table must be current.
7. **Respect the hard cap** — Max 15 issues per session. Refuse larger queues.
8. **Resume from GitHub state** — No local state files. Query `auto/*` branches/PRs to detect prior work.
9. **Clean up on skip** — If an issue is already done (merged PR exists), note it and move on. Don't recreate work.
10. **Compose existing skills** — /full-review is called as-is (which chains /agent-review → /check-pr). Don't reinvent their logic.
11. **Decompose, don't skip** — High-complexity issues get broken into sub-issues, not skipped. Only skip truly non-automatable work.
12. **Comment on skips** — Every skipped issue gets a GitHub comment explaining why. The user sees the reason.
13. **Pre-Skill Checkpoint** — Re-read CLAUDE.md before running /full-review to prevent context drift in long sessions.

## Customization Points

Lines and sections marked with `{{CUSTOMIZE}}` need repo-specific adaptation:

- **Default issue label** for work queue (e.g., `ready-to-build`, `ready`, `accepted`)
- **Branch naming convention** (e.g., `auto/<number>-<slug>` vs `feat/<number>-<slug>`)
- **Test runner command** (e.g., `npm test`, `pytest`, `godot --headless --script`)
- **Test file conventions** (e.g., `__tests__/*.test.ts`, `*_test.gd`, `*.spec.js`)
- **Lint/typecheck commands** (e.g., `npm run lint && npm run typecheck`, `mypy .`)
- **PR test plan items** (e.g., "App type-checks clean", "Manual smoke test")
- **Commit scope conventions** (e.g., `server`, `app`, `core`, `ui`)
