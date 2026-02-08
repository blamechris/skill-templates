# Repo Relay Skill Customizations

## Project Context
- **Tech:** Node.js 20+, TypeScript (ES2022), discord.js 14.x, better-sqlite3
- **Repo:** blamechris/repo-relay
- **Main branch:** main
- **CI:** npm test + npm run typecheck
- **Status:** Skills already hardened — gold standard reference

## check-pr Customizations
- Issue labels: `complexity:low/medium/high`, `testing:low/medium/high`
- Already has Copilot polling (Section 0)
- Already has CI waiting
- Already has mandatory issue creation
- Minor: could add the "3 outcomes only" constraint language from chroxy

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
