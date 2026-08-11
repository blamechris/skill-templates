---
type: pr-record
date: 2026-08-11T13:40Z
pr: 210
---
# Vault-anchored session seeds (#205, as amended)

**This file is a narrative artifact of PR #210 — a record of what the change was for. It is
NOT a session seed and nothing is resumed from it.** The seed this repo's sessions actually
read is `$CLAUDE_HANDOFF_DIR/NEXT-skill-templates.md`, an absolute path in the vault, outside
every git workspace. Confusing the two is the mistake this PR exists to correct.

## What changed, and why the previous three rounds did not work

The seed used to live inside a git workspace: first the shared vault file `NEXT.md`, then a
committed `<repo>/docs/handoffs/YYYY-MM-DD-<slug>.md`. Every round of review found the same
defect class again, because an in-workspace seed has four independent ways to disappear and a
fix has to reason about all of them at once:

1. **Worktree teardown** — `git worktree remove --force` deletes untracked files silently.
2. **Branch reachability** — a seed committed on a feature branch is invisible from the main
   checkout, and its paste-path dies when another session moves that checkout's HEAD.
3. **Staged vs committed** — round 3's own durability proof used `git cat-file -e ":path"`,
   which is *index* syntax: it passed on a merely-staged file, and the seed was then destroyed
   by `worktree remove --force`.
4. **An unset `$SESSION_BRANCH`** — every `origin/$SESSION_BRANCH:...` check degrades to
   something that either errors or, worse, resolves to the wrong ref.

An absolute path in the vault has no worktree to be torn down with, no branch to be
unreachable from, and no index to be confused with. The surface is removed rather than
guarded, which is why End step 3 shrank from a commit-push-prove sequence to a single
`[ -f "$SEED" ]`. The vault is now git-backed and pushed
(`blamechris/no-it-all-vault`, private), so durability no longer depends on being inside a
repo — and the seed is private by construction, which the public registry repo could not offer.

## The shape

| Thing | Value |
|---|---|
| Repo-scoped seed | `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md` (default dir `~/Obsidian/no-it-all/handoffs/`) |
| Non-repo session | `NEXT-fleet.md`, or `NEXT-fleet-<topic>.md` for a named topic |
| Scope key | the **main worktree's directory basename**, from `git rev-parse --path-format=absolute --git-common-dir` |
| Collision | archive the incumbent to `NEXT-<scope>.<UTC>-<sid>.md`, then write |
| Ranking | `/next` ranks canonical seeds by frontmatter `date:`; undated seeds are grouped, never silently sorted |

The scope key is the directory basename and not the origin slug because `chroxy` and
`chroxy-daemon` share one origin URL and are separate projects with separate work; keying on
the remote would merge their seeds and let each overwrite the other's.

Archive-on-collide rather than per-session-unique filenames: unique names would also preserve
the incumbent, and would destroy the *"one line to paste"* affordance that makes the handoff
usable at all. One canonical name per scope, and a parked seed keeps its bytes under a name
that says when it was parked.

## Amendment to #205

Issue #205 specified the opposite — seeds committed inside each repo at
`<repo>/docs/handoffs/`. **That part of #205 is superseded.** `docs/handoffs/` survives only
as what this file is: an optional per-repo narrative record of a change. It is not the
continuity mechanism, and no session is seeded from it.

## Also in this PR

- `assets/scripts/fleet-check.py` — class-split drift detection between the two **authored**
  copies of the global conventions. Five FLOOR rules must match (exit 1); everything else is
  DEFAULT and reports a direction (exit 0). `git fetch` is a hard precondition, exit 2 when it
  fails — never 0, because a check that cannot see the registry copy must not report agreement.
  Tested by `assets/scripts/fleet-check.test.sh`, including the case where origin moves a floor
  rule under an unfetched clone.
- Rule-class tokens (`<!--floor:id-->` / `<!--default:id-->`) on rules rather than sections:
  the floor rule `seed-written-outside-any-worktree` lives inside a section that is otherwise
  all defaults, and headings get renamed.
- `assets/global-CLAUDE.md` gains **Rule precedence (all projects)** and the machine-only
  `**Next:**` rule (#208), so a single copy-out is now lossless in both directions.
