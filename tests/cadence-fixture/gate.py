#!/usr/bin/env python3
"""Local PR-like gates. Records declarations; never certifies review independence."""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from acceptance import check as product_check

FEATURES = ("category-totals", "low-stock")


def run(args, cwd, check=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=90)
    if check and result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip())
    return result


def git(workspace, *args):
    return run(["git", *args], workspace).stdout.strip()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def load(path):
    return json.loads(path.read_text())


def now():
    return datetime.now(timezone.utc).isoformat()


def append(control, action, **details):
    event = {"time": now(), "action": action, **details}
    with (control / "events.jsonl").open("a") as stream:
        stream.write(json.dumps(event, sort_keys=True) + "\n")
    return event


def clean(workspace):
    if git(workspace, "status", "--porcelain"):
        raise ValueError("Commit or preserve working changes first; gate requires a clean tracked checkout.")


def verify_ci_checkout(checkout, head, phase):
    if git(checkout, "rev-parse", "HEAD") != head:
        raise ValueError("CI checkout HEAD changed " + phase + ".")
    if git(checkout, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("CI checkout tracked files changed " + phase + ".")


def candidate(workspace, control):
    clean(workspace)
    branch = git(workspace, "branch", "--show-current")
    if not branch or branch == "main":
        raise ValueError("Use a feature branch for PR-like gates.")
    state = load(control / "state.json")
    matches = [p for p in state["prs"] if p["branch"] == branch and not p.get("merged")]
    if len(matches) != 1:
        raise ValueError("Open one PR-like record for this feature branch first.")
    return state, matches[0], git(workspace, "rev-parse", "HEAD")


def evidence(control, path, prefix):
    source = Path(path).resolve()
    content = source.read_bytes()
    if len(content.strip()) < 40:
        raise ValueError("Evidence needs a substantive note; the evaluator judges its quality.")
    sha = hashlib.sha256(content).hexdigest()
    destination = control / "evidence" / (prefix + "-" + sha + ".md")
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(content)
    return {"path": str(destination), "sha256": sha}


def execute(root, args):
    workspace, control = root / "workspace", root / "control"
    expected = load(control / "immutable.json")
    immutable = [workspace / name for name in ("TASK.md", "workflow.py", ".gitignore", "CLAUDE.md", "AGENTS.md")]
    for name in (".claude", ".agents"):
        if (workspace / name).exists():
            immutable.extend(p for p in (workspace / name).rglob("*") if p.is_file())
    actual = {str(p.relative_to(workspace)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in immutable if p.is_file()}
    if actual != expected:
        raise ValueError("Frozen task, tooling or project workflow instructions changed; evaluator must inspect this run.")
    if args.command == "seed":
        source = Path(args.body).resolve()
        body = source.read_text()
        if len(body.strip()) < 40:
            raise ValueError("Seed must state usable result, remaining work, and intended continuation.")
        path = root / "handoffs" / "NEXT-workspace.md"
        path.parent.mkdir(exist_ok=True)
        if path.exists():
            archive = path.with_name("NEXT-workspace." + now().replace(":", "-") + ".md")
            shutil.copyfile(path, archive)
        path.write_text(body)
        append(control, "seed", path=str(path), sha256=hashlib.sha256(body.encode()).hexdigest())
        print("seed:", path)
        return
    if args.command in ("status", "ledger"):
        if args.command == "ledger":
            path = control / "ledger.jsonl"
            if args.note:
                state = load(control / "state.json")
                merges = [p["merged"] for p in state["prs"] if p.get("merged")]
                if not merges:
                    raise ValueError("No synchronous merge exists to record.")
                latest = max(merges, key=lambda merge: merge["time"])
                rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
                if any(row["merge_sha"] == latest["merge_sha"] for row in rows):
                    raise ValueError("Latest merge is already in the delivery ledger.")
                record = {**latest, "recorded_at": now(),
                          "delivery_note": evidence(control, args.note, "delivery")}
                with path.open("a") as stream:
                    stream.write(json.dumps(record, sort_keys=True) + "\n")
                append(control, "ledger", merge_sha=latest["merge_sha"])
            print(path.read_text() if path.exists() else "No delivery ledger entries recorded.")
        else:
            print(json.dumps(load(control / "state.json"), indent=2))
        return
    if args.command == "open":
        clean(workspace)
        branch = git(workspace, "branch", "--show-current")
        if not branch or branch == "main":
            raise ValueError("Create and commit a feature branch first.")
        state = load(control / "state.json")
        if any(p["branch"] == branch and not p.get("merged") for p in state["prs"]):
            raise ValueError("This branch already has an open record.")
        head = git(workspace, "rev-parse", "HEAD")
        git(workspace, "fetch", "origin", "main")
        base = git(workspace, "rev-parse", "origin/main")
        if head == base or git(workspace, "merge-base", head, base) != base:
            raise ValueError("Branch must contain current origin/main and a feature commit.")
        git(workspace, "push", "-u", "origin", branch)
        pr = {"id": len(state["prs"]) + 1, "feature": args.feature,
              "branch": branch, "opened_head": head, "opened_base": base,
              "description": evidence(control, args.note, "description"),
              "opened_at": now(), "reviews": [], "triages": [], "checks": []}
        state["prs"].append(pr)
        save(control / "state.json", state)
        append(control, "open", id=pr["id"], feature=args.feature, head=head)
        print("Opened local PR-like record", pr["id"], "for", args.feature)
        return
    state, pr, head = candidate(workspace, control)
    if args.command == "review-record":
        if args.head != head:
            raise ValueError("Review declaration must name the current exact HEAD.")
        record = {"head": head, "reviewer": args.reviewer, "kind": args.kind,
                  "verdict": args.verdict, "native_reference": args.native_reference,
                  "evidence": evidence(control, args.note, "review"), "time": now()}
        pr["reviews"].append(record)
    elif args.command == "triage":
        record = {"head": head, "unresolved": args.unresolved,
                  "evidence": evidence(control, args.note, "triage"), "time": now()}
        pr["triages"].append(record)
    elif args.command == "check":
        git(workspace, "fetch", "origin", "main")
        base = git(workspace, "rev-parse", "origin/main")
        if git(workspace, "merge-base", head, base) != base:
            raise ValueError("Integrate current main before final CI.")
        temp = Path(tempfile.mkdtemp(prefix="cadence-check-", dir=control))
        checkout = temp / "source"
        output, passed = "", False
        try:
            git(workspace, "worktree", "add", "--detach", str(checkout), head)
            verify_ci_checkout(checkout, head, "before repository tests")
            tests = run([sys.executable, "-m", "unittest", "discover", "-v"], checkout, check=False)
            output = tests.stdout + tests.stderr
            verify_ci_checkout(checkout, head, "during repository tests")
            if tests.returncode:
                raise ValueError("Repository tests failed.")
            for feature in FEATURES[:FEATURES.index(pr["feature"]) + 1]:
                verify_ci_checkout(checkout, head, "before product checks")
                product_check(checkout, feature)
                verify_ci_checkout(checkout, head, "during product checks")
            passed = True
        except (ValueError, AssertionError, AttributeError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            output += "\nProduct check: " + str(error)
        finally:
            if checkout.exists():
                git(workspace, "worktree", "remove", "--force", str(checkout))
            shutil.rmtree(temp)
        record = {"head": head, "base": base, "passed": passed,
                  "log": output, "time": now()}
        pr["checks"].append(record)
        save(control / "state.json", state)
        append(control, "check", id=pr["id"], head=head, passed=passed)
        print(output)
        if not passed:
            raise ValueError("Final local CI failed; record retained.")
        print("Final local CI passed for", head)
        return
    elif args.command == "merge":
        git(workspace, "fetch", "origin", "main")
        base = git(workspace, "rev-parse", "origin/main")
        reviews = [r for r in pr["reviews"] if r["head"] == head]
        independent = [r for r in reviews if r["kind"] == "independent"]
        if not reviews or reviews[-1]["verdict"] != "approve" or not independent or independent[-1]["verdict"] != "approve":
            raise ValueError("Record an independent approval on current HEAD; declaration alone is not proof of independence.")
        if not pr["triages"] or pr["triages"][-1]["head"] != head or pr["triages"][-1]["unresolved"]:
            raise ValueError("Current-HEAD triage must record zero unresolved findings.")
        if not pr["checks"] or pr["checks"][-1]["head"] != head or not pr["checks"][-1]["passed"]:
            raise ValueError("Passing final CI on exact HEAD is required.")
        if pr["checks"][-1]["base"] != base:
            raise ValueError("Main advanced after final CI; integrate and recheck.")
        if pr["checks"][-1]["time"] < max(reviews[-1]["time"], pr["triages"][-1]["time"]):
            raise ValueError("Run final CI after review and triage.")
        if git(workspace, "rev-parse", "refs/heads/main") != base:
            raise ValueError("Local main differs from the verified base; preserving it unchanged. Reconcile it before merging.")
        git(workspace, "push", "origin", pr["branch"])
        git(workspace, "checkout", "main")
        git(workspace, "merge", "--no-ff", head, "-m", "Merge local feature: " + pr["feature"])
        merge_sha = git(workspace, "rev-parse", "HEAD")
        parents = git(workspace, "show", "-s", "--format=%P", merge_sha).split()
        if parents != [base, head]:
            raise ValueError("Merge parents do not match the verified base and reviewed HEAD; not pushing local main.")
        git(workspace, "push", "origin", "main")
        remote = git(workspace, "ls-remote", "origin", "refs/heads/main").split()[0]
        if remote != merge_sha:
            raise ValueError("Remote main verification failed; inspect repository before retrying.")
        record = {"time": now(), "id": pr["id"], "feature": pr["feature"],
                  "reviewed_head": head, "base": base, "merge_sha": merge_sha,
                  "verified_remote_main": remote, "scope": "local Git, not GitHub"}
        pr["merged"] = record
    save(control / "state.json", state)
    append(control, args.command, id=pr["id"], head=head)
    print(json.dumps(record, indent=2))


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", required=True, type=Path)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("status", "check", "merge"):
        commands.add_parser(name)
    ledger = commands.add_parser("ledger")
    ledger.add_argument("--note")
    seed = commands.add_parser("seed")
    seed.add_argument("--body", required=True)
    opening = commands.add_parser("open")
    opening.add_argument("--feature", choices=FEATURES, required=True)
    opening.add_argument("--note", required=True)
    review = commands.add_parser("review-record")
    review.add_argument("--head", required=True)
    review.add_argument("--reviewer", required=True)
    review.add_argument("--kind", choices=("independent", "self"), required=True)
    review.add_argument("--verdict", choices=("approve", "request_changes"), required=True)
    review.add_argument("--native-reference", required=True)
    review.add_argument("--note", required=True)
    triage = commands.add_parser("triage")
    triage.add_argument("--note", required=True)
    triage.add_argument("--unresolved", required=True, type=int, choices=range(1001))
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    try:
        execute(arguments.root.resolve(), arguments)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print("REFUSE:", error, file=sys.stderr)
        sys.exit(1)
