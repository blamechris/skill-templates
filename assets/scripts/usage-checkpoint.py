#!/usr/bin/env python3
"""Capture immutable cumulative Claude session usage, or aggregate latest captures.

No prompt or tool content is copied. Without --out-dir, capture prints JSON only.
"""
import argparse
import glob
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usage_accounting import RATE_CARD_VERSION, Responses, price_usage, token_split

TOKEN_FIELDS = ("input_tokens", "output_tokens", "cache_5m_tokens",
                "cache_1h_tokens", "cache_read_input_tokens", "cache_ttl_unknown_tokens")


def empty_part():
    return {"responses": 0, "priced_responses": 0, "lower_usd": Decimal(0),
            "upper_usd": Decimal(0), "tokens": {field: 0 for field in TOKEN_FIELDS},
            "by_model": {}}


def minimal_record(item, key):
    """Persist only fields needed to reselect and reprice across sessions."""
    record = item["record"]
    msg = record.get("message") or {}
    request_id = key[1] if key[0] == "pair" else record.get("requestId")
    message_id = key[2] if key[0] == "pair" else msg.get("id")
    return {"type": "assistant", "timestamp": record.get("timestamp"),
            "requestId": request_id,
            "message": {"id": message_id, "model": msg.get("model"),
                        "usage": msg.get("usage"), "stop_reason": msg.get("stop_reason")},
            "source": item["source"], "line": item["line"], "role": item["role"]}


def resolve_session(value):
    value = value or os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if not value:
        raise ValueError("session ID or main .jsonl path required")
    path = Path(value).expanduser()
    if path.suffix == ".jsonl" and path.is_file():
        return path
    if any(c in value for c in "*?["):
        raise ValueError("wildcard session ID refused")
    hits = [Path(p) for p in glob.glob(str(Path.home() / ".claude" / "projects" /
                                        "*" / (value + ".jsonl")))]
    if len(hits) != 1:
        raise ValueError("session ID resolves to %d main transcripts; pass an exact path" % len(hits))
    return hits[0]


def capture(path, run_id, captured_at, status):
    paths = [path]
    subdir = path.with_suffix("") / "subagents"
    if subdir.is_dir():
        paths += sorted(subdir.rglob("*.jsonl"))
    selected = Responses()
    coverage = []
    for source in paths:
        digest = hashlib.sha256()
        byte_count = 0
        with source.open("rb") as fh:
            for line_no, raw in enumerate(fh, 1):
                digest.update(raw)
                byte_count += len(raw)
                try:
                    selected.add(json.loads(raw), str(source), line_no,
                                 "child" if source != path else "main")
                except json.JSONDecodeError:
                    continue
        coverage.append({"path": str(source), "bytes": byte_count,
                         "sha256": digest.hexdigest()})
    resolved = selected.selected
    out = {"run_id": run_id, "session_id": path.stem, "captured_at": captured_at,
           "status": status, "rate_card": RATE_CARD_VERSION,
           "source_coverage": coverage,
           "quality": {"conflicting_response_pairs": selected.conflicts,
                       "cross_role_pairs": selected.cross_role_pairs,
                       "ambiguous_identities": selected.ambiguous_identities,
                       "selected_without_terminal_metadata": selected.without_terminal_metadata(),
                       "unidentified_records": selected.unidentified,
                       "synthetic_records": selected.synthetic,
                       "speed_unknown_responses": 0,
                       "geography_unknown_responses": 0,
                       "service_tier_unknown_responses": 0,
                       "invalid_token_responses": 0},
           "parent": empty_part(), "children": empty_part(),
           "unpriced_models": {},
           "selected_responses": [minimal_record(item, key)
                                  for key, item in resolved.items()]}
    for item in selected.rows():
        msg = item["record"].get("message") or {}
        model = msg.get("model")
        usage = msg.get("usage") or {}
        for field, name in (("speed", "speed_unknown_responses"),
                            ("inference_geo", "geography_unknown_responses"),
                            ("service_tier", "service_tier_unknown_responses")):
            if not usage.get(field) or (field == "inference_geo" and
                                        usage.get(field) == "not_available"):
                out["quality"][name] += 1
        part = out["children" if item["role"] == "child" else "parent"]
        part["responses"] += 1
        try:
            tokens = token_split(usage)
        except ValueError:
            out["quality"]["invalid_token_responses"] += 1
        else:
            # Keep observed tokens even if the model or modifier cannot be priced.
            for field in TOKEN_FIELDS:
                part["tokens"][field] += tokens[field]
        try:
            priced = price_usage(msg.get("usage"), model)
        except ValueError:
            out["unpriced_models"][model or "unknown"] = out["unpriced_models"].get(model or "unknown", 0) + 1
            continue
        part["lower_usd"] += priced["lower_usd"]
        part["upper_usd"] += priced["upper_usd"]
        part["priced_responses"] += 1
        by_model = part["by_model"].setdefault(model, {"responses": 0,
                                                       "lower_usd": Decimal(0),
                                                       "upper_usd": Decimal(0)})
        by_model["responses"] += 1
        by_model["lower_usd"] += priced["lower_usd"]
        by_model["upper_usd"] += priced["upper_usd"]
    out["all_in"] = empty_part()
    for part in (out["parent"], out["children"]):
        for key in ("responses", "priced_responses", "lower_usd", "upper_usd"):
            out["all_in"][key] += part[key]
        for field in TOKEN_FIELDS:
            out["all_in"]["tokens"][field] += part["tokens"][field]
        for model, detail in part["by_model"].items():
            target = out["all_in"]["by_model"].setdefault(model, {"responses": 0,
                         "lower_usd": Decimal(0), "upper_usd": Decimal(0)})
            for key in target:
                target[key] += detail[key]
    out["tokens_cover_selected_responses"] = out["quality"]["invalid_token_responses"] == 0
    for part in ("parent", "children", "all_in"):
        for key in ("lower_usd", "upper_usd"):
            out[part][key] = str(out[part][key])
        for detail in out[part]["by_model"].values():
            for key in ("lower_usd", "upper_usd"):
                detail[key] = str(detail[key])
    return out


def latest_totals(directory):
    latest = {}
    for path in directory.glob("*.json"):
        doc = json.loads(path.read_text())
        if doc.get("rate_card") != RATE_CARD_VERSION:
            raise ValueError("mixed rate-card versions; reprice or segregate checkpoints")
        key = (doc["run_id"], doc["session_id"])
        if key not in latest or (doc["captured_at"], doc["status"] == "final") > (latest[key]["captured_at"], latest[key]["status"] == "final"):
            latest[key] = doc
    result = {"sessions": len(latest), "partial_sessions": 0,
              "rate_card": RATE_CARD_VERSION, "cumulative": True,
              "source_checkpoints": [],
              "parent_lower_usd": Decimal(0), "parent_upper_usd": Decimal(0),
              "children_lower_usd": Decimal(0), "children_upper_usd": Decimal(0),
              "parent_responses": 0, "children_responses": 0,
              "parent_priced_responses": 0, "children_priced_responses": 0,
              "unpriced_models": {},
              "tokens": {field: 0 for field in TOKEN_FIELDS}}
    global_rows = Responses()
    for (run_id, session_id), doc in sorted(latest.items()):
        result["partial_sessions"] += doc["status"] != "final"
        if "selected_responses" not in doc:
            raise ValueError("checkpoint lacks response identities; cannot deduplicate sessions")
        result["source_checkpoints"].append({
            "run_id": run_id, "session_id": session_id,
            "captured_at": doc["captured_at"], "status": doc["status"],
            "source_coverage": [{"bytes": source["bytes"], "sha256": source["sha256"]}
                                for source in doc.get("source_coverage", [])]})
        for item in doc["selected_responses"]:
            global_rows.add(item, item["source"], item["line"], item["role"])
    response_times = []
    undated = 0
    invalid_token_responses = 0
    for item in global_rows.rows():
        msg = item["record"]["message"]
        role = "children" if item["role"] == "child" else "parent"
        result[role + "_responses"] += 1
        try:
            at = datetime.fromisoformat(item["record"]["timestamp"].replace("Z", "+00:00"))
            if at.tzinfo is None:
                raise ValueError("response timestamp needs timezone")
            response_times.append(at.astimezone(timezone.utc))
        except (KeyError, TypeError, AttributeError, ValueError):
            undated += 1
        try:
            tokens = token_split(msg["usage"])
        except (KeyError, ValueError):
            invalid_token_responses += 1
        else:
            for field in TOKEN_FIELDS:
                result["tokens"][field] += tokens[field]
        try:
            priced = price_usage(msg["usage"], msg.get("model"))
        except ValueError:
            model = msg.get("model") or "unknown"
            result["unpriced_models"][model] = result["unpriced_models"].get(model, 0) + 1
            continue
        result[role + "_priced_responses"] += 1
        result[role + "_lower_usd"] += priced["lower_usd"]
        result[role + "_upper_usd"] += priced["upper_usd"]
    result["all_in_lower_usd"] = result["parent_lower_usd"] + result["children_lower_usd"]
    result["all_in_upper_usd"] = result["parent_upper_usd"] + result["children_upper_usd"]
    # Existing consumers read these as lower-bound values. Explicit upper fields
    # and coverage keep uncertain cache lifetimes and unpriced models visible.
    for role in ("parent", "children", "all_in"):
        result[role + "_usd"] = result[role + "_lower_usd"]
    result["all_in_responses"] = result["parent_responses"] + result["children_responses"]
    result["priced_responses"] = result["parent_priced_responses"] + result["children_priced_responses"]
    result["unpriced_responses"] = result["all_in_responses"] - result["priced_responses"]
    result["excluded_ambiguous_observations"] = global_rows.ambiguous_identities
    result["coverage_gap_observations"] = (result["unpriced_responses"] +
                                           result["excluded_ambiguous_observations"])
    result["bounds_cover_all_responses"] = result["coverage_gap_observations"] == 0
    result["pricing_complete"] = (result["bounds_cover_all_responses"] and
                                  result["all_in_lower_usd"] == result["all_in_upper_usd"] and
                                  result["partial_sessions"] == 0 and
                                  global_rows.conflicts == 0 and
                                  global_rows.without_terminal_metadata() == 0)
    result["valuation_scope"] = ("all selected responses" if result["bounds_cover_all_responses"]
                                 else "priced-response subtotal; unpriced or ambiguous observations excluded")
    result["tokens_cover_selected_responses"] = invalid_token_responses == 0
    result["selected_response_time_bounds"] = {
        "first": min(response_times).isoformat() if response_times else None,
        "last": max(response_times).isoformat() if response_times else None,
        "without_timestamp": undated}
    result["quality"] = {"cross_session_conflicts": global_rows.conflicts,
                         "cross_role_pairs": global_rows.cross_role_pairs,
                         "ambiguous_identities": global_rows.ambiguous_identities,
                         "selected_without_terminal_metadata": global_rows.without_terminal_metadata(),
                         "unidentified_records": global_rows.unidentified,
                         "invalid_token_responses": invalid_token_responses}
    for field, name in (("speed", "speed_unknown_responses"),
                        ("inference_geo", "geography_unknown_responses"),
                        ("service_tier", "service_tier_unknown_responses")):
        result["quality"][name] = sum(
            not bool((item["record"].get("message") or {}).get("usage", {}).get(field)) or
            (field == "inference_geo" and
             (item["record"].get("message") or {}).get("usage", {}).get(field) == "not_available")
            for item in global_rows.rows())
    for key in (role + suffix for role in ("parent", "children", "all_in")
                for suffix in ("_lower_usd", "_upper_usd", "_usd")):
        result[key] = str(result[key])
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session", help="full session ID or exact main transcript path")
    ap.add_argument("--run-id", help="stable run ID; defaults to full session ID")
    ap.add_argument("--capture-at", help="UTC ISO timestamp; defaults to now")
    ap.add_argument("--status", choices=("partial", "final"), default="partial")
    ap.add_argument("--out-dir", type=Path, help="write one immutable JSON checkpoint")
    ap.add_argument("--aggregate-dir", type=Path, help="sum latest checkpoint per run/session")
    args = ap.parse_args()
    try:
        if args.aggregate_dir:
            print(json.dumps(latest_totals(args.aggregate_dir), indent=2))
            return 0
        path = resolve_session(args.session)
        at = args.capture_at or datetime.now(timezone.utc).isoformat()
        instant = datetime.fromisoformat(at.replace("Z", "+00:00"))
        if instant.tzinfo is None:
            raise ValueError("capture timestamp needs a timezone")
        at = instant.astimezone(timezone.utc).isoformat()
        doc = capture(path, args.run_id or path.stem, at, args.status)
        encoded = json.dumps(doc, indent=2) + "\n"
        if args.out_dir:
            args.out_dir.mkdir(parents=True, exist_ok=True)
            stamp = instant.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            dest = args.out_dir / (path.stem + "-" + stamp + ".json")
            with dest.open("x") as fh:
                fh.write(encoded)
            print(dest)
        else:
            print(encoded, end="")
        return 0
    except (OSError, ValueError, KeyError) as exc:
        print("REFUSE: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
