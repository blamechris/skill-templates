import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_claude  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SOURCE = (REPO / "assets/AGENTS.md").read_text()


def body(source, rule_id):
    """First sentence-ish line of a rule's body, taken from the real file by rule ID."""
    match = re.search(r"<!--(?:floor|default):" + re.escape(rule_id) + r"-->\n(.*?)(?=^<!--(?:floor|default):|\Z)",
                      source, re.M | re.S)
    assert match, rule_id
    return match.group(1).strip()


def following_rule_id(source, rule_id):
    after = source[source.index(f"<!--default:{rule_id}-->"):]  # the rule itself is a default
    return re.search(r"^<!--(?:floor|default):([\w-]+)-->", after[1:], re.M).group(1)


class RealSourceExtractTests(unittest.TestCase):
    def test_cadence_ends_at_last_selected_rule(self):
        cadence, _ = install_claude.instruction_extracts(SOURCE)
        last = install_claude.CADENCE_RULES[-1]
        self.assertEqual(last, "restart-triggers")
        self.assertTrue(cadence.endswith(body(SOURCE, last)), "cadence must end with the last rule")
        following = body(SOURCE, following_rule_id(SOURCE, last))
        self.assertTrue(following[:80] not in cadence, "cadence leaked the following rule")

    def test_report_ends_before_exec_brief(self):
        _, report = install_claude.instruction_extracts(SOURCE)
        self.assertEqual(report, body(SOURCE, "next-line"))
        self.assertTrue(body(SOURCE, "exec-brief")[:80] not in report, "report leaked exec-brief")
        self.assertTrue("<!--" not in report, "report contains a marker")


class SyntheticSourceTests(unittest.TestCase):
    RULES = "".join(f"<!--default:{r}-->\ntext of {r}\n\n" for r in install_claude.CADENCE_RULES)
    GOOD = (RULES + "<!--default:next-line-->\nNEXT BODY\n\n<!--default:exec-brief-->\nBRIEF BODY\n")

    def test_synthetic_good_source_is_bounded(self):
        cadence, report = install_claude.instruction_extracts(self.GOOD)
        self.assertEqual(report, "NEXT BODY")
        self.assertTrue("BRIEF BODY" not in report)
        self.assertTrue(cadence.endswith("text of restart-triggers"))

    def test_missing_report_end_marker_raises(self):
        source = self.GOOD.replace("<!--default:exec-brief-->", "")
        with self.assertRaisesRegex(ValueError, "exec-brief"):
            install_claude.instruction_extracts(source)

    def test_missing_report_start_marker_raises_value_error(self):
        source = self.GOOD.replace("<!--default:next-line-->", "")
        with self.assertRaisesRegex(ValueError, "next-line"):
            install_claude.instruction_extracts(source)

    def test_duplicate_marker_raises(self):
        source = self.GOOD + "<!--default:exec-brief-->\nagain\n"
        with self.assertRaisesRegex(ValueError, "exec-brief"):
            install_claude.instruction_extracts(source)

    def test_end_marker_before_start_raises(self):
        source = self.RULES + "<!--default:exec-brief-->\nB\n<!--default:next-line-->\nN\n"
        with self.assertRaisesRegex(ValueError, "precedes"):
            install_claude.instruction_extracts(source)

    def test_missing_cadence_rule_raises(self):
        source = self.GOOD.replace("<!--default:in-effect-line-->", "")
        with self.assertRaisesRegex(ValueError, "Missing cadence rule: in-effect-line"):
            install_claude.instruction_extracts(source)


if __name__ == "__main__":
    unittest.main()
