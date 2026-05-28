# Repo Memory Skill Customizations

## Project Context
- **Tech:** Node.js 20+, TypeScript (ES2022), MCP server (Model Context Protocol)
- **Repo:** blamechris/repo-memory
- **Main branch:** main
- **CI:** npm test + npm run typecheck + npm run build
- **Status:** Greenfield — bootstrapping from empty repo

## start-working Customizations

### Ready-to-Work Labels
- `complexity:low` and `complexity:medium` are ready
- Issues labeled with milestone `V1` take priority over `V2`/`V3`

### Blocked Labels
- `blocked`, `wontfix`, `needs-design-spike`

### Roadmap File Locations
- `docs/planning/architecture.md`, `ROADMAP.md`, `TODO.md`

### Source File Patterns for TODOs
- `src/**/*.ts`

### Priority Signals
- Foundation/infra issues before feature work
- `V1` milestone before `V2`/`V3`
- Issues with no unresolved dependencies first

### Dependency Check
- `npm outdated` and `npm audit`

### Test Runner
- `npm test` and `npm run typecheck`

### Audit Focus Areas
- File hash correctness and cache invalidation
- MCP protocol compliance
- Summary accuracy and staleness detection
- Persistence layer integrity
- Memory/performance with large repos

## check-pr Customizations
- Issue labels: `complexity:low/medium/high`, `testing:low/medium/high`
- CI: typecheck + unit tests + build
- Focus: cache correctness, MCP protocol compliance, no stale data returned

## learn Customizations
- **CLAUDE.md sections:** `## Architecture`, `## MCP Server`, `## Cache/Storage`, `## Testing`
- **Rules naming:** kebab-case (e.g., `cache-invalidation.md`, `mcp-protocol.md`)
- **Domain quality bar:** MCP protocol details, file hashing edge cases, cache invalidation patterns, TypeScript AST/parsing quirks qualify as durable insights
- **Common paths:** `src/**/*.ts`

## agent-review Customizations

### Persona
**Memory Architect** — expert in TypeScript, Node.js, MCP servers, file system APIs, caching systems, AST parsing, and developer tooling.

Mindset: "Will this code reliably reduce token waste and repo re-scanning while never returning stale or incorrect cached data?"

### Code Quality
- TypeScript strict mode
- Proper async/await and error handling
- No console.log in production (structured logging via MCP)
- Cache correctness over cache performance
- Deterministic file hashing

### Architecture
- MCP server: tool handlers exposing get_file_summary, get_changed_files, get_project_map
- Cache engine: file hash tracking, summary storage, invalidation
- Indexer: import/reference extraction, dependency graph
- Task memory: session/task-scoped investigation context
- Persistence: local-first JSON/SQLite storage

### Integration
- MCP protocol compliance (tools, resources, prompts)
- File system watching / polling for change detection
- Git integration for diff-aware updates
- TypeScript/JavaScript AST parsing for import extraction

### Testing
- npm run typecheck passes
- npm test (unit + integration)
- Benchmark fixtures with sample repos
- Cache correctness regression tests

### Issue Labels
Required on ALL issues:
- `complexity:low` — Single file/module, < 1 day
- `complexity:medium` — Multiple modules, 1-3 days
- `complexity:high` — Architectural, cross-cutting, > 3 days
- `testing:low` — Pure logic, unit testable
- `testing:medium` — Requires file system fixtures
- `testing:high` — Full MCP integration testing or benchmark harness

## parallel-dev Customizations

Shares all customization points with autonomous-dev-flow (branch prefix, test runner, commit scopes from agent-review/start-working sections).

### Parallel-Specific Settings
- **Default concurrency:** 3
- **Dependency setup in worktree:** `npm install`

## create-issue Customizations
- Always apply complexity and testing labels
- Apply milestone (`V1`, `V2`, `V3`, or `Hardening`) when clear
- Apply epic label when applicable (e.g., `epic:mcp-server`, `epic:cache-engine`, `epic:indexer`, `epic:task-memory`, `epic:telemetry`, `epic:infra`)

## decompose-issue Customizations
- Default sub-issue labels: ALWAYS apply both `complexity:` and `testing:` labels (mandatory in this repo). Default to `complexity:low` or `complexity:medium` for sub-issues — if any sub-issue still warrants `complexity:high`, split further.
- Inherit the parent's milestone (`V1` / `V2` / `V3` / `Hardening`) on every sub-issue.
- Inherit any `epic:*` label from the parent (e.g., `epic:mcp-server`, `epic:cache-engine`, `epic:indexer`, `epic:task-memory`, `epic:telemetry`, `epic:infra`).
- Parent-link convention: body line "Part of #N" only — no separate `parent:#N` label.
- Sub-issues should align with module boundaries (cache engine vs. indexer vs. MCP protocol surface) when proposing seams.

## create-pr Customizations
- Reference related issue(s)
- Include test plan
- Note cache correctness implications if touching cache/hash logic
