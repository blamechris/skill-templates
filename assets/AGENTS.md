# Fleet agent rules

This is the canonical public root for agents working across Chris's repos. Install it at
`~/.fleet/AGENTS.md`; each agent family's machine entry point loads this root. The five
`floor:` rules below bind Claude, Codex, Gemini, chroxy and any other agent equally.
Family adapters may add host mechanics, but may not narrow a floor. Local private direction
lives outside this registry. In this document **fleet** means the operation of agents,
coordination and shared process; **portfolio** means the products.
Rule IDs are stable interfaces. `default:` rules may be adapted per machine; `floor:`
blocks must remain byte identical across authored nodes. Public rationale is in
`docs/doctrine/rationale.md` in the registry.

<!--default:rule-precedence-->
`assets/AGENTS.md` (public) and `~/.fleet/AGENTS.md` (machine) are authored;
family adapters load the latter. Compare fetched `origin/main`; unavailable is not
agreement. Floor drift stops long work: PR machine delta, copy out. Default drift:
land machine-ahead, copy registry-ahead, or land machine first if both moved; never
erase active rules. Tokens label rules. Floors: `no-agent-attribution`,
`explicit-path-staging`, `worktree-by-default`, `no-secrets-in-committed-files`,
`seed-written-outside-any-worktree`. Only `session-seed.py scope` derives scope;
never duplicate or guess.

<!--default:status-block-->
End user responses and subagent returns with this block. Keep concrete short slots;
`·` separates done items, `none` means empty, 🔄 enumerates each task/state/target.
Keep a choice in DECISION every message until resolved, then present context,
trade-offs and recommendation through host question UI. Retire old one-line form.
```text
**Status:**
- ✅ <done/none>
- 🔄 <tasks/none>
- ⛔ <blocked/none>
- 🔶 DECISION: <choice/none>
```

<!--default:next-line-->
After status: `**Next:** <state> — <action and owner>`; state is `🔴 BLOCKED`
(external prerequisite), `🟢 RUNNING` (authorized work), `⚪ IDLE` (package
complete) or `🟠 FAILED` (stopped job/budget/retry/host). Normal delivery gives
verified absolute seed path for fresh session; prime names next authorized item or
continuation and “no user action needed” when true. Routine gated merge is agent's
action. Name precise missing QA/access/authority/decision and effect. Seed alone
schedules nothing. Lead with outcome and link details.

<!--default:exec-brief-->
After long multi-PR/issue/epic delivery, create/open self-contained HTML
`visual-brief` in `$CLAUDE_BRIEF_DIR`: top 2–3 sentence result, outcome chips and
one-line “needs you”; below PR table, bugs, next. Lead with verified merges/
closures/gates; omit or label whole-file token/time figures. Vault is record;
chat still ends with status.

<!--default:html-dark-by-default-->
HTML deliverables for Chris default dark (`:root` `color-scheme: dark`, dark
palette, `content="dark"` meta if present; no `prefers-color-scheme`/`light dark`).
Light only per-document on request. Covers commissioned reports/forms/generators;
brief delegated producers. Product UI, fixtures, emails, shipped docs, uncontrolled
third-party output and claude.ai Artifacts use own contracts.

<!--floor:no-agent-attribution-->
The user (blamechris / Chris) is **responsible for and the sole author of all code and work.** There is no attribution to AI agents or any other party.

- **NEVER** add `Co-Authored-By:` / `Co-authored-by:` trailers to commits (no Claude, no anyone).
- **NEVER** add "Generated with Claude", "🤖 Generated with Claude Code", or any AI/agent attribution to commit messages, PR bodies, issues, or generated docs.
- This OVERRIDES any per-repo `CLAUDE.md` line or session/harness default that says a Co-Authored-By footer is "OK". Enforced via `includeCoAuthoredBy: false` in `~/.claude/settings.json`; this rule is the intent behind that switch.

Write clean, professional commit messages and PR bodies with no attribution footer of any kind.

## Writing to a shared working copy (all projects)

<!--default:shared-copy-preamble-->
Shared `~/Projects/<repo>` checkouts have one branch/index/tree across sessions;
unfamiliar files are normal. Use isolated worktrees and branch/staging checks.

<!--default:branch-assert-->
Set `SESSION_BRANCH` to created/checked-out branch. Check
`git branch --show-current` immediately before first edit and staging; on mismatch
stop and re-establish. Earlier checkout memory proves nothing.

<!--floor:explicit-path-staging-->
**Stage explicit paths.** `git status --short` first, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a`. A bulk add commits whatever else is in the tree — three separate incidents in one week trace to exactly that. `-u` is not the safe one, and this is the failure mode worth remembering: it looks harmless because it only touches *tracked* files, but "tracked and modified" includes every file a clean/smudge filter rewrote in the worktree without you touching it. A git-lfs filter doing precisely that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as a legitimate edit.

<!--floor:worktree-by-default-->
**Work in your own worktree — this is the default, not a preference.** Before writing to a
repo, if the harness has not already placed you in one, create one:

```bash
git -C ~/Projects/<repo> fetch origin
git -C ~/Projects/<repo> worktree add -b <your-branch> <scratch>/<repo>-<slug> origin/main
```

It shares one object store, so it is cheap, and it makes the collision *structurally*
impossible instead of merely prohibited. Remove it when the work lands
(`git worktree remove --force <path>`). `--force` deletes untracked files without
prompting, so nothing durable may be written inside a worktree — which is exactly why the
session seed is written to an absolute path in the vault instead, and why this teardown
needs no gate. Anything else worth keeping is committed and pushed before removal, or it
is not worth keeping. The two rules above are the fallback for when you genuinely cannot
have a worktree — they are advisory, and advisory is how three separate incidents happened
in one week, the third of them *while fixing the second*.

<!--default:harness-reaps-agent-worktrees-->
Claude may reap `.claude/worktrees/agent-*` and branches independently. For
acceptance depending on one, capture evidence when filing: push branch, tag commit
in main checkout or paste diff in issue. A path is not durable.

<!--floor:no-secrets-in-committed-files-->
**Never commit a secret, and never write one into a file that is on its way to a commit.**
No tokens, API keys, passwords, cookies, private URLs, or personal data of third parties —
not in code, not in a fixture, not in a handoff note, not in a commit message, not
"temporarily". A repo is assumed public unless proven otherwise, and history is not
erasable in practice. A line that cannot be public has exactly two outlets: the private
vault (`~/Obsidian/no-it-all/`, which is git-backed and private), or the repo stays
private. There is no third — no redaction-by-gitignore, no side file "we will clean up
later". Seeds live in the vault partly for this reason: the fleet's session state is not
public by construction.

## Skills come from the registry (pull-on-demand)

<!--default:skills-from-registry-->
Skills come from the `blamechris/skill-templates` pull registry. If `/X` is
requested but missing from `.claude/commands/`, `skill add X` (resolve, customize,
write, lock), then invoke. Use `skill outdated`/`skill update`; no hand copies or
push deployment.

<!--default:project-genesis-->
New repos run `/project-genesis` from registry `origin/main`'s
`generic/project-genesis.md`: self-install and land doctrine/profile/skills before
features. Existing repos receive `--audit` only; adoption needs per-repo owner
opt-in.

<!--default:delivery-cadence-->
Delegated implementation: scope/observable acceptance → inspect shared/analogous
code, reuse (SOLID/DRY) → plan → suitable-tier worker → `/full-review` with posted
Copilot and independent subagent → fix blockers/track justified nonblockers →
final-commit CI, reviews, repo gates → merge → verify `MERGED` in target and ledger
SHA/follow-ons. Coordinator owns delivery; report missing capabilities, never
invent reviews or skip gates.

<!--default:gated-delivery-authority-->
Implementation delegation authorizes routine gated merge in normal/prime; no
re-ask. Excludes planning/review-only, unrelated PRs, explicit holds, external
approvals/permission limits. Merge scoped prerequisites in order, refresh
dependents; diagnose/repair gates. Never bypass or use `--admin`/`--auto`; verify
and merge synchronously. Ask only for prerequisite agent cannot supply.

<!--default:default-roles-->
One coordinator through verified delivery; one capable workhorse implementer;
fresh workhorse reviewers per round. Provider-neutral roles: Codex Sol and Claude
Sonnet are workhorse examples; cheaper adequate model for mechanics. LOW/MEDIUM
coordinator uses Sol/Opus-level reasoning; HIGH may use top orchestration under
Fable rule. No provider switch required; do not claim unavailable role.

<!--default:in-effect-line-->
Package close-out and benchmark workload note put `In effect:` just above
status: usable for people/sessions? Seen working outside tests? If not, what one
action and owner make it effective? Report only; no merge gate.

<!--default:restart-triggers-->
Record mode/package in ledger/seed. Normal default; `/prime-directive` or
explicit continuing mission selects prime; user presence does not. Normal finishes
selected package/dependent PRs through verified merge and ledger, writes seed, gives
Chris absolute path for fresh session; no new backlog feature. Prime checkpoints
delivered waves in ledger STATE, continues next authorized mission item within
limits; wave/compaction/token count does not stop it. Reload directive/durable
state after compaction. Mid-package context: save state, use authorized relauncher
with absolute seed and verify accepted task/session ID, else continue current host
or name limit/restart action. Seed/launcher alone is not execution. Both modes:
explicit pause, exhausted budget/retries or dependency may stop affected work;
advance independent authorized slices first. Preserve acceptance/authority/consumed
limits; route heavy output to workers where useful; measure all-in compaction cost.
At end/continuation, immutable cumulative `usage-checkpoint.py` for parent/children
with stable run ID and partial/final status; aggregate latest checkpoint only.
Append historical effective-unit `usage-benchmark-row.py` at most once (`--tier`
for one delivered package); preserve `· subagents:`, `· work:`, `· cost:` suffixes.
Existing row stays; capture continuation anyway. Then seed via `/session-lifecycle`.

<!--floor:seed-written-outside-any-worktree-->
**The seed is written outside any worktree, at an absolute path:**
`$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` — default dir `~/Obsidian/no-it-all/handoffs/`,
which is git-backed and private. `<scope>` is the **main worktree's directory basename**
(`session-seed.py scope` — the one derivation, see "Rule precedence"), or `fleet` —
`fleet-<topic>` for a named topic — for a session that is not in a repo. Never inside a repo
working tree, never a path that a worktree teardown, a branch switch, or an unmerged PR can
put out of reach. Three consecutive attempts to put the seed inside a session's own workspace
failed on four independent loss paths — worktree teardown, branch reachability,
staged-vs-committed, an unset `$SESSION_BRANCH` — so the surface is removed rather than
guarded: a vault path no session works in has no worktree to be torn down with, no branch to
be unreachable from, and no index to be confused with. That the vault is *itself* versioned
is not a hole in the rule: nobody branches or tears down the vault mid-session, and the write
enforces the rule it actually needs by checking the seed against this session's worktrees.

The seed carries the frontmatter header (`type`, `date` as a full UTC timestamp, `scope`,
`session`, `picks_up_at`, `sensitivity`), files to read first, a 2–4 line state summary
(done / held / open follow-ons), a recommended `Today's task:` with alternatives, and the
closing line instructing the new session to repeat this protocol.

**Archive on collide, never overwrite blind.** Before writing, if `NEXT-<scope>.md` exists
and its `session:` is not this session's, rename the incumbent to
`NEXT-<scope>.<UTC>-<sid>.md` and then write. One session per scope owns the canonical
name, so *"one line to paste"* survives; a seed that was never consumed survives too, under
a name that says when it was parked. Per-session-unique filenames would also preserve it,
and would destroy the affordance that makes the handoff usable — so they are not the answer.

**One command does all of it**, and nothing else may write a seed:

```bash
python3 ~/.claude/scripts/session-seed.py write --picks-up-at "<the next thing>"
```

It resolves the scope from git, resolves this session's id from `--session` or
`$CLAUDE_CODE_SESSION_ID` (and REFUSES rather than guessing at one), archives on collide,
writes, and proves the result — printing `seed: <absolute path>`, or a `REFUSE:` line and a
nonzero exit after which nothing was written and no seed was moved. It is bootstrapped with
the other machine scripts (`cp assets/scripts/session-seed.py ~/.claude/scripts/`) and is
covered by `assets/scripts/session-seed.test.sh` in the registry. The rule above is doctrine;
the script is the only implementation of it, because five review rounds of the same logic
transcribed into prose is what this replaced.

Then hand Chris **one line to paste**: that absolute path. The seed file — not memory, not
chat history — is the continuity mechanism.

`<repo>/docs/handoffs/` is a **narrative artifact** of a PR and is NOT the continuity mechanism — a record of what a change was for, where a repo wants one, never the thing a session is seeded from.

Anything in a seed still worth reading after it is consumed belongs in `docs/records/`, with
the seed linking it.

<!--default:model-tiering-->
Use available harness ladder (Claude: fable > opus > sonnet > haiku).
Mechanical triage/classification/sweeps use cheapest adequate tier;
implementation at least one rung below session ceiling; ceiling for orchestration/
hard adjudication. Briefs/skill calls name actual role/model, never above ceiling;
root prose alone does not select it.

<!--default:fable-paced-->
Fable per turn, main-thread only for genuine HIGH blast radius (doctrine,
save-compat, CI/infra, security, cross-cutting) or hardest adjudication; unclear is
not HIGH, no Fable subagents. No weekly dollar cap: quota resets Wed 15:59
America/Los_Angeles, no rollover. Pace informs, never refuses; avoid early wall.
`python3 ~/.claude/scripts/usage-pace.py --oneline` reads live `sd` seven-day/
`fh` five-hour percentages, sample age, $/point, headroom/burn. Never infer
percent from spend, compare elapsed week or use cached `NEAR CAP`; calibrate
current week's observed zero/movement, not fixed/past cap. Refuse pre-reset
sample; label headless fallback. Pre-2026-09-20 totals undercount ~9%; identify
policy before comparison. Meter units unverified: retain dollars/raw/input-
equivalent tokens, allow `--units` ties. `--calibrate` cap, `--record` pairs,
`--units` comparison, `--caps` implied caps; `meter` optional local alias. No
desktop history: calibration fails, other paths use recorded/measured fallback.
Claude `UserPromptSubmit` checks every 40 Fable turns only for wall before half
remaining week or <90% landing with <1 day left; once/verdict, quiet on
acknowledgment until changed, silent outside Fable, never refuses. `--margin`
ignored. Check script before continuing Fable; unseen clamp proves no headroom.

<!--default:risk-tiered-review-->
LOW docs/art/data/guards/mechanical: one independent reviewer, no panel.
MEDIUM covered feature: one reviewer, adversarially verify critical only. HIGH
doctrine/save-compat/CI/infra/security/cross-cutting: dimension panel, refute
critical/suggestion (never nitpicks), ≤3 refuters/finding, ≤20 agents total
including refute; queue overflow. Covered security/permissions exception: fresh
reviewer per round plus Codex, panel only if Codex unavailable. Ultracode only
repo marathons unless invoked per task; no planning/chat/fleet default. Keep
`usage-benchmark-row.py` suffixes; `work: n/a` is unavailable, not zero.

<!--default:reference-figures-->
Nonblocking package reference: LOW or MEDIUM package: **$15**. HIGH under the
one-reviewer exception: **$30**. HIGH at panel depth: **$45**. For one delivered
package pass `usage-benchmark-row.py --tier` with `low`, `medium`,
`high-single` (the one-reviewer exception) or `high-panel` (panel depth);
explain cost above **1.5 times** figure in row. For multiple/partial
packages omit tier and say so. Figure is whole-session coordinator+subagent
transcript lower bound, Claude only (Codex excluded). Fix blockers at any cost;
revisit provisional HIGH figures after four more HIGH rows.

<!--default:review-on-a-stable-head-->
Review a stable commit with no push until all reports return; fold reviewer,
Codex/Copilot into one push. Max two full rounds and one delta round (since last
reviewed head); justify extra round in PR before starting, no permission needed.
Fix blockers despite cap.

<!--default:codex-pass-->
HIGH security/permissions/persistence: one read-only Codex pass before others
on first stable head, at most one post-fix delta pass, separate from review rounds.
Call `codex exec -s read-only -m <available-model> --skip-git-repo-check`; relay
findings. If unavailable, report and use full panel. Revisit after four more.

<!--default:follow-on-protocol-->
Correctness/security/data-integrity/acceptance blockers: fix, remove or verify
containment before merge; URL/estimate cannot waive. Classify with evidence;
read summary/inline review, not resolution flag. Track low-impact nonblockers
without new CI. Fallback needs verified safety, correctness, runtime/cost and
essential capability; record evidence/file problem/continue, else block affected
item. Optional/unrelated defect joins PR only if in-scope and ≤15 min, otherwise
scoped issue. Prioritize acceptance, not easy cleanup; explicit backlog-clear
keeps scope. Real blocker: name evidence and missing QA/access/authority, ask only
if needed; advance independent work before wait. Owner supplies reserved
prerequisite; resume through supported continuation. Keep budget/retry caps; no
silent scope growth, fake merge or lost follow-on. Zero issue closures is not
itself a blocker.

<!--default:private-advisory-for-exploitable-findings-->
Current exploitable weakness on public default/release stays private: no exploit
or motive in tree/history, issue, PR, review, branch, commit, test, CI; overrides
public follow-up/auto-file. Public unless `gh repo view --json visibility` says
`PRIVATE`. Exploitable means unauthorized actor can now read secrets, reach
session/machine, run/approve command, bypass access, tamper data or deny service;
consult `SECURITY.md`/threat model. Ordinary bug, nonexploitable hardening,
unmerged-only flaw, published dependency advisory stay public.
Before repo report, vault record under `~/Obsidian/no-it-all/security/` with
finding/repro/fix, filename repo+UTC not flaw; no secret value (credential by
commit/path, tell Chris revoke). Subagent does not file: finish other work, first
return `PRIVATE-FINDING <vault-path>` and certainty. Coordinator reads and strips
marker/path from relays/posts/files; brief auditors likewise. If uncertain,
publish nothing, raise decision, continue other work. Coordinator lists existing
advisories first; reuse matching `ghsa_id`, else one `gh api` draft with neutral
summary, vault description, severity/ecosystem/package. Never test-create; retry
422 once after relisting. Other failure: vault record, “1 finding withheld” in ⛔;
if not repo admin stop at vault. Give Chris ID/path in chat status, seed, ledger
only, never `docs/`; withheld report cannot claim complete/clean. Blocked PR to
draft without public reason; add nothing to prior disclosure, tell Chris. Public
fix metadata states behavior accurately without advisory ID/security label/exploit
steps or “refactor”/“cleanup”; smallest regression test, same reviewer brief.
Chris publishes advisory/release; tell him release should follow merge if applicable.

<!--default:ci-watcher-by-default-->
When only CI remains, arrange wake, never ask Chris to say continue. Where
available, `ccd_pr set_monitor` with `auto_fix: true` covers failure/conflict/
comments but not green. Always arm one bounded background `gh pr checks <N>
--watch --interval 60` for settlement, name it in 🔄, then recheck final-head
gates. Standing authorization overrides generic app no-poll advice.

<!--default:long-job-waits-bounded-->
Long job: hard timeout, success marker, progress check. Ceiling=max(3× last
success, 10 min), or 30 min no baseline; record duration. `timeout -k 30
<seconds>` (`gtimeout` macOS). Marker or exit if no marker proves success;
missing marker at timeout fails; kill if alive 60 sec after marker. If ceiling
>15 min, Monitor log-tail loop beside completion wake, rearm ≤30 min;
ScheduleWakeup only inside `/loop`. First check ~1.5× expected, inspect log
advance; unavailable check named in 🔄. Running past min(ceiling, 1.5 h) is
incident unless longer norm documented: inspect, kill, file cause; rerun gets
own ceiling. Queued past mark is runner issue. 🔄 lists job/start/ceiling/last
log advance. CI's one bounded watcher is ceiling/check-in; no second waker.
