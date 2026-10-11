# Install one root for every provider

`assets/AGENTS.md` is the authored registry root. Install it at `~/.fleet/AGENTS.md`;
Claude imports it through `assets/global-CLAUDE.md`, while Codex and Gemini receive
copies. The copies are adapters, not separate authored rule sets. Machine-only
private instructions stay on the machine. Historical explanations are in
[rationale.md](rationale.md).

## Machine bootstrap

Bootstrap and fleet-check require Python 3.11+ for complete TOML validation. On macOS, use `python3.12` explicitly if `python3 --version` reports an older system Python. Run from a reviewed
registry checkout. The command previews all writes by default:

```bash
python3 assets/scripts/fleet-bootstrap.py
```

For an existing machine, reconcile its defaults before passing `--replace-existing`.
Provide reviewed local additions with `--local-rules /absolute/path/to/private-rules.md`;
they become a separate default block in the machine root and its copies. Preserve
Claude-only additions with `--claude-extra /absolute/path/to/claude-only.md`.
Never commit those files. The tool backs up every changed incumbent under
`~/.fleet/backups/` before replacing any file and preserves unrelated TOML settings.
It does not change model defaults. Read the printed file list before applying:

```bash
python3 assets/scripts/fleet-bootstrap.py --replace-existing --apply
```

This stages the root and Codex/Gemini copies, sets Codex's top-level
`project_doc_max_bytes` to at least 65536, and installs fleet-check/session-seed.
It deliberately leaves the current Claude file intact. Before replacing that file,
prove a fresh live Claude session loaded an import of `@~/.fleet/AGENTS.md`.
Record the exact loaded path and the five floor IDs from that session; a static
check or an unauthenticated CLI is not proof. Then repeat the reviewed command with
`--claude-import-verified`. That option records the operator's acknowledgment; the
installer does not itself run a provider or certify its output. Include the same
local additions on both runs. Replacement refuses to remove machine-only blocks unless
`--discard-local` explicitly authorizes discarding them. Tagged local blocks are retained
verbatim; untagged additions become the reserved private `machine-local` block.
The reserved block is reported as INFO by fleet-check, excluded from drift counts and
publication advice. Never move it into the registry.

Use `--home /temporary/home` to rehearse without touching the live machine.
Nonempty Codex `AGENTS.override.md` and symlink destinations refuse installation:
reconcile them explicitly first. Copies remain the portable default even if a
particular Codex build follows symlinks. Other active profiles or custom provider
homes require a corresponding explicit installation and verification.

After publication and installation:

```bash
python3 ~/.claude/scripts/fleet-check.py --project-dir /absolute/path/to/project
```

A fresh fetch is mandatory. Exit **0** means floors agree; default differences are
informational. Exit **1** means floor drift. Exit **2** means the checker could not
honestly verify inputs, adapters, config or the size bound. It is never agreement.
The size check includes the machine file, the selected project chain, and Codex’s
23-byte separator between loaded files. A margin below 2,048 bytes exits 2.
Use `--all-repos` to check every checkout under `~/Projects/` with an `AGENTS.md`,
along with the selected session directory. `AGENTS.override.md`, nested rules and configured fallback names matter.
Run it from the actual session directory, not just the repository root.

The bootstrap preserves each incumbent’s file mode, or the source mode for a new
file. To preview restoring a backup, run
`python3 assets/scripts/fleet-bootstrap.py --restore /absolute/backup/directory`;
add `--apply` after reviewing its target paths. The backup’s `paths.txt` identifies
the original targets. Restore preflights all backup files and destinations, then
restores their bytes and modes. It does not infer missing files or defaults.

This is a static check of the supported default configuration, not a runtime loading
certificate. It refuses custom Codex root markers/profiles and any project Codex
or Gemini settings layer with exit 2 rather than guessing trust-dependent precedence.
Gemini machine settings (system defaults, user, system overrides) must select only
GEMINI.md; an alternative or additional filename requires a separate migration.
Invocation flags, extension instructions and injected host configuration need a fresh
session smoke test; do not treat this check as proof of those runtime settings.

## Repository migration recipe

1. In an isolated worktree, inventory existing project rules, nested files, imports,
   generated copies, loaders and CI checks. Record the actual loaded byte count.
2. Move the authored project contract into `AGENTS.md`, preserving all operative
   rules. Replace `CLAUDE.md` with `@AGENTS.md` and genuinely Claude-only additions.
   Configure Gemini to load AGENTS.md or use its documented import mechanism;
   verify with a fresh session. Do not assume all hosts load files the same way.
3. Retire the old generator and drift check in the same PR. Replace their coverage
   with adapter/source checks and a size check; keep required CI green.
4. Start fresh sessions in each supported host. Ask for actual loaded rule paths and
   all five floor IDs. Check answers against the files and record the evidence.
   A process unable to authenticate is unverified, not a passing smoke test.
5. Run product smoke checks and the repository's review/merge gates. Land each
   repository separately; refresh installed skills through `skill update`.

A provider that does not read instruction files needs a tested compilation adapter;
a provider that already reads them must not receive duplicate copies. Verify host
behavior before changing that boundary. Genesis template/source inversion is a
separate migration; the current verifier reads floor IDs from the new root while
retaining the old path for historical pins.

## Verification sources

- [Codex instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
  documents root-to-directory discovery and the default 32 KiB bound.
- [Claude imports](https://code.claude.com/docs/en/memory#import-additional-files)
  documents home imports, launch-time expansion and the four-hop limit.
- [Gemini context files](https://geminicli.com/docs/cli/gemini-md/)
  documents hierarchical context and filename configuration.

Documented support is the starting point. Runtime parity is established by the
fresh-session evidence, not by the documentation alone.
