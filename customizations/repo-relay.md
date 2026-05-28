# Repo Relay Skill Customizations

## Project Context
- **Tech:** Node.js 20+, TypeScript (ES2022), discord.js 14.x, better-sqlite3
- **Repo:** blamechris/repo-relay
- **Main branch:** main
- **CI:** npm test + npm run typecheck
- **Status:** Skills already hardened — gold standard reference

## start-working Customizations

### Ready-to-Work Labels
- `complexity:low` and `complexity:medium` with `testing:low` or `testing:medium` are ready
- Issues with both complexity and testing labels have been triaged

### Blocked Labels
- `blocked`, `wontfix`

### Roadmap File Locations
- Default scan only (`ROADMAP.md`, `TODO.md`, `docs/`)

### Source File Patterns for TODOs
- `src/**/*.ts`

### Priority Signals
- `complexity:low` + `testing:low` → quickest wins, prioritize
- `testing:high` (full GitHub Actions integration testing) → deprioritize (hard to automate)
- Discord API rate limiting issues → P0

### Dependency Check
- `npm outdated` and `npm audit`

### Test Runner
- `npm test` and `npm run typecheck`

### Audit Focus Areas
- Discord embed limits compliance (title 256, desc 4096, fields 25)
- GitHub webhook payload handling robustness
- SQLite concurrency patterns (better-sqlite3)
- Thread management and stale message handling

## check-pr Customizations
- Issue labels: `complexity:low/medium/high`, `testing:low/medium/high`
- Already has Copilot polling (Section 0)
- Already has CI waiting
- Already has mandatory issue creation
- Minor: could add the "3 outcomes only" constraint language from chroxy

## learn Customizations
- **CLAUDE.md sections:** `## Architecture`, `## Discord Integration`, `## GitHub Integration`
- **Rules naming:** kebab-case (e.g., `discord-embeds.md`, `webhook-handling.md`)
- **Domain quality bar:** Discord API limits, GitHub webhook payload quirks, SQLite concurrency patterns qualify as durable insights
- **Common paths:** `src/**/*.ts`

## parallel-dev Customizations

Shares all customization points with autonomous-dev-flow (branch prefix, test runner, decomposition, commit scopes from agent-review/start-working sections).

### Parallel-Specific Settings
- **Default concurrency:** 3
- **Dependency setup in worktree:** `npm install`

## agent-review Customizations

### Persona
**Relay Inspector** — expert in TypeScript, Node.js, discord.js 14.x, GitHub webhooks/API, SQLite/better-sqlite3.

Mindset: "Will this code reliably deliver GitHub event notifications to Discord with clean threading and accurate status?"

### Code Quality
- TypeScript strict mode
- Proper async/await and error handling
- No console.log in production (structured logging)
- discord.js best practices (channel type guards, permission checks)

### Architecture
- Handler pattern: handler function → export → handleEvent routing
- Embed building via buildEmbedWithStatus() / buildPrEmbed()
- Thread operations via getOrCreateThread()
- State management via StateDb
- Stale message handling pattern

### Integration
- GitHub webhook payload types match API docs
- Discord embed limits (title 256, desc 4096, fields 25)
- SQLite parameterized statements
- Event routing in cli.ts mapGitHubEvent()

### Testing
- npm run typecheck passes
- npm run build succeeds
- No formal test framework yet — type safety focus

### Issue Labels
Required on ALL issues:
- `complexity:low` — Single file, < 1 day
- `complexity:medium` — Multiple files, 1-3 days
- `complexity:high` — Architectural, > 3 days
- `testing:low` — Pure logic, unit testable
- `testing:medium` — Requires Discord bot setup
- `testing:high` — Full GitHub Actions integration testing
