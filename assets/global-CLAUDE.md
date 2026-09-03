<!--
  REGISTRY NODE for the global instructions — the conventions loaded into every
  Claude Code session on a machine, version-controlled here so they persist across
  machines. Bootstrap a new machine with:

      cp assets/global-CLAUDE.md ~/.claude/CLAUDE.md

  ~/.claude/CLAUDE.md is AUTHORED, not generated: it is edited in place on the
  machine, and this file is edited in place here. Two authored nodes drift in both
  directions at once, so "which one wins" is not a single answer — it is two, split
  by rule class. See "Rule precedence" below, and run:

      python3 ~/.claude/scripts/fleet-check.py

  Each rule carries an HTML-comment class token — floor:id or default:id — on the RULE,
  never on the heading above it. Headings get renamed; rules are what fleet-check compares.
-->

# Global instructions

## Rule precedence (all projects)

<!--default:rule-precedence-->
**Two nodes hold these conventions, and both are authored.** The **machine node** is
`~/.claude/CLAUDE.md`, loaded into every session on this machine. The **registry node** is
`assets/global-CLAUDE.md` on `origin/main` of `blamechris/skill-templates`, the copy a new
machine bootstraps from. Neither generates the other. Nothing here is push-deployed.

**Two rule classes, and a rule's class is carried by a token on the rule itself** —
`<!--floor:id-->` or `<!--default:id-->`, on the line above the rule's paragraph:

- **FLOOR** — exactly five rules: `no-agent-attribution`, `explicit-path-staging`,
  `worktree-by-default`, `no-secrets-in-committed-files`,
  `seed-written-outside-any-worktree`. A floor rule reads identically on both nodes or the
  fleet is broken; a floor difference stops long work until it is reconciled.
- **DEFAULT** — everything else, including every unclassified line. A default may differ
  per machine. Difference is *information*, not an error.

Section granularity cannot express that split — `seed-written-outside-any-worktree` sits
inside a section that is otherwise all defaults — and headings get renamed, which is why
the token goes on the rule and heading lines are ignored when comparing.

**The resolver**, when the two nodes differ:

1. **A floor rule differs** → stop. Reconcile before starting long work: land the machine's
   delta in the registry (PR), then copy out once. Never resolve it by deleting.
2. **A default differs, machine-ahead** → the machine is the one in use; land it in the
   registry so the next machine gets it.
3. **A default differs, registry-ahead** → copy out.
4. **Both moved** → land the machine's delta first, then copy out once. "Registry wins" as a
   blanket rule silently deletes conventions in active use, which is how #208 happened.

`fleet-check.py` reports exactly this: exit 1 on a floor difference, exit 0 naming the
direction on a default difference, exit 2 — never 0 — when it cannot see the registry copy.
Its `git fetch` is a hard precondition, because a comparison against a stale clone is a
wrong answer delivered confidently.

**The seed path is a floor rule for one reason:** it is the only file the *next* session
depends on, and every other placement put it somewhere a teardown, a branch, or an index
could destroy it. It lives at an absolute path in the vault —
`$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, default dir `~/Obsidian/no-it-all/handoffs/` — and
`<scope>` is the **main worktree's directory basename**, resolved from git. **Ask the script.
Never re-derive it here:**

```bash
python3 ~/.claude/scripts/session-seed.py scope     # `fleet` outside any repo
```

Never a `$PWD` prefix test (worktrees live outside `~/Projects`), and never the origin slug:
`chroxy` and `chroxy-daemon` share one origin URL and are separate scopes with separate work.
Those are properties the script already holds, not a specification to reimplement — along
with several a two-line snippet cannot carry: a bare repo, a git failure that is not "not a
repository", and a linked worktree whose main checkout is gone are each a REFUSE rather than
a guess at `fleet`.

This paragraph carried a hand-written `git rev-parse` copy of that derivation until #210 —
a *second* implementation, in the file every agent reads, added four commits after the
extraction whose entire purpose was to have one. That is how this defect class works: the
copy is always the convenient thing to write and always the thing that drifts, and the copy
in the most-read file is the one that wins the drift. CI now fails on a second derivation
anywhere in `generic/` or `assets/`.

## End-of-message summary (status block) — all projects, all agents

<!--default:status-block-->

**End every response to the user with a MECHANICAL status block** — the final thing in the message. A bold `**Status:**` lead on its own line, then the same four slots in the same order, one bullet each, `none` when a slot is empty:

```
**Status:**
- ✅ <done this turn>
- 🔄 <in flight — enumerated, see below>
- ⛔ <blocked — on what>
- 🔶 DECISION: <pending user decision, or none>
```

- Keep each slot to short specific phrases (name the PR, issue, CI run, task ID, or person).
  Several outcomes in ✅ are separated by `·` — outcomes, not narrative.
- **The 🔄 slot enumerates, never summarizes.** Every agent/task still running gets its own
  indented sub-bullet, `<agent/task> — <state> (<target>)`:

  ```
  - 🔄 2 in flight:
    - bug-hunt — running (auth module)
    - agent-review — done, merging results (PR #53)
  ```

  A bare summary phrase ("agents working", "3 tasks in flight") is exactly the failure this
  slot exists to prevent — the reader must see at a glance which agents are working and which
  are finished. When nothing is in flight, the slot is just `- 🔄 none`.
- **The DECISION slot is load-bearing**: any choice waiting on the user appears there in a few
  words, every message, until resolved — never only in prose. When the user replies "decision"
  (or names one), immediately present it via AskUserQuestion with full context, trade-offs,
  and a recommendation.

This applies to the main agent AND to any subagent reporting back (a subagent's final message should likewise end with its own status block). The point is consistency: the user tracks progress at a glance from the last lines, without re-reading the whole message. In the desktop/mobile app a block of short bullets scans; the old one-`·`-separated-line format does not and is **retired** — don't emit it. Don't pad the block — it's a status, not a recap.

<!--default:next-line-->
**After the status block, add one final line:** `**Next:** <one sentence — the single thing Chris should do now>` (merge X / answer the DECISION / start a fresh session / nothing — all clear). It is the executive summary of the whole message; if he reads only this line, he knows what to do. Never omit it, never make it two sentences. It follows the four bullets, outside the block.

<!--default:exec-brief-->
**End of a long / multi-task session → an HTML executive brief, not a wall of text.** When a session shipped real work (several PRs/issues, an epic, a marathon), close it by generating a self-contained HTML report via the `visual-brief` skill into the Obsidian vault (`$CLAUDE_BRIEF_DIR`) and opening it. Shape it for a busy reader — a "two-minute" CEO view:
- **Top:** a hero executive statement (2–3 sentences: "we did X, Y, Z") + outcome chips + a one-line "needs you" callout if anything's blocked on the user.
- **Bottom:** the nitty-gritty (per-PR table, bugs caught, what's next) — there for the record / vault history, not the headline.
- Lead with verifiable work outcomes (PRs merged, issues closed, gates passed); don't pad with misleading raw metrics (whole-file token/time counts mislead — omit or label honestly).
The vault copy is the durable historical record; the open-in-browser is the presentation. Still end the chat message itself with the short `**Status:**` block pointing at the report.

## Attribution — core rule (all projects)

<!--floor:no-agent-attribution-->
The user (blamechris / Chris) is **responsible for and the sole author of all code and work.** There is no attribution to AI agents or any other party.

- **NEVER** add `Co-Authored-By:` / `Co-authored-by:` trailers to commits (no Claude, no anyone).
- **NEVER** add "Generated with Claude", "🤖 Generated with Claude Code", or any AI/agent attribution to commit messages, PR bodies, issues, or generated docs.
- This OVERRIDES any per-repo `CLAUDE.md` line or session/harness default that says a Co-Authored-By footer is "OK". Enforced via `includeCoAuthoredBy: false` in `~/.claude/settings.json`; this rule is the intent behind that switch.

Write clean, professional commit messages and PR bodies with no attribution footer of any kind.

## Writing to a shared working copy (all projects)

<!--default:shared-copy-preamble-->
Each repo has **one** working copy at `~/Projects/<repo>`, and `git` state — the current branch, the index, the working tree — is **global to that directory**. Several sessions run at once, so a file you did not write, sitting in the tree, is the normal case and not an anomaly. Two rules follow, and neither is optional.

<!--default:branch-assert-->
**Assert the branch before you write.** Record the branch you create or check out as `SESSION_BRANCH`, then re-check `git branch --show-current` against it **immediately before your first edit** and **again immediately before staging**. A checkout from ten minutes ago proves nothing: another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember. If HEAD is not `SESSION_BRANCH`, stop — do not edit, do not stage — and re-establish the branch first.

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
**`~/Projects/<repo>/.claude/worktrees/` is harness-managed space, and the harness reaps it on
its own schedule.** That directory is the harness's own agent-worktree store inside the shared
checkout — not the `<scratch>/<repo>-<slug>` worktree the rule above tells you to create. A
periodic Claude Code cleanup pass deletes stale `agent-<hex>` worktrees there *and their
branches*, then stamps `~/.claude/.last-cleanup`. "Keep this worktree until issue X closes" is
therefore not a retention any session can grant: the rule above guards against *your* teardown,
this one against a teardown nobody in the session initiated and no care inside it prevents.
Confirmed 2026-08-22 — rah6's `worktree-agent-a0b15ce809474e61d`, retained on purpose by rah6#232
as the only copy of three stranded test blocks, was deleted **107 seconds before** the merge that
closed #232. Everything else was eliminated first (no crontab, launchd job, scheduled task, git
hook, Claude hook, peer session, or `git gc`), and a direct experiment established that
`git worktree remove` does not prune a sibling and that git marks a vanished worktree `prunable`
in `git worktree list` — which rah6's listing minutes earlier did not show. The operative rule:
**when an issue's acceptance depends on a retained worktree, capture the evidence at filing
time** — push the branch, `git tag` the commit in the main checkout, or paste the diff into the
issue body. A filesystem path in an issue is a pointer to something already scheduled for
deletion.

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
Skills live in the `blamechris/skill-templates` registry and install on demand
via `/skill`. If asked to run `/X` and it is not present in this repo's
`.claude/commands/`, first run `skill add X` (resolve → customize for this repo
→ write + lock), then invoke `/X`. Use `skill outdated` / `skill update` to
refresh drifted skills. Don't hand-copy skills between repos or re-enable the
old push-deploy.

## Session boundaries (all projects)

<!--default:restart-triggers-->
Context re-reads dominate cost (70% in the 2026-07 audit): every request re-reads
the whole context at cache-read rates, so a restart that halves context pays for
itself within ~10 requests. Rules:

- **Restart into a fresh session** — seeded from this scope's seed,
  `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` (paste its absolute path as the opening message)
  plus any queue/ledger STATE header it points to, never the full history — at: each
  marathon wave boundary; a second compaction; or when switching work class (new epic,
  security-critical work, high fan-in refactors, visual-verify features). Outside a repo,
  `/next` ranks the fleet from those same seeds.
- **Continue** only when the next task genuinely needs the context already loaded.
- **One wave per session — there is no in-wave token ceiling to hold.** A single
  wave's context legitimately crosses 150K mid-flight (measured 2026-08-19: the
  median one-PR wave passes it by request ~40), so a numeric ceiling can only be
  violated and trains sessions to ignore rules. The real levers: restart at the
  wave boundary, and route heavy tool output — full-file reads, test logs, recon
  dumps — through subagents instead of the main thread.
- **Applies to orchestrator/chat sessions too**, not just repo marathons: a wave ends →
  write the handoff → end the session (recommend it explicitly when attended). For
  autonomous continuity, create a one-time scheduled task at the boundary that fires a
  fresh session seeded from the handoff — **naming that absolute path explicitly** — the
  wave, not the session, is the unit of continuity (skill-templates#181). The path is
  stable across waves, which is what makes a relaunch task safe to write in advance.
- **Ending a session = two artifacts, every time:** ① the session's row appended to
  the usage benchmark (`~/Obsidian/no-it-all/briefs/usage-benchmark.md`) — generate it
  with `python3 ~/.claude/scripts/usage-benchmark-row.py` and replace only the
  `<workload note>` placeholder with a one-line workload note (duration + workload
  class make rows comparable; the measured `· subagents:` suffix stays as emitted); if it
  resolves to a session ID that already has a row, neither append nor overwrite — the
  counters are cumulative and both corrupt the record; ② the next-session seed, below.

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
**Subagent/model tiering:** resolve roles against the harness ladder (currently
fable > opus > sonnet > haiku). Mechanical work (triage, classification,
verification sweeps) runs on the cheapest adequate tier; implementation runs
one tier below the session ceiling; the ceiling itself is reserved for
orchestration and the hardest adjudication. Skills and worker briefs specify
roles ("workhorse", "mechanical"), never a model above the session ceiling.

**Naming the tier in doctrine has not moved a dollar, so the tier goes in the
brief that spawns the agent** (decided 2026-09-02). Four consecutive weeks of
subagent spend closed at effectively **$0 haiku** while this paragraph said
mechanical work belongs there, and the week closing 2026-09-02 ran **97.0% opus /
2.3% sonnet / 0.7% fable / 0.03% haiku** — with sonnet *regressing* from 15% the
week before. Subagents are now **45% of all-in spend**, the largest share on
record, so this is the biggest untouched dial by a wide margin: a third of that
moved down one rung is worth more than the entire Fable overage that prompted a
rule change. The concrete action is not another sentence here — it is putting the
role in the **worker briefs and review skills that actually call the Agent tool**
(triage, classification, verification sweeps, refuter panels), where the model is
chosen. A principle stated at the top of every session and applied at none is
evidence about placement, not about the principle.

<!--default:fable-paced-->
**Fable is scoped, and the scope is paced — not capped** (decided 2026-09-02,
replacing the `$500`/week ceiling of 2026-08-26, which replaced the self-expiring
hard throttle of 2026-08-22). Fable costs exactly **2x Opus** ($10/$50 per M vs
$5/$25), so it is permitted in exactly one place: **main-thread orchestration of
work that is HIGH-tier by the risk tiers below** — doctrine, serialization/save-compat,
CI/infra, security, cross-cutting refactors — **and the hardest adjudication.**
Judge the tier from the blast radius the session is aiming at, not from how the
work feels; when it is genuinely unclear, it is not HIGH. **Never for subagents**
— no Fable finder, refuter, judge, or sweep, whatever the panel's tier. That half
is categorical and needs no arithmetic to obey; it still leaked $8.73 across four
agents in the week closing 2026-09-02, so it is restated here rather than assumed.

**There is no weekly dollar ceiling, and reinstating one is the thing to argue
against.** The subscription is a flat fee whose meter resets Wednesday 15:59
America/Los_Angeles and **does not roll over** — quota unspent is quota destroyed.
The objective is to saturate the week, not to minimize it. The `$500` ceiling was
derived as "half the worst observed week," a risk number rather than a quota
number, and the ledger had already falsified it: the week closing **2026-08-05 ran
fable $963 through the meter with no clamp**, so the true cap is *provably above
$963* and `$500` was capping at **52% of demonstrated-safe headroom**. Two more
weeks ran $833 and $878 unclamped. A ceiling below proven headroom is waste
wearing the costume of discipline.

**What replaces it is a pace check, and its job is to make you look — never to
stop you.** The failure it exists to prevent is exhausting the meter on Tuesday
and being blocked until the next Wednesday; that is a pacing failure, not a
spending one. So: while a session is on Fable, compare consumption against the
fraction of the meter week elapsed, and when consumption outruns elapsed time,
**surface the number and require an explicit acknowledgment to continue.**
Acknowledging is always available and is not a failure — a heavy week that paces
to 100% is the system working. **Ask the script, never a guess or a fresh scan**
(it buckets by the same boundary)**:**

```bash
python3 ~/.claude/scripts/usage-pace.py --oneline    # fable $N, % of cap, % of week elapsed
```

It answers the pacing question in one line and costs ~0.1s warm (an incremental
byte-offset cache; ~5s only on the first call of a new meter week), so there is no
budget excuse for not looking. `usage-trend.py --week --oneline` still works and is
the same arithmetic, but rescans every transcript on every call — prefer the former.

**A `UserPromptSubmit` hook runs this automatically** (`~/.claude/settings.json`):
while a session is on Fable, every 40 turns, it compares consumption to elapsed time
and prints a `<usage-pace>` block only when consumption is more than 15 points ahead
— or past 90% of cap. It speaks once per verdict, escalates if the situation worsens,
and is silent for every non-Fable session. It cannot refuse anything.

Until a real meter reading exists, it paces against computed spend and the
proven-safe floor (`> $963`) rather than the retired 2026-08-06 estimate, and says so
in its own output. **A second thing is unverified and worth stating plainly: nobody
has established what the meter counts.** Every cap figure in this system is quoted in
dollars because that is what the first calibration assumed, not because it was tested.
Three units fit the evidence — list-price dollars, raw tokens (cache reads are ~97% of
all tokens, so this differs by roughly 10x), and input-equivalent tokens (the same
cache/output weighting as dollars but blind to Fable's 2x model premium). Each reading
therefore records all three, because a reading stored in one unit cannot be converted
into another after transcripts are pruned. `--units` compares implied-cap stability
across readings and names the unit whose cap holds steady; it reports a tie as a tie
rather than guessing, since dollars and input-equivalent tokens are degenerate until
readings sample genuinely different Fable shares. Across the eight weeks on record the
discriminating ratios span 1.41x (`$/ieq`) and 1.23x (`raw/ieq`), both far above the
noise in an eyeballed percentage — so two well-placed readings settle it. **Record a reading any day of the week** — the deadline is gone:

```bash
python3 ~/.claude/scripts/usage-pace.py --record  # prompts for the two /usage percentages
python3 ~/.claude/scripts/usage-pace.py --units   # which unit does the meter count?
python3 ~/.claude/scripts/usage-pace.py --caps    # implied caps from every reading
```

`meter` is an **optional per-machine alias** for the first of those, not a shipped
command — nothing in the registry defines it, so the script form above is the one that
works on a machine that bootstrapped from `assets/scripts/`. `session-lifecycle` carries
the one-line definition for machines that want the shorthand. Either form prompts when
given no values, so neither needs a placeholder substituted into it: a documented command
carrying `<angle brackets>` is read by the shell as a redirection and cannot be run as
written.

**Fable is a per-turn choice, not a session mode.** This is the defect the pace
check is shaped around, and it is worth stating separately because the previous
rule missed it entirely. In the week closing 2026-09-02 two sessions ran **100%
Fable for 600 and 542 consecutive requests** at ~580K context per request, $441
and $368, and **neither ever ran the command above** — not once across 1,142
requests. The rule was not overridden or argued with; it was never read. A tier
selected at turn one and never revisited is how $500 became $878 without anyone
deciding to spend it. Whatever surfaces the pace must make *continuing* on Fable
an act, not an inheritance.

The honest evidence, because a rule argued from a flattering summary is a rule
nobody can re-evaluate later: **one** week ran under the hard throttle (closing
2026-08-26, fable $470, 44 PRs across 6 repos) and **one** under the `$500`
ceiling (closing 2026-09-02, fable $878 — the ceiling was crossed mid-session on
08-29 and nothing noticed). Unthrottled weeks have run $348 / $640 / $833 / $963.
The throttle cannot be credited with the low unit price either: the cheapest
main-thread week on record is $0.172/req opus-equivalent, closing 2026-08-12,
**unthrottled at fable $833** — against $0.180 for the throttled week. What the
throttled week does show is that removing Fable cost no measurable throughput,
which is an argument about *value*, not about *cost*, and is still open.

Two ceilings have now been tried and neither was ever consulted by the sessions
that crossed it. The lesson generalizes past Fable: **in this ledger every
honor-system limit has failed and every mechanically-bound one has held** — the
agent fan-out cap was breached 8 times on the honor system and 0 times in 17
workflows after `skill-guards.json` bound it. A limit nobody queries is not a
limit, and a third written number would be the third of the same kind.

<!--default:risk-tiered-review-->
**Review intensity is risk-tiered** (decided 2026-08-14, spend audit; refuter
panels buy precision, not recall — the catches live in the finder pass and the
test gates). Depth scales with blast radius:
- **LOW** (docs, pack/art data, guard additions, mechanical renames): inline
  `/code-review` at high effort — no subagent fan-out.
- **MEDIUM** (feature code with test coverage): 1 review agent; adversarially
  verify **critical** findings only.
- **HIGH** (doctrine, serialization/save-compat, CI/infra, security,
  cross-cutting refactors): full dimension panel; refuters on critical +
  suggestion findings only; **hard cap: ≤3 refuters per finding and ≤20 agents
  per review workflow, the refute stage included.** Finding count never scales
  the fan-out past the cap — when findings are many, queue refutation rounds
  instead of widening (the "~20" tilde was read as panel-only and breached six
  times, 27–70 agents, in its first week; hence no tilde).
Nitpick-severity findings never get refuter panels. Ultracode stays on for repo
marathon sessions only; planning/chat/fleet sessions run without it (invoke
per-task when wanted). Benchmark rows carry `· subagents: <eff>M/<count>`
(weighted eff units, e.g. `4.5M/61`, `0.0M/0`), measured and emitted by
`usage-benchmark-row.py` — keep the emitted value, never hand-type it.

## Follow-on protocol (all projects)

<!--default:follow-on-protocol-->
When a task completes and work remains:

1. In-scope and ≤15 min → fold into the current PR.
2. Anything else → file a scoped issue (`/create-issue` where installed) and queue
   it (autonomous-queue in marathons, else the tracker).
3. Blocked → comment-and-skip with a reason bucket (needs-dogfood/device,
   needs-owner-decision, visual-verify).
4. Never expand scope silently, never fake-merge, never drop a follow-on unrecorded.
