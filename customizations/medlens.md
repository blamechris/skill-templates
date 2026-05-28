# MedLens Skill Customizations

## Project Context
- **Tech:** React Native/Expo (TypeScript strict), SQLite (expo-sqlite), local-first medical tracking
- **Repo:** blamechris/medlens
- **Main branch:** main
- **CI:** None yet (manual testing, Jest for unit tests)

## check-pr Customizations
- Copilot review IS active — keep the Step 0 polling loop. Verified via `gh api repos/blamechris/medlens/pulls/<n>/reviews` showing copilot-pull-request-reviewer[bot] on recent PRs.
- Issue labels: `enhancement`, `bug`, `from-review`, `export`, `ocr`, `ui`, `privacy`, `db`, `camera`, `trends`
- Code style: TypeScript strict, semicolons, single quotes (verified against `app/_layout.tsx` and friends).
- Evidence pattern: "per CLAUDE.md: TypeScript strict, functional components only"
- Branch protection: not configured yet — no merge gate needed

## agent-review Customizations

### Persona
**MedLens Inspector** — expert in React Native/Expo, SQLite, medical data privacy, OCR pipelines, mobile accessibility.

Mindset: "Will this code work reliably offline with sensitive medical data on a stressed caregiver's phone?"

### Code Quality
- TypeScript strict, functional components with hooks only
- React Context + useReducer for state (no external state libs)
- All DB access through repository classes in `src/db/repositories/`
- No `any` types in new code
- All dates as ISO 8601 strings
- UUIDs via expo-crypto

### Architecture
- Local-first: all data in SQLite + local filesystem
- Photos at `{documentDirectory}/photos/{patientId}/{YYYY-MM}/{timestamp}_{shortId}.jpg`
- DB stores RELATIVE photo paths
- OCR pipeline: 3 tiers (local regex, API text, API vision)
- Export system: curated selection → structured markdown for LLM consumption

### Mobile
- Dark theme default (hospital context)
- Touch targets min 48dp
- Camera requires dev build (not Expo Go)
- Notification reminders for medications

### Privacy
- Medical data never leaves device unless user explicitly opts into API tiers
- API key in Keychain (expo-secure-store), never in SQLite
- Export is explicit user action with item-by-item selection

## create-pr Customizations
- Test plan should include: `npx tsc --noEmit` passes, `npx jest` passes, dark theme check, 48dp tap targets, tested on emulator
- Issue labels to scan: `from-review`, `enhancement`
- Branch naming: `feat/`, `fix/`, `refactor/`, `test/` prefixes

## create-issue Customizations
- Labels available: `enhancement`, `bug`, `from-review`, `export`, `ocr`, `ui`, `privacy`, `db`, `camera`, `trends`
- No complexity labels yet

## learn Customizations
- **CLAUDE.md sections:** `## Code Style`, `## Key Constraints`, `## Git Workflow`
- **Rules naming:** kebab-case (e.g., `expo-sqlite.md`, `ocr-pipeline.md`)
- **Domain quality bar:** Expo/React Native platform constraints, SQLite patterns, medical data handling, OCR extraction patterns
- **Common paths:** `src/**/*.ts`, `src/**/*.tsx`, `app/**/*.tsx`

## start-working Customizations
- Ready-to-work signals: `enhancement` label + acceptance criteria in body
- Blocked labels: `blocked`, `needs-design`
- Roadmap files: `MEDLENS-DESIGN.md` (implementation phases with `- [ ]` checkboxes)
- Source file patterns: `*.ts`, `*.tsx`
- Test runner: `npx jest`
- Dependency check: `npx expo install --check`

## autonomous-dev-flow Customizations
- Test command: `npx jest --no-cache`
- Type check: `npx tsc --noEmit`
- Source directories: `src/`, `app/`
- Test pattern: `src/__tests__/*.test.ts`

## tackle-issues Customizations
- Max concurrent: 1 (mobile app, need to test on device)
- Priority labels: `bug` > `from-review` > `enhancement`
- Test gate: `npx jest --no-cache && npx tsc --noEmit`

## full-review Customizations
- Composes agent-review (MedLens Inspector persona) + check-pr sequentially
- Copilot review IS active — agent-review's run naturally fills most of the ~4-min Copilot review delay so check-pr starts with comments waiting.

## decompose-issue Customizations
- Default sub-issue labels: `enhancement` or `bug` plus the area label that still applies after the split — `export`, `ocr`, `ui`, `privacy`, `db`, `camera`, `trends`. `from-review` inherited only if the parent has it. No `complexity:*` labels yet — skip them.
- Parent-link convention: body line "Part of #N" only — no `parent:#N` label scheme.
- Parent-marker label: none currently. Skip the parent-marker step.
- Natural seams follow the area labels — each area is a candidate sub-issue boundary. OCR pipeline splits along its 3 tiers (local regex / API text / API vision) when changes touch all three. Export system splits along selection vs structured-markdown vs LLM-consumption flow.
- Code-structure seams: `src/db/repositories/` (DB access), `src/` (general), `app/` (Expo Router screens). DB-schema or repository changes always need a sub-issue separate from the consuming UI to make the migration review-able in isolation.
- Privacy-touching sub-issues (`privacy` label) must include in the acceptance criteria that no PII leaves the device unless user opts into an API tier — the merge-gate question, not a nice-to-have.

## parallel-dev Customizations
- Worktree-based isolation works well for this repo
- Each worktree needs its own `node_modules` (`npm install` in worktree)

## smoke-test Customizations
- Check: `npx tsc --noEmit` (type check)
- Check: `npx jest --no-cache` (unit tests)
- Check: Verify `android/app/build/outputs/apk/debug/app-debug.apk` exists if Android build ran
