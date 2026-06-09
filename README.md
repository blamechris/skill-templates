# skill-templates

A **registry** of reusable Claude Code skills — `npm`/`brew` for `.claude/commands/*.md`.
It is the canonical source of truth for review workflows, PR processes, and development
skills used across all managed repos.

Skills are **not** pushed out. Repos install them **on demand** via the `/skill` client,
and the invoking agent customizes each template inline for its repo. There is no central
fan-out, no deploy step, and no API key in this repo.

> **License: all rights reserved.** This repo is public for visibility only — it is not
> open source. No permission to use, copy, or adapt these skills is granted by its
> availability. See [NOTICE](./NOTICE); contact [@blamechris](https://github.com/blamechris)
> to request use.

## Layout

```
skill-templates/
├── generic/                     # Skill templates (repo-agnostic, with {{CUSTOMIZE: ...}} markers)
│   └── skill.md                 # the /skill client itself
├── registry.json                # generated index: skill → template hash, description, guards
├── skill-guards.json            # per-skill content guards (load-bearing markers)
├── scripts/
│   ├── build-index.sh           # regenerates registry.json from generic/ + skill-guards.json
│   └── skill-lint.sh            # mechanical gate: residual markers, attribution, version stamp, guards
└── docs/skill-profile-schema.md # the .claude/skill-profile.md spec
```

## Using skills (consumer side)

In any managed repo, run `/skill`:

- **`skill add <name>`** — resolve from `registry.json` → fetch `generic/<name>.md` → the
  agent fills `{{CUSTOMIZE: ...}}` markers from the repo's `CLAUDE.md` +
  `.claude/skill-profile.md` + code → self-validate → write `.claude/commands/<name>.md`
  (version-stamped) → lint the written file with the registry clone's
  `scripts/skill-lint.sh` (a deterministic gate independent of the agent's judgment) →
  record in `.claude/skills.lock`. Consumers can run the same linter in a pre-commit hook
  or CI.
- **`skill list`** — show installed skills and their registry status.
- **`skill outdated`** — flag drift: **version** (template hash moved), **profile**
  (`.claude/skill-profile.md` changed), or **corruption** (a `guards` check fails).
- **`skill update [name]`** — re-install drifted skills.
- **`skill remove <name>`** — delete an installed skill.

**Install-on-miss is a rule, not automatic tooling:** per the global `CLAUDE.md`, if `/X`
is requested but absent from `.claude/commands/`, the agent runs `skill add X` first, then
invokes it.

### Each consuming repo carries

- **`.claude/skill-profile.md`** — the repo's customization profile (tech stack, CI commands,
  branch conventions, per-skill overrides). See [`docs/skill-profile-schema.md`](docs/skill-profile-schema.md).
- **`.claude/skills.lock`** — which skills are installed, at what template hash + profile hash.
- **`.claude/commands/*.md`** — the installed, customized skills (version-stamped).

## Maintaining the registry

1. Edit a template in `generic/`.
2. Commit.
3. Run `./scripts/build-index.sh` to refresh `registry.json` (hashes, descriptions, guards).

Consumers pick up the change on their next `skill update`. There is no deploy step.

Each installed skill carries a version stamp so drift is detectable:

```
<!-- skill-templates: <name> <hash> <date> -->
```

## History

This repo previously used a **push-deploy** model (`deploy.sh` + `deploy.conf` +
a GitHub Action that fanned out a full N-repo × M-skill re-customization on every change).
That was retired in favor of the pull-based registry — see #68 (epic) and #75 (cleanup).
Do not reintroduce a push trigger, `deploy.sh`, or `deploy.conf`.

## Attribution

The repo owner is the sole author of all work here. No `Co-Authored-By` trailers, no
"Generated with Claude" or any AI/agent attribution in commits, PRs, issues, or docs.
