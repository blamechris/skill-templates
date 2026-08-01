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
│   └── skill-lint.sh            # mechanical gate: residual markers, attribution, version stamp, guards, self-merge posture
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
  or CI — note its three outcomes: **0** clean, **1** real findings, **2** not fully
  verifiable. A repo-only skill (kept in `.claude/commands/` and absent from the index)
  legitimately exits **2** — but only if it is *unstamped*. A **stamped** file the index
  does not know is a stale clone, a renamed/retired skill, a typo'd name or the wrong
  registry, and exits **1**; the linter draws that line itself, so the hook is just:

  ```bash
  scripts/skill-lint.sh "$name" "$file" ; rc=$?
  # `if` blocks, not `[ … ] && exit 1`: an and-list as a script's last command
  # exports the failed test's status, so the hook would exit 1 on a clean run.
  if [ "$rc" -eq 1 ]; then exit 1; fi   # findings, incl. a stamped file the index lacks
  # Exit 2 on a stamped file can now only mean environment breakage — a missing or
  # wrong-path registry, no python3, an unreadable file. Still a failure for a hook.
  if [ "$rc" -eq 2 ] && grep -q '^<!-- skill-templates: ' "$file"; then exit 1; fi
  ```

  Key on the exit code, not the output markers — `ERROR:` also appears on exit 1, and a
  usage error exits 2 printing none. Full guidance in `generic/skill.md` step 6.

  The linter also checks one thing that is **not** per-file: for `autonomous-dev-flow` and
  `tackle-issues` it compares the installed Critical Rule 5 against the self-merge posture the
  repo pins in `.claude/skill-profile.md`, and reports a contradiction as a finding. The profile
  is found automatically for a file at `<root>/.claude/commands/<name>.md`; pass it as an optional
  4th argument when linting a copy staged elsewhere. A repo that pins no posture — most of them —
  is unaffected: absence is never a finding. This closes a gap the `self-merge-posture` guard
  cannot (#172): that guard is `anyOf: [<gated>, <withheld>, …]` on purpose, so it fires when
  Rule 5 is *deleted* but passes either posture, leaving a withheld → gated flip invisible to
  every mechanical check.
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
