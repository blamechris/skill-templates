---
type: handoff
date: 2026-08-11T09:20Z
repo: skill-templates
picks_up_at: "issue #203 — the ~/.claude/CLAUDE.md copy-out, blocked behind #208"
sensitivity: public
---
# Handoff — layered session continuity landed (#205)

- **Boundary reason:** work-class switch — the registry change is done; what remains is
  machine-side surgery on `~/.claude/` and the vault, which is a different kind of work
  with a different blast radius.
- **Picks up at:** #208 first (reconcile the two-way `global-CLAUDE.md` drift), then #203's
  copy-out. Not before: copying out today drops the machine's un-landed `**Next:**` rule.

## STATE

- **Branch:** `feat/layered-session-continuity`, branched from `origin/main` @ `b20c42f`.
- **Working tree:** clean at each commit; every path staged by name, no bulk adds.
- **Worked in:** a linked worktree under `/private/tmp/...`, never
  `~/Projects/skill-templates` (whose checkout sits at `e053400`, an ancestor of `main`).
- **CI:** all six existing `validate-registry` steps pass locally, plus the new one.
- **PR:** #210 — open at the time this seed was written, not merged. Treat everything below
  as *proposed* until you have confirmed otherwise with the first command in the next block.
- **Open, related:** #205 (this), #204 (closed by this), #203 / #207 / #208 / #209 (open),
  #181 and #198 (unchanged, referenced).

## Verify before building on any of this — re-derive, don't trust

```bash
gh pr view 210 --repo blamechris/skill-templates --json state,mergeStateStatus
# expect state=MERGED before treating the doctrine below as landed

grep -rn "no-it-all/handoffs/NEXT" generic assets      # expect: no matches
grep -rln "docs/handoffs/<date>-<slug>.md" generic     # expect: 3 files, 6 sites

python3 -c "import json;r=json.load(open('registry.json'));\
print(r['skillCount'], len([s for s in r['skills'] if s['name']=='session-lifecycle'][0]['guards']))"
# expect: 41 11   (8 pre-existing guards + the 3 added here)

shasum -a 256 ~/Obsidian/no-it-all/handoffs/NEXT.md
# expect: still PR #206's generated index — the tombstone is NOT done yet
```

## TL;DR — what shipped

The global `~/Obsidian/no-it-all/handoffs/NEXT.md`, overwritten at every session end, is
retired in the registry's text. Session seeds are now per-repo, dated, append-only and
committed at `<repo>/docs/handoffs/YYYY-MM-DD-<slug>.md`; "NEXT" is a query — the newest
entry — not a file. `/next` (`assets/next.md`) derives a fleet ranking at read time from
those seeds plus a hand-written `~/Projects/PRIORITIES.md`, holds no state, and ends every
row with the one line to paste.

- `generic/session-lifecycle.md` — Resume step 6 reads the newest seed (filename date, then
  frontmatter timestamp, never mtime); the end checklist goes 5 steps → 7 and names both
  ending artifacts; Resume step 5 now drift-checks `next.md` alongside `global-CLAUDE.md`.
- `skill-guards.json` — three new `session-lifecycle` guards: `append-only-handoff`,
  `both-end-artifacts`, `newest-wins-not-mtime`.
- `generic/{prime-directive,tackle-issues,autonomous-dev-flow}.md` — the wave-handoff
  default moves out of the vault, and relaunch tasks must name the dated file.
- `assets/global-CLAUDE.md` — the "Session boundaries" restart bullet and artifact ②.
- `assets/next.md` — new.
- `.github/workflows/validate-registry.yml` — one step locking all of the above.

## Next task

**#208, then #203.** #208 reconciles `global-CLAUDE.md` in both directions (the machine copy
carries an un-landed `**Next:**` rule; the registry copy is ahead on #194's status-block
reformat). Only after that does the copy-out to `~/.claude/CLAUDE.md` land #203's acceptance
criterion — a clean `diff -q` between the two.

Alternatives if #208 is not the right size: **#207** (the registry's
`usage-benchmark-row.py` is missing the machine copy's dedup fix and overcounts ~2.2x — it
is artifact ① of the very checklist this PR rewrote), or **#209** (`assets/scripts/*.py` has
no test coverage; this PR deliberately added no executable assets to keep it out of scope).

## Left undone, deliberately

- **The copy-out to `~/.claude/CLAUDE.md`.** Ordering is: merge this → land #208 → copy out
  once. #203 is therefore **not** closed by this PR.
- **The vault `NEXT.md` tombstone.** Post-merge, machine-side, copy-first: `shasum` it,
  `cp -p` it to `NEXT-index-2026-08-11.bak.md`, verify the hashes match, and only then write
  the five-line redirect over it. The vault is not git-tracked; there is no undo.
- **The 19 existing vault handoff files.** Left exactly where they are, as history. No moves,
  no deletes, no bulk migration — including the six unconsumed seeds and the two hand-rescued
  ones. Per-repo adoption is lazy: each repo's own next session copies its vault seed into
  `docs/handoffs/`, commits it, and leaves the original untouched.
- **`~/.claude/scripts/handoff-index.py`.** Retired by disuse, not deletion. It is the only
  copy of PR #206's read-before-overwrite guard, and the branch `fix/per-project-handoff-seeds`
  is the only home of that PR's artifact. Leave both byte-for-byte.
- **`~/Projects/PRIORITIES.md`.** Owner-written only. `/next` prints a starter template when
  it is missing and never writes it.

## Records

Nothing here graduated to `docs/records/` — the durable conclusions of this session are the
doctrine itself, which lives in the templates rather than in a record. If #198's convention
lands in this repo, the `--git-common-dir`-not-`$PWD` finding is the candidate.
