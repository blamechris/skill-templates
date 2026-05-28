# skill-templates Skill Customizations

## Project Context
- **Tech:** Bash (deploy.sh, sync.sh), GitHub Actions workflows, Markdown templates
- **Repo:** blamechris/skill-templates
- **Main branch:** main
- **CI:** Self-hosted runner triggers `deploy.sh --changed-templates` and `--changed-customs` on push to main, which opens PRs in every managed repo whose skills changed
- **Special:** This repo *is* the source of truth for all other repos' skills. Edits here are propagated automatically — be deliberate.

## Attribution Policy
This repo follows the user's project-wide **zero-attribution** policy. NEVER add `Co-Authored-By: Claude` or `Generated with Claude` to commits, PRs, or any output. See CLAUDE.md.

## Bash Compatibility
- macOS ships bash 3.2. **No associative arrays** (`declare -A`) — use parallel indexed arrays.
- For large heredocs, prefer `read -r -d '' var <<'DELIM' || true` over `var=$(cat <<'DELIM' ... DELIM)`.
- See `.claude/rules/bash-compat.md` for the codified rules.

## GitHub Actions Self-Hosted Runner
- `gh` CLI has no auth session in the runner — always `export GH_TOKEN` from the deploy PAT before any `gh pr`/`gh issue` call.
- Workflow `if:` conditions compare step outputs as strings — use `!= '0'` not `> 0` for numeric-like comparisons.
- See `.claude/rules/gh-actions.md`.

## check-pr Customizations
- This is a low-traffic repo for human review — Copilot review polling is *optional*. Skip the Step 0 wait if no Copilot review is configured.
- Issue labels: `enhancement`, `from-review`, `bug` (verify with `gh label list` before using).
- Reply headers: **FIX** / **FALSE POSITIVE** / **FOLLOW-UP ISSUE**.

## agent-review Customizations

### Persona
**Template Reviewer** — expert in Claude Code skill design, Bash 3.2 portability, GitHub Actions on self-hosted runners, and the `{{CUSTOMIZE: ...}}` substitution model used by `deploy.sh`.

Mindset: *"Will this template still produce correct customized output when Haiku fills in the `{{CUSTOMIZE}}` markers from a sparse customization file? Will the deployed skill work in every managed repo?"*

### Code Quality — Templates
- Each generic template must have clear `{{CUSTOMIZE: ...}}` markers that describe what content is needed.
- Markers without corresponding content in customization files will be stripped by deploy.sh — that's the intended behavior, but check that the resulting skill still reads well.
- Skill files: `# /skill-name` header, `## Arguments`, `## Instructions` numbered sections, `## Configuration` block, `## Examples` block at end.
- No emojis unless the user explicitly requests.
- Avoid attribution footers in any sample commit messages inside templates.

### Code Quality — deploy.sh / sync.sh
- Bash 3.2 compatible — no associative arrays.
- Set `-euo pipefail`.
- Read config from `deploy.conf` (single source of truth — never duplicate the mapping).
- Always quote variable expansions.

## swarm-audit Customizations

### Domain-Specific Extended Agents

| Agent | Nickname | Lens | When to Include |
|-------|----------|------|-----------------|
| Template Critic | "Auditor" | Generic template structure, `{{CUSTOMIZE: ...}}` marker hygiene, customization file coverage, deployed skill correctness across the 12 managed repos with varied tech stacks | Target includes `generic/*.md` files or `deploy.sh` / `sync.sh` |
| Deploy Pathologist | "Deployer" | `deploy.sh` / `sync.sh` failure modes, missing customization files, Haiku API errors, GH Actions runner auth, bash 3.2 incompatibilities | Target includes `deploy.sh`, `sync.sh`, or `deploy.conf` |

### Grading Criteria
- Auditor should weight whether deployed output still reads as a coherent skill after `{{CUSTOMIZE}}` substitution
- Deployer should weight self-hosted-runner-specific gotchas (no inherited `gh` auth, macOS launchd OnDemand culling)

## project-audit Customizations

### Domain-Specific Extended Agents

| Agent | Nickname | Lens | When to Include |
|-------|----------|------|-----------------|
| Template Critic | "Auditor" | Generic template structure, `{{CUSTOMIZE: ...}}` marker hygiene, customization file coverage, deployed skill correctness across the 12 managed repos with varied tech stacks | Auto-include — this is the project's primary surface |
| Deploy Pathologist | "Deployer" | `deploy.sh` / `sync.sh` failure modes, missing customization files, Haiku API errors, GH Actions runner auth, bash 3.2 incompatibilities | Auto-include — this is the deploy path's primary surface |

## recon Customizations

### Domain-Specific Extended Scouts

| Scout | Nickname | Lens | When to Include |
|-------|----------|------|-----------------|
| Template Critic | "Auditor" | Generic template structure, `{{CUSTOMIZE: ...}}` marker placement and density across `generic/*.md` files | Reconning `generic/`, `deploy.sh`, or `sync.sh` |

## bug-hunt Customizations

### Domain-Specific Extended Hunters

| Hunter | Nickname | Lens | Include When |
|--------|----------|------|--------------|
| Template Critic | "Auditor" | Generic templates that produce defective customized output (residual markers, attribution leaks, heading drift, length runaway, hallucinated examples) | Target is `generic/*.md` |
| Deploy Pathologist | "Deployer" | `deploy.sh` / `sync.sh` failure modes — missing customization files, Haiku API errors (4xx, 5xx, 529 overload), GH Actions runner offline, bash 3.2 incompatibilities, FETCH_HEAD vs local-branch checkout bugs | Target is `deploy.sh`, `sync.sh`, or `deploy.conf` |

### Mandatory Checks
- Guardian must verify that any new `{{CUSTOMIZE: ...}}` marker added to a generic template will not let Haiku invent specifics — markers must either be closed ("copy ONLY X from notes") or substitution-shaped (named field). Open-ended "Add X if relevant" markers are the documented defect class (see `docs/audit-results/customization-pipeline`).

## create-issue Customizations
- Default labels: `enhancement` for features, `bug` for defects, `from-review` if review-sourced, `from-bug-hunt` if from `/bug-hunt`.
- This repo doesn't use complexity labels — skip them.

## decompose-issue Customizations
- Default sub-issue labels: `enhancement` only. No `complexity:*` labels in this repo.
- Parent-link convention: rely on the body line "Part of #N" — no `parent:#N` label scheme.
- Parent-marker label: none (this repo doesn't use `decomposed` / `epic`). Skip that step.
- Sub-issue scope hints: most decomposition here splits across `generic/<skill>.md`, `customizations/<repo>.md`, and `deploy.sh` / `sync.sh` — name the files concretely in the proposed sub-issue table.

## tackle-issues Customizations
- This is a low-velocity meta-repo. Marathons are unusual. Most changes are surgical edits to a single template plus a customization-file note.
- Always re-run `./sync.sh` after deploying a skill change to verify drift is resolved.

## autonomous-dev-flow Customizations
- Branch prefix: `feat/` for features, `fix/` for bug fixes, `chore/` for routine maintenance, `docs/` for documentation-only.
- Test runner: `bash -n` for shell-syntax smoke tests on `deploy.sh` / `sync.sh`. No formal test framework — manual verification via `./deploy.sh --dry-run` and `./sync.sh` is the established pattern.
- Commit scopes: `(deploy)`, `(sync)`, `(generic)`, `(customizations)`, `(workflow)`, `(docs)`.

## Lessons Learned
- **2026-05-19:** First substantive customization written. PR #17 produced 4 Copilot-caught defects (a hallucinated `deploy.sh:<line>` bug example, inconsistent rules, hardcoded labels, cross-section drift). Root cause traced via `/swarm-audit` to the customization-pipeline design — see `docs/audit-results/customization-pipeline/`. Phase 1 hardening landed in PR (this commit's branch).
