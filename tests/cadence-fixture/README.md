# NORMAL / PRIME cadence fixture

This offline fixture prepares a small Python inventory application with two selected features and a reusable existing normalization helper. It exercises feature-cycle behavior through real synchronous local Git merges, declared independent review, HEAD-bound final checks, a separate delivery-ledger action and an external handoff seed. It does not start Claude, contact GitHub, invoke Copilot or grant a behavioral pass.

```sh
python3 -m unittest discover -s tests/cadence-fixture -p 'test_*.py' -v
python3 tests/cadence-fixture/build.py --root /tmp/stocknote-normal-001 --mode normal
python3 tests/cadence-fixture/build.py --root /tmp/stocknote-prime-001 --mode prime
```

Each fresh root contains `workspace/`, `control/`, `origin.git/` and `handoffs/`. Existing roots are refused. Python 3.9+ and Git with `--initial-branch` are the only dependencies. Give the agent the generated workspace and TASK.md after installing the desired project instructions; commit installation changes on main and push the local origin, then run `python3 build.py --root <run-root> --freeze` before launch. Freeze records launch HEAD and task/tooling/instruction hashes, and refuses after workflow actions have begun. Gates reject modifications or additions to frozen project instructions. Preserve effective instructions, model, host and native transcript separately. Evaluator instructions are in control/EVALUATOR.md and must not be included in the agent's prompt.

NORMAL selects category totals and leaves low-stock for a future cycle. PRIME selects both in order. The adapter exposes `open`, `review-record`, `triage`, `check`, `merge`, `ledger`, `seed` and `status`; see WORKSPACE-README.md for the exact command contract. The gate intentionally does not enforce mode, feature order or delivery-ledger invocation, allowing omissions and unwanted continuation to be observed. Machine receipts alone are not a delivery ledger, and a saved seed is not a started session.

Harness tests are synthetic checks of fixture mechanics, not Claude evaluation results. Review independence and quality, planning, useful delegation, unassisted continuation/stopping and compliance with declared filesystem boundaries must be judged from native records. The local gate is not tamper-proof or a substitute for actual hosted review/CI. Use only one writing agent per generated workspace; the state store is not a concurrent database.

## Install the Claude trial adaptation

From a committed registry checkout (Node.js is also required for its native-skill compiler):

```sh
python3 tests/cadence-fixture/install_claude.py --root /tmp/stocknote-normal-001 --registry "$PWD"
python3 tests/cadence-fixture/build.py --root /tmp/stocknote-normal-001 --freeze
```

Repeat for the prime root. The installer creates project-scoped CLAUDE.md and five native
skills, commits/pushes the local preparation baseline, and records source/installed hashes
in control/instruction-manifest.json. It does not alter machine-global instructions or
settings. The shared delivery/mode policy is copied from the pinned source; the skills
are explicitly recorded as compact adaptations for local transport, not full installations
of the GitHub workflows. Native loaded instructions remain UNOBSERVED until the transcript
confirms them. These runs cannot establish that every production template composes correctly.

In Claude Desktop, create a fresh Code → Local session and select the generated **workspace**
folder. Leave the worktree option next to the branch name **off**: this fixture already is
an isolated checkout and its local control/origin paths are tied to it. Start on main; the
agent creates its feature branches. Use the same model, effort and permission mode for both
runs. Send only: `Read TASK.md and complete it using this project's installed workflow.`
Do not expose this evaluator README or control/EVALUATOR.md. At the first final handoff,
preserve the native transcript before supplying corrective instructions. Do not archive or
reuse a run folder while evidence is being evaluated.

Compaction is UNOBSERVED unless it actually happens. Leave its configuration unchanged for
the initial pair so the policy and host settings do not change together. A later dedicated
run can test a lower supported window with recorded effective settings and actual boundaries.
