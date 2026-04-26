# LTL Skill Customizations

## Project Context
- **Tech:** React Native + Expo (SDK 54+, TypeScript strict), Supabase (Postgres, Auth, Storage, Realtime, Edge Functions), `@op-engineering/op-sqlite` + SQLCipher for at-rest encryption (migrated from expo-sqlite per PR #123/#197), Zustand + TanStack Query, NativeWind. Future: RevenueCat for billing, Sentry, self-hosted PostHog.
- **Repo:** blamechris/ltl
- **Main branch:** main
- **CI:** GitHub Actions — `.github/workflows/ci.yml` runs the required "Typecheck + Lint" check on every PR (matches branch-protection rule exactly); `.github/workflows/supabase-tests.yml` runs pgTAP against migrations on DB-relevant PRs (not yet required, see #134).
- **Authoritative spec:** `docs/LTL_Design_Document.md` — source of truth for product, data model, death transition, permissions, pricing, and roadmap. Open questions live in §14.

## Zero Attribution Policy
**Critical:** Never add `Co-Authored-By: Claude`, "Generated with Claude Code", or any AI attribution in commits, PRs, issues, or file contents. The user is sole author.

## Merge Gate
- **Enabled:** Yes — `/full-review` is MANDATORY before every merge (no shortcuts, no XS exceptions). Documented in user's auto-memory.
- Exception: pure `.md` skill/doc files with zero code changes can skip review.

## Branch Protection
- `main` is protected: PR required, conversation resolution required, no force pushes, no deletions.
- Required status check: "Typecheck + Lint" (the exact name is pinned by branch protection — renaming the CI job breaks merge even when CI passes).

## check-pr Customizations
- Copilot review IS active — keep the Step 0 polling loop. Do not assume Copilot is absent.
- Issue labels: `enhancement`, `bug`, `from-review`, `design`, `data-model`, `death-transition`, `privacy`, `ui`, `prompts`, `memorial`, `offline-sync`.
- Code style: TypeScript strict, functional components with hooks only, ESM, no `any` in new code.
- Evidence pattern: "per CLAUDE.md: TypeScript strict, functional components only, no `any`" and "per design doc §N: …"
- Branch protection: enforced via GitHub settings; see above.

## agent-review Customizations

### Persona
**LTL Inspector** — expert in React Native/Expo, TypeScript strict, Supabase (Postgres + RLS + Edge Functions), SQLite/SQLCipher offline sync, grief-sensitive UX, privacy-by-default data modeling, and death-transition state machines.

Mindset: *"Does this code respect the grieving user? Is the deceased's authored content preserved and uneditable? Does offline-first actually work? Are RLS policies tight? Does it match the design doc or is it drifting?"*

### Code Quality
- TypeScript strict, ESM, functional components with hooks only
- All DB access through typed repositories — no raw Supabase client calls in UI code
- Zod validation at every trust boundary (edge functions, form submissions)
- No `any` types in new code
- All dates as ISO 8601 strings; UUIDs via `expo-crypto` (client) or `gen_random_uuid()` (Postgres)
- No comments that restate code — comments explain non-obvious *why*

### Architecture
- Offline-first: every core read path works from SQLite without network; writes queue and sync
- Polymorphic `entries` table per design doc §7.3 — `track` enum + `context_id` column
- RLS enabled on every table; readable/writable policies per §8.2
- Audit log (`audit_log`) is append-only; no DELETE or UPDATE policies
- Death transition state changes run server-side only (Edge Functions), never client-only (design doc §6)
- Media access via signed URLs from RLS-aware backend functions — never expose storage paths directly
- High-sensitivity content (voice notes, private entries) client-side encrypted before upload

### Grief-Sensitive UX Rules (design doc §1.3, §3.4, §10.5)
- Never punish a user for missing a day; streak grace budgets must be honored
- Memorial prompts must pass the *next-week test* ("would I be glad I answered this a week from now?") and the *stranger test* (works for diverse grief contexts: child, parent, sibling, pet)
- Copy is direct and humane; never "celebrate" a death anniversary; prefer the person's name over "loss"
- No "like" button, no public feed, no infinite scroll, no engagement-maximizing patterns
- The deceased's authored content is frozen — no edit mechanism anywhere for anyone

### Privacy & Safety
- RLS tested on every new table; default-deny
- No PII in logs or analytics events
- Never train AI on user content — enforced in Anthropic API contract and privacy policy
- MFA required for: initiating death transition, changing Legacy Contacts, approving Sunset, account deletion (design doc §8.1)
- Notifications to user themselves during memorial initiation — critical anti-hostile-memorialization defense (§6.6)

### Mobile
- Warm dark theme as default (design doc §10.1)
- Touch targets min 48dp
- Offline behavior tested with airplane mode on every flow
- Expo config: SDK 54+, dev build expected (not Expo Go) — `@op-engineering/op-sqlite` is a third-party native module that won't load in Expo Go.

## create-pr Customizations
- Test plan should include: `npm run typecheck` passes, `npm run lint` passes, `npm run format:check` passes (all three are local mirrors of CI's "Typecheck + Lint" job), `npm test -w @ltl/mobile` for jest suites, manual offline test (airplane mode) when DB/sync touched, dark theme check, 48dp tap targets.
- Issue labels to scan: `from-review`, `enhancement`, `bug`
- Branch naming: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/` prefixes

## create-issue Customizations
- Labels available: `enhancement`, `bug`, `from-review`, `design`, `data-model`, `death-transition`, `privacy`, `ui`, `prompts`, `memorial`, `offline-sync`
- For design-doc open questions (§14), use `design` label and link to the relevant section

## learn Customizations
- **CLAUDE.md sections:** `## Code Style`, `## Key Constraints`, `## Git Workflow`
- **Rules naming:** kebab-case (e.g., `rls-policies.md`, `offline-sync.md`, `death-transition.md`)
- **Domain quality bar:** Expo/React Native platform constraints, Postgres RLS patterns, SQLite offline patterns, grief-sensitive UX, death-transition integrity
- **Common paths:** `apps/mobile/**/*.ts`, `apps/mobile/**/*.tsx`, `supabase/migrations/*.sql`, `supabase/functions/**/*.ts`, `packages/**/*.ts`

## start-working Customizations
- Ready-to-work signals: `enhancement` or `bug` label + acceptance criteria in body + design-doc section reference if relevant
- Blocked labels: `blocked`, `needs-design`
- Roadmap: `docs/LTL_Design_Document.md` §13 (phased roadmap) and §14 (open questions)
- Source file patterns: `*.ts`, `*.tsx`, `*.sql`
- Test runner: `npm test -w @ltl/mobile` (jest 29 + jest-expo). Tests live under `apps/mobile/lib/**/__tests__/*.test.ts`.
- Type check: `npm run typecheck` (runs `tsc --noEmit` across all four workspaces).

## autonomous-dev-flow Customizations
- Test command: `npm test -w @ltl/mobile` (jest). Filter to one suite via `npx jest <path-pattern>` from `apps/mobile/`.
- Type check: `npm run typecheck` (root) — runs `tsc --noEmit` across `@ltl/mobile`, `@ltl/shared`, `@ltl/ui`, `@ltl/prompts`.
- Lint + format: `npm run lint` (eslint 9 flat config at root) and `npm run format:check` (prettier).
- Source directories: `apps/mobile/`, `packages/`, `supabase/`
- Test pattern: `**/*.test.ts`, `**/*.test.tsx`
- pgTAP DB tests: `supabase test db` against the local stack (run when migrations or RLS change).

## tackle-issues Customizations
- Max concurrent: 1 (solo-dev phase; test on device)
- Priority labels: `death-transition` > `privacy` > `bug` > `from-review` > `enhancement`
- Test gate: `npm test -w @ltl/mobile && npm run typecheck && npm run lint`. Add `supabase test db` when migrations are touched.

## full-review Customizations
- Composes agent-review (LTL Inspector persona) + check-pr sequentially.
- Copilot review IS active here — keep the check-pr Step 0 polling loop. Agent-review's ~minute-or-two run naturally fills most of the Copilot delay.

## parallel-dev Customizations
- Worktree-based isolation works well for this repo
- Each worktree needs its own `node_modules` (`npm install` in worktree) once scaffolded

## smoke-test Customizations
- Check: `npm run typecheck` (type check across all workspaces)
- Check: `npm test -w @ltl/mobile` (jest unit suites)
- Check: `npm run lint && npm run format:check`
- Check: design-doc alignment (any drift from `docs/LTL_Design_Document.md`?)
- Check: Supabase migrations apply cleanly against a fresh DB — `supabase db reset` then `supabase test db`.
