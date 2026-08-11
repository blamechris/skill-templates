# /next

Answer **"what should I work on?"** by *deriving* the answer at the moment of asking, never by reading a status file someone maintained. Location decides scope: inside a repo this hands straight to `/session-lifecycle start` with that scope's seed; outside one it ranks the fleet from the seeds in `$CLAUDE_HANDOFF_DIR` plus the hand-written `~/Projects/PRIORITIES.md`, and ends every row with the one line to paste. It reads; it never writes.

This file is distributed **verbatim** from the `skill-templates` registry (`assets/next.md` → `~/.claude/commands/next.md`) — it carries no `{{CUSTOMIZE}}` markers and is not customized per repo. Its drift detector is the `diff -q` in `/session-lifecycle`'s Resume step 5; there is no CI gate behind it.

## Arguments

- `$ARGUMENTS` — optional. A path to a handoff seed (`…/NEXT-<scope>.md`, or an archived
  `…/NEXT-<scope>.<UTC>-<sid>.md`). Given one, `/next` reads that file and stops — that is the
  relauncher case, where a scheduled task names the exact file it wants resumed. Empty is the
  normal invocation.

## Instructions

### The invariant that licenses everything below

**The dispatcher ranks; the repo re-derives.** Nothing downstream trusts a number `/next`
computed, so a stale dispatcher is structurally harmless — the worst case is a slightly wrong
ranking, never building on false state. That is what buys the right to be cheap: no `gh`, no
network, no cache, header reads only.

### 0. The selection rule — first match wins

**1 — the prompt names a seed file.** If `$ARGUMENTS` is a path to an existing file, read it and
stop. Do not rank, do not enumerate, do not second-guess it: a relaunch task naming a seed is
asking for that seed.

```bash
[ -f "$ARGUMENTS" ] && echo "seed given: $ARGUMENTS"
```

**2 — repo scope.** Ask the script that owns the seed. It resolves via **git, never a `$PWD` prefix
match against `~/Projects`** — worktrees routinely live outside `~/Projects` (a linked worktree
under `/private/tmp/...` is the ordinary case on this machine), so a path-prefix test reports
"fleet scope" while sitting inside a repo:

```bash
SCOPE=$(python3 ~/.claude/scripts/session-seed.py scope) || exit 1   # `fleet` outside any repo
SEED=$(python3 ~/.claude/scripts/session-seed.py path)  || exit 1
TREE=$(git rev-parse --show-toplevel 2>/dev/null)                    # where I am, if anywhere
```

**The dispatcher does not re-implement the key; the writer and the reader must agree by
construction.** Two hand-written copies of this derivation is how the fleet acquired a defect that
only showed up on one side of it, and there is exactly one implementation now — the same one End
step 1 writes through. Its properties, each of which something simpler gets wrong:

- **`--git-common-dir`, with `--path-format=absolute`.** It points at the *shared* `.git` — the
  repo's identity — from the main checkout, a nested subdirectory, a detached HEAD and every
  linked worktree alike. The bare form returns a relative `.git` from a main checkout, which
  cannot be `dirname`'d into a repo root, so the flag is an addition to the test rather than a
  substitute for it.
- **The directory basename, not the origin slug.** `chroxy` and `chroxy-daemon` share one origin
  URL and are separate projects with separate work; keying on the remote would merge their seeds
  and let each overwrite the other's.
- **Outside any repo the scope is `fleet`** — the same word the fleet seed is named for, so an
  orchestrator session and this dispatcher agree without a special case. A session with a named
  topic uses `NEXT-fleet-<topic>.md`, which `session-seed.py path --topic <name>` prints.
- **A git failure that is not "not a git repository" is a REFUSE, not a `fleet` fallback**, and it
  exits nonzero — hence the `|| exit 1`. Ranking the fleet from inside a repo the dispatcher
  could not identify is a confident wrong answer.

In repo scope, read `$SEED` and hand off to `/session-lifecycle start`. Exactly one canonical
seed exists per scope, so there is nothing to rank and nothing to tie-break. If it is absent, say
so and list any `NEXT-$SCOPE.*.md` archives — the newest of those is often an unconsumed handoff —
then fall back to `git log`.

**3 — fleet scope.** Everything below.

### 1. Fleet intent — `~/Projects/PRIORITIES.md`

Print its age on **every** run, first line of the output. It is hand-written by the owner and
only by the owner: `/next` never writes it, never reformats it, never proposes an edit beyond
the one word below.

```bash
PRI=~/Projects/PRIORITIES.md
if [ -f "$PRI" ]; then
  # BSD and GNU `stat` disagree on BOTH flags, and they disagree SILENTLY in the
  # worst direction: `stat -f` on GNU asks for FILESYSTEM stats, so it neither
  # errors usefully nor returns an mtime — it prints an unrelated number that then
  # formats as a plausible date. Probe once, and never mix the two spellings.
  mtime=$(stat -c %Y "$PRI" 2>/dev/null || stat -f %m "$PRI")
  age=$(( ( $(date +%s) - mtime ) / 86400 ))
  printf 'PRIORITIES.md — last edited %s (%s days ago)%s\n' \
    "$(date -u -d "@$mtime" +%Y-%m-%d 2>/dev/null || date -u -r "$mtime" +%Y-%m-%d)" "$age" \
    "$( [ "$age" -gt 14 ] && echo ' — stale; worth two minutes' )"
  cat "$PRI"
fi
```

Format: 3–10 lines of free prose, one repo per line, order = priority. Extract only the repo
names and their order; pass anything else on the line through verbatim as that row's annotation.
It has no schema, no generator and no validator, and it must stay writable by hand in under two
minutes — if it ever takes longer, the intent layer is overbuilt.

**Missing?** Print this starter template, then continue without it — a missing intent file
degrades the ranking, it does not stop the run:

```markdown
# Priorities — 2026-08-11
1. stock-keep — vertical slice; nothing else ships first
2. aeolus — PR #117 needs my review before anything else moves
3. skill-templates — continuity + #207/#208/#209, then quiet
- Parked: duskwright, dockkeeper (held), website refresh
```

### 2. Enumerate — the seeds first, the checkouts second

**The seeds are the fleet's state, and they all live in one directory.** No repo is walked to
find them, no branch is consulted, and a repo that is not cloned on this machine still has a seed
if a session ever ended on it:

```bash
python3 ~/.claude/scripts/session-seed.py list        # scope <TAB> date <TAB> path, one row per scope
python3 ~/.claude/scripts/session-seed.py list --archives   # only if a canonical seed is missing
```

**Archives are history and are never ranked**, and the discriminator is not "the name contains a
dot": `blamechris.github.io` is a legal directory basename and therefore a legal scope key. An
archive is the timestamped suffix `NEXT-<scope>.<UTC>-<sid>.md`, and that rule lives in the script
alongside the sanitiser that produces those names — one definition, so the writer cannot mint a
name the reader misclassifies. It did once: a sanitiser that permitted `.` in the `<sid>` position
produced archives this listing read back as canonical seeds, hanging a phantom scope off the fleet.

**A seed with no parseable `date:` is UNDATED, not old.** Order it by nothing: list it in a
separate *"undated seeds"* group with its scope and path, and say the ranking could not place it.
Most seeds written before this convention carry no frontmatter at all, and an empty field sorts
before every digit — so "sort and move on" silently ranks exactly the seeds most likely to hold
unconsumed work at the bottom of the list. That is the ranking bug this group exists to prevent,
not a cosmetic detail. **Never mtime**: the vault is a git repo, and a fresh clone of it would
order every seed by checkout order.

**Then the checkouts**, for the recency fallback and for saying what branch each project is
parked on. `~/Projects/*/` containing a `.git` entry, **depth 1 only** — depth 1 is what keeps
`<repo>/.claude/worktrees/*`, of which one repo can have several live at once, out of the listing.
`-e` rather than `-d` because a linked worktree's `.git` is a file:

```bash
for dd in ~/Projects/*/; do
  [ -e "$dd.git" ] || continue
  br=$(git -C "$dd" branch --show-current 2>/dev/null); [ -n "$br" ] || br='(detached)'
  def=$(git -C "$dd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  def=${def#origin/}; [ -n "$def" ] || def='(default unknown)'   # no `remote set-head` here
  printf '%s\t%s\t%s\n' "${dd%/}" "$br" "$def"
done
```

No `gh`, no network, no GitHub API. A repo with neither a seed nor a local clone cannot be
ranked — a deliberate consequence of staying cheap, and worth saying out loud when the owner asks
about a project that did not appear.

### 3. One header per seed — and nothing more

`head -20` of each canonical seed: frontmatter + H1 + the `Picks up at:` bullet. That is the whole
read. Do not open the body.

**Say which branch the checkout is parked on — every row that has one.** The seed's *path* no
longer depends on it, which is the point of putting seeds in the vault; the seed's *content* still
does. `~/Projects/<scope>` is a shared checkout, other sessions move its HEAD, and several of the
fleet's checkouts sit on feature branches right now — so a seed's verify block, its named branch,
and its PR number are all read against whatever branch that checkout happens to be on. Append
`· checkout on <branch>` to every row that has a local clone, and when `<branch>` is not that
repo's default, say so explicitly. Where the default is `(default unknown)` — a clone that never
ran `git remote set-head` — print the branch and skip the comparison; an unverifiable claim about
which branch is canonical is worse than none. A scope with a seed and no local clone says
`· no local checkout` and is still ranked: the seed is the state.

### 4. Rank

Advisory ordering, in this order:

1. Repos named in `PRIORITIES.md`, in the order they appear there.
2. Remaining scopes with a **dated** seed, by that timestamp, newest first.
3. Remaining repos with a commit in the last 14 days, by commit recency.
4. The rest are **counted, not listed**.

Undated seeds are listed in their own group after the ranked rows — never folded into it, never
dropped. Cap the ranked listing at 8 rows.

### 5. Present — every row ends in its paste-line

```
PRIORITIES.md — last edited 2026-08-08 (3 days ago)

1. stock-keep — seed 2026-08-11T21:40Z (today) · priority #1 · checkout on main
   picks up: issue #209 — assets/scripts has no test coverage
   paste: /Users/blamechris/Obsidian/no-it-all/handoffs/NEXT-stock-keep.md

2. Aeolus — seed 2026-08-11T09:10Z (today) · checkout on feat/117-review-fixes (NOT main)
   picks up: PR #117 — owner must review before merge
   paste: /Users/blamechris/Obsidian/no-it-all/handoffs/NEXT-Aeolus.md

3. chroxy-daemon — seed 2026-08-09T18:02Z (2 days ago) · checkout on main
   picks up: issue #41 — daemon restart loses the socket
   paste: /Users/blamechris/Obsidian/no-it-all/handoffs/NEXT-chroxy-daemon.md

Undated seeds — no parseable `date:`, so the ranking could not place them; read the header
before assuming they are stale:
   duskwright  /Users/blamechris/Obsidian/no-it-all/handoffs/NEXT-duskwright.md

9 other repos: no seed, no commits in 14 days — not listed.

Ranking is advisory. Nothing here is state: /next holds no file, writes no file, and caches
nothing. The scope re-derives on arrival — /session-lifecycle start re-reads the seed, re-runs
git status, and verifies the last claimed merge before building on any of it.
```

The `picks up:` line is the seed's `picks_up_at:` frontmatter value — or, for seeds that have no
frontmatter, its `Picks up at:` bullet — lifted **verbatim**. `/next` does not summarize it, and it
is the only claim about a project's state that leaves this skill. The closing paragraph is
**required output on every run**, not a flourish: it is what tells the reader (and any agent
chaining off this output) that these rows are not authority.

### What `/next` must never do

- **Never write a file.** No index, no cache, no `LATEST.md`, no fleet status board. A
  hand-maintained fleet board goes stale within a day, silently, and re-creates the shared-file
  collision this whole scheme exists to remove. There is no fleet status file: it is derived at
  read time, by this skill, every time.
- **Never emit a PR number, issue state, or CI verdict it computed itself.** Rows carry a path
  and a verbatim `picks_up_at:` line. Anything more invites a downstream step to act on a
  dispatcher's stale reading.
- **Never rewrite, rename, or delete a seed or an archive**, in any scope, for any reason —
  including "tidying up" superseded ones. Archiving is the *writer's* move, made once, at the
  moment of collision; a reader that renames files is a reader that can lose them.
- **Never modify `PRIORITIES.md`.**
- **Never ask GitHub.** Latency and cost for authority the dispatcher does not need.

End the response with the standard mechanical `**Status:**` block.
