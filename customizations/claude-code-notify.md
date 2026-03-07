# claude-code-notify

## Project Info

- **Repo:** blamechris/claude-code-notify
- **Tech:** Bash scripts, jq, curl, Discord webhook API
- **Main branch:** main
- **CI:** GitHub Actions (ubuntu-latest, bash test suite)
- **Purpose:** Discord notification hooks for Claude Code agent status (idle, permission, subagent tracking, bg bash tracking, heartbeat/stale detection)

## check-pr Customizations

**Issue labels:**
- `enhancement`, `from-review` (no complexity/testing labels — small project)

**Evidence patterns:**
- Shell scripting: "per POSIX: set -euo pipefail", "per ShellCheck: proper quoting"
- jq usage: "per jq docs: --arg for string interpolation"
- Discord API: "per Discord webhook docs: embed field limits"
- Architecture: "per existing pattern: config hierarchy is env var > .env > defaults"

**Attribution:** Zero Attribution Policy enforced via CLAUDE.md (same as all other repos)

**Copilot polling:** Include Section 0 (standard)

**Notes:**
- Small codebase (2 scripts, ~380 lines total)
- CI runs automatically but is fast — no need to poll/wait during check-pr
- Reviews likely focused on shell safety, input validation, Discord API compliance

## learn Customizations
- **CLAUDE.md sections:** `## Architecture`, `## Shell Conventions`
- **Rules naming:** kebab-case (e.g., `discord-webhooks.md`, `hook-events.md`)
- **Domain quality bar:** Shell portability gotchas, jq edge cases, Discord webhook limits, Claude Code hook event quirks qualify as durable insights
- **Common paths:** `*.sh`

## agent-review Customizations

**Persona:** Notify Inspector — expert in Bash scripting, shell utilities (jq, curl), Discord webhook API, Claude Code hooks system

**Mindset:** "Will this hook script fire reliably, safely, and quickly across all event types and edge cases?"

### Code Quality
- `set -euo pipefail` in all scripts
- Proper jq escaping (`--arg` for strings, `--argjson` for non-strings)
- All variables properly quoted
- No eval/exec of user-controlled data
- Input validation with safe defaults
- Errors to stderr, clean exit codes

### Architecture
- Hook script pattern: stdin JSON -> parse -> action
- Config hierarchy: env var > .env file > defaults
- State: /tmp for ephemeral (throttle, counts), ~/.claude-notify for persistent (config)
- jq for all JSON, curl for all HTTP
- No breaking changes to hook event handling or config formats

### Testing
- Shell test scripts pass
- Edge cases: malformed JSON, missing fields, empty stdin
- Mock webhook verification

### Performance
- Script execution speed (runs on every hook event)
- Minimal file I/O
- No unnecessary subshells

### Issue Labels
- `enhancement`, `from-review` (basic label set)

## start-working Customizations

### Ready-to-Work Labels
- No explicit `ready-to-build` label — treat unblocked, unassigned `enhancement` and `from-review` issues as ready
- Small codebase — most issues are directly actionable

### Blocked Labels
- `blocked`, `wontfix`

### Roadmap File Locations
- Default scan only (`ROADMAP.md`, `TODO.md`, `docs/`)

### Source File Patterns for TODOs
- `*.sh` (only 2 main scripts)

### Priority Signals
- `from-review` → P1
- `bug` → P0
- `from-audit` → P2

### Dependency Check
- No package manager — dependencies are system tools (jq, curl, bash)
- Check jq version compatibility if relevant

### Test Runner
- Shell test suite (bash-based)

### Audit Focus Areas
- Shell safety (quoting, set -euo pipefail, input validation)
- Discord webhook API compliance and rate limits
- Hook event handling edge cases (malformed JSON, missing fields)
- Script execution speed (runs on every hook event)

## parallel-dev Customizations

Shares all customization points with autonomous-dev-flow (branch prefix, test runner, commit scopes from agent-review/start-working sections).

### Parallel-Specific Settings
- **Default concurrency:** 3
- **Dependency setup in worktree:** None (Bash project — no package manager install step)

## project-audit Customizations

**Issue labels:**
- `enhancement`, `from-audit` for recommendations
- `bug`, `from-audit` for bugs/security findings

**Evidence patterns:**
- Same as check-pr (shell scripting, jq, Discord API, architecture patterns)

**Notes:**
- Auto-discovery will detect: Bash project, has tests (13 files, 289 assertions), has CI, no frontend, no dependencies beyond jq/curl
- Competitive Analysis (Scout) agent is relevant — this is a public product with 15+ competitors
- DevOps (Deployer) agent is relevant — has CI workflow
- UX/DX (Advocate) agent is relevant — this is a CLI/hooks tool with developer experience surface
