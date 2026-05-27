# Claude Development Notes — skill-templates

## Project Overview

**skill-templates** is a private repository of reusable Claude Code skill templates (`.claude/commands/*.md`) that get customized per project. It serves as the canonical source of truth for review workflows, PR processes, and development skills used across all repos.

## How It Works

```
skill-templates/
├── generic/           # Gold standard templates (repo-agnostic)
├── customizations/    # Per-repo adaptation notes
├── deploy.conf        # Repo-to-skill mapping (authoritative source)
├── deploy.sh          # Claude API-powered skill deployment
├── sync.sh            # Drift checker (reads deploy.conf)
└── .github/workflows/ # CI: auto-deploy on push to main
```

**Configuration:** `deploy.conf` is the single source of truth for which repos get which skills. Both `sync.sh` and `deploy.sh` read from it. Format: `REPO|GITHUB_SLUG|LOCAL_PATH_SUFFIX|SKILL1,SKILL2,...`

**Deployment:** `deploy.sh` calls the Claude API (Haiku 4.5, temperature 0) to customize generic templates using per-repo customization notes. It replaces `{{CUSTOMIZE: ...}}` markers with repo-specific content.
- **Local mode:** `./deploy.sh --local --repo chroxy --skill agent-review` — writes directly to local repo clone
- **CI mode:** Triggered by GitHub Actions on push to main when `generic/`, `customizations/`, or `deploy.conf` change. Clones target repos, creates PRs with customized skills.
- **Drift check:** `./sync.sh [repo]` — compares deployed skills against templates using pattern checks

**Workflow:**
1. Skills are refined here when failure modes are discovered
2. Push to main auto-deploys changed templates/customizations to managed repos via PR
3. `sync.sh` checks for drift between deployed skills and templates
4. Each repo's `.claude/commands/` contains the customized version

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

This table is **derived from `deploy.conf`** — it lists each managed repo and the skills currently deployed to it. Repos can also have **repo-only skills** (`commit`, `qa-update`, `tdd-feature`, `consolidate-dependabot`) maintained directly in their `.claude/commands/` — those aren't in `deploy.conf` and aren't listed here. **`deploy.conf` is the authoritative source; this table is documentation.** If they drift, trust `deploy.conf`.

| Repo | Tech Stack | Skills (from `deploy.conf`) |
|------|-----------|--------|
| chroxy | Node.js + React Native/Expo + Tauri | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, manual-testing-mode |
| exodus-loop | Godot 4.5, GDScript | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, fetch-docs, agentic-audit, batch-merge, merge, parallel-dev |
| archery-apprentice | Kotlin/KMP, Android/iOS | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, fetch-docs, batch-merge, merge, parallel-dev |
| repo-relay | Node.js, TypeScript, discord.js | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| claude-code-notify | Bash, jq, curl, Discord webhooks | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, project-audit, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| repo-memory | TypeScript, MCP server | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, smoke-test, parallel-dev |
| medlens | Expo + RN, TypeScript | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, smoke-test, parallel-dev |
| carebridge | TypeScript fullstack (Turborepo, Fastify+tRPC, Next.js 15, Drizzle, BullMQ) | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| marchborne | Multiplayer game (MarchBorne) | check-pr, agent-review, swarm-audit, recon, bug-hunt, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev |
| ltl | Expo + RN, TypeScript, op-sqlite + SQLCipher, Jest 29 | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, agentic-audit, fetch-docs, project-audit |
| explAIn | Expo + RN-Web, TypeScript, Supabase, Vercel AI SDK + DeepSeek | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test, fetch-docs |
| readitation | Flutter (Dart), iOS-only v0.1 | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test |
| sovereign-storm | TypeScript pnpm monorepo (Colyseus + Phaser 3 + Vite) | check-pr, agent-review, swarm-audit, full-review, create-pr, create-issue, learn, autonomous-dev-flow, tackle-issues, start-working, fix-ci, batch-merge, merge, parallel-dev, smoke-test |
| skill-templates | Bash, GitHub Actions, Markdown templates | agent-review, full-review, check-pr, create-pr, create-issue, learn, start-working, swarm-audit, recon, bug-hunt |
