---
description: "A reload-resilient north star for an unattended, multi-wave backlog-clearing marathon — a compact, self-contained constitution you re-invoke after every..."
---

# /prime-directive

A reload-resilient north star for an unattended, multi-wave backlog-clearing marathon — a compact, self-contained constitution you re-invoke after every context compaction to re-establish the mission, the authority you were granted, the per-issue loop, and the never-strip guardrails before resuming. Where `/tackle-issues` and `/autonomous-dev-flow` are the machinery, this is the constitution that keeps a long autonomous run from drifting as its context is summarized and rebuilt.

Invoke it at the **start** of an unattended run to set the mission, and again **after every compaction** to reload it. It does not start work by itself — it re-grounds the agent, then hands off to the marathon machinery (`/tackle-issues`) for the actual wave loop. Treat this file as load-bearing: everything an interrupted, freshly-compacted agent needs to safely resume is here, in one read. Natural-language cues like *"work autonomously / use the prime directive / keep going until the backlog is clean or you're genuinely blocked"* should route here.

## Arguments

- `$ARGUMENTS` — all optional:
  - *(empty)* — reload the directive as written: re-establish mission + guardrails, read the session log for live state, resume the marathon.
  - A path — override the session-log location for this run (default below).
  - A short mission override in quotes — narrow the scope for this run (e.g. `"only label:ready-to-build"`), without editing the file.

## Reliability — the reload contract (read this first)

This skill exists because a long autonomous run is **compacted repeatedly**, and each compaction summarizes (and can quietly distort) the agent's memory of *what it is doing and what the rules are*. The directive is the antidote: a stable, self-contained artifact that restores ground truth on demand. Four rules make that reliable — do not weaken them:

1. **Reload by invocation, never by file-path `cat`.** After every compaction, run **`/prime-directive`**. Do **not** rely on `cat .claude/commands/<name>.md` or any hard-coded path: the legacy `.claude/commands/` slash-command loader is broken upstream (anthropics/claude-code#31846), and the live artifact is the compiled `.claude/skills/prime-directive/SKILL.md` that `/prime-directive` loads. The invocation is the contract; a path is a footgun that silently loads nothing.

2. **Plant the reload trigger where a compacted agent will see it.** The session log's **first line** must read, verbatim: *"After any compaction: re-invoke `/prime-directive`, then read this log from the top for live state, then resume."* Summarizers preserve the top of a document; putting the trigger there makes it survive the very event it guards against.

3. **Keep this file self-contained.** Re-reading **this file alone** must re-establish: the mission (what "done"/convergence means), the authority granted, the per-issue loop, the hard guardrails, and where live state lives. Compose heavy machinery (`/tackle-issues`, `/full-review`) by reference, but never factor an *essential rule* out into a skill that might not be reloaded. The constitution stands alone; the machinery is called by name.

4. **Re-entry is idempotent.** Resuming mid-run must never duplicate work. Derive progress from durable external state — open/merged PRs per issue (GitHub) + the session log — exactly as `/tackle-issues` resume does, not from in-context memory. Re-invoking `/prime-directive` at any moment is always safe.

## Mission

Clear the **entire** open issue backlog for `blamechris/skill-templates`, autonomously, until **convergence**. There is **no stop condition besides a converged backlog** — keep going until every open issue is resolved (closed via a merged PR, decomposed into tracked sub-issues, or documented-blocked with a comment), or nothing tractable remains. The user is away and will review on return. Do **not** wait for the user, and do **not** stop early for confirmation: make the decision, record it, proceed.

At the start of a run, triage every open issue into **autonomously-completable** vs **blocked** (needs the user's machine / infra / a live visual check / external data / an owner decision). Work the completable ones in value order; for each blocked one, comment *why* it's blocked and what's needed, then skip it. **Never fake-merge a blocked issue as done**, and never loosen a gate to force a merge — a documented-blocked issue is a legitimate terminal state; a faked completion is a lie in the backlog the user has to discover later.

## Authority

For an unattended run, this directive grants: full autonomous **self-merge under the merge gate below**; create / close / comment / label issues; decompose epics into sub-issues; file follow-up issues for deferred work; and use a decision panel (a panel of independent review sub-agents) to choose among genuine options and then **act on the recommendation** rather than escalating to the user.

**Self-merge IS authorized for this repo**, strictly under the merge gate in step 8: a clean `/full-review`, all CI green on the final commit, all threads resolved, then a synchronous squash merge. The owner's stated rule is *"PRs merged into main when tests pass"*, and the reason given is isolation — every change to `main` must be one reviewable, revertable unit.

That authority does **not** extend to reaching `main` any other way. `main` carries a rule requiring a pull request, and it is configured with `enforce_admins: false` — so a plain `git push origin main` from this account **succeeds** and GitHub merely logs *"Bypassed rule violations"* afterwards. The rule will not stop you; you stop you. This has already happened once (commit `49ccfc5`, reverted in #132 and re-landed as #133). No change is too mechanical for a PR — "it was only a regenerated file" is an argument for how cheap the PR would have been.

**The merge gate is self-imposed. Nothing enforces it.** `main` has `required_status_checks: null` and `required_approving_review_count: 0`, so `gh pr merge` on a PR with **red CI and zero reviews** succeeds silently — no bypass is logged, because no rule was broken. The direct-push path at least leaves a trace; this one leaves none. Every condition in step 8 is therefore checked by you, on purpose, every time: read the actual conclusion of the run on the **final** commit (`gh api .../actions/runs/<id> --jq .conclusion`, not a stale green from an earlier push), confirm the review verdict, confirm zero unresolved threads. If you find yourself reasoning that a gate "obviously" passes, that is the moment to go and check it.

**Composed skills are not installed in this repo.** `/full-review`, `/tackle-issues`, `/check-pr`, `/swarm-audit`, `/project-audit` and `visual-brief` are all referenced by name below and **none** of them is present in `.claude/commands/` here — only `prime-directive` is. They resolve at runtime through the install-on-miss rule in `CLAUDE.md` (`skill add <name>`, then invoke). Expect that first call to install, not to fail, and do not read a bare skill name in this file as evidence it is available.

## Per-issue loop (self-contained — run for every issue, every wave)

1. **Sync** — `git checkout main && git pull origin main`. Always branch fresh from main; never stack branches.
2. **Understand** — read the issue + linked threads. no code-intel MCP is wired up here; use `grep`/`Read` directly. The repo is small — `generic/*.md` templates, `scripts/*.sh`, `registry.json`, `skill-guards.json` — so a targeted grep beats any indexing step. Re-verify any stored audit/plan claim against current main — audits go stale as main moves.
3. **Decide (only if genuinely ambiguous)** — for any real decision (epic scope, design fork, choosing among N approaches), run the decision panel (a panel of independent sub-agents, one per candidate approach, then act on the majority), **pick the recommended option**, and **record the decision** in the session log plus a one-line note on the issue. Never block on the user.
4. **Implement (TDD)** — branch `<type>/<slug>` matching the conventional-commit type — `feat/`, `fix/`, `docs/`, `chore/`, `revert/`, then RED → GREEN → REFACTOR. Match house style: markdown templates in `generic/` (prose + fenced examples, no frontmatter); shell in `scripts/` is bash with embedded `python3` heredocs for anything beyond simple control flow — `set -euo pipefail` in `build-index.sh` and `skill-lint.sh`, but **`skill-lint.test.sh` deliberately uses `set -uo pipefail`**: its harness captures a non-zero `rc` from every "dirty" case, so adding `-e` aborts the suite on the first one. `assets/compile-skill-targets.mjs` is the repo's only JS (ES modules, Node); conventional commits (`type(scope): subject`); no attribution anywhere. Run the **full** per-package test suite locally (not just the touched file) before pushing. For changes that genuinely can't be unit-tested (visual/UI-only), validate by parse-check + extracting the pure logic into a tested helper + a real-data sanity probe, and **flag the PR for the user's live verification** — never claim a visual change is verified when it isn't.
5. **PR** — push, open a PR. Link the issue with a closing keyword: `Closes #N`. One keyword **per issue** — `Closes #X, #Y` only closes the first, so repeat the keyword for each. Avoid negated phrasings ("does NOT close #N" still auto-closes).
6. **Full review (MANDATORY)** — run `/full-review`. A sub-agent review is mandatory on **every** PR (read-only: `gh pr diff` / `git show <ref>:<path>`; a non-worktree review agent must **never** `git checkout`). Copilot reviews every PR here and has been reliable — wait for it, and treat its comments as first-class (verify each claim rather than accepting or dismissing it wholesale). If it is blocked, quota-exhausted, or has not arrived after the `/check-pr` Step 0 polling window, proceed without it and say so in the PR; do not stall the run on it. Triage every thread.
7. **Resolve + follow-ups** — fix review findings; after a **FIX** reply, call `resolveReviewThread` (do not punt resolution to the user). **File follow-up issues** for anything deferred and link them. All threads resolved before merge.
8. **Merge gate (self-merge)** — merge **only** after: clean `/full-review` verdict **and** ALL CI checks green on the final commit **and** ALL review threads resolved. Then **synchronous squash merge**; confirm the PR reports `MERGED`. **NEVER** `gh pr merge --auto`, `--admin`, or any protection override. If any gate fails, flag the PR (name the failed gate) in the log and move on — do not merge.
9. **Record** — append the entry (issue, PR #, review verdict, checks, merge SHA, any decision) to the session log, then continue to the next issue.

## Waves / queue

- **Prioritize** tractable, well-scoped issues first (from-review hardening, DRY dedups, lint guards, low/medium bugs), then medium features, then **decompose epics** into concrete sub-issues — decomposition itself is progress; do not one-shot an epic.
- **Replenish** the queue between waves: pick up sub-issues created by decomposition plus any newly-tractable issue. Escalate strategy on retries: fresh context → alternative approach → simplify scope → documented-blocked comment.
- **Converge:** if a wave produces zero new completions on the remaining set, stop and summarize. (For the full wave/retry/convergence machinery, this composes `/tackle-issues` — call it; do not re-implement it here.)

## Final step (only when the backlog is empty / converged)

Run a **SOLID + DRY** whole-project audit (a swarm of review sub-agents across `generic/`, `scripts/`, `assets/` (the compiler — the repo's largest single file and CI-gated), and the CI workflows) and file / act on its findings, then write the end-of-run report (below).

## Hard guardrails

### Universal — never strip (these are guarded)

- **Zero attribution** — never add `Co-Authored-By`, "Generated with …", or any AI/assistant mention to commits, PRs, issues, or docs. The user is the sole author.
- **Never commit to main** — feature branch + PR, always.
- **Merge gate** — `/full-review` clean **+** ALL CI green on the final commit **+** ALL threads resolved; synchronous squash; verify `MERGED`. **No** `--auto`, **no** `--admin`, **no** protection overrides.
- **Explicit staging** — stage named paths only; never `git add -A` or `git add <dir>` (untracked artifacts ride along). `git status --short` before every commit.
- **Report** — end **every** user-facing message with a bold `**Status:**` line (the last thing in the message): what's done, what's in flight, what you're blocked on or doing next (name the background task / CI run / review). At the end of a long run, also produce an executive brief via the `visual-brief` skill, written into `$CLAUDE_BRIEF_DIR`: hero statement + outcome chips + a "needs you" callout on top, per-PR / bugs-caught / what's-next detail below. Lead with verifiable outcomes (PRs merged, issues closed, gates passed); do not pad with whole-file token/time metrics.

### Project-specific — build-breaking invariants (CUSTOMIZE)

- **`registry.json` is generated** — never hand-edit. Edit `generic/<name>.md` or `skill-guards.json`, commit, *then* run `./scripts/build-index.sh` and commit the index. The per-skill `hash` is `git log -1 -- generic/<name>.md`, so reindexing before the content commit records the wrong hash.
- **Squash-merge leaves the index stale** — a squashed template PR rewrites the commit the index pins, so `main` ends up referencing a hash that no longer exists there. After merging any PR that touches `generic/`, re-run `build-index.sh` and land the result **as its own PR** (#122 tracks automating this). PRs that touch only `registry.json` do not have this problem.
- **`scripts/skill-lint.test.sh` must stay green** — it is wired into `validate-registry.yml` and is the only thing standing between a linter refactor and every consumer repo silently losing a gate. Mutation-test any change to `skill-lint.sh`: revert the fix on a scratch copy and confirm a case actually goes red.
- **Guards are regexes matched against *installed* skills** — rewording a guarded line in a template can break the guard in every repo that already installed it. Check `skill-guards.json` before editing template prose, and prefer meaning-based alternates (`[Nn][Oo] attribution`) over literals.
- **Never edit an installed skill to appease the linter** — if the linter flags a load-bearing line, the linter is what gets fixed (#115 is the precedent).
- **Fleet-verify linter changes** — run the old and new linter across every `~/Projects/*/.claude/commands/*.md` and diff the exit codes before claiming no blast radius. Pass the registry path explicitly: a copy run from outside the repo resolves its default registry relative to itself and errors on every file, which looks like "no differences".

## State / where things live

- **Session log + decision log:** `autonomous-session-<date>.md` at the repo root — gitignored via `.gitignore`, never committed. Source of truth for progress + decisions to present on interrupt. Its **first line carries the reload trigger** (Reliability rule 2). Division of truth: the **issue tracker** (`gh issue list --state open`) is authoritative for what's *left*; the **session log** is authoritative for the *plan + decisions*. On reload, re-derive the backlog from the tracker — never trust a stale in-log snapshot.
- **This directive:** invoke `/prime-directive` (compiled live artifact: `.claude/skills/prime-directive/SKILL.md`). Do not depend on the `.claude/commands/` path resolving (Reliability rule 1).
- **Issue list:** `gh issue list --state open`.
