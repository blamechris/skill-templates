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
- No Copilot polling needed (reviews complete fast, can add later)
- Issue labels: `enhancement`, `from-review` (no complexity/testing labels yet)
- Server style: no semicolons, single quotes — common false positive from Copilot
- Evidence pattern: "per CLAUDE.md: no semicolons, single quotes"
- Reply headers: **FIX** / **FALSE POSITIVE** / **FOLLOW-UP ISSUE** (bolder than generic)
- Branch protection requires conversation resolution — inline replies are mandatory for merge

### Lessons Learned
- **2026-02-08:** Agent posted summary review but skipped all 7 inline replies on PR #116. Root cause: skill said "reply inline" but agent batched mentally and only did the summary. Fix: (1) added verification step that counts root comments vs replied threads, (2) reworded critical rules to make inline replies the PRIMARY output, (3) enforced one-at-a-time processing order.

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
