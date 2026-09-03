#!/usr/bin/env python3
"""Pace Fable consumption against the meter week's elapsed time.

The instrument here is deliberately NOT a ceiling. Decided 2026-09-02, replacing the
$500/week cap: the subscription meter resets Wed 15:59 PT and does NOT roll over, so
unspent quota is destroyed, not saved -- a dollar cap below the real ceiling throws away
paid capacity. The week closing 2026-08-05 ran fable $963 through the meter with no
clamp, which is why $963 is the floor used below and why $500 was capping at ~52% of
demonstrated-safe headroom.

What actually failed in the week closing 2026-09-02 was not the total. Two sessions ran
100% Fable for 600 and 542 consecutive requests and never once ran the running-total
command -- 1,142 requests, zero lookups. So this surfaces a number and asks for an
acknowledgment; it never refuses. A refusal can only destroy quota, and nobody was
overspending on purpose.

Entry points:
  --oneline     human one-liner (what a session runs by hand)
  --json        machine-readable, everything
  --hook        UserPromptSubmit hook: prints ONLY when a session on Fable is ahead of
                pace, and only every --every turns. Silent and cheap otherwise.
  --at-now      the (spend, timestamp) half of a meter reading, for the `meter` function
"""
import argparse, hashlib, json, os, sys, time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

HOME = Path.home()
HIST = HOME / ".claude" / "usage-history"
ROOT = HOME / ".claude" / "projects"
CACHE = HIST / "pace-cache.json"
STATE = HIST / "pace-state.json"
READINGS = HOME / "Obsidian" / "no-it-all" / "briefs" / "meter-readings.md"
PT = ZoneInfo("America/Los_Angeles")
WEEK_WD, WEEK_H, WEEK_MIN = 2, 15, 59          # Wednesday 15:59 PT

# Observed-unclamped floors. NOT estimates -- each is a week that actually passed
# through the meter without a clamp, so the true cap is at least this.
FLOOR = {"fable": 963.0, "all": 2920.0}

PRICING = [
    ("fable-5", (10.0, 50.0)), ("mythos", (10.0, 50.0)),
    ("opus-5", (5.0, 25.0)), ("opus-4-8", (5.0, 25.0)), ("opus-4-7", (5.0, 25.0)),
    ("opus-4-6", (5.0, 25.0)), ("opus-4-5", (5.0, 25.0)),
    ("opus-4-1", (15.0, 75.0)), ("opus-4-2025", (15.0, 75.0)), ("opus", (5.0, 25.0)),
    ("sonnet", (3.0, 15.0)),
    ("haiku-3-5", (0.8, 4.0)), ("haiku", (1.0, 5.0)),
]
TIERS = ["fable", "opus", "sonnet", "haiku"]


def rates(model):
    for key, r in PRICING:
        if key in model:
            return r
    return (5.0, 25.0)


def tier(model):
    for t in TIERS:
        if t in model:
            return t
    return "other"


def cost_usd(u, model):
    """Identical pricing to usage-trend.py -- keep the two in step."""
    inp, out = rates(model)
    c = u.get("input_tokens", 0) * inp / 1e6
    c += u.get("output_tokens", 0) * out / 1e6
    c += u.get("cache_read_input_tokens", 0) * inp * 0.1 / 1e6
    cc = u.get("cache_creation") or {}
    if "ephemeral_5m_input_tokens" in cc or "ephemeral_1h_input_tokens" in cc:
        c += cc.get("ephemeral_5m_input_tokens", 0) * inp * 1.25 / 1e6
        c += cc.get("ephemeral_1h_input_tokens", 0) * inp * 2.0 / 1e6
    else:
        c += u.get("cache_creation_input_tokens", 0) * inp * 1.25 / 1e6
    return c


def week_close(dt):
    """The Wed-15:59-PT boundary closing dt's meter week, as YYYY-MM-DD."""
    loc = dt.astimezone(PT)
    cand = (loc + timedelta(days=(WEEK_WD - loc.weekday()) % 7)).replace(
        hour=WEEK_H, minute=WEEK_MIN, second=0, microsecond=0)
    if cand <= loc:
        cand += timedelta(days=7)
    return cand.strftime("%Y-%m-%d")


def week_bounds(close_label):
    close = datetime.strptime(close_label, "%Y-%m-%d").replace(
        hour=WEEK_H, minute=WEEK_MIN, tzinfo=PT)
    return close - timedelta(days=7), close


# ---------------------------------------------------------------- incremental scan

def _load_cache(week):
    """Cache is per-week; a new week discards the old one rather than migrating it."""
    try:
        c = json.loads(CACHE.read_text())
        if c.get("week") == week:
            c["seen"] = set(c.get("seen", []))
            return c
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    return {"week": week, "files": {}, "totals": {}, "seen": set()}


def _save_cache(c):
    out = dict(c)
    out["seen"] = sorted(c["seen"])
    tmp = CACHE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(out))
        tmp.replace(CACHE)
    except OSError:
        pass


def token_measures(u):
    """(raw, input-equivalent) tokens for one request.

    raw  -- every token class counted once. Cache reads are ~97% of all tokens here,
            so this differs from the dollar measure by roughly an order of magnitude;
            that gap is what makes the two distinguishable from a meter reading.
    ieq  -- tokens normalized to input-tokens-at-this-model's-rate: the same
            cache/output weighting the dollar figure uses, but WITHOUT the per-model
            price multiplier. It is the candidate that says "the meter counts tokens,
            weighted by cache class, but does not care that Fable costs 2x Opus."
    """
    cc = u.get("cache_creation") or {}
    i = u.get("input_tokens", 0)
    o = u.get("output_tokens", 0)
    cr = u.get("cache_read_input_tokens", 0)
    if "ephemeral_5m_input_tokens" in cc or "ephemeral_1h_input_tokens" in cc:
        c5 = cc.get("ephemeral_5m_input_tokens", 0)
        c1 = cc.get("ephemeral_1h_input_tokens", 0)
    else:
        c5, c1 = u.get("cache_creation_input_tokens", 0), 0
    raw = i + o + cr + c5 + c1
    ieq = i + cr * 0.1 + c5 * 1.25 + c1 * 2.0 + o * 5.0
    return raw, ieq


def scan(week, force=False):
    """Totals for `week`, reading only bytes appended since the last call.

    Transcripts are append-only JSONL, so a byte offset per file is sound. A file that
    shrank was rewritten or pruned -- reread it from zero rather than trusting the offset.
    Dedup by (message id, requestId) is kept because one request can land in more than one
    transcript (resumes, sidechains); without it a resumed session double-counts.
    """
    c = {"week": week, "files": {}, "totals": {}, "seen": set()} if force else _load_cache(week)
    tot = {k: float(v) for k, v in c.get("totals", {}).items()}
    seen, files = c["seen"], c["files"]
    for path in ROOT.rglob("*.jsonl"):
        parts = path.parts
        if "memory" in parts or "tool-results" in parts:
            continue
        key = str(path)
        try:
            size = path.stat().st_size
        except OSError:
            continue
        off = files.get(key, 0)
        if size < off:          # truncated or replaced
            off = 0
        if size == off:
            continue
        is_sub = "subagents" in parts
        try:
            fh = open(path, "r", errors="replace")
        except OSError:
            continue
        with fh:
            try:
                fh.seek(off)
            except OSError:
                fh.seek(0)
            for line in fh:
                if '"type":"assistant"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if e.get("type") != "assistant":
                    continue
                m = e.get("message") or {}
                u, model = m.get("usage"), m.get("model") or ""
                if not u or not model or model == "<synthetic>":
                    continue
                ts = e.get("timestamp")
                if not ts:
                    continue
                try:
                    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except ValueError:
                    continue
                if week_close(dt) != week:
                    continue
                k = hashlib.md5(f"{m.get('id')}|{e.get('requestId')}".encode()).hexdigest()[:12]
                if k in seen:
                    continue
                seen.add(k)
                cost, t = cost_usd(u, model), tier(model)
                raw, ieq = token_measures(u)
                tot["all"] = tot.get("all", 0.0) + cost
                tot[t] = tot.get(t, 0.0) + cost
                tot["sub" if is_sub else "main"] = tot.get("sub" if is_sub else "main", 0.0) + cost
                # Parallel accumulators in the two non-dollar candidate units, so a
                # meter reading can identify WHICH unit the meter counts (see
                # `--units`). Cheap to carry; impossible to reconstruct once
                # transcripts are pruned.
                tot["all_raw"] = tot.get("all_raw", 0.0) + raw
                tot["all_ieq"] = tot.get("all_ieq", 0.0) + ieq
                tot[f"{t}_raw"] = tot.get(f"{t}_raw", 0.0) + raw
                tot[f"{t}_ieq"] = tot.get(f"{t}_ieq", 0.0) + ieq
                if is_sub:
                    tot[f"sub_{t}"] = tot.get(f"sub_{t}", 0.0) + cost
            files[key] = fh.tell()
    c["totals"] = tot
    _save_cache(c)
    return tot


# ---------------------------------------------------------------- cap resolution

def read_readings():
    """Parse meter-readings.md.

    Columns are resolved by header name rather than position: the schema gained token
    columns on 2026-09-02 and will likely grow again, and an index-based parser
    silently mis-reads the old shape rather than failing loudly. Missing columns come
    back as None, which the analysis treats as "not measured" rather than zero.
    """
    rows = []
    if not READINGS.exists():
        return rows
    hdr = None
    NUM = {"all_pct": "all%", "fable_pct": "fable%", "all_at": "all$", "fable_at": "fable$",
           "all_raw": "all_tok", "fable_raw": "fable_tok",
           "all_ieq": "all_ieq", "fable_ieq": "fable_ieq"}
    for line in READINGS.read_text().splitlines():
        if not line.startswith("|"):
            continue
        f = [x.strip() for x in line.strip("|").split("|")]
        if hdr is None:
            if "week-close" in f:
                hdr = f
            continue
        if set("".join(f)) <= set("-: ") or not f[0]:
            continue
        get = lambda name: (f[hdr.index(name)] if name in hdr and hdr.index(name) < len(f) else "")
        def num(name):
            v = get(name).lstrip("$").rstrip("%").replace(",", "")
            try:
                return float(v)
            except ValueError:
                return None
        rec = {"week": f[0], "at": get("read at"), "note": get("note")}
        for k, col in NUM.items():
            rec[k] = num(col)
        if rec["all_pct"] is None or rec["fable_pct"] is None:
            continue
        rows.append(rec)
    return rows


UNITS = [("$", "all_at", "fable_at", "${:,.0f}"),
         ("raw tokens", "all_raw", "fable_raw", "{:,.0f}"),
         ("input-eq tokens", "all_ieq", "fable_ieq", "{:,.0f}")]


def implied_caps(rows, unit="$"):
    """cap = measure_at_reading / (meter% / 100), per meter, in one candidate unit.

    A reading below MIN_PCT is dropped: dividing a small measure by a small percentage
    amplifies the percentage's own rounding into a wildly wrong cap."""
    ak, fk = next((a, f) for u, a, f, _ in UNITS if u == unit)
    out = {"all": [], "fable": []}
    for r in rows:
        for meter, pct, at in (("all", r["all_pct"], r.get(ak)),
                               ("fable", r["fable_pct"], r.get(fk))):
            if at is not None and pct is not None and pct >= MIN_PCT and at > 0:
                out[meter].append(100.0 * at / pct)
    return out


def spread(vals):
    """max/min. The unit the meter actually counts is the one whose implied cap is
    STABLE across readings with different model mixes; the others swing."""
    vals = [v for v in vals if v > 0]
    if len(vals) < 2:
        return None
    return max(vals) / min(vals)


def resolve_cap(kind, rows):
    """Best available cap, and how much to trust it."""
    caps = implied_caps(rows)[kind]
    if caps:
        caps = sorted(caps)
        med = caps[len(caps) // 2] if len(caps) % 2 else (caps[len(caps) // 2 - 1] + caps[len(caps) // 2]) / 2
        return med, f"median of {len(caps)} meter reading(s)", True
    return FLOOR[kind], "observed-unclamped floor (no meter reading yet -- true cap is HIGHER)", False


# ---------------------------------------------------------------- pace

def pace(now=None, force=False):
    now = now or datetime.now().astimezone()
    wk = week_close(now)
    open_, close = week_bounds(wk)
    span = (close - open_).total_seconds()
    elapsed = max(0.0, min(1.0, (now.astimezone(PT) - open_).total_seconds() / span))
    tot = scan(wk, force=force)
    rows = [r for r in read_readings() if r["week"] == wk]
    fable = tot.get("fable", 0.0)
    cap, basis, calibrated = resolve_cap("fable", rows)
    consumed = fable / cap if cap else 0.0
    return {
        "week": wk, "now": now.astimezone(PT).isoformat(timespec="minutes"),
        "elapsed": elapsed, "days_left": (close - now.astimezone(PT)).total_seconds() / 86400,
        "fable": fable, "all": tot.get("all", 0.0),
        "main": tot.get("main", 0.0), "sub": tot.get("sub", 0.0),
        "sub_fable": tot.get("sub_fable", 0.0),
        "cap": cap, "cap_basis": basis, "calibrated": calibrated,
        "consumed": consumed, "ahead_by": consumed - elapsed,
        "projected": fable / elapsed if elapsed > 0.02 else 0.0,
    }


def verdict(p, margin):
    """Ahead of pace, or nearly out of week. Neither is a refusal."""
    if p["consumed"] >= 0.90:
        return "near-cap"
    if p["ahead_by"] > margin:
        return "ahead"
    return "ok"


def fmt(p, margin):
    v = verdict(p, margin)
    mark = {"ok": "on pace", "ahead": "AHEAD OF PACE", "near-cap": "NEAR CAP"}[v]
    return (f"fable ${p['fable']:,.0f} = {100*p['consumed']:.0f}% of cap ${p['cap']:,.0f} "
            f"({p['cap_basis']}) | week {100*p['elapsed']:.0f}% elapsed, "
            f"{p['days_left']:.1f}d left | {mark} | all-models ${p['all']:,.0f}")


# ---------------------------------------------------------------- hook

def last_model(transcript):
    """Model of the most recent assistant turn. The hook only speaks to sessions actually
    spending Fable -- an Opus session has nothing to decide."""
    try:
        p = Path(transcript)
        size = p.stat().st_size
        with open(p, "r", errors="replace") as fh:
            fh.seek(max(0, size - 400_000))
            tail = fh.read()
    except OSError:
        return ""
    # No compact-separator fast path here, deliberately. scan() uses one because it
    # walks millions of lines and is validated against usage-trend.py's identical
    # filter; this walks a few hundred and stops at the first assistant record, so the
    # filter would buy nothing and cost correctness -- a writer emitting
    # '"type": "assistant"' with a space would make this silently return "" and the
    # hook would go quiet forever, which is the one failure mode nobody would notice.
    for line in reversed(tail.splitlines()):
        try:
            e = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(e, dict) and e.get("type") == "assistant":
            m = (e.get("message") or {}).get("model") or ""
            if m and m != "<synthetic>":
                return m
    return ""


def hook(args):
    """Fires on UserPromptSubmit. Silence is the normal outcome; anything printed to
    stdout lands in the session's context."""
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    sid = payload.get("session_id") or "?"
    transcript = payload.get("transcript_path") or ""

    if tier(last_model(transcript)) != "fable":
        return 0

    try:
        st = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        st = {}
    s = st.get(sid) or {"turns": 0, "last": 0.0, "acked_at": 0.0}
    s["turns"] = s.get("turns", 0) + 1

    due = s["turns"] - s.get("last_fire_turn", 0) >= args.every
    if not due:
        st[sid] = s
        _write_state(st)
        return 0

    p = pace()
    v = verdict(p, args.margin)
    if v == "ok":
        s["last_fire_turn"] = s["turns"]
        st[sid] = s
        _write_state(st)
        return 0

    # Re-surfacing the same verdict every N turns after an acknowledgment is nagging,
    # not information. Escalating to near-cap always speaks again.
    if s.get("acked") == v:
        s["last_fire_turn"] = s["turns"]
        st[sid] = s
        _write_state(st)
        return 0

    s["last_fire_turn"] = s["turns"]
    s["acked"] = v
    st[sid] = s
    _write_state(st)

    head = ("FABLE PACE — near the cap" if v == "near-cap" else "FABLE PACE — ahead of the week")
    print(f"""<usage-pace>
{head}. This is a prompt to decide, NOT a limit — continuing is always allowed and
a week that paces to 100% is the system working. Unspent quota does not roll over.

  {fmt(p, args.margin)}
  at this rate the week ends near ${p['projected']:,.0f} of fable spend
""" + ("""  the cap above is a floor, not a measurement — no meter reading exists for this
  week, so the real cap is HIGHER and this reading errs toward surfacing early.
  Running `meter` records one (it prompts; any day, any time).
""" if not p["calibrated"] else "") + f"""{'  RULE BREACH: $%.2f of fable spend is in SUBAGENTS, which the scope forbids outright.' % p['sub_fable'] if p['sub_fable'] > 0 else ''}
Tell the user where the week stands in one line and ask whether to stay on Fable or
drop to Opus for this work. Then do what they say. Do not re-raise this unprompted.
</usage-pace>""")
    return 0


def _write_state(st):
    try:
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(STATE)
    except OSError:
        pass


# ---------------------------------------------------------------- main

MIN_PCT = 5.0   # below this, spend/(pct/100) amplifies rounding in the percentage
                # into hundreds of dollars of implied cap -- record it, don't imply from it


def record(all_pct, fable_pct, note):
    """Write one meter reading, capturing spend at the same instant as the percentage.

    Lives here rather than in the `meter` shell function so the implied-cap rule has ONE
    implementation. A confirmation printed by zsh with its own arithmetic was reporting
    caps from readings that implied_caps() then correctly discarded -- a second derivation
    disagreeing with the first, which is the defect class this repo keeps re-learning.
    """
    for name, v in (("all-models", all_pct), ("fable", fable_pct)):
        if not (0.0 <= v <= 100.0):
            print(f"REFUSE: {name} percentage {v} is not in 0-100", file=sys.stderr)
            return 1
    now = datetime.now().astimezone()
    wk = week_close(now)
    tot = scan(wk)
    at = now.astimezone(PT).isoformat(timespec="minutes")
    all_at, fable_at = tot.get("all", 0.0), tot.get("fable", 0.0)

    READINGS.parent.mkdir(parents=True, exist_ok=True)
    if not READINGS.exists():
        READINGS.write_text(
            "# Meter readings (by hand from /usage — any day of the meter week)\n\n"
            "Each row pairs a meter percentage with the usage measured at the SAME\n"
            "instant, in THREE candidate units, because it is not established which one\n"
            "the meter actually counts:\n\n"
            "- `all$` / `fable$` — dollars at list price (cache reads x0.1, output x5,\n"
            "  and Fable x2 vs Opus).\n"
            "- `all_tok` / `fable_tok` — raw tokens, every class counted once. Cache reads\n"
            "  are ~97% of all tokens, so this differs from dollars by roughly 10x.\n"
            "- `all_ieq` / `fable_ieq` — input-equivalent tokens: the same cache/output\n"
            "  weighting as dollars, but blind to the per-model price multiplier.\n\n"
            "Implied cap = measure / (pct/100). The unit the meter really counts is the\n"
            "one whose implied cap stays STABLE across readings taken at different model\n"
            "mixes; the others swing. `usage-pace.py --units` does that comparison, and\n"
            "`--caps` reports the dollar view.\n\n"
            "Several rows per week is better than one — each is an independent estimate,\n"
            "and two readings bracketing a stretch of known model mix are stronger still.\n\n"
            "| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok "
            "| all_ieq | fable_ieq | note |\n"
            "|---|---|---|---|---|---|---|---|---|---|---|\n")
    with open(READINGS, "a") as fh:
        fh.write(f"| {wk} | {at} | {all_pct:g}% | {fable_pct:g}% | "
                 f"{all_at:.2f} | {fable_at:.2f} | "
                 f"{tot.get('all_raw', 0):.0f} | {tot.get('fable_raw', 0):.0f} | "
                 f"{tot.get('all_ieq', 0):.0f} | {tot.get('fable_ieq', 0):.0f} | "
                 f"{note.replace('|', ' ')} |\n")

    try:
        (HIST / f"READING-DUE-{wk}").unlink()
    except OSError:
        pass

    print(f"recorded: week {wk} at {at}")
    for name, pct, at_ in (("all-models", all_pct, all_at), ("fable", fable_pct, fable_at)):
        if pct < MIN_PCT or at_ <= 0:
            why = (f"under {MIN_PCT:g}% — too little signal" if pct < MIN_PCT
                   else "no spend recorded at this instant")
            print(f"  {name:11s} {pct:g}% of cap, ${at_:,.2f} spent  -> no cap implied "
                  f"({why}; the row is still recorded)")
        else:
            print(f"  {name:11s} {pct:g}% of cap, ${at_:,.2f} spent  -> cap ~${100*at_/pct:,.0f}")
    rows = read_readings()
    n = sum(1 for r in rows if r["week"] == wk)
    if n > 1:
        print(f"  ({n} readings for this week — each is an independent estimate; "
              f"`usage-pace.py --caps` reconciles them)")
    print(f"  -> {READINGS}")
    return 0


def units_report(rows):
    """Which unit does the meter count? Compare implied-cap stability across readings."""
    if len(rows) < 2:
        print(f"{len(rows)} reading(s) on file. The unit test needs at least 2 taken at")
        print("DIFFERENT model mixes -- ideally two in one week bracketing a stretch that")
        print("was mostly Opus, and another bracketing a stretch that was mostly Fable.")
        print("Until then no unit can be ruled out, and the dollar view is an ASSUMPTION.")
        if rows:
            print()
        else:
            return 0
    print("Implied cap per candidate unit. The real unit is the one whose implied cap is")
    print("STABLE across readings (spread near 1.00); the others swing with model mix.\n")
    verdicts = []
    for unit, ak, fk, fmt in UNITS:
        caps = implied_caps(rows, unit)
        print(f"-- meter counts {unit}? --")
        for meter in ("all", "fable"):
            v = caps[meter]
            if not v:
                print(f"   {meter:6s} no usable reading (need pct >= {MIN_PCT:g}% and a measure)")
                continue
            sp = spread(v)
            shown = "  ".join(fmt.format(x) for x in v)
            line = f"   {meter:6s} {shown}"
            if sp is not None:
                line += f"   spread {sp:.2f}x"
                verdicts.append((sp, unit, meter))
            print(line)
        print()
    if not verdicts:
        return 0
    best = min(verdicts)
    # Report ties as ties. Dollars and input-eq tokens differ ONLY by the per-model
    # price multiplier, so a set of readings taken at a near-constant Fable share
    # makes them mathematically degenerate -- both fit perfectly and picking the
    # min() silently returns whichever sorts first. Verified against synthetic data
    # where that arbitrary pick named the wrong unit.
    tied = sorted({u for sp, u, m in verdicts if sp <= best[0] * 1.02})
    if len(tied) > 1:
        print(f"DEGENERATE: {' and '.join(tied)} fit equally well "
              f"(spread {best[0]:.2f}x). These readings cannot separate them.")
        if "$" in tied and "input-eq tokens" in tied:
            print("  $ and input-eq tokens differ ONLY by the per-model price multiplier,")
            print("  so they are indistinguishable while the Fable share is near-constant.")
            print("  To separate them: take one reading bracketing a mostly-Fable stretch")
            print("  and another bracketing a mostly-Opus one. Fable share has ranged")
            print("  0%-30% of spend across weeks, which is ample once both are sampled.")
        return 0
    print(f"tightest: {best[1]} on the {best[2]} meter, spread {best[0]:.2f}x")
    if best[0] < 1.10:
        print("  -> consistent with the meter counting this unit, and this unit alone.")
    else:
        print("  -> nothing is tight yet. Either the readings share too similar a")
        print("     model mix to discriminate, or the meter counts something else.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--oneline", action="store_true", help="human one-liner")
    g.add_argument("--json", action="store_true", help="everything, machine-readable")
    g.add_argument("--hook", action="store_true", help="UserPromptSubmit hook mode")
    g.add_argument("--at-now", action="store_true", help="spend+timestamp for a meter reading")
    g.add_argument("--caps", action="store_true", help="implied caps from every meter reading")
    g.add_argument("--units", action="store_true",
                   help="which unit does the meter count? (needs >=2 readings)")
    g.add_argument("--record", nargs="*", metavar="VAL",
                   help="record a meter reading: [all-pct] [fable-pct] [note]; "
                        "with no values, prompts for them")
    ap.add_argument("--every", type=int, default=40, help="hook: turns between checks (default 40)")
    ap.add_argument("--margin", type=float, default=0.15,
                    help="hook: how far ahead of elapsed time before speaking (default 0.15)")
    ap.add_argument("--force", action="store_true", help="ignore the incremental cache")
    a = ap.parse_args()

    if a.hook:
        return hook(a)

    if a.units:
        return units_report(read_readings())

    if a.record is not None:
        vals, note = a.record[:2], " ".join(a.record[2:])
        if len(vals) < 2:
            # Prompting rather than printing a usage line with <placeholders> in it.
            # 2026-09-02: the placeholder form was handed to a shell verbatim and zsh
            # read the angle brackets as redirections ("parse error near `<'"). A
            # command whose documented form cannot be run as written is a bad command;
            # asking for the two numbers removes the substitution step entirely.
            if not sys.stdin.isatty():
                # A concrete example, not angle-bracket placeholders: this line gets
                # pasted straight into a shell, where `<all-pct>` is a redirection.
                print("usage: meter 87 46 \"optional note\"    "
                      "(percentages from /usage: all-models, then fable)\n"
                      "   or: meter                            "
                      "(prompts for them)", file=sys.stderr)
                return 1
            print("Reading the /usage meter. Enter the two percentages it shows.")
            print("(blank to cancel — nothing is written)")
            vals = []
            for label in ("all-models", "fable"):
                while True:
                    try:
                        raw = input(f"  {label} % of cap: ").strip().rstrip("%")
                    except (EOFError, KeyboardInterrupt):
                        print("\ncancelled — nothing written", file=sys.stderr)
                        return 1
                    if not raw:
                        print("cancelled — nothing written", file=sys.stderr)
                        return 1
                    try:
                        v = float(raw)
                    except ValueError:
                        print("    not a number — try again, e.g. 87 or 87.5")
                        continue
                    if not (0.0 <= v <= 100.0):
                        print("    must be between 0 and 100 — try again")
                        continue
                    vals.append(v)
                    break
            if not note:
                try:
                    note = input("  note (optional, Enter to skip): ").strip()
                except (EOFError, KeyboardInterrupt):
                    note = ""
        else:
            try:
                vals = [float(x.rstrip("%")) for x in vals]
            except ValueError:
                print("REFUSE: percentages must be numeric", file=sys.stderr)
                return 1
        return record(vals[0], vals[1], note)

    if a.at_now:
        # Consumed by the `meter` shell function: capture spend at the same instant as
        # the percentage, so the pair is self-contained and survives transcript pruning.
        now = datetime.now().astimezone()
        tot = scan(week_close(now), force=a.force)
        print(json.dumps({"week": week_close(now),
                          "at": now.astimezone(PT).isoformat(timespec="minutes"),
                          "all": round(tot.get("all", 0.0), 2),
                          "fable": round(tot.get("fable", 0.0), 2)}))
        return 0

    if a.caps:
        rows = read_readings()
        if not rows:
            print("no meter readings recorded — every cap in use is an observed-unclamped floor:")
            for k, v in FLOOR.items():
                print(f"  {k:6s} > ${v:,.0f}")
            return 0
        caps = implied_caps(rows)
        def cap_cell(pct, at_):
            if pct < MIN_PCT or at_ <= 0:
                return "n/a"
            return f"${100 * at_ / pct:,.0f}"

        print(f"{'week':12}{'read at':18}{'all%':>6}{'all$':>10}{'-> cap':>11}"
              f"{'fbl%':>7}{'fbl$':>9}{'-> cap':>11}")
        for r in rows:
            print(f"{r['week']:12}{r['at'][:16]:18}{r['all_pct']:5.0f}%{r['all_at']:10,.0f}"
                  f"{cap_cell(r['all_pct'], r['all_at']):>11}"
                  f"{r['fable_pct']:6.0f}%{r['fable_at']:9,.0f}"
                  f"{cap_cell(r['fable_pct'], r['fable_at']):>11}")
        for k in ("all", "fable"):
            cap, basis, cal = resolve_cap(k, rows)
            print(f"  {k:6s} cap ${cap:,.0f}  ({basis})")
        return 0

    p = pace(force=a.force)
    if a.json:
        print(json.dumps(p, indent=2))
    else:
        print(fmt(p, a.margin))
    return 0


if __name__ == "__main__":
    sys.exit(main())
