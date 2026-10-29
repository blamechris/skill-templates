#!/usr/bin/env python3
"""Eight offline session signals, under one 0.8s subprocess deadline; always exit 0.

Raw invocation observes only. --snapshot-file writes a scratch JSON snapshot, never
an actual seed; only session-seed.py write may persist it. Optional --signals-file
accepts explicitly cached, source-labelled measurements; no model/network calls.
"""
import time
STARTED = time.monotonic()

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
from datetime import datetime, timezone

sys.dont_write_bytecode = True
SOURCES = {"claude", "codex", "chroxy"}
LIMIT = 0.8


class Budget:
    def __init__(self):
        self.deadline = STARTED + LIMIT
        self.degraded = False

    def run(self, argv):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.degraded = True
            return subprocess.CompletedProcess(argv, 128, "", "pulse deadline exhausted")
        process = None
        try:
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True,
                                       env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
            stdout, stderr = process.communicate(timeout=max(0.001, self.deadline - time.monotonic()))
            return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        except (OSError, subprocess.TimeoutExpired):
            self.degraded = True
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.communicate(timeout=0.015)
                except subprocess.TimeoutExpired:
                    pass
            return subprocess.CompletedProcess(argv, 128, "", "pulse source unavailable or timed out")

    def git(self, *args):
        return self.run(["git", "-c", "core.fsmonitor=false", *args])


def clean(value, limit=180):
    if value is None:
        return "n/a"
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", str(value))
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    return re.sub(r"\s+", " ", text).strip()[:limit]


def usage_signature(oneline):
    """Compare supported printed measurements, never ages or projections.

    This is presentation parsing, not another accounting implementation. Keep
    direct sd/fh/fable readings, total/subtotal and fable spend, and derived
    capacity exactly at the source formatter's precision. Unrecognized/missing
    measurements stay unknown; sample identity/age, reset countdown, burn,
    headroom, rates and projected landings are not stable source measurements.
    """
    text, values = clean(oneline, 10000), {}
    number = r"[0-9][0-9,]*(?:\.[0-9]+)?"
    money = r"\$" + number
    amount = money + r"(?:-" + money + r")?"
    patterns = {
        "sd": r"^sd (" + number + r")%",
        "fh": r"(?:^| · )fh (" + number + r")%",
        "fable_reading": r"(?:^| · )fable(?: reading)? (" + number + r")%",
        "spend": r"(?:^| · )spent (" + amount + r")(?= since | · |$)",
        "spend_subtotal": r"(?:^| · )priced spend subtotal (" + amount + r") \(not total\)",
        "fable_spend": r"(?:^| · )(" + amount + r") fable(?= · |$)",
        "derived_pct": r"(?:^| · )all-models ~(" + number + r")% of cap ",
        "derived_cap": r"(?:^| · )all-models ~" + number + r"% of cap (" + money + r")",
    }
    for name, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            values[name] = match.group(1)
    return values or None


def read_text(path):
    # A pipe/device supplied as a cache path must not block the eight-line reader.
    info = os.stat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > 512 * 1024:
        raise ValueError("not a bounded regular cache file")
    return Path(path).read_text(encoding="utf-8")


def timestamp(value):
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if "T" not in value or result.tzinfo is None or result.utcoffset().total_seconds() != 0:
            return None
        return result
    except (ValueError, TypeError, AttributeError):
        return None


def age(value, now):
    parsed = timestamp(value)
    return max(0, (now - parsed).total_seconds()) if parsed is not None and parsed <= now else None


def age_text(seconds):
    if seconds is None:
        return "n/a"
    return "%dm" % (seconds // 60) if seconds < 3600 else "%.1fh" % (seconds / 3600)


def cached_signals(path, source, warnings):
    if not path:
        return {}
    try:
        value = json.loads(read_text(path))
        allowed = {"source", "observed_at", "open_items", "turns", "context_pct",
                   "compactions", "estimate", "actual", "unit"}
        if not isinstance(value, dict) or set(value) - allowed:
            raise ValueError("unknown cache fields")
        if value.get("source") not in SOURCES or source not in SOURCES or value["source"] != source:
            raise ValueError("cache source does not match the selected host")
        if timestamp(value.get("observed_at")) is None:
            raise ValueError("cache needs an observed_at UTC timestamp")
        for key in ("open_items", "turns", "compactions"):
            if key in value and (type(value[key]) is not int or value[key] < 0):
                raise ValueError("cache count must be a nonnegative integer")
        for key in ("context_pct", "estimate", "actual"):
            if key in value and (type(value[key]) not in (int, float) or not math.isfinite(value[key]) or value[key] < 0):
                raise ValueError("cache measurement must be finite and nonnegative")
        if value.get("context_pct", 0) > 100:
            raise ValueError("context_pct exceeds 100")
        if ("estimate" in value or "actual" in value) and (
            not {"estimate", "actual", "unit"} <= set(value)
            or not isinstance(value["unit"], str) or not value["unit"].strip()):
            raise ValueError("estimate/actual need the same stated unit")
        return value
    except (OSError, ValueError, UnicodeError, TypeError):
        warnings.append("cached signals invalid/unavailable")
        return {}


def cached_state(seed, seed_module):
    prose = seed_module.outside_fences(seed)
    state = next((body for title, body in seed_module.sections(prose)
                  if re.match(r"state\b", title, re.I)), "")
    def field(name):
        m = re.search(r"^\s*-?\s*(?:\*\*)?" + name + r":(?:\*\*)?\s*(.+)$", state, re.M | re.I)
        return clean(m.group(1)) if m else None
    return field


def decision_state(seed, fm, seed_module, previous, now, warnings):
    decisions, legacy, streaks = None, [], {}
    if "decisions" in fm:
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                decisions = seed_module.validate_decisions(json.loads(fm["decisions"]))
        except (ValueError, TypeError, SystemExit):
            warnings.append("decisions metadata invalid")
    # Legacy pending prose can coexist with an empty structured default. Never
    # silently translate that into zero pending decisions or invent a count.
    for line in seed_module.outside_fences(seed.split("\n---", 1)[-1]).splitlines():
        if re.search(r"still-open owner decision|DECISION carried since|\bDECISION\s*:", line, re.I):
            if not re.search(r"DECISION\s*:\s*(?:none|no pending)\b", line, re.I):
                legacy.append(line.strip())
    old_streaks = previous.get("state", {}).get("decision_streaks", {}) if previous else {}
    if not isinstance(old_streaks, dict):
        old_streaks = {}
    entries = decisions or []
    ages = [age(d["opened_at"], now) for d in entries]
    defaults = [d["default"] for d in entries]
    keys = [d["text"] for d in entries]
    if legacy:
        warnings.append("legacy pending DECISION needs structured metadata")
        for line in legacy:
            m = re.search(r"\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z)?", line)
            if m:
                ages.append(age(m.group() if "T" in m.group() else m.group() + "T00:00:00Z", now))
        keys.append("legacy:" + hashlib.sha256("\n".join(legacy).encode()).hexdigest())
    for key in keys:
        prior = old_streaks.get(key)
        streaks[key] = prior + 1 if type(prior) is int and prior >= 0 else 1
    repeated = any(n >= 2 for n in streaks.values())
    if repeated:
        warnings.append("same decision >=2 recorded pulses")
    known_ages = [a for a in ages if a is not None]
    count = None if decisions is None or legacy else len(decisions)
    summary = "%s open; oldest %s; default %s; text %s" % (
        clean(count), age_text(max(known_ages) if known_ages else None),
        clean(" / ".join(defaults), 100) if defaults else "n/a",
        clean(" / ".join([d["text"] for d in entries] + legacy), 220) if entries or legacy else "n/a")
    return summary, {"decisions": decisions, "legacy_pending": bool(legacy),
                     "legacy_decisions": legacy,
                     "decision_streaks": streaks}, repeated


def prior_snapshot(fm, seed_module, warnings):
    if "last_pulse" not in fm:
        return None
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return seed_module.validate_pulse_snapshot(json.loads(fm["last_pulse"]))
    except (ValueError, TypeError, SystemExit):
        warnings.append("previous pulse invalid")
        return None


def delta(state, previous):
    if previous is None:
        return "no baseline"
    # Ages and recurrence counters are observations, not material state changes.
    fields = set(state) | set(previous["state"])
    changed = sorted(key for key in fields if key not in ("decision_streaks", "signals_observed_at")
                     and state.get(key) != previous["state"].get(key))
    return ("changed " + ", ".join(changed)) if changed else "no material change since " + previous["at"]


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def pulse(argv=None):
    budget = Budget()
    parser = Parser(add_help=False)
    parser.add_argument("--topic")
    parser.add_argument("--source", default="unknown")
    parser.add_argument("--signals-file")
    parser.add_argument("--snapshot-file")
    parser.add_argument("--boundary", action="store_true")
    parser.add_argument("--now")
    args = parser.parse_args(argv)
    now = timestamp(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        raise ValueError("--now must be UTC")
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    warnings = []
    spec = importlib.util.spec_from_file_location("session_seed", Path(__file__).with_name("session-seed.py"))
    seed_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(seed_module)
    seed_module._git = budget.git
    scope, path, seed, fm = None, None, "", {}
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            scope = seed_module.resolve_scope(args.topic)
            path = seed_module.seed_path(scope)
    except (SystemExit, OSError):
        warnings.append("scope unavailable")
    if path:
        try:
            seed = read_text(path)
            fm = seed_module.parse_frontmatter(seed)
            with contextlib.redirect_stderr(io.StringIO()):
                seed_module.validate_content(seed)
        except (OSError, ValueError, UnicodeError, SystemExit):
            warnings.append("seed missing/invalid")
    previous = prior_snapshot(fm, seed_module, warnings)
    cache = cached_signals(args.signals_file, args.source, warnings)
    field = cached_state(seed, seed_module)
    seed_age = age(fm.get("date"), now)
    if seed_age is not None and seed_age > 24 * 3600:
        warnings.append("seed >24h")
    picks = clean(fm.get("picks_up_at"))
    def git(*git_args):
        result = budget.git(*git_args)
        return result.stdout.strip() if result.returncode == 0 else None
    head = git("rev-parse", "--short", "HEAD")
    branch = git("branch", "--show-current")
    if head and branch == "":
        branch = "detached"
    status = git("status", "--porcelain", "--untracked-files=normal")
    tree = "dirty" if status else "clean" if status is not None else None
    counts = git("rev-list", "--left-right", "--count", "HEAD...@{upstream}")
    ahead, behind = None, None
    if counts and re.fullmatch(r"\d+\s+\d+", counts):
        ahead, behind = map(int, counts.split())
    commits = git("rev-list", "--count", "--since=" + fm["date"], "HEAD") if timestamp(fm.get("date")) else None
    if commits is not None and not commits.isdigit():
        commits = None
    def count(key, label):
        if key in cache:
            return cache[key]
        value = field(label)
        return int(value) if value and value.isdigit() else None
    open_items = count("open_items", "Open items")
    turns = count("turns", "Turns")
    tests, ci = field("Tests"), field("CI")
    decisions_line, decisions, repeated_decision = decision_state(seed, fm, seed_module, previous, now, warnings)
    if open_items is not None and open_items > 3:
        warnings.append("open items >3")
    compactions = cache.get("compactions")
    if compactions is not None and compactions >= 2:
        warnings.append("compactions >=2")
    if args.boundary and tree == "dirty":
        warnings.append("dirty at boundary")
    estimate, actual = cache.get("estimate"), cache.get("actual")
    estimate_drift = False
    if estimate is not None and actual is not None:
        drift = abs(actual - estimate) / estimate if estimate else float("inf") if actual else 0
        if drift > 0.25:
            estimate_drift = True
            warnings.append("stated estimate drift >25%")
    usage, usage_measurements = None, None
    # An explicitly selected Claude host and the actual harness session id are
    # both required. Codex/chroxy never consult Claude's unrelated meter.
    if args.source == "claude" and os.environ.get("CLAUDE_CODE_SESSION_ID"):
        pace = budget.run([sys.executable, str(Path(__file__).with_name("usage-pace.py")), "--oneline"])
        if pace.returncode == 0:
            usage = clean(pace.stdout, 1200) or None
            usage_measurements = usage_signature(pace.stdout)
    if budget.degraded:
        warnings.append("source unavailable/deadline")
    state = {"scope": scope, "seed_date": fm.get("date"), "picks": fm.get("picks_up_at"),
             "head": head, "branch": branch, "tree": tree, "ahead": ahead, "behind": behind,
             "commits": int(commits) if commits is not None else None, "open_items": open_items,
             "turns": turns, "tests": tests, "ci": ci, **decisions, "usage": usage_measurements,
             "context_pct": cache.get("context_pct"), "compactions": compactions,
             "estimate": estimate, "actual": actual, "unit": cache.get("unit"),
             "signals_source": cache.get("source"), "signals_observed_at": cache.get("observed_at"),
             "warn_decision_repeat": repeated_decision,
             "warn_open_items": open_items is not None and open_items > 3,
             "warn_seed_age": seed_age is not None and seed_age > 24 * 3600,
             "warn_compactions": compactions is not None and compactions >= 2,
             "warn_dirty_boundary": args.boundary and tree == "dirty",
             "warn_estimate_drift": estimate_drift}
    change = delta(state, previous)
    last_line = "delta: %s | %s" % (change, "WARN: " + "; ".join(warnings) if warnings else "WARN: none")
    if args.snapshot_file:
        try:
            destination = Path(args.snapshot_file)
            # Snapshots are scratch only. Never permit this optional output to
            # become an alternative seed writer, including via symlink aliases.
            canonical = Path(path).resolve() if path else None
            resolved = destination.resolve()
            info = destination.stat() if destination.exists() else None
            if (resolved.name.startswith("NEXT-") or destination.name.startswith("NEXT-")
                    or (canonical and resolved == canonical)
                    or seed_module._is_under(str(resolved), seed_module.handoff_dir())
                    or (info and (not stat.S_ISREG(info.st_mode) or info.st_nlink > 1))):
                raise ValueError("snapshot destination is a seed")
            snapshot = {"at": at, "line": last_line, "state": state}
            with contextlib.redirect_stderr(io.StringIO()):
                seed_module.validate_pulse_snapshot(snapshot)
            destination.write_text(json.dumps(snapshot, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8")
        except (OSError, ValueError, UnicodeError, SystemExit):
            last_line = (last_line.replace("WARN: none", "WARN: snapshot not saved")
                         if last_line.endswith("WARN: none") else last_line + "; snapshot not saved")
    return ["scope: " + clean(scope),
            "seed: age %s | picks %s" % (age_text(seed_age), picks),
            "git: HEAD %s | branch %s | tree %s | ahead %s / behind %s" % tuple(map(clean, (head, branch, tree, ahead, behind))),
            "work: commits since seed %s | open items %s | turns %s" % tuple(map(clean, (commits, open_items, turns))),
            "cached: tests %s | CI %s" % (clean(tests), clean(ci)),
            "decisions: " + decisions_line,
            "usage: %s | context %s | compactions %s" % (clean(usage, 1200), clean(cache.get("context_pct")), clean(compactions)),
            last_line]


def main(argv=None):
    try:
        lines = pulse(argv)
    except (Exception, SystemExit):
        lines = ["scope: n/a", "seed: age n/a | picks n/a",
                 "git: HEAD n/a | branch n/a | tree n/a | ahead n/a / behind n/a",
                 "work: commits since seed n/a | open items n/a | turns n/a",
                 "cached: tests n/a | CI n/a", "decisions: n/a | age n/a | default n/a",
                 "usage: n/a | context n/a | compactions n/a",
                 "delta: no baseline | WARN: pulse source unavailable"]
    for line in lines:
        print(clean(line, 2000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
