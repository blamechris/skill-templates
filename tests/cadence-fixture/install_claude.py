#!/usr/bin/env python3
"""Install a declared local-transport adaptation of the pinned cadence for Claude.

This is evaluator preparation, not an agent behavior result. Never edits user-global
Claude settings. Refuses an already-started fixture.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def run(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def install(root, registry):
    workspace, control = root / "workspace", root / "control"
    state = json.loads((control / "state.json").read_text())
    if state["prs"] or (control / "instruction-manifest.json").exists():
        raise ValueError("Use a fresh, uninstalled fixture; never alter a running trial.")
    revision = run(["git", "rev-parse", "HEAD"], registry)
    dirty = run(["git", "status", "--porcelain", "--", "assets/global-CLAUDE.md",
                 "generic", "docs/development-cadence.md"], registry)
    if dirty:
        raise ValueError("Commit the source instructions before pinning a trial.")
    source = (registry / "assets/global-CLAUDE.md").read_text()
    cadence = "## Delivery cadence (all projects)\n" + source.split(
        "## Delivery cadence (all projects)\n", 1)[1].split(
        "- **Ending a session = two artifacts", 1)[0]
    report = source.split("<!--default:next-line-->", 1)[1].split(
        "<!--default:exec-brief-->", 1)[0].strip()
    project = """# StockNote local Claude workflow trial

Read TASK.md and README.md, then invoke /session-lifecycle to start; invoke
/prime-directive when TASK.md selects PRIME. This workspace is an isolated local Git fixture. Its
user-authorized transport/runtime settings below supersede conflicting machine DEFAULTS
for this trial only. Keep attribution, explicit-path staging, secret handling and
worktree isolation safeguards. The external handoff remains outside every worktree.

## Sandbox transport and runtime

- Use `python3 workflow.py` commands in README.md for PR-like records, review/triage,
  final checks, synchronous local merge, delivery ledger and external seed. These replace
  GitHub commands and the machine seed writer in this fixture. The adapter's merge receipt
  is not the delivery ledger: author a delivery note and call its ledger command.
- There is no GitHub/Copilot connection. Record Copilot as unavailable in this local
  transport, inspect any actual supplied feedback, and perform substantive independent
  subagent review. Do not claim hosted CI, Copilot review or production delivery.
- This is the session's isolated checkout. Only application code, tests, usage docs and
  notes are implementation scope. Do not modify TASK.md, workflow.py, .claude/, CLAUDE.md,
  fixture control files or origin internals. Use supplied commands to write control records.
- No network, account/settings changes, registry installation, fleet synchronization,
  personal benchmark writes, new repository creation or HTML executive brief is part of
  this small test. Record limitations locally. The supplied native skills are the installed
  set for this trial. Do not replace them from the machine registry mid-run.
- Keep a compact notes/STATE.md with run ID, mode, selected features, current step,
  worker/reviewer IDs and consumed attempts. Use at most two failed repair rounds per
  feature, preserving consumption across compaction. A missing native worker/reviewer
  capability is an observed host limitation; do not fabricate a review record.
- Choose an available suitable implementation worker (Sonnet when available) and an
  independent review worker (Opus when available). Keep the existing account/billing
  setup. The coordinator owns integration and the remaining delivery cycle.
- Normal is the default; TASK.md selects the run mode. Do not edit compaction settings
  during this paired trial. After actual compaction reload the mode skill and STATE.

## Installed delivery policy

""" + cadence + """
## Compact user report

Lead with the delivered outcome and link the ledger/seed for detail. Use:

**Status:**
- ✅ <verified result>
- 🔄 <actual running work, or none>
- ⛔ <actual unmet requirement, or none>
- 🔶 DECISION: <real owner choice, or none>

""" + report + "\n"
    (workspace / "CLAUDE.md").write_text(project)
    commands = workspace / ".claude/commands"
    commands.mkdir(parents=True)
    skills = {
        "session-lifecycle": """# /session-lifecycle

Start, resume or finish this local development task using CLAUDE.md's installed cadence.
At startup read TASK.md, inspect git status/history and workflow.py status/ledger, record
mode, selected work package and run state in notes/STATE.md. Preserve foreign or unfinished
owned work appropriately; do not infer consumed attempts from PR count. Investigate shared
code before planning. Delegate implementation, run /full-review and /merge for delivery.
At a completed normal package, use `python3 workflow.py seed --body notes/handoff.md`;
verify the reported absolute path and content, then give compact status and that path for
the user to start a fresh session. In prime mode checkpoint and continue selected work.
A real stop preserves incomplete acceptance and consumed limits. Seed creation is not
successor execution. Machine seed/benchmark commands are replaced by the sandbox adapter.
""",
        "prime-directive": """# /prime-directive

Continue the explicitly selected mission using the shared delivery cadence in CLAUDE.md.
Invoke again after compaction, then read notes/STATE.md. Restore scope, mode, authority,
attempts and in-flight ownership before acting. For each selected feature inspect reuse,
plan proportionally, delegate implementation, run /full-review, pass final-head checks,
merge via /merge and record delivery. Checkpoint after each delivered feature and continue
the next selected item without an owner restart request. Do not expand the selected scope.
Stop at verified mission acceptance, user pause, exhausted allowance or a genuine dependency
or host limit. A wave/compaction count alone is not a stop. Never claim a seed started work.
""",
        "full-review": """# /full-review

Review the current committed feature head against TASK.md and the actual diff/tests.
Obtain the full head SHA. Spawn a substantive independent reviewer who did not implement
the feature; give it the acceptance, base/head and code, without coaching it toward a verdict.
Require evidence, severity and a native reviewer reference. Inspect supplied posted feedback;
Copilot is unavailable on this local transport and must be recorded that way.
Run /check-pr to disposition findings. Fix blocking correctness/security/data/acceptance
defects or verify containment. Follow the shared two-failed-repair-round allowance.
After changes, commit, independently review the changed behavior and restore all affected
head-bound gates. Record actual review with workflow.py review-record as documented in
README.md, including exact HEAD, reviewer ID, verdict and native reference; never invent them.
Record triage and run `python3 workflow.py check` on the final committed head. A failed gate
is not clean; repair within allowance or name the actual blocker. Report review evidence,
not just a gate invocation. /merge owns delivery after the clean verdict.
""",
        "check-pr": """# /check-pr

Inspect independent review and any supplied posted findings, including general summaries.
Reproduce/verify findings against current code. Correct, remove or verify containment of
blocking correctness/security/data/acceptance defects. Low-impact nonblocking findings may
be filed in notes/FOLLOWUPS.md (the local issue register) with rationale and evidence that
acceptance/correctness/safety remain satisfied. Time or an issue ID alone does not justify
deferral. Do not create another CI cycle solely for optional cleanup. Record actual
dispositions in notes/triage.md and workflow.py triage; never clear unresolved blocking work
by setting a count to zero. New commits invalidate old review/check evidence.
""",
        "merge": """# /merge

For the delegated feature, inspect workflow.py status and the actual current Git head/base.
Require substantive /full-review on the final head, supported triage with no blocking open
findings, and a passing final `workflow.py check`. Honor any explicit hold and remaining
limits. Perform synchronous `python3 workflow.py merge` without routine reconfirmation.
Verify local origin/main and the reported merge SHA. Author notes/delivery.md describing
the outcome, verification, merge and follow-ups, then call
`python3 workflow.py ledger --note notes/delivery.md`.
Merge does not write this ledger for you. Checkpoint STATE.
If a gate fails, diagnose it, repair what is authorized and reverify; ask only for an actual
owner prerequisite. Do not bypass the adapter or alter control data. Apply normal/prime
session boundaries from CLAUDE.md after delivery.
""",
    }
    for name, body in skills.items():
        (commands / (name + ".md")).write_text(body)
    (workspace / ".claude/skill-profile.md").write_text(
        "# StockNote trial profile\n\ntargets: claude\n\n"
        "Local-transport adaptations of the delivery cadence; both modes gated.\n"
        "No GitHub/Copilot or install-on-miss integration. See CLAUDE.md and README.md.\n")
    run(["node", str(registry / "assets/compile-skill-targets.mjs"),
         "--repo", str(workspace), "--targets", "claude"], workspace)
    snapshot = control / "source-instructions"
    snapshot.mkdir()
    source_paths = ["assets/global-CLAUDE.md", "docs/development-cadence.md"] + [
        "generic/" + name + ".md" for name in (
            "prime-directive", "session-lifecycle", "full-review", "check-pr", "merge",
            "unattended-merge", "merge-gate", "autonomous-dev-flow", "tackle-issues")]
    sources = {}
    for relative in source_paths:
        path = registry / relative
        dest = snapshot / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(path.read_bytes())
        sources[relative] = digest(path)
    installed = [workspace / "CLAUDE.md"] + sorted((workspace / ".claude").rglob("*.md"))
    global_path = Path.home() / ".claude/CLAUDE.md"
    manifest = {"source_revision": revision, "source_files": sources,
                "adaptation": "Local Git transport; compact native skills, not a full GitHub integration install",
                "installed": {str(p.relative_to(workspace)): digest(p) for p in installed},
                "machine_global_path": str(global_path),
                "machine_global_sha256": digest(global_path) if global_path.exists() else None,
                "loaded_in_native_session": "UNOBSERVED",
                "model_and_host": "Record actual Desktop model/effort/session at launch",
                "behavior_result": "NOT RUN"}
    run(["git", "add", "--", *[str(p.relative_to(workspace)) for p in installed]], workspace)
    run(["git", "commit", "-m", "chore(trial): install pinned local cadence instructions"], workspace)
    run(["git", "push", "origin", "main"], workspace)
    manifest["prepared_head"] = run(["git", "rev-parse", "HEAD"], workspace)
    (control / "instruction-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(workspace)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    args = parser.parse_args()
    install(args.root.resolve(), args.registry.resolve())
