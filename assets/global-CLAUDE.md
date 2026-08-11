<!--
  CANONICAL SOURCE for ~/.claude/CLAUDE.md — the machine-level global instructions
  loaded into every Claude Code session on a machine.

  This file is version-controlled here (skill-templates) so the conventions persist
  across machines. Bootstrap a new machine with:

      cp assets/global-CLAUDE.md ~/.claude/CLAUDE.md

  To change a global convention: PR this file here, then copy to ~/.claude/CLAUDE.md
  on each machine. Machine-local additions are fine but drift silently — prefer
  landing them here.
-->

# Global instructions

## End-of-message summary (status block) — all projects, all agents

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

**End of a long / multi-task session → an HTML executive brief, not a wall of text.** When a session shipped real work (several PRs/issues, an epic, a marathon), close it by generating a self-contained HTML report via the `visual-brief` skill into the Obsidian vault (`$CLAUDE_BRIEF_DIR`) and opening it. Shape it for a busy reader — a "two-minute" CEO view:
- **Top:** a hero executive statement (2–3 sentences: "we did X, Y, Z") + outcome chips + a one-line "needs you" callout if anything's blocked on the user.
- **Bottom:** the nitty-gritty (per-PR table, bugs caught, what's next) — there for the record / vault history, not the headline.
- Lead with verifiable work outcomes (PRs merged, issues closed, gates passed); don't pad with misleading raw metrics (whole-file token/time counts mislead — omit or label honestly).
The vault copy is the durable historical record; the open-in-browser is the presentation. Still end the chat message itself with the short `**Status:**` block pointing at the report.

## Attribution — core rule (all projects)

The user (blamechris / Chris) is **responsible for and the sole author of all code and work.** There is no attribution to AI agents or any other party.

- **NEVER** add `Co-Authored-By:` / `Co-authored-by:` trailers to commits (no Claude, no anyone).
- **NEVER** add "Generated with Claude", "🤖 Generated with Claude Code", or any AI/agent attribution to commit messages, PR bodies, issues, or generated docs.
- This OVERRIDES any per-repo `CLAUDE.md` line or session/harness default that says a Co-Authored-By footer is "OK". Enforced via `includeCoAuthoredBy: false` in `~/.claude/settings.json`; this rule is the intent behind that switch.

Write clean, professional commit messages and PR bodies with no attribution footer of any kind.

## Writing to a shared working copy (all projects)

Each repo has **one** working copy at `~/Projects/<repo>`, and `git` state — the current branch, the index, the working tree — is **global to that directory**. Several sessions run at once, so a file you did not write, sitting in the tree, is the normal case and not an anomaly. Two rules follow, and neither is optional.

**Assert the branch before you write.** Record the branch you create or check out as `SESSION_BRANCH`, then re-check `git branch --show-current` against it **immediately before your first edit** and **again immediately before staging**. A checkout from ten minutes ago proves nothing: another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember. If HEAD is not `SESSION_BRANCH`, stop — do not edit, do not stage — and re-establish the branch first.

**Stage explicit paths.** `git status --short` first, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a`. A bulk add commits whatever else is in the tree — three separate incidents in one week trace to exactly that. `-u` is not the safe one, and this is the failure mode worth remembering: it looks harmless because it only touches *tracked* files, but "tracked and modified" includes every file a clean/smudge filter rewrote in the worktree without you touching it. A git-lfs filter doing precisely that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as a legitimate edit.

**Work in your own worktree — this is the default, not a preference.** Before writing to a
repo, if the harness has not already placed you in one, create one:

```bash
git -C ~/Projects/<repo> fetch origin
git -C ~/Projects/<repo> worktree add -b <your-branch> <scratch>/<repo>-<slug> origin/main
```

It shares one object store, so it is cheap, and it makes the collision *structurally*
impossible instead of merely prohibited. Remove it when the work lands
(`git worktree remove --force <path>`) — **but that removal is gated, because `--force` is
precisely the flag that deletes untracked files without prompting, and the session seed is
an untracked file inside this tree until it is committed.** Commit and push the seed, then
prove it is reachable from outside the tree you are about to delete:

```bash
git -C ~/Projects/<repo> cat-file -e <your-branch>:docs/handoffs/<file> && echo durable
```

No `durable`, no removal — leave the worktree standing and say why. Bare `git worktree
remove` refuses on a dirty tree; `--force` is what converts that refusal into an
unrecoverable delete, and the seed has no backup anywhere. The two rules above are the
fallback for when you genuinely cannot have one — they are advisory, and advisory is how
three separate incidents happened in one week, the third of them *while fixing the second*.

## Skills come from the registry (pull-on-demand)

Skills live in the `blamechris/skill-templates` registry and install on demand
via `/skill`. If asked to run `/X` and it is not present in this repo's
`.claude/commands/`, first run `skill add X` (resolve → customize for this repo
→ write + lock), then invoke `/X`. Use `skill outdated` / `skill update` to
refresh drifted skills. Don't hand-copy skills between repos or re-enable the
old push-deploy.

## Session boundaries (all projects)

Context re-reads dominate cost (70% in the 2026-07 audit): every request re-reads
the whole context at cache-read rates, so a restart that halves context pays for
itself within ~10 requests. Rules:

- **Restart into a fresh session** — seeded from the newest note in that repo's
  `docs/handoffs/` (paste its path as the opening message) plus any queue/ledger
  STATE header it points to, never the full history — at: each marathon wave boundary; a second
  compaction; or when switching work class (new epic, security-critical work,
  high fan-in refactors, visual-verify features). Outside a repo, `/next` derives the
  ranking from those same seeds.
- **Continue** only when the next task genuinely needs the context already loaded.
- Keep main-thread context under **~150K tokens**: once past it, finish the current
  item, write handoff state, end the session.
- **Applies to orchestrator/chat sessions too**, not just repo marathons: a wave ends →
  write the handoff → end the session (recommend it explicitly when attended). For
  autonomous continuity, create a one-time scheduled task at the boundary that fires a
  fresh session seeded from the handoff — **naming that dated file explicitly, never a
  pointer that can move** — the wave, not the session, is the unit of
  continuity (skill-templates#181).
- **Ending a session = two artifacts, every time:** ① the session's row appended to
  the usage benchmark (`~/Obsidian/no-it-all/briefs/usage-benchmark.md`) — generate it
  with `python3 ~/.claude/scripts/usage-benchmark-row.py` and replace the placeholder
  with a one-line workload note (duration + workload class make rows comparable); if it
  resolves to a session ID that already has a row, neither append nor overwrite — the
  counters are cumulative and both corrupt the record;
  ② the **next-session seed written to a new file at
  `<repo>/docs/handoffs/YYYY-MM-DD-<slug>.md`, then committed and pushed in the same
  step that writes it**: the frontmatter header, files to read first, a 2–4 line state
  summary (done / held / open follow-ons), a recommended `Today's task:` with
  alternatives, and the closing line instructing the new session to repeat this
  protocol. **Append-only — add a file, never rewrite or delete one; two sessions ending
  on one repo write two files.** *"NEXT" is a query, not a file:* the newest entry in
  `docs/handoffs/`. Writing it is half the artifact — an uncommitted seed lives in one
  directory that the worktree teardown above deletes without asking, so **a seed that is
  not committed has not been written.** Then hand Chris **one line to paste**: that
  file's absolute path, in a tree that still exists after cleanup ran. The seed file —
  not memory, not chat history — is the continuity mechanism. Anything in a seed still worth reading after it is
  consumed belongs in `docs/records/`, with the seed linking it. The vault stays
  presentational (briefs, benchmark rows), never canonical.
- Subagent/model tiering: resolve roles against the harness ladder (currently
  fable > opus > sonnet > haiku). Mechanical work (triage, classification,
  verification sweeps) runs on the cheapest adequate tier; implementation runs
  one tier below the session ceiling; the ceiling itself is reserved for
  orchestration and the hardest adjudication. Skills and worker briefs specify
  roles ("workhorse", "mechanical"), never a model above the session ceiling.

## Follow-on protocol (all projects)

When a task completes and work remains:

1. In-scope and ≤15 min → fold into the current PR.
2. Anything else → file a scoped issue (`/create-issue` where installed) and queue
   it (autonomous-queue in marathons, else the tracker).
3. Blocked → comment-and-skip with a reason bucket (needs-dogfood/device,
   needs-owner-decision, visual-verify).
4. Never expand scope silently, never fake-merge, never drop a follow-on unrecorded.
