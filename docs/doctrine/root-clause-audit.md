# Fleet root clause audit

This audit checks operative behavior in the root before and after the prose correction. It records public rules rather than session narrative or machine-private direction. Existing rule IDs and all five floor blocks are retained. The former compressed root measured 21,914 bytes; the corrected root's exact byte count is recorded with validation in the PR.

## Required restorations

| Rule ID | Restored instruction |
| --- | --- |
| `status-block` | Enumerate every in-flight task under `N in flight:` using `<agent/task> — <state> (<target>)`; forbid bare summaries and use `- 🔄 none` when empty. Keep decisions visible until resolved; a “decision” reply invokes the host question UI with context, trade-offs and recommendation. |
| `next-line` | Write one sentence after the four bullets; identify action and owner, stopped limit and restart needed. |
| `branch-assert` | On a mismatch, do not edit and do not stage; re-establish and assert the intended branch. |
| `default-roles` | Every review round uses fresh reviewers; never resume a previous round's reviewer. |
| `restart-triggers` | Never invent a relaunch command or schedule. Verify an accepted task/session identifier; preserve emitted benchmark values. |
| `fable-paced` | The objective is to saturate the week; argue against reinstating a weekly dollar ceiling. |
| `risk-tiered-review` | Every HIGH change outside the covered security/permissions exception, including doctrine, keeps the panel. Keep emitted benchmark values and never hand-type them. |
| `private-advisory-for-exploitable-findings` | List and review existing advisories before creation, stop/reuse on a match, build the description from the vault file, and allow only one 422 retry after relisting. Never test-create. The named script implements commands and is tested with fake `gh`. |
| `ci-watcher-by-default` | Turn on `set_monitor` with `auto_fix: true` where available and always arm one bounded `run_in_background` watcher; recheck final-head gates after settlement. |

## Additional operative details checked

A section-by-section comparison also found details whose explicit wording had been compressed away. The correction restores the following behavior in the root.

| Rule ID | Detail restored or made explicit |
| --- | --- |
| `rule-precedence` | A successful fetch is mandatory; exit 1 means floor drift, exit 0 means a verified comparison, and exit 2 means inability to verify. Unclassified text is default; compare rule tokens rather than headings. Scope belongs to the script alone. |
| `restart-triggers` | Record mode/package at startup, not only at close-out. A dependent first PR does not complete its package. Treat a lower compaction window as a host experiment and include reconstruction cost when measuring savings. |
| `fable-paced` | Prefer the incremental script to a fresh scan; readings can be recorded on any day. Commands prompt without shell placeholders. The optional `meter` alias is not shipped. Reject stale samples, label derived fallback, retain measurement policy and all candidate units. |
| `reference-figures` | Use the transcript lower bound for coordinator plus children; do not substitute exit-only harness totals. Claude-only pricing excludes Codex. |
| `private-advisory-for-exploitable-findings` | An uncertainty decision belongs in the seed as well as status. Failed filing reports the path and “1 finding withheld.” Private fixes cover changelogs, diffs, logs and discussions as well as PR metadata. |
| `long-job-waits-bounded` | Do not wait again on an incident run; give a rerun its own ceiling. TERM alone may leave shutdown stuck. Progress comes from the log, and CI gets no second waker. |

## Preserved behavior across the remaining defaults

| Rule IDs | Behavior checked |
| --- | --- |
| `exec-brief`, `html-dark-by-default` | Open a self-contained outcome-first brief after long delivery; preserve dark styling, delegation instructions and all stated exemptions. |
| `shared-copy-preamble`, `harness-reaps-agent-worktrees` | Shared branch/index/tree state requires isolation; harness retention is not guaranteed, so capture durable acceptance evidence when filing. |
| `skills-from-registry`, `project-genesis` | Install missing requested skills on demand; never hand-copy/push-deploy. New repos establish doctrine before features; existing repos get audit-only unless the owner opts in. |
| `delivery-cadence`, `gated-delivery-authority` | Preserve observable acceptance, reuse, independent reviews, final-commit gates, synchronous protected merge and verified ledger delivery. Authority includes scoped prerequisites and excludes planning/review-only or explicit holds. |
| `in-effect-line`, `model-tiering` | Report real availability and observation outside tests; name remaining adoption owner without a merge gate. Use available model roles and put tier choices in spawning calls/briefs. |
| `review-on-a-stable-head`, `codex-pass` | Freeze reviewed head; combine reports into one push. Keep two full rounds plus one delta and written justification for more. Keep the separate read-only security/permissions/persistence pass and panel fallback. |
| `follow-on-protocol` | Evidence determines blockers and fallbacks; fix/contain acceptance failures, retain scope and retry limits, advance independent work and preserve owner prerequisites and follow-ons. |

## Boundaries and validation

The five floor bodies are compared byte-for-byte, extracting each body between rule tokens; all five match the earlier root. Rule IDs are compared as a set and all 30 IDs in the pre-correction root remain. `machine-local` remains a reserved private machine block; neither it nor private machine direction is added to this public root or audit.

The correction also adds the configured-cap margin requirement to public drift policy and names the advisory implementation script. Historical measurements belong in rationale; they do not become new quota constants. UI-smoke issue #403 remains open for its separately specified model and live-package acceptance; this audit does not claim that a UI delivery has been observed.
