# /merge

Merge PRs, verify post-merge version bump, and run post-merge actions (build, deploy, etc.).

## Arguments

- `$ARGUMENTS` - PR numbers, `all`, or flags:
  - `123` or `123 456` — specific PR(s)
  - `all` — all open PRs targeting main
  - {{CUSTOMIZE: Post-merge skip flag — e.g., `--no-build`, `--no-deploy`. Name the flag after the post-merge action.}}
  - {{CUSTOMIZE: Post-merge only flag — e.g., `--build-only`, `--deploy-only`. Runs post-merge actions on current main without merging.}}
  - `--skip-version-check` — don't wait for auto-version CI

## Instructions

### Phase 0: Mandatory Review Gate

**CRITICAL: Every PR MUST be reviewed before merging. No exceptions for "obvious" fixes.**

For each PR to be merged, check if `/full-review` has already been run:

```bash
# Check for existing review comments (agent-review posts a structured review)
gh api repos/${REPO}/issues/${PR_NUM}/comments --jq '[.[] | select(.body | test("Code Review|Review Comments Addressed"))] | length'
```

If no review exists, run `/full-review ${PR_NUM}` **before proceeding to merge**. For multiple PRs, run reviews in parallel (background agents), then merge sequentially after all reviews complete.

{{CUSTOMIZE: Review skip exceptions — e.g., "Pure documentation/skill file changes (.md files) with zero code changes may skip review." Adjust based on your repo's review requirements.}}

### Phase 1: Pre-Merge Preparation

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

If the post-merge-only flag is set, skip to Phase 3.

Parse PR numbers from arguments. For `all`:

```bash
gh pr list --base main --state open --json number,title,headRefName,mergeStateStatus
```

For each PR, pre-check:

```bash
# CI status
gh pr checks ${PR_NUM}

# Merge state
gh pr view ${PR_NUM} --json mergeable,mergeStateStatus
```

Display summary table (no confirmation gate — user invoked the command explicitly):

```markdown
## Merge Queue ({N} PRs)

| # | PR | Title | CI | Merge State |
|---|-----|-------|----|-------------|
| 1 | #123 | feat: add feature | PASS | CLEAN |
```

### Phase 2: Merge Execution

#### Small batch (1-2 PRs): Direct merge

For each PR:

1. **Check CI** — if any checks are pending, poll every 30s up to 3 min. If failed, run `/fix-ci` once and retry.
2. **Check merge state** — if BLOCKED, diagnose:

   | Error Pattern | Action | Max Retries |
   |---|---|---|
   | "not up to date" / "branch is behind" | `gh api repos/${REPO}/pulls/${PR_NUM}/update-branch -X PUT`, wait for CI, retry | 1 |
   | "status check" / "required status" | `/fix-ci`, retry | 1 |
   | "review" / "unresolved threads" | Resolve via GraphQL (see below), retry | 1 |
   | "conflict" / "not mergeable" | Skip, report conflict | 0 |
   | "already merged" | Skip silently | 0 |
   | Rate limit (403/429) | Back off 60s, retry | 2 |
   | Unknown | Log error, skip | 0 |

3. **Resolve review threads** if blocking merge:

   ```python
   # MUST use Python — bash corrupts Base64 thread IDs in GraphQL mutations
   python3 -c "
   import subprocess, json
   result = subprocess.run(['gh', 'api', 'graphql', '-f',
     'query={repository(owner:\"OWNER\",name:\"REPO\"){pullRequest(number:PR_NUM){reviewThreads(first:50){nodes{id,isResolved}}}}}'],
     capture_output=True, text=True)
   data = json.loads(result.stdout)
   for t in [x for x in data['data']['repository']['pullRequest']['reviewThreads']['nodes'] if not x['isResolved']]:
       mutation = 'mutation { resolveReviewThread(input: {threadId: \"' + t['id'] + '\"}) { thread { isResolved } } }'
       subprocess.run(['gh', 'api', 'graphql', '-f', f'query={mutation}'], capture_output=True, text=True)
   "
   ```

4. **Squash merge:**
   ```bash
   # {{CUSTOMIZE: Merge strategy — --squash, --merge, or --rebase. Include --delete-branch if desired.}}
   gh pr merge ${PR_NUM} --squash --delete-branch
   ```

5. **Verify:** `gh pr view ${PR_NUM} --json state -q .state` should be `MERGED`

#### Large batch (3+ PRs): Delegate to /batch-merge

Run `/batch-merge ${PR_NUMS}` — it handles sequential merge with update-branch, CI waiting, Copilot gating, and conflict resolution. After delegation completes, continue to Phase 2b with the list of successfully merged PRs.

### Phase 2b: Version Verification

{{CUSTOMIZE: Version verification — adapt to your repo's version bump mechanism.
Some repos use auto-version CI workflows that bump on every merge to main.
Some use manual version bumps. Some don't version at all.
If your repo has no auto-version, delete this entire phase.}}

After merging, wait for the post-merge CI workflow that bumps versions:

```bash
# Wait 15s for the workflow to trigger
sleep 15

# {{CUSTOMIZE: Auto-version workflow filename}}
WORKFLOW="auto-version.yml"

# Poll for completion (every 15s, max 3 min)
for i in $(seq 1 12); do
  STATUS=$(gh run list --workflow "$WORKFLOW" --branch main --limit 1 --json status,conclusion,headSha --jq '.[0]')
  CONCLUSION=$(echo "$STATUS" | jq -r '.conclusion // empty')
  if [ "$CONCLUSION" = "success" ]; then
    break
  fi
  sleep 15
done
```

Once complete, fetch the new version:

```bash
# {{CUSTOMIZE: Path to version source of truth and how to extract version}}
NEW_VERSION=$(gh api repos/${REPO}/contents/packages/server/package.json --jq '.content' | base64 -d | node -p "JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).version")
echo "Version bumped to: v${NEW_VERSION}"
```

Report the version change. If the workflow doesn't complete in 3 min, warn and continue — never block post-merge actions on version verification.

If `--skip-version-check` is set, skip this phase entirely.

### Phase 3: Post-Merge Actions

**Skip conditions:**
- Post-merge skip flag is set
- No PRs were merged (all skipped/blocked)
- {{CUSTOMIZE: File-path skip logic — e.g., skip rebuild when merged PRs only touch docs/, .github/, etc.}}

{{CUSTOMIZE: Post-merge build/deploy steps. This is where repo-specific actions go.
Replace the placeholder below with your repo's post-merge workflow.

Common patterns:
- Desktop app rebuild (Tauri, Electron)
- Docker image build + push
- Deployment to staging/production
- Documentation rebuild
- Cache invalidation
- Mobile app OTA update

If your repo has no post-merge actions, delete this entire phase
and remove the skip/only flags from the Arguments section.}}

#### Step 3a: Pull latest main

```bash
git checkout main
git pull --ff-only origin main
# If fast-forward fails (divergent from stale cherry-picks/worktrees):
# git reset --hard origin/main
```

Verify local version matches the auto-versioned remote:
```bash
# {{CUSTOMIZE: Local version check command}}
echo "Local version: $(node -p \"require('./packages/server/package.json').version\")"
```

#### Step 3b–N: [Repo-specific build/deploy steps]

_Replace with your repo's post-merge workflow._

### Phase 4: Report

```markdown
## Merge Complete

| PR | Title | Status |
|----|-------|--------|
| #123 | feat: add feature | Merged |
| #456 | fix: resolve crash | Skipped (conflict) |

**Version:** v1.2.3 → v1.2.4
{{CUSTOMIZE: Additional report lines for post-merge actions (e.g., "Desktop app rebuilt", "Deployed to staging")}}
```

## Error Recovery

| Error | Recovery |
|---|---|
| CI failure on PR | Run `/fix-ci`, wait, retry merge |
| Unresolved review threads | Resolve via GraphQL Python script, retry |
| Merge conflict | Skip PR, report to user |
| Version bump timeout | Warn and continue to post-merge actions |
| Post-merge build failure | Report error, suggest manual intervention |
| Divergent local branches | `git reset --hard origin/main` |

## Critical Rules

1. **NEVER merge without /full-review** — every PR must be reviewed before merging. This is a hard gate. Run Phase 0 first.
2. **For 3+ PRs, delegate to /batch-merge** — don't reinvent sequential merge logic
3. **Version verification is informational** — never block post-merge actions on it
3. **GraphQL resolveReviewThread must use Python** — bash corrupts Base64 thread IDs
4. **Never use --admin** — respect branch protections
5. **Idempotent** — safe to re-run; already-merged PRs detected and skipped
6. **No attribution** — Zero Attribution Policy applies to all commits
7. {{CUSTOMIZE: Add repo-specific critical rules}}

## Customization Points

| Token | Default | Description |
|---|---|---|
| Merge strategy | `--squash --delete-branch` | `--squash`, `--merge`, or `--rebase` |
| Auto-version workflow | `auto-version.yml` | Workflow filename, or remove Phase 2b if no auto-version |
| Version source of truth | `package.json` | Path to file containing canonical version |
| Post-merge skip flag | `--no-build` | Flag name to skip post-merge actions |
| Post-merge only flag | `--build-only` | Flag name to run post-merge only (skip merging) |
| Post-merge actions | _(none)_ | Build, deploy, or other post-merge steps |
| Skip logic | _(none)_ | File paths that trigger/skip post-merge actions |
| Review skip exceptions | Pure `.md` doc/skill files | File patterns that may skip `/full-review` |
| Repo-specific rules | _(none)_ | Additional critical rules |
