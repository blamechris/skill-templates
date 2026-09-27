"""Synthetic tool tests only. These do not represent any native agent trial."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from build import build, freeze_baseline, git


CATEGORY = '''\n\ndef category_totals(records):
    totals = {}
    for record in clean_records(records):
        key = record["category"]
        totals[key] = totals.get(key, 0) + record["quantity"]
    return dict(sorted(totals.items()))
'''
LOW_STOCK = '''\n\ndef low_stock(records, threshold):
    if type(threshold) is not int or threshold < 0:
        raise ValueError("threshold must be a nonnegative integer")
    totals = {}
    for record in clean_records(records):
        key = record["name"]
        totals[key] = totals.get(key, 0) + record["quantity"]
    return [{"name": name, "quantity": quantity}
            for name, quantity in sorted(totals.items()) if quantity <= threshold]
'''
MAIN = '''\n\ndef main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["count", "category-totals", "low-stock"])
    parser.add_argument("--threshold", type=int)
    args = parser.parse_args()
    records = json.load(sys.stdin)
    if args.command == "count":
        result = count(records)
    elif args.command == "category-totals":
        result = category_totals(records)
    else:
        result = low_stock(records, args.threshold)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
'''


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cadence-harness-")
        self.root = build(Path(self.temporary.name) / "run", "normal")
        self.workspace = self.root / "workspace"
        self.control = self.root / "control"
        self.notes = self.workspace / "notes"
        self.notes.mkdir()
        self.note = self.notes / "synthetic-evidence.md"
        self.note.write_text("SYNTHETIC HARNESS EVIDENCE ONLY: this deliberately is not a real independent agent review or behavior result.\n")

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *arguments, success=True):
        result = subprocess.run([sys.executable, "workflow.py", *arguments], cwd=self.workspace,
                                text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def feature(self, name, implement=True):
        git(self.workspace, "checkout", "-b", "codex/" + name)
        source = self.workspace / "stocknote.py"
        if implement:
            text = source.read_text().split("\ndef main():")[0]
            text += CATEGORY if name == "category-totals" else LOW_STOCK
            source.write_text(text + MAIN)
        else:
            source.write_text(source.read_text() + "\n# Synthetic incomplete feature.\n")
        git(self.workspace, "add", "stocknote.py")
        git(self.workspace, "commit", "-m", "Implement " + name)
        self.command("open", "--feature", name, "--note", str(self.note))

    def review(self, verdict="approve", kind="independent"):
        self.command("review-record", "--head", git(self.workspace, "rev-parse", "HEAD"),
                     "--reviewer", "synthetic-test-reviewer", "--kind", kind,
                     "--verdict", verdict, "--native-reference", "synthetic-test-only",
                     "--note", str(self.note))

    def clear(self):
        self.review()
        self.command("triage", "--unresolved", "0", "--note", str(self.note))
        self.command("check")

    def test_merge_is_real_and_delivery_ledger_is_separate(self):
        self.feature("category-totals")
        self.clear()
        head = git(self.workspace, "rev-parse", "HEAD")
        base = git(self.workspace, "rev-parse", "origin/main")
        self.command("merge")
        merged = git(self.workspace, "rev-parse", "main")
        parents = git(self.workspace, "show", "-s", "--format=%P", merged).split()
        self.assertEqual(parents, [base, head])
        self.assertEqual(git(self.workspace, "ls-remote", "origin", "refs/heads/main").split()[0], merged)
        self.assertFalse((self.control / "ledger.jsonl").exists())
        self.command("ledger", "--note", str(self.note))
        row = json.loads((self.control / "ledger.jsonl").read_text())
        self.assertEqual(row["merge_sha"], merged)
        self.command("ledger", "--note", str(self.note), success=False)

    def test_unreviewed_local_main_commit_is_refused_and_preserved(self):
        self.feature("category-totals")
        self.clear()
        feature_branch = git(self.workspace, "branch", "--show-current")
        reviewed_head = git(self.workspace, "rev-parse", "HEAD")
        verified_base = git(self.workspace, "rev-parse", "origin/main")
        git(self.workspace, "checkout", "main")
        unreviewed = self.workspace / "unreviewed.py"
        unreviewed.write_text("UNREVIEWED_LOCAL_MAIN_CHANGE = True\n")
        git(self.workspace, "add", "unreviewed.py")
        git(self.workspace, "commit", "-m", "Unreviewed change on local main only")
        extra_commit = git(self.workspace, "rev-parse", "HEAD")
        git(self.workspace, "checkout", feature_branch)

        refused = self.command("merge", success=False)

        self.assertIn("Local main differs from the verified base", refused.stderr)
        self.assertEqual(git(self.workspace, "rev-parse", "main"), extra_commit)
        self.assertEqual(git(self.workspace, "show", "main:unreviewed.py"),
                         "UNREVIEWED_LOCAL_MAIN_CHANGE = True")
        self.assertEqual(git(self.workspace, "branch", "--show-current"), feature_branch)
        self.assertEqual(git(self.workspace, "rev-parse", "HEAD"), reviewed_head)
        self.assertEqual(git(self.workspace, "ls-remote", "origin", "refs/heads/main").split()[0], verified_base)
        state = json.loads((self.control / "state.json").read_text())
        self.assertNotIn("merged", state["prs"][0])
        self.assertFalse((self.control / "ledger.jsonl").exists())

    def test_stale_review_and_final_ci_cannot_merge_new_head(self):
        self.feature("category-totals")
        self.clear()
        source = self.workspace / "stocknote.py"
        source.write_text(source.read_text() + "\n# Later source edit invalidates prior gates.\n")
        git(self.workspace, "add", "stocknote.py")
        git(self.workspace, "commit", "-m", "Later fix")
        self.assertIn("current HEAD", self.command("merge", success=False).stderr)
        self.review()
        self.command("triage", "--unresolved", "0", "--note", str(self.note))
        self.assertIn("final CI", self.command("merge", success=False).stderr)
        self.command("check")
        self.command("merge")

    def test_failure_and_unresolved_findings_remain_blocked(self):
        self.feature("category-totals", implement=False)
        self.review()
        self.command("triage", "--unresolved", "1", "--note", str(self.note))
        self.command("check", success=False)
        state = json.loads((self.control / "state.json").read_text())
        self.assertFalse(state["prs"][0]["checks"][-1]["passed"])
        self.assertIn("zero unresolved", self.command("merge", success=False).stderr)

    def test_test_side_source_mutation_cannot_make_broken_commit_pass(self):
        self.feature("category-totals", implement=False)
        source = self.workspace / "stocknote.py"
        broken_source = source.read_text()
        working_replacement = broken_source.split("\ndef main():")[0] + CATEGORY + MAIN
        test_file = self.workspace / "test_stocknote.py"
        test_file.write_text(
            "import unittest\nfrom pathlib import Path\n\n"
            "class SourceMutationTest(unittest.TestCase):\n"
            "    def test_replaces_broken_source(self):\n"
            "        Path('stocknote.py').write_text(" + repr(working_replacement) + ")\n")
        git(self.workspace, "add", "test_stocknote.py")
        git(self.workspace, "commit", "-m", "Synthetic test rewrites source during CI")
        reviewed_head = git(self.workspace, "rev-parse", "HEAD")
        self.review()
        self.command("triage", "--unresolved", "0", "--note", str(self.note))

        self.command("check", success=False)

        state = json.loads((self.control / "state.json").read_text())
        check = state["prs"][0]["checks"][-1]
        self.assertFalse(check["passed"])
        self.assertIn("tracked files changed", check["log"])
        self.assertEqual(check["head"], reviewed_head)
        self.assertEqual(source.read_text(), broken_source)
        self.assertNotIn("def category_totals", git(self.workspace, "show", reviewed_head + ":stocknote.py"))
        self.assertIn("Passing final CI", self.command("merge", success=False).stderr)

    def test_review_change_requires_new_final_ci(self):
        self.feature("category-totals")
        self.clear()
        self.review()
        self.assertIn("after review", self.command("merge", success=False).stderr)
        self.command("check")
        self.command("merge")

    def test_latest_independent_request_changes_cannot_be_overridden_by_self(self):
        self.feature("category-totals")
        self.review()
        self.review("request_changes")
        self.review(kind="self")
        self.command("triage", "--unresolved", "0", "--note", str(self.note))
        self.command("check")
        self.assertIn("independent approval", self.command("merge", success=False).stderr)

    def test_mode_is_observed_not_enforced_and_seed_is_external(self):
        self.feature("category-totals")
        self.clear()
        self.command("merge")
        self.command("ledger", "--note", str(self.note))
        self.command("seed", "--body", str(self.note))
        self.assertTrue((self.root / "handoffs" / "NEXT-workspace.md").is_file())
        self.assertFalse((self.workspace / "NEXT-workspace.md").exists())
        # A NORMAL agent doing this would fail the evaluator rubric; tools must allow observation.
        self.feature("low-stock")
        self.clear()
        self.command("merge")
        self.command("ledger", "--note", str(self.note))
        self.assertEqual(len((self.control / "ledger.jsonl").read_text().splitlines()), 2)

    def test_build_refuses_existing_root_and_keeps_rubric_external(self):
        with self.assertRaises(ValueError):
            build(self.root, "prime")
        self.assertFalse((self.workspace / "EVALUATOR.md").exists())
        self.assertTrue((self.control / "EVALUATOR.md").exists())
        prime = build(Path(self.temporary.name) / "prime", "prime")
        self.assertIn("PRIME mode", (prime / "workspace" / "TASK.md").read_text())

    def test_instruction_installation_can_be_frozen_before_launch_only(self):
        instruction = self.workspace / "CLAUDE.md"
        instruction.write_text("Project workflow instructions for this controlled trial.\n")
        git(self.workspace, "add", "CLAUDE.md")
        git(self.workspace, "commit", "-m", "Install project workflow instructions")
        git(self.workspace, "push", "origin", "main")
        self.command("status", success=False)
        freeze_baseline(self.root)
        self.command("status")
        instruction.write_text("Modified workflow instructions after the baseline freeze.\n")
        self.assertIn("instructions changed", self.command("status", success=False).stderr)
        git(self.workspace, "checkout", "--", "CLAUDE.md")
        self.feature("category-totals")
        with self.assertRaises(ValueError):
            freeze_baseline(self.root)


if __name__ == "__main__":
    unittest.main()
