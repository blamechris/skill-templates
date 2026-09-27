# Development cadence: normal and prime-directive

Owner-approved specification, September 26, 2026. This supersedes the old convention
that interactive development must wait for a separate merge request. It does not
authorize unrelated work, turn a planning/review request into implementation, remove
an explicit merge hold, or bypass a required external approval.

## Shared delivery cycle

1. Scope the feature/work package and observable acceptance; settle necessary design decisions.
2. Inspect existing code and analogous flows for shared helpers/classes and reusable logic.
   Apply SOLID/DRY proportionally; do not invent abstractions just to satisfy a ritual.
3. Record a proportional implementation plan, including validation and reuse decisions.
4. Delegate the plan to the suitable available implementation model. The coordinator retains
   responsibility for review, integration and delivery. An unavailable capability is reported,
   never represented as an executed worker or independent review.
5. Run `/full-review`: posted Copilot feedback, including general summaries, plus independent
   subagent review. Follow the repository's declared policy when Copilot is unavailable.
6. Triage by impact and evidence. Fix, remove or verify containment of blocking correctness,
   security, data-integrity and acceptance defects. File justified low-impact nonblocking
   findings as issues without requiring another CI cycle solely for optional cleanup.
7. Verify review dispositions, required resolved threads, CI on the final commit and repository
   requirements; merge synchronously. In-scope prerequisite PRs determine ordering, not a new
   owner decision. Refresh and verify dependent PRs after their base changes. Never use an
   override, `--admin` or `--auto` to evade this sequence.
8. Verify `MERGED` into the intended base. Record outcome, PR, merge SHA, validation and deferred
   issues in the ledger. A green open PR is reviewed work; it is not a verified merge.

Routine gated merge is delegated in both modes. Ask the owner only for an actual reserved
decision, approval, access or QA action. Name the failed requirement when execution is blocked;
continue independent authorized work within the original limits.

## The mode controls the next cycle

| Mode | Selection | After delivery |
| --- | --- | --- |
| Normal | Default for a bounded development task | Finish the selected package, write and verify the external seed, provide concise status, and instruct the user to start a fresh session from its absolute path. Leave other backlog features for later. |
| Prime-directive | Explicit `/prime-directive` or an authorized continuing autonomous mission | Checkpoint the same ledger state and continue the next item in the selected mission/backlog. Use supported host continuation/auto-compaction. |

Record and preserve the mode. Watching the app does not switch it. A package may include
several dependent PRs; the first merge is not necessarily its end. A prime run ends at
acceptance, an explicit user pause, an exhausted configured limit, or an actual dependency
or host limit preventing further authorized work. Compaction and a wave boundary alone do
not end it. Restore run identity, acceptance, authority, attempts and consumed limits after
compaction; a fresh context does not reset them.

An actual successor must be accepted before a report claims it is running. A seed records
continuity; it does not start execution. Changing the host's compaction window is a separate
measured experiment, not an arbitrary token-based instruction to stop work.

## Reporting contract

Lead with the usable outcome. Keep detailed findings, agent histories and checks in a linked
ledger/report. End with the existing four-slot status and one Next sentence:

```text
Implemented <outcome> and verified it on main.

Status:
- ✅ <verified delivery; PR and ledger reference>
- 🔄 <each actual running task, or none>
- ⛔ <specific unmet requirement, or none>
- 🔶 DECISION: <actual owner decision, or none>

Next: <who acts next and why; normal mode includes the absolute verified seed path>
```

Do not label a routine merge "blocked on owner" or write "DECISION: none" while silently
requiring an owner choice. In prime mode the Next sentence normally names the continuing
agent work and says that no user action is needed.

## Validation sequence

Use the [acceptance scenarios](outcome-continuation-trial.md) and
[runnable local fixture](../tests/cadence-fixture/README.md). Start with paired fresh normal
and prime runs on the same fixture and installed instruction revision. Freeze source, effective
instruction hashes, model, host, permissions and limits. Keep evaluator expectations outside
the opening task and preserve the first handoff before any coaching.

Local Git trials test ownership, real local merge behavior, ledger and mode boundaries. They
do not establish GitHub/Copilot integration. Follow with a GitHub-backed, explicitly scoped
feature run using the same rules; record current-head CI, posted Copilot findings, independent
review, merge and ledger evidence. Then exercise an explicit merge hold and a blocking finding
alongside a nonblocking follow-up, followed by the continuation/prerequisite scenarios.

Do not infer broad adoption readiness from harness tests or a passing local adapter. Keep the
workflow PR draft until its declared behavioral acceptance is observed, rather than asking
the owner to merge an untested workflow change merely because static CI is green.
