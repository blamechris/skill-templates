# no-it-all Skill Customizations

## Project Context
- **Tech:** Swift 5, AppKit (`NSPanel` stealth window) + SwiftUI (`NSHostingView` chat UI), macOS 14+
- **Build system:** XcodeGen — `project.yml` is the source of truth, `NoItAll.xcodeproj` is git-ignored and regenerated
- **Repo:** blamechris/no-it-all
- **Main branch:** main
- **CI:** none yet — the build *is* the gate (`xcodebuild … build`)
- **Status:** Greenfield personal tool. Scoping locked (see `docs/SCOPING.md`); all four hard requirements working (capture-invisible, no focus theft, global hotkey, Anthropic LLM chat).
- **Hard requirements (never regress):** capture-invisible panel (`sharingType = .none`), non-activating `NSPanel` (no focus theft), always-on-top + Carbon global hotkey ⌘⇧\, lightweight.

## Build / Test Commands
- **Regenerate project** (after editing `project.yml` or adding/removing source files): `xcodegen generate`
- **Build (the gate):** `xcodebuild -project NoItAll.xcodeproj -scheme NoItAll -configuration Debug build`
- **No test target yet** — there are no unit tests. A green build + manual smoke test (launch, ⌘⇧\ summon, ask a question) is the bar. A `Tests/` target is a future addition.
- **Lint/typecheck:** the Swift compiler via the build above. No SwiftLint configured.

## Branch & Commit Conventions
- **Autonomous session branch prefix:** `auto/`
- **Branch naming:** `auto/<number>-<slug>`
- **Commit style:** conventional commits (matches CLAUDE.md), e.g. `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`
- **Commit scopes:** `panel` (StealthPanel/window), `hotkey` (HotKeyManager), `llm` (AnthropicClient/ConversationModel), `ui` (ContentView), `core`, `build` (project.yml/XcodeGen)
- **Source file patterns:** `Sources/NoItAll/**/*.swift`

## start-working Customizations

### Ready-to-Work Labels
- `complexity:low` and `complexity:medium` are ready
- `ready-to-build` marks explicitly-queued issues

### Blocked Labels
- `blocked`, `wontfix`, `needs-design-spike`

### Roadmap File Locations
- `docs/SCOPING.md` (living spec / decisions), `README.md` ("Current state of the build")

### Source File Patterns for TODOs
- `Sources/NoItAll/**/*.swift`

### Priority Signals
- Anything that protects the hard requirements (capture-invisibility, focus, hotkey) first
- `complexity:low` before `medium`; skip `complexity:high` (decompose first)
- Issues with no unresolved dependencies first

### Dependency Check
- No package manager yet (no SwiftPM/CocoaPods). Skip dependency-audit steps until one is added.

### Test Runner
- `xcodebuild -project NoItAll.xcodeproj -scheme NoItAll -configuration Debug build` (build is the gate)

### Audit Focus Areas
- Capture-invisibility holds across recorders (QuickTime, OBS, Zoom, ScreenCaptureKit, native screenshot)
- No focus theft regressions (non-activating panel semantics)
- API key never logged or written outside the Keychain
- Hotkey registration/cleanup correctness
- Lightweight: cold-start time, idle CPU

## decompose-issue / autonomous-dev-flow Customizations
- **Decomposition trigger label:** `complexity:high`
- **Branch prefix:** `auto/` → `auto/<number>-<slug>`
- **Test runner:** `xcodebuild -project NoItAll.xcodeproj -scheme NoItAll -configuration Debug build`
- **Test file conventions:** none yet (no test target)
- **Lint/typecheck:** covered by the build (Swift compiler); no separate linter
- **Commit scopes:** `panel`, `hotkey`, `llm`, `ui`, `core`, `build`
- **PR test plan items:**
  - `- [ ] Builds clean (xcodebuild)`
  - `- [ ] App launches; ⌘⇧\ summons/dismisses the overlay`
  - `- [ ] Overlay still capture-invisible and non-activating (no focus theft)`
- **Smoke-test condition:** run when the change touches UI/window code — pattern `ContentView|StealthPanel`

## create-issue Customizations
- **Origin line:** `Found during review of PR #N` when from a PR; otherwise `From the no-it-all roadmap (docs/SCOPING.md).`
- **Complexity labels:** yes — use `complexity:low|medium|high`

## check-pr Customizations
- Issue labels: `complexity:low/medium/high`
- CI: none — reviewer must confirm a clean `xcodebuild` build locally
- Focus: stealth requirements intact, Keychain key hygiene, no focus theft

## learn Customizations
- **CLAUDE.md sections:** `## Core requirements`, `## Conventions`
- **Rules naming:** kebab-case (e.g., `stealth-panel.md`, `keychain-key.md`)
- **Domain quality bar:** macOS window/`NSPanel` semantics, capture-exclusion quirks across macOS versions, Carbon hotkey gotchas, Keychain access patterns, Anthropic streaming SSE parsing
- **Common paths:** `Sources/NoItAll/**/*.swift`

## agent-review Customizations

### Persona
**macOS Stealth-Overlay Engineer** — expert in AppKit/`NSPanel`, SwiftUI interop, macOS window/capture/Spaces semantics, Carbon hotkeys, Keychain Services, and the Anthropic Messages API.

Mindset: "Does this keep the overlay invisible to capture, never steal foreground focus, stay lightweight, and keep the API key in the Keychain — while the LLM path stays correct?"
