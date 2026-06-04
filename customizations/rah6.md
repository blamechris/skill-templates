# Rah6 Skill Customizations

## Project Context
- **Tech:** Node + TypeScript (strict), npm workspaces (`engine` / `server` / `client`). Engine is a pure reducer (no I/O). Server: Express + ws + Postgres (`pg`). Client: React + Vite. Tests: Vitest in every workspace.
- **Repo:** blamechris/rah6 (private, MIT)
- **Main branch:** main
- **CI:** GitHub Actions — workflow **`CI`** (`.github/workflows/ci.yml`), single job **`Build, lint, test`**: install workspaces → build engine → lint all workspaces (`tsc --noEmit`) → `npm test --workspaces` → build server + client. The required-check name for merge gating is the job name, **`Build, lint, test`**.
- **Status:** A1 shipped (pure engine reducer + full bet catalog + chip registry; Express+ws server with Postgres-optional persistence; React+Vite client). A2 roguelike primitives in place (run/antes, chip shop, shooter rotation, bet leveling). Client has the drag-flick dice shooter, the Phase-4 skill training panel, and multi-bettor binding. All three workspaces' tests run green under CI.
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
- CI: workflow **`CI`**, required job **`Build, lint, test`** (build engine, lint all workspaces, `npm test --workspaces`, build server + client). Wait on that check before declaring a PR mergeable.
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
Match the generic template. The CI status column reflects the **`Build, lint, test`** check on the workflow **`CI`**.

## smoke-test Customizations
- **Ports / URLs:** server on `http://localhost:6336` (HTTP + WS), client dev server on `http://localhost:5173` (Vite, proxies `/api` + `/ws` → 6336). The smoke test drives the **client** URL.
- **Health endpoint:** `GET /api/health` (server). Use it to detect the server is up.
- **Detect & start:** readiness = `curl -s http://localhost:6336/api/health` (server) and `curl -s http://localhost:5173` (client). Start with `npm run dev:server` and `npm run dev:client` as two background processes. Postgres is optional — the server boots in memory-only mode when `DATABASE_URL` is unset, which is the right mode for a smoke test.
- **Smoke test script path:** `client/scripts/smoke-test.mjs` (create it if absent — ESM, `import { chromium } from 'playwright'`). There is **no** `smoke-test` npm script, so run it directly: `node client/scripts/smoke-test.mjs $PW_FLAGS` (never append `$ARGUMENTS`/`$KEEP_SCREENSHOTS`).
- **Readiness check:** the table only renders after the WS delivers the initial `TableState`. There is **no `window.__appReady` global** — wait on a real element: `await page.waitForSelector('[data-testid="dice-shooter"]')`.
- **Screenshot directory:** `client/.smoke-screenshots/` (add to `.gitignore`) or `/tmp/rah6-smoke`. Clean up unless `--keep-screenshots`.
- **Stable selectors:** `[data-testid="dice-shooter"]` (the dice shooter container), `getByRole("button", { name: /^field$/i })` and other `.bet-button`s (bet picker), `label.training-toggle input` (training-mode toggle), `[aria-label="Bettors"]` + `[aria-label="Bettor p1"]` (multi-bettor roster), `[aria-label="Bankroll"]` (header).
- **Test categories:** (1) app loads & connects (dice render, no console errors); (2) place a Field bet → it appears in the bet list with the right amount; (3) roll (Quick-roll button or a gesture) → a settlement line appears; (4) open the Chips drawer and toggle a chip; (5) "New 2-player game" → roster shows two bettors + an invite link.
- **Never:** rolling/betting is local and cheap, but don't spam ROLL in a loop or create persistent rooms that leak across runs (memory-only mode resets on server restart).

## fix-ci Customizations
- **Workflow name:** **`CI`** (`.github/workflows/ci.yml`). Use `--workflow "CI"` in every `gh run list` call.
- Single job **`Build, lint, test`**. Failures are almost always one of: a workspace typecheck error (`tsc --noEmit`), a Vitest failure, or a stale **engine build** — server and client import `engine/dist`, so a broken engine build cascades. When debugging locally, rebuild the engine first: `npm run build --workspace engine`.

## batch-merge Customizations
- **Required check names:** `REQUIRED_CHECKS=("Build, lint, test")` — this is the CI **job** name (what `gh pr checks` returns under `.name`), *not* a shell command. There is exactly one job, so one entry.

## Attribution Policy
**Include** `Co-Authored-By: Claude` — the repo's own `CLAUDE.md` explicitly permits the Co-Authored-By footer. Commit format: `type(scope): subject`, scopes `engine` / `server` / `client` / `docs` / `chore`. No emoji unless asked.
