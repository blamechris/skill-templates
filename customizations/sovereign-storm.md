# Sovereign Storm Skill Customizations

## Project Context
- **Tech:** TypeScript (strict), Phaser 3 (client), Colyseus 0.16 + @colyseus/schema 3.0.76 (server), Vite (client bundler), tsx (server dev), pnpm + monorepo (`packages/{shared,client,server}`).
- **Repo:** blamechris/sovereign-storm
- **Main branch:** main
- **CI:** Not yet set up (planned: GitHub Actions running `pnpm -r typecheck`).
- **Status:** Step 6 milestone in progress — Voyage mode foundation (hotspot system + cargo + economy refactor + cannon/vessel asymmetry). PvE expedition modes (#47, #51) and procedural generation (#52) are the next major arcs.
- **Genre:** TypeScript/Phaser/Colyseus port of Obsidio (a libGDX Puzzle Pirates blockade simulator).

## Inspiration / Source Material
- **Obsidio**: 4-slot move planning (forward / left / right / stall), L-shape movement, wind tiles, whirlpools, flag capture scoring.
- **Puzzle Pirates**: Atlantis (citadel timed events), Haunted Seas (depth-zone scaling, sink-loses-the-map), Cursed Isles (captain-decides-when-to-extract). The PP puzzle layer is intentionally NOT ported — the navigation board itself is the puzzle.

## Critical: Schema Sync Workaround
**Colyseus 0.16 + schema 3.0.76 does not propagate primitive Schema field mutations to clients.** Confirmed empirically: `state.greenScore += 1` reaches 30+ on the server while the client still reads 0.

**Pattern:** Broadcast a custom typed message instead of relying on `room.onStateChange`. See `MSG_SCORE`, `MSG_FLAGS`, `MSG_HOTSPOTS`, `MSG_EVENTS` in `packages/shared/src/index.ts` and the corresponding `broadcastScore()` / `broadcastPlayers()` helpers in `BattleRoom.ts`. Schema-defined fields can stay in place (server resolver reads naturally) — they're just not the wire format.

**What NOT to do:** Don't reach for `setState()` or assume schema sync will work for any new primitive. Always use a custom broadcast.

## Hotspot Effect-List Architecture (#50)
The hotspot system is the load-bearing flexibility surface: every dockable interaction is data, not code paths.

- `Hotspot.effects: Effect[]` — declarative list applied in order on each successful Dock action.
- `Effect` variants: `log / heal / damage / score / buff / cargo / extract`. Adding a new variant = one new case in server `applyEffect`.
- `HOTSPOT_REGISTRY` in `packages/shared/src/map.ts` — maps each `HotspotKind` to label + charges + default effects.
- New hotspot kinds (e.g., "speed-shrine", "kraken-portal") are pure data: register in `HOTSPOT_REGISTRY` + add a tile constant + add a case in `hotspotKindForTile` + add a draw case in `renderHotspotOverlay`. No resolver changes required for kinds that compose existing effects.

**When adding a new mechanic that affects ships:** prefer a new Effect variant + applyEffect case over per-feature server logic. The dispatcher is the single point of mutation.

## Per-Player Buff System (#50)
- `PlayerInfo.buffs: ActiveBuff[]` — timed magnitude stacks (e.g., damage-bonus +1 for 3 turns).
- Tick at top of `resolveTurn` (`tickBuffs`); cleared on sink + match start (clean break).
- Cannon damage reads via `buffMagnitude(p, "damage-bonus")` + base from `VESSEL_CANNON_DAMAGE`.
- Adding a new buff kind: extend `BuffKind` union, add a reader (e.g., `cannonRangeFor(p)` reads "range-bonus" stack), wire into the system that consumes it.

## Token Pool Economy (#42)
- `PlayerInfo.tokenPool: { forward, left, right }` regenerates progressively each `resolveTurn`.
- Order: `tickBuffs → deductPlanCosts → applyRespawns → regenTokenPools`.
- Per-vessel `VESSEL_TOKEN_START / REGEN / MAX` tables — sloops weave (high lateral regen), frigates plow forward but turning is rare.
- Plans validated server-side via `poolCovers(pool, planTokenCost(moves))` in `MSG_SET_MOVES`.

## Cannon Reload Model (Step 6e)
- **Infinite ammo, per-side reload.** Each side reloads independently for `VESSEL_RELOAD_SLOTS[vessel]` slots after firing.
- `simulateCannonPlan(vessel, cannons)` is the single legality check, used by client toggle-disable, server validation, and bot planner.
- Cannon damage = `VESSEL_CANNON_DAMAGE[vessel] + buffMagnitude(p, "damage-bonus")`.
- Reload state resets between turns (within-turn discipline only — keep this; cross-turn would require additional state machinery).

## Vessel Asymmetry (#48)
- Three roles: **Sloop "Runner"** / **Brigantine "Balanced"** / **Frigate "Escort"**.
- Differentiated stats: HP (6/10/16), Hold (3/6/10), Range (3/4/5), Cannon dmg (1/2/3), Reload (0/1/2 slots), Token pools.
- `VESSEL_ROLE` label surfaces in lobby picker, in-match captain card, and Help-modal Legend.
- Deferred: `dockTurns` (multi-turn docking for frigates) — was scoped out of the initial #48 commit. Add as a follow-up if procedural / Voyage mode needs it.

## Repo Conventions

### No Emoji in Code or UI
**Per existing convention:** UI strings, commit messages, and code comments avoid emoji. The captain card uses text labels (e.g., "Cargo 3/5", not "📦 3/5"). Move glyphs use unicode arrows (↑ ↖ ↗ ·) — these are text, not emoji.

The one exception is `⚓` for the Dock action glyph (already shipped in Step 6a). Don't add new emoji to UI text without checking with the user.

### Attribution Policy
**OK to include `Co-Authored-By: Claude` in commits** for this repo. (Differs from explAIn/skill-templates where attribution is forbidden.) Keep the commit footer line in this format:
```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

### Commit Message Style
- Subject line: `Step Nx: short description (#issue-or-pr-ref)` where `Nx` is the milestone step letter.
- Body: explain *what* changed, *why*, and any deferred follow-ups.
- Example: `Step 6f: vessel asymmetry — cargo + token pools + role labels (#48)`.

### Branch Naming
- `feature/<short-slug>` for feature branches (e.g., `feature/hotspot-system`).
- `fix/<short-slug>` for bug fixes.
- Direct commits to `main` only for trivial doc/config tweaks.

## start-working Customizations

### Ready-to-Work Labels
- No formal `ready-to-build` label — treat unblocked, unassigned issues as ready.
- `priority:high` are next-up; `priority:med` and `priority:low` queue after.
- Open epic: #31 (roadmap umbrella) + #49 (Voyage mode epic).

### Blocked Labels
- `wontfix` (e.g., #40 mid-match team change — parked).
- `epic` (umbrella issues — don't tackle directly; pick a sub-issue instead).

### Roadmap File Locations
- Issue #31 — Sovereign Storm Roadmap & Tracking (the live source of truth).
- Issue #49 — Voyage mode epic.
- `ASSETS.md` — Kenney pack license + per-asset provenance.
- `packages/client/public/assets/LICENSE.md` — asset attributions.

### Source File Patterns for TODOs
- `packages/shared/src/**/*.ts`
- `packages/server/src/**/*.ts`
- `packages/client/src/**/*.ts`

### Priority Signals
- `priority:high` first. Within tier, prefer issues that unblock others (architecture / substrate before features).
- Voyage-mode sub-issues (#45–48) build on each other in order; respect the build order from the epic.

### Dependency Check
- `pnpm install` after pulling. Workspace deps in `pnpm-workspace.yaml`.
- TypeScript strict mode across all three packages — run `pnpm -r typecheck` before declaring work complete.

### Test Runner
- No automated test suite yet. Manual verification on the dev server (`pnpm dev` from repo root) is the current gate.
- "Test path" in the PR description should list the manual flow to verify the change.

## check-pr Customizations

### Issue Labels
- Areas: `area:gameplay` / `area:ai` / `area:visual` / `area:audio` / `area:ui` / `area:lobby` / `area:infra`.
- Priority: `priority:high` / `priority:med` / `priority:low`.
- Special: `epic` (umbrella tracking), `wontfix`, `bug`, `documentation`.

### Code Style
- TypeScript strict, ESM, no `any` in new code.
- Functional helpers preferred over class methods for pure data transforms (see `simulateCannonPlan`, `planTokenCost` in shared).
- Comments explain *why*, not *what* — well-named identifiers handle the *what*.

### Evidence Patterns
- "per CLAUDE.md / customizations/sovereign-storm.md: <constraint>"
- "per the schema sync gap memory: use a custom broadcast, not state mutation"
- "per the effect-list architecture: prefer a new Effect variant over an inline branch"

### Manual Test Plan
- New mechanics need a "how to test" section in the PR body — exact map / vessel / steps to verify the change.
- Voyage Test map (`voyage-test`) is the canonical hotspot/cargo testbed. Use it for any change touching the hotspot, cargo, buff, or token-pool systems.

## learn Customizations

### CLAUDE.md Sections to Update
The repo doesn't have a CLAUDE.md yet — durable insights go into the customizations file (this one) directly under the relevant section. When CLAUDE.md is added, mirror the section structure: Project Context, Tech Stack, Critical Patterns, Architecture, Conventions.

### Rules Naming
kebab-case (e.g., `colyseus-schema-sync.md`, `hotspot-effects.md`, `vessel-asymmetry.md`).

### Domain Quality Bar
Insights worth recording:
- Colyseus / @colyseus/schema interaction quirks (the schema-sync gap is the canonical example)
- Phaser depth ordering for layered sprites/graphics (terrain 0 / hotspots 4 / flags 5 / ships 10 / VFX 15)
- Plan-resolution ordering (the `tickBuffs → deductPlanCosts → applyRespawns → regenTokenPools` sequence is load-bearing)
- Per-vessel tuning numbers when they're tweaked from the current defaults

### Common Paths
- `packages/shared/src/index.ts` — schema, message types, vessel constants, helpers
- `packages/shared/src/map.ts` — tile constants, hotspot registry, map definitions
- `packages/server/src/rooms/BattleRoom.ts` — the resolver + room state machine (single ~2000 line file)
- `packages/client/src/scenes/BattleScene.ts` — Phaser scene + HUD rendering (single ~2200 line file)
- `packages/client/src/styles.css` — UI styles

## agent-review Customizations

### Persona
**Sovereign Storm Inspector** — expert in TypeScript-strict monorepos, Phaser 3 scene graphs / depth ordering, Colyseus 0.16 room lifecycle + schema sync quirks, multiplayer turn-based simulation, push-your-luck game loops, and the Obsidio / PP blockade-nav lineage.

Mindset: *"Does this respect the effect-list architecture (data over branching)? Does any new state need a custom broadcast (the schema sync gap)? Does the resolveTurn ordering still hold? Does the manual test path exercise the change end-to-end? Are vessel asymmetry knobs being added or just tuned?"*

### Code Quality
- TypeScript strict, ESM, no `any` in new code; prefer typed unions over enum strings.
- Pure functions in shared (no side effects); stateful resolution in server only.
- Phaser display objects need explicit `setDepth()` — depth ordering is load-bearing (Step 4 had a regression where ships rendered under terrain because the depth wasn't set).
- Cannon / move / hotspot legality checks live in shared helpers (`simulateCannonPlan`, `poolCovers`, etc.) so client preview and server validation read the same source.

### Architecture
- **Authoritative server, optimistic client.** Server is source of truth; client predicts only what's safe (slot cycle filtering, cannon button disable). Server always re-validates and silently no-ops illegal plans.
- **Custom broadcasts for any state that reaches the client.** Schema-defined fields are fine for server-internal reads but never trust them for client sync.
- **Effect-list dispatch over branching.** New hotspot interactions = new Effect variant + new applyEffect case + registry entry. Don't add per-kind branches to resolveActionsForStep.
- **Plan-resolution ordering is load-bearing.** Changes to `tickBuffs → deductPlanCosts → applyRespawns → regenTokenPools` need a deliberate justification — the order encodes whether buffs/respawns/regen apply to the *current* turn or the *next*.

### Testing
- No automated tests yet. Manual verification on the dev server is the gate.
- For any new mechanic: PR description must include a "Test path" section with map / vessel / step-by-step verification.
- Type checking (`pnpm -r typecheck`) must pass before declaring work complete.

### Phaser-Specific Constraints
- Don't create graphics in render functions called per-frame; cache and re-render on state change only.
- TileSprite + setTint is the canonical pattern for tinted-tile water (see `mapGraphics`).
- Depth assignments: terrain=0, decoration overlay=2, hotspots=4, flags=5, ships=10, effects=15+.

## parallel-dev Customizations

### Default Concurrency
- 2 (TypeScript builds + tsx watch are reasonably parallel; Vite hot-reload is fast).

### Dependency Setup in Worktree
- Run `pnpm install` after creating worktree (workspace symlinks recreate per-worktree).
- Don't re-run if `pnpm-lock.yaml` hasn't changed — the install is no-op.

## tackle-issues Customizations

### Branch Prefix
- `feature/<slug>` for new features (e.g., `feature/voyage-rules`, `feature/procedural-hotspots`).
- `fix/<slug>` for bugs.
- `chore/<slug>` for refactors / tooling / docs.

### Skip Labels
- `wontfix`, `epic` (don't pick the umbrella; pick a sub-issue).

### Decomposition Trigger
- Issues spanning multiple packages (`shared` + `server` + `client`) — fine if cohesive, but each package change should be a coherent commit within the same PR.
- "All maps", "all vessels", "all hotspot kinds" scope — break into per-axis sub-issues unless it's a uniform refactor.

### Commit Scopes
- Match issue-area labels where possible: `gameplay`, `ai`, `visual`, `audio`, `ui`, `lobby`, `infra`.
- Step prefix is the milestone tracking convention: `Step 6f: vessel asymmetry — cargo + token pools + role labels (#48)`.

### PR Test Plan Items
- "Switch map to <map-id> in the lobby"
- "Add a bot, start match, and verify <expected behavior>"
- "Run `pnpm -r typecheck` — all three packages green"
- "Open the Help modal and verify the Legend reflects new mechanics"
- "Sink + respawn (use the host debug-sink button) — verify state cleanup"

## full-review Summary Table Format
Match the generic template; no repo-specific override needed. Include the PR number, agent-review verdict + finding count, check-pr fix count, CI status (— until CI lands), brief change list, and created/closed issues.

<!-- retrigger: deploy diagnostic -->
