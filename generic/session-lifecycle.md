# /session-lifecycle

The session bookends, codified — one skill that makes every repo start, run, and end sessions the same way. It bundles the Resume protocol (session start), the during-session reporting conventions, the end-of-session checklist, and the follow-on protocol into a single installable unit, composing the component skills (`/catchup`, `/learn`, `/visual-brief`, `/create-issue`) by reference. Natural-language cues like *"resume"*, *"let's start"*, *"wrap up"*, or *"close out the session"* should route here.

This skill is a **bundle head**: it does not re-implement the components, it drives them. Where a component skill is not yet installed in this repo, the install-on-miss rule applies — run `skill add <name>` first, then invoke it.

## Arguments

- `$ARGUMENTS` — optional subcommand:
  - `start` — run the session-start (Resume) protocol only.
  - `end` — run the end-of-session checklist only.
  - *(empty)* — infer from context: fresh session with no work done yet → `start`; work shipped and the user is wrapping up → `end`; otherwise ask which bookend is meant.

## Instructions

### Session start — the Resume protocol

Run these in order; each step re-derives state rather than trusting memory:

1. **Conventions** — read `CLAUDE.md` (project root). If the repo has none, note it and continue.
2. **Working tree** — `git status && git log --oneline -5`. Name anything dirty; never assume a clean tree. Record the branch you will work on as `SESSION_BRANCH` — this is the session's *claim*, and every write from here on is checked against it (see "During the session"). Dirty files you did not create belong to another session sharing this working copy: report them, leave them alone, and never stage them. Re-claim it whenever you deliberately switch branches — creating the feature branch you will write to is a legitimate switch, and a SESSION_BRANCH still pinned to `main` would make every later write assertion fail on correct work. The assertion exists to catch a branch that moved under you, not one you moved on purpose.
3. **Open PRs, split by author** — the split matters so external contributions aren't lost before autonomous work starts:
   ```bash
   gh pr list --state open --author "@me"
   gh pr list --state open --search "-author:@me"
   ```
4. **Skill drift** — run `/skill outdated` and report any drifted skills (fix now only if the session will use them).
5. **Global-conventions sync** — the canonical `~/.claude/CLAUDE.md` is version-controlled at
   `~/Projects/skill-templates/assets/global-CLAUDE.md`; check `diff -q` between the two. If they
   differ, surface the drift before long work: the registry copy wins unless the local delta is an
   un-landed improvement — in that case land it in the registry first (PR), then copy out.
6. **Prior-session state** — read the vault seed for **this** project,
   `~/Obsidian/no-it-all/handoffs/NEXT-<project>.md` (its sibling `NEXT.md` is an index of
   every project's seed — use it to find the file, don't read it as one). Then, if a
   repo-local handoff note, session ledger, or queue file exists ({{CUSTOMIZE: where this repo keeps handoff notes / session ledgers / queue files, e.g. `handoffs/`, `autonomous-session-<date>.md`, `scratchpad/autonomous-queue.json` — or remove this step's path list if the repo has none yet}}), read the ledger's STATE header (not the full history) and the handoff TL;DR. `/catchup` is the component skill for reconstructing a prior session where installed.
7. **Verify the last claimed merge** — if the prior session's notes claim a merge, confirm it (`gh pr view <n>` reports `MERGED`) before building on it. State is re-derived, not trusted.

Then state, in one short block: branch/HEAD, dirty files, open PRs (mine/others), drifted skills, and what the session is picking up.

### During the session

- **Every user-facing message ends with the mechanical `**Status:**` line** — four fixed slots (done · in flight · blocked · DECISION), `none` when empty. This is the global reporting rule in `~/.claude/CLAUDE.md` ("End-of-message summary"); follow it from there — do not restate or fork it here. Subagents' final messages carry their own `**Status:**` line.
- **Session boundaries** — the global `~/.claude/CLAUDE.md` "Session boundaries" section governs when to end this session and restart fresh (wave boundaries, ~150K main-thread context, second compaction, work-class switches). Follow it from there.
- **Assert the branch before you write.** `git` state is global to the working copy and several sessions share it, so re-check `git branch --show-current` against `SESSION_BRANCH` (claimed at start, step 2) **immediately before your first edit** and **again immediately before staging**. A checkout from earlier in the session proves nothing — another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember; if HEAD has moved, stop and re-establish the branch before writing anything.
- **Stage explicit paths.** `git status --short`, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a` — a foreign file in a shared tree is the normal case, so a bulk add commits someone else's work into your PR. `-u` is not the safe one: it restages every *tracked* file whose worktree copy differs, including files a clean/smudge filter rewrote without you touching them — that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as an edit.
- **Prefer a per-session worktree.** Where the harness gives this session its own `git worktree`, use it; where it does not, the two rules above are the whole of the protection and apply verbatim.

### Session end — the checklist

Run in order; skip a step only by saying so with a reason. Steps 4 and 5 are the **two vault
artifacts** the global `~/.claude/CLAUDE.md` requires at every session end — a run that skips
them ships an incomplete handoff no matter how complete the rest looks:

1. **Convergence note** — write what shipped, what remains, and *why* each remaining item is blocked or deferred, into {{CUSTOMIZE: where session state lives in this repo — the session ledger if one exists, else the closing chat message}}. This is the repo-local record and is **not** the handoff seed — step 5 is, and it is written even when this note is thorough.
2. **Executive brief** — for a session that shipped real work (several PRs/issues, an epic), run `/visual-brief` into the vault (`$CLAUDE_BRIEF_DIR`). Skip for small sessions — say so.
3. **Capture learnings** — run `/learn` for genuinely novel lessons; "nothing novel" is a valid outcome, stated.
4. **Vault artifact ① — usage-benchmark row.** Run `python3 ~/.claude/scripts/usage-benchmark-row.py`, replace the placeholder with a one-line workload note (duration + workload class, so rows stay comparable), and append it to `~/Obsidian/no-it-all/briefs/usage-benchmark.md`. If the script resolves to a session ID that already has a row, do **not** append or overwrite — say so and leave it for the user, because the transcript's counters are cumulative and either action corrupts the record.
5. **Vault artifact ② — the next-session seed.** Write `~/Obsidian/no-it-all/handoffs/NEXT-<project>.md`: files to read first, a 2–4 line state summary (done / held / open follow-ons), a recommended `Today's task:` with alternatives, and a closing line telling the next session to repeat this protocol. Then regenerate the index with `python3 ~/.claude/scripts/handoff-index.py --write`.
   - **Write only your own project's file.** Projects run concurrently and cannot see each other, so a shared seed path is a race — the later write destroys the earlier seed, and the vault is not git-tracked, so nothing recovers it. Never write a bare `NEXT.md` seed (it is the generated index), and never edit or delete another project's `NEXT-*.md`.
6. **Cleanup** — remove this session's worktrees (leave other sessions' worktrees alone), prune branches only after verifying each had a `MERGED` PR, stop dev daemons/servers started this session, restore any test-env mutations ({{CUSTOMIZE: repo-specific cleanup — daemons to stop, env files that get mutated during testing and must be restored, e.g. remove the marker if none}}).
7. **Final `**Status:**` block, then the one line to paste** — the last message ends with the short status pointing at the brief (if one was produced) and naming anything left for the user, and hands over the single line that seeds the next session: the `NEXT-<project>.md` path.

### Follow-on protocol (when a task completes and work remains)

The canonical rules live in `~/.claude/CLAUDE.md` under **"Follow-on protocol"** — fold-in vs file-an-issue vs comment-and-skip. Follow them from there; this skill deliberately does not duplicate the text, so the global file stays the single source of truth. The one repo-local hook: filing a scoped follow-up goes through `/create-issue` where installed.

## Component skills (the bundle)

| Component | Role | If missing |
|---|---|---|
| `/catchup` | Reconstruct prior-session state at start | `skill add catchup` |
| `/visual-brief` | End-of-session HTML executive brief | `skill add visual-brief` |
| `/learn` | Persist novel lessons at end | `skill add learn` |
| `/create-issue` | File scoped follow-on issues | `skill add create-issue` |

Installing `session-lifecycle` should be followed by installing any missing components in the same pass — the bundle head without its components is a checklist that can't execute.

## Customization Points

Lines and blocks marked `{{CUSTOMIZE}}` need repo-specific adaptation:

- **Handoff/ledger/queue paths** — where this repo keeps *repo-local* prior-session state
  (Resume step 6). The vault seed path is global and not customizable: it is always
  `~/Obsidian/no-it-all/handoffs/NEXT-<project>.md`.
- **Convergence-note destination** — session ledger vs closing message (End step 1).
- **Repo-specific cleanup** — daemons, test-env restores (End step 6).
