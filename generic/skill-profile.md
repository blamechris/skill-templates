# /skill-profile

Generate or refresh this repo's `.claude/skill-profile.md` — the self-description the `/skill` client reads to tailor generic skill templates for *this* repo at install time. Run it once when a repo starts using skills (and again after conventions change) so every `skill add` / `skill update` customizes sharply and deterministically instead of re-inferring the repo from scratch each time.

This skill **writes** the profile; `/skill` **reads** it. The profile is optional — without it, installs still work by inferring from `CLAUDE.md` and the layout — but a profile makes them sharper, more consistent, and cheaper.

## Arguments

- `$ARGUMENTS` — optional:
  - `--check` — report how the profile would change vs the current repo state (drift), but write nothing.
  - `--print` — print the composed profile to stdout instead of writing the file.
  - `--planned "<skill list>" [--plan <plan.json>]` — compose the profile for skills that are **about to be installed**, before the first `skill add` (see "Planned mode" below). `/project-genesis` runs this in its Phase 4 with the genesis plan. Combines with `--print` and `--check`.
  - With no argument, write/update `.claude/skill-profile.md` in place.

## Instructions

### 1. Read the current state

- Read `.claude/skill-profile.md` if it exists (you are refreshing, not blindly overwriting — preserve hand-written nuance that's still accurate).
- List `.claude/commands/*.md` to see which skills this repo uses — the profile carries a tailoring section for the ones that need repo-specific values. (Installed copies have already had their `{{CUSTOMIZE}}` markers filled in at install time; the *registry templates* are where you read what each skill needs — see step 2.)

### 2. Gather repo facts (real values only)

Discover, don't assume. Pull from the repo itself:

- **Tech / build system** — from the manifest (`package.json` / `Cargo.toml` / `go.mod` / `pyproject.toml` / …) and `CLAUDE.md`.
- **Repo + branch** — `gh repo view --json nameWithOwner,defaultBranchRef` (or `git remote`).
- **CI / required checks** — `.github/workflows/*`, the repo's rulesets (`gh api repos/{owner}/{repo}/rulesets`, then each ruleset's `required_status_checks`), and classic protection (`gh api repos/{owner}/{repo}/branches/{main}/protection`), which 404s on a ruleset-only repo. If there are none, record "none — build is the gate".
- **Build / test / lint commands** — the manifest's scripts and `CLAUDE.md`. Capture the *exact* commands.
- **Conventions** — branch naming, commit style + scope list, source-file globs — from `CLAUDE.md` and recent `git log`.
- **Hard requirements / invariants** — non-negotiables from `CLAUDE.md` (e.g. "never return stale data", "ESM only", a zero-attribution policy).
- **Labels** — `gh label list` (for skills that file issues). Record the real label families; never invent.
- **Per-skill needs** — for each skill this repo uses, read its **registry template** (`generic/<name>.md` in the resolved registry — see `/skill`'s "Resolving the registry") to learn what its `{{CUSTOMIZE}}` markers ask for (persona, review criteria, audit focus, required-check names, test conventions, label scheme, publish footguns, …). The installed `.claude/commands/<name>.md` has already had its markers filled, so the **template** is the source of truth for what needs a value — then decide whether this repo has a real, specific one.

### 3. Compose the profile

Write markdown in this structure (the schema `/skill` expects). The first three sections are repo-wide; then one `## <skill-name> Customizations` section per installed skill that genuinely needs more than the generic template.

```markdown
# <repo> skill profile

## Project Context
- Tech: <languages, frameworks, platform>
- Build system: <how it builds>
- Repo: <owner/name>
- Main branch: <main>
- CI: <required checks, or "none — build is the gate">
- Status: <one line>
- Hard requirements (never regress): <invariants>

## Build / Test Commands
- Build (the gate): <exact command>
- Test: <exact command, or "no test target yet">
- Lint/typecheck: <command, or how it's covered>

## Conventions
- Branch prefix / naming: <e.g. auto/<number>-<slug>>
- Commit style + scopes: <conventional commits; scope list>
- Source file patterns: <globs the skills should target>

## Skill Targets
targets: <comma-separated agents this repo drives — e.g. claude, gemini, codex>

## <skill-name> Customizations
<Exactly what that skill's customization markers need — persona, labels, review
criteria, audit focus, required-check names, publish footguns, etc. Head each
section with the skill's exact name + the literal " Customizations" suffix.>
```

The `targets:` line drives `compile-skill-targets.mjs` (`claude` → `.claude/skills/<name>/SKILL.md`, `gemini` → `.gemini/commands/<name>.toml`, `codex` → `.codex/skills/<name>/SKILL.md`). All three emit version-controlled, repo-tracked artifacts, so any combination is safe to commit.

### 4. Rules (match the registry's profile contract)

- **Use real values, never invent.** No label set, test command, or persona for a spot? Omit it — at install time the agent drops the corresponding marker rather than fabricate a value. Placeholder *shapes* (`scope`, `path/to/file:<line>`) are fine; fabricated specifics are not.
- **Decisions are kept, not re-inferred.** A refresh keeps every `### Self-merge posture` block, the `## project-genesis Customizations` section, and any section for a skill that is pinned but not yet installed (a merge strategy for `unattended-merge`, say) verbatim. They record owner decisions that the repo's files cannot re-derive.
- **One section per skill that needs it**, headed `## <skill-name> Customizations` (exact skill name + literal ` Customizations`). Skills with no repo-specific needs get no section — they just use the generic template.
- **No secrets.** The profile is committed. Keys, tokens, OTP secrets never go here (a publish footgun like "OTP is interactive, don't retry" is fine — a *value* is not).
- **Capture hard-won footguns.** If a skill has bitten this repo before (a release OTP quirk, a native-module/runtime constraint, a lint-vs-typecheck gap), record it in that skill's section — that is the highest-value content a profile carries.
- **Keep it tight.** The profile is read on every install; favor specifics over prose.
- **Targets are version-controlled.** Every agent in `targets:` emits a repo-tracked artifact (`claude` → `.claude/skills/`, `gemini` → `.gemini/commands/`, `codex` → `.codex/skills/`) — list exactly the agents this repo drives. Codex users on machines without repo-local discovery copy/sync `.codex/skills/<name>` into `~/.codex/skills`.

### Planned mode (`--planned`)

A profile written *after* installs arrives too late for the pins that matter most: a posture-pinned skill installed with no pin installs **gated**, and every install records the profile's hash, so a profile written afterwards shows as profile drift on every skill. Planned mode composes the profile first.

1. **The skill set is the given list**, not `.claude/commands/`. Refuse any name that is not in the registry's `registry.json`. Step 2's per-skill template reading is unchanged.
2. **With `--plan <plan.json>`** (the output of `genesis-verify.py --plan --json`), compose exactly the text below, in this order. Put one blank line between sections and end the file with a newline. Every value is read from the plan or from `gh`, and none is typed, so the same plan always composes the same bytes:
   ```markdown
   # <.intent.name> skill profile

   ## Project Context
   - Tech: <.intent.overlays joined ", ", or "undecided"> — see SPEC
   - Repo: <.intent.repo>
   - Main branch: <gh repo view --json defaultBranchRef -q .defaultBranchRef.name>
   - CI: <the required_status_checks contexts in .github.ruleset, joined ", ">

   ## Build / Test Commands
   <.profile.build_commands, one per line>

   ## Conventions
   <the bullets of the rendered CLAUDE.md's "## Git workflow" section (the .files entry for CLAUDE.md), verbatim>

   ## Skill Targets
   targets: <.profile.targets>

   ## create-issue Customizations
   - Labels: <.profile.labels joined ", ">

   ## <each skill in .profile.posture_sections> Customizations

   ### Self-merge posture

   <the posture line below for .profile.posture>

   ## <each skill in .profile.merge_sections> Customizations
   - Merge strategy: <.profile.merge_strategy>

   <.profile.section, verbatim>
   ```
   The posture line is fixed text, one per posture:
   - `**Withheld.** Every merge in this repo is a human act: PRs accumulate for the owner however clean the review and checks are. Set by /project-genesis; flip it by editing both pins.`
   - `**Gated.** An autonomous session may merge its own PR once every Unattended Merge Gate condition is met. Set by /project-genesis; flip it by editing both pins.`
3. **Without `--plan`,** gather the repo facts as in step 2 for the listed skills. The self-merge posture is written only when the owner states it: **in planned mode the posture comes from the plan or the owner, never from this skill.** Report that an unpinned posture skill will install gated.
4. **A re-run writes nothing new, and never overwrites a decision.**
   - If the composed file is byte-identical to the existing one, write nothing, so a genesis resume leaves every lock's profile hash where it was.
   - REFUSE and write nothing when an existing `### Self-merge posture` pin disagrees with the plan's posture. A posture flip is the owner's edit, never a re-plan's.
   - REFUSE and write nothing when the existing `## project-genesis Customizations` records an overlay or module that the plan's intent lacks. A re-plan may add a layer, which is `/project-genesis --add`, but never drop one.
   - Keep any existing section for a skill outside the list, in its original order, after the composed sections.

### 5. Write / report

- Default: write `.claude/skill-profile.md` (create `.claude/` if needed).
- `--check`: report the diff vs the existing profile (added/changed/removed sections) and exit without writing.
- `--print`: print the composed profile; write nothing.

### 6. Report to the user

State: the sections written, which installed skills got a `Customizations` section (and which were left to the generic template), and anything deliberately omitted for lack of a real value. If a profile already existed, summarize what changed.

## Notes

- **Run after `skill add`s settle** — except in planned mode, which exists to run *before* them. The profile is most useful once a repo has installed the skills it uses — then the per-skill sections target real markers. Re-run after installing new skills or changing conventions.
- **`profileHash`.** `/skill` records the profile's hash in `.claude/skills.lock`; `skill outdated` flags skills tailored against an older profile, so refreshing the profile and running `skill update` re-tailors them. Updating the profile is how you push a convention change out to every installed skill.
- **Idempotent.** Re-running reproduces the same profile from the same repo state; it only changes when the repo does.
