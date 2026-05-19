# Skeptic's Audit: Customization Pipeline

**Agent**: Skeptic — cynical systems engineer
**Overall Rating**: 1.8 / 5
**Date**: 2026-05-19

## Executive Summary

The pipeline is built on an unexamined premise: that Haiku 4.5 at temperature 0 will (a) only touch `{{CUSTOMIZE}}` markers, (b) not invent file:line citations, and (c) reliably resolve cross-section coupling between unmarked prose. None of those hold. The system prompt at `deploy.sh:264-275` enumerates aspirations ("Preserve ALL non-customizable sections EXACTLY as-is") with zero output validation, no schema for customization notes, and no per-marker scoping — so when Haiku hallucinates (`deploy.sh:47` bug example), copies generic text verbatim (`--label "bug,from-bug-hunt"`), or mutates "unmarked" prose to stay coherent with a fabrication, the pipeline silently ships it to every managed repo. The defects on PR #17 are not bad luck — they are the predictable failure mode of a template engine that delegates determinism to a probabilistic model and then doesn't check its work.

## Top 5 Findings

### 1. The system prompt promises "ONLY job is to take X and Y" but Haiku gets no scope on what counts as "derived from"

**Finding**: Rule 1 at `deploy.sh:268` says "Replace every {{CUSTOMIZE: ...}} marker with content derived from the customization notes." There is no constraint on *how* derived — invention is not forbidden, only undocumented. The Summary Table example in `generic/bug-hunt.md:173` contains a *generic* placeholder (`bug(payments): charge handler null-derefs on missing currency | src/payments/charge.ts:47`). That row is NOT inside a `{{CUSTOMIZE}}` marker, but Haiku, having read `customizations/skill-templates.md` and seeing it talks about deploy.sh, "improved" the example to `bug(deploy): missing customization file causes silent skip | deploy.sh:47`. The literal line number from the *example* was preserved and re-cited against `deploy.sh`, producing a plausible-looking but fabricated bug citation.

**Evidence**:
- `generic/bug-hunt.md:173`: `| 1 | critical | bug(payments): charge handler null-derefs on missing currency | src/payments/charge.ts:47 | Skeptic, Guardian | — |`
- Original deployed output (commit `b27a193:.claude/commands/bug-hunt.md` L174): `| 1 | critical | bug(deploy): missing customization file causes silent skip | deploy.sh:47 | Skeptic, Guardian | — |`
- Actual `deploy.sh:47`: `echo "Usage: $0 [--dry-run] [--local] ..."` — argument-parsing usage line, not a bug
- `customizations/skill-templates.md` contains NO `deploy.sh:47` reference, NO fake bug example to copy

**Defect mapping**: Defect #1 (hallucinated deploy.sh:47 bug). This is the textbook structural cause: an unmarked example with a specific file:line was sitting next to the words "deploy.sh" in customization notes, and Haiku's temperature-0 next-token completion produced a topical re-skin while preserving the digit `47` from the generic example.

**Why this pattern recurs**: The pipeline draws no boundary between *example payload* and *contract structure* in templates. Numbered examples (`src/payments/charge.ts:47`) look to Haiku like negotiable text. Rule 3 at `deploy.sh:270` claims non-customizable sections are preserved "EXACTLY as-is," but the implicit contract — "the customizer should leave example tables alone" — is nowhere in the prompt. There is no marker syntax for "example, do not adapt" and no post-deploy validation to catch fabricated citations.

### 2. The customization notes are free-form prose, not structured slots for the markers in the template

**Finding**: `customizations/skill-templates.md` is a 68-line markdown document organized by *human-readable section headings* (`## check-pr Customizations`, `## swarm-audit / project-audit / recon / bug-hunt Customizations`). The generic templates contain *unnamed* `{{CUSTOMIZE: ...}}` markers (e.g. `generic/bug-hunt.md:61`, `:71`, `:241`, `:295`). There is no key, no marker ID, no anchor — Haiku must *guess* which prose block in the customization file maps to which marker. When the guess is wrong or partial, Haiku invents to fill the gap.

**Evidence**:
- `generic/bug-hunt.md:71`: `{{CUSTOMIZE: Add a domain-specific hunter if it pays off. Example: "GameFeel" for game projects ...; "NetworkPathology" for networking projects ...}}` — no ID, no anchor
- `customizations/skill-templates.md:50-53` defines `TemplateCritic` and `DeployPathologist`, but these are NOT bound to marker 71 by any identifier. Haiku correctly mapped them here, but only because there was one obvious match
- The Selection Algorithm at `generic/bug-hunt.md:75-82` contains no `{{CUSTOMIZE}}` markers — so Haiku had to *infer* it needed to add `TemplateCritic` / `DeployPathologist` rows there to stay consistent with the agents it injected at marker 71. That inference is unbounded.

**Defect mapping**: Defect #2 (TemplateCritic "When to Include" said `generic/*.md` but Selection Algorithm matched `generic/` directory) and Defect #4 (recon cross-section misalignment). When Haiku has to *propagate* a customization across multiple sections, none of which are individually marked, it produces inconsistent paraphrases. The "When to Include" cell and the "Selection Algorithm" line are written in different parts of the table and resolved by two independent generations of the same idea.

**Why this pattern recurs**: There is no marker for "the Selection Algorithm must list any agent added via the Extended Roster marker." Cross-section consistency is a structural property of the output, but the template treats each marker as independent. Haiku cannot maintain joint invariants it has not been told are invariants — and with temperature 0 it will pick whatever phrasing has highest local probability in each section, even when those phrasings diverge.

### 3. The system prompt's "Preserve ALL non-customizable sections EXACTLY as-is" is contradicted by what Haiku must actually do

**Finding**: Rule 3 at `deploy.sh:270` says preserve non-customizable sections "EXACTLY as-is. Do not rephrase, reorder, or 'improve' any text that isn't a {{CUSTOMIZE}} marker." But for the customization to be *coherent*, Haiku often *must* touch unmarked text — e.g., adding new agent rows to the Selection Algorithm (unmarked), adapting the Examples block (`generic/bug-hunt.md:299-305`) to use repo-relevant paths (unmarked but obviously stale if not changed), and *removing* lines like `For projects with existing post-mortem patterns ... bias Guardian or Tester to specifically hunt for that pattern.` (`generic/bug-hunt.md:61` marker content) without leaving residue. The rule is fictional. Haiku is operating under a contradiction.

**Evidence**:
- `generic/bug-hunt.md:299-305` (Examples block) has no `{{CUSTOMIZE}}` marker — yet the deployed `.claude/commands/bug-hunt.md:307-312` clearly shows repo-specific examples (`/bug-hunt deploy.sh`, `/bug-hunt sync.sh`). Haiku rewrote unmarked text.
- `generic/bug-hunt.md:17-22` (the earlier Examples block) — same: also rewritten in the deployed file at `:18-22`.
- `generic/bug-hunt.md:317`: `A typical pipeline: /recon src/payments → /bug-hunt src/payments → ...` — was rewritten to `/recon generic/ → /bug-hunt generic/` in the deployed file at `:324`. Again, no marker.

**Defect mapping**: All four defects share this root. Once Haiku is licensed to "improve" unmarked text to keep the document coherent with marker substitutions, it will also "improve" examples it shouldn't — including inventing plausible-looking bug citations. The fabricated `deploy.sh:47` example (Defect #1) is exactly this: an unmarked example row whose generic content felt incoherent next to a repo about deploy.sh, so Haiku rewrote it.

**Why this pattern recurs**: The prompt's rules are *aspirational invariants*, not enforced contracts. There is no diff-check against the generic template's non-marker regions, no whitelist of "you may rewrite unmarked text in regions A, B, C," and no detection when Haiku silently rewrites unmarked text that should have been preserved. The rule will be violated every time consistency demands it — which, by the prompt's own admission of how `{{CUSTOMIZE}}` works, is essentially every deployment.

### 4. Zero output validation. Every deploy is shipped on faith.

**Finding**: After the Claude API call in `deploy.sh:257-302`, the response is unwrapped via `jq` and written to the target repo. There is no check that file:line citations resolve, no check that examples in the output reference files that exist in the target, no check that label names match `gh label list`, no check that section headers are preserved, no check that no `{{CUSTOMIZE}}` markers remain (which *would* catch a class of failure mode). The pipeline trusts Haiku's output verbatim.

**Evidence**:
- `deploy.sh:264-275` system prompt, no validation step in the function (the file continues with retry logic for HTTP failures only)
- `sync.sh` is the *drift* checker, runs *after* deployment — and it checks "pattern conformance," not factual correctness. A fabricated `deploy.sh:47` citation would pass any pattern check.
- The hardcoded `--label "bug,from-bug-hunt"` block in the original deployment (`b27a193:.claude/commands/bug-hunt.md` L215-216): Haiku was *told* in `customizations/skill-templates.md:60` to skip complexity labels and verify with `gh label list`, but the prompt provided no mechanism to enforce that the example block reflect that instruction. No validation caught it.

**Defect mapping**: Defects #1, #2, #3, #4 all leaked because *nothing checked them.* A 50-line `validate.sh` could have flagged at least Defects #1 (regex for `deploy.sh:\d+` in deployed file → assert that line exists and contains relevant text) and #3 (assert `--label` block uses dynamic lookup or matches the customization file's label rule).

**Why this pattern recurs**: The architectural assumption is "Haiku is reliable enough." That assumption is also encoded in `CLAUDE.md` (the project documentation), which describes deploy.sh as "Claude API-powered" without any mention of validation. Without an explicit "outputs are untrusted" stance, the natural state of the system is no validation. Every defect that ships becomes someone's surprise.

### 5. Temperature 0 ≠ deterministic across slightly-different inputs; the pipeline conflates them

**Finding**: The pipeline uses `temperature: 0` (`deploy.sh:299`), which the docs and the codebase treat as a determinism guarantee. But `temperature 0` only guarantees determinism for the *same exact prompt*. The user-message at `deploy.sh:278-288` interpolates *both* the generic template content *and* the customization-file content into the prompt — so any unrelated edit to either side produces a different prompt and thus a potentially different output. The PR #17 defects appear in a deployment that was *almost* the same as previous deployments to other repos, but the customization file's `{{CUSTOMIZE}}` mapping was sparser than e.g. chroxy's, and Haiku invented more to fill.

**Evidence**:
- `deploy.sh:299`: `temperature: 0` — alone, this guarantees nothing about consistency across deploys with different customization files
- `customizations/skill-templates.md` is 68 lines; `customizations/chroxy.md` or other repos are typically much richer in concrete guidance. The same generic template, customized for two repos with very different note density, produces *very different* outputs from Haiku — and there is no calibration for how Haiku handles sparse vs. dense customizations
- The "lessons learned" section (`customizations/skill-templates.md:67-68`) is literally empty: `(None yet — file new lessons here as they are discovered, with date prefix.)` — Haiku was given license to *invent* concrete examples when there were none

**Defect mapping**: This is meta — it explains why defects appear *intermittently* and per-repo. Other managed repos (chroxy, ltl) get richer customization notes and produce more correct output. Skill-templates' own customization file is the sparsest in the deployment set, so it gets the most invention. The pipeline is structurally biased to fail hardest on the *meta-repo that maintains the pipeline.*

**Why this pattern recurs**: Without per-marker structured slots (Finding #2), the variance in output quality is a direct function of customization-file density, not pipeline correctness. The pipeline appears to "work" for rich customization files and "fail" for sparse ones — but the failure mode is *identical*: Haiku filling unmarked structural slots with plausible-looking but unverified content.

## Section Ratings

| Area | Rating | Justification |
|---|---|---|
| System prompt (deploy.sh L264-275) | 2/5 | Seven rules, all phrased as aspirations. No mechanism to enforce any of them. Rule 3 ("preserve EXACTLY as-is") is structurally violated by every deploy because unmarked examples must be rewritten to be coherent. Rule 1 ("derived from the customization notes") has no constraint on derivation depth. The prompt is good prose, bad contract. |
| {{CUSTOMIZE: ...}} marker design in generic templates | 1/5 | Markers are anonymous (no IDs, no anchors), have no scope (no indication of what surrounding text they may affect), and no consistency constraints (no way to say "this marker and that marker must agree"). The choice to put marker *instructions* inside the marker itself (`{{CUSTOMIZE: Add a domain-specific hunter if...}}`) means the customization file can't directly address a marker — it can only address the *intent* expressed in the marker, which is itself paraphrased by Haiku. |
| Customization file structure (customizations/skill-templates.md) | 2/5 | Organized by human-readable headings (`## bug-hunt Customizations`) rather than by skill/marker IDs. Sparse and unstructured. No required slots, no per-marker mapping, no examples-to-emit-verbatim section. Free-form prose is fine for human review but is exactly the wrong substrate for deterministic substitution. The "Lessons Learned" section is literally empty — a self-documenting example of the structural problem. |
| Validation / output checks (none) | 1/5 | There is no validation step. Not a regex check for `{{CUSTOMIZE}}` leakage, not a diff against the generic template's non-marker regions, not a citation-resolution check, not a label-lookup check, not a heading-preservation check. `sync.sh` exists but checks deployed-vs-template drift, not deployed-vs-truth. The entire correctness contract of the pipeline rests on the LLM call. |

## Verdict

The pipeline is **structurally underconstrained**, not fundamentally broken. The LLM call itself is a reasonable building block — Haiku 4.5 at temperature 0 is a capable substitution engine when given structured input and validated output. What's missing is everything *around* the LLM call: structured markers with IDs, structured customization slots that map 1:1 to those IDs, a "preserve verbatim" syntax for examples and code blocks, and a post-call validation step that diffs non-marker regions against the generic template and resolves any file:line citations the output introduces. The smallest set of changes that would prevent all four PR #17 defects: (a) replace anonymous `{{CUSTOMIZE: prose}}` markers with `{{CUSTOMIZE: id=hunter-extended description=...}}` and require the customization file to use matching `[hunter-extended]` sections; (b) wrap all examples in a `{{EXAMPLE}}...{{/EXAMPLE}}` block that the system prompt explicitly forbids touching unless an `[example:id]` customization exists; (c) add a 30-line `validate.sh` that runs after the Claude call and fails the deploy if (1) any `{{CUSTOMIZE}}` marker survives, (2) any file:line citation in the output doesn't resolve in the target repo, (3) non-marker regions diverge from the generic template by more than expected. Until those exist, every deploy is a coin flip on whether Haiku stays inside the lines — and PR #17 demonstrated the lines aren't actually drawn.
