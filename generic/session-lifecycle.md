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
5. **Global-conventions sync** — `~/.claude/CLAUDE.md` and `assets/global-CLAUDE.md` in the registry
   are **both authored**, so they drift in both directions at once and a bare `diff -q` cannot say
   which side is right. Run the class-split check instead:

   ```bash
   python3 ~/.claude/scripts/fleet-check.py    # 0 = floor intact · 1 = FLOOR drift · 2 = could not verify
   ```

   Exit 1 is a stop: reconcile the named floor rule before long work (land the machine's delta in
   the registry, then copy out). Exit 0 with default drift is information — it names the direction,
   act on it when convenient. Exit 2 means it could not see the registry copy (the `git fetch` is a
   hard precondition, never softened) — that is *not* agreement; say so rather than proceeding as if
   it passed.

   Then `/next` itself, which is distributed **verbatim** (no rule classes, no `{{CUSTOMIZE}}`), so a
   plain `diff -q` is its whole drift detector — and **a missing file is not drift**:

   ```bash
   if [ ! -f ~/.claude/commands/next.md ]; then
     echo "/next is not installed on this machine — cp assets/next.md ~/.claude/commands/next.md"
   else
     diff -q ~/.claude/commands/next.md ~/Projects/skill-templates/assets/next.md
   fi
   ```

   Without the guard `diff` just errors on a machine that has never installed `/next`, which reads
   as a failed check rather than as "install it". Install (or copy) first, then compare.
6. **Prior-session state** — read this scope's seed, `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` (default dir `~/Obsidian/no-it-all/handoffs/`), plus {{CUSTOMIZE: any session ledger or queue file this repo keeps, e.g. `autonomous-session-<date>.md`, `scratchpad/autonomous-queue.json` — or remove this list if the repo has none}}. `<scope>` is the main worktree's directory basename, resolved from git — `python3 ~/.claude/scripts/session-seed.py path` prints the exact file to open — so every worktree of a repo resolves to the same seed and no `$PWD` test is involved. There is exactly **one** canonical seed per scope, so nothing has to be ranked: no newest-wins rule, no mtime, no tie to resolve. Sibling files named `NEXT-<scope>.<UTC>-<sid>.md`, or `…-<sid>-<n>.md` when two archives landed in one second, are **archived** seeds — a previous session's, parked when this one collided with it. Do not read them by default, but if the canonical seed is missing, say so and list them: the newest archive is usually an unconsumed handoff, and a session that silently starts from nothing is how work gets repeated. Read the seed's header and TL;DR plus the ledger's STATE header — not the full history. Seeds are **perishable**: each is superseded by the next, and anything in one still worth reading after it is consumed belongs in `docs/records/`, linked from the seed. `/catchup` is the component skill for reconstructing a prior session where installed.
7. **Verify the last claimed merge** — if the prior session's notes claim a merge, confirm it (`gh pr view <n>` reports `MERGED`) before building on it. State is re-derived, not trusted.

Then state, in one short block: branch/HEAD, dirty files, open PRs (mine/others), drifted skills, and what the session is picking up.

### During the session

- **Every user-facing message ends with the mechanical `**Status:**` block** — a `**Status:**` lead on its own line, then four fixed slots as one bullet each (done · in flight · blocked · DECISION), `none` when empty. This is the global reporting rule in `~/.claude/CLAUDE.md` ("End-of-message summary"); follow it from there — do not restate or fork it here, and in particular do not emit the retired one-line `·`-separated form. Subagents' final messages carry their own `**Status:**` block.
- **Session boundaries** — the global `~/.claude/CLAUDE.md` "Session boundaries" section governs when to end this session and restart fresh (wave boundaries, second compaction, work-class switches — the numeric context ceiling is retired). Follow it from there.
- **Assert the branch before you write.** `git` state is global to the working copy and several sessions share it, so re-check `git branch --show-current` against `SESSION_BRANCH` (claimed at start, step 2) **immediately before your first edit** and **again immediately before staging**. A checkout from earlier in the session proves nothing — another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember; if HEAD has moved, stop and re-establish the branch before writing anything.
- **Stage explicit paths.** `git status --short`, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a` — a foreign file in a shared tree is the normal case, so a bulk add commits someone else's work into your PR. `-u` is not the safe one: it restages every *tracked* file whose worktree copy differs, including files a clean/smudge filter rewrote without you touching them — that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as an edit.
- **Prefer a per-session worktree.** Where the harness gives this session its own `git worktree`, use it; where it does not, the two rules above are the whole of the protection and apply verbatim.

### The interactive flow — two wait points

An **interactive** session (an operator is watching) stops and waits on the user at exactly **two** points. Every other transition is the agent's to make.

1. **Scope, at the start.** Seed pasted → agent states the next task and its scope → operator approves or redirects. One wait, at the top.
2. **Merge, at the end.** After the review pipeline the repo requires passes clean, ask **once**: "gates green — merge?". This is the one mid-flow wait with catch value; the repo's own `CLAUDE.md` defines that gate — what must be reviewed, which checks must be green, how threads are resolved — so follow it from there rather than restating the criteria here.

**Between those two, do not ask — act.** Specifically, never ask:

- *"want a PR?"* — PR-first is already the workflow; open it.
- *"merge or review?"* — review is mandatory; run it, never offer to skip it.
- *"shall I fix the findings?"* — fix them, re-run the gates, and return to wait point 2.

Each of those asks permission for something policy already requires, so it buys a stall with no catch value — the safety lives in the review gate, not in the questions. A **genuine** decision the agent cannot resolve — a design fork, a real scope question — is not one of these: it goes in the `DECISION` slot of the `**Status:**` block and the agent continues other work while it waits, rather than blocking on it.

**Unattended sessions have zero mid-flow waits** *where the repo grants an unattended-merge authority*. Wait point 2 is then replaced by that authority's gates — the same review-and-checks bar, self-verified instead of operator-confirmed — exactly as the repo's own `CLAUDE.md` defines it. Follow it from there; never assume an authority a repo did not grant.

**Clearing the session** follows the global "Session boundaries" rule; the operational test that a boundary is genuinely *clean* is three clauses, **all** of which must hold: (a) every session PR is **merged and verified on `origin/main`** — not merely "merged"; (b) nothing is in flight and every follow-on is filed; (c) the next task is a different work class or needs almost none of the loaded context. Continue past a boundary only for a **dependent chain** — the next PR needs this session's context. Never stack **independent, same-class** waves past a boundary: that is the one pattern the flow audit measured as pure overhead, where a session overstayed and carried ~15% idle wall-clock. Second compaction or work-class switch → clear regardless.

> Codified from a 9-session flow audit (skill-templates#237): the zero-wait configuration ran 19 PRs with 0 rollbacks and 9/9 clean endings, while the only measured overhead came from overstaying a boundary, not from asking questions. The cost of a Path-B wait is still unmeasured — when a mid-flow wait *does* happen, timestamp the ask and the reply in the status flow so the counterfactual can close.

### Session end — the checklist

Run in order; skip a step only by saying so with a reason. **Steps 1–3 are the two ending artifacts and the one check that proves the seed the next session opens is the one this session wrote; a session that skips either artifact has not ended.**

1. **Handoff seed (artifact ②)** — **the seed is written outside every worktree, at an absolute path:** `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, default dir `~/Obsidian/no-it-all/handoffs/`. It holds what shipped, what remains, and *why* each remaining item is blocked or deferred. Not in the repo, not in this session's worktree, not on a branch — an absolute path outside every *session's* workspace has **no worktree to be torn down with, no branch to be unreachable from, and no index to be confused with**, which is why nothing downstream has to be gated on it. Three earlier attempts to keep the seed inside a session's own workspace failed on exactly those surfaces, the last of them on a "committed" proof that had only staged the file. Read the property precisely: the default handoff dir is itself a git repo (the vault is versioned, and should be), and that takes nothing away — what the seed must be outside is the tree *this session* edits, branches and tears down, which is exactly what the write checks it against.

   **One command writes it.** It resolves the scope, resolves this session's id, archives whatever it collides with, writes the seed, and proves the result — all of it in `session-seed.py`, none of it transcribed here:

   ```bash
   python3 ~/.claude/scripts/session-seed.py write \
     --picks-up-at "issue #209 — assets/scripts has no test coverage" \
     --boundary-reason "wave boundary" \
     --body-file /tmp/handoff-body.md
   ```

   It prints `seed: <absolute path>` — which is step 7's one line to paste — or a `REFUSE:` line with a nonzero exit. **A REFUSE never destroys an existing seed**: the archive is what earns the right to write, so a failed archive aborts before the write. It does *not* mean nothing happened, and reading it that way is the trap — the last thing the write does is run step 3's proof, so a REFUSE from *there* arrives after the seed is already on disk. Do not infer from the exit code; read the lines above it, which say what was done and in what order: `archived: <path>` iff an incumbent was moved, then `seed: <path>` iff the proof passed. Add `--topic <name>` for a fleet session with a named topic; never anywhere else.

   `--body-file` is the seed's body, written first to a scratch path (`-` reads stdin). Omit it and the script writes a skeleton to fill in: `## STATE` (branch/HEAD, working tree, CI, tests, open PRs and issues) · a **"Verify before building on any of this — re-derive, don't trust"** block where every command carries its expected answer as a comment · `## TL;DR — what shipped` · `## Today's task` · `## Left undone, deliberately`.

   **Why a script and not a snippet.** This step was prose containing bash, transcribed and executed by an agent, and tested by extracting the fenced blocks back out and running them. Five rounds of review each fixed their findings and each introduced new ones, because every fix added more shell to a document: scope resolution, path sanitising, collision archiving, id resolution and a re-derivation of all three appeared twice, in near-copies that drifted. The logic is one implementation now, with its own test suite; what stays here is the doctrine, which is the part a customized copy must not be able to drop. **Do not hand-write the seed** or re-derive the scope, the id, the archive name or the proof by hand at the boundary — a second implementation is the drift that cost five rounds.

   **`<scope>` is the main worktree's directory basename**, resolved from git. Not the origin slug, which two different repos can share (`chroxy` and `chroxy-daemon` do), and never a `$PWD` prefix test, which reports the wrong answer from a linked worktree — where sessions actually run. Every worktree, subdirectory and detached HEAD of one repo therefore resolves to one seed. A session that is not in a repo at all is `fleet`, or `NEXT-fleet-<topic>.md` with `--topic`. Anything that is *not* "this is not a git repository" — a dubious-ownership refusal, a git too old for the flag — is a REFUSE rather than a fallback to `fleet`: filing the seed under a scope nobody reads looks exactly like success.

   **The session id is `--session`, else `$CLAUDE_CODE_SESSION_ID`, else a REFUSE.** There is no third source, and specifically no "most recently modified transcript" pick: that is fleet-wide, so on a machine running several sessions it names whichever session last wrote a turn — neither stable across the two places the id is used nor necessarily this session at all. A session that cannot name itself writes nothing: an anonymous seed is one the next session cannot archive (it reads as `unknown`) and this one cannot prove, so an unresolvable id is a reason to halt, not a value to carry. `$CLAUDE_CODE_SESSION_ID` truncated to 8 characters is exactly what `usage-benchmark-row.py` prints in artifact ①'s id column, so the seed and the benchmark row name the session with the same string.

   **Archive on collide — never overwrite a seed this session did not write.** If the canonical file exists carrying a different `session:`, the incumbent is renamed to `NEXT-<scope>.<UTC>-<sid>.md` (`-<n>` appended when two archives land in one second) and only then is the seed written. **The archive is what earns the right to write, so the write is conditional on it: an archive that fails aborts the step rather than falling through.** Unchecked, this destroys the incumbent with no race and no hostile actor — `rename(2)` needs the write bit on the *directory* while overwriting a file inside it does not, so a read-only handoff dir silently turns "archive then write" into "write over it". Re-running the same session's own write is not a collision and overwrites in place.

   Archiving preserves the incumbent byte for byte and frees the canonical name immediately, which is what keeps *"one line to paste"* working. Per-session-unique filenames would preserve the old seed too, and would destroy that affordance: the next session would have to be told which of N files to read, which is the thing the seed exists to avoid.

   Required header — `session:` is what makes archive-on-collide decidable *and* what step 3 reads back, so it is never decorative; `picks_up_at:` is the only line `/next` quotes:

   ```markdown
   ---
   type: handoff
   date: 2026-08-11T21:40Z          # full UTC timestamp
   scope: skill-templates           # the main worktree's directory basename, or fleet
   session: a1b2c3d4                # this session's id
   picks_up_at: "issue #205 — extract the seed logic into a tested script"
   sensitivity: public              # public | vault
   ---
   ```

   The script generates all of it; `session-seed.py header <path>` reads it back. The seed's own home is private, so `sensitivity: vault` needs no separate outlet; what still may not go in is a secret, in any file, ever.

2. **Benchmark row (artifact ①)** — append this session's row to `~/Obsidian/no-it-all/briefs/usage-benchmark.md` via `python3 ~/.claude/scripts/usage-benchmark-row.py`, replacing the placeholder with a one-line workload note. If the script resolves to a session ID that already has a row, **neither append nor overwrite** — the transcript counters are cumulative, so both actions corrupt the record; say so instead.
3. **Prove the seed the next session will read is *this* session's.** Step 1 already ran this proof and its verdict was step 1's exit code; run it again after anything that could have moved underneath you, and to re-print the paste line:

   ```bash
   python3 ~/.claude/scripts/session-seed.py verify     # + the same --topic the write used
   ```

   `seed:` must print and `REFUSE:` must not. The proof re-derives the scope, the handoff dir and the path from scratch in a fresh process — it is handed nothing the write computed — and then reads the seed's `session:` back. **Existence is not the property worth proving**: a file is at the canonical path in every failure mode this checklist has, and the two that matter fail in different halves.

   - **Wrong file.** The scope was keyed on something other than the main worktree — the *linked* worktree's basename is the near miss — so a perfectly well-formed seed sits at a path nobody opens while the previous session's stale seed still occupies the canonical name. Only re-deriving the scope catches this. **A check handed the write's own path reads back the very file the write misfiled, finds its own id, and passes — structurally incapable of failing for the mistake it exists to catch.**
   - **Right file, wrong author.** The archive was destroyed and overwritten, so the canonical path holds someone else's seed. Reading `session:` back is what distinguishes "I wrote the seed" from "a seed exists": the same field the archive decides on, used a second time as the proof.

   A bare `[ -f "$SEED" ]` calls both a pass, and an unresolvable session id is a REFUSE too — otherwise an empty id matches a seed with no `session:` line and the check passes on nothing. There is no commit to make, no branch to push, and no `cat-file` to run: the previous three rounds of this checklist all failed inside that machinery. Whether the vault repo itself is committed and pushed is ordinary vault hygiene, not a precondition — the seed already exists at a stable absolute path that nothing this session does can delete.
4. **Executive brief** — for a session that shipped real work (several PRs/issues, an epic), run `/visual-brief` into the vault (`$CLAUDE_BRIEF_DIR`). Skip for small sessions — say so.
5. **Capture learnings** — run `/learn` for genuinely novel lessons; "nothing novel" is a valid outcome, stated.
6. **Cleanup** — remove this session's worktrees (leave other sessions' worktrees alone), prune branches only after verifying each had a `MERGED` PR, stop dev daemons/servers started this session, restore any test-env mutations ({{CUSTOMIZE: repo-specific cleanup — daemons to stop, env files that get mutated during testing and must be restored, e.g. remove the marker if none}}).

   This step is **ungated on purpose**: `git worktree remove --force` deletes untracked files without prompting, and the seed is not in any worktree to be deleted. Anything else durable that got written into a worktree is committed and pushed before removal, or it is lost — so do not write durable things there.
7. **Final `**Status:**` block** — the last message ends with the mechanical status block and **the one line to paste**: the seed's absolute path, `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, expanded — which is the `seed:` line step 1 printed. There is exactly one legal form, it is the same string at every boundary of this scope, and cleanup cannot invalidate it — which is what makes a relaunch task safe to write in advance. If a PR is still open at the close, name its number alongside the path.

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

**Two machine-level scripts** back the End steps, and they are bootstrapped once per machine from
the registry rather than installed per repo — both End step 1 and `/next` call the same copy, which
is the point:

```bash
cp assets/scripts/session-seed.py assets/scripts/usage-benchmark-row.py ~/.claude/scripts/
```

`session-seed.py` owns artifact ② (scope, session id, archive-on-collide, the write, the proof);
`usage-benchmark-row.py` emits artifact ①'s row. Each ships with a sibling `<name>.test.sh` in
the registry, run by CI, and that is where their behaviour is pinned — this file states the
doctrine, not the code. Bootstrap both or neither: a machine with a stale
`usage-benchmark-row.py` writes step 2's row on a different scale from every row above it, and
step 2 forbids repairing it.

## Customization Points

Lines and blocks marked `{{CUSTOMIZE}}` need repo-specific adaptation:

- **Ledger / queue paths** — the repo-local state files a resuming session reads *alongside* the
  seed (Resume step 6). The seed's own path is **not** customizable: it is
  `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` in every repo, which is what lets one relaunch task, one
  `/next` dispatcher, and one paste-line work across the whole fleet.
- **Repo-specific cleanup** — daemons, test-env restores (End step 6).
