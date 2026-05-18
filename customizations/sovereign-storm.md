# sovereign-storm Skill Customizations

## Project Context
- **Tech:** pnpm monorepo (3 packages) — `shared/` (schemas + types, source-only), `server/` (Colyseus 0.16 + Express 5 + TypeScript), `client/` (Phaser 3 + Vite + TypeScript)
- **Repo:** blamechris/sovereign-storm (**private** — placeholder art in use, no public deploys)
- **Main branch:** main
- **What it is:** browser-first, turn-based multiplayer naval blockade game with 5 match modes (`blockade`, `voyage`, `hunt`, `ffa`, `odyssey`) dispatched via strategy pattern
- **Hosting:** `pnpm host` builds client + spawns server + opens Cloudflare quick tunnel (`scripts/host.mjs`)
- **CI: None yet.** `.github/workflows/` does not exist. Tests run via `pnpm test` per package locally. **Do not assume merge gates exist** — `/check-pr` should skip the "wait for CI" loop here.

## Attribution Policy
This repo follows the user's project-wide **zero-attribution** policy. NEVER add `Co-Authored-By: Claude` or `Generated with Claude` to commits, PRs, or any output.

## Architectural Gotchas (CRITICAL — read before any change to server/shared)

### Colyseus schema is vestigial — MSG_* is the real protocol
Despite using Colyseus, **only `BattleState.phase` is schema-synced** (see `packages/shared/src/index.ts:158`). Comment at L128 explains: "primitive schema fields don't reliably propagate in Colyseus 0.16 + schema 3.0." Everything else — `hostSessionId`, scores, round number, mode, players list — routes through custom `MSG_*` messages via `room.send` / `room.onMessage`. Do not add fields to `BattleState` expecting they'll auto-sync; add a new `MSG_*` and broadcast manually.

### Server-authoritative with full-replay model
Round resolution is **fully simulated on the server** in `packages/server/src/rooms/BattleRoom.ts:1927` (`resolveRound`), then shipped as a `ticks[]` array via `MSG_ROUND_RESULT`. **The client does NOT re-simulate; it only animates.** This guarantees no outcome drift, but means every round's wire payload contains full per-slot, per-ship state. Do not add client-side prediction without explicit design — it would diverge from the authoritative replay.

### `BattleRoom.ts` is a 6,048-line god-class
The entire server gameplay loop — onCreate, 26 onMessage handlers, the resolver pipeline, mode dispatch, broadcast helpers — lives in one file. Behavior-sliced tests (`BattleRoom.<feature>.test.ts`, ~35 of them) cover specific paths, but the class itself is monolithic. When editing here, run the **full test set** for the package, not just the file you think you touched.

## check-pr Customizations
- **Skip Copilot polling.** Copilot reviews are NOT configured on this repo. Step 0 (poll for Copilot) should short-circuit — there's no review to wait for. Process whatever inline comments humans/agent-review left.
- Issue labels: verify with `gh label list` before applying. Repo is young; assume only `bug` and `enhancement` exist unless found otherwise.
- Reply headers: **FIX** / **FALSE POSITIVE** / **FOLLOW-UP ISSUE** (standard).
- No branch protection configured yet — inline replies are useful for traceability but not gated by CI.

## agent-review Customizations

### Persona
**Multiplayer Reliability Engineer** — expert in Colyseus 0.16 state-sync caveats, server-authoritative multiplayer architectures, Phaser 3 scene lifecycle, and the wire-protocol attack surface.

Mindset: *"This is the authoritative game state. Will the change desync the client from the server? Does this validator catch every malformed payload a malicious client could send? Will this change to lazy-init / save logic corrupt mid-match state for active rooms?"*

### Code Quality — Server (`packages/server/`)
- Module resolution is `NodeNext` (server) vs `Bundler` (shared/client) — import paths matter.
- Every `onMessage` handler must validate via a `sanitize*` function from `shared/` BEFORE mutating state. Direct `this.state.x = payload.y` without sanitize is a bug.
- `BattleRoom`'s recursion-guarded scheduler uses `setImmediate` deferral around `tryResolveRound` / `armPlanningPhase` — touching this pipeline is high-risk for desyncs.
- Mode-specific behavior lives in `packages/server/src/rooms/modes/*.ts` implementing `MatchModeStrategy` — changes to the interface in `types.ts` silently break every mode unless every implementation is updated.

### Code Quality — Client (`packages/client/`)
- Module resolution is `Bundler`; adds DOM lib (`packages/client/tsconfig.json:6`).
- `BattleScene.ts` (8,689 LOC) is the second god-file. Has no direct scene-class test — auxiliary helpers under `scenes/__tests__/` are partial coverage.
- Round replay player at `BattleScene.ts:6671+` walks server-shipped `ticks[]` via `runTick(idx)` recursion. Tween-callback bugs here cause animation desync, not state desync.
- `BootScene` constructs the Colyseus `Client` and stashes it in `registry`. Other scenes pull it via `this.registry.get("colyseus")`. Do not construct a second `Client`.

### Code Quality — Shared (`packages/shared/`)
- **Source-only** — package consumes `src/index.ts` directly via `exports`. `tsc --noEmit` is the build. Do not add `outDir` or expect compiled artifacts.
- `shared/src/index.ts` is the **single source of legality**: schemas, MSG types, validators, gameplay constants, sanitize/coerce functions. Any breaking change radiates to both client and server.
- Validators (`sanitizeCreateMatchOptionsVerbose`, `sanitizeMatchSettingsVerbose`, `sanitizeMoves`, `sanitizeCannons`, `sanitizeBotProfile`, `sanitizeFfaConfig`, `sanitizeChatPayload`) — these are the documented edge — server's defense-in-depth assumes they cover every case.

## swarm-audit / recon / bug-hunt Customizations

### Domain Agents
For audits and recon of this repo, useful extra agents:
- **WireProtocolist** — checks every `MSG_*` handler for: sanitize-before-mutate ordering, type-narrowing on optional payload fields, rate-limit gaps, payload-size unbounded growth.
- **DesyncHunter** — looks for places where client and server might diverge: lazy-init paths that overwrite state, client-side caches that aren't invalidated on round reset, unhandled `onLeave` cases mid-round.

### Hotspot Guidance
The three god-files dominate by churn and size; bias hunters here:
1. `packages/server/src/rooms/BattleRoom.ts` — 6,048 LOC, ~107 commits/90d. Authoritative state class. 26 onMessage handlers at L694–1345. Resolver pipeline at L1810-2350. **Highest-value target.**
2. `packages/client/src/scenes/BattleScene.ts` — 8,689 LOC, ~135 commits/90d. No direct scene-class test.
3. `packages/shared/src/index.ts` — 3,784 LOC, ~85 commits/90d. Wire contract + validators.

Highest-churn mode strategies: `packages/server/src/rooms/modes/ffa.ts` and `odyssey.ts` — they have prior bug history clustered around mode interactions (see `BattleRoom.odysseyMidJoin.test.ts`, `BattleRoom.voyageRespawnCap.test.ts`).

## create-issue / bug-hunt Customizations
- Default labels: `bug` for defects, `enhancement` for features. Skip `complexity:*` and `from-review` unless they exist (`gh label list` to verify).
- Repro steps for any multiplayer bug must specify: mode (blockade/voyage/hunt/ffa/odyssey), player count, and whether the bug is observed by host vs joiner. Single-player repros are insufficient for round-resolver bugs.

## tackle-issues / autonomous-dev-flow Customizations
- Test command: `pnpm test` per package, or `pnpm -r typecheck && pnpm -r test` from root.
- No CI gate, so the agent must run tests locally and report explicit pass/fail before declaring a fix done.
- Marathons are unusual for this repo (small, single-developer); prefer surgical single-PR work over batch flows.

## smoke-test Customizations
- Start with `pnpm dev` (concurrent server + client) — opens `http://localhost:5173` for client and `:2567` for server.
- For tunnel smoke: `pnpm host` and look for the `https://<random>.trycloudflare.com` line in stderr. Quick tunnels live ~24h.

## Lessons Learned
- **2026-05-17:** First substantive customization written using output of `/recon` on the repo. Recon document at `docs/recon/sovereign-storm-20260517.md`. Re-run recon and refresh this file when major architectural changes land (especially anything that breaks the Colyseus-schema-is-vestigial invariant).
