# Exodus Loop Skill Customizations

## Project Context
- **Tech:** Godot 4.5, GDScript, Mobile-first (720x1280)
- **Repo:** blamechris/exodus-loop
- **Main branch:** main
- **CI:** Attribution check + Godot export pipeline
- **Commercial:** Intended for sale — asset licensing critical

## Merge Gate
- **Enabled:** Partial — `required_conversation_resolution` removed (2026-03-01)
- Branch protection still enforces CI and stale review dismissal
- Merge gate pattern in CLAUDE.md updated to reflect new behavior
- See `generic/merge-gate.md` for history

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

## start-working Customizations

### Ready-to-Work Labels
- `complexity:low` and `complexity:medium` issues with acceptance criteria are ready
- Issues with `smoke-test:` labels have been triaged and are ready

### Blocked Labels
- `blocked`, `wontfix`
- Phase 5 store/deployment tasks — not automatable

### Roadmap File Locations
- `docs/GDD_ORIGINAL.md` (Game Design Document — source of truth for planned features and mechanics)
- Default scan locations (`ROADMAP.md`, `TODO.md`, `docs/`)

### Source File Patterns for TODOs
- `src/**/*.gd`
- `src/**/*.tscn` (less common but possible)

### Priority Signals
- `complexity:low` → prioritize (quick wins)
- `complexity:high` → note for decomposition, not direct work
- GDD sections marked "Planned" or "TODO" indicate upcoming features

### Dependency Check
- No package manager — Godot addons checked manually
- GUT test framework updates checked via `addons/gut/`

### Test Runner
- `timeout 60 godot --headless res://test/test_runner.tscn`

### Audit Focus Areas
- Game balance and GDD alignment
- Asset licensing (all assets must be CC0 or permissive)
- GDScript performance in _process/_physics_process
- Scene tree organization and signal patterns

## autonomous-dev-flow Customizations

### Branch Naming
- Use `feat/`, `fix/`, `test/`, `refactor/` prefixes (per commit type) instead of generic `auto/`
- Format: `feat/${ISSUE_NUM}-description` (number first, matching generic template pattern)

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

## tackle-issues Customizations

Shares all customization points with `autonomous-dev-flow` above (branch naming, test runner, decomposition, skip labels, PR test plan, commit scopes, pre-skill checkpoint, resume strategy).

### Additional Marathon-Specific Settings
- **Default max:** 15 (exodus-loop issues tend to be interconnected — smaller batches reduce cross-issue conflicts)
- **Default waves:** 3
- **merge:true safe:** Yes — CI is fast (self-hosted, ~90s) and branch protection handles safety
- **Wave 2 focus:** Re-read GDD for context on retry — game mechanics issues often fail because the first approach misses a GDD constraint
- **Wave 3 simplification:** For game mechanics issues, prefer implementing the "minimum playable version" over full spec — create follow-up issues for polish/edge cases

## fix-ci Customizations

### CI Workflow
- Name: `CI` (single workflow in `.github/workflows/ci.yml`)
- Runner: self-hosted (fast, ~2 min)
- Concurrency: `${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`

### Event Mapping
- `pull_request` → full CI suite (Check Skip, Attribution, Lint, Debug Flags, Validate, Run Tests)
- `pull_request_review` → `notify` job only (NOT full CI)
- `workflow_dispatch` → full CI suite

This matters for cancellation diagnosis: when review-agent pushes fix commits, the new `pull_request` event cancels the in-progress run. If the replacement event is `pull_request_review` (only `notify`), the full suite never re-runs.

### Known Failure Patterns
| Job | Pattern | Outcome | Fix |
|-----|---------|---------|-----|
| Run Tests | No output + timeout (>60s) | ESCALATE | Parse error in `test_runner.gd` — needs manual investigation |
| Run Tests | `N failed` in output | ESCALATE | Actual test failure — report failing test names |
| Check Debug Flags | Flags enabled | FIX | Set flags to `false` in `src/autoload/debug_config.gd` |
| Check Attribution | Policy violation | ESCALATE | Can't rewrite pushed history — requires force push or new commits |
| Lint GDScript | Style errors | ESCALATE | Varied fixes, needs case-by-case review |

### Re-trigger Preference
1. `gh run rerun <id> --failed` (preferred — fast, targeted, re-runs only failed/cancelled jobs)
2. Close/reopen PR (fallback if `gh run rerun` doesn't work)
3. Avoid empty commits (project has strict commit history conventions)

### CI Timeout
- 3 minutes (self-hosted runner is fast)
- Use `MAX_WAIT=180` and `INTERVAL=30`

## fetch-docs Customizations

### Companion Repo
- **Repo:** `blamechris/exodus-loop-docs`
- **Local path:** `~/Projects/exodus-loop-docs`
- **Type:** Obsidian vault (markdown notes)

### Key Docs
| Doc | Path | Description |
|-----|------|-------------|
| Game Design Document | `GDD/` | Source of truth for game mechanics, balance, combat system |
| Architecture Notes | `Architecture/` | System design, scene tree organization, state machines |
| Art Direction | `Art/` | Visual style guide, asset requirements, palette |
| Session Logs | `Sessions/` | Development session summaries and decisions |

### Search Patterns
- `*.md` (Obsidian markdown)

## batch-merge Customizations

### Required CI Checks
- `Run Tests`, `Validate Project` (from branch protection rules)

### Merge Strategy
- `--squash` (per CLAUDE.md convention)

### CI Timing
- Self-hosted runner — CI completes in ~90s
- `MAX_WAIT=180`, `INTERVAL=30`

### Copilot Wait
- 8 minutes max (matching check-pr timeout)
- Copilot typically arrives in 3-5 min

### Concurrency
- CI uses `cancel-in-progress: true` per branch
- After update-branch, wait for the NEW run (not the cancelled one)

### Stale Reviews
- `dismiss_stale_reviews: true` — pushing fix commits invalidates Copilot review
- Must wait for fresh Copilot review cycle after any push

### Branch Protection (as of 2026-03-01)
- `required_conversation_resolution: false` — removed to enable batch-merge without human thread resolution
- CI checks still required (`strict: true`)
- Stale reviews still dismissed on push

### Fix Commits
- Zero Attribution Policy applies
- Pre-commit hook validates author
- Use `from-review` label on any follow-up issues created
