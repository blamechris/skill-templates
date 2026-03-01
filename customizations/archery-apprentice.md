# Archery Apprentice Skill Customizations

## Project Context
- **Tech:** Kotlin Multiplatform (KMP), Android/iOS, Jetpack Compose
- **Repo:** blamechris/archery-apprentice
- **Main branch:** main
- **CI:** ktlintCheck + detekt + testDebugUnitTest
- **Multi-agent:** AAP, AAM, AAA, Agent-D, Orchestrator

## start-working Customizations

### Ready-to-Work Labels
- No formal `ready-to-build` label — treat unblocked, unassigned issues as ready
- Issues with acceptance criteria rank higher

### Blocked Labels
- `blocked`, `wontfix`, `needs-design`

### Roadmap File Locations
- `TDD_MODUS_OPERANDI.md` (testing methodology doc — may contain planned testing work)
- Default scan locations (`ROADMAP.md`, `TODO.md`, `docs/`)
- Multi-agent coordination files on `agent-coordination` branch (informational only)

### Source File Patterns for TODOs
- `shared/src/**/*.kt`
- `androidApp/src/**/*.kt`
- `iosApp/**/*.swift`

### Priority Signals
- Multi-agent coordination: check `orchestrator-current.md` on `agent-coordination` branch for session context
- Firebase auth issues → P0 (auth is critical path)
- Platform parity issues → P1 (features must work on both Android and iOS)

### Dependency Check
- `./gradlew dependencyUpdates` (if Gradle Versions Plugin is configured)
- `./gradlew ktlintCheck detekt` for code quality

### Test Runner
- `./gradlew testDebugUnitTest`

### Audit Focus Areas
- KMP shared vs platform-specific boundary
- Compose recomposition performance
- Firebase auth timing issues
- Platform parity (Android vs iOS feature coverage)

## check-pr Customizations
- Issue labels: match existing label system (needs audit — currently no required labels)
- Add Copilot polling (Section 0 from generic template)
- Add mandatory issue creation (currently missing entirely)
- Preserve multi-agent coordination references

## learn Customizations
- **CLAUDE.md sections:** `## Kotlin/KMP Patterns`, `## Architecture`, `## Testing`
- **Rules naming:** kebab-case (e.g., `compose.md`, `kmp-shared.md`)
- **Domain quality bar:** KMP shared/platform boundary quirks, Compose recomposition gotchas, Firebase auth timing issues qualify as durable insights
- **Common paths:** `shared/src/**/*.kt`, `androidApp/src/**/*.kt`, `iosApp/**/*.swift`
- **Note:** Only Orchestrator may modify CLAUDE.md — learn proposals targeting CLAUDE.md should note this constraint

## agent-review Customizations

### Persona
**Agent 3 (AAA)** — Analysis/Testing agent in multi-agent coordination system.

Scoring: Code quality (0-2), Architecture (0-2), Testing (0-2), Security (0-2), Platform parity (0-2) = X/10.

### Code Quality
- Kotlin strict (no `!!`, prefer safe calls)
- Jetpack Compose best practices
- Coroutine patterns (structured concurrency)
- Firebase auth: capture currentUser BEFORE launching coroutines

### Architecture
- KMP shared module for business logic
- Platform-specific implementations in androidApp/iosApp
- ViewModel + Repository pattern
- Enum evolution: additive changes only, never rename/remove

### Testing
- TDD mandatory (RED-GREEN-REFACTOR per TDD_MODUS_OPERANDI.md)
- 3-layer testing: assertExists (80%), scroll tests (5%), assertIsDisplayed (15%)
- `./gradlew ktlintCheck detekt testDebugUnitTest` must pass

### Platform Parity
- Features must work on both Android and iOS
- KMP shared code preferred over platform-specific
- iOS KMP quirks documented in CLAUDE.md

### Multi-Agent Coordination
- Update agent-3-current.md on agent-coordination branch
- Check orchestrator-current.md for session context
- Only Orchestrator may modify CLAUDE.md

## fetch-docs Customizations

### Companion Repo
- **Repo:** `blamechris/archery-apprentice-docs`
- **Local path:** `~/StudioProjects/archery-apprentice-docs`
- **Type:** Obsidian vault (markdown notes)

### Key Docs
| Doc | Path | Description |
|-----|------|-------------|
| Architecture | `Architecture/` | KMP module structure, platform boundaries, data flow |
| Multi-Agent | `Agents/` | Agent coordination protocol, role definitions, session logs |
| UI/UX | `Design/` | Screen flows, Compose component patterns, accessibility |
| Session Logs | `Sessions/` | Development session summaries and decisions |

### Search Patterns
- `*.md` (Obsidian markdown)
