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
- **No secrets.** Profiles are committed to the repo. Keys and tokens never go here.
- **Keep it current.** When conventions change (a new required check, a renamed scope),
  update the profile so future `skill add` / `skill update` installs stay accurate.

## Migration from `customizations/<repo>.md`

The registry's `customizations/<repo>.md` files map 1:1 onto this schema (same sections).
Migrating a repo means copying its `customizations/<repo>.md` to `<repo>/.claude/skill-profile.md`
(adjusting the H1 to `# <repo> skill profile`) and folding any `values/<repo>.values`
deterministic overrides into the relevant skill sections. Tracked by #70.
