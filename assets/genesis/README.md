# `assets/genesis/` — Fleet Project Genesis Standard v1

The data behind `/project-genesis`. `assets/scripts/genesis-verify.py` renders it into a
plan for a new repo (`--plan`) and probes an existing repo against it (verify mode), so
the plan and the audit read one source.

| File | What it is |
|---|---|
| `standard-v1.json` | The machine-read standard: layers (core, stack overlays, modules), every rule ID classed `probe` or `advisory`, the skill install set and deferred triggers, the GitHub settings, and the issues genesis files. |
| `templates/` | The files rendered into a new repo, grouped by layer. Every file ends in `.tmpl`, so nothing here acts as a live `.gitignore`, `.gitattributes` or nested `CLAUDE.md` inside this registry. `*.fragment.tmpl` files are spliced into a core template rather than written on their own. |
| `ruleset-main.json` | The `POST repos/{owner}/{repo}/rulesets` body: `ci-gate` required (Actions app 15368, strict), squash only, Copilot review at PR open only, and `bypass_actors: []`. |
| `labels.json` | The 21 seed labels, with colours and descriptions. |

## Placeholders

Templates use `@@KEY@@`, which cannot collide with the `${{ }}` of GitHub Actions or the
`$VAR` of shell. Every key is declared in `standard-v1.json`'s `placeholders`. The renderer
refuses an undeclared key, and a rendered file never keeps one. A line made only of
placeholders that render empty is dropped, so an absent overlay leaves no gap.

## Rules and probes

Every rule is either classed `probe`, in which case `genesis-verify.py` has a function
registered under exactly that ID, or classed `advisory` and explained. `--self-check` (a CI
step in `validate-registry.yml`) fails on a probe-class rule with no probe, a probe with no
rule, an orphan or missing template, an undeclared placeholder, or a template action that
is not pinned to a full SHA. `genesis-verify.test.sh` holds a mutation that turns each
probed rule FAIL, and fails when a rule has none.

Probes are structural. The headings, ignore lines and job graph a repo must have are read
from the same rendered templates the plan wrote, never from a second hard-coded list.

## What v1 implements

- **Core**, the `kotlin` overlay, and the `runner-mac`, `repo-memory`, `repo-relay` and
  `credits` modules.
- **Declared but `planned`:**
  - the other overlays and modules the standard names;
  - `--visibility public`, whose bundle is LICENSE, SECURITY.md and fork-PR hardening.

  `--plan` refuses a planned layer by name instead of rendering values nobody has
  grounded.

To add a layer, set its `status` to `implemented` and give it templates, rules, probes and
mutations in the same PR. The self-check and the coverage check fail until all four exist.
