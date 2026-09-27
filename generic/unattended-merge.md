# Gated Merge Authority

## Purpose

Define the delivery gate for delegated implementation in both ordinary and prime-directive runs. The historical skill name `unattended-merge` is retained for existing callers; user presence does not change merge authority. Once the gates pass, the agent merges, verifies delivery and records it without another routine confirmation.

This authority covers PRs created or explicitly taken over for the delegated work. It does not authorize merging unrelated existing PRs. Honor an explicit user hold, required human approval or unavailable permission; these are specific prerequisites, not a general confirm-before-merge convention.

## The Gate — ALL conditions required

A PR within the delegated scope may be merged by the agent ONLY when every condition holds:

1. **`/full-review` completed with a clean verdict covering the final head** — independent review plus Copilot/other posted feedback triage, including general summaries, has run. A skipped or partial review fails the gate. Blocking correctness, security, data-integrity or promised-acceptance defects must be fixed, removed or verified contained. Documented low-impact nonblocking findings may become follow-up issues with evidence and rationale; their size or an issue URL alone does not establish eligibility.
2. **ALL CI checks pass on the final commit** — if a fix or branch update was pushed, verify the new run. A green result on a stale commit fails the gate.
3. **ZERO unresolved review threads** — every thread has a supported fix, false-positive explanation or eligible follow-up disposition, then is resolved. Resolving a conversation does not fix a blocking defect.
4. **Authority and branch protection are satisfied without overrides** — honor explicit user holds and required human approvals; never `--admin`, never bypass rules, never edit protection settings to get a merge through.
5. **The merge is synchronous and verified** — NEVER `gh pr merge --auto` and never GitHub auto-merge. Verify gates 1–4, merge against that checked head, then confirm the PR reports `MERGED` and capture its merge SHA.
6. **A ledger and report entry are mandatory** — immediately record the PR, accepted review, final-head checks and merge SHA in the session ledger. Every self-merged PR MUST appear in the end-of-session report. The final report is a summary of verified deliveries.

**If ANY gate fails: do NOT merge.** Diagnose the failed gate through `/merge-gate` and recover within scope and remaining repair limits. Ask only for a verified owner-reserved prerequisite; otherwise keep handling the work and advance independent authorized slices. Never retry by loosening a gate.

## Merge command

Verify that repository policy permits a synchronous merge before invoking it. If a merge queue is required, report that policy dependency; do not silently enqueue or use `--admin` to bypass it.

```bash
# CHECKED_HEAD is the full head SHA whose review, CI and thread gates just passed.
gh pr merge ${PR_NUM} --squash --delete-branch --match-head-commit "${CHECKED_HEAD}"   # {{CUSTOMIZE: merge strategy per repo convention — squash/merge/rebase}}
# Verify — do not trust the exit code alone:
gh pr view ${PR_NUM} --json state,mergeCommit,mergedAt
```

If the head moved, recheck its review and CI evidence before another merge attempt. After a verified merge, run authorized repo post-merge steps: {{CUSTOMIZE: post-merge steps, or "none"; distinguish routine build/recording from separately reserved deployment, signing or release actions}}.

## Report entry format

Keep one ledger entry per verified merge, summarized in the end-of-session report:

| PR | Outcome | Review | Checks at head | Merge SHA |
|----|---------|--------|----------------|-----------|
| [#45](url) | Retry behavior delivered | Clean, 0 unresolved | all green at `head-sha` | `merge-sha` |

Open PRs retain their exact failed gate in the ledger and status. A ready dependency is merged in order and the dependent PR is then rechecked; merge order alone is not an owner decision.

## CLAUDE.md Snippet

```markdown
**Gated merge authority:** Delegated implementation includes review, merge and ledger
recording in ordinary and prime-directive runs. Once `/full-review` is clean, ALL CI
checks are green on the final commit and ALL review threads have supported resolved
dispositions, merge synchronously and verify `MERGED` and the merge SHA. No repeated
merge confirmation, `gh pr merge --auto`, `--admin` or protection overrides. Honor an
explicit user hold, required human approval or unavailable permission and report the
actual prerequisite. This grant does not cover unrelated existing PRs. Record every
merge in the ledger and end-of-session report.
```

## Integration points

- **Ordinary development:** complete the scoped delivery through merge and ledger, then produce the uniform status and verified seed for a new session under `/session-lifecycle`.
- **Prime-directive runs:** use the same delivery gate, update durable run state, then continue the authorized mission through supported host continuation/compaction. Preserve consumed limits.
- **`/autonomous-dev-flow` and `/tackle-issues`:** merge inline through this gate. An explicit `merge:off` hold leaves reviewed PRs open and recorded; it does not weaken review requirements.
- **`/merge`:** performs the same gates for explicitly selected PRs. A review-only request does not authorize merge.
