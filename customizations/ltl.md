# LTL Skill Customizations

## Project Context
- **Tech:** React Native + Expo (SDK 52+, TypeScript strict), Supabase (Postgres, Auth, Storage, Realtime, Edge Functions), expo-sqlite + SQLCipher for offline, Zustand + TanStack Query, NativeWind, RevenueCat for billing, Sentry, self-hosted PostHog
- **Repo:** blamechris/ltl
- **Main branch:** main
- **CI:** None yet (Phase 0). Planned: GitHub Actions for lint + type-check + test on PR once Phase 1 scaffolding lands.
- **Authoritative spec:** `docs/LTL_Design_Document.md` — source of truth for product, data model, death transition, permissions, pricing, and roadmap. Open questions live in §14.

## Zero Attribution Policy
**Critical:** Never add `Co-Authored-By: Claude`, "Generated with Claude Code", or any AI attribution in commits, PRs, issues, or file contents. The user is sole author.

## Merge Gate
- **Enabled:** Not yet. Phase 0 is solo; merge gate to be reconsidered in Phase 1 when code lands.
- Exception (once enabled): pure `.md` skill/doc files with zero code changes can skip review.

## Branch Protection
- `main` is protected: PR required, conversation resolution required, no force pushes, no deletions.
- No required status checks until CI exists (Phase 1).

## check-pr Customizations
- Copilot polling NOT needed — no Copilot review configured.
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
- Expo config: SDK 52+, dev build expected (not Expo Go)

## create-pr Customizations
- Test plan should include (once CI/tests exist): `npx tsc --noEmit` passes, `npx vitest run` passes, manual offline test (airplane mode), dark theme check, 48dp tap targets
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
- Test runner (Phase 1+): `npx vitest run`
- Type check: `npx tsc --noEmit`

## autonomous-dev-flow Customizations
- Test command (Phase 1+): `npx vitest run`
- Type check: `npx tsc --noEmit`
- Source directories: `apps/mobile/`, `packages/`, `supabase/`
- Test pattern: `**/*.test.ts`, `**/*.test.tsx`
- Phase 0: no automated tests yet; rely on design-doc alignment + manual review

## tackle-issues Customizations
- Max concurrent: 1 (solo-dev phase; test on device)
- Priority labels: `death-transition` > `privacy` > `bug` > `from-review` > `enhancement`
- Test gate (Phase 1+): `npx vitest run && npx tsc --noEmit`

## full-review Customizations
- Composes agent-review (LTL Inspector persona) + check-pr sequentially
- No Copilot delay concern (not configured)

## parallel-dev Customizations
- Worktree-based isolation works well for this repo
- Each worktree needs its own `node_modules` (`npm install` in worktree) once scaffolded

## smoke-test Customizations
- Check (Phase 1+): `npx tsc --noEmit` (type check)
- Check (Phase 1+): `npx vitest run` (unit tests)
- Check: design-doc alignment (any drift from `docs/LTL_Design_Document.md`?)
- Check: Supabase migrations apply cleanly against a fresh DB (Phase 1+)
