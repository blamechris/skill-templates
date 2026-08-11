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
   un-landed improvement — in that case land it in the registry first (PR), then copy out. Check
   `~/.claude/commands/next.md` against `~/Projects/skill-templates/assets/next.md` the same way —
   same rule, same direction. Both files are distributed verbatim, so this `diff -q` is their only
   drift detector; there is no CI gate behind it.
6. **Prior-session state** — read the **newest** note in {{CUSTOMIZE: this repo's handoff directory — default `docs/handoffs/` (`YYYY-MM-DD-<slug>.md`, one file per session boundary); add any session ledger or queue file this repo keeps, e.g. `autonomous-session-<date>.md`, `scratchpad/autonomous-queue.json`}}. **Newest wins**, resolved by the filename date first and, for two seeds sharing a date, by the `date:` timestamp in the frontmatter — never by mtime, which git does not preserve and which has already misordered production files. If two same-day seeds still tie, read both and say so rather than guessing. A seed whose `date:` is missing or unparseable — every seed written before this convention landed, and every one written by a template that forgot the header — **cannot be ordered against a same-day sibling at all**: that is a tie, not a loss. Read both and say so. A missing header must never be what decides which session you resume. Read the seed's header and TL;DR plus the ledger's STATE header — not the full history. Handoff notes are **perishable**: each is superseded by the next, and anything in one still worth reading after it is consumed belongs in `docs/records/`, linked from the seed. `/catchup` is the component skill for reconstructing a prior session where installed.
7. **Verify the last claimed merge** — if the prior session's notes claim a merge, confirm it (`gh pr view <n>` reports `MERGED`) before building on it. State is re-derived, not trusted.

Then state, in one short block: branch/HEAD, dirty files, open PRs (mine/others), drifted skills, and what the session is picking up.

### During the session

- **Every user-facing message ends with the mechanical `**Status:**` line** — four fixed slots (done · in flight · blocked · DECISION), `none` when empty. This is the global reporting rule in `~/.claude/CLAUDE.md` ("End-of-message summary"); follow it from there — do not restate or fork it here. Subagents' final messages carry their own `**Status:**` line.
- **Session boundaries** — the global `~/.claude/CLAUDE.md` "Session boundaries" section governs when to end this session and restart fresh (wave boundaries, ~150K main-thread context, second compaction, work-class switches). Follow it from there.
- **Assert the branch before you write.** `git` state is global to the working copy and several sessions share it, so re-check `git branch --show-current` against `SESSION_BRANCH` (claimed at start, step 2) **immediately before your first edit** and **again immediately before staging**. A checkout from earlier in the session proves nothing — another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember; if HEAD has moved, stop and re-establish the branch before writing anything.
- **Stage explicit paths.** `git status --short`, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a` — a foreign file in a shared tree is the normal case, so a bulk add commits someone else's work into your PR. `-u` is not the safe one: it restages every *tracked* file whose worktree copy differs, including files a clean/smudge filter rewrote without you touching them — that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as an edit.
- **Prefer a per-session worktree.** Where the harness gives this session its own `git worktree`, use it; where it does not, the two rules above are the whole of the protection and apply verbatim.

### Session end — the checklist

Run in order; skip a step only by saying so with a reason. **Steps 1–3 are the two ending artifacts and the commit that lands them; a session that skips either artifact has not ended.**

1. **Handoff seed (artifact ②)** — write a **new** file at {{CUSTOMIZE: handoff directory — default `docs/handoffs/`}}`YYYY-MM-DD-<slug>.md`: what shipped, what remains, and *why* each remaining item is blocked or deferred. **Append-only: add a file, never rewrite, rename, or delete an existing one** — two sessions ending on one repo write two files instead of racing, so no session's *write* can destroy another's seed. That is the only destruction this scheme rules out, and it is worth being precise about the rest: until step 3 commits it, the seed is an ordinary untracked file, and `git worktree remove --force` — the registry's own teardown idiom — deletes it without a prompt, unrecoverably, as does `git clean -fd` in a shared checkout. Step 3 is therefore not bookkeeping; it is what makes the seed exist, and step 6 may not run before it has. It lives in the repo, committed, so the next session reads it with no external dependency; the vault brief is the presentation copy, never the source of truth. A line that cannot be public has exactly two outlets — the vault brief, or the repo stays private. There is no third: no redaction-by-gitignore, no side file.

   `<slug>` is 2–5 kebab-case words naming the *outcome* (`e2-inline-write-path`), never a date and never the word `handoff`. `repo:` is the repo **directory** name, resolved from git rather than convention so two sessions cannot diverge on it:

   ```bash
   basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
   ```

   Required header — the only part `/next` reads:

   ```markdown
   ---
   type: handoff
   date: 2026-08-11T21:40Z          # full UTC timestamp; breaks same-day ties
   repo: skill-templates            # the repo directory name
   picks_up_at: "issue #205 — implement the layered continuity scheme"
   sensitivity: public              # public | vault
   ---
   # Handoff — <what this session actually landed>

   - **Boundary reason:** <which global session-boundary rule fired>
   - **Picks up at:** <the one thing the next session starts on>
   ```

   Then, in order: `## STATE` (branch/HEAD, working tree, CI, tests, open PRs/issues) · a **"Verify before building on any of this — re-derive, don't trust"** bash block where every command carries its expected answer as a comment · `## TL;DR — what shipped` · the next task · `## Left undone, deliberately`.

2. **Benchmark row (artifact ①)** — append this session's row to `~/Obsidian/no-it-all/briefs/usage-benchmark.md` via `python3 ~/.claude/scripts/usage-benchmark-row.py`, replacing the placeholder with a one-line workload note. If the script resolves to a session ID that already has a row, **neither append nor overwrite** — the transcript counters are cumulative, so both actions corrupt the record; say so instead.
3. **Land the seed** — `git status --short`, stage the file **by name**, commit `docs(handoffs): record the <date> session boundary`, **push the branch**, and include it in this session's PR — or open a docs-only PR if there is none. Never a direct push to a protected `main`. Then prove the seed survives this session's disk:

   ```bash
   git cat-file -e "$SESSION_BRANCH:docs/handoffs/<file>" && echo "committed"
   git cat-file -e "origin/$SESSION_BRANCH:docs/handoffs/<file>" && echo "pushed"
   ```

   Both must print before step 6 runs. An unpushed seed inside a per-session worktree exists in exactly one place, and step 6 deletes that place. If the PR is still open at the close, the final status line names the file path **and** the PR number.
4. **Executive brief** — for a session that shipped real work (several PRs/issues, an epic), run `/visual-brief` into the vault (`$CLAUDE_BRIEF_DIR`). Skip for small sessions — say so.
5. **Capture learnings** — run `/learn` for genuinely novel lessons; "nothing novel" is a valid outcome, stated.
6. **Cleanup — gated on step 3** — remove this session's worktrees (leave other sessions' worktrees alone), prune branches only after verifying each had a `MERGED` PR, stop dev daemons/servers started this session, restore any test-env mutations ({{CUSTOMIZE: repo-specific cleanup — daemons to stop, env files that get mutated during testing and must be restored, e.g. remove the marker if none}}).

   **Never remove a worktree that holds this session's seed until step 3's two checks have both printed.** `git worktree remove` refuses on a tree with untracked files; `--force` is exactly the flag that turns that refusal into a silent, unrecoverable delete, and the seed is an untracked file in that tree until it is committed. If either check fails, **skip this step, say so, and leave the worktree standing** — a stale worktree costs disk, a deleted seed costs the next session.

   The seed also needs somewhere to be read from *after* the removal. Before deleting the worktree, resolve which of step 7's two legal paste-lines applies; if it is form (a), confirm it now:

   ```bash
   REPO_ROOT=$(git rev-parse --path-format=absolute --git-common-dir); REPO_ROOT=$(dirname "$REPO_ROOT")
   git -C "$REPO_ROOT" cat-file -e "HEAD:docs/handoffs/<file>" && echo "(a) live in the main checkout"
   ```
7. **Final `**Status:**` line** — the last message ends with the short status and **the one line to paste, which must still resolve after step 6 ran**. Exactly two forms are legal:
   - **(a)** the seed's absolute path in the repo's **main checkout** — legal only once the seed's commit is reachable from the branch that checkout has checked out (the `cat-file -e` in step 6 printed).
   - **(b)** the seed's absolute path **in a worktree step 6 deliberately left standing** — the case when the seed is committed and pushed on a branch that has not landed in the main checkout yet. Name the PR number alongside it, and say the worktree is being kept for that reason.

   A path inside a worktree step 6 removed is not a third form; it is a dead paste-line, and the seed's entire delivery mechanism is that line. Where neither form is available, the fallback is a branch-qualified reference the next session can read from any tree — `git -C <repo> show <branch>:docs/handoffs/<file>` — stated as such, never dressed up as a path. If more waves remain, the relaunch task names that exact dated file — never a pointer that can move.

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

- **Handoff directory** — where this repo keeps its append-only session seeds, default
  `docs/handoffs/` (Resume step 6 **and** End step 1 — one marker text, two sites; keep them
  identical, and add any ledger/queue path this repo carries to the Resume-step copy).
- **Repo-specific cleanup** — daemons, test-env restores (End step 6).
