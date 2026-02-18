# claude-code-notify

## Project Info

- **Repo:** blamechris/claude-code-notify
- **Tech:** Bash scripts, jq, curl, Discord webhook API
- **Main branch:** main
- **CI:** None currently (shell test suite planned)
- **Purpose:** Discord notification hooks for Claude Code agent status (idle, permission, subagent tracking)

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
- No CI to wait for currently
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
