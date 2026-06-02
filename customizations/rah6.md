# Rah6 Skill Customizations

## Project Context
- **Tech:** Node + TypeScript (strict), npm workspaces (`engine` / `server` / `client`). Engine is a pure reducer (no I/O). Server: Express + ws + Postgres (`pg`). Client: React + Vite. Tests: Vitest in every workspace.
- **Repo:** blamechris/rah6 (private, MIT)
- **Main branch:** main
- **CI:** Not yet set up (planned: GitHub Actions running `npm test --workspaces` + typecheck).
- **Status:** Phase 0 — engine MVP complete (56 tests green: seeded RNG, pass + odds + place 6/8 at real payouts, shooter/bettor chip contracts, purist test enforced). Next: wire engine into server over HTTP+WS, render a bare table client, save-on-every-action to Postgres.
- **Genre:** Balatro-leaning roguelike co-op craps. Real-casino bet fidelity is a hard pillar — the "purist test" (disabling all chips must leave a faithful real-money table) is enforced by the chip-contract surface in code, not just convention.

## Critical: The Purist Test
The engine layer is the **non-negotiable** 1:1 craps simulation — odds, payouts, and bet behavior must match a real casino table. Chips/jokers sit on top of resolved bets; they never replace the math.

- **Shooter chips** can ONLY mutate dice (`onPostRoll`) — loaded faces, re-rolls, extra dice.
- **Bettor chips** can ONLY mutate settlements (`onPostResolve`) — payout multipliers, scoring chips on top.
- There is no API for crossing that line. Any chip that breaks real-casino fidelity at the table layer is a regression even if it makes a joker design work.

When reviewing chip/bet code, the test is: "Could a craps purist disable all chips and play a faithful table?" If no, the base layer is broken.

## Repo Layout
```
rah6/
├── engine/   pure reducer + bet catalog + chip registry. No I/O. JSON-serializable state.
├── server/   Express + ws + Postgres. The only thing that runs the reducer.
└── client/   React + Vite. Subscribes to server state; sends actions.
```

Engine knows nothing about server/client. Server knows nothing about React. One-way deps, strict.

## start-working Customizations

### Ready-to-Work Labels
- No formal labels yet — treat unblocked, unassigned issues as ready.
- TBD: when a label scheme lands, add `ready-to-build` / phase / system axes here.

### Blocked Labels
- TBD: `blocked`, `wontfix` will be added when needed.

### Roadmap File Locations
- `README.md` (scaffold overview)
- `docs/design.md` (TBD — design pillars + decision log; not yet written)
- Memory at `~/.claude/projects/-Users-blamechris-Projects-rah6/memory/project_rah6.md` (auto-memory; cross-session design context)

### Source File Patterns for TODOs
- `engine/src/**/*.ts`
- `server/src/**/*.ts`
- `client/src/**/*.{ts,tsx}`

### Priority Signals
- Engine layer changes block server/client work
- Purist-test failures (any chip that crosses the dice/payout boundary) are P0
- Server protocol decisions block client UI work

### Dependency Check
- `npm install` at repo root (workspaces share `node_modules` at root + per-package).
- Verify all three workspaces typecheck: `npm run lint --workspaces --if-present`.

### Test Runner
- Vitest in every workspace. `npm test --workspaces` from root.
- Engine tests are the deepest — they prove casino-faithful payouts. Treat any engine test failure as P0.

## check-pr Customizations
- Issue labels: TBD — none yet defined.
- CI not yet configured — focus on: `npm run build --workspaces`, `npm test --workspaces`, type checks clean.
- Engine purist test (`resolver.test.ts`, `chips.test.ts`) must remain green — these are the load-bearing assertions about casino fidelity.

## learn Customizations
- **CLAUDE.md sections:** None yet — write into `docs/design.md` (TBD) when adding durable architectural insight, or into `.claude/rules/` for tactical guidance.
- **Rules naming:** kebab-case (e.g., `engine-purity.md`, `chip-contract.md`, `bet-catalog-shape.md`).
- **Domain quality bar:** Insights worth recording:
  - Engine-purity gotchas (anything that snuck I/O / randomness / clocks into the reducer or chip hooks)
  - Casino-craps payout edge cases when adding new bets (true odds vs house payout, working/off semantics, come/don't-come puck movement)
  - Serialization gotchas (closures-in-state, Date objects, anything that breaks JSON round-trip)
  - Chip composition order — when a shooter chip and a bettor chip stack, what order does the engine apply them in?
- **Common paths:**
  - `engine/src/bets.ts` (BetCatalog)
  - `engine/src/chips.ts` (Chip contract + registry)
  - `engine/src/resolver.ts` (pure settlement logic)
  - `engine/src/reducer.ts` (the only place that touches RNG and applies money)
  - `engine/src/state.ts` (TableState shape — must stay JSON-serializable)

## agent-review Customizations

### Persona
**Rah6 Inspector** — expert in TypeScript-strict monorepos, deterministic reducer architectures (Redux/event-sourcing lineage), seeded RNG correctness, casino-craps math (true odds, house edges, working/off semantics for every bet type), and Balatro-style modifier-stacking systems where deck-builder chaos sits on top of a deterministic core.

Mindset: *"Does this respect the purist test? Does the reducer stay pure (no I/O, no clocks, no Math.random)? Are bet payouts at real-casino odds? Is state still JSON-serializable? Does the chip contract still gate shooter→dice / bettor→payouts strictly?"*

### Code Quality
- TypeScript strict, ESM, no `any` in new code.
- Pure functions in `engine/` (no side effects, no I/O, no clocks). Stateful resolution in server only.
- BetDefs and ChipDefs are DATA — adding new bets/chips should be new entries, not new reducer branches.
- The reducer's `switch` is exhaustive; new actions must extend the union and handle every case.

### Architecture
- **Authoritative server.** Server is the only thing that runs the reducer; clients send actions, receive state (or state diffs).
- **Engine purity.** Anything that adds I/O, clocks (`Date.now()`), or unseeded randomness (`Math.random()`) to `engine/` is a regression.
- **Chip contract is load-bearing.** Shooter chips → `onPostRoll` only (dice mutation). Bettor chips → `onPostResolve` only (settlement mutation). New chip types must extend the union, not punch through it.
- **State JSON-serializable.** No closures in state, no class instances, no refs. The reducer must round-trip through `JSON.stringify` cleanly — this is what makes save/resume / online co-op / replay / deterministic tests all work.

### Testing
- Vitest. Engine tests are the deepest — casino-faithful payouts, phase transitions, determinism (incl. JSON round-trip), purist test, chip composition.
- For any new bet: include a test asserting the real-casino payout (true odds or house odds, whichever the bet uses).
- For any new chip: include a test that the chip's effect happens in the right slot (`onPostRoll` vs `onPostResolve`) and that disabling all chips still yields a casino-faithful resolution.

### Engine-Specific Constraints
- Never import `engine/` from `client/`. Server is the only consumer.
- Never put server protocol concerns (room IDs, WS message shapes, auth) into engine state.
- Never put React state shape (UI selections, hover state, animations) into engine state.

## decompose-issue Customizations
- Default sub-issue labels: TBD — when labels exist, inherit parent's area/priority.
- Parent-link convention: body line "Part of #N" only.
- Decomposition trigger: issues spanning multiple workspaces (`engine` + `server` + `client`), OR scoped to "all bet types" / "all chips" / "all phases" unless it's a uniform refactor.
- Natural seams in code: the workspace boundary (`engine/` → `server/` → `client/`) AND the catalog axis (one bet at a time, one chip at a time). Schema changes that propagate across all three workspaces typically need a coordinated PR; per-bet / per-chip additions are independent sub-issues.

## parallel-dev Customizations
- **Default concurrency:** 3 (workspaces build independently; tests are fast).
- **Dependency setup in worktree:** Run `npm install` after creating worktree.

## tackle-issues Customizations

### Branch Prefix
- `feat/` for new features
- `fix/` for bug fixes
- `chore/` for tooling / docs / refactors

### Skip Labels
- TBD — none yet defined.

### Decomposition Trigger
- Issues spanning `engine/` + `server/` + `client/`
- Issues scoped to "all bet types", "all chips", "every phase", "every player role" — unless uniform refactor

### Commit Scopes
- Match workspace boundaries: `engine`, `server`, `client`, plus `docs`, `ci`, `chore`.
- Example: `feat(engine): add come / don't come to BetCatalog`

### PR Test Plan Items
- "`npm test --workspaces` — all three workspaces green"
- "`npm run build --workspaces` — clean build"
- "Engine purist test still passes (chips can't break casino fidelity)"
- "Manual: open client, place pass + odds, roll — payouts at real-casino numbers"

## full-review Summary Table Format
Match the generic template. CI status column is "—" until CI lands.

## Attribution Policy
TBD — defer until convention is set. Default to **including** `Co-Authored-By: Claude` until told otherwise.
