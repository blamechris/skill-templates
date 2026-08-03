# /full-review

Run a complete review pipeline: agent-review first, then check-pr. The agent-review pass naturally fills the ~4 minute Copilot review delay, so check-pr starts with comments already waiting.

## Arguments

- `$ARGUMENTS` - PR number (optional, defaults to current branch's PR)

## Instructions

### Phase 1: Agent Review

Run the `/agent-review` skill on the PR. This is a deep expert review that:
- Reads CLAUDE.md and the full PR diff
- Reviews against project-specific code quality, architecture, and testing criteria
- Posts a review comment on the PR
- Creates follow-up issues for deferred suggestions
- Reconciles any from-review issues resolved by this PR

**Capture the results:** verdict, findings counts, issues created/closed.

### Phase 2: Check-PR

After agent-review completes, run the `/check-pr` skill on the same PR. By now, Copilot review has typically arrived (~4 min). This skill:
- Waits for Copilot review if still pending (Step 0 polling)
- Processes every review comment (Copilot + human + agent-review findings if inline)
- Fixes, dismisses, or defers each comment with inline replies
- Pushes all fixes and verifies every thread has a reply
- **Resolves every conversation thread via GraphQL** so branch protection's "conversations resolved" gate clears. Replies alone don't do this.
- Cross-references fixes against open from-review issues

**Capture the results:** comments processed, fixes committed, issues created/closed.

### Phase 2.5: Verify CI (Optional)

If check-pr pushed any fix commits in Phase 2, CI needs to pass on the new HEAD before merge. Concurrency groups commonly cancel the in-progress run when fixes are pushed, leaving CI stale.

1. Check if any commits were pushed in Phase 2 (check-pr fixes)
2. If yes, run `/fix-ci` on the same PR
3. Common outcome: retriggering a cancelled run after concurrency cancellation
4. If no commits were pushed, skip this phase (CI is still valid from before)

**Capture the results:** CI status, any action taken (retrigger/fix/escalate).

### Phase 2.6: Fix-Delta Verify

Fix rounds get their own review. If Phase 2 pushed fix commits, adversarially verify the
**fix delta itself** — not just re-check the original diff. The characteristic escaped
defect is in the code written to fix the previous finding, and the test written alongside
a fix is often structurally blind to it (a fixture that cannot produce the failure it
guards; a test asserting only the case where the claim was already true; deletions the
suite never notices).

1. Diff the fix commits alone (`git diff <pre-fix-sha>..HEAD`).
2. Spawn a verifier scoped to that delta's behavior changes, prompted to REFUTE the fixes.
3. Tell the verifier explicitly that **"nothing found" is a valid result** — it must not
   manufacture findings to justify the pass.
4. A real finding loops back through Phase 2 (fix → reply → resolve → re-verify the new
   delta); "nothing found" proceeds to merge.

If Phase 2 pushed no commits, skip (nothing new to verify).

**Capture the results:** verified/skipped, findings looped back (if any).

### Phase 3: Combined Summary

Output a **single combined summary table** covering both phases. This is the PRIMARY output.

```markdown
| PR | Review | Check-PR | CI | Changes | Issues |
|----|--------|----------|----|---------|--------|
| #XX | Verdict (N critical, M suggestions) | P comments → Q fixed | PASS (after retrigger) | brief change 1, change 2 | Created: #A, #B. Closed: #C, #D |
```

**Column guide:**
- **Review:** Verdict + finding counts from agent-review
- **Check-PR:** `N comments → M fixed` (add `, X false pos` / `, Y deferred` if any)
- **CI:** Status from Phase 2.5. `PASS` / `PASS (after retrigger)` / `PASS (after fix)` / `ESCALATED` / `—` (if Phase 2.5 was skipped because no commits were pushed)
- **Changes:** Comma-separated brief descriptions of what changed (2-5 words each, from check-pr fixes)
- **Issues:** Combined from both phases. `Created: #X` for new follow-ups. `Closed: #Y` for resolved issues. Deduplicate (agent-review may create issues that check-pr then closes).

Then below the table:
- Full commit hashes for each fix
- Reasons for any false positives
- URLs for all created/closed issues
- PR ready for re-review: Yes/No

## Execution Notes

- **Sequential, not parallel.** Agent-review MUST complete before check-pr starts. This is by design — the delay lets Copilot review arrive.
- **Same branch.** Both skills operate on the same PR branch. Check-pr may commit fixes on top of the reviewed code.
- **Deduplication.** If agent-review creates a follow-up issue and check-pr's fixes resolve it, close the issue in Phase 2 with a PR cross-reference.
- **Threads resolved before declaring done.** Check-pr's step 6b runs the GraphQL `resolveReviewThread` mutation for every thread. Without it, branch protection blocks merge silently — the user has to click "Resolve conversation" once per thread. If you skip this, full-review is not done; you've handed the user manual cleanup.
- **Attribution.** Follow Zero Attribution Policy throughout — no AI mentions in commits, replies, or issues.

## Customization Points

This skill composes agent-review and check-pr. Customize those skills individually per the notes in each template. The only full-review-specific customization is the summary table format, which can be adapted per repo.
