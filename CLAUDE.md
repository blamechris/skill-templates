# Claude Development Notes — skill-templates

## Project Overview

**skill-templates** is a private repository of reusable Claude Code skill templates (`.claude/commands/*.md`) that get customized per project. It serves as the canonical source of truth for review workflows, PR processes, and development skills used across all repos.

## How It Works (pull-based registry)

This repo is a **registry** — `npm`/`brew` for Claude Code skills. Repos install skills
**on demand** via the `/skill` client; the invoking agent customizes each template inline
for its repo. There is no central fan-out. (Migration tracked in #68; the old push-deploy
is retired — see "Legacy" below.)

```
skill-templates/
├── README.md                    # registry overview + /skill workflow
├── generic/                     # Skill templates (repo-agnostic, with {{CUSTOMIZE: ...}} markers)
│   └── skill.md                 # the /skill client itself
├── registry.json                # generated index: skill → template hash, description, guards
├── skill-guards.json            # per-skill content guards (load-bearing markers)
├── assets/                      # files distributed verbatim to consumer repos
│   └── compile-skill-targets.mjs # generic→native compiler (claude/gemini/codex), copied into a repo's scripts/
├── scripts/build-index.sh       # regenerates registry.json
└── docs/skill-profile-schema.md # the .claude/skill-profile.md spec
```

**Using skills (consumer side)** — in any repo, run `/skill`:
- `skill add <name>` — resolve from `registry.json` → fetch `generic/<name>.md` → the
  agent fills `{{CUSTOMIZE: ...}}` from the repo's `CLAUDE.md` + `.claude/skill-profile.md`
  + code → self-validate → write `.claude/commands/<name>.md` (version-stamped) → record
  in `.claude/skills.lock`.
- `skill list` / `outdated` / `update [name]` / `remove <name>`.
- Install-on-miss is a **rule, not automatic tooling**: per global `CLAUDE.md`, if `/X` is
  requested but absent from `.claude/commands/`, the agent runs `skill add X` first, then
  invokes it.

**Maintaining the registry** — edit a template in `generic/`, commit, then run
`./scripts/build-index.sh` to refresh `registry.json`. Consumers pick it up on their next
`skill update`. No deploy step, no API key here.

**Drift** — `skill outdated` (consumer side) flags version drift (template hash moved),
profile drift (`.claude/skill-profile.md` changed), and corruption drift (a `guards`
check fails).

### Legacy (#68 / #75)
The push-deploy model is **fully retired** (#75). All 16 managed repos are on the pull
model — each carries its own `.claude/skill-profile.md` + `.claude/skills.lock`.

**Removed:** `deploy.sh` (Haiku push-deploy), `sync.sh` (central drift scan), the
`deploy-skills.yml` / `test-deploy-sh.yml` workflows, `tests/test_deploy_bash_compat.sh`,
`deploy.conf` (repo→skill map), `customizations/` (migrated into each repo's
`.claude/skill-profile.md`), `values/` (deploy-time substitutions), `skill-check.sh`
(SessionStart drift hook — superseded by `skill outdated`), and the one-time migration tool
`scripts/rollout-pull-model.sh` (its job is done). **Do not recreate a push trigger,
`deploy.sh`, or `deploy.conf`.**

## Critical: Attribution Policy

**I am the sole author of all work in this repository.**

- NEVER include `Co-Authored-By` lines in commits
- NEVER add "Generated with Claude" or similar AI attribution
- Commit messages should be clean and professional

## Git Workflow

- `main` branch, PRs for significant changes
- Direct commits OK for template refinements
- Commit format: `type(scope): description`
- Types: feat, fix, refactor, docs, chore

## Repo Memory MCP

The `repo-memory` MCP is available. Prefer `get_file_summary` over `Read` when exploring code you won't edit — it returns cached summaries and saves tokens. Also available: `get_project_map`, `get_related_files`, `search_by_purpose`. Use `Read` when you need exact lines or plan to edit. When launching subagents, tell them repo-memory tools are available.

## Managed Repos

> **Legacy note (#68/#75):** the rollout is **complete** — every repo owns which skills it
> installs via its `.claude/commands/` + `.claude/skills.lock`, which is now the authoritative
> source. `deploy.conf` has been removed; the table below is a **historical snapshot** of the
> old push-model mapping, kept for reference only.

The table lists each managed repo and the skills it carried under the old push model. Repos can also have **repo-only skills** (`commit`, `qa-update`, `tdd-feature`, `consolidate-dependabot`) maintained directly in their `.claude/commands/`.

| Repo | Tech Stack | Skills (from `deploy.conf`) |
|------|-----------|--------|
| chroxy | Node.js + React Native/Expo + Tauri | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, manual-testing-mode |
| exodus-loop | Godot 4.5, GDScript | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, fetch-docs, agentic-audit, batch-merge, merge, parallel-dev |
| archery-apprentice | Kotlin/KMP, Android/iOS | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, fetch-docs, batch-merge, merge, parallel-dev |
| repo-relay | Node.js, TypeScript, discord.js | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| claude-code-notify | Bash, jq, curl, Discord webhooks | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, project-audit, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| repo-memory | TypeScript, MCP server | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, smoke-test, parallel-dev |
| medlens | Expo + RN, TypeScript | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, smoke-test, parallel-dev |
| carebridge | TypeScript fullstack (Turborepo, Fastify+tRPC, Next.js 15, Drizzle, BullMQ) | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| marchborne | Multiplayer game (MarchBorne) | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| ltl | Expo + RN, TypeScript, op-sqlite + SQLCipher, Jest 29 | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, agentic-audit, fetch-docs, project-audit |
| explAIn | Expo + RN-Web, TypeScript, Supabase, Vercel AI SDK + DeepSeek | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, fetch-docs |
| readitation | Flutter (Dart), iOS-only v0.1 | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test |
| sovereign-storm | TypeScript pnpm monorepo (Colyseus + Phaser 3 + Vite) | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, decompose-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test |
| skill-templates | Bash, GitHub Actions, Markdown templates | agent-review, full-review, check-pr, create-pr, create-issue, decompose-issue, learn, start-working, swarm-audit, recon, bug-hunt |
