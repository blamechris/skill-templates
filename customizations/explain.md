# explAIn Skill Customizations

## Project Context
- **Tech:** Expo (SDK 54+, Expo Router, RN-Web target) + TypeScript strict, NativeWind v4 (pinned to Tailwind 3.4.x — NativeWind v4 is incompatible with Tailwind 4), Supabase (Postgres + RLS + Auth + Realtime + Edge Functions/Deno), Vercel AI SDK v5 (`ai` + `@ai-sdk/anthropic` + `@ai-sdk/deepseek`). Monorepo via pnpm + Turborepo: `apps/mobile/`, `packages/{ui,db,llm,personas,shared}`, `supabase/{migrations,functions}/`.
- **Repo:** blamechris/explAIn (private)
- **Main branch:** main
- **CI:** GitHub Actions — `.github/workflows/ci.yml` runs typecheck + lint on PRs. No required check is wired to branch protection yet (solo dogfood phase).
- **Authoritative spec:** `docs/design.md` for product thesis, `docs/architecture.md` for schema + message lifecycle, `docs/roadmap.md` for v0.1 → v1 milestones.

## Product Thesis (the only non-obvious thing)
explAIn is a 1:1 messenger where each user has a per-user **advisor** that helps them refine outgoing drafts, plus a shared **mediator** with switchable personas (DM, Moderator, Arbiter, Judge, Chronicler). Both parties see the original draft, the advisor's revision, and any mediator transformation — **transparency is the product**. v0.1 ships Moderator + DeepSeek + web-only. Other personas and providers are deferred.

When reviewing or designing, ask: "does this preserve the transparency contract?" Anything that hides the original draft, the suggestion, or the mediator's reasoning from the recipient is a regression of the core value prop, not a feature.

## Zero Attribution Policy
**Critical:** Never add `Co-Authored-By: Claude`, "Generated with Claude Code", or any AI attribution in commits, PRs, issues, or file contents. The user is sole author.

## Merge Gate
- Solo-dev dogfood phase: `/full-review` is **recommended** before merging non-trivial work, not mandatory.
- Documentation-only and skill-template changes can skip review.

## Branch Protection
- `main` is currently unprotected (private repo, solo dev). When the second contributor lands or v0.1 ships publicly, enable: PR required, conversation resolution required, no force pushes, and pin the CI check name.

## RLS / Edge-Function Pattern (load-bearing)
This project hit a recurring PostgREST quirk where INSERT/SELECT through the `authenticated` role would RLS-deny even with a valid JWT and correct policies (verified via `set local role authenticated; set local request.jwt.claims = …` in the SQL editor). **Read paths and write paths that have hit this are routed through edge functions using the service role**, with the JWT decoded locally to derive `userId`:

- `supabase/functions/_shared/auth.ts` decodes the JWT directly (Kong already verifies the signature) rather than calling `client.auth.getUser()` — that call kept failing under the new asymmetric ES256 keys.
- `create-conversation`, `list-conversations`, `load-conversation`, `delete-conversation` all follow this pattern: authenticate via JWT decode, then run queries as service role with the userId pinned in WHERE clauses.
- The client calls these via plain `fetch()` in `apps/mobile/lib/edge.ts` (NOT `supabase-js` `functions.invoke()`, which has been inconsistent about auto-attaching the Authorization header in v2 — Kong was rejecting `invoke()` calls with `UNAUTHORIZED_NO_AUTH_HEADER`).

When designing a new feature that touches RLS-protected tables: default to writing an edge function unless the existing direct-PostgREST paths (e.g., `redeem_invite` RPC) are known to work for that exact policy.

## check-pr Customizations
- Copilot review may or may not be active — keep the Step 0 polling loop; bail gracefully if no review materializes.
- Issue labels: `enhancement`, `bug`, `documentation`, `question`. (Defaults from GitHub; we'll grow this list as the project matures.)
- Code style: TypeScript strict, ESM, functional components with hooks only, no `any` in new code.
- Evidence patterns: "per CLAUDE.md / docs/design.md: <thesis or constraint>", "per docs/architecture.md §<section>: …".

## agent-review Customizations

### Persona
**explAIn Inspector** — expert in Expo + Expo Router web/native, TypeScript strict, Supabase (Postgres + RLS + Edge Functions/Deno), Vercel AI SDK v5 streaming, NativeWind, and the per-user-advisor + shared-mediator transparency model.

Mindset: *"Does this preserve the transparency contract? Are RLS boundaries respected (or properly delegated to a service-role edge function with JWT-derived scoping)? Does this work on web first (v0.1 target) and not assume native APIs? Is streaming wired correctly so the UI actually shows token-by-token output?"*

### Code Quality
- TypeScript strict, ESM, functional components with hooks only
- Zod validation at edge-function trust boundaries (see `_shared/auth.ts` and the request schemas in each function)
- No `any` in new code; prefer typed errors (`EdgeError` carries `{status, code}`)
- All dates ISO 8601 strings; UUIDs via `gen_random_uuid()` in Postgres
- No comments that restate code — comments explain non-obvious *why* (e.g., the RLS workaround banner in `lib/db/queries.ts`)

### Architecture
- **Transparency contract:** every persisted message row carries `original_draft`, `advisor_suggestion`, `sent_text`, `mediator_output`, `mediator_action`, `mediator_reasoning`, `final_rendered`. UI must surface all of these to both parties (collapsible "show your work").
- **Mediator action enum:** `passthrough | annotate | transform | block | narrate` — Moderator (v0.1) only uses `annotate`. Other actions are deferred to specific personas.
- **Per-call ledger:** every LLM call (advisor, mediator, chronicler, dm) records to `llm_calls` for the future paid-quota system. Don't bypass this even for streaming.
- **RLS:** enabled on every public table; default-deny. New tables must add policies in the same migration. Direct-from-client write paths must be verified end-to-end through PostgREST, not just by SQL-editor simulation — the project has hit JWT-context propagation bugs that simulation doesn't catch. When in doubt, route through an edge function.
- **Edge functions:** stream `text/plain` for advisor/mediator (`AsyncIterable<string>` on the client). Persist message rows server-side; clients rely on realtime for the persisted row.

### Streaming + UI
- Advisor stream debounces ~400ms before firing
- Composer must accept/edit/discard the suggestion (transparency: user always sees both)
- Mediator stream is visible to BOTH participants (transparency: peer sees the rewrite/annotation in real time, not just the final)

### Privacy & Safety
- No PII in logs (DeepSeek + edge-function logs). LLM call records carry only token counts + cost, never message content.
- DeepSeek API key is server-side only (Supabase Edge Function secret). Never exposed to client.
- Future paid-tier work must respect the per-conversation `chronicle_mode` (shared vs per_user) for any data that aggregates across messages.

### Mobile / Web
- v0.1 is web-only (Expo web build). Native iOS/Android builds are deferred — but every component should still render in a native context (no `window`-only APIs in shared components).
- NativeWind v4 + Tailwind 3.4.x: do not bump Tailwind to 4 (incompatible).
- Touch targets min 44pt for the eventual mobile build.

## create-pr Customizations
- Test plan should include: `pnpm typecheck` passes (workspace root), `pnpm lint` passes, manual web check (`pnpm --filter mobile start --web`), and — when edge functions or migrations change — `supabase functions deploy <fn>` and/or `supabase db push` from the project root.
- Issue labels to scan: `from-review`, `enhancement`, `bug`, `documentation`
- Branch naming: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/` prefixes

## create-issue Customizations
- Default labels: `enhancement`, `bug`, `documentation`, `question`. We don't yet have a `from-review` label — create it when the first review-derived issue lands, or skip it gracefully.
- Reference `docs/design.md`, `docs/architecture.md`, or `docs/roadmap.md` sections in the body when the issue maps to a design decision.

## learn Customizations
- **CLAUDE.md sections:** `## Code Style`, `## Key Constraints`, `## RLS / Edge-Function Pattern`, `## Git Workflow`
- **Rules naming:** kebab-case (e.g., `rls-edge-functions.md`, `streaming-ui.md`, `transparency-contract.md`)
- **Domain quality bar:** Expo/RN-Web platform constraints, Postgres RLS + edge-function service-role patterns, Vercel AI SDK streaming, transparency UI
- **Common paths:** `apps/mobile/**/*.ts`, `apps/mobile/**/*.tsx`, `supabase/migrations/*.sql`, `supabase/functions/**/*.ts`, `packages/**/*.ts`

## start-working Customizations
- Ready-to-work signals: `enhancement` or `bug` label + acceptance criteria in body + design-doc / architecture-doc reference if relevant
- Blocked labels: `blocked`, `needs-design` (create on demand)
- Roadmap: `docs/roadmap.md`
- Source file patterns: `*.ts`, `*.tsx`, `*.sql`
- Test runner: not yet — v0.1 has no test suite. Add jest later. For now, "test" = manual web smoke + typecheck.
- Type check: `pnpm -r typecheck` (Turborepo across all packages).

## autonomous-dev-flow Customizations
- Test command: not applicable in v0.1 (no jest yet). Substitute `pnpm -r typecheck` + manual web check.
- Type check: `pnpm -r typecheck`
- Lint: `pnpm -r lint`
- Source directories: `apps/mobile/`, `packages/`, `supabase/`
- Edge-function deploy (when functions change): `supabase functions deploy <fn>` from repo root
- DB migrations: `supabase db push` from repo root; migration filenames must be `YYYYMMDDHHMMSS_*.sql` — older `0001_*.sql` style is silently skipped

## tackle-issues Customizations
- Max concurrent: 1 (solo-dev dogfood phase)
- Priority labels: `bug` > `from-review` > `enhancement` > `documentation`
- Test gate: `pnpm -r typecheck && pnpm -r lint`. Add manual web smoke when UI changes; add `supabase db reset` when migrations change.

## full-review Customizations
- Composes agent-review (explAIn Inspector persona) + check-pr sequentially.
- Copilot polling: keep the loop but tolerate absent reviews (project is private and small).

## decompose-issue Customizations
- Default sub-issue labels: `enhancement`, `bug`, `documentation`, or `question` to match the parent. `from-review` is not yet a repo label — skip it gracefully or create it when the first review-derived sub-issue lands (the skill should fall back cleanly).
- Parent-link convention: body line "Part of #N" only — no `parent:#N` label scheme.
- Parent-marker label: none currently. Skip the parent-marker step.
- Natural seams follow the monorepo: `apps/mobile/` (Expo client) vs `packages/{ui,db,llm,personas,shared}` (shared libs) vs `supabase/{migrations,functions}/` (DB schema + edge functions). Edge-function changes are usually their own sub-issue because they ship + deploy independently and have a separate trust boundary.
- Other axes: per persona (Moderator is v0.1; DM/Arbiter/Judge/Chronicler are deferred), per `Effect` / `mediator_action` variant when adding new transparency-contract surface, and per edge function when adding RLS-protected write paths.
- If the parent touches the transparency contract (`original_draft` / `advisor_suggestion` / `sent_text` / `mediator_output` columns), every sub-issue body must restate that the contract is preserved — splits often miss UI surfacing on one side.

## parallel-dev Customizations
- Worktree-based isolation works for this repo
- Each worktree needs its own `node_modules` (`pnpm install` in worktree) once scaffolded
- Edge-function and migration changes must run against the **shared** Supabase project — coordinate, don't run two `supabase db push` ops in parallel

## smoke-test Customizations
- Check: `pnpm -r typecheck` (across all workspaces)
- Check: `pnpm -r lint`
- Check: `pnpm --filter mobile start --web` boots and the conversation list loads (manual)
- Check: any new edge function deploys cleanly (`supabase functions deploy <fn>`)
- Check: if migrations changed, `supabase db reset` (against local stack) applies cleanly

## fetch-docs Customizations
- Common targets: Supabase docs (auth + RLS + edge functions + realtime), Vercel AI SDK v5 (streaming, provider config), Expo Router, NativeWind, DeepSeek API reference.
- DeepSeek's API is OpenAI-compatible at `api.deepseek.com`; it's documented separately from `@ai-sdk/openai`-style usage in the AI SDK.
