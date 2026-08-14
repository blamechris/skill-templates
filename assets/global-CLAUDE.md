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
- Keep main-thread context under **~150K tokens**: once past it, finish the current
  item, write handoff state, end the session.
- **Applies to orchestrator/chat sessions too**, not just repo marathons: a wave ends →
  write the handoff → end the session (recommend it explicitly when attended). For
  autonomous continuity, create a one-time scheduled task at the boundary that fires a
  fresh session seeded from the handoff — **naming that absolute path explicitly** — the
  wave, not the session, is the unit of continuity (skill-templates#181). The path is
  stable across waves, which is what makes a relaunch task safe to write in advance.
- **Ending a session = two artifacts, every time:** ① the session's row appended to
  the usage benchmark (`~/Obsidian/no-it-all/briefs/usage-benchmark.md`) — generate it
  with `python3 ~/.claude/scripts/usage-benchmark-row.py` and replace the placeholder
  with a one-line workload note (duration + workload class make rows comparable); if it
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
  suggestion findings only; ~20-agent cap per review workflow.
Nitpick-severity findings never get refuter panels. Ultracode stays on for repo
marathon sessions only; planning/chat/fleet sessions run without it (invoke
per-task when wanted). Benchmark rows carry `· subagents: <eff>/<count>` per
the usage-benchmark.md 2026-08-14 note.

## Follow-on protocol (all projects)

<!--default:follow-on-protocol-->
When a task completes and work remains:

1. In-scope and ≤15 min → fold into the current PR.
2. Anything else → file a scoped issue (`/create-issue` where installed) and queue
   it (autonomous-queue in marathons, else the tracker).
3. Blocked → comment-and-skip with a reason bucket (needs-dogfood/device,
   needs-owner-decision, visual-verify).
4. Never expand scope silently, never fake-merge, never drop a follow-on unrecorded.
