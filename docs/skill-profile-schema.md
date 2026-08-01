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
  review, however clean).

  **The canonical form is a `### Self-merge posture` block whose first line is the bolded
  declaration**, followed by the rationale. This is what every managed repo writes, and it is
  the form `scripts/skill-lint.sh` parses:

  ```markdown
  ## autonomous-dev-flow Customizations

  ### Self-merge posture

  **Withheld.** Every merge in this repo is a human act. However clean the review and the
  checks are, PRs accumulate for the user rather than self-merging, so Critical Rule 5 must
  be written in its WITHHELD form.

  Recorded in the profile, not just in the installed skill: `.claude/commands/` is regenerated
  on every `skill update`, this file is not.
  ```

  The declaration is the block's **bold lead** — `**Withheld.**` or `**Gated.**`, on its own or
  as a list item (`- **Withheld.** …`). Everything after it is prose the linter ignores, which
  is deliberate: the rationale above names the *other* posture ("takes the template default —
  gated self-merge"), so the posture cannot be read by searching the block for the word. A
  one-line `Self-merge posture: withheld — …` inside the section is also accepted as shorthand.

  Omit the block and the install gets **gated** — the template default, and the right outcome for a
  repo that genuinely has no objection to gated self-merge. The failure mode is narrower than
  "unstated": a repo that *intends* **withheld** but never pins it in the profile gets gated back on
  its next `skill update`, silently re-enabling unattended merges that someone had deliberately
  turned off. So pin `withheld` in the profile rather than relying on the installed file's current
  wording; the file is regenerated, the profile is not. A repo that withholds it also does not honour
  `merge:on`: an invocation flag cannot grant authority the repo withholds.

  **The pin is enforced, not just recorded (#172).** `scripts/skill-lint.sh` compares the installed
  Critical Rule 5 against this block and fails (exit 1) when they contradict — naming both what the
  profile pins and what the file says. The registry's `self-merge-posture` guard cannot do this: it
  is `anyOf: [<gated wording>, <withheld wording>, …]` by design, so it fires when Rule 5 is
  *deleted* but accepts either posture, which left the withheld → gated flip passing every
  mechanical check. Declaring nothing here stays entirely unenforced — absence is not a finding.
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
