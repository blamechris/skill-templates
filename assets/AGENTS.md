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
`assets/AGENTS.md` and `~/.fleet/AGENTS.md` are authored public and machine
nodes. Family adapters load the machine root. Neither generates the other;
there is no push deployment. Compare freshly fetched registry `origin/main`;
an unavailable or stale copy is not agreement.

Classify each rule with `<!--floor:id-->` or `<!--default:id-->` above its text.
There are exactly five floors: `no-agent-attribution`,
`explicit-path-staging`, `worktree-by-default`, `no-secrets-in-committed-files`,
and `seed-written-outside-any-worktree`. Floors must be identical on authored nodes and in loaded family rules.
Other rules and unclassified lines are machine-adaptable defaults. Compare tokens, not headings.

Resolve differences without erasing active rules:

1. A floor difference stops long work. Land the machine's delta through a
   registry PR, then copy out once. Never reconcile a floor by deleting it.
2. For a machine-ahead public default, land the delta in the registry. For a
   registry-ahead default, copy out. If both moved, land the machine's public
   delta first, then copy out once. Never apply blanket “registry wins.”
3. The reserved `machine-local` block is private. Preserve it on the machine;
   exclude it from public drift counts and instructions to land content in the
   registry. Report it as INFO: “private, not for the registry.”

`fleet-check.py` requires a successful fetch. It exits 1 for floor drift, 0 for
a verified comparison reporting public default direction, and 2 when inputs or
a full instruction load cannot be verified. An incomplete check is not agreement.
The Codex size check includes file separators and reserves at least 2,048 bytes
under the configured cap for each checked chain.

Only `session-seed.py scope` derives scope. Ask the script rather than duplicating
its git logic or guessing from the current directory or origin URL:

```bash
python3 ~/.claude/scripts/session-seed.py scope
```

Never add a second derivation to rules, skills or snippets.

<!--default:status-block-->
End user responses and subagent returns with this status block and the `Next`
line. Use the four slots in order, with `none` when empty:

```text
**Status:**
- ✅ <done this turn>
- 🔄 <in flight, enumerated below, or none>
- ⛔ <blocked, with the prerequisite, or none>
- 🔶 DECISION: <pending user decision, or none>
```

Use short concrete slots naming PRs, issues, runs, tasks or people; separate
completed outcomes with `·`. The 🔄 slot enumerates every agent or task
still in flight under `N in flight:`, with one indented sub-bullet each in the
format `<agent/task> — <state> (<target>)`:

```text
- 🔄 2 in flight:
  - bug-hunt — running (auth module)
  - agent-review — done, merging results (PR #53)
```

Bare summaries such as “agents working” or “3 tasks in flight” are forbidden
without the enumeration. When nothing is in flight, write `- 🔄 none`.
Keep a choice waiting on Chris in DECISION every message until resolved. When
Chris replies “decision” or names a pending choice, immediately present it through
the host question UI with context, trade-offs and a recommendation. Keep the block a status without recap padding; the old one-line format is retired.

<!--default:next-line-->
After the four bullets, add one final sentence: `**Next:** <state> — <one task and executor>`. Both `Next` and the seed's `picks_up_at` name exactly one imperative task with `(agent name)` or `OWNER: name`; alternatives belong only in the seed body, never as candidates in `Next`. Use `🟢 RUNNING` for authorized work actually continuing or an accepted continuation, `⚪ IDLE` only when nothing waits on anyone, `🔴 BLOCKED` whenever an owner action, external prerequisite or non-`none` DECISION remains, and `🟠 FAILED` for a stopped job, budget, retry or host limit. Before writing a seed with a choice, use `/decide`: pick and record an authorized reversible choice; proactively present an owner-reserved choice through the host question UI with trade-offs, a recommendation and a default before writing. Keep it in DECISION with `recommend:` and `default:` until answered; its default records the recommended plan only and never authorizes reserved execution without an answer. Continue independent authorized work while that task stays blocked. Normal delivery gives Chris a verified absolute seed path for a fresh session; prime names the next authorized task or accepted continuation, with “no user action needed” when true. Routine gated merge is the agent's action. Name missing QA, access, authority or a decision and what it unblocks; for a reached limit, name the limit and restart needed. A saved seed schedules nothing. Lead the message with the usable outcome and link details.

<!--default:exec-brief-->
After long multi-PR/issue, epic or marathon delivery, use the `visual-brief` skill
to create and open a self-contained HTML report in `$CLAUDE_BRIEF_DIR`.
Begin with a two- or three-sentence result, outcome chips and a one-line “needs
you” callout when Chris has a prerequisite. Below that, give the per-PR table,
bugs caught and next work. Lead with verified merges, closures and gates passed.
Omit misleading whole-file token or time figures, or label their actual scope.
The vault is the record; the chat ends with status and `Next`, linking the brief.

<!--default:html-dark-by-default-->
HTML deliverables written or commissioned for Chris default to dark styling.
Put `color-scheme: dark` on `:root`, ship a dark palette and use `content="dark"`
in the color-scheme meta tag if present. Add no `prefers-color-scheme` switch or
`light dark` declaration. Light styling requires a per-document request.

This covers reports, smoke or review records, QA forms and task-specific
generators. Put the instruction in delegated producers' briefs or generators. Product UI,
fixtures, emails, shipped documentation, uncontrolled third-party output and
claude.ai Artifacts follow their own contracts.

<!--floor:no-agent-attribution-->
The user (blamechris / Chris) is **responsible for and the sole author of all code and work.** There is no attribution to AI agents or any other party.

- **NEVER** add `Co-Authored-By:` / `Co-authored-by:` trailers to commits (no Claude, no anyone).
- **NEVER** add "Generated with Claude", "🤖 Generated with Claude Code", or any AI/agent attribution to commit messages, PR bodies, issues, or generated docs.
- This OVERRIDES any per-repo `CLAUDE.md` line or session/harness default that says a Co-Authored-By footer is "OK". Enforced via `includeCoAuthoredBy: false` in `~/.claude/settings.json`; this rule is the intent behind that switch.

Write clean, professional commit messages and PR bodies with no attribution footer of any kind.

## Writing to a shared working copy (all projects)

<!--default:shared-copy-preamble-->
Shared `~/Projects/<repo>` checkouts have one branch, index and working tree
across sessions. Unfamiliar files are normal. Use isolated worktrees and branch/staging checks;
the checks still apply when a worktree is unavailable.

<!--default:branch-assert-->
Record the created or checked-out branch as `SESSION_BRANCH`. Compare
`git branch --show-current` with it immediately before the first edit and again
immediately before staging. An earlier checkout proves nothing about current
HEAD. On a branch mismatch, stop: do not edit and do not stage. Re-establish the
intended branch and assert it again before continuing.

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
Claude may independently reap `.claude/worktrees/agent-*` directories and
their branches. The harness store is distinct from agent-created scratch worktrees. When an issue's acceptance depends on a retained harness
worktree, capture evidence at filing time: push its branch, tag the commit in
the main checkout or paste the diff into the issue. A path alone is not durable evidence.

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
Skills install on demand from the `blamechris/skill-templates` pull registry.
If requested `/X` is missing from `.claude/commands/`, first run `skill add X`
to resolve, customize, write and lock it, then invoke `/X`. Use `skill outdated` and `skill update`; never hand-copy or push-deploy skills.

<!--default:project-genesis-->
New repositories start with `/project-genesis` from the registry's
`origin/main` copy of `generic/project-genesis.md` until it installs itself.
Land doctrine files, the skill profile and skills before feature code. Existing
repos receive `--audit` only, which reports conformance and fixes nothing.
Adoption requires per-repo owner opt-in.

<!--default:delivery-cadence-->
For delegated implementation, complete this proportional delivery cycle:

1. Establish scope, design and observable acceptance.
2. Inspect shared code and analogous flows; apply SOLID and DRY, reusing logic
   before adding another implementation.
3. Record a plan and delegate to the suitable available implementation model
   under the tiering policy.
4. Run `/full-review`, including posted Copilot feedback and an independent
   subagent review at the required risk depth.
5. Fix blockers and record justified nonblocking follow-ups.
6. Verify final-commit CI, review dispositions and repository requirements,
   then merge through those gates.
7. Verify `MERGED` into the target branch and ledger the SHA and remaining issues.

The coordinator owns delivery; report missing capabilities, never invent
reviews or skip gates.

<!--default:gated-delivery-authority-->
Implementation delegation grants routine gated merge authority in normal and
prime modes. Do not re-ask because Chris is present. Planning-only or review-only
requests, unrelated PRs and explicit holds are excluded; actual external approvals
and permission restrictions still apply.

Merge scoped prerequisites in dependency order, then refresh and verify dependent
PRs. Diagnose and repair failed gates within authority. Never bypass protections or use `--admin` or `--auto`.
Verify gates and merge synchronously. Ask only for a precise prerequisite the
agent cannot supply within its authority.

<!--default:default-roles-->
Use one coordinator through verified delivery, one capable workhorse
implementer and fresh workhorse reviewers each round. Never resume a previous
round's reviewer to satisfy a fresh review. Mechanical work uses a cheaper
adequate tier. Resolve roles against the available provider: Codex Sol and Claude
Sonnet are workhorse examples. LOW/MEDIUM coordination uses Sol/Opus-level reasoning; HIGH may use top
orchestration under the Fable rule. No provider switch is required; never claim unavailable roles.

<!--default:in-effect-line-->
Put `In effect:` above status at package close-out and in the benchmark
workload note. Say whether people/sessions can use it and whether it was seen
working outside tests. If not, name the action and owner that make it effective.
This reports use; it is no merge gate.

<!--default:restart-triggers-->
Record mode/package at startup and in ledger/seed. Normal is default;
`/prime-directive` or an explicit continuing mission selects prime. Chris's
presence does not change it.

Normal mode finishes the package and dependent PRs through verified merge and
ledger update, then writes the seed and gives Chris its verified absolute path
for a fresh session. The first PR does not complete the package. Start no new
backlog feature.

Prime checkpoints each wave in ledger STATE, then continues the next authorized
mission item within limits through supported continuation/auto-compaction.
Waves, second compactions and arbitrary token counts do not force an end.
Reload directive and durable state after compaction; summaries do not preserve
authority or consumed limits.

For fresh context mid-package, save state. Give an authorized relauncher the
absolute seed and verify an accepted task/session ID. Otherwise continue on the
host, or name its limit and precise restart needed. A launcher or seed is not
execution. Never invent a command or schedule.

Pause, exhausted configured budget/retries or dependency may stop affected work.
Advance independent authorized slices before a wait-only handoff. Preserve
acceptance, authority and consumed limits across restarts; route heavy output
to workers when useful. A lower compaction window is a host experiment, not a
stopping rule; measure compaction, handoff and reconstruction cost before
claiming savings.

At end or continuation, capture immutable cumulative `usage-checkpoint.py`
usage for parent/children with stable run ID and partial/final status. Aggregate
each run/session's latest checkpoint only. Append the historical effective-unit
`usage-benchmark-row.py` row at most once; pass `--tier` for one delivered package.
Keep emitted `· subagents:`, `· work:` and `· cost:` values, never hand-type them.
Keep existing rows and capture continuation anyway. Then write the seed through
`/session-lifecycle`, which carries full commands.

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
Resolve roles against the available harness ladder; Claude's is Fable, Opus,
Sonnet and Haiku. Mechanical triage, classification and sweeps use the cheapest
adequate tier. Implementation runs at least one rung below the session ceiling,
which is reserved for orchestration and hardest adjudication. Worker briefs and
skills that spawn agents name the actual role and model, never above that ceiling.
Put choices in spawning calls and briefs; root prose does not select models.

<!--default:fable-paced-->
Fable is a per-turn, main-thread choice for genuinely HIGH blast radius or
the hardest adjudication. HIGH includes doctrine, serialization/save compatibility,
CI/infrastructure, security and cross-cutting refactors. Judge blast radius rather
than uncertainty; an unclear tier is not HIGH. Never use Fable subagents,
including finders, refuters, judges or sweeps.

There is no weekly dollar ceiling, and reinstating one is the thing to argue
against. The objective is to saturate the week. Quota resets Wednesday at 15:59
America/Los_Angeles without rollover. Pace work to avoid exhausting the meter
early; a pace check informs and never refuses authorized work.

Before continuing Fable, read the script rather than guessing or rescanning:

```bash
python3 ~/.claude/scripts/usage-pace.py --oneline
```

Prefer it to the rescanning `usage-trend.py --week --oneline`. It reports live
`sd` seven-day/`fh` five-hour percentages, sample age, $/point, headroom and burn. Read percentages, never infer them
from spend or elapsed week, and never revive cached `NEAR CAP` verdicts. Calibrate
against this week's observed zero and movement, not a fixed or past cap.
Reject pre-period samples. Without a desktop sample, label output
`derived — no live sample` and name its statistic. Absence of an observed clamp
does not prove headroom.

Pre-2026-09-20 totals undercounted roughly 9%; identify their accounting policy
before comparison with corrected figures. Meter units are unverified; retain dollars, raw tokens and input-equivalent
tokens in readings. `--units` may report a tie
rather than guess. Record readings on any day with these runnable commands:

```bash
python3 ~/.claude/scripts/usage-pace.py --calibrate
python3 ~/.claude/scripts/usage-pace.py --record
python3 ~/.claude/scripts/usage-pace.py --units
python3 ~/.claude/scripts/usage-pace.py --caps
```

They calibrate, record pairs, compare units and report implied caps. Commands prompt when needed; use no angle placeholders in runnable commands. `meter` is an optional
machine alias, not shipped. Without desktop history, calibration fails with an explanation; other paths
use recorded/measured fallbacks.
Do not treat past caps as constants.

Claude's `UserPromptSubmit` hook checks every 40 Fable turns only for a wall
before half the remaining week or landing below 90% with less than one day left. It speaks once per verdict, is quiet
after acknowledgment until that verdict changes, and is silent outside Fable.
It cannot refuse work; `--margin` is accepted and ignored. Still check before continuing.

<!--default:risk-tiered-review-->
Scale review with blast radius:

- LOW docs, pack/art data, guards and mechanical changes get one focused
  independent reviewer through `/full-review`, without a panel.
- MEDIUM features with coverage get one reviewer; adversarially verify critical
  findings only.
- HIGH doctrine, serialization/save compatibility, CI/infrastructure, security
  and cross-cutting changes get a dimension panel. Refute critical and suggestion
  findings only, never nitpicks. Use at most three refuters per finding and at
  most 20 agents for the whole workflow, including refutation. Queue overflow
  instead of widening fan-out.

The sole HIGH exception is security or permissions code covered by executable
tests: one fresh reviewer per round plus Codex, with a panel if Codex cannot run.
Every other HIGH change, doctrine included, keeps the panel. Use fresh reviewers
each round, never a previous round's reviewer resumed. Ultracode runs only for
repo marathons unless invoked per task; planning, chat and fleet default to off.

`usage-benchmark-row.py` emits `· subagents: <eff>M/<count>` for weighted units and
count, `· work: <n>pr/<n>iss` for merged PRs and closed issues, and
`· cost: $<lower>–<upper>` for priced range against a passed tier's reference.
Keep the emitted values, never hand-type them. `work: n/a` means GitHub could
not be queried; it is not zero and must not be replaced with `0`.

<!--default:reference-figures-->
Nonblocking cost references for one delivered package are $15 for LOW or
MEDIUM, $30 for HIGH under the one-reviewer exception, and $45 for HIGH at panel
depth. Pass `usage-benchmark-row.py --tier` with `low`, `medium`, `high-single`
or `high-panel`, respectively. Explain costs above 1.5 times the reference in
the row. For multiple or partial packages, omit the tier and say so. Fix blockers
at any cost; the figures stop nothing.

The basis is the whole session's coordinator and subagents, using the script's
transcript-priced lower bound. This covers Claude only, excluding Codex; do not substitute exit-only harness totals.
The HIGH figures remain provisional; revisit them after four more HIGH rows.

<!--default:review-on-a-stable-head-->
Review a stable commit and push nothing on top until all reports return.
Fold independent reviewers, Codex and Copilot into one corrective push. Use at most two full rounds and one delta round since the last reviewed head. Justify any additional round in the PR before starting;
no permission is needed. Fix blockers despite the cap and use fresh reviewers.

<!--default:codex-pass-->
HIGH changes to security, permissions or persistence get one read-only Codex
pass on the first stable head before other reviewers, and at most one post-fix
delta pass. Count these separately from review rounds. Invoke
`codex exec -s read-only -m <available-model> --skip-git-repo-check` and relay the
findings. Name an available model; a default can be rejected by the login. Keep the
git-check flag.
If Codex cannot run, report it and use full panel depth. Revisit after four more
such packages on the whole result, not merely the finding count.

<!--default:follow-on-protocol-->
Fix, remove or verify containment of correctness, security, data-integrity
and promised-acceptance blockers before merge. Neither an issue URL nor an
estimate waives them. Classify with evidence; read summaries and inline threads, not resolution flags. Track
low-impact nonblockers when safety and acceptance remain satisfied without
manufacturing another CI cycle.

Verify a fallback's safety, correctness, runtime/cost and essential capability;
record evidence, file the problem and continue without an owner pause. Otherwise block the affected item
and advance independent authorized work.

Optional or unrelated defects join a PR only if in scope and at most 15 minutes;
otherwise file a scoped issue through `/create-issue` where installed. Prioritize
the delegated outcome and acceptance, not easy cleanup. Review suggestions do not expand scope. An explicit backlog-clear run keeps its selected scope.

Name the evidence and missing QA, access or authority for a real blocker; ask
only for necessary user action. Zero issue closures alone is not a blocker.
Advance independent slices through their authorized gates before a wait-only
handoff. The owner supplies only the reserved prerequisite; retain and resume
already delegated execution through supported continuation. Keep retry/budget
caps, and never silently expand scope, fake a merge or lose an unrecorded follow-on.

<!--default:private-advisory-for-exploitable-findings-->
A currently exploitable weakness on a public default branch or released
version stays private. Its nature, trigger and motive go nowhere public or into tree/history,
issues, PRs, discussions, reviews, branches, commits, tests or CI. This overrides public follow-up and auto-file
steps; the blocking criteria above still apply. Assume public unless
`gh repo view --json visibility` reports `PRIVATE`.

Exploitable means unauthorized secret access, session/machine access, command
execution/approval, auth/permission bypass, data tampering or denial of service
today. Consult `SECURITY.md` or the threat model. Ordinary bugs,
nonexploitable hardening, unmerged-only flaws and published dependency advisories
remain public review or upgrade work.

Before any repo report, write the finding, location, reproduction and fix under
`~/Obsidian/no-it-all/security/`, named for the repo and UTC time rather than the
flaw. Never include a secret value; identify a credential by commit/path and
tell Chris to revoke it first. Subagents finish other work with the finding omitted and return
`PRIVATE-FINDING <vault-path>` first
with certainty; they do not file. The coordinator reads it and strips
marker/path from public relays and files.
Brief auditors likewise. If unsure, publish nothing, put the question in DECISION
and the seed, and continue other work.

Locate the fetched registry checkout and invoke its `assets/scripts/private-advisory.sh`
by absolute path with `--repo OWNER/REPO` to list advisories first. Read the result; use `--reuse GHSA-ID` for a matching advisory and create
nothing. Only after semantic review finds no match, create one draft with
a neutral summary, vault description, severity, ecosystem and package, using the
`--create --reviewed-list` digest and explicit finding/metadata arguments. The script relists before creation, builds with
`jq --rawfile` and POSTs in the same call only if the body builds. Never create a
test draft; drafts have close, not delete. Use `--repo` to target another repo. A 422
gets at most one retry after relisting; a match stops creation and a changed list
requires renewed review. Every other failure is final. If Chris is not a repo
administrator, stop at the vault file.

On failure, retain the record and put failure, path and “1 finding withheld” in
⛔. Give Chris the ID/path in chat status, seed and ledger only, never `docs/`.
A withheld report cannot claim complete/clean. If it blocks a PR,
convert the PR to draft without a public reason and tell Chris privately. Add
nothing to existing public disclosure; record it privately and tell Chris.

Public fix metadata states behavior without motive: no
advisory ID, security label or exploit steps in branch names, PRs, commits,
changelogs, tests, diffs, logs or reviews, and never “refactor” or “cleanup.” Use
the smallest regression input asserting new behavior and brief reviewers likewise.
Chris publishes advisories/releases; tell him a release should follow merge where
applicable.

<!--default:ci-watcher-by-default-->
When only CI remains, arrange a wake-up; never ask Chris to say “continue.”
Where available, turn on `ccd_pr set_monitor` with `auto_fix: true` under standing
authorization. It wakes on failure, conflict and comments, not green.
Always arm one bounded `run_in_background` watcher, such as
`timeout -k 30 5400 gh pr checks <N> --watch --interval 60` (`gtimeout` on stock
macOS). Choose the ceiling under the long-job rule when a baseline exists.
Name it in 🔄. Recheck final-head gates after settlement. Use one watcher per wait, carrying CI's ceiling/check-in;
add no second waker. This overrides generic app advice against polling CI.

<!--default:long-job-waits-bounded-->
Give long jobs a hard timeout, success marker and progress check. The ceiling
is max(three times the last success, 10 minutes), or 30 minutes without a baseline;
record duration. Run `timeout -k 30 <seconds>` (`gtimeout` on macOS); TERM may
leave shutdown stuck. Success is the job's marker, or exit code if none. Investigate
missing markers at timeout; kill processes alive 60 seconds after success.

Above 15 minutes, arm a check-in beside completion wake. `run_in_background`
wakes only on exit. Use `Monitor` on a log-heartbeat loop, rearmed on expiry for
at most 30 minutes. Use `ScheduleWakeup` only inside `/loop`. First check at about
1.5 times expected duration; read tail and log advance. Name unavailable checks
in 🔄.

Running past min(ceiling, 1.5 hours) is an incident unless a longer norm is
documented. Inspect logs, identify the stuck step, kill and file the cause;
never wait on that run again. A rerun gets its own ceiling. Report queued runs
past that mark as runner problems. In 🔄, list job, start, ceiling and last log
advance. CI's one bounded watcher is ceiling/check-in; add no second waker.
