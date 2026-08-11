# /next

Answer **"what should I work on?"** by *deriving* the answer at the moment of asking, never by reading a status file someone maintained. Location decides scope: inside a repo this hands straight to `/session-lifecycle start`; outside one it ranks the fleet from each repo's newest `docs/handoffs/` seed plus the hand-written `~/Projects/PRIORITIES.md`, and ends every row with the one line to paste. It reads; it never writes.

This file is distributed **verbatim** from the `skill-templates` registry (`assets/next.md` → `~/.claude/commands/next.md`) — it carries no `{{CUSTOMIZE}}` markers and is not customized per repo. Its drift detector is the `diff -q` in `/session-lifecycle`'s Resume step 5, the same one that guards `global-CLAUDE.md`; there is no CI gate behind it.

## Arguments

- `$ARGUMENTS` — optional. A path to a handoff seed file (`…/docs/handoffs/YYYY-MM-DD-<slug>.md`).
  Given one, `/next` reads that file and stops — that is the relauncher case, where a scheduled
  task names the exact dated file it wants resumed. Empty is the normal invocation.

## Instructions

### The invariant that licenses everything below

**The dispatcher ranks; the repo re-derives.** Nothing downstream trusts a number `/next`
computed, so a stale dispatcher is structurally harmless — the worst case is a slightly wrong
ranking, never building on false state. That is what buys the right to be cheap: no `gh`, no
network, no cache, header reads only.

### 0. The selection rule — first match wins

**1 — the prompt names a seed file.** If `$ARGUMENTS` is a path to an existing file, read it and
stop. Do not rank, do not enumerate, do not second-guess it: a relaunch task naming a dated file
is asking for that file.

```bash
[ -f "$ARGUMENTS" ] && echo "seed given: $ARGUMENTS"
```

**2 — repo scope.** Resolve via **git, never a `$PWD` prefix match against `~/Projects`.**
Worktrees routinely live outside `~/Projects` (a linked worktree under `/private/tmp/...` is the
ordinary case on this machine), so a path-prefix test reports "fleet scope" while sitting inside
a repo. `--git-common-dir` is the test because it points at the *shared* `.git` — which is the
repo's identity — from the main checkout and from every linked worktree alike:

```bash
GIT_COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || GIT_COMMON=
if [ -n "$GIT_COMMON" ]; then
  REPO_ROOT=$(dirname "$GIT_COMMON")     # identity: which repo am I in
  REPO=$(basename "$REPO_ROOT")          # repo identity == the repo directory name
  TREE=$(git rev-parse --show-toplevel)  # where I write: THIS worktree's tree
fi
```

`--path-format=absolute` is an addition to the test, not a substitute for it: the bare form
returns a relative `.git` from a main checkout, which cannot be `dirname`'d into a repo root.
Outside any repo, `git rev-parse` exits 128 and `GIT_COMMON` stays empty — that is branch 3.

In repo scope, hand off to `/session-lifecycle start`, seeded from the newest entry of
`$TREE/docs/handoffs/`. If that directory is absent or empty **in this worktree**, fall back to
`$REPO_ROOT/docs/handoffs/` and say which one you read — a seed committed on another branch is
visible in the main checkout and not here, and silently reading the wrong tree is how a session
picks up the wrong work.

**3 — fleet scope.** Everything below.

### 1. Fleet intent — `~/Projects/PRIORITIES.md`

Print its age on **every** run, first line of the output. It is hand-written by the owner and
only by the owner: `/next` never writes it, never reformats it, never proposes an edit beyond
the one word below.

```bash
PRI=~/Projects/PRIORITIES.md
if [ -f "$PRI" ]; then
  age=$(( ( $(date +%s) - $(stat -f %m "$PRI") ) / 86400 ))   # GNU: stat -c %Y
  printf 'PRIORITIES.md — last edited %s (%s days ago)%s\n' \
    "$(stat -f '%Sm' -t '%Y-%m-%d' "$PRI")" "$age" \
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

### 2. Enumerate the fleet

`~/Projects/*/` containing a `.git` entry, **depth 1 only**, plus any path named in
`PRIORITIES.md`. Depth 1 is load-bearing: it is what keeps `<repo>/.claude/worktrees/*` — of
which one repo can have several live at once — out of the listing. `-e` rather than `-d`
because a linked worktree's `.git` is a file.

Record the **branch each checkout is parked on** while enumerating — it is not decoration, see
below:

```bash
for d in ~/Projects/*/; do
  [ -e "$d.git" ] || continue
  br=$(git -C "$d" branch --show-current 2>/dev/null); [ -n "$br" ] || br='(detached)'
  def=$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  def=${def#origin/}; [ -n "$def" ] || def='(default unknown)'   # no `remote set-head` here
  printf '%s\t%s\t%s\n' "${d%/}" "$br" "$def"
done
```

No `gh`, no network, no GitHub API. A repo that is not cloned locally cannot be ranked — that
is a deliberate consequence of staying cheap, and worth saying out loud in the output when the
owner asks about a repo that did not appear.

### 3. One header per repo — and nothing more

For each repo, find the newest seed in `<repo>/docs/handoffs/`, then read `head -20` of it:
frontmatter + H1 + the `Picks up at:` bullet. That is the whole read. Do not open the body.

**Say which branch you read it from — every row, not just the interesting ones.** Repo scope
already discloses this (§0 branch 2); fleet scope needs it more, not less. `~/Projects/<repo>`
is a *shared* checkout: other sessions move its HEAD, and right now several of the fleet's
checkouts sit on feature branches. A seed committed on a branch that checkout is not on is
invisible here, and a seed visible only because it is on that branch vanishes the moment
another session switches away — so the row's `paste:` path can be dead thirty seconds after
`/next` prints it. The disclosure is the whole mitigation: append `· read on <branch>` to every
row, and when `<branch>` is not that repo's default, say so explicitly and add *"seeds on other
branches were not read"*. Where the default is `(default unknown)` — a clone that never ran
`git remote set-head` — still print the branch and skip the comparison; an unverifiable claim
about which branch is canonical is worse than none. Never silently present a branch-scoped read
as the repo's state.

**Newest wins, resolved by the filename date first and then by the frontmatter `date:`
timestamp — never by mtime.** git does not preserve mtime, so a fresh clone orders seeds by
checkout order; and mtime ordering has already misordered production files in this fleet.

The filename date decides **alone**; only when two seeds share it does the frontmatter `date:`
get a vote. A seed with no parseable one **cannot be ordered against a same-day sibling at
all** — that is a *tie*, never a loss. Most seeds in the fleet today predate this convention and
carry no frontmatter at all, so ranking a headerless seed below a headed one would silently
resume the wrong session; an empty field sorting before every digit (and a legally quoted
`"2026-…"` doing the same) is exactly how that happens. Ties exit **2** and print every
candidate.

```bash
newest_seed() {                       # $1 = a docs/handoffs directory
                                      # 0: one winner on stdout   1: no seeds here
                                      # 2: unresolvable tie — every candidate on stdout
  d=$1
  [ -d "$d" ] || return 1
  # `find`, not a glob: an unmatched glob is a literal in bash and a hard error in zsh,
  # and the `[ -e ]` guard that papers over the first never runs under the second.
  rows=$(find "$d" -maxdepth 1 -type f \
              -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md' |
         while IFS= read -r f; do
           base=${f##*/}
           ts=$(awk 'NR>1 && /^---[[:space:]]*$/ {exit}
                     /^date:[[:space:]]*/ {
                       sub(/^date:[[:space:]]*/,"");     # strip the key
                       sub(/[[:space:]]*#.*$/,"");       # trailing comment
                       sub(/[[:space:]]+$/,"");          # trailing whitespace
                       print; exit }' "$f")
           ts=${ts#\"}; ts=${ts%\"}          # a quoted scalar is valid YAML — and an
           ts=${ts#\'}; ts=${ts%\'}          # unstripped quote sorts before every digit
           # `grep`, not `case`: bash 3.2 (the /bin/bash macOS ships) cannot parse a
           # `case` nested inside `$( )`. Anything not shaped like a timestamp is
           # treated as MISSING, never as "early".
           printf '%s' "$ts" |
             grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T' || ts=
           printf '%s\t%s\t%s\n' "${base:0:10}" "$ts" "$f"
         done)
  [ -n "$rows" ] || return 1          # directory exists, holds no conforming seed
  day=$(printf '%s\n' "$rows" | cut -f1 | LC_ALL=C sort | tail -1)
  cand=$(printf '%s\n' "$rows" | awk -F'\t' -v d="$day" '$1==d')
  [ "$(printf '%s\n' "$cand" | wc -l)" -eq 1 ] && { printf '%s\n' "$cand"; return 0; }
  # >1 seed on the newest day: the frontmatter timestamp is the only tiebreak there is.
  printf '%s\n' "$cand" | awk -F'\t' '$2==""' | grep -q . && {
    printf '%s\n' "$cand"; return 2; }              # any headerless candidate: unresolvable
  best=$(printf '%s\n' "$cand" | LC_ALL=C sort | tail -1 | cut -f2)
  won=$(printf '%s\n' "$cand" | awk -F'\t' -v t="$best" '$2==t')
  [ "$(printf '%s\n' "$won" | wc -l)" -eq 1 ] || { printf '%s\n' "$won"; return 2; }
  printf '%s\n' "$won"
}
```

**Exit 2 is loud, and it is never resolved silently.** Two seeds sharing both the filename date
and the timestamp — two sessions ending on one repo in the same minute, normal under this scheme
— and any same-day pair where one lacks a usable header are the same outcome: read **every**
line the function printed, say in the row that the day is ambiguous and why, and let the reader
pick. Sorting by path, by length, or by "the one with frontmatter looks more official" is
exactly the silent wrong answer this branch exists to prevent.

**No `docs/handoffs/` at all — or one holding no conforming seed?** Both return **1**, and the
`rows` check is what makes the second one signal: a `return` from inside a pipeline exits only
its subshell, so a status set there never reaches the caller. Fall back to
`git -C "$d" log -1 --format='%cI %s'` and rank on that. Seeds are the better signal; a repo
without them is not thereby invisible.

### 4. Rank

Advisory ordering, in this order:

1. Repos named in `PRIORITIES.md`, in the order they appear there.
2. Remaining repos with a seed, by frontmatter timestamp, newest first.
3. Remaining repos with a commit in the last 14 days, by commit recency.
4. The rest are **counted, not listed**.

Cap the listing at 8 rows.

### 5. Present — every row ends in its paste-line

```
PRIORITIES.md — last edited 2026-08-08 (3 days ago)

1. stock-keep — seed 2026-08-11 (today) · priority #1 · read on main
   picks up: issue #209 — assets/scripts has no test coverage
   paste: /Users/blamechris/Projects/stock-keep/docs/handoffs/2026-08-11-wave-16.md

2. aeolus — seed 2026-08-11 (today) · read on feat/117-review-fixes (NOT main;
   seeds on other branches were not read, and this path dies if that checkout moves)
   picks up: PR #117 — owner must review before merge
   paste: /Users/blamechris/Projects/Aeolus/docs/handoffs/2026-08-11-gate-on-117.md

3. duskwright — seed 2026-08-03 (8 days ago) · parked · read on main
   picks up: issue #20 — implement ADR 0007
   paste: /Users/blamechris/Projects/duskwright/docs/handoffs/2026-08-03-adr-0007-and-housekeeping.md
   AMBIGUOUS: 2026-08-03 carries two seeds and neither has a usable `date:` —
   the other is …/2026-08-03-queue-drain.md; read both before choosing.

9 other repos: no seed, no commits in 14 days — not listed.

Ranking is advisory. Nothing here is state: /next holds no file, writes no file, and caches
nothing. The repo re-derives on arrival — /session-lifecycle start re-reads docs/handoffs/,
re-runs git status, and verifies the last claimed merge before building on any of it.
```

The `picks up:` line is the seed's `picks_up_at:` frontmatter value — or, for the many seeds
that have no frontmatter, its `Picks up at:` bullet — lifted **verbatim**. `/next` does not
summarize it, and it is the only claim about a repo's state that leaves this skill. `read on
<branch>` is likewise required on every row, and an `AMBIGUOUS:` block is required wherever
`newest_seed` exited 2. The closing paragraph is **required output on every run**, not a
flourish: it is what tells the reader (and any agent chaining off this output) that these rows
are not authority.

### What `/next` must never do

- **Never write a file.** No index, no cache, no `LATEST.md`, no fleet status board. A
  hand-maintained fleet board goes stale within a day, silently, and re-creates the shared-file
  collision this whole scheme exists to remove. There is no fleet status file: it is derived at
  read time, by this skill, every time.
- **Never emit a PR number, issue state, or CI verdict it computed itself.** Rows carry a path
  and a verbatim `picks_up_at:` line. Anything more invites a downstream step to act on a
  dispatcher's stale reading.
- **Never rewrite, rename, or delete a handoff seed**, in any scope, for any reason —
  including "tidying up" superseded ones. Seeds are append-only. A global seed file overwritten
  at every session end came within one write of destroying an unconsumed, unbacked-up seed;
  that is the failure this design removes rather than guards against.
- **Never modify `PRIORITIES.md`.**
- **Never ask GitHub.** Latency and cost for authority the dispatcher does not need.

End the response with the standard mechanical `**Status:**` block.
