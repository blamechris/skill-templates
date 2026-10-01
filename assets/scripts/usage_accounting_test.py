"""Synthetic edge cases and the preserved, sanitized recent-cohort arithmetic."""
import json
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from usage_accounting import RATE_CARD_VERSION, Responses, price_usage


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rec(ts, request, message, model, output, cache_read=0, cache_5m=0,
        cache_1h=0, stop=None):
    return {"type": "assistant", "timestamp": ts, "requestId": request,
            "message": {"id": message, "model": model, "stop_reason": stop,
                        "usage": {"input_tokens": 0, "output_tokens": output,
                                  "cache_read_input_tokens": cache_read,
                                  "cache_creation_input_tokens": cache_5m + cache_1h,
                                  "cache_creation": {
                                      "ephemeral_5m_input_tokens": cache_5m,
                                      "ephemeral_1h_input_tokens": cache_1h}}}}


class UsageAccountingTests(unittest.TestCase):
    def test_exact_rates_cache_lifetimes_and_unknowns(self):
        u = rec("2026-09-29T00:00:00Z", "r", "m", "claude-opus-5-5", 0,
                cache_read=1000000, cache_5m=1000000, cache_1h=1000000)["message"]["usage"]
        self.assertEqual(price_usage(u, "claude-opus-5-5")["lower_usd"], Decimal("13.20"))
        self.assertEqual(price_usage(u, "claude-opus-5")["lower_usd"], Decimal("16.75"))
        u["cache_creation_input_tokens"] += 1000000
        p = price_usage(u, "claude-opus-5-5")
        self.assertEqual((p["lower_usd"], p["upper_usd"]),
                         (Decimal("18.20"), Decimal("21.20")))
        self.assertEqual(p["tokens"]["cache_ttl_unknown_tokens"], 1000000)
        with self.assertRaises(ValueError):
            price_usage(u, "claude-unknown")
        u["cache_creation_input_tokens"] = 1
        with self.assertRaises(ValueError):
            price_usage(u, "claude-opus-5-5")
        plain = {"input_tokens": 1000000}
        self.assertEqual(price_usage(plain, "claude-opus-5-5")["speed"], "unknown")
        self.assertEqual(price_usage(dict(plain, speed="fast"), "claude-opus-5-5")["lower_usd"],
                         Decimal(8))
        self.assertEqual(price_usage(dict(plain, service_tier="batch"), "claude-opus-5-5")["lower_usd"],
                         Decimal(2))
        self.assertEqual(price_usage(dict(plain, inference_geo="us"), "claude-opus-5-5")["lower_usd"],
                         Decimal("4.4"))
        with self.assertRaises(ValueError):
            price_usage(dict(plain, speed="fast"), "claude-haiku-4-5-20251001")

    def test_streaming_and_copied_partial_choose_one_coherent_response(self):
        selected = Responses()
        initial = rec("2026-09-29T00:00:00Z", "r", "m", "claude-opus-5-5", 2,
                      cache_read=1000000)
        final = rec("2026-09-29T00:00:02Z", "r", "m", "claude-opus-5-5", 100,
                    cache_read=1000000, stop="end_turn")
        stale_copy = dict(initial, timestamp="2026-09-29T00:00:10Z")
        selected.add(initial, "main", 1)
        selected.add(final, "main", 2)
        selected.add(stale_copy, "copy", 1)
        self.assertEqual(len(selected.selected), 1)
        item = next(iter(selected.rows()))
        self.assertEqual(item["record"]["message"]["usage"]["output_tokens"], 100)
        self.assertEqual(item["source"], "main")
        selected.add(rec("2026-09-29T00:01:00Z", "r2", "m2", "claude-sonnet-5", 1),
                     "child", 1, "child")
        self.assertEqual(len(selected.selected), 2)
        for first_role, second_role in (("main", "child"), ("child", "main")):
            copies = Responses()
            copies.add(final, first_role, 1, first_role)
            copies.add(dict(final, timestamp="2026-09-29T00:00:20Z"),
                       second_role, 1, second_role)
            self.assertEqual(next(iter(copies.rows()))["role"], "main")
            self.assertEqual(copies.cross_role_pairs, 1)
        for missing in ("requestId", "message_id"):
            for reverse in (False, True):
                partial = json.loads(json.dumps(initial))
                if missing == "requestId":
                    partial.pop("requestId")
                else:
                    partial["message"].pop("id")
                aliased = Responses()
                order = (final, partial) if reverse else (partial, final)
                for index, record in enumerate(order):
                    aliased.add(record, "main", index)
                self.assertEqual(len(aliased.selected), 1)
                self.assertEqual(next(iter(aliased.rows()))["record"]["message"]["usage"]["output_tokens"], 100)
        shared_id = rec("2026-09-29T00:02:00Z", None, "shared", "claude-opus-5-5", 100)
        shared_id.pop("requestId")
        pair1 = rec("2026-09-29T00:02:01Z", "r1", "shared", "claude-opus-5-5", 1)
        pair2 = rec("2026-09-29T00:02:02Z", "r2", "shared", "claude-opus-5-5", 100)
        for order in ((shared_id, pair1, pair2), (pair2, pair1, shared_id)):
            ambiguous = Responses()
            for index, record in enumerate(order):
                ambiguous.add(record, "copy", index)
            self.assertEqual(len(ambiguous.selected), 2)
            self.assertEqual(ambiguous.ambiguous_identities, 1)
            self.assertEqual(sum(item["record"]["message"]["usage"]["output_tokens"]
                                 for item in ambiguous.rows()), 101)

    def test_partial_cache_split_remains_in_raw_and_historical_index(self):
        pace = load("usage_pace_accounting", HERE / "usage-pace.py")
        usage = {"input_tokens": 1, "output_tokens": 2,
                 "cache_read_input_tokens": 3, "cache_creation_input_tokens": 10,
                 "cache_creation": {"ephemeral_5m_input_tokens": 4}}
        raw, index = pace.token_measures(usage)
        self.assertEqual(raw, 16)
        self.assertEqual(index, 1 + 10 + .3 + 10 * 1.25)

    def test_pace_keeps_distinct_pairs_and_ignores_stale_unpriced_copy(self):
        pace = load("usage_pace_ids", HERE / "usage-pace.py")
        def scan(records):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / "projects" / "session.jsonl"
                source.parent.mkdir(parents=True)
                source.write_text("".join(json.dumps(r, separators=(",", ":")) + "\n"
                                          for r in records))
                pace.ROOT = source.parent
                pace.HIST = root / "history"
                pace.CACHE = pace.HIST / "pace-cache.json"
                return pace.scan_detail("2026-09-30", force=True)[0]
        first = rec("2026-09-29T12:00:00Z", "r1", "shared", "claude-opus-5-5", 1000000)
        second = rec("2026-09-29T12:00:01Z", "r2", "shared", "claude-opus-5-5", 1000000)
        self.assertEqual(scan([first, second])["all"], 40)
        final = rec("2026-09-29T12:00:02Z", "rf", "mf", "claude-opus-5-5", 100,
                    stop="end_turn")
        stale = rec("2026-09-29T12:00:03Z", "rf", "mf", "unknown-model", 2)
        totals = scan([final, stale])
        self.assertEqual(totals["all"], .002)
        self.assertEqual(totals["unpriced_responses"], 0)
        alias = rec("2026-09-29T12:00:04Z", "ra", "ma", "claude-opus-5-5", 100)
        alias.pop("requestId")
        paired = rec("2026-09-29T12:00:05Z", "ra", "ma", "claude-opus-5-5", 2)
        for order in ((alias, paired), (paired, alias)):
            uncertain = scan(order)
            self.assertEqual(uncertain.get("all", 0), .00004)
            self.assertEqual(uncertain["unpriced_responses"], 1)
        second_pair = rec("2026-09-29T12:00:06Z", "rb", "ma",
                          "claude-opus-5-5", 100)
        for order in ((alias, paired, second_pair), (paired, second_pair, alias),
                      (second_pair, alias, paired)):
            uncertain = scan(order)
            self.assertEqual(uncertain.get("all", 0), .00204)
            self.assertEqual(uncertain["unpriced_responses"], 1)
        smaller_alias = rec("2026-09-29T12:00:04Z", "ra", "ma",
                            "claude-opus-5-5", 2)
        smaller_alias.pop("requestId")
        larger_pair = rec("2026-09-29T12:00:05Z", "ra", "ma",
                          "claude-opus-5-5", 100)
        for order in ((smaller_alias, larger_pair), (larger_pair, smaller_alias)):
            coherent = scan(order)
            self.assertEqual(coherent.get("all", 0), .002)
            self.assertEqual(coherent["unpriced_responses"], 0)

    def test_preserved_recent_cohort_reprices_exactly(self):
        fixture = json.loads((HERE / "fixtures" /
                              "usage-recent-cohort-2026-09-29.json").read_text())
        total = Decimal(0)
        legacy = Decimal(0)
        responses = 0
        for model, row in fixture["models"].items():
            t = row["tokens"]
            u = {"input_tokens": t["input_tokens"],
                 "output_tokens": t["output_tokens"],
                 "cache_read_input_tokens": t["cache_read_input_tokens"],
                 "cache_creation_input_tokens": t["cache_creation_input_tokens"],
                 "cache_creation": {"ephemeral_5m_input_tokens": t["cache_5m_tokens"],
                                    "ephemeral_1h_input_tokens": t["cache_1h_tokens"]}}
            p = price_usage(u, model)
            self.assertEqual(p["tokens"]["cache_ttl_unknown_tokens"], 0)
            total += p["lower_usd"]
            old_input, old_output = ((Decimal(3), Decimal(15)) if "sonnet" in model else
                                     (Decimal(5), Decimal(25)) if "opus" in model else
                                     (Decimal(1), Decimal(5)))
            legacy += (t["input_tokens"] * old_input +
                       t["output_tokens"] * old_output +
                       t["cache_5m_tokens"] * old_input * Decimal("1.25") +
                       t["cache_1h_tokens"] * old_input * 2 +
                       t["cache_read_input_tokens"] * old_input * Decimal(".1")) / 1000000
            responses += row["responses"]
        self.assertEqual(str(total), fixture["expected_usd"])
        self.assertEqual(legacy, Decimal("959.23834400"))
        self.assertEqual(legacy - total, Decimal("369.61734755"))
        self.assertEqual(responses, 8545)
        self.assertEqual(sum(fixture["role_responses"].values()), responses)
        self.assertEqual(sum((Decimal(x) for x in fixture["role_usd"].values()), Decimal(0)), total)
        self.assertEqual(fixture["selected_without_terminal_metadata"], 632)

    def test_continuation_checkpoints_use_latest_parent_and_child_snapshot(self):
        script = HERE / "usage-checkpoint.py"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main = root / "session-1.jsonl"
            child = root / "session-1" / "subagents" / "agent-1.jsonl"
            child.parent.mkdir(parents=True)
            initial = rec("2026-09-29T00:00:00Z", "r1", "m1", "claude-opus-5-5", 2)
            final = rec("2026-09-29T00:00:02Z", "r1", "m1", "claude-opus-5-5", 100,
                        stop="end_turn")
            main.write_text(json.dumps(initial) + "\n" + json.dumps(final) + "\n")
            child.write_text(json.dumps(rec("2026-09-29T00:00:03Z", "r2", "m2",
                                            "claude-sonnet-5", 100,
                                            cache_5m=1000000)) + "\n")
            out = root / "checkpoints"
            def run(at, status):
                return subprocess.run([sys.executable, str(script), "--session", str(main),
                                       "--run-id", "run-1", "--capture-at", at,
                                       "--status", status, "--out-dir", str(out)],
                                      capture_output=True, text=True)
            self.assertEqual(run("2026-09-29T00:01:00Z", "partial").returncode, 0)
            main.write_text(main.read_text() + json.dumps(rec("2026-09-29T00:02:00Z", "r3", "m3",
                                                              "claude-opus-5-5", 100)) + "\n")
            self.assertEqual(run("2026-09-29T00:03:00Z", "final").returncode, 0)
            self.assertNotEqual(run("2026-09-29T00:03:00Z", "final").returncode, 0)
            aggregate = subprocess.check_output([sys.executable, str(script),
                                                 "--aggregate-dir", str(out)], text=True)
            doc = json.loads(aggregate)
            self.assertEqual((doc["sessions"], doc["partial_sessions"]), (1, 0))
            self.assertEqual(Decimal(doc["parent_usd"]), Decimal(".004"))
            self.assertEqual(Decimal(doc["children_usd"]), Decimal("2.501"))
            self.assertEqual(Decimal(doc["all_in_usd"]), Decimal("2.505"))
            self.assertEqual(doc["all_in_lower_usd"], doc["all_in_upper_usd"])
            self.assertEqual(doc["source_checkpoints"][0]["run_id"], "run-1")
            self.assertEqual(doc["selected_response_time_bounds"]["without_timestamp"], 0)
            self.assertEqual(doc["rate_card"], RATE_CARD_VERSION)
            snapshots = [json.loads(p.read_text()) for p in out.glob("*.json")]
            final = next(s for s in snapshots if s["status"] == "final")
            self.assertEqual(final["all_in"]["responses"], 3)
            self.assertEqual(final["all_in"]["tokens"]["output_tokens"], 300)
            self.assertEqual(final["children"]["by_model"]["claude-sonnet-5"]["responses"], 1)
            self.assertEqual(len(final["source_coverage"]), 2)
            self.assertTrue(all(len(p["sha256"]) == 64 for p in final["source_coverage"]))
            copy_session = root / "session-2.jsonl"
            copy_session.write_text(json.dumps(final["selected_responses"][0]) + "\n")
            copied = subprocess.run([sys.executable, str(script), "--session", str(copy_session),
                                     "--run-id", "run-2", "--capture-at",
                                     "2026-09-29T00:04:00Z", "--status", "final",
                                     "--out-dir", str(out)], capture_output=True, text=True)
            self.assertEqual(copied.returncode, 0, copied.stderr)
            deduped = json.loads(subprocess.check_output(
                [sys.executable, str(script), "--aggregate-dir", str(out)], text=True))
            self.assertEqual(deduped["sessions"], 2)
            self.assertEqual(deduped["all_in_responses"], 3)
            self.assertEqual(Decimal(deduped["all_in_usd"]), Decimal("2.505"))

    def test_aggregate_keeps_unknown_ttl_bounds_and_unpriced_coverage(self):
        checkpoint = load("usage_checkpoint_bounds", HERE / "usage-checkpoint.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "session.jsonl"
            uncertain = rec("2026-09-29T00:00:00Z", "r1", "m1", "claude-opus-5-5", 0)
            uncertain["message"]["usage"]["cache_creation_input_tokens"] = 1000000
            uncertain["message"]["usage"]["cache_creation"] = {}
            unknown = rec("2026-09-29T00:01:00Z", "r2", "m2", "claude-unknown", 1)
            source.write_text(json.dumps(uncertain) + "\n" + json.dumps(unknown) + "\n")
            out = root / "checkpoints"
            out.mkdir()
            snapshot = checkpoint.capture(source, "pilot-1", "2026-09-29T00:02:00Z", "final")
            (out / "snapshot.json").write_text(json.dumps(snapshot))
            aggregate = checkpoint.latest_totals(out)
            self.assertEqual(Decimal(aggregate["parent_lower_usd"]), Decimal(5))
            self.assertEqual(Decimal(aggregate["parent_upper_usd"]), Decimal(8))
            self.assertEqual(Decimal(aggregate["all_in_upper_usd"]), Decimal(8))
            self.assertEqual(aggregate["parent_usd"], aggregate["parent_lower_usd"])
            self.assertEqual(aggregate["tokens"]["cache_ttl_unknown_tokens"], 1000000)
            self.assertEqual((aggregate["priced_responses"], aggregate["unpriced_responses"]), (1, 1))
            self.assertFalse(aggregate["bounds_cover_all_responses"])
            self.assertFalse(aggregate["pricing_complete"])
            self.assertEqual(aggregate["unpriced_models"], {"claude-unknown": 1})
            self.assertEqual(aggregate["source_checkpoints"][0]["session_id"], "session")
            self.assertEqual(aggregate["selected_response_time_bounds"], {
                "first": "2026-09-29T00:00:00+00:00", "last": "2026-09-29T00:01:00+00:00",
                "without_timestamp": 0})
            source.write_text(json.dumps(uncertain) + "\n")
            known_only = root / "known-only"
            known_only.mkdir()
            (known_only / "snapshot.json").write_text(json.dumps(
                checkpoint.capture(source, "pilot-1", "2026-09-29T00:03:00Z", "final")))
            ttl_only = checkpoint.latest_totals(known_only)
            self.assertTrue(ttl_only["bounds_cover_all_responses"])
            self.assertFalse(ttl_only["pricing_complete"])
            self.assertEqual(ttl_only["unpriced_responses"], 0)
            certain = rec("2026-09-29T00:00:00Z", "r3", "m3", "claude-opus-5-5", 1,
                          stop="end_turn")
            source.write_text(json.dumps(certain) + "\n")
            exact_dir = root / "exact"
            exact_dir.mkdir()
            (exact_dir / "snapshot.json").write_text(json.dumps(
                checkpoint.capture(source, "pilot-1", "2026-09-29T00:04:00Z", "final")))
            exact = checkpoint.latest_totals(exact_dir)
            self.assertTrue(exact["pricing_complete"])
            self.assertEqual(exact["all_in_lower_usd"], exact["all_in_upper_usd"])

    def test_checkpoint_keeps_pair_identity_when_one_id_wins(self):
        checkpoint = load("usage_checkpoint_alias", HERE / "usage-checkpoint.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "session.jsonl"
            pair = rec("2026-09-29T00:00:00Z", "r", "m", "claude-opus-5-5", 2)
            alias = rec("2026-09-29T00:00:01Z", "r", "m", "claude-opus-5-5", 100)
            alias.pop("requestId")
            source.write_text(json.dumps(pair) + "\n" + json.dumps(alias) + "\n")
            doc = checkpoint.capture(source, "run", "2026-09-29T00:02:00Z", "final")
            self.assertEqual(doc["all_in"]["responses"], 1)
            self.assertEqual(doc["selected_responses"][0]["requestId"], "r")
            self.assertEqual(doc["selected_responses"][0]["message"]["usage"]["output_tokens"], 100)

    def test_cross_session_ambiguous_alias_prevents_complete_valuation(self):
        checkpoint = load("usage_checkpoint_ambiguous", HERE / "usage-checkpoint.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "checkpoints"
            out.mkdir()
            alias = rec("2026-09-29T00:00:00Z", None, "shared", "claude-opus-5-5", 100)
            alias.pop("requestId")
            pairs = [rec("2026-09-29T00:00:01Z", "r1", "shared", "claude-opus-5-5", 1),
                     rec("2026-09-29T00:00:02Z", "r2", "shared", "claude-opus-5-5", 1)]
            for index, record in enumerate([alias] + pairs):
                source = root / ("session-%d.jsonl" % index)
                source.write_text(json.dumps(record) + "\n")
                (out / ("snapshot-%d.json" % index)).write_text(json.dumps(
                    checkpoint.capture(source, "run", "2026-09-29T00:03:00Z", "final")))
            aggregate = checkpoint.latest_totals(out)
            self.assertEqual(aggregate["all_in_responses"], 2)
            self.assertEqual(aggregate["unpriced_responses"], 0)
            self.assertEqual(aggregate["quality"]["ambiguous_identities"], 1)
            self.assertEqual(aggregate["excluded_ambiguous_observations"], 1)
            self.assertEqual(aggregate["coverage_gap_observations"], 1)
            self.assertFalse(aggregate["bounds_cover_all_responses"])
            self.assertFalse(aggregate["pricing_complete"])

    def test_trend_uses_final_record_day_and_global_parent_child_selection(self):
        spec = importlib.util.spec_from_file_location("usage_trend", HERE / "usage-trend.py")
        trend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(trend)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parent = root / "session.jsonl"
            child = root / "session" / "subagents" / "agent.jsonl"
            child.parent.mkdir(parents=True)
            early = rec("2026-09-30T06:59:59Z", "r1", "m1", "claude-opus-5-5", 2)
            late = rec("2026-09-30T07:00:01Z", "r1", "m1", "claude-opus-5-5", 100,
                       stop="end_turn")
            parent.write_text(json.dumps(early) + "\n" + json.dumps(late) + "\n")
            child.write_text(json.dumps(early) + "\n" + json.dumps(rec(
                "2026-09-30T07:00:02Z", "r2", "m2", "claude-sonnet-5", 100,
                cache_5m=1000000)) + "\n")
            old_root = trend.ROOT
            trend.ROOT = root
            try:
                selected = trend.selected_responses()
                self.assertEqual(len(selected.selected), 2)
                self.assertEqual(selected.conflicts, 0)
                days = trend.scan()
                self.assertNotIn("2026-09-29", days)
                self.assertIn("2026-09-30", days)
                self.assertEqual(sum(d["requests"] for d in days.values()), 2)
                self.assertEqual(days["2026-09-30"]["sessions"], 1)
                self.assertAlmostEqual(sum(d["cost"] for d in days.values()), 2.503, places=3)
                weeks = trend.scan_weeks()
                self.assertEqual(sum(w["reqs_main"] for w in weeks.values()), 1)
                self.assertEqual(sum(w["requests"] for w in weeks.values()), 2)
                self.assertAlmostEqual(sum(w["cost_sub"] for w in weeks.values()), 2.501, places=3)
            finally:
                trend.ROOT = old_root

    def test_trend_merge_retains_unknown_ttl_range_and_unpriced_coverage(self):
        trend = load("usage_trend_merge_accounting", HERE / "usage-trend.py")
        with tempfile.TemporaryDirectory() as tmp:
            old_hist = trend.HIST_DIR
            trend.HIST_DIR = Path(tmp)
            try:
                snapshot = {"2026-09-30": {"rate_card": RATE_CARD_VERSION,
                    "cost": 5.0, "cost_upper": 8.0,
                    "cache_ttl_unknown_tokens": 1000000, "unpriced_responses": 2,
                    "requests": 1, "sessions": 1}}
                (Path(tmp) / "daily-v2-test.json").write_text(json.dumps(snapshot))
                merged = trend.merged_history()["2026-09-30"]
                self.assertEqual((merged["cost"], merged["cost_upper"]), (5, 8))
                self.assertEqual(merged["cache_ttl_unknown_tokens"], 1000000)
                self.assertEqual(merged["unpriced_responses"], 2)
            finally:
                trend.HIST_DIR = old_hist


if __name__ == "__main__":
    unittest.main()
