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
