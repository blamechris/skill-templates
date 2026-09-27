# Merge Gate Recovery

## Purpose

Recover a blocked merge using current evidence and supported tools. The agent owns review, remediation and merge for delegated implementation in both ordinary and prime-directive runs. A failed merge is a reason to inspect the failed gate, not automatically a task for the user.

## Recovery procedure

1. **Re-read the gate at the CURRENT head.** Query the PR's `headRefOid`, `mergeable`, `mergeStateStatus`, checks and review state after every push or base update. A stale `BLOCKED` or `CLEAN` reading is not evidence about the new head. `UNKNOWN` is an unresolved state; use the host's supported status/continuation mechanism to obtain a fresh result rather than inventing a blocker or bypassing a host restriction.
2. **Identify the actual failed requirement.** Inspect required checks, review findings and unresolved threads, required approvals, branch freshness/conflicts, permissions and any explicit user hold. Resolve contradictory readings from their underlying evidence. Do not guess that every block is an unresolved thread or claim that only humans can resolve threads.
3. **Recover within delegated authority and remaining repair limits.** Use `/fix-ci` for a verified CI failure and `/check-pr` for findings. Resolve only threads with a supported current-head disposition; review summaries without threads still count. Update an owned PR branch or resolve its conflicts where authorized, preserve unrelated work, and repeat affected review/CI gates after changes. Dependencies between authorized PRs determine merge order; merge the ready prerequisite, then recheck its dependent PR.
4. **Recheck every merge gate before retrying.** Require clean `/full-review` evidence covering the final head, ALL CI checks green on that commit, ALL review threads resolved with evidence, and repository protection satisfied. Never use `--admin`, `gh pr merge --auto`, GitHub auto-merge or a protection override. Merge synchronously and verify `MERGED`; update the ledger with the PR and merge SHA.
5. **Escalate only the genuine prerequisite.** If a required human approval, missing permission, explicit hold, exhausted allowance or unsupported host operation prevents progress, report that exact requirement and evidence. Ask the owner only for an action reserved to them, state what the agent will resume afterward, and continue independent authorized work. An unresolved requirement stays blocked; a follow-up issue does not waive it.

## CLAUDE.md Snippet

```markdown
**Merge recovery:** For delegated implementation in ordinary and prime-directive runs,
the agent diagnoses and recovers a failed merge using current-head evidence and supported
tools. Use `/merge-gate`; do not hand unresolved review threads to the owner by default.
Clean `/full-review`, final-commit CI, supported thread dispositions and repository
protection remain mandatory. Never use `--admin`, `gh pr merge --auto` or protection
overrides. Ask only for a verified owner-reserved approval/access action or explicit hold;
retain responsibility for the merge when that prerequisite is supplied.
```

## Report a genuine block

> Merge blocked: #N at `<head SHA>` requires `<verified requirement>`.
> Owner action: `<only the reserved action, or none>`.
> Agent next: `<recheck/resume action after the prerequisite; independent work meanwhile>`.

Report host or budget limits as limits, not as a product decision. Follow the global status block and next-action convention.

## Customization

- Record repository-specific protection requirements, merge strategy and authorized recovery tools.
- Preserve explicit user holds and genuinely required external approvals. Ordinary user presence is not a merge hold.
