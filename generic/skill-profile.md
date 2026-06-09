# /skill-profile

Generate or refresh this repo's `.claude/skill-profile.md` — the self-description the `/skill` client reads to tailor generic skill templates for *this* repo at install time. Run it once when a repo starts using skills (and again after conventions change) so every `skill add` / `skill update` customizes sharply and deterministically instead of re-inferring the repo from scratch each time.

This skill **writes** the profile; `/skill` **reads** it. The profile is optional — without it, installs still work by inferring from `CLAUDE.md` and the layout — but a profile makes them sharper, more consistent, and cheaper.

## Arguments

- `$ARGUMENTS` — optional:
  - `--check` — report how the profile would change vs the current repo state (drift), but write nothing.
  - `--print` — print the composed profile to stdout instead of writing the file.
  - With no argument, write/update `.claude/skill-profile.md` in place.

## Instructions

### 1. Read the current state

- Read `.claude/skill-profile.md` if it exists (you are refreshing, not blindly overwriting — preserve hand-written nuance that's still accurate).
- List `.claude/commands/*.md` to see which skills this repo uses — the profile carries a tailoring section for the ones that need repo-specific values. (Installed copies have already had their `{{CUSTOMIZE}}` markers filled in at install time; the *registry templates* are where you read what each skill needs — see step 2.)

### 2. Gather repo facts (real values only)

Discover, don't assume. Pull from the repo itself:

- **Tech / build system** — from the manifest (`package.json` / `Cargo.toml` / `go.mod` / `pyproject.toml` / …) and `CLAUDE.md`.
- **Repo + branch** — `gh repo view --json nameWithOwner,defaultBranchRef` (or `git remote`).
- **CI / required checks** — `.github/workflows/*` and, if available, `gh api repos/{owner}/{repo}/branches/{main}/protection`. If there are none, record "none — build is the gate".
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

## <skill-name> Customizations
<Exactly what that skill's customization markers need — persona, labels, review
criteria, audit focus, required-check names, publish footguns, etc. Head each
section with the skill's exact name + the literal " Customizations" suffix.>
```

### 4. Rules (match the registry's profile contract)

- **Use real values, never invent.** No label set, test command, or persona for a spot? Omit it — at install time the agent drops the corresponding marker rather than fabricate a value. Placeholder *shapes* (`scope`, `path/to/file:<line>`) are fine; fabricated specifics are not.
- **One section per skill that needs it**, headed `## <skill-name> Customizations` (exact skill name + literal ` Customizations`). Skills with no repo-specific needs get no section — they just use the generic template.
- **No secrets.** The profile is committed. Keys, tokens, OTP secrets never go here (a publish footgun like "OTP is interactive, don't retry" is fine — a *value* is not).
- **Capture hard-won footguns.** If a skill has bitten this repo before (a release OTP quirk, a native-module/runtime constraint, a lint-vs-typecheck gap), record it in that skill's section — that is the highest-value content a profile carries.
- **Keep it tight.** The profile is read on every install; favor specifics over prose.

### 5. Write / report

- Default: write `.claude/skill-profile.md` (create `.claude/` if needed).
- `--check`: report the diff vs the existing profile (added/changed/removed sections) and exit without writing.
- `--print`: print the composed profile; write nothing.

### 6. Report to the user

State: the sections written, which installed skills got a `Customizations` section (and which were left to the generic template), and anything deliberately omitted for lack of a real value. If a profile already existed, summarize what changed.

## Notes

- **Run after `skill add`s settle.** The profile is most useful once a repo has installed the skills it uses — then the per-skill sections target real markers. Re-run after installing new skills or changing conventions.
- **`profileHash`.** `/skill` records the profile's hash in `.claude/skills.lock`; `skill outdated` flags skills tailored against an older profile, so refreshing the profile and running `skill update` re-tailors them. Updating the profile is how you push a convention change out to every installed skill.
- **Idempotent.** Re-running reproduces the same profile from the same repo state; it only changes when the repo does.
