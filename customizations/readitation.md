# Readitation Skill Customizations

## Project Context
- **Tech:** Flutter (Dart), iOS-only for v0.1 (Android deferred). Local SQLite via `drift` or `sqflite`. State management TBD — Riverpod vs BLoC (issue #2).
- **Repo:** blamechris/readitation
- **Main branch:** main
- **CI:** none yet (Flutter not scaffolded). Will be `flutter test` + `flutter analyze` once scaffolded.
- **Status:** Pre-code phase. v0.1 spec'd in `SPEC.md`. A single-file vanilla-JS RSVP prototype lives at `prototype/rsvp.html` to validate the timing/ORP model before the Flutter port. Reviews currently target spec edits, the prototype, docs, and the imminent Flutter scaffolding.
- **Critical:** Zero-attribution policy. NEVER add `Co-Authored-By: Claude`, "Generated with Claude Code", or any AI attribution in commits, PRs, or code comments. The user is the sole author. Skills MUST emit clean commit messages and PR bodies with no attribution footer.

## start-working Customizations

### Ready-to-Work Labels
- `enhancement` and `bug` issues without `blocked` are ready
- `decision` issues (open SPEC questions from §12) are ready only if the user has picked an option in a comment

### Blocked Labels
- `blocked`, `wontfix`, `decision` (until resolved)

### Roadmap File Locations
- `SPEC.md` (authoritative for v0.1 scope, timing model, gestures, UI states, content schema, and roadmap §11)
- `CLAUDE.md` (session protocol, git workflow)
- Default scan also covers `prototype/README.md`

### Source File Patterns for TODOs
- `lib/**/*.dart` (once scaffolded)
- `prototype/**/*.html`, `prototype/**/*.js`
- `SPEC.md` for "TBD" markers

### Priority Signals
- Anything blocking the Flutter scaffold (issue #2 state-management decision, content ingest schema) → P0
- iOS-only build/release issues → P0 (v0.1 targets iOS exclusively)
- Prototype work (HTML-only) → P2 unless it validates a SPEC question
- Android-related work → defer (out of v0.1 scope per SPEC §3)

### Dependency Check
- `flutter pub outdated` (once scaffolded)
- Pre-Flutter: skip

### Test Runner
- `flutter test` + `flutter analyze` (once scaffolded). Until then there is no test runner — note this and check `dart format --output=none --set-exit-if-changed .` if any `.dart` files exist.

### Audit Focus Areas
- RSVP timing accuracy (SPEC §4.2: `base_ms × length_factor × punct_factor`)
- ORP rendering correctness (SPEC §4.1 length-bucket table)
- Position-tracking and resume behavior (SPEC §6)
- Bundled Bible content schema and tokenization (SPEC §8.1)
- iOS Safari behavior for the prototype (touch gestures, viewport, no auto-zoom)

## check-pr Customizations
- Issue labels in use: `enhancement`, `bug`, `decision`. No complexity/testing labels yet.
- Zero-attribution policy applies to ALL commits the skill creates — never add Co-Authored-By trailers, never add "Generated with Claude" footers.
- Squash merge only, after explicit user confirmation. Never auto-merge.

## learn Customizations
- **CLAUDE.md sections:** `## Local Dev Setup`, `## Git Workflow`, `## Code Style`, `## Architecture`
- **Rules naming:** kebab-case (e.g., `dart-style.md`, `rsvp-timing.md`)
- **Domain quality bar:** Insights about RSVP timing perception, ORP positioning, iOS gesture quirks, Flutter performance on iOS, drift/sqflite schema choices qualify as durable. Generic Flutter tips do not.
- **Common paths:** `lib/**/*.dart`, `prototype/**`, `SPEC.md`

## parallel-dev Customizations

Shares all customization points with autonomous-dev-flow (branch prefix, test runner, decomposition, commit scopes from agent-review/start-working sections).

### Parallel-Specific Settings
- **Default concurrency:** 2 (small repo, pre-Flutter; raise to 3 once scaffolded)
- **Dependency setup in worktree:** `flutter pub get` (once scaffolded). Pre-Flutter: no-op.

## agent-review Customizations

### Persona
**Readitation Engineer** — expert in Flutter/Dart, iOS app architecture, mobile reading UX, RSVP/Spritz mechanics, local-first SQLite apps, and the ORP fixation model.

Mindset: "Will this code present words at the correct cadence on iOS, with frame-accurate WPM control, correct ORP alignment, and resume-safe position tracking?"

### Code Quality
- Dart formatter (`dart format`) is authoritative for layout — no debates
- Functional widgets where reasonable; small files; meaningful names over comments
- No comments explaining *what* the code does — only *why* when non-obvious (per CLAUDE.md)
- No print/debugPrint in shipped code (use logger once chosen)
- Zero-attribution policy in code comments and commit messages

### Architecture
- v0.1 scope from SPEC §2 is the hard boundary — flag anything out of scope (BYO EPUB, public-domain library beyond Bible, modern content marketplace, community features, cloud sync)
- iOS-only for v0.1 — flag Android-specific code or platform-channel work
- RSVP engine boundaries: timing math (SPEC §4.2), ORP table (SPEC §4.1), tokenization (SPEC §8.1) should live in pure-Dart units that the UI consumes
- Local SQLite as source of truth; resume state survives kill
- State management decision (Riverpod vs BLoC) pending issue #2 — flag PRs that pick one without closing #2

### Integration
- Bundled Bible content schema matches SPEC §8.1 (`{Book, Chapter, Verse, Token}`)
- Position tracking persists across cold start (SPEC §6.1)
- Gestures match SPEC §5 (tap-while-playing pauses; play button required to start/resume; long-press scrubs at 2× WPM; swipe up/down adjusts WPM)
- ORP letter visually fixed; non-ORP word body shifts (no eye movement) — SPEC §4.1

### Testing
- `flutter test` for unit/widget tests (once Flutter is scaffolded)
- `flutter analyze` must be clean
- Prototype changes can be smoke-tested via Node (see prior session) — there is no formal test runner for `prototype/`
- Manual testing on actual iOS device for any gesture/timing change before merge

### Issue Labels
Required on ALL issues the skill creates:
- `enhancement` — new feature work
- `bug` — defect
- `decision` — open spec/architecture question (record chosen option in a comment before closing)

No complexity/testing labels yet — keep issue templates simple.

## fix-ci Customizations
- No CI configured pre-Flutter. If a Flutter CI workflow exists, it should run `flutter analyze` + `flutter test`. iOS build verification requires macOS runners and signing certs — defer until needed.

## smoke-test Customizations
- Prototype: Node-based smoke (`node --check` on extracted JS, integration eval) — see prior session's `/tmp/readitation-grief/smoke.js` for a working pattern
- Flutter app (post-scaffold): `flutter test` golden-path widget tests
