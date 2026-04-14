# MarchBorne Skill Customizations

## Project Context
- **Tech:** Unity 6 (6000.4.2f1), URP, C#, targeting Android/iOS/Steam
- **Repo:** blamechris/MarchBorne
- **Main branch:** main
- **CI:** Not yet set up (GitHub Actions planned for Unity test runner)
- **Status:** Phase 1 (Core Runner) in progress — scaffolding complete, iterating on gameplay
- **Genre:** Medieval army runner / roguelike / auto-battler hybrid

## start-working Customizations

### Ready-to-Work Labels
- No formal `ready-to-build` label yet — treat unblocked, unassigned issues as ready
- Phase label (`phase:1-core-runner`, `phase:2-units-combat`, etc.) denotes priority — work current phase first
- `type:architecture` issues block gameplay issues in the same phase

### Blocked Labels
- `blocked`, `wontfix`, `type:design-gap` (these are open design questions, not implementation)

### Roadmap File Locations
- `Marchborne-GDD-v0.1.docx` (primary design reference — check for updates)
- `CLAUDE.md` (architecture decisions and agent guidelines)
- `SETUP.md` (project setup instructions)

### Source File Patterns for TODOs
- `Assets/Scripts/**/*.cs`

### Priority Signals
- Phase 1 (Core Runner) before Phase 2+
- Foundation/manager classes before gameplay features
- Combat/balance issues blocked on Issue #29 (unit balance numbers)
- Monetization decisions blocked on Issue #34 (Commander Pass concern)

### Dependency Check
- Check `Packages/manifest.json` for Unity package versions
- Verify URP, TextMeshPro, and Input System packages are current

### Test Runner
- Unity Test Framework not yet configured
- Manual play-mode verification via Unity Editor
- When CI is set up: `Unity -batchmode -runTests -testPlatform EditMode`

### Audit Focus Areas
- Swarm performance with 200+ units (mobile target)
- GPU instancing correctness for unit rendering
- Formation/separation algorithm efficiency
- Gate trigger collision reliability
- Procedural generation coherence (segment chaining, difficulty curve)
- Meta progression save integrity (when implemented)

## check-pr Customizations
- Issue labels: `phase:*`, `system:*` (units/gates/combat/procedural/meta/ui/audio), `type:*` (architecture/gameplay/art/design-gap)
- CI not yet configured — focus on: scripts compile, scene loads, no runtime errors in play mode
- Unity .meta files must be committed alongside asset changes
- Verify no Unity scene/prefab YAML was edited by hand (per CLAUDE.md)

## learn Customizations
- **CLAUDE.md sections:** `## Tech Stack`, `## Key Architecture Decisions`, `## Agent Guidelines`
- **Rules naming:** kebab-case (e.g., `swarm-performance.md`, `urp-materials.md`, `unity-batch-mode.md`)
- **Domain quality bar:** Unity-specific gotchas (URP material keywords, batch mode quirks, GPU instancing edge cases, DOTS considerations for 200+ units), cross-platform mobile performance patterns, ScriptableObject best practices qualify as durable insights
- **Common paths:** `Assets/Scripts/**/*.cs`, `Assets/ScriptableObjects/**/*.asset`, `Assets/Scenes/*.unity`

## agent-review Customizations

### Code Quality
- C# modern patterns (target-typed new, switch expressions, nullable reference types where practical)
- Unity performance: avoid allocations in Update loops, use object pooling, prefer struct for data types
- Balance values MUST live in ScriptableObjects, never hardcoded
- Namespaced by system: `Marchborne.Core`, `Marchborne.Units`, `Marchborne.Gates`, etc.
- PascalCase for public members, `_camelCase` for private fields

### Architecture
- Swarm-based unit simulation (units follow leader, NOT individually AI-controlled)
- Data-driven via ScriptableObjects (UnitConfig, GateConfig, BiomeConfig, SegmentConfig, CombatMatrix)
- Singleton pattern for managers with `DontDestroyOnLoad` where appropriate
- PVP uses snapshot-based async resolution, NOT real-time netcode
- GPU instancing required for unit rendering

### Testing
- Unity Test Framework not yet configured — when added, use EditMode tests for logic, PlayMode tests for integration
- Manual play-mode verification required until automated tests exist
- All new features must include "how to test manually" steps in the PR description

### Unity-Specific Constraints
- Agents MUST NOT edit `.meta` files or scene/prefab YAML directly — use Unity Editor scripts (like `ProjectBootstrapper` or `SceneBuilder`) to generate them
- Focus agent work on: C# scripts, ScriptableObject definitions, editor tooling, build configurations
- CLAUDE.md must be updated when architectural decisions change

## parallel-dev Customizations
- **Default concurrency:** 2 (Unity builds are heavy, especially URP shader compilation)
- **Dependency setup in worktree:** Open Unity once to resolve packages, then close

## tackle-issues Customizations

### Branch Prefix
- `feature/` for new features (per GDD Section 10.1)
- `fix/` for bug fixes
- `chore/` for tooling/CI/docs

### Skip Labels
- `type:design-gap` (open design questions, not implementation)
- `blocked`, `wontfix`

### Decomposition Trigger
- Issues with multiple systems involved (spanning `system:units` + `system:combat` + `system:ui`, for example)
- Issues with "300+ nodes", "all 6 biomes", "all modes" scope

### Commit Scopes
- Match system labels: `units`, `gates`, `combat`, `procedural`, `meta`, `ui`, `audio`, `core`
- Example: `feat(units): add archer projectile auto-fire`

### PR Test Plan Items
- "Open Unity project and verify scripts compile without errors"
- "Open Assets/Scenes/GameScene and hit Play"
- "Verify no console errors/warnings related to this change"
- "Manual gameplay verification (specify what to test)"
