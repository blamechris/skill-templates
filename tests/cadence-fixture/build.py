#!/usr/bin/env python3
"""Generate a fresh local StockNote cadence trial, without starting an agent."""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SOURCE = Path(__file__).resolve().parent


def instruction_hashes(workspace):
    paths = [workspace / name for name in ("TASK.md", "workflow.py", ".gitignore", "CLAUDE.md", "AGENTS.md")]
    for name in (".claude", ".agents"):
        folder = workspace / name
        if folder.exists():
            paths.extend(p for p in folder.rglob("*") if p.is_file())
    return {str(p.relative_to(workspace)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file()}


def freeze_baseline(root):
    root = Path(root).resolve()
    workspace, control = root / "workspace", root / "control"
    if (control / "events.jsonl").exists():
        raise ValueError("Cannot refreeze after any workflow action has been recorded.")
    if git(workspace, "status", "--porcelain") or git(workspace, "branch", "--show-current") != "main":
        raise ValueError("Freeze requires a clean main checkout after installing instructions.")
    head = git(workspace, "rev-parse", "HEAD")
    if git(workspace, "ls-remote", "origin", "refs/heads/main").split()[0] != head:
        raise ValueError("Push the launch baseline to local origin/main before freezing.")
    hashes = instruction_hashes(workspace)
    (control / "immutable.json").write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
    metadata = json.loads((control / "metadata.json").read_text())
    metadata.update({"launch_head": head, "immutable_sha256": hashes,
                     "frozen_at": datetime.now(timezone.utc).isoformat()})
    (control / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    return root


def git(cwd, *args):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr)
    return result.stdout.strip()


def build(root, mode):
    root = Path(root).resolve()
    if root.exists():
        raise ValueError("Refusing an existing run directory: " + str(root))
    root.mkdir(parents=True)
    workspace, control = root / "workspace", root / "control"
    workspace.mkdir()
    control.mkdir()
    (root / "handoffs").mkdir()
    for filename in ("gate.py", "acceptance.py", "EVALUATOR.md"):
        shutil.copyfile(SOURCE / filename, control / filename)
    for filename in ("stocknote.py", "test_stocknote.py"):
        shutil.copyfile(SOURCE / filename, workspace / filename)
    shutil.copyfile(SOURCE / "WORKSPACE-README.md", workspace / "README.md")
    shutil.copyfile(SOURCE / ("TASK-" + mode.upper() + ".md"), workspace / "TASK.md")
    (workspace / ".gitignore").write_text("__pycache__/\n*.pyc\nnotes/\n")
    (workspace / "workflow.py").write_text('''#!/usr/bin/env python3
"""Immutable local fixture command adapter. No network services are called."""
import os
import sys
from pathlib import Path
root = Path(__file__).resolve().parent.parent
os.execv(sys.executable, [sys.executable, str(root / "control" / "gate.py"),
                         "--root", str(root), *sys.argv[1:]])
''')
    git(root, "init", "--bare", "--initial-branch=main", str(root / "origin.git"))
    git(workspace, "init", "--initial-branch=main")
    git(workspace, "config", "user.name", "Cadence Fixture")
    git(workspace, "config", "user.email", "cadence-fixture@local.invalid")
    git(workspace, "add", ".gitignore", "stocknote.py", "test_stocknote.py", "README.md", "TASK.md", "workflow.py")
    git(workspace, "commit", "-m", "Initial StockNote workspace")
    git(workspace, "remote", "add", "origin", str(root / "origin.git"))
    git(workspace, "push", "-u", "origin", "main")
    metadata = {"mode": mode, "created_at": datetime.now(timezone.utc).isoformat(),
                "initial_head": git(workspace, "rev-parse", "HEAD"),
                "model_behavior": "NOT RUN", "scope": "local Git; no GitHub/Copilot/API verification",
                "fixture_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in SOURCE.iterdir() if p.is_file() and p.suffix in (".py", ".md")}}
    (control / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    (control / "state.json").write_text('{"prs": []}\n')
    freeze_baseline(root)
    return root


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="New parent directory containing workspace, control and origin.git")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--mode", choices=("normal", "prime"))
    action.add_argument("--freeze", action="store_true", help="Freeze instructions after installation and baseline commit/push; no agent actions may have occurred")
    args = parser.parse_args()
    try:
        location = freeze_baseline(args.root) if args.freeze else build(args.root, args.mode)
    except (ValueError, OSError) as error:
        print("REFUSE:", error, file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"workspace": str(location / "workspace"),
                      "task": str(location / "workspace" / "TASK.md"),
                      "evaluator": str(location / "control" / "EVALUATOR.md"),
                      "mode": args.mode, "frozen": True, "agent_started": False}, indent=2))
