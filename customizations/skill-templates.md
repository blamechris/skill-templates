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

Mindset: *"Will this template still produce correct customized output when Haiku fills in the {{CUSTOMIZE}} markers from a sparse customization file? Will the deployed skill work in every managed repo?"*

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

## swarm-audit / project-audit / recon / bug-hunt Customizations

### Domain Agents
For audits and recon of this repo, useful extra agents:
- **TemplateCritic** — checks that generic templates produce correct deployed skills across all 12 managed repos with their varied tech stacks (Node, Tauri, Godot, Kotlin, Bash, etc.).
- **DeployPathologist** — focuses on deploy.sh/sync.sh failure modes (missing customization files, Haiku API errors, GH Actions auth, bash 3.2 incompatibilities).

### Hotspot Guidance
- High-churn: `generic/*.md` (every skill template). Templates that change often: `check-pr`, `agent-review`, `tackle-issues`.
- Critical path: `deploy.sh` (any bug here breaks deploys to all 12 repos at once).

## create-issue / bug-hunt Customizations
- Default labels: `enhancement` or `bug`, `from-review` if review-sourced, `from-bug-hunt` if from bug-hunt.
- This repo doesn't use complexity labels — skip them.

## tackle-issues / autonomous-dev-flow Customizations
- This is a low-velocity meta-repo. Marathons are unusual. Most changes are surgical edits to a single template plus a customization-file note.
- Always re-run `./sync.sh` after deploying a skill change to verify drift is resolved.

## Lessons Learned
- (None yet — file new lessons here as they are discovered, with date prefix.)
