# Master Assessment: Customization Pipeline

**Target:** The skill-templates customization pipeline (`deploy.sh` + Haiku 4.5 customizer + `customizations/*.md` files + `generic/*.md` templates)
**Triggering incident:** 4 Copilot defects on PR #17 (skill-templates' own deployment) — hallucinated `deploy.sh:47` "missing GH_TOKEN export" example, cross-section rule inconsistencies, hardcoded labels violating the file's own "skip missing labels" rule, stale cross-section drift in recon.md.
**Date:** 2026-05-19
**Panel:** Skeptic, Builder, Guardian, Minimalist (4 core agents, no extended roster — fast audit per user's "real quick" request)

---

## Aggregate Rating: **1.9 / 5** — *Concerning, trending toward Fundamentally broken*

Weighted average of core panel (1.0x each):

| Agent | Rating |
|---|---|
| Skeptic | 1.8 / 5 |
| Builder | 2.5 / 5 |
| Guardian | 1.6 / 5 |
| Minimalist | 1.8 / 5 |
| **Aggregate** | **1.9 / 5** |

## Final Verdict: **Needs Work**

The pipeline is structurally sound but **underconstrained at the LLM boundary**. The 4 PR #17 defects are not anomalies — they're inevitable outputs of the current design. The minimum viable hardening is ~5 hours of work and prevents the entire observed defect class. Without that hardening, every deploy is non-deterministic in its semantic correctness, and the deployed skills themselves become misinformation vectors for downstream agents.

---

## Auditor Panel

| Agent | Lens | Rating | Key contribution |
|---|---|---|---|
| Skeptic | Claims vs reality | 1.8/5 | Identified the structural cause of the `deploy.sh:47` hallucination: `generic/bug-hunt.md:173` contains an unmarked example row with `src/payments/charge.ts:47` — Haiku preserved the digit `47` while re-skinning the row, because Rule 3 ("preserve EXACTLY as-is") is structurally violated by Examples blocks every deploy. |
| Builder | Implementability | 2.5/5 | Most optimistic — sees this as a guideline/procedural fix, not an architecture rewrite. Specific 5-hour action plan: 20-line `validate_output()` function + customization file restructuring + table-walking selection algorithm. |
| Guardian | Failure modes | 1.6/5 | Most concerned. **The deployed skill itself is the attack surface** — skills are agent instructions, not docs, so a hallucinated bug example becomes a prompt-injection vector for future `/bug-hunt` runs. Calls this a "today problem," not "tomorrow." |
| Minimalist | Cut what doesn't pay | 1.8/5 | The contrarian voice: argues the LLM step itself is over-engineered. Estimates ~70% of `{{CUSTOMIZE: ...}}` markers are simple substitutions (path / command / label list) that mustache/envsubst handle deterministically. Haiku is being used as a $0.001/call regex engine. |

---

## Consensus Findings (3+ agents agree)

### C1 — **Zero output validation between Haiku response and deploy.** *(All 4 auditors)*

`deploy.sh:257-302` (call) → `:358` (read `.content[0].text`) → `:361` (check `[ -z "$response" ]` only) → file write → `git add` / `gh pr create`. **No semantic check happens anywhere in this chain.** A 30-line validator (residual `{{CUSTOMIZE` regex, attribution scan, heading parity, file:line citation resolution, label-name check against `gh label list`, length bounds) would catch every PR #17 defect.

**Priority: P0.** This is the highest-leverage fix. Even partial validation (just regex for residual markers + attribution) prevents the worst classes.

### C2 — **The customization-file architecture invites invention.** *(Skeptic, Builder, Minimalist)*

`{{CUSTOMIZE: ...}}` markers in `generic/bug-hunt.md` and `generic/recon.md` are unstructured prose like:

> `{{CUSTOMIZE: Add a domain-specific hunter if it pays off. Example: "GameFeel" for game projects...}}`

There is no marker ID, no schema, no "do-not-invent" boundary. The customization file is human-organized markdown, not a typed input. Haiku is told to "use the customization notes to fill it in appropriately" — which licenses creative completion when notes are sparse. The 4 PR #17 defects all came from places where Haiku had to invent content the customization file didn't directly provide.

**Priority: P1.** Restructure 1-2 worst markers as constrained slots (allowlist, "use only these examples, do not add others"). Builder estimates 1-2h.

### C3 — **Skill-templates' own customization file is structurally weaker than peer files.** *(Skeptic, Builder)*

Comparison from Builder:
- `customizations/chroxy.md:285-294` — proper table with all columns (Nickname, Lens, When-to-Include)
- `customizations/ltl.md:30-71` — per-skill named subsections
- `customizations/skill-templates.md:48` — merges four skills under one heading, agent definitions as prose bullets without nicknames

This is **why skill-templates produced the defects and chroxy didn't.** Skill-templates is the meta-repo that maintains the pipeline — the pipeline fails hardest on its own customization. Builder estimates 45min to restructure.

**Priority: P1.** Also a useful test: a corrected `skill-templates.md` is the canary for whether the pipeline produces clean output from a well-formed input.

### C4 — **"Preserve exactly as-is" (Rule 3) is structurally violated every deploy.** *(Skeptic, Minimalist)*

The customizer system prompt at `deploy.sh:270` says: *"Preserve ALL non-customizable sections EXACTLY as-is. Do not rephrase, reorder, or 'improve' any text that isn't a {{CUSTOMIZE}} marker."*

But Examples blocks (`generic/bug-hunt.md:299-305`, `:317`, summary-table example at `:173`) contain no markers and are clearly re-adapted in the deployed output. Once Haiku has license to rewrite unmarked text for "coherence," it will also rewrite the example bug citation — and `deploy.sh:47` is born. The system prompt promises something the model is not actually doing.

**Priority: P2.** Either add an explicit do-not-touch syntax (`<!-- VERBATIM -->...<!-- /VERBATIM -->`), or accept that examples will be re-skinned and constrain how (e.g., "Example references must use placeholders like `path/to/file:<line>`, never real file:line").

---

## Contested Points

### **Should the LLM step exist at all?** *(Minimalist vs everyone else)*

- **Minimalist (1.8/5):** ~70% of markers are simple substitutions. Replace Haiku with mustache/envsubst (~50 lines). Eliminates the entire defect class — you can't hallucinate what you can't synthesize.
- **Skeptic (1.8):** LLM is fine; what's missing is marker structure and a 30-line validator.
- **Builder (2.5):** LLM is doing real work (rephrasing customization prose into deployment-ready content). Replacing it would force every customization file to be pre-formatted markdown blocks that match the template's exact context.
- **Guardian (1.6):** Doesn't take a strong position; focused on the gate, not the engine.

**Synthesizer's call:** **Minimalist is right in principle but wrong in practical sequencing.** Replacing Haiku with deterministic templating is a 1-2 week refactor that breaks the customization-author UX. The 5-hour validation + restructuring fix gets you 80% of the safety for 5% of the cost. **If validation + restructuring don't hold after two more deployment cycles, escalate to Minimalist's path.**

### **How bad is it?** *(Guardian vs Builder)*

- **Guardian: today problem.** Deployed skills become prompt-injection material for future agents; recovery is 13 manual reverts.
- **Builder: tomorrow problem.** Defects so far have been caught by Copilot; minimal fixes prevent recurrence.

**Synthesizer's call:** **Guardian's framing is more accurate but Builder's prioritization is right.** The blast radius is real (a hallucinated "critical bug" in a deployed skill would be acted on by `/bug-hunt`), but the rate is low enough that Phase 1 fixes are sufficient response. The relevant Guardian guard (residual `{{CUSTOMIZE` regex + attribution scan, 5-10 lines) is already in Builder's P0 action.

---

## Factual Corrections to Earlier Work

| What was claimed | Reality | Source |
|---|---|---|
| "Empty `customizations/sovereign-storm.md` doesn't trigger deploys" (PR #16 reasoning) | True for `--changed-customs`, but if a parallel session edits *any* customization file, the empty file is still passed to Haiku and produces fully-fabricated content. Skeptic flagged this as a near-miss. | Skeptic finding 5 |
| `deploy.sh:47` "missing GH_TOKEN export" critical bug | deploy.sh:47 is argument parsing (`shift ;; *) echo "Unknown argument: $1" >&2`). `GH_TOKEN` is correctly exported at deploy.sh:251-254. The example was hallucinated by Haiku. | All 4 auditors |
| "Rule 3 means non-customizable sections are preserved exactly" | The rule is in the system prompt but is structurally violated on every deploy (examples blocks are re-skinned). Haiku interprets "non-customizable" as "non-{{CUSTOMIZE: ...}} marker" but doesn't preserve examples within those markers. | Skeptic, Minimalist |

---

## Risk Heatmap

```
                    IMPACT
            Low      Medium     High     Critical
         ┌────────┬──────────┬────────┬──────────┐
  Likely  │        │ ░░ R5    │ ██ R1  │ ░░ R2    │
         ├────────┼──────────┼────────┼──────────┤
 Possible │ ·· R6  │ ·· R7    │ ░░ R3  │ ██ R4    │
         ├────────┼──────────┼────────┼──────────┤
 Unlikely │        │          │        │          │
         └────────┴──────────┴────────┴──────────┘

██ = Immediate action   ░░ = Plan to address   ·· = Monitor
```

- **R1 (Likely × High):** Hallucinated example content in deployed skills (the PR #17 class). Has already shipped; will recur without intervention.
- **R2 (Likely × Critical):** Cross-section rule inconsistencies that change skill behavior (recon.md Selection Algorithm vs When-to-Include). Subtle and not caught by surface review.
- **R3 (Possible × High):** Hallucinated bug example acted on as real by downstream `/bug-hunt` agent — wasted investigation cycles.
- **R4 (Possible × Critical):** Customization file goes stale / wrong (e.g., zero-attribution policy claim against a repo that allows attribution — the actual near-miss on PR #16). One bad file deploys to 13 repos.
- **R5 (Likely × Medium):** Stale or contradictory deployed skills shipping silently because no diff-of-meaning validation exists.
- **R6 (Possible × Low):** Haiku regression on model version change (4.5 → 4.6) introducing new defect classes — currently zero canary / golden-file coverage.
- **R7 (Possible × Medium):** Branch name collision on `skill-deploy/${BRANCH_DATE}` recycling (Guardian finding 5).

---

## Recommended Action Plan

Synthesized and deduplicated. Ordered by impact / effort.

| # | Recommendation | Priority | Effort | Source | Catches |
|---|---|---|---|---|---|
| 1 | Add `validate_output()` to deploy.sh between Haiku response and file write — at minimum: residual `{{CUSTOMIZE` regex, attribution scan (Co-Authored-By / Generated with), heading-count parity vs template, output length bounds | **P0** | M (2-3h) | All 4 | R1, R2, R5, R6 |
| 2 | Restructure `customizations/skill-templates.md` to match `chroxy.md` / `ltl.md` structural pattern — per-skill named subsections, proper agent tables with nickname / lens / when-include columns | **P0** | S (45min) | Builder, Skeptic | R1, R2 |
| 3 | Add a "do-not-invent" constraint to the customizer system prompt — explicitly: "Do not synthesize example content not present in the customization notes. For example bug citations, use placeholders like `path/to/file:<line>` unless a real reference is provided" | **P0** | S (15min) | Skeptic, Minimalist | R1 |
| 4 | Tighten `{{CUSTOMIZE: ...}}` markers in `generic/bug-hunt.md` and `generic/recon.md` — replace open-ended "Add X if it pays off. Example: ..." with closed: "Add domain-specific X ONLY if customization notes provide them. Do NOT invent." | **P1** | S (1h) | Skeptic, Builder | R1 |
| 5 | Add golden-file regression test in CI — one canonical (template + customization) → expected output, asserted in deploy-skills workflow before fan-out | **P1** | M (3h) | Guardian | R6 |
| 6 | Replace the parallel Selection Algorithm in `generic/bug-hunt.md` with a table-walk so adding a hunter via customization doesn't leave the algorithm stale | **P1** | S (1h) | Builder | R2 |
| 7 | Add branch protection on `customizations/**` + `generic/**` requiring PR review before merge — prevents an in-progress customization edit from triggering deploy mid-write | **P2** | S (15min) | Guardian | R4 |
| 8 | Capture Haiku request+response as workflow artifacts with template/custom content hashes baked into the version stamp — auditability when a bad deploy is discovered later | **P2** | M (2h) | Guardian | R6 |

**Phase 1 (this week):** Items 1-4. ~5 hours total. Eliminates every PR #17 defect class.
**Phase 2 (this month):** Items 5-6. Adds drift protection and tightens hunter-roster sync.
**Phase 3 (backlog):** Items 7-8. Defense-in-depth for low-probability / high-impact failure modes.

**Deferred / rejected:**
- Minimalist's "rip out Haiku, replace with mustache." Correct in principle, wrong in sequencing. Re-evaluate if Phase 1 doesn't hold after 2+ deployment cycles.

---

## Appendix: Individual Reports

| Agent | File | Rating | Headline |
|---|---|---|---|
| Skeptic | [01-skeptic.md](./01-skeptic.md) | 1.8/5 | Structurally underconstrained; LLM call is fine but lacks marker IDs, do-not-touch syntax, and post-call validator |
| Builder | [02-builder.md](./02-builder.md) | 2.5/5 | Guideline/procedural fix, not architecture rewrite; 5-hour action plan prevents every PR #17 defect |
| Guardian | [03-guardian.md](./03-guardian.md) | 1.6/5 | Today problem; deployed skills are agent instructions, not docs, so hallucinations are injection vectors |
| Minimalist | [04-minimalist.md](./04-minimalist.md) | 1.8/5 | Haiku is being used as a $0.001/call regex engine; ~70% of markers are deterministic substitutions in disguise |
