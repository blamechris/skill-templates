# Chroxy Skill Customizations

## Project Context
- **Tech:** Node.js (server, ES modules, no TS) + React Native/Expo (app, TypeScript)
- **Repo:** blamechris/chroxy
- **Main branch:** main
- **CI:** Copilot review + CodeQL ruleset

## Merge Gate
- **Enabled:** Yes — branch protection requires conversation resolution (noted in check-pr line 15)
- See `generic/merge-gate.md` for the CLAUDE.md snippet
- **TODO:** Add merge-gate snippet to chroxy CLAUDE.md

## check-pr Customizations
- Copilot polling IS needed — reviews take ~4 min to start after PR creation. Use Step 0 from generic template.
- Issue labels: `enhancement`, `from-review` (no complexity/testing labels yet)
- Server style: no semicolons, single quotes — common false positive from Copilot
- Evidence pattern: "per CLAUDE.md: no semicolons, single quotes"
- Reply headers: **FIX** / **FALSE POSITIVE** / **FOLLOW-UP ISSUE** (now synced to generic as of 2026-02-16)
- Reply Format Examples section with detailed examples (now synced to generic as of 2026-02-16)
- Branch protection requires conversation resolution — inline replies are mandatory for merge

### Lessons Learned
- **2026-02-08:** Agent posted summary review but skipped all 7 inline replies on PR #116. Root cause: skill said "reply inline" but agent batched mentally and only did the summary. Fix: (1) added verification step that counts root comments vs replied threads, (2) reworded critical rules to make inline replies the PRIMARY output, (3) enforced one-at-a-time processing order.
- **2026-02-10:** check-pr ran immediately after PR #423 was created and found 0 comments because Copilot review hadn't started yet (~4 min delay). Root cause: local skill was missing Step 0 (Copilot polling) from generic template, and generic template only waited for IN_PROGRESS→COMPLETED, not NOT_FOUND→appeared. Fix: (1) updated generic template to also wait for review to appear when PR is <5 min old, (2) synced Step 0 into chroxy local skill.
- **2026-02-16:** check-pr agent on PR #540 posted 4 FOLLOW-UP ISSUE replies saying "Created a follow-up issue." without the issue URL. Despite the template clearly showing `Created ${ISSUE_URL} to track this.`, the agent wrote free-form text instead. Same issue in agent-review: Deferred Items table had `#XX` placeholder but "Include created issue URLs" instruction was too soft. Fix: (1) added explicit comment in check-pr bash block: "NEVER write 'Created a follow-up issue' without the URL", (2) replaced soft "Include created issue URLs" in agent-review with CRITICAL block mandating linked URLs, (3) updated Deferred Items table template to show `[#XX](issue_url)` format. Both generic and local templates updated.

## agent-review Customizations

### Persona
**Chroxy Inspector** — expert in Node.js, React Native/Expo, WebSocket protocol, Claude Code CLI, Cloudflare tunnels, mobile connectivity.

Mindset: "Will this code work reliably over a cellular connection through a tunnel to a remote dev machine?"

### Code Quality — Server
- ES modules (import/export), no TypeScript
- No semicolons, single quotes
- EventEmitter pattern for component communication
- Proper cleanup on destroy/close

### Code Quality — App
- TypeScript strict, functional components with hooks
- Zustand store patterns (immutable updates via `set()`)
- No `any` types, platform-aware code
- No `AbortSignal.timeout()` (not in React Native)

### Architecture
- CLI mode and PTY/terminal mode remain independent paths
- WS protocol messages documented in ws-server.js header
- Auth flow: auth → auth_ok → server_mode → status → claude_ready

### Mobile
- Touch targets min 44pt
- Keyboard handling for Android suggestion bar
- Safe area insets, Expo Go compatibility

## full-review Customizations
- Composes agent-review (Chroxy Inspector persona) + check-pr sequentially
- Agent-review takes ~2-3 min, which covers most of the Copilot review delay (~4 min)
- Combined summary table is the primary output — matches the format used in batch PR reviews
- Same attribution policy applies: no AI mentions anywhere

## create-pr Customizations
- Test plan should include: server tests pass, app type-checks clean, manual smoke test
- Batch-fix PRs are common (from-review batches) — use batch template when closing 3+ issues
- Issue labels to scan: `from-review`, `enhancement`
- Branch naming: `feat/`, `fix/`, `refactor/`, `test/` prefixes with issue numbers in name

## create-issue Customizations
- Labels available: `enhancement`, `from-review` (no `complexity:` or `testing:` labels yet)
- If complexity/testing labels are added later, update this note
- Review comment URLs follow GitHub format: `https://github.com/blamechris/chroxy/pull/N/files#r<comment_id>`

## learn Customizations
- **CLAUDE.md sections:** `## Server Conventions`, `## App Conventions`, `## Debugging`
- **Rules naming:** kebab-case (e.g., `react-native.md`, `websocket.md`)
- **Domain quality bar:** React Native platform constraints, WebSocket protocol quirks, tunnel reliability patterns qualify as durable insights
- **Common paths:** `app/**/*.tsx`, `server/**/*.js`

## start-working Customizations

### Ready-to-Work Labels
- No explicit `ready-to-build` label — treat unblocked, unassigned `enhancement` and `from-review` issues as ready
- `from-review` issues are higher priority (deferred PR feedback should be addressed promptly)

### Blocked Labels
- `blocked`, `wontfix`, `needs-design`

### Roadmap File Locations
- Default scan only (`ROADMAP.md`, `TODO.md`, `docs/`) — no custom planning docs

### Source File Patterns for TODOs
- Server: `server/**/*.js`
- App: `app/**/*.tsx`, `app/**/*.ts`

### Priority Signals
- `from-review` → P1 (deferred review feedback)
- `bug` → P0
- No milestones currently in use

### Dependency Check
- `npm outdated` and `npm audit`

### Test Runner
- Server: `npm test`
- App: `npx jest` (TypeScript)

### Audit Focus Areas
- Mobile connectivity reliability (WebSocket, tunnels)
- React Native platform-specific edge cases
- Server event handler cleanup patterns

## swarm-audit Customizations

### Domain-Specific Extended Agents

| Agent | Nickname | Lens | When to Include |
|-------|----------|------|-----------------|
| Expo Expert | "Expo Expert" | Expo SDK lifecycle, React Native constraints, OTA updates, dev client vs Expo Go | Target involves mobile app architecture, updates, or Expo-specific features |
| Tunneler | "Tunneler" | Cloudflare tunnels, DNS, TLS, WebSocket proxying, network reliability | Target involves tunnel configuration, connectivity, or networking |

### Grading Criteria
- Operator should weight mobile UX: touch targets, offline behavior, reconnect experience
- Guardian should weight WebSocket edge cases: stale sockets, tunnel drops, concurrent writes
- Expert agents should verify claims against actual Cloudflare/Expo documentation
