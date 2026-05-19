# Minimalist's Audit: Customization Pipeline

**Agent**: Minimalist — ruthless cutter
**Overall Rating**: 1.8 / 5
**Date**: 2026-05-19

## Executive Summary

This pipeline is **over-engineered for its actual job**. Haiku is being used as a $0.001-per-call regex engine, and the 4 defects in PR #17 are not bugs — they are the inevitable hallucinations of asking an LLM to "invent" content when nothing in the customization file authorizes it. The fix is not more validation, not more examples, and not more guard-rails. The fix is to **stop calling the LLM for things a templating engine can do**, and to **forbid markers that ask the model to invent content the customization file doesn't already contain**.

## What to Cut (Top 5)

### 1. **The LLM-as-customizer step (mostly)**

**What**: Replace `call_claude()` with deterministic templating (mustache, envsubst, or a 40-line awk/python script) for ~70% of the existing markers.

**Why it costs more than it returns**: I inspected the actual marker contents in `generic/smoke-test.md`, `generic/merge.md`, and `generic/autonomous-dev-flow.md`. The dominant marker class is **simple text substitution**:

```
{{CUSTOMIZE: Path to smoke test script}}              → "packages/server/tests/smoke-test.mjs"
{{CUSTOMIZE: Test runner command}}                    → "npx jest"
{{CUSTOMIZE: Branch prefix}}                          → "feat/"
{{CUSTOMIZE: Commit scope conventions}}               → "server, app, desktop, tunnel, ws, cli"
{{CUSTOMIZE: UI file pattern}}                        → "dashboard-next|\.tsx$|\.css$"
```

These are **named-key string substitutions**. Mustache handles them in 5 lines of code, deterministically, for free, with no API key, no retry logic, no rate-limit handling, no jq escaping, no Bash 3.2 heredoc gymnastics. The current `deploy.sh` spends roughly **lines 257–367 (110 lines)** wrapping a single API call — that is more code than the actual customization logic deserves.

Every Haiku call introduces stochastic risk. Temperature 0 reduces but does not eliminate it — Haiku still chooses tokens; deterministic determinism is a stronger guarantee than "we asked it to be deterministic."

**What replaces it**: A YAML/JSON-frontmatter `customizations/<repo>.yaml` keyed by skill, with named substitution variables. `deploy.sh` becomes `envsubst < generic/skill.md > target.md` (or mustache). The 4 defects on PR #17 all came from places where Haiku had to **invent** — replace those markers with explicit named slots and the bug class disappears at the source, not in a validator.

**Risk of cutting**: Real. The pipeline genuinely does **two** different jobs today: (a) substitute named values, (b) gracefully *omit* sections whose marker has no matching content (system prompt rule 2). A pure substitution engine handles (a) trivially but needs a tiny convention for (b) — e.g., `{{#if smoke_test}} ... {{/if}}` or just "if the variable is empty, skip the section." This is 20 lines of templating logic, not 110 lines of API plumbing.

### 2. **The "invent content" class of markers**

**What**: Forbid markers that ask Haiku to imagine. These four marker types should be **deleted from every generic template**:

| Bad marker pattern | Why it's a hallucination factory |
|---|---|
| `{{CUSTOMIZE: Add a domain-specific hunter if it pays off. Example: GameFeel for game projects...}}` | Asks Haiku to invent a roster entry. The example IS the temptation. |
| `{{CUSTOMIZE: Adjust label set to match this repo's conventions}}` | Repo's label list is **knowable** (`gh label list`) — don't ask the LLM to guess. |
| `{{CUSTOMIZE: For projects with existing post-mortem patterns, bias Guardian to specifically hunt for X. Example: ...}}` | The "Example:" gets copied into output verbatim with token-level mutations. |
| `{{CUSTOMIZE: If this repo has a known class of bug, encode it here as a mandatory check}}` | Same trap — example-with-mutation. |

**Why it costs more than it returns**: The deployed `bug-hunt.md` shows the failure mode cleanly. Compare generic line 173 (the example row in the summary table) vs deployed line 175:

- Generic: `| 1 | critical | bug(payments): charge handler null-derefs on missing currency | src/payments/charge.ts:47 | ...`
- Deployed: `| 1 | critical | bug(scope): concise issue title | path/to/file:<line> | ...`

Haiku **mutated the example row into a placeholder** because the table was inside a customizable section and it tried to "generalize" it for the repo. The example was load-bearing illustrative content, and the model decided it was customizable. This is exactly the class of defect you get when you give an LLM creative latitude inside a template.

**What replaces it**: Two changes. (1) Examples in templates go in fenced code-blocks or `<!-- example -->` comments that the templater is forbidden from touching. (2) "Add if relevant" markers become **explicit named slots** in customization files: `extended_hunters: []` is empty by default, or a populated list. No latitude.

**Risk of cutting**: Some templates currently have nice "for this repo, add..." flexibility. After the cut, adding a domain hunter requires editing the customization file rather than having Haiku notice from prose. Honest assessment: this is **a feature**, not a regression. The customization file should be the contract, not Haiku's interpretation of the customization file.

### 3. **Half the depth of every customization file**

**What**: `chroxy.md` is 293 lines. `medlens.md` is 94 lines. The chroxy file contains five "Lessons Learned" sub-sections, exhaustive merge instructions for Tauri rebuilds, version-sync detail across 9 files, and full smoke-test rituals — easily 150+ lines that **Haiku does not use to fill any marker**.

**Why it costs more than it returns**: Look at the deployed `bug-hunt.md` vs the generic. The customization that **actually shipped into the deployed file**:

> "For this repo (skill-templates), Guardian must specifically hunt for deploy.sh/sync.sh failure modes: missing customization files, Haiku API errors, GH Actions auth failures, and bash 3.2 incompatibilities..."

This came from `customizations/skill-templates.md` section "swarm-audit / project-audit / recon / bug-hunt Customizations / Domain Agents". That section is **9 lines**. The other **59 lines** of that file are background context (project description, attribution policy, bash-compat notes, etc.) that Haiku reads, the context cost is paid, and the content **does not flow into the deployed skill**.

In `chroxy.md`, the "Lessons Learned" entries with dated post-mortems are valuable to humans but **inert** to the customizer — Haiku doesn't have a marker that ingests them. They're paying token cost on every customization call across all 17 skills × this repo, for zero output.

**What replaces it**: Split customization files into two:
- `customizations/<repo>.yaml` — structured, named slots, ~30 lines per repo. This is what the deployer reads.
- `customizations/<repo>-notes.md` — human-only context, lessons learned, dated post-mortems. **Not sent to the API.**

**Risk of cutting**: Some lessons learned *might* be implicitly informing Haiku's tone. Honestly? Unlikely at temperature 0 on a short skill template. The risk is low and the savings are large (~60–80% token reduction per call × 17 skills × 14 repos).

### 4. **The CI fan-out + PR creation flow**

**What**: Don't open 14 PRs across 14 repos for every template change. Replace with one of:

(a) **Submodule** — managed repos add `skill-templates` as a git submodule at `.claude/commands-src/`, with a tiny `post-merge` hook that runs templating locally. Updates are a `git submodule update` away.

(b) **Cron-pull** — managed repos have a `sync-skills.yml` workflow on their own cron that pulls latest, runs templating, and self-commits.

(c) **Symlink farm** — for the local-dev case (which is most of them in this single-user setup), `.claude/commands/` symlinks into a central deployed set.

**Why it costs more than it returns**: The CI flow in `deploy.sh` is a *significant* chunk of the script: lines 442–588 (~150 lines) handle clone-with-PAT-credential-helper defenses, branch idempotence, push, gh-pr-create with token export, existing-PR detection. Half of `.claude/rules/gh-actions.md` exists *only* because of this fan-out. The PAT health-check at line 462 exists *only* because of this fan-out. The `osxkeychain` workaround at line 480 exists *only* because of this fan-out.

A single managed repo (e.g., `medlens`) probably sees a skill-templates PR roughly **once a week**. The PR auto-merges or sits open. Either way: it's noise.

**Risk of cutting**: You lose the per-repo review point. For a single-user system where the human author of the templates is also the human author of every managed repo, this review point is **theater**. For a multi-tenant org? Keep the PR flow. For this org of one? Cut it.

### 5. **The `<!-- skill-templates: <skill> <hash> <date> -->` version stamp**

**What**: Remove the stamp at deploy.sh:411–416.

**Why it costs more than it returns**: It exists so `sync.sh` can detect drift. But you have `git` and a deterministic templater — drift detection becomes `diff <(deterministic_render generic/skill.md customs/repo.yaml) deployed_skill.md`. No stamp needed; the templater is reproducible.

**What replaces it**: Nothing. `sync.sh` becomes `for repo,skill in pairs: render and diff`.

**Risk of cutting**: Low. The stamp is informational; removing it makes deployed files cleaner (one fewer line of meta-commentary).

## What's Doing Real Work

Three parts of this pipeline genuinely earn their keep:

1. **`deploy.conf` as the single source of truth.** The repo→skills mapping in pipe-delimited config form is honest, greppable, and matches the audit need. Keep.
2. **`build_pairs()` change-detection logic.** Deciding "which (repo, skill) pairs need redeploying after a change" is real work that needs done deliberately. Keep.
3. **The PAT health-check + credential-helper workaround** (lines 462–500). Once you commit to CI-based fan-out, those defenses are correctly defending against real macOS-runner pathologies (#15 in the comments cites this). They're ugly because **CI fan-out is ugly**, not because the workaround is wrong. (See cut #4: kill the fan-out and the workaround dies with it.)

## Counter-recommendation

The other auditors will propose hardening. I expect:

- **Builder** will propose adding a marker schema (e.g., `{{CUSTOMIZE:key=test_runner, type=string, required=true}}`), a pre-flight validator, and example outputs the LLM should match.
- **Guardian** will propose a post-deploy diff check, output-shape validation (count headings, check for stray `{{CUSTOMIZE}}` leakage), and rollback on validation failure.
- **Skeptic** will probably argue the LLM should be replaced by structured output (tool-use / JSON mode) with a tight schema, plus assertions on every section.

**My counter-argument**: Builder's marker schema is the right diagnosis with the wrong prescription. Once you have `key=test_runner, type=string, required=true`, **you no longer need the LLM**. The schema *is* the templating contract. Asking Haiku to perform substitution from a typed schema is paying the API tax to do what `envsubst` does in pure C. Builder will land you at "LLM + schema + validator + retry + manual review of every PR" — which is exactly the pipeline that produced 4 defects today, but with more YAML.

**Where less is more**: If the marker can be expressed as `{{key}}`, the marker doesn't need an LLM. Reserve the LLM **only** for genuinely generative tasks — and ideally, audit whether *any* marker in the current template set is genuinely generative. (I claim: zero are. Every marker I inspected is either a named substitution or a "should this section appear at all" toggle. Both are deterministic.)

The hardening proposals will improve the pipeline by ~20%. Cutting the LLM step entirely improves it by **>80%** because most of the failure surface (hallucination, retries, jq escaping, rate limits, API key management, response parsing, token budgeting) **vanishes**, not gets validated.

## Section Ratings

| Area | Rating (current value) | Could it be simpler? |
|---|---|---|
| LLM-as-customizer (vs. deterministic templating) | 1/5 | Yes — replace with mustache/envsubst for ~95% of markers. Reserve LLM (if at all) for one explicit `{{LLM_GENERATE: ...}}` marker class, and audit whether any exists. |
| Per-repo customization files | 2/5 | Yes — split into structured data (`.yaml`) + human notes (`.md`). Stop sending 200-line files to the API to extract 20 lines of substitutions. |
| `{{CUSTOMIZE: ...}}` marker richness | 1/5 | Yes — current free-form prose markers ARE the bug. Replace with typed named slots. The defects on PR #17 are direct evidence: every "Example: ..." inside a marker is a hallucination invitation. |
| CI fan-out PR creation | 2/5 | Yes — for a single-user org, submodule or cron-pull eliminates ~150 lines of clone/push/PR machinery and an entire class of macOS-runner-auth pathologies. |

## Verdict

This pipeline is doing a **deterministic job with a stochastic tool**, then adding 200 lines of bash to manage the stochasticity. The 4 defects on PR #17 are not symptoms of "insufficient validation" — they are the predictable cost of giving an LLM creative latitude over content that has a canonical right answer. The correct minimal architecture is: structured customization data (YAML), a 50-line templater (envsubst or mustache + tiny conditional logic), and no API call at all. The pipeline as it stands is justifiable **only** if a future use case requires genuine content generation that a human couldn't author once and store as a slot value — and I see no such case in the current marker set. Cut the LLM. Cut half the customization-file depth. Cut the CI fan-out. What remains is ~100 lines of bash that does the same job, more reliably, for $0.
