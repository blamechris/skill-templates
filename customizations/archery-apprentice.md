# Archery Apprentice Skill Customizations

## Project Context
- **Tech:** Kotlin Multiplatform (KMP), Android/iOS, Jetpack Compose
- **Repo:** blamechris/archery-apprentice
- **Main branch:** main
- **CI:** ktlintCheck + detekt + testDebugUnitTest
- **Multi-agent:** AAP, AAM, AAA, Agent-D, Orchestrator

## check-pr Customizations
- Issue labels: match existing label system (needs audit — currently no required labels)
- Add Copilot polling (Section 0 from generic template)
- Add mandatory issue creation (currently missing entirely)
- Preserve multi-agent coordination references

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
