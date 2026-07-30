# `.claude/skill-profile.md` — repo profile schema

A **skill profile** is a markdown file a repo keeps at `.claude/skill-profile.md`. It is
the repo's self-description: enough identity and per-skill tailoring notes for the
`/skill` client to customize a generic template for *this* repo at install time.

In the pull-based registry model the profile lives **in the consuming repo** (not
centrally in `skill-templates`). It replaces the old `customizations/<repo>.md` notes.

## How it's used

When you run `/skill add <name>`, the invoking agent reads this profile (plus the repo's
`CLAUDE.md` and the code itself) and uses it to fill the template's `{{CUSTOMIZE: …}}`
markers. The profile is **optional** — if absent, the agent infers what it can from
`CLAUDE.md` and the repo layout, and notes in its report that adding a profile would
sharpen future installs. A profile makes installs sharper and more deterministic.

## Structure

Markdown, with these sections. The first three are repo-wide; the rest are one section
per skill that needs more than the generic template provides.

```markdown
# <repo> skill profile

## Project Context
- Tech: <languages, frameworks, platform>
- Build system: <how the project builds>
- Repo: <owner/name>
- Main branch: <main>
- CI: <required checks, or "none — build is the gate">
- Status: <one line>
- Hard requirements (never regress): <invariants the repo must keep>

## Build / Test Commands
- Build (the gate): <exact command>
- Test: <exact command, or "no test target yet">
- Lint/typecheck: <command, or how it's covered>

## Conventions
- Branch prefix / naming: <e.g. auto/<number>-<slug>>
- Commit style + scopes: <conventional commits; scope list>
- Source file patterns: <globs the skills should target>

## Skill Targets
targets: <comma-separated agents this repo drives — e.g. claude, gemini>

## <skill-name> Customizations
<Anything that skill's {{CUSTOMIZE}} markers need: persona, labels, review
criteria, audit focus, required-check names, test conventions, etc. One
section per skill that needs it. Head each `## <skill-name> Customizations` —
the skill's exact name plus the literal ` Customizations` suffix.>
```

## Rules

- **Use real values, never invent.** If you don't have a label set, a test command, or a
  persona, omit it — the agent will drop the corresponding marker rather than fabricate.
  Placeholders (`scope`, `path/to/file:<line>`) are fine; fabricated specifics are not.
- **One section per skill** that needs customization, headed `## <skill-name> Customizations`
  — the skill's exact name plus the literal ` Customizations` suffix (e.g.
  `## agent-review Customizations`). Skills with no section just use the generic template.
- **Self-merge posture is a profile decision, and the profile is the only place it lives.**
  `autonomous-dev-flow` and `tackle-issues` each carry a Critical Rule 5 whose text comes from
  this profile, and every merge step in those skills defers to it. State it in the skill's
  `Customizations` section as either **gated** (an autonomous session may merge its own PR once
  every Unattended Merge Gate condition is met) or **withheld** (PRs always accumulate for user
  review, however clean):

  ```markdown
  ## autonomous-dev-flow Customizations
  Self-merge posture: withheld — every merge in this repo is a human act. PRs accumulate for
  user review no matter how clean the review and checks are.
  ```

  Omit the line and the install gets **gated**, which is the template default. Say it explicitly
  in either direction if the answer matters for the repo — an omission reads as "nobody decided",
  and the next `skill update` will quietly grant merge authority. A repo that withholds it also
  does not honour `merge:on`: an invocation flag cannot grant authority the repo withholds.
- **No secrets.** Profiles are committed to the repo. Keys and tokens never go here.
- **Keep it current.** When conventions change (a new required check, a renamed scope),
  update the profile so future `skill add` / `skill update` installs stay accurate.
- **`targets:` selects which agents a skill compiles for.** `compile-skill-targets.mjs` reads
  this line: `claude` → `.claude/skills/<name>/SKILL.md`, `gemini` → `.gemini/commands/<name>.toml`,
  `codex` → `.codex/skills/<name>/SKILL.md`, `pi` → `~/.pi/agent/skills/<name>/SKILL.md`.
  The first three emit **version-controlled, repo-tracked** artifacts, so any combination of them is
  safe to commit (codex's repo folder can be copied/synced into `~/.codex/skills` where repo-local
  discovery is unavailable). No line ⇒ the compiler falls back to `claude`.
- **`pi` is the one target that writes outside the repo**, because Pi has no repo-local skill
  discovery. Committing `pi` in `targets:` means every `skill add`/`update` in this repo writes into
  the home directory of whoever ran it — fine for a solo repo whose owner drives Pi, wrong for a
  shared one. Prefer leaving it out of the committed line and passing `--targets claude,pi` per
  machine.
  The compiler notices `~/.pi` and prints the flag to add; it never adds the target itself.

## History: migration from `customizations/<repo>.md`

Migration is **complete** (#70, #75) — every managed repo now carries its own
`.claude/skill-profile.md`, and the registry's old `customizations/<repo>.md` and
`values/<repo>.values` sources have been removed. For the record, migrating a repo meant
copying its `customizations/<repo>.md` into `<repo>/.claude/skill-profile.md` (adjusting the
H1 to `# <repo> skill profile`) and folding any `values/<repo>.values` deterministic
overrides into the relevant skill sections.
