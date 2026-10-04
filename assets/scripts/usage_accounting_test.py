"""Synthetic edge cases and the preserved, sanitized recent-cohort arithmetic."""
import hashlib
import json
import importlib.util
import io
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta
from decimal import Decimal
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import usage_accounting
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
                                  "inference_geo": "global",
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
        unknown_geo = price_usage(dict(plain, inference_geo="not_available"),
                                  "claude-opus-5-5")
        self.assertEqual((unknown_geo["lower_usd"], unknown_geo["upper_usd"]),
                         (Decimal(4), Decimal("4.4")))
        self.assertTrue(unknown_geo["geography_uncertain"])
        missing_geo = price_usage(plain, "claude-opus-5-5")
        self.assertEqual((missing_geo["lower_usd"], missing_geo["upper_usd"]),
                         (Decimal(4), Decimal("4.4")))
        self.assertTrue(missing_geo["geography_uncertain"])
        legacy_geo = price_usage(dict(plain, inference_geo="not_available"),
                                 "claude-haiku-4-5")
        self.assertEqual(legacy_geo["lower_usd"], legacy_geo["upper_usd"])
        self.assertFalse(legacy_geo["geography_uncertain"])
        ttl_geo = price_usage({"cache_creation_input_tokens": 1000000,
                               "inference_geo": "not_available"}, "claude-sonnet-5-5")
        self.assertEqual((ttl_geo["lower_usd"], ttl_geo["upper_usd"]),
                         (Decimal("2.50"), Decimal("4.4")))
        with self.assertRaises(ValueError):
            price_usage(dict(plain, inference_geo="eu"), "claude-opus-5-5")
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

    def test_real_pilot_metadata_bounds_unknown_geo_and_keeps_tokens(self):
        fixture = json.loads((HERE / "fixtures" /
                              "usage-pilot-geo-not-available-2026-10-01.json").read_text())
        checkpoint = load("usage_checkpoint_pilot_geo", HERE / "usage-checkpoint.py")
        pace = load("usage_pace_pilot_geo", HERE / "usage-pace.py")
        trend = load("usage_trend_pilot_geo", HERE / "usage-trend.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "projects" / "pilot.jsonl"
            source.parent.mkdir()
            lines = []
            for index, counters in enumerate(fixture["responses"]):
                usage = {**counters, "speed": fixture["speed"],
                         "service_tier": fixture["service_tier"],
                         "inference_geo": fixture["inference_geo"],
                         "cache_creation": {"ephemeral_1h_input_tokens":
                                            counters["cache_creation_input_tokens"],
                                            "ephemeral_5m_input_tokens": 0}}
                final = {"type": "assistant", "timestamp":
                         f"2026-10-01T17:07:{index:02d}Z", "requestId": f"r{index}",
                         "message": {"id": f"m{index}", "model": fixture["model"],
                                     "stop_reason": "end_turn", "usage": usage}}
                partial = json.loads(json.dumps(final))
                partial["message"]["stop_reason"] = None
                partial["message"]["usage"]["output_tokens"] = 1
                lines.extend([partial, final, final, final])
            source.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n"
                                      for row in lines))
            doc = checkpoint.capture(source, "pilot", "2026-10-01T17:09:00Z", "final")
            self.assertEqual((doc["parent"]["responses"], doc["children"]["responses"]), (6, 0))
            self.assertEqual(doc["quality"]["geography_unknown_responses"], 6)
            self.assertTrue(doc["tokens_cover_selected_responses"])
            out = root / "checkpoints"
            out.mkdir()
            (out / "pilot.json").write_text(json.dumps(doc))
            aggregate = checkpoint.latest_totals(out)
            self.assertEqual((aggregate["all_in_responses"], aggregate["unpriced_responses"]),
                             (6, 0))
            self.assertEqual((aggregate["all_in_lower_usd"], aggregate["all_in_upper_usd"]),
                             (fixture["expected_global_lower_usd"],
                              fixture["expected_us_only_upper_usd"]))
            self.assertTrue(aggregate["bounds_cover_all_responses"])
            self.assertFalse(aggregate["pricing_complete"])
            self.assertTrue(aggregate["tokens_cover_selected_responses"])
            self.assertEqual(aggregate["quality"]["geography_unknown_responses"], 6)
            self.assertEqual(aggregate["tokens"]["input_tokens"], 12)
            self.assertEqual(aggregate["tokens"]["output_tokens"], 8525)
            self.assertEqual(aggregate["tokens"]["cache_1h_tokens"], 112840)
            self.assertEqual(aggregate["tokens"]["cache_read_input_tokens"], 388843)
            self.assertEqual(aggregate["tokens"]["cache_ttl_unknown_tokens"], 0)

            pace.ROOT = source.parent
            pace.HIST = root / "history"
            pace.CACHE = pace.HIST / "pace-cache.json"
            totals = pace.scan_detail("2026-10-07", force=True)[0]
            self.assertEqual(totals["geo_unknown_responses"], 6)
            self.assertEqual(totals["unpriced_responses"], 0)
            self.assertAlmostEqual(totals["all"], float(fixture["expected_global_lower_usd"]))

            trend.ROOT = source.parent
            daily = trend.scan()
            weekly = trend.scan_weeks()
            self.assertEqual(sum(row["geo_unknown_responses"] for row in daily.values()), 6)
            self.assertEqual(sum(row["geo_unknown_responses"] for row in weekly.values()), 6)
            self.assertGreater(sum(row["cost_upper"] for row in daily.values()),
                               sum(row["cost"] for row in daily.values()))

            unknown = rec("2026-10-01T17:08:00Z", "ru", "mu", "claude-unknown", 7,
                          cache_read=13, stop="end_turn")
            source.write_text(json.dumps(unknown, separators=(",", ":")) + "\n")
            unpriced = checkpoint.capture(source, "pilot", "2026-10-01T17:10:00Z", "final")
            self.assertEqual(unpriced["all_in"]["priced_responses"], 0)
            self.assertEqual(unpriced["all_in"]["tokens"]["output_tokens"], 7)
            self.assertTrue(unpriced["tokens_cover_selected_responses"])
            (out / "pilot.json").write_text(json.dumps(unpriced))
            subtotal = checkpoint.latest_totals(out)
            self.assertEqual(subtotal["unpriced_responses"], 1)
            self.assertEqual(subtotal["tokens"]["output_tokens"], 7)
            self.assertFalse(subtotal["bounds_cover_all_responses"])
            unpriced_pace = pace.scan_detail("2026-10-07", force=True)[0]
            self.assertEqual(unpriced_pace["unpriced_responses"], 1)
            self.assertEqual(unpriced_pace["all_raw"], 20)
            self.assertAlmostEqual(unpriced_pace["all_ieq"], 36.3)
            unpriced_daily = trend.scan()
            unpriced_weekly = trend.scan_weeks()
            self.assertEqual(sum(row["output_tokens"] for row in unpriced_daily.values()), 7)
            self.assertEqual(sum(row["cache_read_tokens"] for row in unpriced_daily.values()), 13)
            self.assertEqual(sum(row["ctx_main"] for row in unpriced_weekly.values()), 13)
            self.assertEqual(sum(row["reqs_main"] for row in unpriced_weekly.values()), 1)
            partial_unknown = rec("2026-10-01T17:08:00Z", "ru", "mu",
                                  "claude-unknown", 2, cache_read=13)
            source.write_text(json.dumps(partial_unknown, separators=(",", ":")) + "\n")
            pace.scan_detail("2026-10-07", force=True)
            with source.open("a") as stream:
                stream.write(json.dumps(unknown, separators=(",", ":")) + "\n")
            completed_tokens = pace.scan_detail("2026-10-07")[0]
            self.assertEqual(completed_tokens["all_raw"], 20)
            self.assertEqual(completed_tokens["unpriced_responses"], 1)
            missing = rec("2026-10-01T17:08:00Z", "rm", "mm", "claude-sonnet-5-5", 7,
                          cache_read=13, stop="end_turn")
            missing["message"]["usage"].pop("inference_geo")
            source.write_text(json.dumps(missing, separators=(",", ":")) + "\n")
            missing_pace = pace.scan_detail("2026-10-07", force=True)[0]
            self.assertEqual(missing_pace["geo_unknown_responses"], 1)
            pace.read_readings = lambda: []
            pace._plan_raw = lambda: []
            def no_anchor(*args, **kwargs):
                raise AssertionError("missing geography must not seed a derived anchor")
            pace.meter_offset = no_anchor
            live = pace.pace(now=pace.datetime.fromisoformat("2026-10-01T17:10:00+00:00"))
            self.assertTrue(live["cost_guidance_unavailable"])
            self.assertIsNone(live["need_per_hour"])
            self.assertEqual(live["warnings"], [])
            unknown["message"]["usage"]["output_tokens"] = -1
            source.write_text(json.dumps(unknown, separators=(",", ":")) + "\n")
            invalid = checkpoint.capture(source, "pilot", "2026-10-01T17:11:00Z", "final")
            self.assertEqual(invalid["quality"]["invalid_token_responses"], 1)
            self.assertFalse(invalid["tokens_cover_selected_responses"])

    def test_incomplete_cost_coverage_suppresses_pace_guidance(self):
        pace = load("usage_pace_incomplete", HERE / "usage-pace.py")
        for cause in ("unpriced_responses", "unidentified_responses",
                      "geo_unknown_responses", "cache_ttl_unknown_tokens"):
            p = {"source": "live", "sd": 19, "fh": 0,
                 "sample_at": "2026-10-01T17:00:00Z", "sample_age_min": 5,
                 "spend": 0.61, "hours_to_reset": 3, "stale": False,
                 "fable_reading": None, "rate": 10, "rate_hi": 11,
                 "usd_left": 810, "usd_left_hi": 891,
                 "hours_to_wall": 1, "hours_to_wall_hi": 1.1,
                 "landing": 50, "landing_hi": 55,
                 "need_per_hour": 270, "need_per_hour_hi": 297,
                 "pct_now": 19, "pct_now_hi": 20,
                 "burn_1h": 5, "burn_3h": 6,
                 "unpriced_responses": 0, "unidentified_responses": 0,
                 "geo_unknown_responses": 0, "cache_ttl_unknown_tokens": 0}
            p[cause] = 6
            self.assertEqual(pace.warnings_for(p), [], cause)
            pace.suppress_incomplete_cost_guidance(p)
            self.assertTrue(p["cost_guidance_unavailable"])
            for field in ("rate", "usd_left", "hours_to_wall", "landing",
                          "need_per_hour", "pct_now", "burn_1h", "burn_3h"):
                self.assertIsNone(p[field], (cause, field))
            self.assertEqual(pace.warnings_for(p), [])
            line = pace.fmt(p)
            self.assertIn("sd 19%", line)
            self.assertIn("cost-derived burn, landing, wall and need unavailable", line)
            self.assertNotIn("→ lands", line)
            self.assertNotIn("need $", line)
        pace.scan_detail = lambda week, force=False: ({"all": 0.61,
            "unpriced_responses": 6, "geo_unknown_responses": 0}, {})
        pace.read_readings = lambda: []
        pace._plan_raw = lambda: []
        def no_anchor(*args, **kwargs):
            raise AssertionError("an incomplete cost basis must not persist a derived anchor")
        pace.meter_offset = no_anchor
        p = pace.pace(now=pace.datetime.fromisoformat("2026-10-01T17:00:00+00:00"))
        self.assertEqual(p["source"], "unavailable")
        self.assertTrue(p["cost_guidance_unavailable"])
        self.assertIsNone(p["need_per_hour"])
        self.assertEqual(p["warnings"], [])
        self.assertIn("no direct meter sample", pace.fmt(p))

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

    def test_trend_week_readout_names_geography_range(self):
        trend = load("usage_trend_geo_readout", HERE / "usage-trend.py")
        with tempfile.TemporaryDirectory() as tmp:
            trend.HIST_DIR = Path(tmp)
            trend.machine_name = lambda: "test"
            week = trend.meter_week_close(trend.datetime.now().astimezone())
            record = {"rate_card": RATE_CARD_VERSION, "cost": .6144,
                      "cost_upper": .6758, "requests": 6,
                      "geo_unknown_responses": 6, "unpriced_responses": 0}
            trend.scan_weeks = lambda: {week: record}
            trend.merged_weekly = lambda fresh, machine, write: fresh
            original_argv = sys.argv
            try:
                for args in (["usage-trend.py", "--week", "--oneline"],
                             ["usage-trend.py", "--week"]):
                    sys.argv = args
                    output = io.StringIO()
                    with redirect_stdout(output):
                        trend.week_main()
                    self.assertIn("6 geography-unknown responses", output.getvalue())
                    self.assertIn("$0.61–$0.68", output.getvalue())
                trend.VAULT_WEEKS_MD = Path(tmp) / "weeks.md"
                trend.write_vault_weeks(trend.week_rows({week: record}, 1), week)
                self.assertIn("$0.61–$0.68", trend.VAULT_WEEKS_MD.read_text())
                self.assertEqual(trend.week_amount(.000002, .0000022),
                                 "$0.0000020–$0.0000022")
            finally:
                sys.argv = original_argv

    def test_trend_context_average_includes_unpriced_observed_responses(self):
        trend = load("usage_trend_unpriced_context", HERE / "usage-trend.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trend.ROOT = root / "projects"
            trend.ROOT.mkdir()
            trend.HIST_DIR = root / "history"
            trend.machine_name = lambda: "test"
            source = trend.ROOT / "pilot.jsonl"
            unknown = rec("2026-10-01T17:08:00Z", "ru", "mu", "claude-unknown", 7,
                          cache_read=300000, stop="end_turn")
            priced = rec("2026-10-01T17:09:00Z", "rp", "mp", "claude-sonnet-5-5", 9,
                         cache_read=100000, stop="end_turn")
            original_argv = sys.argv
            try:
                sys.argv = ["usage-trend.py", "--no-sync"]
                for records, observed, average in (([unknown], 1, 300),
                                                   ([unknown, priced], 2, 200)):
                    source.write_text("".join(json.dumps(row) + "\n" for row in records))
                    output = io.StringIO()
                    with redirect_stdout(output):
                        trend.main()
                    row = trend.merged_history()["2026-10-01"]
                    self.assertEqual(row["token_observed_responses"], observed)
                    self.assertEqual(row["cache_read_tokens"], average * observed * 1000)
                    self.assertRegex(output.getvalue(),
                                     rf"2026-10-01[^\n]*\s{average}K")
            finally:
                sys.argv = original_argv


# A synthetic session that was split across two project dirs by a worktree recycle
# (skill-templates#377). Ids are made up; nothing here is read from a real transcript.
SPLIT = "5ae4397b-0000-4000-8000-00000000cafe"
FOREIGN = "0d2a7f2c-aaaa-4bbb-8ccc-dddddddddddd"


def write_records(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records))


def priced_child(tag):
    """One child response priced at exactly 2.501 USD (1M 5m-cache writes + 100 output)."""
    return rec("2026-09-29T00:00:03Z", "r-" + tag, "m-" + tag, "claude-sonnet-5", 100,
               cache_5m=1000000, stop="end_turn")


def priced_parent(tag):
    """One parent response priced at exactly 0.002 USD."""
    return rec("2026-09-29T00:00:01Z", "r-" + tag, "m-" + tag, "claude-opus-5-5", 100,
               stop="end_turn")


class SessionFixture(unittest.TestCase):
    """A temporary HOME, so no test reads or writes the real ~/.claude."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "home"
        self.projects = self.home / ".claude" / "projects"
        self.projects.mkdir(parents=True)
        patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)


def unreadable(test, path):
    """chmod `path` to 0 for the test, restoring it so the temporary tree can be removed."""
    mode = path.stat().st_mode & 0o777
    path.chmod(0)
    test.addCleanup(path.chmod, mode)


needs_non_root = unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads any file")


class ScanFixture(SessionFixture):
    """Both scripts that read a session's children, run against the temporary HOME."""
    def recycled_session(self, sid=SPLIT):
        """Main transcript and one child in the NEW dir, the earlier children in the OLD
        dir (no main transcript there), and a foreign session living in the old dir."""
        # The NEW dir sorts AFTER the old one, so discovery order (the transcript's own
        # dir first) and sorted order differ and the coverage sort is observable.
        new, old = self.projects / "-demo-zzz-new", self.projects / "-demo-aaa-old"
        write_records(new / (sid + ".jsonl"), [priced_parent(sid + "p1"), priced_parent(sid + "p2")])
        write_records(new / sid / "subagents" / "agent-new.jsonl", [priced_child(sid + "n1")])
        write_records(old / sid / "subagents" / "agent-a.jsonl",
                      [priced_child(sid + "a1"), priced_child(sid + "a2")])
        write_records(old / sid / "subagents" / "workflows" / "wf_x" / "agent-b.jsonl",
                      [priced_child(sid + "b1")])
        write_records(old / (FOREIGN + ".jsonl"), [priced_parent("fp")])
        write_records(old / FOREIGN / "subagents" / "agent-x.jsonl", [priced_child("fx")])
        return new, old

    def run_checkpoint(self, *args):
        return subprocess.run([sys.executable, str(HERE / "usage-checkpoint.py"), *args],
                              capture_output=True, text=True)

    def run_row(self, session):
        # no gh on the PATH: a fixture with no PR references never asks, and must not
        env = dict(os.environ, PATH="/usr/bin:/bin")
        return subprocess.run([sys.executable, str(HERE / "usage-benchmark-row.py"), str(session)],
                              capture_output=True, text=True, env=env)

    def capture(self, session):
        done = self.run_checkpoint("--session", str(session))
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout), done.stderr

    @staticmethod
    def checkpoint_figures(doc):
        return {"files": len(doc["source_coverage"]) - 1,
                "parent": doc["parent"]["responses"], "children": doc["children"]["responses"],
                "lower": Decimal(doc["children"]["lower_usd"]),
                "upper": Decimal(doc["children"]["upper_usd"])}

    @staticmethod
    def row_figures(done):
        counts = re.search(r"parent (\d+), children (\d+); child transcript files (\d+)", done.stderr)
        usd = re.search(r"children ([0-9.]+)–([0-9.]+); all-in", done.stderr)
        return {"files": int(counts.group(3)), "parent": int(counts.group(1)),
                "children": int(counts.group(2)),
                "lower": Decimal(usd.group(1)), "upper": Decimal(usd.group(2))}


class SessionScopedCheckpointTests(ScanFixture):
    def test_children_in_every_project_dir_are_priced(self):
        new, old = self.recycled_session()
        doc, err = self.capture(SPLIT)
        paths = [c["path"] for c in doc["source_coverage"]]
        self.assertEqual(len(paths), 4)
        self.assertEqual(paths[0], str(new / (SPLIT + ".jsonl")))
        self.assertEqual(paths[1:], sorted([
            str(new / SPLIT / "subagents" / "agent-new.jsonl"),
            str(old / SPLIT / "subagents" / "agent-a.jsonl"),
            str(old / SPLIT / "subagents" / "workflows" / "wf_x" / "agent-b.jsonl")],
            key=lambda f: Path(f).parts))
        self.assertEqual((doc["parent"]["responses"], doc["children"]["responses"]), (2, 4))
        self.assertEqual(Decimal(doc["children"]["lower_usd"]), Decimal("10.004"))
        self.assertEqual(Decimal(doc["children"]["upper_usd"]), Decimal("10.004"))
        dirs = sorted(os.path.realpath(d) for d in (new, old))
        self.assertEqual(doc["session_project_dirs"], dirs)
        self.assertEqual(doc["quality"]["split_project_dirs"], 2)
        self.assertEqual(err.count("WARNING:"), 1)
        self.assertEqual(err.splitlines()[1:3],
                         [f"  {d}" + ("  (main transcript)" if d == os.path.realpath(new) else "")
                          for d in dirs])
        # The same session addressed by its transcript path reads the same figure.
        by_path, _ = self.capture(new / (SPLIT + ".jsonl"))
        self.assertEqual(by_path["children"], doc["children"])
        self.assertEqual(by_path["source_coverage"], doc["source_coverage"])

    def test_a_foreign_session_in_the_same_dir_keeps_only_its_own_files(self):
        new, old = self.recycled_session()
        doc, err = self.capture(FOREIGN)
        self.assertEqual([c["path"] for c in doc["source_coverage"]],
                         [str(old / (FOREIGN + ".jsonl")),
                          str(old / FOREIGN / "subagents" / "agent-x.jsonl")])
        self.assertEqual((doc["parent"]["responses"], doc["children"]["responses"]), (1, 1))
        self.assertEqual(Decimal(doc["children"]["lower_usd"]), Decimal("2.501"))
        self.assertEqual(doc["session_project_dirs"], [os.path.realpath(old)])
        self.assertEqual(doc["quality"]["split_project_dirs"], 0)
        self.assertNotIn("WARNING", err)

    def test_a_split_warning_goes_to_stderr_only_and_checkpoints_with_session_project_dirs_still_aggregate(self):
        self.recycled_session()
        out = self.root / "checkpoints"
        for session in (SPLIT, FOREIGN):
            done = self.run_checkpoint("--session", session, "--out-dir", str(out),
                                       "--capture-at", "2026-09-29T00:05:00Z",
                                       "--status", "final")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(len(done.stdout.splitlines()), 1)
            self.assertTrue(Path(done.stdout.strip()).is_file())
            self.assertEqual("WARNING" in done.stderr, session == SPLIT)
        saved = [json.loads(p.read_text()) for p in sorted(out.glob("*.json"))]
        self.assertTrue(all("session_project_dirs" in d for d in saved))
        done = self.run_checkpoint("--aggregate-dir", str(out))
        self.assertEqual(done.returncode, 0, done.stderr)
        aggregate = json.loads(done.stdout)
        self.assertEqual((aggregate["sessions"], aggregate["children_responses"]), (2, 5))
        self.assertEqual(Decimal(aggregate["children_usd"]), Decimal("12.505"))

    def test_an_empty_extra_uuid_folder_is_not_a_split(self):
        new = self.projects / "-demo-new"
        write_records(new / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(new / SPLIT / "subagents" / "agent-new.jsonl", [priced_child("n1")])
        (self.projects / "-demo-empty" / SPLIT / "subagents").mkdir(parents=True)
        write_records(self.projects / "-demo-meta" / SPLIT / "subagents" / "meta.json", [{}])
        doc, err = self.capture(SPLIT)
        self.assertEqual(len(doc["source_coverage"]), 2)
        self.assertEqual(doc["session_project_dirs"], [os.path.realpath(new)])
        self.assertEqual(doc["quality"]["split_project_dirs"], 0)
        self.assertNotIn("WARNING", err)

    def test_explicit_path_outside_the_projects_dir_keeps_its_sibling_children(self):
        outside = self.root / "outside"
        write_records(outside / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(outside / SPLIT / "subagents" / "agent.jsonl", [priced_child("o1")])
        doc, err = self.capture(outside / (SPLIT + ".jsonl"))
        self.assertEqual(len(doc["source_coverage"]), 2)
        self.assertEqual(doc["children"]["responses"], 1)
        self.assertEqual(doc["session_project_dirs"], [os.path.realpath(outside)])
        self.assertEqual(doc["quality"]["split_project_dirs"], 0)
        self.assertNotIn("WARNING", err)

    def test_one_dir_reached_through_two_roots_is_counted_once(self):
        new = self.projects / "-demo-new"
        write_records(new / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(new / SPLIT / "subagents" / "agent.jsonl", [priced_child("n1")])
        alias = self.projects / "-demo-alias"
        alias.mkdir()
        os.symlink(new / SPLIT, alias / SPLIT)
        doc, err = self.capture(SPLIT)
        self.assertEqual(len(doc["source_coverage"]), 2)
        self.assertEqual(doc["children"]["responses"], 1)
        self.assertEqual(doc["session_project_dirs"], [os.path.realpath(new)])
        self.assertEqual(doc["quality"]["split_project_dirs"], 0)
        self.assertNotIn("WARNING", err)

    def test_children_only_in_the_old_dir_still_split_and_count_every_file(self):
        # the commonest recycle shape: the dir the transcript moved to holds no child at all
        new, old = self.projects / "-demo-new", self.projects / "-demo-old"
        write_records(new / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(old / SPLIT / "subagents" / "agent-a.jsonl", [priced_child("a1")])
        write_records(old / SPLIT / "subagents" / "agent-b.jsonl",
                      [priced_child("b1"), priced_child("b2")])
        doc, err = self.capture(SPLIT)
        self.assertEqual(len(doc["source_coverage"]), 3)
        self.assertEqual(doc["children"]["responses"], 3)
        dirs = sorted(os.path.realpath(d) for d in (new, old))
        self.assertEqual(doc["session_project_dirs"], dirs)
        self.assertEqual(doc["quality"]["split_project_dirs"], 2)
        self.assertIn("found in 2 project dirs", err)
        self.assertEqual(err.splitlines()[1:3],
                         [f"  {d}" + ("  (main transcript)" if d == os.path.realpath(new) else "")
                          for d in dirs])

    def test_a_three_dir_session_lists_every_dir_and_says_three(self):
        mid, aaa, zzz = (self.projects / n for n in ("-demo-mid", "-demo-aaa", "-demo-zzz"))
        write_records(mid / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(aaa / SPLIT / "subagents" / "agent-a.jsonl", [priced_child("a1")])
        write_records(zzz / SPLIT / "subagents" / "agent-z.jsonl", [priced_child("z1")])
        doc, err = self.capture(SPLIT)
        dirs = [os.path.realpath(d) for d in (aaa, mid, zzz)]
        self.assertEqual(doc["session_project_dirs"], dirs)
        self.assertEqual(doc["quality"]["split_project_dirs"], 3)
        self.assertIn("found in 3 project dirs", err)
        self.assertEqual(err.splitlines()[1:4],
                         [f"  {dirs[0]}", f"  {dirs[1]}  (main transcript)", f"  {dirs[2]}"])

    def test_coverage_is_in_path_component_order_not_string_order(self):
        # `-Users-x-repo` beside `-Users-x-repo--claude-worktrees-w1`: by components the
        # shorter name comes first, as a string the worktree does ("-" sorts below "/")
        repo = self.projects / "-Users-x-repo"
        worktree = self.projects / "-Users-x-repo--claude-worktrees-w1"
        write_records(repo / (SPLIT + ".jsonl"), [priced_parent("p1")])
        write_records(repo / SPLIT / "subagents" / "agent-r.jsonl", [priced_child("r1")])
        write_records(worktree / SPLIT / "subagents" / "agent-w.jsonl", [priced_child("w1")])
        write_records(worktree / SPLIT / "subagents" / "agent-w2.jsonl", [priced_child("w2")])
        doc, _ = self.capture(SPLIT)
        paths = [c["path"] for c in doc["source_coverage"]][1:]
        self.assertEqual(paths, [str(repo / SPLIT / "subagents" / "agent-r.jsonl"),
                                 str(worktree / SPLIT / "subagents" / "agent-w.jsonl"),
                                 str(worktree / SPLIT / "subagents" / "agent-w2.jsonl")])
        self.assertNotEqual(paths, sorted(paths))      # the fixture can tell the two orders apart
        self.assertEqual(paths, sorted(paths, key=lambda f: Path(f).parts))

    def test_a_bad_byte_is_parsed_with_replacement_and_the_file_still_hashes_as_raw_bytes(self):
        main = self.projects / "-demo-new" / (SPLIT + ".jsonl")
        write_records(main, [priced_parent("p1")])
        child = main.with_suffix("") / "subagents" / "agent.jsonl"
        child.parent.mkdir(parents=True)
        good = lambda tag: (json.dumps(priced_child(tag)) + "\n").encode()
        raw = good("c1") + b"\xff\xfe not json\n" + good("c2") + b'{"x": "\xc3'   # cut inside a 2-byte char
        child.write_bytes(raw)
        doc, _ = self.capture(main)
        self.assertEqual(doc["children"]["responses"], 2)
        entry = doc["source_coverage"][1]
        self.assertEqual((entry["bytes"], entry["sha256"]),
                         (len(raw), hashlib.sha256(raw).hexdigest()))


class ChildScanAgreementTests(ScanFixture):
    """usage-checkpoint.py and usage-benchmark-row.py read children through one walker, so
    for the same session they read the same files and price the same children, or both
    refuse (skill-templates#377, first acceptance item)."""
    def sid(self, index):
        return "7e7e7e7e-0000-4000-8000-%012d" % index

    def main_transcript(self, sid, project="-demo-new", parents=("p1",)):
        main = self.projects / project / (sid + ".jsonl")
        write_records(main, [priced_parent(sid + tag) for tag in parents])
        return main

    def subagents(self, sid, project="-demo-new"):
        path = self.projects / project / sid / "subagents"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def build_recycled(self, sid):
        return self.recycled_session(sid)[0] / (sid + ".jsonl")

    def build_old_only(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid, "-demo-old") / "agent-a.jsonl", [priced_child(sid + "a")])
        write_records(self.subagents(sid, "-demo-old") / "agent-b.jsonl",
                      [priced_child(sid + "b1"), priced_child(sid + "b2")])
        return main

    def build_three_dirs(self, sid):
        main = self.main_transcript(sid, "-demo-mid")
        write_records(self.subagents(sid, "-demo-aaa") / "agent-a.jsonl", [priced_child(sid + "a")])
        write_records(self.subagents(sid, "-demo-zzz") / "agent-z.jsonl", [priced_child(sid + "z")])
        return main

    def build_dir_named_jsonl(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "nested.jsonl" / "agent.jsonl", [priced_child(sid + "n")])
        return main

    def build_symlinked_dir(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "agent-real.jsonl", [priced_child(sid + "r")])
        write_records(self.root / "elsewhere" / "x.jsonl", [priced_child(sid + "x")])
        os.symlink(self.root / "elsewhere", self.subagents(sid) / "link.jsonl")
        return main

    def build_symlinked_file(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "agent-real.jsonl", [priced_child(sid + "r")])
        write_records(self.root / "elsewhere" / "target.jsonl", [priced_child(sid + "t")])
        os.symlink(self.root / "elsewhere" / "target.jsonl", self.subagents(sid) / "alias.jsonl")
        return main

    def build_dangling_symlink(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "agent-real.jsonl", [priced_child(sid + "r")])
        os.symlink(self.root / "missing.jsonl", self.subagents(sid) / "dangling.jsonl")
        return main

    def build_bad_byte(self, sid):
        main = self.main_transcript(sid)
        child = self.subagents(sid) / "agent.jsonl"
        good = lambda tag: (json.dumps(priced_child(sid + tag)) + "\n").encode()
        child.write_bytes(good("c1") + b"\xff\xfe\n" + good("c2"))
        return main

    def build_cut_tail(self, sid):
        main = self.projects / "-demo-new" / (sid + ".jsonl")
        write_records(main, [priced_parent(sid + "p1")])
        main.write_bytes(main.read_bytes() + b'{"type": "assistant", "x": "\xc3')
        child = self.subagents(sid) / "agent.jsonl"
        write_records(child, [priced_child(sid + "c1")])
        child.write_bytes(child.read_bytes() + b'{"x": "\xe2\x82')
        return main

    def build_unreadable_subdir(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "agent-real.jsonl", [priced_child(sid + "r")])
        write_records(self.subagents(sid) / "workflows" / "agent-w.jsonl", [priced_child(sid + "w")])
        unreadable(self, self.subagents(sid) / "workflows")
        return main

    def build_unreadable_root(self, sid):
        main = self.main_transcript(sid)
        write_records(self.subagents(sid) / "agent-real.jsonl", [priced_child(sid + "r")])
        unreadable(self, self.subagents(sid))
        return main

    def build_unreadable_old_root(self, sid):
        main = self.build_recycled(sid)
        unreadable(self, self.projects / "-demo-aaa-old" / sid / "subagents")
        return main

    def test_both_scripts_read_the_same_files_and_agree_on_the_children(self):
        agree = [("recycled", self.build_recycled, 3, 4), ("old dir only", self.build_old_only, 2, 3),
                 ("three dirs", self.build_three_dirs, 2, 2),
                 ("a directory named x.jsonl is descended", self.build_dir_named_jsonl, 1, 1),
                 ("a symlinked directory is not followed", self.build_symlinked_dir, 1, 1),
                 ("a symlinked file counts", self.build_symlinked_file, 2, 2),
                 ("a bad byte is not a refusal", self.build_bad_byte, 1, 2),
                 ("a line cut inside a multi-byte character", self.build_cut_tail, 1, 1)]
        refuse = [("a dangling symlink", self.build_dangling_symlink, False),
                  ("an unreadable subdirectory", self.build_unreadable_subdir, True),
                  ("an unreadable root", self.build_unreadable_root, True),
                  ("an unreadable root in the old dir", self.build_unreadable_old_root, True)]
        for index, (name, build, files, children) in enumerate(agree):
            with self.subTest(name):
                main = build(self.sid(index))
                cp, row = self.run_checkpoint("--session", str(main)), self.run_row(main)
                self.assertEqual((cp.returncode, row.returncode), (0, 0), (cp.stderr, row.stderr))
                figures = self.checkpoint_figures(json.loads(cp.stdout))
                self.assertEqual(figures, self.row_figures(row))
                self.assertEqual((figures["files"], figures["children"]), (files, children))
        for index, (name, build, needs_chmod) in enumerate(refuse, len(agree)):
            if needs_chmod and hasattr(os, "geteuid") and os.geteuid() == 0:
                continue                       # root reads any file
            with self.subTest(name):
                main = build(self.sid(index))
                cp, row = self.run_checkpoint("--session", str(main)), self.run_row(main)
                self.assertEqual((cp.returncode, cp.stdout), (1, ""))
                self.assertTrue(cp.stderr.startswith("REFUSE:"), cp.stderr)
                self.assertEqual((row.returncode, row.stdout), (1, ""))
                self.assertIn("REFUSE: cannot measure subagents:", row.stderr)


class SessionChildFilesTests(SessionFixture):
    def tree(self, *names):
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n")
        return [str(self.root / n) for n in names]

    def test_files_sort_globally_by_path_components_across_every_root(self):
        self.tree("z-root/m.jsonl", "a-root/a/x.jsonl", "a-root/a-b.jsonl")
        roots = [str(self.root / "z-root"), str(self.root / "a-root")]      # not in sorted order
        files, holding = usage_accounting.session_child_files(roots)
        self.assertEqual(files, [str(self.root / "a-root" / "a" / "x.jsonl"),
                                 str(self.root / "a-root" / "a-b.jsonl"),
                                 str(self.root / "z-root" / "m.jsonl")])
        self.assertEqual(files, sorted(files, key=lambda f: Path(f).parts))
        self.assertNotEqual(files, sorted(files))      # string order would swap the first two
        self.assertEqual(holding, roots)

    def test_only_roots_holding_a_jsonl_file_are_holders_in_input_order(self):
        self.tree("held-b/x.jsonl", "notes/readme.txt", "held-a/deep/er/y.jsonl")
        (self.root / "empty").mkdir()
        roots = [str(self.root / n) for n in ("held-b", "empty", "notes", "held-a")]
        files, holding = usage_accounting.session_child_files(roots)
        self.assertEqual(holding, [roots[0], roots[3]])
        self.assertEqual(len(files), 2)
        self.assertEqual(usage_accounting.session_child_files([]), ([], []))

    def test_a_dangling_symlink_is_listed_and_a_symlinked_directory_is_not_followed(self):
        self.tree("root/real.jsonl", "elsewhere/x.jsonl")
        os.symlink(self.root / "missing.jsonl", self.root / "root" / "dangling.jsonl")
        os.symlink(self.root / "elsewhere", self.root / "root" / "link.jsonl")
        files, _ = usage_accounting.session_child_files([str(self.root / "root")])
        self.assertEqual([Path(f).name for f in files], ["dangling.jsonl", "real.jsonl"])

    @needs_non_root
    def test_an_unreadable_directory_raises_instead_of_undercounting(self):
        self.tree("root/real.jsonl", "root/locked/hidden.jsonl")
        unreadable(self, self.root / "root" / "locked")
        with self.assertRaises(OSError):
            usage_accounting.session_child_files([str(self.root / "root")])


class SessionDiscoveryTests(SessionFixture):
    def roots(self, transcript):
        return usage_accounting.session_subagent_roots(transcript)

    def sub(self, project, session=SPLIT):
        path = self.projects / project / session / "subagents"
        path.mkdir(parents=True, exist_ok=True)
        return str(path)

    def test_roots_are_the_sibling_first_then_every_project_dir_sorted(self):
        for project in ("-z", "-m", "-c", "-a", "-k"):
            self.sub(project)
        self.sub("-a", FOREIGN)
        transcript = self.projects / "-c" / (SPLIT + ".jsonl")
        roots, main_dir = self.roots(str(transcript))
        self.assertEqual(roots, [self.sub("-c")] + [self.sub(p) for p in ("-a", "-k", "-m", "-z")])
        self.assertEqual(main_dir, os.path.realpath(self.projects / "-c"))
        self.assertEqual(self.roots(transcript), (roots, main_dir))

    def test_only_existing_directories_are_roots(self):
        (self.projects / "-p" / (SPLIT + "x") / "subagents").mkdir(parents=True)  # another id
        (self.projects / "-q" / SPLIT).mkdir(parents=True)                        # no subagents
        (self.projects / "-r" / SPLIT).mkdir(parents=True)
        (self.projects / "-r" / SPLIT / "subagents").write_text("a file, not a directory")
        roots, main_dir = self.roots(self.projects / "-p" / (SPLIT + ".jsonl"))
        self.assertEqual(roots, [])
        self.assertEqual(main_dir, os.path.realpath(self.projects / "-p"))

    def test_path_outside_the_projects_dir_keeps_its_sibling_with_no_projects_dir_at_all(self):
        outside = self.root / "outside"
        (outside / SPLIT / "subagents").mkdir(parents=True)
        with mock.patch.dict(os.environ, {"HOME": str(self.root / "no-such-home")}):
            roots, main_dir = self.roots(str(outside / (SPLIT + ".jsonl")))
        self.assertEqual(roots, [str(outside / SPLIT / "subagents")])
        self.assertEqual(main_dir, os.path.realpath(outside))

    def test_roots_dedupe_by_realpath_and_keep_the_first_spelling(self):
        real = self.sub("-new")
        alias = self.projects / "-alias"
        alias.mkdir()
        os.symlink(self.projects / "-new" / SPLIT, alias / SPLIT)
        roots, _ = self.roots(self.projects / "-new" / (SPLIT + ".jsonl"))
        self.assertEqual(roots, [real])
        # Addressed through the alias, the alias is the spelling that survives.
        roots, _ = self.roots(alias / (SPLIT + ".jsonl"))
        self.assertEqual(roots, [str(alias / SPLIT / "subagents")])

    def test_main_dir_is_the_realpath_of_the_transcripts_directory(self):
        real = self.projects / "-real"
        real.mkdir()
        os.symlink(real, self.projects / "-link")
        _, main_dir = self.roots(self.projects / "-link" / (SPLIT + ".jsonl"))
        self.assertEqual(main_dir, os.path.realpath(real))
        self.assertNotEqual(main_dir, str(self.projects / "-link"))

    def test_the_session_id_is_glob_escaped(self):
        # A metacharacter in the transcript's own name must match itself and nothing else.
        for stem, foreign in (("sess-*", "sess-other"), ("ab[cd]", "abc")):
            with self.subTest(stem=stem):
                literal = self.sub("-p", stem)
                self.sub("-p", foreign)
                roots, _ = self.roots(self.projects / "-p" / (stem + ".jsonl"))
                self.assertEqual(roots, [literal])
                other = self.sub("-q", stem)
                roots, _ = self.roots(self.projects / "-p" / (stem + ".jsonl"))
                self.assertEqual(roots, [literal, other])

    def test_a_transcript_with_no_id_in_its_name_has_no_roots(self):
        # a file literally called `.jsonl` has an empty id, which would widen the glob to
        # every projects/*/subagents
        (self.projects / "-p" / "subagents").mkdir(parents=True)
        (self.projects / "-q" / "subagents").mkdir(parents=True)
        roots, main_dir = self.roots(self.projects / "-p" / ".jsonl")
        self.assertEqual(roots, [])
        self.assertEqual(main_dir, os.path.realpath(self.projects / "-p"))

    def test_a_home_with_glob_metacharacters_still_finds_the_projects(self):
        home = self.root / "h[1]*"
        for project in ("-a", "-b"):
            (home / ".claude" / "projects" / project / SPLIT / "subagents").mkdir(parents=True)
        with mock.patch.dict(os.environ, {"HOME": str(home)}):
            roots, _ = self.roots(self.root / "elsewhere" / (SPLIT + ".jsonl"))
        self.assertEqual(roots, [str(home / ".claude" / "projects" / p / SPLIT / "subagents")
                                 for p in ("-a", "-b")])


class SplitRuleTests(SessionFixture):
    def holder(self, project):
        path = self.projects / project / SPLIT / "subagents"
        path.mkdir(parents=True, exist_ok=True)
        return str(path)

    def main_dir(self, project):
        return os.path.realpath(self.projects / project)

    def test_no_holder_or_only_the_main_dir_is_not_a_split(self):
        main = self.main_dir("-main")
        self.assertEqual(usage_accounting.split_project_dirs([], main), [])
        self.assertEqual(usage_accounting.split_project_dirs([self.holder("-main")], main), [])

    def test_a_child_in_another_dir_splits_and_names_the_main_dir_too(self):
        main = self.main_dir("-main")
        # Every child in the old dir: the main transcript's own dir holds none, and
        # still belongs in the listing.
        self.assertEqual(usage_accounting.split_project_dirs([self.holder("-old")], main),
                         sorted([main, self.main_dir("-old")]))
        self.assertEqual(usage_accounting.split_project_dirs(
            [self.holder("-main"), self.holder("-old")], main),
            sorted([main, self.main_dir("-old")]))

    def test_the_result_is_sorted_whatever_order_the_holders_arrive_in(self):
        names = ["-d%02d" % i for i in range(12)]
        main = self.main_dir("-d05")
        holders = [self.holder(n) for n in reversed(names)]
        want = sorted(self.main_dir(n) for n in names)
        self.assertEqual(usage_accounting.split_project_dirs(holders, main), want)
        self.assertEqual(usage_accounting.split_project_dirs(holders[::-1], main), want)

    def test_holders_compare_by_realpath_and_repeat_roots_count_once(self):
        main = self.main_dir("-main")
        link = self.projects / "-link"
        os.symlink(self.projects / "-main", link)
        via_link = str(link / SPLIT / "subagents")
        self.holder("-main")
        self.assertEqual(usage_accounting.split_project_dirs([via_link], main), [])
        old = self.holder("-old")
        self.assertEqual(usage_accounting.split_project_dirs([old, old, via_link], main),
                         sorted([main, self.main_dir("-old")]))


class TrendPartialPeriodTests(SessionFixture):
    """usage-trend.py after a rate-card change (skill-templates#392): a period whose transcripts
    are partly pruned is repriced from what is left, and must say so. The module is loaded under
    the temporary HOME, so its ROOT, HIST_DIR, vault file and machine name all live in it."""
    WEEK = "2026-09-02"                  # 2026-09-01 and 2026-09-02 (before 15:59 PT) are inside it
    TS = "2026-09-01T12:00:00Z"
    OLD_DOLLARS = 987654.5               # sentinel: a leak prints as $987,654 or 987654.50
    UNKNOWN_MODEL = "claude-unknown-9"   # not in RATES: its responses are read but unpriced

    def setUp(self):
        super().setUp()
        (self.home / ".claude" / "machine-name").write_text("test\n")
        self.trend = load("usage_trend_partial_periods", HERE / "usage-trend.py")
        self.assertEqual(self.trend.HIST_DIR, self.home / ".claude" / "usage-history")
        self.hist = self.trend.HIST_DIR
        self.hist.mkdir(parents=True)
        self.day = self.local_day(self.TS)

    @staticmethod
    def local_day(ts):
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")

    def transcript(self, name, count, ts=None, model="claude-opus-5-5"):
        write_records(self.trend.ROOT / "-demo" / (name + ".jsonl"),
                      [rec(ts or self.TS, "r-%s-%d" % (name, i), "m-%s-%d" % (name, i),
                           model, 100, stop="end_turn") for i in range(count)])

    def transcript_days(self, name, stamps):
        """One priced response at each timestamp."""
        write_records(self.trend.ROOT / "-demo" / (name + ".jsonl"),
                      [rec(ts, "r-%s-%d" % (name, i), "m-%s-%d" % (name, i), "claude-opus-5-5",
                           100, stop="end_turn") for i, ts in enumerate(stamps)])

    def earlier(self, kind, periods):
        """The pre-v2 snapshot file: no rate_card, only `requests`, and dollars from another card."""
        old = self.OLD_DOLLARS
        (self.hist / ("%s-test.json" % kind)).write_text(json.dumps({
            period: {"requests": float(count), "cost": old, "cost_main": old, "cost_sub": 0.0,
                     "tier_opus": old, "output_tokens": 1.0}
            for period, count in periods.items()}))

    def v2_file(self, kind, machine, records):
        (self.hist / ("%s-v2-%s.json" % (kind, machine))).write_text(json.dumps(records))

    def persisted(self, kind):
        return json.loads((self.hist / ("%s-v2-test.json" % kind)).read_text())

    def run_trend(self, entry, *argv):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["usage-trend.py", *argv]), \
                redirect_stdout(out), redirect_stderr(io.StringIO()):
            getattr(self.trend, entry)()
        return out.getvalue()

    def week(self, *argv):
        return self.run_trend("week_main", "--week", *argv)

    def daily(self, *argv):
        return self.run_trend("main", "--no-sync", *argv)

    def vault(self):
        return self.trend.VAULT_WEEKS_MD.read_text()

    def row(self, out, label):
        return next(line for line in out.splitlines() if line.startswith(label))

    def footer(self, out):
        return next(line for line in out.splitlines() if line.startswith("! = partial"))

    def block(self, out, heading):
        """The indented lines under `heading` (a console list)."""
        lines = out.splitlines()
        start = lines.index(heading) + 1
        end = start
        while end < len(lines) and lines[end].startswith("  "):
            end += 1
        return lines[start:end]

    def assertNoOldDollars(self, text):
        for needle in ("987,65", "987654"):
            self.assertNotIn(needle, text)

    # ---- both counts, in every view

    def test_a_week_rescanned_from_pruned_transcripts_is_marked_with_both_counts(self):
        self.transcript("s1", 40)
        self.earlier("weekly", {self.WEEK: 100})
        out = self.week("--write")
        self.assertTrue(self.row(out, self.WEEK).startswith(self.WEEK + " !"))
        self.assertIn("$0.08", self.row(out, self.WEEK))
        self.assertIn("! = partial: the scan read under 99.5% of the requests on record",
                      self.footer(out))
        self.assertIn(self.WEEK + " 40.0% (40 of 100)", self.footer(out))
        self.assertEqual(out.count(self.trend.READ_NOTE), 1)
        saved = self.persisted("weekly")[self.WEEK]
        self.assertEqual(saved["requests_not_rescanned"], 60)
        self.assertEqual((saved["requests"], saved["rate_card"]), (40, RATE_CARD_VERSION))
        self.assertAlmostEqual(saved["cost"], 0.08)
        vault = self.vault()
        self.assertIn("| %s (partial 40.0%%) |" % self.WEEK, vault)
        self.assertIn("- %s: read 40 of 100 requests on record (40.0%%); partial" % self.WEEK, vault)
        self.assertIn(RATE_CARD_VERSION, vault)
        self.assertIn("weekly-test.json", vault)
        for text in (out, vault, json.dumps(saved)):
            self.assertNoOldDollars(text)

    def test_a_day_rescanned_from_pruned_transcripts_is_marked_with_both_counts(self):
        self.transcript("s1", 40)
        self.earlier("daily", {self.day: 100})
        out = self.daily()
        self.assertTrue(self.row(out, self.day).startswith(self.day + "!"))
        footer = self.footer(out)
        self.assertIn("1 of the 1 day(s) shown were read at under 99.5% of the responses an earlier "
                      "snapshot recorded for that local day; 0 recorded day(s) in the whole history "
                      "have nothing read", footer)
        self.assertIn("transcripts were pruned", footer)
        self.assertIn("another timezone", footer)
        self.assertNotIn("no transcripts left", out)
        self.assertEqual(self.block(out, "partial days shown:"),
                         ["  %s: read 40 of 100 requests on record (40.0%%)" % self.day])
        self.assertEqual(out.count(self.trend.READ_NOTE), 1)
        self.assertEqual(out.splitlines()[-1].split(":")[0], "this machine")
        saved = self.persisted("daily")[self.day]
        self.assertEqual(saved["requests_not_rescanned"], 60)
        self.assertAlmostEqual(saved["cost"], 0.08)
        self.assertNoOldDollars(out + json.dumps(saved))
        merged = json.loads(self.daily("--json"))[self.day]
        self.assertEqual(merged["requests_not_rescanned"], 60)
        self.assertAlmostEqual(merged["cost"], 0.08)

    def test_a_period_read_in_full_is_not_marked_and_prints_as_before(self):
        self.transcript("s1", 40)
        def outputs():
            return (self.week("--write"), self.daily(), self.vault(),
                    self.persisted("weekly"), self.persisted("daily"))
        without = outputs()
        for path in self.hist.glob("*.json"):
            path.unlink()
        self.earlier("weekly", {self.WEEK: 40})
        self.earlier("daily", {self.day: 40})
        with_earlier = outputs()
        self.assertEqual(with_earlier[0], without[0])
        self.assertEqual(with_earlier[1], without[1])
        self.assertEqual(with_earlier[3:], without[3:])
        self.assertNotIn("requests_not_rescanned", json.dumps(with_earlier[3:]))
        self.assertNotIn("!", with_earlier[0] + with_earlier[1])
        # An earlier-card snapshot exists, so the vault says which card the figures are on.
        added = [line for line in with_earlier[2].splitlines() if line not in without[2].splitlines()]
        self.assertEqual(len(added), 1)
        self.assertIn(RATE_CARD_VERSION, added[0])
        self.assertNotIn("partial", with_earlier[2])

    def test_a_history_with_no_earlier_snapshot_never_mentions_coverage(self):
        self.transcript("s1", 40)
        text = (self.week("--write") + self.daily() + self.daily("--all") + self.daily("--json") +
                self.vault() + self.week("--oneline"))
        for word in ("partial", "not rescanned", "on record", "nothing read", "before", "!",
                     "requests_not_rescanned", "transcripts_left", "requests_read", RATE_CARD_VERSION):
            self.assertNotIn(word, text)

    # ---- the threshold

    def test_the_threshold_is_99_5_percent_and_a_marked_period_never_prints_as_it(self):
        weeks = (("a", "2026-09-01", 995), ("b", "2026-09-08", 998), ("c", "2026-09-15", 986),
                 ("d", "2026-09-22", 994))
        for name, day, count in weeks:
            self.transcript(name, count, day + "T12:00:00Z")
        self.earlier("weekly", {"2026-09-02": 1000, "2026-09-09": 1000, "2026-09-16": 1000,
                                "2026-09-23": 1000})
        out = self.week("--write")
        for week in ("2026-09-02", "2026-09-09"):         # 995 sits ON the threshold, 998 above it
            self.assertNotIn(" !", self.row(out, week))
        for week in ("2026-09-16", "2026-09-23"):
            self.assertIn(" !", self.row(out, week))
        footer = self.footer(out)
        self.assertIn("under 99.5% of the requests", footer)
        self.assertNotIn("under 100%", footer)
        self.assertIn("2026-09-16 98.6% (986 of 1,000)", footer)
        self.assertIn("2026-09-23 99.4% (994 of 1,000)", footer)    # floored: never "99.5%"
        self.assertNotIn("2026-09-02", footer)
        self.assertEqual(self.block(out, "shown weeks with a shortfall too small to mark:"),
                         ["  2026-09-02: read 995 of 1,000 requests on record (99.5%)",
                          "  2026-09-09: read 998 of 1,000 requests on record (99.8%)"])
        vault = self.vault()
        self.assertIn("| 2026-09-16 (partial 98.6%) |", vault)
        self.assertIn("| 2026-09-23 (partial 99.4%) |", vault)
        self.assertIn("| 2026-09-02 |", vault)
        self.assertIn("- 2026-09-02: read 995 of 1,000 requests on record (99.5%)\n", vault)
        self.assertIn("under 99.5% of them", vault)
        self.assertNotIn("under 100%", vault)

    def test_percent_labels_floor_to_one_decimal_and_never_round_a_shortfall_up(self):
        trend = self.trend
        self.assertEqual(trend.read_pct_label(1989, 2000), "99.4%")      # 99.45%
        self.assertEqual(trend.read_pct_label(29999, 30000), "99.9%")    # not 100.0%
        self.assertEqual(trend.read_pct_label(29238, 29651), "98.6%")    # not 99%
        self.assertEqual(trend.read_pct_label(0, 0), "100.0%")
        for read, short, partial in ((995, 5, False), (994, 6, True), (1989, 11, True),
                                     (29999, 1, False), (10, 0, False)):
            self.assertIs(trend.period_coverage({"requests": read, "requests_not_rescanned": short})
                          ["partial"], partial, (read, short))
        coverage = trend.period_coverage({"requests": 29999, "requests_not_rescanned": 1})
        self.assertIn("(99.9%)", trend.coverage_text(coverage))

    def test_a_shortfall_under_the_threshold_is_persisted_and_a_day_just_over_it_is_marked(self):
        t1, t2 = "2026-09-01T12:00:00Z", "2026-09-02T12:00:00Z"
        self.transcript("a", 998, t1)
        self.transcript("b", 994, t2)
        self.earlier("daily", {self.local_day(t1): 1000, self.local_day(t2): 1000})
        out = self.daily()
        self.assertNotIn("!", self.row(out, self.local_day(t1)))
        self.assertTrue(self.row(out, self.local_day(t2)).startswith(self.local_day(t2) + "!"))
        self.assertIn("1 of the 2 day(s) shown", self.footer(out))
        self.assertIn("under 99.5% of the responses", self.footer(out))
        self.assertNotIn("under 100%", self.footer(out))
        saved = self.persisted("daily")
        self.assertEqual(saved[self.local_day(t1)]["requests_not_rescanned"], 2)   # persisted, not marked
        self.assertEqual(saved[self.local_day(t2)]["requests_not_rescanned"], 6)

    # ---- periods with nothing read

    def test_a_week_recorded_earlier_with_no_transcripts_left_is_listed_without_a_row(self):
        self.transcript("s1", 40)
        self.earlier("weekly", {"2026-07-08": 4198, self.WEEK: 40})
        out = self.week("--write")
        self.assertFalse([line for line in out.splitlines() if line.startswith("2026-07-08")])
        # listed on every run, not only when it falls in the shown span
        self.assertEqual(self.block(out, "weeks with nothing read (no row: no dollars on this card):"),
                         ["  2026-07-08: 4,198 requests on record, no transcripts left"])
        vault = self.vault()
        self.assertNotIn("| 2026-07-08", vault)
        self.assertIn("- 2026-07-08: not rescanned: 4,198 requests on record and no transcripts "
                      "left (no row: no dollars on this card)", vault)
        self.assertNotIn("2026-07-08", self.persisted("weekly"))
        # --oneline still reports only the open week, whose wording is untouched.
        self.assertNotIn("not rescanned", self.week("--oneline"))

    def test_a_day_with_nothing_read_is_listed_inside_the_shown_span_and_counted_before_it(self):
        t1, t2 = "2026-08-10T12:00:00Z", "2026-08-20T12:00:00Z"
        self.transcript_days("a", [t1] * 40)
        self.transcript_days("b", [t2] * 40)
        d1, d2 = self.local_day(t1), self.local_day(t2)
        self.earlier("daily", {d1: 40, d2: 40, "2026-08-15": 70, "2026-07-08": 120, "2026-07-09": 80})
        out = self.daily()
        heading = "recorded days with nothing read (no row: no dollars on this card):"
        self.assertEqual(self.block(out, heading), [
            "  2026-08-15: 70 requests on record, nothing read",
            "  2 more before %s (--all lists them)" % d1])
        self.assertIn("0 of the 2 day(s) shown", self.footer(out))
        self.assertIn("3 recorded day(s) in the whole history have nothing read", self.footer(out))
        self.assertFalse([l for l in out.splitlines() if l.startswith(("2026-07-08", "2026-08-15"))])
        every = self.daily("--all")
        self.assertEqual(self.block(every, heading), [
            "  2026-07-08: 120 requests on record, nothing read",
            "  2026-07-09: 80 requests on record, nothing read",
            "  2026-08-15: 70 requests on record, nothing read"])
        self.assertNotIn("more before", every)

    def test_the_daily_view_takes_unread_days_out_before_it_keeps_the_last_30(self):
        skip = datetime(2026, 7, 20)
        stamps = [(datetime(2026, 7, 1) + timedelta(days=i)).strftime("%Y-%m-%dT12:00:00Z")
                  for i in range(36) if datetime(2026, 7, 1) + timedelta(days=i) != skip]
        self.transcript_days("a", stamps)
        read_days = [self.local_day(ts) for ts in stamps]
        gap = self.local_day("2026-07-20T12:00:00Z")
        before = [self.local_day("2026-06-10T12:00:00Z"), self.local_day("2026-06-11T12:00:00Z")]
        self.earlier("daily", {gap: 50, before[0]: 20, before[1]: 30})
        out = self.daily()
        shown = read_days[-30:]
        self.assertIn("\n30 days shown,", out)
        self.assertTrue(out.splitlines()[1].startswith(shown[0]))
        heading = "recorded days with nothing read (no row: no dollars on this card):"
        self.assertEqual(self.block(out, heading), [
            "  %s: 50 requests on record, nothing read" % gap,
            "  2 more before %s (--all lists them)" % shown[0]])
        every = self.daily("--all")
        self.assertIn("\n35 days shown,", every)
        self.assertEqual(len(self.block(every, heading)), 3)

    def test_each_console_list_is_capped_at_ten_lines_worst_first(self):
        stamps = ["2026-08-%02dT12:00:00Z" % d for d in range(1, 13)]
        for i, ts in enumerate(stamps):
            self.transcript("d%d" % i, 10 + i, ts)
        self.earlier("daily", {self.local_day(ts): 100 for ts in stamps})
        out = self.daily()
        lines = self.block(out, "partial days shown:")
        self.assertEqual(len(lines), 11)
        self.assertEqual(lines[-1], "  ... and 2 more")
        self.assertIn("read 10 of 100 requests on record (10.0%)", lines[0])     # worst first
        self.assertIn("read 19 of 100 requests on record (19.0%)", lines[9])
        self.assertIn("12 of the 12 day(s) shown", self.footer(out))
        # weeks with nothing read: the same cap, largest first
        self.transcript("w", 40)
        self.earlier("weekly", dict({"2026-05-%02d" % d: 100 + d for d in range(1, 13)},
                                    **{self.WEEK: 40}))
        lines = self.block(self.week(), "weeks with nothing read (no row: no dollars on this card):")
        self.assertEqual(len(lines), 11)
        self.assertEqual(lines[0], "  2026-05-12: 112 requests on record, no transcripts left")
        self.assertEqual(lines[-1], "  ... and 2 more")

    def test_json_days_with_a_shortfall_carry_derived_counts_and_the_rest_keep_their_keys(self):
        stamps = {"a": "2026-08-10T12:00:00Z", "b": "2026-08-11T12:00:00Z", "c": "2026-08-12T12:00:00Z"}
        self.transcript("a", 40, stamps["a"])
        self.transcript("b", 200, stamps["b"])
        self.transcript("c", 10, stamps["c"])
        days = {k: self.local_day(v) for k, v in stamps.items()}
        self.earlier("daily", {days["a"]: 100, days["b"]: 201, days["c"]: 10, "2026-08-01": 50})
        out = self.daily()
        merged = json.loads(self.daily("--json"))
        a, b, c, d = merged[days["a"]], merged[days["b"]], merged[days["c"]], merged["2026-08-01"]
        self.assertEqual((a["requests_read"], a["requests_on_record"], a["read_pct"], a["partial"],
                          a["transcripts_left"], a["requests_not_rescanned"]), (40, 100, 40.0, True, True, 60))
        self.assertEqual((b["read_pct"], b["partial"], b["requests_not_rescanned"]), (99.5, False, 1))
        self.assertEqual(set(c), set(self.trend._day_bucket()))        # no shortfall: today's keys
        self.assertEqual((d["transcripts_left"], d["requests_on_record"], d["cost"], d["partial"]),
                         (False, 50, 0, True))
        total = re.search(r"\$([0-9,.]+) total", out).group(1)
        self.assertEqual(round(sum(day["cost"] for day in merged.values()), 2), float(total.replace(",", "")))
        self.assertEqual(sum(day["requests"] for day in merged.values()),
                         sum(day["requests"] for day in merged.values() if day.get("transcripts_left", True)))
        # derived, never persisted: the weekly merge sums every persisted field
        for record in self.persisted("daily").values():
            self.assertNotIn("read_pct", record)
            self.assertNotIn("transcripts_left", record)

    # ---- the high-water mark

    def test_the_mark_survives_a_second_scan_without_the_earlier_file(self):
        self.transcript("s1", 40)
        self.earlier("weekly", {self.WEEK: 100})
        self.earlier("daily", {self.day: 100})
        self.week("--write")
        self.daily()
        for kind in ("weekly", "daily"):
            (self.hist / ("%s-test.json" % kind)).unlink()   # only the v2 records carry the count now
        out = self.week("--write")
        self.assertIn(self.WEEK + " 40.0% (40 of 100)", out)
        self.assertTrue(self.row(self.daily(), self.day).startswith(self.day + "!"))
        # Further pruning: the same-card rule keeps the record that read more, and its mark.
        (self.trend.ROOT / "-demo" / "s1.jsonl").unlink()
        self.transcript("s2", 10)
        out = self.week("--write")
        self.assertIn(self.WEEK + " 40.0% (40 of 100)", out)
        self.assertEqual(self.persisted("weekly")[self.WEEK]["requests_not_rescanned"], 60)
        self.daily()
        self.assertEqual(self.persisted("daily")[self.day]["requests_not_rescanned"], 60)

    def test_a_same_card_record_with_no_mark_gains_one_from_an_earlier_snapshot_with_no_transcripts_left(self):
        # the upgrade path: v2 records written before any shortfall was tracked
        record = {"rate_card": RATE_CARD_VERSION, "requests": 40, "cost": 0.08, "cost_upper": 0.08}
        self.v2_file("weekly", "test", {self.WEEK: dict(record)})
        self.v2_file("daily", "test", {self.day: dict(record)})
        self.earlier("weekly", {self.WEEK: 100})
        self.earlier("daily", {self.day: 100})
        out = self.week("--write")
        self.assertTrue(self.row(out, self.WEEK).startswith(self.WEEK + " !"))
        self.assertEqual(self.persisted("weekly")[self.WEEK]["requests_not_rescanned"], 60)
        self.assertTrue(self.row(self.daily(), self.day).startswith(self.day + "!"))
        self.assertEqual(self.persisted("daily")[self.day]["requests_not_rescanned"], 60)

    def test_an_inherited_mark_shrinks_and_clears_as_the_scan_reads_more(self):
        self.transcript("s1", 40)
        self.earlier("weekly", {self.WEEK: 100})
        self.week("--write")
        self.assertEqual(self.persisted("weekly")[self.WEEK]["requests_not_rescanned"], 60)
        self.transcript("s2", 30)
        out = self.week("--write")
        self.assertIn(self.WEEK + " 70.0% (70 of 100)", out)
        self.assertEqual(self.persisted("weekly")[self.WEEK]["requests_not_rescanned"], 30)
        self.transcript("s3", 50)
        out = self.week("--write")
        self.assertNotIn("on record", out)
        self.assertNotIn("requests_not_rescanned", self.persisted("weekly")[self.WEEK])

    def test_a_rescan_that_prices_fewer_responses_keeps_the_count_on_record(self):
        self.transcript("s1", 40)
        self.transcript("u1", 10, model=self.UNKNOWN_MODEL)
        self.earlier("weekly", {self.WEEK: 100})
        self.week("--write")
        saved = self.persisted("weekly")[self.WEEK]
        self.assertEqual((saved["requests"], saved["unpriced_responses"],
                          saved["requests_not_rescanned"]), (40, 10, 50))
        (self.trend.ROOT / "-demo" / "u1.jsonl").unlink()
        self.week("--write")
        saved = self.persisted("weekly")[self.WEEK]
        self.assertEqual(saved["requests"] + saved.get("unpriced_responses", 0)
                         + saved["requests_not_rescanned"], 100)

    def test_pruned_unpriced_responses_are_not_a_shortfall_without_an_earlier_snapshot(self):
        self.transcript("s1", 40)
        self.transcript("u1", 5, model=self.UNKNOWN_MODEL)
        self.week("--write")
        self.daily()
        self.assertEqual(self.persisted("weekly")[self.WEEK]["unpriced_responses"], 5)
        (self.trend.ROOT / "-demo" / "u1.jsonl").unlink()
        outs = (self.week("--write"), self.daily(), self.daily("--json"), self.vault())
        self.assertNotIn("unpriced_responses", self.persisted("weekly")[self.WEEK])
        self.assertIn("0 unpriced responses", outs[0])
        text = "\n".join(outs) + json.dumps([self.persisted("weekly"), self.persisted("daily")])
        for word in ("!", "partial", "not rescanned", "on record", "requests_not_rescanned"):
            self.assertNotIn(word, text)
        self.assertNotIn(RATE_CARD_VERSION, "\n".join(outs))      # (the records carry it, as always)

    def test_an_unmarked_period_stays_unmarked_when_another_period_has_an_earlier_snapshot(self):
        self.transcript("a", 40)                                        # week 2026-09-02
        self.transcript("b", 30, "2026-09-08T12:00:00Z")
        self.transcript("u", 5, "2026-09-08T13:00:00Z", model=self.UNKNOWN_MODEL)
        self.earlier("weekly", {self.WEEK: 100})                        # only the first week
        self.week("--write")
        (self.trend.ROOT / "-demo" / "u.jsonl").unlink()
        out = self.week("--write")
        self.assertTrue(self.row(out, self.WEEK).startswith(self.WEEK + " !"))
        self.assertNotIn(" !", self.row(out, "2026-09-09"))
        self.assertNotIn("requests_not_rescanned", self.persisted("weekly")["2026-09-09"])

    def test_unpriced_responses_count_as_read(self):
        self.transcript("s1", 40)
        self.transcript("u1", 10, model=self.UNKNOWN_MODEL)
        self.earlier("weekly", {self.WEEK: 60})
        self.earlier("daily", {self.day: 60})
        out = self.week("--write")
        self.assertIn(self.WEEK + " 83.3% (50 of 60)", self.footer(out))
        saved = self.persisted("weekly")[self.WEEK]
        self.assertEqual((saved["requests"], saved["unpriced_responses"],
                          saved["requests_not_rescanned"]), (40, 10, 10))
        self.assertEqual(self.block(self.daily(), "partial days shown:"),
                         ["  %s: read 50 of 60 requests on record (83.3%%)" % self.day])

    def test_a_v2_record_under_another_card_hands_its_count_on(self):
        older = {"rate_card": "older-card", "requests": 80, "requests_not_rescanned": 20,
                 "cost": self.OLD_DOLLARS, "cost_upper": self.OLD_DOLLARS,
                 "cost_main": self.OLD_DOLLARS, "cost_sub": self.OLD_DOLLARS,
                 "tier_fable": self.OLD_DOLLARS}   # fields the fresh record lacks must not survive
        self.v2_file("weekly", "test", {self.WEEK: older, "2026-08-05": dict(older)})
        self.transcript("s1", 40)
        out = self.week("--write")
        saved = self.persisted("weekly")
        self.assertEqual(saved[self.WEEK]["rate_card"], RATE_CARD_VERSION)
        self.assertEqual(saved[self.WEEK]["requests_not_rescanned"], 60)
        self.assertAlmostEqual(saved[self.WEEK]["cost"], 0.08)
        self.assertIn(self.WEEK + " 40.0% (40 of 100)", out)
        # A week with no fresh scan keeps the other card's record untouched and is listed
        # unread, at its ON-RECORD count (80 read plus the 20 it already knew it had not).
        self.assertEqual(saved["2026-08-05"]["rate_card"], "older-card")
        self.assertIn("- 2026-08-05: not rescanned: 100 requests on record", self.vault())
        self.assertNoOldDollars(out + self.vault() + json.dumps(saved[self.WEEK]))

    def test_machines_sum_their_shortfalls_and_never_a_high_water_mark(self):
        self.transcript("s1", 100)
        self.earlier("weekly", {self.WEEK: 150})            # this machine: read 100 of 150
        self.earlier("daily", {self.day: 150})
        other = {"rate_card": RATE_CARD_VERSION, "requests": 100, "requests_not_rescanned": 100,
                 "cost": 1.0, "cost_main": 1.0}
        self.v2_file("weekly", "other", {self.WEEK: other})
        self.v2_file("daily", "other", {self.day: other})
        # read 200; short 50 + 100 = 150; on record 350 (a max-based mark would say 200 or 150)
        self.assertIn(self.WEEK + " 57.1% (200 of 350)", self.footer(self.week()))
        self.daily()
        merged = self.trend.merged_history("test")[self.day]
        self.assertEqual((merged["requests"], merged["requests_not_rescanned"]), (200, 150))
        self.assertIn("1 of the 1 day(s) shown", self.footer(self.daily()))

    def test_a_period_short_on_one_machine_and_unread_on_another_keeps_both_counts(self):
        other = {"rate_card": RATE_CARD_VERSION, "requests": 100, "requests_not_rescanned": 20,
                 "cost": 1.0, "cost_main": 1.0}
        self.v2_file("weekly", "other", {self.WEEK: other})
        self.v2_file("daily", "other", {self.day: other})
        self.earlier("weekly", {self.WEEK: 150})            # this machine: no transcripts at all
        self.earlier("daily", {self.day: 150})
        weekly = self.trend.merged_weekly({}, "test", False)[self.WEEK]
        self.assertEqual((weekly["requests"], weekly["requests_not_rescanned"]), (100, 170))
        daily = self.trend.merged_history("test")[self.day]
        self.assertEqual((daily["requests"], daily["requests_not_rescanned"]), (100, 170))
        self.assertIn(self.WEEK + " 37.0% (100 of 270)", self.footer(self.week()))
        # an other-card record that itself carries a shortfall contributes its ON-RECORD count
        older = {"rate_card": "older-card", "requests": 80, "requests_not_rescanned": 20}
        self.v2_file("weekly", "test", {"2026-08-05": older})
        self.v2_file("daily", "test", {"2026-08-05": older})
        self.assertEqual(self.trend.merged_weekly({}, "test", False)["2026-08-05"],
                         {"requests_not_rescanned": 100})
        self.assertEqual(self.trend.merged_history("test")["2026-08-05"]["requests_not_rescanned"], 100)

    def test_no_dollar_from_another_rate_card_enters_a_v2_total(self):
        # Nothing was scanned: every dollar on offer belongs to another card.
        self.earlier("weekly", {self.WEEK: 100})
        self.earlier("daily", {self.day: 100})
        older = {"rate_card": "older-card", "requests": 70, "cost": self.OLD_DOLLARS,
                 "cost_upper": self.OLD_DOLLARS, "cost_main": self.OLD_DOLLARS,
                 "tier_opus": self.OLD_DOLLARS, "tier_cost": {"opus": self.OLD_DOLLARS}}
        self.v2_file("weekly", "other", {"2026-08-05": older})
        self.v2_file("daily", "other", {"2026-08-05": older})
        weekly = self.trend.merged_weekly({}, "test", False)
        daily = self.trend.merged_history("test")
        self.assertEqual(set(weekly[self.WEEK]), {"requests_not_rescanned"})
        self.assertEqual(set(daily[self.day]) - {"requests_not_rescanned"},
                         set(self.trend._day_bucket()))
        self.assertNotIn("2026-08-05", weekly)
        self.assertNotIn("2026-08-05", daily)
        for bucket in list(weekly.values()) + list(daily.values()):
            for field in ("cost", "cost_upper", "cost_main", "cost_sub", "tier_opus"):
                self.assertEqual(bucket.get(field, 0), 0, field)
            self.assertEqual(sum(bucket.get("tier_cost", {}).values()), 0)
        for text in (self.week("--write"), self.daily(), self.vault(), self.daily("--json")):
            self.assertNoOldDollars(text)

    # ---- the vault

    def test_the_vault_lists_a_marked_a_short_and_an_unread_week_in_full_and_in_order(self):
        self.transcript("a", 90)
        self.transcript("b", 998, "2026-09-08T12:00:00Z")
        self.earlier("weekly", {"2026-07-08": 4198, "2026-09-02": 100, "2026-09-09": 1000})
        self.week("--write")
        lines = self.vault().splitlines()
        start = next(i for i, line in enumerate(lines)
                     if line.startswith("Requests on record that the scan did not read"))
        self.assertIn(self.trend.READ_NOTE[1:-1], lines[start])
        self.assertIn("under 99.5% of them", lines[start])
        self.assertEqual(lines[start + 2:start + 5], [
            "- 2026-07-08: not rescanned: 4,198 requests on record and no transcripts left "
            "(no row: no dollars on this card)",
            "- 2026-09-02: read 90 of 100 requests on record (90.0%); partial",
            "- 2026-09-09: read 998 of 1,000 requests on record (99.8%)"])
        self.assertEqual(len(lines), start + 5)

    def test_the_rate_card_line_names_where_the_earlier_figures_are(self):
        self.transcript("s1", 40)
        # only an earlier-card v2 record exists: the merge replaces it, and the line is
        # decided BEFORE that, so it still appears
        self.v2_file("weekly", "test", {self.WEEK: {"rate_card": "older-card", "requests": 40}})
        self.week("--write")
        self.assertEqual(self.persisted("weekly")[self.WEEK]["rate_card"], RATE_CARD_VERSION)
        line = next(l for l in self.vault().splitlines() if l.startswith("Priced under rate card"))
        self.assertIn(RATE_CARD_VERSION, line)
        self.assertIn("earlier-card v2 records for weeks this scan repriced are no longer on disk", line)
        self.assertNotIn("remain in weekly-test.json", line)
        # with the pre-v2 snapshot on disk it says that instead
        self.earlier("weekly", {self.WEEK: 40})
        self.week("--write")
        line = next(l for l in self.vault().splitlines() if l.startswith("Priced under rate card"))
        self.assertIn("remain in weekly-test.json and are not comparable", line)

    def test_the_open_week_says_partial_in_its_oneline_only_when_it_is(self):
        now = datetime.now().astimezone()
        week = self.trend.meter_week_close(now)
        self.transcript("s1", 40, now.isoformat())
        plain = self.week("--oneline")
        self.assertTrue(plain.startswith("week closing %s: " % week))
        self.assertNotIn("partial", plain)
        self.earlier("weekly", {week: 40})
        self.assertEqual(self.week("--oneline"), plain)
        self.earlier("weekly", {week: 100})
        self.assertEqual(self.week("--oneline"), plain.rstrip("\n") +
                         "; partial: the scan read 40.0% of the 100 requests on record\n")
        # open AND partial: both markers, no space between them, and the label still leaves
        # a space before the amount in its 14-character column
        row = self.row(self.week(), week)
        self.assertTrue(row.startswith(week + " *!"))
        self.assertRegex(row, r"^%s \*!\s+\$" % week)

    # ---- timezone, and corrupt files

    def test_a_snapshot_taken_in_another_timezone_names_that_cause(self):
        old_tz = os.environ.get("TZ")
        def restore():
            if old_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old_tz
            time.tzset()
        self.addCleanup(restore)
        self.transcript("a", 48, "2026-09-01T05:00:00Z")
        self.transcript("b", 48, "2026-09-01T20:00:00Z")
        self.earlier("daily", {"2026-09-01": 96})        # as a UTC scan would have bucketed it
        os.environ["TZ"] = "Asia/Tokyo"                 # 05:00Z is 14:00 on the 1st, 20:00Z is 05:00 on the 2nd
        time.tzset()
        out = self.daily()
        self.assertTrue(self.row(out, "2026-09-01").startswith("2026-09-01!"))
        self.assertIn("pruned", self.footer(out))
        self.assertIn("another timezone", self.footer(out))
        self.assertEqual(self.persisted("daily")["2026-09-01"]["requests_not_rescanned"], 48)

    def test_count_and_read_records_tolerate_malformed_values_and_files(self):
        trend = self.trend
        for value, want in ((3.6, 4), ("7", 7), (-5, 0), ("abc", 0), (None, 0), (float("nan"), 0),
                            (float("inf"), 0), ([1], 0), (0, 0)):
            self.assertEqual(trend._count({"x": value}, "x"), want, value)
        self.assertEqual(trend._count(None, "x"), 0)
        self.assertEqual(trend._count([1], "x"), 0)
        path = self.root / "snap.json"
        self.assertEqual(trend.read_records(path), {})                          # absent
        for content in (b"\xff\xfe", b"not json", b"[1, 2]", b'"text"', b""):
            path.write_bytes(content)
            self.assertEqual(trend.read_records(path), {}, content)             # corrupt, non-UTF-8, non-dict
        path.write_text(json.dumps({"a": {"requests": 1}, "b": 3, "c": [1]}))
        self.assertEqual(trend.read_records(path), {"a": {"requests": 1}})

    def test_a_corrupt_snapshot_file_is_ignored_in_every_mode(self):
        self.transcript("s1", 40)
        script = str(HERE / "usage-trend.py")
        corrupt = ("daily-test.json", "weekly-test.json", "daily-v2-other.json",
                   "weekly-v2-other.json", "weekly-v2-test.json")
        modes = (["--no-sync"], ["--no-sync", "--json"], ["--week"], ["--week", "--oneline"])
        def run_all():
            done = [subprocess.run([sys.executable, script, *argv], capture_output=True, text=True)
                    for argv in modes]
            for result in done:
                self.assertEqual(result.returncode, 0, result.stderr)
            return [result.stdout for result in done]
        for name in corrupt:
            (self.hist / name).write_bytes(b"\xff\xfe not json \x80")
        with_corrupt = run_all()
        for name in corrupt:
            (self.hist / name).unlink()
        self.assertEqual(run_all(), with_corrupt)       # the corrupt files were ignored, not half-read


if __name__ == "__main__":
    unittest.main()
