# Claude Development Notes — skill-templates

## Project Overview

**skill-templates** is a private repository of reusable Claude Code skill templates (`.claude/commands/*.md`) that get customized per project. It serves as the canonical source of truth for review workflows, PR processes, and development skills used across all repos.

## How It Works

```
skill-templates/
├── generic/           # Gold standard templates (repo-agnostic)
├── customizations/    # Per-repo adaptation notes
└── sync.sh           # Diff local repo skills against templates
```

**Workflow:**
1. Skills are refined here when failure modes are discovered
2. `sync.sh` shows which repos have drifted from the template
3. Agents receive prompts referencing the template + repo-specific customization notes
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

## Managed Repos

| Repo | Tech Stack | Skills |
|------|-----------|--------|
| chroxy | Node.js + React Native/Expo | check-pr, agent-review, commit, create-pr, qa-update |
| exodus-loop | Godot 4.5, GDScript | check-pr, agent-review, commit, create-pr, qa-update, tdd-feature |
| archery-apprentice | Kotlin/KMP, Android/iOS | check-pr, agent-review, consolidate-dependabot, qa-update |
| repo-relay | Node.js, TypeScript, discord.js | check-pr, agent-review |
