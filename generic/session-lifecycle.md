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
   it passed. Check `~/.claude/commands/next.md` against `~/Projects/skill-templates/assets/next.md`
   with `diff -q`: it is distributed verbatim, carries no rule classes, and that diff is its only
   drift detector.
6. **Prior-session state** — read this scope's seed, `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` (default dir `~/Obsidian/no-it-all/handoffs/`), plus {{CUSTOMIZE: any session ledger or queue file this repo keeps, e.g. `autonomous-session-<date>.md`, `scratchpad/autonomous-queue.json` — or remove this list if the repo has none}}. `<scope>` is the main worktree's directory basename, resolved from git (End step 1 carries the snippet), so every worktree of a repo resolves to the same seed and no `$PWD` test is involved. There is exactly **one** canonical seed per scope, so nothing has to be ranked: no newest-wins rule, no mtime, no tie to resolve. Sibling files named `NEXT-<scope>.<UTC>-<sid>.md` are **archived** seeds — a previous session's, parked when this one collided with it. Do not read them by default, but if the canonical seed is missing, say so and list them: the newest archive is usually an unconsumed handoff, and a session that silently starts from nothing is how work gets repeated. Read the seed's header and TL;DR plus the ledger's STATE header — not the full history. Seeds are **perishable**: each is superseded by the next, and anything in one still worth reading after it is consumed belongs in `docs/records/`, linked from the seed. `/catchup` is the component skill for reconstructing a prior session where installed.
7. **Verify the last claimed merge** — if the prior session's notes claim a merge, confirm it (`gh pr view <n>` reports `MERGED`) before building on it. State is re-derived, not trusted.

Then state, in one short block: branch/HEAD, dirty files, open PRs (mine/others), drifted skills, and what the session is picking up.

### During the session

- **Every user-facing message ends with the mechanical `**Status:**` line** — four fixed slots (done · in flight · blocked · DECISION), `none` when empty. This is the global reporting rule in `~/.claude/CLAUDE.md` ("End-of-message summary"); follow it from there — do not restate or fork it here. Subagents' final messages carry their own `**Status:**` line.
- **Session boundaries** — the global `~/.claude/CLAUDE.md` "Session boundaries" section governs when to end this session and restart fresh (wave boundaries, ~150K main-thread context, second compaction, work-class switches). Follow it from there.
- **Assert the branch before you write.** `git` state is global to the working copy and several sessions share it, so re-check `git branch --show-current` against `SESSION_BRANCH` (claimed at start, step 2) **immediately before your first edit** and **again immediately before staging**. A checkout from earlier in the session proves nothing — another session can move HEAD in between, and your edits then land on its branch. Re-check, never remember; if HEAD has moved, stop and re-establish the branch before writing anything.
- **Stage explicit paths.** `git status --short`, then `git add` the files you changed, **by name**. Never `git add -A`, `git add .`, `git add -u`, `git add <dir>/`, or `git commit -a` — a foreign file in a shared tree is the normal case, so a bulk add commits someone else's work into your PR. `-u` is not the safe one: it restages every *tracked* file whose worktree copy differs, including files a clean/smudge filter rewrote without you touching them — that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer and committed it as an edit.
- **Prefer a per-session worktree.** Where the harness gives this session its own `git worktree`, use it; where it does not, the two rules above are the whole of the protection and apply verbatim.

### Session end — the checklist

Run in order; skip a step only by saying so with a reason. **Steps 1–3 are the two ending artifacts and the one check that proves the seed the next session opens is the one this session wrote; a session that skips either artifact has not ended.**

1. **Handoff seed (artifact ②)** — **the seed is written outside every worktree, at an absolute path:** `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, default dir `~/Obsidian/no-it-all/handoffs/`. It holds what shipped, what remains, and *why* each remaining item is blocked or deferred. Not in the repo, not in this session's worktree, not on a branch — an absolute path outside every git workspace has **no worktree to be torn down with, no branch to be unreachable from, and no index to be confused with**, which is why nothing downstream has to be gated on it. Three earlier attempts to keep the seed inside a workspace failed on exactly those surfaces, the last of them on a "committed" proof that had only staged the file.

   `<scope>` is the **main worktree's directory basename**, resolved from git — not the origin slug, which two different repos can share (`chroxy` and `chroxy-daemon` do), and never a `$PWD` prefix test, which reports the wrong answer from a linked worktree:

   ```bash
   common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
   if [ -n "$common" ]; then SCOPE=$(basename "$(dirname "$common")"); else SCOPE=fleet; fi
   HANDOFF_DIR=${CLAUDE_HANDOFF_DIR:-$HOME/Obsidian/no-it-all/handoffs}
   SEED="$HANDOFF_DIR/NEXT-$SCOPE.md"
   ```

   A session that is not in a repo at all resolves to `fleet` — or `NEXT-fleet-<topic>.md` when it has a named topic. Every worktree, subdirectory, and detached HEAD of one repo resolves to one seed.

   **Archive on collide — never overwrite a seed this session did not write.** Before writing, if the canonical file exists and its `session:` is not this session's, rename the incumbent out of the way, then write. **The archive is what earns the right to write, so the write is conditional on it: an `mv` that fails aborts the step rather than falling through.** Unchecked, this destroys the incumbent without a race and without a hostile actor — `rename(2)` needs the write bit on the *directory* while overwriting a file inside it does not, so a read-only handoff dir silently turns "archive then write" into "write over it".

   ```bash
   if [ -f "$SEED" ]; then
     prev=$(awk 'NR>1 && /^---[[:space:]]*$/ {exit}
                 /^session:[[:space:]]*/ { sub(/^session:[[:space:]]*/,"");
                                           sub(/[[:space:]]*#.*$/,"");
                                           sub(/[[:space:]]+$/,""); print; exit }' "$SEED")
     prev=${prev#\"}; prev=${prev%\"}; prev=${prev#\'}; prev=${prev%\'}   # quoted scalars are legal YAML
     [ -n "$prev" ] || prev=unknown       # unidentifiable is a reason to keep it, not to clobber it
     if [ "$prev" != "$SID" ]; then
       # The incumbent's own bytes must never steer the path that protects it: reduce
       # the id to one filename component before it is interpolated anywhere.
       slug=$(printf '%s' "$prev" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)
       case "$slug" in ''|.|..) slug=unknown;; esac
       mv "$SEED" "$HANDOFF_DIR/NEXT-$SCOPE.$(date -u +%Y%m%dT%H%M%SZ)-$slug.md" || {
         echo "REFUSE: could not archive $SEED — the incumbent stays, the seed is not written"
         exit 1
       }
     fi
   fi
   # then write $SEED
   ```

   The guard and the sanitiser fix different halves and neither replaces the other. The guard is what makes the incumbent safe: any `mv` that fails now stops the step instead of being followed by the write. The sanitiser is what keeps the step *usable* — `session:` is sourced from an id documented as `[session-id-or-jsonl-path]`, so a slash in one is a plausible agent choice rather than an attack, and interpolated raw it names a directory that does not exist. With the guard alone that id is no longer data loss, but it is a session that can never write a seed at all, on a value it read out of someone else's file. Reduce the id to one filename component and the archive path is always constructible. (Containment is separately structural: `$slug` sits behind the `NEXT-$SCOPE.<UTC>-` prefix, so it is never the leading component of a path element and a `..` in it cannot climb anywhere. Keep it in that position.)

   `mv` preserves the incumbent byte for byte, and the canonical name is free again immediately — so *"one line to paste"* keeps working. Per-session-unique filenames would preserve the old seed too, and would destroy that affordance: the next session would have to be told which of N files to read, which is the thing the seed exists to avoid. Re-running the same session's own write is not a collision and overwrites in place.

   Required header — the `session:` field is what makes archive-on-collide decidable *and* what step 3 reads back to prove this session wrote the seed, so it is never decorative; `picks_up_at:` is the only line `/next` quotes:

   ```markdown
   ---
   type: handoff
   date: 2026-08-11T21:40Z          # full UTC timestamp
   scope: skill-templates           # the main worktree's directory basename, or fleet
   session: a1b2c3d4                # this session's id — the one usage-benchmark-row.py prints
   picks_up_at: "issue #205 — implement the layered continuity scheme"
   sensitivity: public              # public | vault
   ---
   # Handoff — <what this session actually landed>

   - **Boundary reason:** <which global session-boundary rule fired>
   - **Picks up at:** <the one thing the next session starts on>
   ```

   Then, in order: `## STATE` (branch/HEAD, working tree, CI, tests, open PRs/issues) · a **"Verify before building on any of this — re-derive, don't trust"** bash block where every command carries its expected answer as a comment · `## TL;DR — what shipped` · the next task · `## Left undone, deliberately`.

   The seed's own home is private, so `sensitivity: vault` needs no separate outlet; what still may not go in is a secret, in any file, ever.

2. **Benchmark row (artifact ①)** — append this session's row to `~/Obsidian/no-it-all/briefs/usage-benchmark.md` via `python3 ~/.claude/scripts/usage-benchmark-row.py`, replacing the placeholder with a one-line workload note. If the script resolves to a session ID that already has a row, **neither append nor overwrite** — the transcript counters are cumulative, so both actions corrupt the record; say so instead.
3. **Prove the seed the next session will read is *this* session's** — two checks, authorship then location, and neither is about git:

   ```bash
   mine=$(awk 'NR>1 && /^---[[:space:]]*$/ {exit}
               /^session:[[:space:]]*/ { sub(/^session:[[:space:]]*/,"");
                                         sub(/[[:space:]]*#.*$/,"");
                                         sub(/[[:space:]]+$/,""); print; exit }' "$SEED" 2>/dev/null)
   mine=${mine#\"}; mine=${mine%\"}; mine=${mine#\'}; mine=${mine%\'}
   if [ -n "$SID" ] && [ "$mine" = "$SID" ]; then
     echo "seed: $SEED"
   else
     echo "REFUSE: $SEED carries session '${mine:-none}', not this session's '${SID:-unset}'"
   fi
   TREE=$(git rev-parse --show-toplevel 2>/dev/null)
   case "$SEED" in "${TREE:-/nonexistent}"/*) echo "REFUSE: the seed is inside this worktree";; esac
   ```

   `seed:` must print and `REFUSE:` must not. **Existence is not the property worth proving** — a file is at `$SEED` in every failure mode this checklist has: when step 1's archive was destroyed and overwritten, and equally when this session keyed `<scope>` on the *linked* worktree's basename instead of the main worktree's, wrote `NEXT-<wrong>.md`, and never touched the canonical file the next session will actually open. Both leave the previous session's stale seed sitting there, and `[ -f "$SEED" ]` calls both a pass. Reading the `session:` field back is what distinguishes "I wrote the seed" from "a seed exists": it is the same field step 1 archives on, used a second time as the proof rather than only as the decision. An unset `$SID` is a REFUSE too — otherwise an empty id matches a seed with no `session:` line and the check passes on nothing. There is no commit to make, no branch to push, and no `cat-file` to run — the previous three rounds of this checklist all failed inside that machinery. Whether the vault repo itself is committed and pushed is ordinary vault hygiene, not a precondition: the seed already exists at a stable absolute path that nothing this session does can delete.
4. **Executive brief** — for a session that shipped real work (several PRs/issues, an epic), run `/visual-brief` into the vault (`$CLAUDE_BRIEF_DIR`). Skip for small sessions — say so.
5. **Capture learnings** — run `/learn` for genuinely novel lessons; "nothing novel" is a valid outcome, stated.
6. **Cleanup** — remove this session's worktrees (leave other sessions' worktrees alone), prune branches only after verifying each had a `MERGED` PR, stop dev daemons/servers started this session, restore any test-env mutations ({{CUSTOMIZE: repo-specific cleanup — daemons to stop, env files that get mutated during testing and must be restored, e.g. remove the marker if none}}).

   This step is **ungated on purpose**: `git worktree remove --force` deletes untracked files without prompting, and the seed is not in any worktree to be deleted. Anything else durable that got written into a worktree is committed and pushed before removal, or it is lost — so do not write durable things there.
7. **Final `**Status:**` line** — the last message ends with the short status and **the one line to paste**: the seed's absolute path, `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, expanded. There is exactly one legal form, it is the same string at every boundary of this scope, and cleanup cannot invalidate it — which is what makes a relaunch task safe to write in advance. If a PR is still open at the close, name its number alongside the path.

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

- **Ledger / queue paths** — the repo-local state files a resuming session reads *alongside* the
  seed (Resume step 6). The seed's own path is **not** customizable: it is
  `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` in every repo, which is what lets one relaunch task, one
  `/next` dispatcher, and one paste-line work across the whole fleet.
- **Repo-specific cleanup** — daemons, test-env restores (End step 6).
