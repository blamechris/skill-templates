# Chroxy Skill Customizations

## Project Context
- **Tech:** Node.js (server, ES modules, no TS) + React Native/Expo (app, TypeScript)
- **Repo:** blamechris/chroxy
- **Main branch:** main
- **CI:** Copilot review + CodeQL ruleset

## check-pr Customizations
- No Copilot polling needed (reviews complete fast, can add later)
- Issue labels: `enhancement`, `from-review` (no complexity/testing labels yet)
- Server style: no semicolons, single quotes — common false positive from Copilot
- Evidence pattern: "per CLAUDE.md: no semicolons, single quotes"

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
