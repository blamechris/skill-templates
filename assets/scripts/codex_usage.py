#!/usr/bin/env python3
"""Read explicit Codex-shaped JSONL fixtures; never discover sessions or write state.

Experimental counter contract, validated with invented fixtures only. This is not
Claude accounting, a pricing source, or evidence of complete live Codex coverage.
"""
import argparse
import json
import re
from datetime import datetime
from pathlib import Path

REQUIRED = ("input_tokens", "output_tokens", "total_tokens")
OPTIONAL = ("cached_input_tokens", "reasoning_output_tokens")
COUNTERS = REQUIRED + OPTIONAL


def _usage(value):
    if not isinstance(value, dict):
        raise ValueError("invalid_usage_object")
    result = {}
    for key in COUNTERS:
        n = value.get(key)
        if key in OPTIONAL and key not in value:
            result[key] = None
        elif type(n) is not int or n < 0:
            raise ValueError("invalid_usage_counter")
        else:
            result[key] = n
    if result["total_tokens"] != result["input_tokens"] + result["output_tokens"]:
        raise ValueError("inconsistent_total_tokens")
    for subset, parent in (("cached_input_tokens", "input_tokens"),
                           ("reasoning_output_tokens", "output_tokens")):
        if result[subset] is not None and result[subset] > result[parent]:
            raise ValueError("inconsistent_subset_counter")
    return result


def _instant(value):
    if not isinstance(value, str):
        raise ValueError("invalid_observation_timestamp")
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.utcoffset() is None:
            raise ValueError()
        return dt.timestamp()
    except (ValueError, OverflowError):
        raise ValueError("invalid_observation_timestamp") from None


def _dominates(a, b):
    return all(a[k] is not None and a[k] >= v for k, v in b.items() if v is not None)


def _disjoint(usage):
    if usage is None:
        return None
    cached, reasoning = usage["cached_input_tokens"], usage["reasoning_output_tokens"]
    return {
        "uncached_input_tokens": None if cached is None else usage["input_tokens"] - cached,
        "cached_input_tokens": cached,
        "non_reasoning_output_tokens": None if reasoning is None else usage["output_tokens"] - reasoning,
        "reasoning_output_tokens": reasoning,
    }


def report(paths):
    """Report one coherent high-water observation per session, never a sum of snapshots.

    No cross-session sum: supplied files cannot prove whether parent/fork/child
    counters overlap, or whether other files and sessions are missing.
    """
    diagnostics, sessions, session_sources, seen_paths = [], {}, {}, set()
    duplicate_paths = ignored = 0

    def problem(code, path, line=0):
        # Never copy JSON, prompts, tool content or exception text into the report.
        diagnostics.append({"code": code, "source": str(path), "line": line})

    for given in paths:
        try:
            path = Path(given).resolve(strict=True)
            if path in seen_paths:
                duplicate_paths += 1
                continue
            seen_paths.add(path)
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError, ValueError):
            problem("unreadable_source", given)
            continue
        identities, observations = set(), []
        for number, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except ValueError:
                problem("malformed_json", path, number)
                continue
            if not isinstance(record, dict):
                problem("invalid_record", path, number)
                continue
            payload = record.get("payload")
            if record.get("type") == "session_meta":
                sid = payload.get("id") if isinstance(payload, dict) else None
                if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", sid):
                    problem("invalid_session_identity", path, number)
                else:
                    identities.add(sid)
            elif record.get("type") == "event_msg" and isinstance(payload, dict) and payload.get("type") == "token_count":
                info = payload.get("info")
                if not isinstance(info, dict) or "total_token_usage" not in info:
                    problem("missing_cumulative_usage", path, number)
                    continue
                try:
                    usage = _usage(info["total_token_usage"])
                    instant = _instant(record.get("timestamp"))
                except ValueError as error:
                    problem(str(error), path, number)
                    continue
                # last_token_usage is deliberately never added to its cumulative total.
                observations.append((instant, usage, str(path), number))
            else:
                ignored += 1
        if len(identities) != 1:
            problem("ambiguous_session_identity" if identities else "missing_session_identity", path)
            continue
        sid = next(iter(identities))
        session_sources.setdefault(sid, str(path))
        sessions.setdefault(sid, []).extend(observations)

    results = []
    for sid, observations in sorted(sessions.items()):
        observations.sort(key=lambda item: (item[0], item[2], item[3]))
        vectors = {tuple(u[k] for k in COUNTERS) for _, u, _, _ in observations}
        ambiguous = False
        last_known = {}
        for _, usage, source, line in observations:
            # Missing fields stay unknown, but do not erase an earlier measured
            # value: 40 -> missing -> 30 is still a counter regression.
            if any(v is not None and key in last_known and v < last_known[key]
                   for key, v in usage.items()):
                problem("counter_regression", source, line)
                ambiguous = True
            last_known.update((key, v) for key, v in usage.items() if v is not None)
        for old, new in zip(observations, observations[1:]):
            a, b = old[1], new[1]
            if old[0] == new[0] and a != b:
                problem("conflicting_observation_timestamp", new[2], new[3])
                ambiguous = True
        candidates = [u for _, u, _, _ in observations
                      if all(_dominates(u, other) for _, other, _, _ in observations)]
        usage = candidates[-1] if candidates and not ambiguous else None
        if observations and not candidates:
            problem("incomparable_cumulative_usage", observations[-1][2], observations[-1][3])
        if not observations:
            problem("no_measured_usage", session_sources[sid])
        results.append({
            "session_id": sid,
            "observation_count": len(observations),
            "repeated_counter_observations": len(observations) - len(vectors),
            "observed_cumulative_usage": usage,
            "disjoint_usage": _disjoint(usage),
            "unknown_counter_fields": [k for k in OPTIONAL if usage is None or usage[k] is None],
            "cost_usd": None,
        })
    return {
        "schema": "codex-fixture-usage/v1",
        "validation_basis": "invented_fixtures_only",
        "coverage": "supplied_files_only",
        "coverage_complete": False,
        "hierarchy_coverage": "unknown",
        "pricing_coverage": "unknown",
        "aggregate_usage": None,
        "aggregate_reason": "cross_session_overlap_and_missing_session_coverage_unknown",
        "duplicate_input_paths": duplicate_paths,
        "ignored_record_count": ignored,
        "sessions": results,
        "diagnostics": diagnostics,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", help="explicit JSONL fixture paths; no discovery")
    args = parser.parse_args(argv)
    result = report(args.files)
    print(json.dumps(result, indent=2, allow_nan=False))
    return 1 if result["diagnostics"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
