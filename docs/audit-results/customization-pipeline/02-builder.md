# Builder's Audit: Customization Pipeline

**Agent**: Builder — pragmatic full-stack dev
**Overall Rating**: 2.5 / 5
**Date**: 2026-05-19

## Executive Summary

The pipeline is one underspecified system prompt (deploy.sh:264–275) plus N free-form customization markdown files, with zero post-deploy validation. Three concrete changes — (a) constrain each `{{CUSTOMIZE: ...}}` marker so the model has less room to extrapolate, (b) post-process the model output through a deterministic linter before write, and (c) restructure `customizations/skill-templates.md` to mirror the field-shape of the good files — would have prevented all four defects from PR #17 with maybe four hours of work total. Anything beyond that is over-engineering for a 10–15 deploy/week pipeline.

## Top 5 Findings (Builder lens)

### 1. The "Skip missing labels rather than failing" rule lives in prose, not in code

**Finding**: The generic template at `generic/bug-hunt.md:215-241` hardcodes `--label "bug,from-bug-hunt"` inside a fenced bash block, then *prose* below it says "Verify labels exist before using them. Skip missing labels rather than failing." Haiku is asked to "preserve all code blocks, bash examples, and formatting exactly as they appear in the template" (`deploy.sh:274`). So the prose rule and the code example contradict each other. Haiku correctly preserved the code block; the deployed `.claude/commands/bug-hunt.md` ended up with the dynamic label-intersection fix only because someone hand-corrected the *generic* template after the fact. Same template still has the failure mode latent — any future regression of the dynamic block restores the bug.

**Evidence**:
- `generic/bug-hunt.md:213-215` — `gh issue create \ --title "${TITLE}" \ --label "bug,from-bug-hunt" \`
- `generic/bug-hunt.md:239` — `**Verify labels exist** before using them. Skip missing labels rather than failing.`
- Deployed `.claude/commands/bug-hunt.md:215-248` now has the corrected dynamic label-intersection block — but that fix lives in the *generic* template, not as a deploy.sh post-processor.

**Specific fix**: Move the label-intersection block into the generic template as the canonical code path (already done in `generic/bug-hunt.md` post-fix — verify) AND add a deploy.sh post-process step: `grep -E '^\s*--label "[^${]*"' "$result"` flags any literal `--label` line in deployed output and fails the deploy. One regex, one CI gate.

**Effort estimate**: S (30 min — one grep, one error path in `deploy_pair`)

### 2. `{{CUSTOMIZE: ...}}` markers have no schema — Haiku invents the cardinality

**Finding**: Markers in `generic/bug-hunt.md:61, 71, 241, 295` describe *intent* in English ("Add a domain-specific hunter if it pays off"). The customization file in `customizations/skill-templates.md:48-58` provides *two* extended agents (TemplateCritic, DeployPathologist) in a bullet-list with prose descriptions — no nickname, no lens, no When-to-Include column. Haiku saw bullets-with-descriptions where the template wanted a table-row-shaped extension, and synthesized fields it didn't have. Result: the deployed `bug-hunt.md:70-71` invents `"Architect"` and `"Deployer"` nicknames not present in the input. That's hallucination by missing schema, not by model failure.

**Evidence**:
- `generic/bug-hunt.md:71` — `{{CUSTOMIZE: Add a domain-specific hunter if it pays off. Example: "GameFeel" for game projects (frame-rate spikes, input lag, save-game corruption); "NetworkPathology" for networking projects (silent drops, reconnect storms).}}`
- `customizations/skill-templates.md:52-53` — `- **TemplateCritic** — checks that generic templates produce correct deployed skills...` (no nickname, no When-to-Include criteria)
- Deployed `.claude/commands/bug-hunt.md:70-71` — Haiku invented `| TemplateCritic | "Architect" | ... | Target is a generic template ... |` — the **"Architect"** nickname appears nowhere in the customization file.

**Specific fix**: Change the marker syntax to be partly machine-parseable. Replace `{{CUSTOMIZE: free prose}}` with `{{CUSTOMIZE name="extended-hunters" shape="table-rows" columns="hunter,nickname,lens,when_to_include" required="hunter,when_to_include" optional="nickname,lens"}}`. Then in `customizations/skill-templates.md`, structure the input to match: either provide the columns, or omit. Haiku now extrapolates over a defined surface, not English suggestions.

**Effort estimate**: M (3–4h — define schema, migrate ~15 markers across `generic/*.md`, update 2–3 customization files. Most templates can keep the free-prose form for non-tabular content; only tabular customizations need the schema.)

### 3. Selection Algorithm vs When-to-Include columns drift independently

**Finding**: `generic/bug-hunt.md:67-71` (Extended Roster table) and `generic/bug-hunt.md:73-82` (Selection Algorithm) are two parallel rule sources for the *same* selection decision. When a customization adds new hunters via the marker at `:71`, only the table updates — the Selection Algorithm at `:76-83` is not a `{{CUSTOMIZE}}` insertion point, so the new hunters never get a selection rule. Deployed `bug-hunt.md:73-84` now has TemplateCritic + DeployPathologist conditions in the algorithm because someone hand-added them post-deploy, but the *generic* template still has no `{{CUSTOMIZE}}` marker on the algorithm. Next custom hunter added → same defect.

**Evidence**:
- `generic/bug-hunt.md:66-71` — Extended Roster table has a `{{CUSTOMIZE}}` marker at :71
- `generic/bug-hunt.md:73-82` — Selection Algorithm has NO marker; structurally cannot be extended via customization
- Deployed `.claude/commands/bug-hunt.md:77-83` — selection algorithm hand-extended with TemplateCritic/DeployPathologist lines that are not derivable from `customizations/skill-templates.md`

**Specific fix**: Either (a) replace the static Selection Algorithm with a `{{CUSTOMIZE selection-rules}}` marker that requires the customization to specify which extended agents apply when, or (b) collapse the two surfaces — put the When-to-Include condition only in the table, and have the Selection Algorithm read from the table column generically ("For each remaining slot: include any extended hunter whose When-to-Include condition matches"). Option (b) is simpler.

**Effort estimate**: S (1h — edit `generic/bug-hunt.md` and `generic/recon.md` to collapse the algorithm to a table-walk)

### 4. No post-deploy validation step at all

**Finding**: `deploy.sh:418-440` writes Haiku's raw output to disk after appending a version stamp. There is no schema check, no `{{CUSTOMIZE}}` residue check, no hallucinated-line-number check, no "did model add attribution" check. The defect 1 from PR #17 — Haiku hallucinated a `deploy.sh:47` example bug — would have been caught by a trivial post-process: `grep -nE '\bdeploy\.sh:[0-9]+\b' "$result"` and cross-reference against `wc -l deploy.sh`. Defect 3 (hardcoded label) caught by the regex above. Defect 4 (cross-section drift) caught by a "two tables describe the same set; their row counts should match" check.

**Evidence**:
- `deploy.sh:404-422` — `result=$(call_claude ...)`, then immediately stamped and written. No validation between call and write.
- `deploy.sh:438` — `echo "$content" > "$target_file"` — write happens before any inspection.

**Specific fix**: Add a `validate_output()` function called between `call_claude` and `deploy_local`/`deploy_ci`. Minimum checks: (a) no remaining `{{CUSTOMIZE` substring, (b) no `Co-Authored-By`/`Generated with Claude` (already user-policy violation), (c) any `file.ext:LINE` reference where `file.ext` matches a tracked file must have LINE ≤ `wc -l file.ext`, (d) no hardcoded `--label "..."` literals when the source template has a dynamic-label pattern. Fail the deploy if any check fails — the version stamp ensures retry-safety.

**Effort estimate**: M (2–3h — five small validators; the cross-reference against `wc -l` is the only one with any complexity)

### 5. `customizations/skill-templates.md` is structurally weaker than `chroxy.md` / `ltl.md`

**Finding**: skill-templates.md (69 lines) is significantly more prose-heavy and missing the field-shape that good customization files use. Contrast `chroxy.md:281-294` and `ltl.md:21-26` — both have *named subsections* keyed to specific skills and provide structured field data Haiku can map 1:1. `skill-templates.md:48-58` lumps `swarm-audit / project-audit / recon / bug-hunt` together under one heading and provides bullet-prose for agents instead of a table. Haiku has to choose where each bullet lands, and chose wrong.

**Evidence**:
- `customizations/chroxy.md:285-294` — `### Domain-Specific Extended Agents` with proper markdown table: `| Agent | Nickname | Lens | When to Include |`
- `customizations/ltl.md:30-71` — `### Persona` / `### Code Quality` / `### Architecture` / `### Grief-Sensitive UX Rules` / `### Privacy & Safety` — discrete labeled subsections, no merging.
- `customizations/skill-templates.md:48-58` — `## swarm-audit / project-audit / recon / bug-hunt Customizations` (four skills merged) with prose-bullet agent definitions instead of a table.

**Specific fix**: Restructure `customizations/skill-templates.md` to mirror `chroxy.md`'s pattern: (a) separate sections per skill (no four-skill merged headers), (b) tables for tabular content (agents/hunters), (c) explicit `### When to Include` text for each extended agent. Concretely: split lines 48-58 into `## bug-hunt Customizations / ### Domain-Specific Hunters` (table format) and `## recon Customizations / ### Domain-Specific Scouts` (table format).

**Effort estimate**: S (45 min — pure markdown restructuring, no logic changes)

## Comparative Analysis

`chroxy.md` and `ltl.md` produce defect-free deployments. `skill-templates.md` produced four defects on one PR. Structural differences:

| Dimension | chroxy.md / ltl.md (good) | skill-templates.md (defective) |
|---|---|---|
| **Section keying** | One `## <skill> Customizations` heading per skill (e.g., `## smoke-test`, `## merge`) | Four skills merged into one heading: `## swarm-audit / project-audit / recon / bug-hunt Customizations` |
| **Tabular data** | Tables when the generic template expects tabular output. `chroxy.md:285-294` provides `\| Agent \| Nickname \| Lens \| When to Include \|` — same columns as the generic template's Extended Roster | Prose bullets at `:52-53`: `- **TemplateCritic** — checks that...`. No nickname, no When-to-Include column. Haiku must invent the missing fields. |
| **Subsection labels** | `### Persona`, `### Code Quality`, `### Architecture`, `### Mobile`, `### Lessons Learned` — every block is named | One unlabeled "agents" bullet list plus one "Hotspot Guidance" prose block |
| **Lessons Learned dated** | `chroxy.md:24-26` has dated post-mortems (`**2026-02-08:**`, `**2026-02-10:**`, `**2026-02-16:**`). When the model rephrases sections, dates anchor "do not invent". | `skill-templates.md:68` has placeholder `(None yet — file new lessons here as they are discovered, with date prefix.)`. No anchored examples. |
| **Skill-specific specificity** | `ltl.md:73` lists exact test commands, exact file paths, exact branch protection check name. Concrete enough that "model invents detail" failure mode can't happen. | `skill-templates.md:48-58` describes responsibilities at the abstraction level of "checks that templates produce correct output across all 12 managed repos" — invites paraphrase. |

**The structural pattern that works**: one heading per skill + tables matching the template's expected shape + dated, concrete examples. Defects appear when customizations under-specify the structure of fields the template wants to insert.

## Section Ratings

| Area | Rating | Justification |
|---|---|---|
| deploy.sh customizer logic | 3.5/5 | Solid retry logic (`:309-347`), permanent/transient error split (`:326-333`), bash 3.2-compatible (`:54-58`), good failure tracking. Loses points for: no post-deploy validation, no schema check, no model-output sanity tests. The plumbing is fine; the missing layer is verification. |
| System prompt clarity | 2.5/5 | Seven rules at `deploy.sh:264-275`. Rule 3 ("preserve EXACTLY as-is") conflicts with rule 1 ("replace markers from notes") at the boundary where a code block contains a value that should be customized (the `--label` case in defect 3). No explicit rule "do not invent file:line references" — Haiku is free to write `deploy.sh:47` as an example bug if the customization mentions deploy.sh. No rule "do not add fields beyond what the customization provides" — explains the nickname hallucination. |
| Customization file structure (skill-templates.md) | 2/5 | Sparse, prose-heavy, four skills jammed under one heading, agent definitions in bullet form instead of tables. Structurally weaker than the good files (chroxy.md, ltl.md). Direct cause of defects 1 & 2 from PR #17. |
| Generic template marker design | 2.5/5 | `{{CUSTOMIZE: free English prose}}` is easy to write but provides zero schema. No way to express "this insertion point is a table row with these columns" or "this insertion is optional". When-to-Include rules and Selection Algorithm are two parallel surfaces that drift independently (defect 2 from PR #17). Markers in code blocks vs prose are indistinguishable to the linter. |
| Post-deploy validation (none currently) | 0.5/5 | Nothing. No `grep` check, no schema check, no line-number cross-ref. Defects 1, 3, 4 from PR #17 are all detectable with one-line validators that don't exist. This is the single biggest gap. |

## Recommended Action Plan

Ordered by impact-per-hour. Items 1-3 are minimum viable; 4-5 are nice-to-have once the foundation lands.

1. **Add `validate_output()` to deploy.sh** — File: `deploy.sh`, between `:409` (after `call_claude` success) and `:418` (before `deploy_local`). Five regex checks: residual `{{CUSTOMIZE`, attribution strings, hardcoded `--label "..."` patterns when the source template has dynamic-label logic, `<file>:<line>` references whose line number exceeds `wc -l <file>`, and "skip missing labels" prose appearing alongside a contradicting hardcoded label literal. Fail the deploy on any check, log to FAILURES array. **Why**: catches defects 1, 3, 4 from PR #17 directly. **Effort**: M (2-3h)

2. **Restructure `customizations/skill-templates.md`** — File: `customizations/skill-templates.md`, lines 48-58. Split the merged "swarm-audit / project-audit / recon / bug-hunt" heading into per-skill sections. Convert the bullet-list agent definitions into proper markdown tables matching the columns in the generic templates' Extended Roster (`| Agent | Nickname | Lens | When to Include |`). Add explicit nicknames so Haiku doesn't invent them. **Why**: addresses the structural root cause of defect 2 (hallucinated nicknames). **Effort**: S (45 min)

3. **Collapse Selection Algorithm to a table walk** — Files: `generic/bug-hunt.md:73-82`, `generic/recon.md:66-74`. Replace the imperative "if X add Y" listings with one generic rule: "For each remaining slot, include any extended agent whose When-to-Include condition matches the target". This eliminates the parallel-rule-source drift (defect 4 pattern). **Why**: kills an entire class of cross-section inconsistency. **Effort**: S (1h)

4. **Add explicit anti-hallucination rules to the system prompt** — File: `deploy.sh:264-275`. Add: "8. Never invent file:line references. Only cite lines that appear in the actual customization notes or the template itself. 9. Never invent fields not present in the customization notes — if a table column has no source data, leave the cell empty or omit the row." **Why**: defense-in-depth; even if validation catches it, prevention is cheaper than retry. **Effort**: S (15 min for the prompt edit; small risk of regressing other behaviors, so test on 2-3 known-good deploys.)

5. **Optional: define a minimal `{{CUSTOMIZE name="..." shape="table-rows" columns="..."}}` schema** — Files: `generic/*.md` markers, a new `deploy.sh` schema-validator function. Only worth doing if defects recur after items 1-4. **Why**: structural fix vs procedural fixes. **Effort**: L (4-6h to migrate 15 markers and update affected customization files)

## Verdict

This is a **guideline fix dressed as an architecture problem**. The architecture (Haiku + system prompt + markdown templates + customization markdown) is fine for this use case — 10–15 deploys per week, low-stakes content, single maintainer. The over-engineered version (schema-typed markers, JSON-shaped customizations, model-output diff against an oracle) would be wildly disproportionate.

What's missing is **boring procedural hardening**: a 20-line `validate_output` function and a structurally consistent customization file format. Both items 1 and 2 are <3 hours combined and would have caught every defect in PR #17. The structural marker schema (item 5) is over-engineering until a fifth defect appears that the validators can't catch.

The single fact that should drive prioritization: every defect from PR #17 was detectable by a string-grep against the model's output that takes <100ms to run, and the pipeline currently runs zero such greps. Fix that first; everything else is sequencing.
