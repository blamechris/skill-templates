# Exodus Loop Skill Customizations

## Project Context
- **Tech:** Godot 4.5, GDScript, Mobile-first (720x1280)
- **Repo:** blamechris/exodus-loop
- **Main branch:** main
- **CI:** Attribution check + Godot export pipeline
- **Commercial:** Intended for sale — asset licensing critical

## Merge Gate
- **Enabled:** Yes — branch protection requires conversation resolution
- See `generic/merge-gate.md` for the CLAUDE.md snippet
- Already added to exodus-loop CLAUDE.md (2026-02-09)

## check-pr Customizations
- Issue labels: `complexity:low/medium/high`, `smoke-test:low/medium/high`
- Add Copilot polling (Section 0 from generic template)
- Asset licensing awareness: flag any new assets without CREDITS.md entry

## learn Customizations
- **CLAUDE.md sections:** `## GDScript Patterns`, `## Architecture`, `## Testing`
- **Rules naming:** kebab-case (e.g., `gdscript.md`, `combat-system.md`)
- **Domain quality bar:** GDScript engine quirks, game balance insights (e.g., "enemy HP formula breaks at wave 15+"), Godot lifecycle gotchas qualify as durable insights
- **Common paths:** `scripts/**/*.gd`, `scenes/**/*.tscn`

## agent-review Customizations

### Persona
**Loop Inspector** — expert in Godot 4.5, GDScript, mobile game development, turn-based combat systems, roguelike design patterns.

Mindset: "Does this maintain game feel while being performant on mobile?"

### Code Quality
- GDScript style (snake_case, type hints where useful)
- Signal pattern for component communication
- Resource management (preload vs load, scene tree cleanup)
- No blocking operations in _process or _physics_process

### Architecture
- GDD alignment (game design document is source of truth)
- Combat system: turn-based on N×M grid
- State machine patterns for game/battle states
- Scene tree organization follows established hierarchy

### Game Design
- Balance changes must reference GDD
- New mechanics need design rationale
- UI changes must work at 720x1280

### Testing
- TDD mandatory (RED-GREEN-REFACTOR)
- Unit tests via GUT framework
- Smoke tests for critical gameplay paths

### Asset Licensing
- All assets must be CC0 or permissive (MIT/Apache/BSD)
- NO CC-BY-NC, CC-BY-SA, or personal-use-only
- New assets need CREDITS.md entry

## autonomous-dev-flow Customizations

### Branch Naming
- Use `feat/`, `fix/`, `test/`, `refactor/` prefixes (per commit type) instead of generic `auto/`
- Format: `feat/description-#123`

### Test Runner
- Command: `godot --headless res://test/test_runner.tscn` (MUST use scene, not `--script`)
- Timeout: `timeout 60 godot --headless res://test/test_runner.tscn`
- Gotcha: `IntentGridRules` alias — tests use `IntentGridRules.`, not `GridRules.`
- Gotcha: Parse errors in `test_runner.gd` cause Godot to hang indefinitely (no exit code)

### Decomposition Threshold
- `complexity: high` triggers auto-decomposition
- Sub-issues get `complexity:` and `smoke-test:` labels (required by project)

### Skip Labels
- `blocked`, `wontfix` — skip silently
- Phase 5 store/deployment tasks — skip with comment

### PR Test Plan Items
```markdown
- [ ] Tests pass (`godot --headless res://test/test_runner.tscn`)
- [ ] CI checks pass (attribution, debug flags, lint)
- [ ] No debug flags left enabled in `debug_config.gd`
- [ ] Manual verification on 720x1280 mobile viewport (if UI changes)
```

### Commit Scopes
- `battle`, `combat`, `ui`, `core`, `node-map`, `carrier`, `replay`, `audio`, `polish`

### Pre-Skill Checkpoint
- MANDATORY before `/full-review` — re-read CLAUDE.md and skill files
- Exodus Loop has a formal Pre-Skill Checkpoint Protocol in CLAUDE.md

### Resume Strategy
- Branch prefix detection: `feat/`, `fix/`, `test/`, `refactor/` (not `auto/`)
- Check for PRs referencing issue numbers in title
