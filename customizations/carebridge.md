# CareBridge Skill Customizations

## Project Context
- **Tech:** TypeScript fullstack — Turborepo monorepo, Fastify + tRPC (api-gateway), Next.js 15 + React 19 (apps), Drizzle ORM + PostgreSQL, BullMQ + Redis, Zod, Claude API (ai-oversight)
- **Repo:** blamechris/carebridge
- **Main branch:** main
- **CI:** GitHub Actions

## Merge Gate
- **Enabled:** Yes — /full-review is MANDATORY before every merge, no exceptions
- Exception: pure `.md` skill/doc files with zero code changes can skip review

## check-pr Customizations
- Copilot polling NOT needed — no Copilot review configured
- Issue labels: `enhancement`, `bug`, `from-review`
- Code style: TypeScript strict, ESM with `.js` extensions in imports, functional style, no classes
- Evidence pattern: "per CLAUDE.md: TypeScript strict, ESM, functional style"
- Branch protection: configured with merge gate via `scripts/require-review-before-merge.sh`

## agent-review Customizations

### Persona
**CareBridge Inspector** — expert in TypeScript, Fastify, tRPC, Next.js 15, Drizzle ORM, BullMQ, Zod, healthcare data modeling, event-driven architecture, AI/LLM system design.

Mindset: "Is this type-safe end-to-end? Does it handle clinical data correctly, respect the event-driven architecture, and avoid leaking patient data?"

### Code Quality — Services (Fastify + tRPC)
- TypeScript strict, ESM (`type: "module"`, `.js` extensions in imports)
- Functional style — no classes unless absolutely necessary
- Zod validation at all service boundaries (use `@carebridge/validators`)
- All dates as ISO 8601 strings; UUIDs via `crypto.randomUUID()`
- tRPC procedures must go through `@carebridge/api-gateway` — no direct inter-service HTTP calls
- BullMQ event emission on all clinical data mutations

### Code Quality — Packages (shared libs)
- `@carebridge/shared-types` — pure types only, no runtime deps
- `@carebridge/validators` — Zod schemas only; validators must mirror shared-types
- `@carebridge/medical-logic` — pure functions, no side effects
- `@carebridge/ai-prompts` — versioned (bump `PROMPT_VERSION` on any prompt change)

### Code Quality — Apps (Next.js)
- TypeScript strict, functional components with hooks
- tRPC client via `@carebridge/clinician-portal/src/lib/trpc.ts`
- No direct database access from frontend

### Architecture
- Monorepo build order: `packages/*` → `services/*` → `apps/*`
- All clinical data mutations emit `ClinicalEvent` to Redis queue `clinical-events`
- AI oversight worker subscribes to that queue — deterministic rules first, then LLM review
- No service should import from another service directly — use tRPC via api-gateway
- `packages/db-schema` is the only place that imports `drizzle-orm` and `postgres`

### Clinical Data Rules
- Never store or log raw patient PII in non-patient-records contexts
- Clinical flags have 5 valid statuses: `open`, `acknowledged`, `resolved`, `dismissed`, `escalated`
- Rule IDs follow pattern: `DOMAIN-CONDITION-SEQ` (e.g., `ONCO-VTE-NEURO-001`)
- All AI-generated content must include rationale + suggested_action

## full-review Customizations
- Composes agent-review (CareBridge Inspector persona) + check-pr sequentially
- No Copilot delay concern (not configured)
- Combined summary table is primary output

## create-pr Customizations
- Test plan should include: `pnpm typecheck` passes, `pnpm lint` passes, affected service tested locally
- Issue labels to scan: `enhancement`, `bug`, `from-review`
- Branch naming: `feat/`, `fix/`, `refactor/`, `chore/`, `docs/` prefixes

## create-issue Customizations
- Labels available: `enhancement`, `bug`, `from-review`
- No complexity labels yet

## learn Customizations
- **CLAUDE.md sections:** `## Key Services`, `## Code Style`, `## AI Oversight Engine`
- **Rules naming:** kebab-case (e.g., `drizzle-patterns.md`, `trpc-patterns.md`, `bullmq-patterns.md`)
- **Domain quality bar:** Drizzle ORM query patterns, tRPC router patterns, BullMQ worker lifecycle, Zod schema composition, clinical data modeling patterns qualify as durable insights
- **Common paths:** `packages/**/*.ts`, `services/**/*.ts`, `apps/**/*.tsx`

## start-working Customizations

### Ready-to-Work Labels
- Treat unblocked, unassigned `enhancement` and `bug` issues as ready
- `from-review` issues are higher priority (deferred PR feedback)

### Blocked Labels
- `blocked`, `wontfix`, `needs-design`

### Roadmap File Locations
- Default scan only (`ROADMAP.md`, `TODO.md`, `docs/`)

### Source File Patterns for TODOs
- Packages: `packages/**/*.ts`
- Services: `services/**/*.ts`
- Apps: `apps/**/*.tsx`, `apps/**/*.ts`

### Priority Signals
- `from-review` → P1
- `bug` → P0
- No milestones currently in use

### Dependency Check
- `pnpm outdated`

### Test Runner
- `pnpm typecheck && pnpm lint`

### Audit Focus Areas
- Type safety across package boundaries
- Clinical data integrity and event emission correctness
- BullMQ worker error handling and retry logic
- Zod validation coverage at API boundaries

## autonomous-dev-flow Customizations

### Branch Prefix
- Uses `feat/` (not `auto/`) — matches existing naming conventions

### Decomposition Trigger
- Treat issues touching 3+ packages/services as decomposition candidates

### Test Runners
- Type check: `pnpm typecheck`
- Lint: `pnpm lint`
- Full: `pnpm typecheck && pnpm lint`

### Commit Scopes
- `db`, `ai`, `notes`, `clinical`, `auth`, `gateway`, `portal`, `infra`

### PR Test Plan
- `- [ ] pnpm typecheck passes`
- `- [ ] pnpm lint passes`
- `- [ ] Affected service tested locally`

## parallel-dev Customizations

Shares all customization points with `autonomous-dev-flow` above.

### Parallel-Specific Settings
- **Default concurrency:** 3
- **Dependency setup in worktree:** `pnpm install` (Turborepo monorepo — each worktree needs its own node_modules)

## merge Customizations

### Review Gate
- /full-review is MANDATORY before every merge — hard gate, no exceptions
- Exception: pure `.md` skill/doc files with zero code changes

### Merge Strategy
- Always `--squash --delete-branch`

### Auto-Version
- None configured yet

### Post-Merge Steps
- None required currently (no native builds)

## swarm-audit Customizations

### Domain-Specific Extended Agents

| Agent | Nickname | Lens | When to Include |
|-------|----------|------|-----------------|
| Healthcare Data Architect | "Chart Keeper" | FHIR R4, ICD-10/CPT codes, clinical data modeling, EHR interoperability, HIPAA-adjacent patterns | Target involves patient data schema, clinical data structures, FHIR gateway, or data migration |
| AI Safety Inspector | "Oversight" | LLM prompt safety, hallucination risk in clinical contexts, prompt injection, Claude API response validation, deterministic rule coverage | Target involves ai-oversight service, clinical rules engine, prompts, or flag generation logic |

### Grading Criteria
- Operator should weight data integrity: are clinical events correctly emitted and consumed?
- Guardian should weight type safety: are package boundary contracts enforced end-to-end?
- Expert agents should verify claims against Drizzle ORM and tRPC documentation

## tackle-issues Customizations
- Max concurrent: 3 (monorepo, parallel package builds safe)
- Priority labels: `bug` > `from-review` > `enhancement`
- Test gate: `pnpm typecheck && pnpm lint`

## fix-ci Customizations
- CI config: `.github/workflows/`
- Test commands: `pnpm typecheck`, `pnpm lint`, `pnpm build`
- Common failures: TypeScript strict violations, missing `.js` extensions in ESM imports, Drizzle schema drift
