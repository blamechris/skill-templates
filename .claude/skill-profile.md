# skill-templates skill profile

## Project Context
- Tech: Markdown skill templates (`generic/*.md`); Bash with embedded `python3` heredocs (`scripts/`, `assets/scripts/`); two ESM Node scripts, `assets/compile-skill-targets.mjs` (CI-gated) and `assets/smoke-intake.mjs`; GitHub Actions. No package manager and no dependencies — every Node import is a `node:` builtin.
- Build system: no compile step. `./scripts/build-index.sh` regenerates `registry.json` from `generic/*.md`, and that generated index *is* the build product; CI fails the PR if it is stale.
- Repo: blamechris/skill-templates (public)
- Main branch: main
- CI: `validate-registry` is the gate — it runs on every PR and on push to `main` (registry sync + freshness, the continuity-doctrine scans, the six regression suites, and a lint of this repo's own `.claude/commands/*.md`). It is **not** a required status check: `main` is protected with `required_status_checks: null` and `required_approving_review_count: 0`, so green CI is read and confirmed by the author, never assumed. `Repo Relay` is a Discord notifier, not a gate; `reindex-after-merge` runs only after a push to `main`.
- Status: pull-based registry — repos install on demand via `/skill`; the push-deploy model is fully retired (#68/#75). Five skills are installed here: `agent-review`, `bug-hunt`, `learn`, `prime-directive`, `recon`.
- Hard requirements (never regress):
  - **Zero attribution.** No `Co-Authored-By`, no "Generated with Claude", no AI/assistant mention in commits, PR bodies, issues, or generated docs. The owner is the sole author.
  - **Every change lands through a PR.** No direct pushes to `main`, no `gh pr merge --auto` / `--admin`, no protection override — a one-line template tweak and a regenerated index are not exempt (`49ccfc5`, reverted in #132, re-landed as #133).
  - **`registry.json` is generated, never hand-edited.** Run `./scripts/build-index.sh` and commit the result; `generatedFromCommit` and the per-skill `hash` are git-derived and cannot be right before the squash — `reindex-after-merge.yml` repairs them.
  - **The push-deploy stays dead.** Do not recreate `deploy.sh`, `deploy.conf`, `sync.sh`, `customizations/`, `values/`, or a push trigger.
  - **The session seed lives outside every worktree** at `$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`. `docs/handoffs/` is a narrative artifact of a PR and is NOT the continuity mechanism. Seeds are per-scope and archive-on-collide; the single global seed file is retired.
  - **Exactly one scope derivation.** `--git-common-dir` is executable only in `assets/scripts/session-seed.py`; prose outside a code fence may explain it. A second copy fails CI.
  - **The floor is exactly five rules** (`no-agent-attribution`, `explicit-path-staging`, `worktree-by-default`, `no-secrets-in-committed-files`, `seed-written-outside-any-worktree`), agreeing in `assets/global-CLAUDE.md` and `assets/scripts/fleet-check.py`.
  - **A new shipped script arrives with an executable sibling suite** (`*.test.sh` / `*.test.mjs`) — an untested script asset is a tracked defect (#209), which is *open*: `scripts/build-index.sh`, `scripts/guard-audit.py` and `assets/smoke-intake.mjs` have none today. Treat that as the known backlog, not as a regression to report.
  - **This repo's own installed skills lint clean.** `.claude/commands/*.md` is covered by CI, and every name in `.claude/skills.lock` must have a file on disk (#156).
  - **No secrets.** The repo is public; keys, tokens, cookies, private URLs, and third-party personal data never land here.

## Build / Test Commands
- Build (the gate): `./scripts/build-index.sh` — regenerates `registry.json`; commit it in the same PR. Verify freshness the way CI does with `python3 scripts/check-index-fresh.py <committed.json> <rebuilt.json>`.
- Test: no single test target — run the suites CI runs:
  - `node assets/compile-skill-targets.test.mjs`
  - `./scripts/skill-lint.test.sh`
  - `./scripts/check-index-fresh.test.sh`
  - `./assets/scripts/session-seed.test.sh`
  - `./assets/scripts/usage-benchmark-row.test.sh`
  - `./assets/scripts/fleet-check.test.sh`
- Lint/typecheck: no typechecker and no linter config (plain ESM, no `package.json`). The mechanical gate is `./scripts/skill-lint.sh <name> .claude/commands/<name>.md ./registry.json` per installed skill — exit 0 clean, 1 findings, 2 not verifiable. Native artifacts are checked with `node assets/compile-skill-targets.mjs --dry-run`.

## Conventions
- Branch prefix / naming: `<type>/<slug>`, or `<type>/<issue>-<slug>` when it closes an issue — `feat/`, `fix/`, `docs/`, `chore/`, `refactor/`, `revert/`. The post-merge reindex bot uses `chore/reindex-registry`.
- Commit style + scopes: conventional commits, `type(scope): subject`. **A change to one skill is scoped by that skill's own name** — `feat(weekly-review)`, `fix(visual-brief)`, `feat(look-approve)`, `fix(batch-merge)` — which is the most common form in the log. Otherwise the scope names the area: `registry`, `skills`, `skill`, `scripts`, `guards`, `generic`, `templates`, `compiler`, `skill-lint`, `session-lifecycle`, `assets`, `global`, `conventions`, `ci`.
- Source file patterns: `generic/*.md` (templates — prose plus fenced examples, no frontmatter); `assets/**` (files distributed verbatim to consumer repos); `scripts/*.sh` and `scripts/*.py` plus their `*.test.sh` siblings; `.github/workflows/*.yml`; `registry.json` (generated) and `skill-guards.json` (hand-maintained); `.claude/commands/*.md` (this repo's own version-stamped installs).
- Shell style: `set -euo pipefail` in `scripts/`, with one deliberate exception — `scripts/skill-lint.test.sh` uses `set -uo pipefail` because its harness captures a non-zero `rc` from every "dirty" case and `-e` would abort the suite on the first one. Bash targets macOS bash 3.2 (`.claude/rules/bash-compat.md`): no `declare -A`, use parallel indexed arrays.
- GitHub Actions (`.claude/rules/gh-actions.md`): `gh` has no auth session on a self-hosted runner — export `GH_TOKEN` before any `gh pr` / `gh issue` call; `if:` compares step outputs as strings, so write `!= '0'`, not `> 0`.
- Registry hygiene: edit `generic/<name>.md`, then `./scripts/build-index.sh`, then commit both. Adding a `self-merge-posture` alternate to `skill-guards.json` also requires teaching `POSTURE_ANCHORS` in `scripts/skill-lint.sh` — the test suite asserts they agree.

## Skill Targets
targets: claude

Only `claude` — this repo is driven from Claude Code and nothing else, which matches every `targets` array in `.claude/skills.lock` and the compiler's current effective behaviour (no profile ⇒ fall back to `claude`). `pi` is deliberately absent: it writes to `~/.pi/agent/skills/` outside the repo, so it belongs on a per-machine `--targets claude,pi` flag, never on a committed line. The compiler's `~/.pi` hint is advisory and must not be acted on by editing this file.

## prime-directive Customizations

- Target repository: `blamechris/skill-templates`.
- Decision mechanism: a decision panel of independent review sub-agents — pick the recommendation and record it; there is no `/swarm-audit` installed here.
- Code intelligence: none wired up. Use `grep` / `Read` directly; the repo is small (`generic/*.md`, `scripts/`, `assets/`, `registry.json`, `skill-guards.json`), so a targeted grep beats any indexing step.
- Composed skills are **not** installed here — `/full-review`, `/tackle-issues`, `/check-pr`, `/swarm-audit`, `/project-audit`, `visual-brief` all resolve at runtime through the install-on-miss rule in `CLAUDE.md`. Expect the first call to install, not to fail.
- Third-party review: Copilot reviews every PR here and has been reliable — wait for it and treat its comments as first-class, but do not stall the run if it is blocked or quota-exhausted.
- Wave re-launcher: none. This repo is driven attended from a terminal, so a wave boundary ends the session rather than forcing a compaction.
- Session log: `autonomous-session-<date>.md` at the repo root — gitignored via `.gitignore`, never committed. The issue tracker is authoritative for what is *left*; the session log is authoritative for the *plan and decisions*.
- Executive brief: the `visual-brief` skill, written into `$CLAUDE_BRIEF_DIR`.
- Cost: the statusline reports session cost. This is a docs-and-shell registry, so the per-wave budget is small — a wave costing more than a couple of dollars is looping, not working.

### Self-merge posture

**Gated.** An autonomous session may merge its own PR in this repo, strictly under the Unattended Merge Gate: a clean `/full-review` verdict, **all** CI green on the **final** commit (read the run's actual conclusion, not a stale green from an earlier push), and **all** review threads resolved — then a synchronous squash merge, confirmed `MERGED`. Never `gh pr merge --auto`, never `--admin`, never a protection override; if a gate fails, name the failed gate and move on without merging.

The gate is self-imposed and nothing enforces it: `main` carries `required_status_checks: null` and `required_approving_review_count: 0`, so a merge with red CI and zero reviews succeeds silently and logs no bypass. That is why every condition is checked deliberately, every time.

Recorded in the profile, not just in the installed skill: `.claude/commands/` is regenerated on every `skill update`, this file is not.

Note that this particular block is **documentation, not a machine-checked pin**: `scripts/skill-lint.sh` scopes check 5 to `POSTURE_SKILLS = (autonomous-dev-flow, tackle-issues)`, so it never reads a `prime-directive` section. The enforced pins are the two sections at the end of this file.

## agent-review Customizations

- Reviewer persona: a registry maintainer who reads skill templates as *programs an agent will execute*, not as documentation — the failure mode is a template that renders plausibly and then behaves wrongly at install time.
- Code quality criteria: no residual `{{CUSTOMIZE}}` markers; no attribution footer; a well-formed version stamp alone on the last non-blank line; guard anchors intact.
- Architecture criteria: one implementation per rule — this repo's recurring defect is a *second* copy of a derivation or a doctrine paragraph, and the copy in the most-read file is the one that wins the drift (#210). A new gate must be able to fail; a needle a scan looks for must not also appear in the prose that explains the ban.
- Test criteria: every shipped script under `scripts/` and `assets/scripts/` has an executable sibling `*.test.sh`, and a new assertion must be shown to fail against a deliberately broken mutant — not merely pass against the good file.
- Labels: `bug`, `enhancement`, `documentation`, and `from-review` for anything a review turned up — those four are the ones actually used. Six GitHub defaults also exist and are unused (`duplicate`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`). Ten labels total; do not invent a `type:`/`triaged:` scheme.

## bug-hunt Customizations

- Labels: `bug` plus `from-review` for anything a review turned up. No `type:` or `severity:` families exist here.
- Domain hunters: none. This is a Markdown/Bash/Actions registry with no runtime, no network surface, and no UI — do not fabricate hunters from the tech stack.
- Guardian must check any new scan-based gate for **satisfaction-by-prose**, because it has bitten this repo twice: `validate-registry`'s own comments explain why `|| true` may not be softened and why `docs/handoffs` is banned, so a substring scan for either phrase is satisfied by the documentation rather than by the code. Anchor to a code fence or the start of a line's content, never to a bare substring.
- Guardian must check any new derivation of the scope key or the seed path against `assets/scripts/session-seed.py`, because a hand-written second copy in `assets/global-CLAUDE.md` is exactly the regression #210 removed — and it landed four commits after the extraction whose purpose was to have one implementation.

## recon Customizations

- Domain scouts: none — no runtime, no framework, no build graph to map.
- The whole repo is small enough to read: `generic/` (templates), `scripts/` + `assets/scripts/` (the tooling and its suites), `assets/` (files distributed verbatim to consumers), `.github/workflows/` (the gates), and `registry.json` + `skill-guards.json` (the generated index and its content guards). Cover those five and the map is complete; a per-package summary has nothing to be per-package about.

## learn Customizations

- Memory layers here are **two authored nodes, not a source and a copy**: the machine node `~/.claude/CLAUDE.md` and the registry node `assets/global-CLAUDE.md` on `origin/main`. Neither generates the other and nothing is push-deployed. A learning that belongs to the fleet lands in the registry node via PR and is then copied out; a floor-rule difference stops long work until it is reconciled (`assets/scripts/fleet-check.py` reports the direction).
- Repo-scoped learnings go in `CLAUDE.md`; path-scoped ones go in `.claude/rules/<topic>.md` with a `paths:` header.
- Durable records of *why* a change was made go in `docs/records/`; `docs/handoffs/` is a narrative artifact of a PR and is NOT the continuity mechanism.

## autonomous-dev-flow Customizations

*Not installed here today — this section exists so the posture is pinned before it ever is. `scripts/skill-lint.sh` reads it; the profile is the pin, and `.claude/commands/` is regenerated on every `skill update`.*

### Self-merge posture

**Gated.** Same posture and same gate as `prime-directive` above: self-merge is authorized under a clean review, all CI green on the final commit, and all threads resolved — with no `--auto`, no `--admin`, and no protection override.

## tackle-issues Customizations

*Not installed here today — this section exists so the posture is pinned before it ever is, for the same reason as `autonomous-dev-flow` above.*

### Self-merge posture

**Gated.** Same posture and same gate as `prime-directive` above: self-merge is authorized under a clean review, all CI green on the final commit, and all threads resolved — with no `--auto`, no `--admin`, and no protection override.
