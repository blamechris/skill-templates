#!/usr/bin/env python3
"""Report the live usage meter, and what this week's own burn does to it.

The instrument here is deliberately NOT a ceiling. Decided 2026-09-02, replacing the
$500/week cap: the subscription meter resets Wed 15:59 PT and does NOT roll over, so
unspent quota is destroyed, not saved -- a dollar cap below the real ceiling throws away
paid capacity, and $500 was well below it.

THE PERCENTAGE IS READ, NEVER COMPUTED. The desktop app persists the real meter to
plan-usage-history.json every time its UI polls /usage, and that file is the ground
truth. This script had it open and printed a derived number beside it anyway: week spend
divided by a cached median cap, which read "96% of cap | NEAR CAP" while the live meter
read 79. Every percentage in --oneline, --hook and --json now comes from that file, with
the age of the sample beside it, because a sample can be forty minutes old and its age is
part of the reading. A sample from BEFORE this meter period is not a reading of it at all
and is refused: the app stops sampling across a closed laptop, so after a Wednesday reset
the newest one on file is still the old week's ~95%, and pairing that with the new week's
spend put the wall minutes away and had --hook announce the week was lost.

The cap in the pacing path is this week's OWN rate -- spend since the meter's observed
zero, divided by the points the meter has moved -- and it self-calibrates on every call.
That replaces every cached, regressed or inferred cap, because the cap is not a constant:
per-week endpoint caps over clean periods measured $2,505 / $2,374 / $2,417 / $2,536, and
dividing this week's spend by another week's median is what produced the 96/79 split.

What actually failed in the week closing 2026-09-02 was not the total. Two sessions ran
100% Fable for 600 and 542 consecutive requests and never once ran the running-total
command -- 1,142 requests, zero lookups. So this surfaces numbers and asks for an
acknowledgment; it never refuses. A refusal can only destroy quota, and nobody was
overspending on purpose.

It also makes no claim about what 100% does. Lockout has never been observed here -- the
"29 hours with nothing served" in the record was a closed laptop, and requests near 100%
were served -- so the warnings below talk about the wall's ARRIVAL TIME, never about what
is on the other side of it.

Entry points:
  --oneline     human one-liner (what a session runs by hand)
  --json        machine-readable, everything
  --hook        UserPromptSubmit hook: prints ONLY when the burn would waste or exhaust
                the week, and only every --every turns. Silent and cheap otherwise.
  --at-now      the (spend, timestamp) half of a meter reading, for the `meter` function
"""
import argparse, bisect, hashlib, json, math, os, sys, time
from datetime import datetime, timedelta, timezone
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

# DERIVED figures, used only when there is no live sample AND no reading on file -- i.e.
# on a machine with no desktop app, which is the only place the derived path runs at all.
# They are statistics, not measurements: all-models is a regression over 6 meter periods
# (mean R2 0.994, 2026-09-04) whose own periods span $1,979-$2,870, and Fable is one
# reading pair 17 points apart (2026-09-05). Both replaced a larger number that came from
# "this week ran without a clamp, so the cap is above it" -- an inference both figures
# falsified, which is why neither is called a measurement here either. The live readout
# never touches them; the cap it uses is this week's own rate.
FALLBACK = {"fable": 920.0, "all": 2363.0}

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


# `mythos` is priced at the Fable rate in PRICING, so it must TIER as fable too.
# usage-trend.py has the same table and the same plain substring match, so it also
# buckets mythos as "other" -- a Fable-priced model invisible to a Fable pace check
# is the guard-never-fires failure this script exists to prevent. Fixed here; the
# sibling needs the same fix (follow-on -- it is not in this registry).
TIER_ALIASES = {"mythos": "fable"}


def tier(model):
    for alias, t in TIER_ALIASES.items():
        if alias in model:
            return t
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
        # A non-dict is VALID json (`[1,2,3]`, `null`, `"x"`): json.loads succeeds and
        # the .get() below raised AttributeError, which was NOT caught -- so a
        # malformed cache crashed the hook with no self-repair. ValueError covers
        # JSONDecodeError and UnicodeDecodeError (invalid UTF-8) alike.
        if isinstance(c, dict) and c.get("week") == week and isinstance(c.get("files"), dict):
            c["seen"] = set(c.get("seen") or [])
            c["totals"] = c["totals"] if isinstance(c.get("totals"), dict) else {}
            return c
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return {"week": week, "files": {}, "totals": {}, "seen": set()}


def _save_cache(c):
    out = dict(c)
    out["seen"] = sorted(c["seen"])
    tmp = CACHE.with_suffix(".tmp")
    try:
        # Create the parent: it does not exist on a freshly bootstrapped machine, and
        # the except-OSError below swallowed the failure -- so the turn counter never
        # persisted, `--every` never came due, and the pace check was permanently
        # silent exactly where a new machine needed it most.
        HIST.mkdir(parents=True, exist_ok=True)
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


def _cache_stale(files):
    """True when the cached totals describe bytes that no longer exist.

    The totals are ONE accumulator across every file; there is no per-file ledger, so
    a file that shrank cannot have its old contribution subtracted -- re-reading it
    from zero (which the previous code did) ADDED its new content on top of the stale
    total and inflated the week permanently. `record()` scans without force, so that
    inflated number could be written into meter-readings.md, which the implied-cap and
    pace arithmetic then treat as ground truth.

    Rather than carry a per-file ledger, detect the anomaly and discard the whole
    cache: a full rescan is ~5s and these events are rare (transcript pruning, a
    resumed session rewriting a file, a deletion). Correct and cheap beats clever.

    Three anomalies, all meaning "not a pure append since the last scan":
      - the file is gone      -- its contribution is still in the totals
      - the file shrank       -- rewritten or pruned
      - same size, new mtime  -- replaced in place; a byte-offset check cannot see it
    """
    for key, rec in (files or {}).items():
        off, mt = rec if isinstance(rec, (list, tuple)) and len(rec) == 2 else (rec, None)
        try:
            st = os.stat(key)
        except OSError:
            return True
        if not isinstance(off, (int, float)) or st.st_size < off:
            return True
        if mt is not None and st.st_size == off and st.st_mtime != mt:
            return True
    return False


def bucket_of(ms):
    """The minute-since-epoch a millisecond instant belongs to."""
    return int(ms // 60000)


def _load_buckets(c):
    """Per-minute spend from the cache, validated entry by entry.

    A malformed entry is dropped rather than raising: this rides in the same file as
    the totals, which `_load_cache` already treats as untrusted, and the pace check
    must not crash on a cache some other version wrote.
    """
    bk = {}
    for k, v in (c.get("bk") or {}).items() if isinstance(c.get("bk"), dict) else ():
        try:
            m = int(k)
            a, f = float(v[0]), float(v[1])
        except (TypeError, ValueError, IndexError, KeyError):
            continue
        if math.isfinite(a) and math.isfinite(f):
            bk[m] = [a, f]
    return bk


def window_spend(bk, lo_ms, hi_ms=None):
    """(all, fable) dollars in (lo, hi], from the per-minute index.

    Resolution is one minute, so a window is a whole number of minute buckets and one of
    its two ends has to give. Which end is not a matter of taste: `hi_ms` is almost always
    NOW (or the instant the meter was read) and is almost never on a minute boundary, so
    rounding the top end DOWN -- which `[lo, hi)` over buckets did -- dropped the minute
    in progress entirely. That is the minute the most recent request landed in, so the
    live figures ran up to a minute behind: `spend since the reset`, the rate's numerator,
    and `burn_1h` (the sole input to the wall, and so to the lockout warning) each
    understated by whatever had just been spent.

    So the buckets are `(bucket_of(lo), bucket_of(hi)]` -- the top end rounds UP to include
    the minute in progress, and the bottom end rounds up with it. That keeps the one
    property the callers depend on, which a "include both ends" fix would have destroyed:
    adjacent windows PARTITION. `window(anchor, s) + window(s, now) == window(anchor, now)`
    exactly, for any split instant `s`, because the bucket containing `s` belongs to the
    lower window and to nothing else. `pace` splits at the sample for precisely that
    reason, and prints `spend` beside the two halves it is made of.

    What the bottom end gives up is the bucket containing `lo` itself, and in both callers
    that is the right bucket to give up. `lo` is the meter's zero: that minute STRADDLES
    the reset, so its spend cannot be attributed to either side of it -- and it now lands
    in the `(prev, anchor]` gap window, which `pace` already reports as a range for exactly
    this reason. When no reset was seen at all, `lo` is the week open -- and that bucket is
    NOT partly last week's, however much it looks as though it should be: `scan_detail`
    keeps only events whose own `week_close` is this week, so no dollar of last week's is
    ever in this week's index to drop. What the drop costs there is up to the first minute
    of THIS week's own spend, and that is the honest reason to accept it -- one bucket, at
    the start of a week measured in hours, against a partition property every split figure
    on the line depends on.

    A full transcript walk per invocation would resolve the whole question and costs ~4
    seconds on every hook fire, which is why the index is per-minute in the first place.
    """
    lo = bucket_of(lo_ms)
    hi = bucket_of(hi_ms) if hi_ms is not None else None
    a = f = 0.0
    for m, v in bk.items():
        if m <= lo or (hi is not None and m > hi):
            continue
        a += v[0]
        f += v[1]
    return a, f


def scan(week, force=False):
    """Totals for `week` -- see scan_detail, of which this is the totals-only half."""
    return scan_detail(week, force=force)[0]


def scan_detail(week, force=False):
    """(totals, per-minute buckets) for `week`, reading only bytes appended since the
    last call.

    Transcripts are append-only JSONL, so a byte offset per file is sound. A file that
    shrank was rewritten or pruned -- reread it from zero rather than trusting the offset.
    Dedup by (message id, requestId) is kept because one request can land in more than one
    transcript (resumes, sidechains); without it a resumed session double-counts.

    The per-minute index exists because the live readout needs spend since an ARBITRARY
    instant (the meter's observed zero) and over the last hour and three hours, and the
    week totals cannot answer either. It is built here rather than by a second walk for
    one reason: the anchor is never earlier than the week open, so everything the readout
    needs is inside the window this function already scans -- incrementally, from a byte
    offset. `_cum_events` still walks every transcript ever for `--calibrate`, and takes
    ~4 seconds doing it; that is acceptable once, and not on every fortieth prompt.
    """
    fresh = {"week": week, "files": {}, "totals": {}, "seen": set()}
    c = fresh if force else _load_cache(week)
    if not force and _cache_stale(c["files"]):
        c = {"week": week, "files": {}, "totals": {}, "seen": set()}
    tot = {k: float(v) for k, v in c.get("totals", {}).items()}
    bk = {} if force else _load_buckets(c)
    # The index and the totals are two accumulators over the same events, so they must
    # agree; when they do not, the cache predates the index (or lost part of it) and the
    # offsets say there is nothing left to read. That combination is silent and badly
    # wrong: on the first run after this file gained the index, spend since the anchor
    # came back as $61 against a true $2,533, because only the minutes scanned AFTER the
    # upgrade were in it. A full rescan is ~5s and happens once.
    if not force and abs(sum(v[0] for v in bk.values()) - tot.get("all", 0.0)) > 0.01:
        c = {"week": week, "files": {}, "totals": {}, "seen": set()}
        tot, bk = {}, {}
    seen, files = c["seen"], c["files"]
    for path in ROOT.rglob("*.jsonl"):
        parts = path.parts
        if "memory" in parts or "tool-results" in parts:
            continue
        key = str(path)
        try:
            stt = path.stat()
        except OSError:
            continue
        size, mtime = stt.st_size, stt.st_mtime
        rec = files.get(key, 0)
        off = rec[0] if isinstance(rec, (list, tuple)) and len(rec) == 2 else rec
        if not isinstance(off, (int, float)) or size < off:
            off = 0
        if size == off:
            files[key] = [off, mtime]
            continue
        is_sub = "subagents" in parts
        # Read bytes, not text lines, and stop at the last newline. A transcript being
        # appended to right now can present a PARTIAL final line; the text iterator
        # yields it, json.loads rejects it, and fh.tell() then recorded an offset PAST
        # those bytes -- so when the rest of that record landed it was never re-read
        # and the request was silently dropped from the week.
        try:
            with open(path, "rb") as fh:
                fh.seek(off)
                data = fh.read()
        except OSError:
            continue
        cut = data.rfind(b"\n")
        if cut < 0:                     # nothing complete yet; hold the offset
            files[key] = [off, mtime]
            continue
        consumed = cut + 1
        for raw in data[:consumed].split(b"\n"):
            if not raw:
                continue
            line = raw.decode("utf-8", "replace")
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
            b = bk.setdefault(bucket_of(dt.timestamp() * 1000), [0.0, 0.0])
            b[0] += cost
            if t == "fable":
                b[1] += cost
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
        # Outside the line loop: the offset must advance even when this chunk held no
        # parseable assistant records, or those bytes are re-read on every scan forever.
        files[key] = [off + consumed, mtime]
    c["totals"] = tot
    # Keys are stringified because JSON object keys are strings anyway; _load_buckets
    # turns them back into ints. A week holds at most 10,080 of them.
    c["bk"] = {str(m): v for m, v in bk.items()}
    _save_cache(c)
    return tot, bk


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


# The Claude desktop app samples the plan meters every ~15 minutes and persists them
# here. `sd` is the seven-day (weekly) ALL-MODELS meter -- the same number /usage shows --
# and `fh` is the five-hour session meter. Validated 2026-09-04 against a hand-recorded
# reading: the screen read session 31% / all-models 8% at 21:52 PT on 2026-09-02, and the
# sample one minute later reads {"fh": 32, "sd": 8}.
#
# This is why meter readings never needed a human. It is macOS-desktop-app state, so it is
# absent on a headless or non-desktop machine -- every consumer of it degrades to the
# hand-recorded readings rather than failing.
#
# NOTE: there is no Fable field. Only the all-models meter can be calibrated from here;
# the Fable cap still needs a hand-recorded reading.
PLAN_SAMPLES = HOME / "Library" / "Application Support" / "Claude" / "plan-usage-history.json"
CALIB = HIST / "pace-calibration.json"
RESET_DROP = 2           # a sd fall of more than this is a reset, not noise
MIN_SEG_SPAN = 15        # a period must cover this many points to be worth fitting


def _num(v):
    """A finite number, or None. json.loads accepts Infinity/NaN and bool subclasses int.

    A NaN `sd` reaches _fit and produces a NaN slope, which the `b <= 0` guard does NOT
    reject -- every NaN comparison is False. Today the R2 filter happens to catch it
    downstream; relying on that is relying on an accident.
    """
    if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
        return float(v)
    return None


def _plan_raw():
    """Sorted (epoch_ms, weekly_pct, five_hour_pct_or_None) from the desktop app.

    One parser, two views: `plan_samples` drops `fh` for the regression machinery, and
    `live_sample` needs it. A second reader of the same file is how two answers to one
    question start.
    """
    try:
        d = json.loads(PLAN_SAMPLES.read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(d, dict) or not isinstance(d.get("samples"), list):
        return []
    out = []
    for x in d["samples"]:
        if not isinstance(x, dict):
            continue
        u = x.get("u") if isinstance(x.get("u"), dict) else {}
        t, sd = _num(x.get("t")), _num(u.get("sd"))
        if t is not None and sd is not None:
            out.append((t, sd, _num(u.get("fh"))))
    return sorted(out)


def plan_samples():
    """Sorted (epoch_ms, weekly_pct) from the desktop app, or [] when unavailable."""
    return [(t, sd) for t, sd, _ in _plan_raw()]


def live_sample(now_ms=None, samples=None):
    """The newest persisted meter reading: the authoritative live percentage.

    Sampling is NOT on a clock -- the app writes when its UI polls /usage, so samples
    cluster around those moments and the newest one can be 15 or 48 minutes old. The age
    is returned with it and printed with it, because a stale percentage read as current
    is the same defect as a computed one read as measured.

    The age is reported here and ACTED ON in `pace`, which refuses a sample older than the
    anchor outright: a reading of the previous meter period is not a stale reading of this
    one, it is a reading of something else. What staleness inside the period costs is
    handled by arithmetic instead of refusal -- `derive` measures the rate at the sample's
    own instant and carries the meter forward over the gap.

    `samples` is injectable for the same reason `observed_anchor`'s is: the caller that
    needs both must read the file ONCE and hand the same snapshot to each. The app writes
    it every ~15 minutes and at every /usage poll, so two reads a few milliseconds apart
    can straddle a write -- and the two answers then disagree about which meter period is
    current, which is the one disagreement this file cannot afford.
    """
    raw = _plan_raw() if samples is None else samples
    if not raw:
        return None
    t, sd, fh = raw[-1]
    now_ms = datetime.now(timezone.utc).timestamp() * 1000 if now_ms is None else now_ms
    return {"t": t, "sd": sd, "fh": fh,
            "at": f"{datetime.fromtimestamp(t / 1000, timezone.utc):%H:%M}Z",
            "age_min": max(0.0, (now_ms - t) / 60000.0)}


LIVE_DROP = 15.0        # a fall this large between two samples is a reset, not noise
STALE_MIN = 30.0        # a sample older than this is called stale in the readout
MIN_MOVED = 5.0         # points the meter must have moved before its $/pt may extrapolate


def observed_anchor(open_ms, samples=None):
    """The meter's zero: (anchor_ms, prev_ms, anchor_sd, label).

    The right anchor is the LATER sample of the newest pair across which the meter fell.
    On 2026-09-09 that pair is sd=100 at 22:52:56Z -> sd=0 at 23:09:58Z with $0.00 of
    local spend in the 17-minute gap, so the anchor is exact and there is nothing to
    estimate. `prev_ms` is returned so the caller can price that gap: when it holds
    spend, the total is a RANGE (anchored at either sample) and is reported as one,
    rather than fitted.

    Fitting is what the previous code did -- it subtracted a regression INTERCEPT as
    "spend the meter already forgot" and took $215 off a week where the samples show
    nothing was forgotten, the intercept having absorbed an anomaly in the period's
    first 20 points instead.

    A drop counts when the LATER sample lands at or after the week open, and the earlier
    one may sit before it -- which is the ordinary shape of the SCHEDULED reset, not an
    edge case: the 2026-09-09 boundary fell at 22:59Z between samples at 22:52:56Z (sd
    100) and 23:09:58Z (sd 0). Requiring both samples to be in-week hid that pair, fell
    back to the boundary instant, and anchored eleven minutes early -- counting spend
    against a meter that had not yet zeroed. With no drop at all since the boundary, the
    boundary is the zero.

    `anchor_sd` is the meter's reading AT the anchor, and it is returned because a fall of
    LIVE_DROP or more does not prove the meter landed on zero. The app samples when its UI
    polls /usage, so the first post-reset sample can arrive after points have already been
    burned: a 100 -> 40 pair passes the threshold, and dividing spend-since-40 by a
    CURRENT reading of 82 then prices 42 points of movement as 82 -- roughly half the true
    $/pt, which halves the headroom and fires the lockout warning spuriously. The caller
    differences instead (`sd - anchor_sd`), which is exact whatever the anchor read and
    needs no near-zero requirement of its own.
    """
    s = _plan_raw() if samples is None else samples
    for i in range(len(s) - 1, 0, -1):
        if s[i][0] < open_ms:
            break
        if s[i - 1][1] - s[i][1] >= LIVE_DROP:
            when = datetime.fromtimestamp(s[i][0] / 1000, PT)
            return (s[i][0], s[i - 1][0], s[i][1],
                    f"the {when:%m-%d %H:%M} PT reset (sd {s[i - 1][1]:.0f} -> {s[i][1]:.0f})")
    return open_ms, None, 0.0, "the Wed 15:59 PT boundary (no reset seen since)"


def _is_reset(prev, cur):
    """The single definition of "the meter reset between these two samples".

    Both _segments and reset_between need this, and they had it twice with different
    rules: _segments gained the fall-to-zero clause after review, reset_between was
    written afterwards without it, so a 2% -> 0% reset split a regression period but
    did NOT disqualify a reading pair spanning it. Two predicates for one concept is
    the drift this repo has CI about; there is now one.

    A fall of more than RESET_DROP is a reset; so is any fall to zero from a positive
    value, which a threshold alone misses late in a quiet week.
    """
    return cur < prev - RESET_DROP or (cur == 0 and prev > 0)


# Instants at which the CAP changed while the meter's zero did not. A reset is a fall
# and _is_reset sees it; a cap change is the opposite shape -- the same spend reads as a
# HIGHER percentage once the cap shrinks -- so the reset guard is blind to it, and a pair
# or a regression period spanning one is differenced across two caps instead of two
# zeros. Same failure class, same treatment: split there, and drop what straddles it.
#
# Each entry is a WINDOW, not an instant, because the /usage banner says only "50%
# higher through September 13": the expiry is somewhere in that day, in a timezone it
# does not name. Anything inside the window is ambiguous and is discarded rather than
# assigned to a side. The boost's START is unknown and cannot be listed -- readings from
# before it are already on file under the same cap assumption; see meter-readings.md.
MULTIPLIER_WINDOWS = (
    (datetime(2026, 9, 13, 0, 0, tzinfo=PT).timestamp(),
     datetime(2026, 9, 14, 0, 0, tzinfo=PT).timestamp(),
     "the +50% boost expired (banner: \"through September 13\"; exact instant unknown, "
     "so the whole day is the window)"),
)


def multiplier_change_between(t0, t1, windows=MULTIPLIER_WINDOWS):
    """Did the cap change between two instants (epoch seconds)? Returns why, or None.

    A pair is disqualified when its interval OVERLAPS a window at all, which also
    catches a reading taken inside one: whether the change had already happened at
    that reading is unknowable, so the reading cannot be assigned to either cap.
    A pair entirely before or entirely after a window is untouched -- which is what
    makes the expiry measurable at all: one pair each side, compared.
    """
    lo, hi = (t0, t1) if t0 <= t1 else (t1, t0)
    for w0, w1, why in windows:
        # Half-open on the far side (a reading AT w1 is after the window) and closed
        # on the near side (a reading AT w0 is inside it): the conservative edge.
        if lo < w1 and hi >= w0:
            return why
    return None


def _segments(samples):
    """Split the series at every reset -- weekly boundary or out-of-band alike -- and at
    every cap change, discarding samples that fall inside a change window."""
    segs, cur, prev = [], [], None
    for t, pct in samples:
        t_s = t / 1000.0
        if multiplier_change_between(t_s, t_s):
            # Inside the window: which cap this sample was measured against is unknown.
            # It joins neither side, and it ends the side before it.
            if cur:
                segs.append(cur)
            cur, prev = [], None
            continue
        # Splicing two different zero points into one regression is the failure here;
        # two different CAPS is the same failure with the opposite sign. The second
        # clause is for a window that no sample landed in -- a sampling gap -- which
        # the first branch cannot see.
        if prev is not None and (_is_reset(prev[1], pct)
                                 or multiplier_change_between(prev[0], t_s)):
            segs.append(cur)
            cur = []
        cur.append((t, pct))
        prev = (t_s, pct)
    if cur or not segs:          # callers index [-1]; never hand back nothing
        segs.append(cur)
    return segs


def _fit(xs, ys):
    n = len(xs)
    if n == 0:                  # the only caller guards this, but the helper must not
        return None, None       # depend on that -- a future caller would divide by zero
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None, None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    b = sxy / sxx
    a = my - b * mx
    ssr = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    sst = sum((y - my) ** 2 for y in ys)
    return b, (1 - ssr / sst if sst else None)


def _cum_events(unit="$"):
    """Cumulative spend over every transcript: (times_ms, cum, cum_fable).

    `cum[k]` is the total after the first k events, so `cum[bisect_right(times, t)]` is
    the total as of instant `t` -- and `cum[0] == 0` covers "before anything happened".

    One full walk, shared. The cap regression and the meter anchor need the same series
    and this walk is the expensive thing in this file; building it twice per invocation
    is what the anchor cache exists to avoid. The Fable column rides along because the
    desktop app's samples carry NO Fable meter, so the Fable side of an out-of-band
    reset can only be recovered by summing Fable spend up to the zero instant.
    """
    idx = {"$": 0, "raw": 1, "ieq": 2}[unit]
    ev, seen = [], set()
    for path in ROOT.rglob("*.jsonl"):
        if "memory" in path.parts or "tool-results" in path.parts:
            continue
        try:
            fh = open(path, "rb")
        except OSError:
            continue
        with fh:
            for raw_line in fh:
                if b'"type":"assistant"' not in raw_line:
                    continue
                try:
                    e = json.loads(raw_line.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if e.get("type") != "assistant":
                    continue
                m = e.get("message") or {}
                u, model = m.get("usage"), m.get("model") or ""
                if not u or not model or model == "<synthetic>":
                    continue
                k = (m.get("id"), e.get("requestId"))
                if k in seen:
                    continue
                seen.add(k)
                ts = e.get("timestamp")
                if not ts:
                    continue
                try:
                    d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except ValueError:
                    continue
                rawt, ieq = token_measures(u)
                v = (cost_usd(u, model), rawt, ieq)[idx]
                ev.append((d.timestamp() * 1000, v, v if tier(model) == "fable" else 0.0))
    if not ev:
        return [], [0.0], [0.0]
    ev.sort()
    times = [e[0] for e in ev]
    cum, cumf = [0.0], [0.0]
    for _, v, vf in ev:
        cum.append(cum[-1] + v)
        cumf.append(cumf[-1] + vf)
    return times, cum, cumf


def sampled_caps(unit="$"):
    """Implied all-models cap per meter period, by regressing spend on the meter %.

    The slope is dollars per percentage point, so slope x 100 is the cap. Fitting a LINE
    rather than dividing means the intercept absorbs the zero point -- which is the same
    property that makes a two-reading difference immune to a reset, generalised over
    every sample in the period. Returns [(label, cap, r2, n), ...], newest last.
    """
    samples = plan_samples()
    if not samples:
        return []
    times, cum, _ = _cum_events(unit)
    if not times:
        return []
    out = []
    for seg in _segments(samples):
        if len(seg) < 8:
            continue
        xs = [p for _, p in seg]
        if max(xs) - min(xs) < MIN_SEG_SPAN:
            continue
        ys = [cum[bisect.bisect_right(times, t)] for t, _ in seg]
        b, r2 = _fit(xs, ys)
        if b is None or not math.isfinite(b) or b <= 0:
            continue
        lo = datetime.fromtimestamp(seg[0][0] / 1000, PT)
        hi = datetime.fromtimestamp(seg[-1][0] / 1000, PT)
        out.append((f"{lo:%m-%d %H:%M}->{hi:%m-%d %H:%M}", b * 100, r2, len(seg)))
    return out


ANCHOR_MIN_SAMPLES = 6   # below this the intercept is noise, not a measurement
ANCHOR_MIN_SPAN = 10     # percentage points the period must cover, as for MIN_DELTA_PCT


def meter_offset(week, force=False):
    """Week-anchored spend the meter has ALREADY forgotten, in dollars.

    The pace numerator was week-anchored and the cap describes a METER PERIOD. Those are
    the same window only while the meter zeroed at the week open. Anthropic reset the
    quota out of band on 2026-09-04, and from that instant every week-anchored total
    overstated what the meter counts by exactly the spend preceding the new zero -- so
    the live check read 90% of the all-models cap against a meter showing 57%, and 29%
    of the Fable cap against a meter showing 21%.

    That defect is the one `resolve_cap` already routes around: it prefers the
    differential precisely BECAUSE the absolute method assumes zero == week open. The
    fix went into the cap and not into the numerator that is divided by it.

    The offset is the INTERCEPT of week-anchored spend regressed on the meter
    percentage over the current period -- spend at 0% -- which is the same fit
    `sampled_caps` takes the slope from, and zero-point independent for the same
    reason. Fitting all of the period's samples beats anchoring to the reset boundary:
    the samples only bracket it (2026-09-04 has a two-hour gap, 34% -> 2%), so a
    boundary anchor would have to guess where in that gap the spend fell.

    The desktop samples carry no Fable meter, so the Fable offset cannot be regressed.
    It is recovered instead by inverting the all-models fit -- find the instant
    week-anchored spend crossed the offset, that is the zero -- and summing Fable spend
    up to it.

    An out-of-band reset moves the ZERO, not the week close: the top-up of 2026-09-01
    was followed by the regular Wednesday reset of 2026-09-02 anyway. So the period the
    meter is pacing over is [zero, week close], which is SHORTER than the week -- and
    `zero_ms` is returned so the elapsed fraction is measured over that same window
    rather than against a 7-day denominator the meter is no longer using.

    Returns (offset_all, offset_fable, zero_ms, note, exact).
    """
    open_ms = week_bounds(week)[0].timestamp() * 1000
    samples = [x for x in plan_samples() if x[0] >= open_ms]
    if not samples:
        return 0.0, 0.0, None, "", True
    segs = _segments(samples)
    seg = segs[-1]
    # _segments hands back [[]] when every sample fell inside a cap-change window. The
    # old fast-path test indexed seg[0] before anything else and crashed the hook on it
    # (#250); the test below reads len(segs) first, and a lone segment -- empty or not --
    # is the quiet case, so nothing here touches seg[0] until it is known to exist.
    # The zero moved only if this segment begins at a RESET. A segment can also begin at
    # a cap-change window (#249), across which the meter is continuous: the same test
    # _segments used to split there says whether the boundary was a fall. Reading every
    # non-first segment as a reset printed "meter reset out of band 09-14 00:00 PT" on
    # every prompt for the rest of the boost-expiry week (#250).
    if len(segs) == 1 or not _is_reset(segs[-2][-1][1], seg[0][1]):
        return 0.0, 0.0, None, "", True

    cached = _cached_anchor(week, seg[0][0]) if not force else None
    if cached:
        return (cached["all"], cached["fable"], cached["zero"],
                cached["note"], cached["exact"])

    when = datetime.fromtimestamp(seg[0][0] / 1000, PT).strftime("%m-%d %H:%M")
    xs = [pct for _, pct in seg]
    if len(seg) < ANCHOR_MIN_SAMPLES or max(xs) - min(xs) < ANCHOR_MIN_SPAN:
        # Known reset, un-fittable period. Saying so beats both alternatives: a silent 0
        # reports a number known to be too high, and a guess dressed as a measurement is
        # what this file keeps having to retract.
        return 0.0, 0.0, None, f"meter reset out of band {when} PT; too few samples " \
                               f"to anchor, so this is the WEEK total and reads high", False

    times, cum, cumf = _cum_events("$")
    if not times:
        return 0.0, 0.0, None, "", True
    base = cum[bisect.bisect_right(times, open_ms)]
    basef = cumf[bisect.bisect_right(times, open_ms)]
    ys = [cum[bisect.bisect_right(times, t)] - base for t, _ in seg]
    b, r2 = _fit(xs, ys)
    if b is None or not math.isfinite(b) or b <= 0:
        return 0.0, 0.0, None, f"meter reset out of band {when} PT; period does not " \
                               f"fit, so this is the WEEK total and reads high", False
    off = sum(ys) / len(ys) - b * (sum(xs) / len(xs))
    # This period STARTS at a reset, so whatever the meter forgot is spend that
    # happened earlier THIS week: the intercept cannot be meaningfully negative. When
    # it is, the fit has failed, and clamping it to zero would apply no correction at
    # all while reporting `exact` -- silently reproducing the very defect this
    # function exists to fix, with a plausible R2 next to it and no warning. Disclose
    # instead, exactly as the `b <= 0` and too-few-samples paths do. A NEAR-zero
    # intercept is a different thing (a reset with little before it) and is kept.
    if off < -max(1.0, 0.01 * ys[-1]):
        return 0.0, 0.0, None, f"meter reset out of band {when} PT; the fit puts " \
                               f"${-off:,.0f} of spend BEFORE the week began, so it " \
                               f"has failed -- this is the WEEK total and reads high", False
    off = min(max(off, 0.0), ys[-1])
    # The instant week-anchored spend crossed the offset IS the meter's zero -- a
    # far tighter localisation than the samples give (they only bracket the reset,
    # two hours wide on 2026-09-04).
    j = bisect.bisect_left(cum, base + off)
    offf = min(max(cumf[min(j, len(cumf) - 1)] - basef, 0.0), cumf[-1] - basef)
    zero_ms = times[min(max(j - 1, 0), len(times) - 1)] if times else None
    # With a zero offset the crossing lands on the week-open index itself, so `j - 1`
    # is the last event of the PREVIOUS week. A zero instant outside this week is not
    # a zero instant; pace() would reject it anyway, but it must not be returned.
    if zero_ms is not None and zero_ms < open_ms:
        zero_ms = None
    note = f"anchored to the out-of-band reset of {when} PT (${off:,.0f} all / " \
           f"${offf:,.0f} fable before the meter's zero, R2 {r2:.3f})" if r2 is not None \
           else f"anchored to the out-of-band reset of {when} PT"
    _save_anchor(week, seg[0][0], off, offf, zero_ms, note)
    return off, offf, zero_ms, note, True


def _cached_anchor(week, seg_start):
    """The offset is a CONSTANT once the reset is past -- it does not drift as spend
    accrues -- so it is computed once per period, not once per invocation. Only a new
    reset or a new week invalidates it, which is what the key checks."""
    try:
        d = json.loads(CALIB.read_text())
        a = d.get("anchor") if isinstance(d, dict) else None
        if (isinstance(a, dict) and a.get("week") == week and a.get("seg") == seg_start
                and all(isinstance(a.get(k), (int, float)) and not isinstance(a.get(k), bool)
                        and math.isfinite(a[k]) for k in ("all", "fable"))):
            z = a.get("zero")
            return {"all": a["all"], "fable": a["fable"],
                    "zero": z if isinstance(z, (int, float)) and not isinstance(z, bool)
                            and math.isfinite(z) else None,
                    "note": a.get("note") or "", "exact": True}
    except (OSError, ValueError):
        pass
    return None


def _merge_calib(update):
    """Read-modify-write the shared calibration file.

    The cap calibration and the meter anchor live in the same JSON. A bare
    `write_text` from either one drops the other -- `--calibrate` used to, which cost
    a full rescan on the next pace check for no reason at all.
    """
    try:
        d = json.loads(CALIB.read_text()) if CALIB.exists() else {}
    except (OSError, ValueError):
        d = {}
    if not isinstance(d, dict):
        d = {}
    d.update(update)
    try:
        CALIB.parent.mkdir(parents=True, exist_ok=True)
        CALIB.write_text(json.dumps(d))
    except OSError:
        pass


def _save_anchor(week, seg_start, off, offf, zero_ms, note):
    _merge_calib({"anchor": {"week": week, "seg": seg_start, "all": off, "fable": offf,
                             "zero": zero_ms, "note": note,
                             "at": datetime.now(PT).isoformat(timespec="minutes")}})


def _median(v):
    v = sorted(v)
    return v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2


def cached_calibration():
    """The last computed sampled cap, or None. Keeps the hook off a full rescan."""
    try:
        d = json.loads(CALIB.read_text())
        v = d.get("all") if isinstance(d, dict) else None
        # json.loads accepts the non-standard literals Infinity/-Infinity/NaN, and bool
        # is an int subclass -- so `isinstance(v, (int, float)) and v > 0` alone admits
        # `Infinity` and `true` as caps. This value is divided by.
        if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v > 0:
            return d
    except (OSError, ValueError):
        pass
    return None


MIN_DELTA_PCT = 10.0     # below this, integer rounding on both readings dominates


def _reading_instant(r):
    """Sort key for a reading: an absolute instant, never the raw ISO string.

    A recorded `at` carries a UTC OFFSET (`...T01:30-08:00`), and offsets change at a
    DST transition, so lexicographic order is not chronological order. Either side of
    the 2026-11-01 PT fall-back, `01:30-08:00` (09:30 UTC) sorts BEFORE `01:45-07:00`
    (08:45 UTC) as text while being 45 minutes LATER in fact. Differencing
    that pair reads the meter as having gone down and reports a reset that never
    happened. Unparseable timestamps sort last rather than throwing.
    """
    at = r.get("at") or ""
    try:
        return (0, datetime.fromisoformat(at).timestamp())
    except (TypeError, ValueError):
        return (1, 0.0)


def reset_between(t0, t1, samples=None):
    """Did the weekly meter reset between two instants (epoch seconds)?

    The `dp < 0` guard in differential_caps only catches a reset when the LATER reading
    reads lower. It cannot see one the meter has already climbed back past -- and that
    is not hypothetical. The two real readings on file, 2026-09-02 21:52 (8%) and
    2026-09-04 23:44 (13%), straddle the out-of-band reset of 2026-09-04 12:51-14:51
    (34% -> 2%), and their delta is POSITIVE (+5). Differencing them yields $20,598
    against a measured $2,363 -- out by 8.7x. Only the 10-point floor dropped that pair,
    which is luck, not a guard.

    The app's own 15-minute samples settle it directly. Where they are unavailable
    (non-macOS, no desktop app) this returns False and the pair is judged by the weaker
    guards alone -- the caller says so rather than implying a check that did not happen.
    """
    s = plan_samples() if samples is None else samples
    lo, hi = (t0, t1) if t0 <= t1 else (t1, t0)
    prev = None
    for t, pct in s:
        t_s = t / 1000.0
        if prev is not None and _is_reset(prev[1], pct):
            # The drop happened somewhere in the OPEN interval (prev_t, t) -- at
            # 15-minute resolution its exact instant is unknown. It disqualifies the
            # pair whenever that interval overlaps the reading window at all. Testing
            # only whether the post-drop SAMPLE lands inside [lo, hi] misses a reset
            # that occurred inside the window but whose first post-reset sample
            # arrived after it, which at a 15-minute cadence is an ordinary case.
            if prev[0] <= hi and t_s >= lo:
                return True
        prev = (t_s, pct)
    return False


def differential_caps(rows, unit="$"):
    """cap = delta-measure / (delta-pct/100), between two readings in one meter week.

    THIS IS THE ONLY METHOD THAT SURVIVES AN OUT-OF-BAND QUOTA RESET, and it is the
    reason readings are worth taking in pairs rather than singly.

    The absolute method (`implied_caps`) divides week-to-date spend by the meter
    percentage, which silently assumes the meter's zero sits exactly at the week open.
    Anthropic reset the quota mid-week on 2026-09-04, moving the zero to an unknown
    instant; every absolute cap computed after that counts pre-reset spend the meter
    itself no longer counts, and so runs high by whatever accumulated before it.

    A difference does not care. Both measures are taken from the same origin, so the
    origin cancels: `spend_B - spend_A` is the spend between the two readings whatever
    the meter's zero was, and `pct_B - pct_A` is the share of cap that bought it. The
    method is likewise blind to a mid-week boost multiplier, as long as it did not
    change between the two readings.

    Two guards. A percentage that went DOWN means the meter reset between the readings
    (or the week rolled), so the pair spans two different zeros and is dropped rather
    than differenced into a negative cap. A delta below MIN_DELTA_PCT is dropped
    because both percentages are read by eye as integers: at a 5-point delta a +/-1
    point rounding is a 20% error in the cap, while at 40 points it is 2.5%.
    """
    ak, fk = next((a, f) for u, a, f, _ in UNITS if u == unit)
    out, notes = {"all": [], "fable": []}, []
    samples = plan_samples()          # loaded once; [] when the app's history is absent
    if not samples and len(rows) > 1:
        notes.append("no meter samples on this machine, so a pair that STRADDLES a reset "
                     "cannot be detected -- only a pair whose percentage went down. Treat "
                     "any cap below with that caveat.")
    weeks = {}
    for r in rows:
        weeks.setdefault(r["week"], []).append(r)
    for wk in sorted(weeks):
        rs = sorted(weeks[wk], key=_reading_instant)
        for a, b in zip(rs, rs[1:]):
            for meter, pk, mk in (("all", "all_pct", ak), ("fable", "fable_pct", fk)):
                pa, pb, ma, mb = a.get(pk), b.get(pk), a.get(mk), b.get(mk)
                if None in (pa, pb, ma, mb):
                    continue
                dp, dm = pb - pa, mb - ma
                ta, tb = _reading_instant(a)[1], _reading_instant(b)[1]
                if ta and tb and reset_between(ta, tb, samples):
                    notes.append(f"{wk} {meter}: {a['at']} -> {b['at']} STRADDLES a meter "
                                 f"reset (seen in the app's own samples). The delta is "
                                 f"positive, so the percentage guard cannot catch this; "
                                 f"differencing across two zero points is what produced "
                                 f"$20,598 against a measured $2,363. Dropped")
                    continue
                why = ta and tb and multiplier_change_between(ta, tb)
                if why:
                    notes.append(f"{wk} {meter}: {a['at']} -> {b['at']} SPANS a cap change "
                                 f"-- {why}. The percentage guard cannot see this either: "
                                 f"a smaller cap makes the same spend read HIGHER, so the "
                                 f"delta is positive and the pair looks healthy. It is a "
                                 f"difference across two caps, not one. Dropped")
                    continue
                if dp < 0 or dm < 0:
                    notes.append(f"{wk} {meter}: {a['at']} -> {b['at']} went DOWN "
                                 f"({pa:g}% -> {pb:g}%) -- the meter reset between these "
                                 f"readings; the pair spans two zeros and is dropped")
                    continue
                if dp < MIN_DELTA_PCT:
                    notes.append(f"{wk} {meter}: {a['at']} -> {b['at']} moved only "
                                 f"{dp:g} points -- below the {MIN_DELTA_PCT:g}-point floor "
                                 f"where integer rounding dominates; dropped")
                    continue
                out[meter].append(100.0 * dm / dp)
    return out, notes


def spread(vals):
    """max/min. The unit the meter actually counts is the one whose implied cap is
    STABLE across readings with different model mixes; the others swing."""
    vals = [v for v in vals if v > 0]
    if len(vals) < 2:
        return None
    return max(vals) / min(vals)


def resolve_cap(kind, rows, use_cached=True):
    """Best available cap, and how much to trust it. For --caps and the derived path only.

    Differential first: it is immune to where the meter's zero sits, and after the
    2026-09-04 quota reset the absolute method's assumption (zero == week open) is
    known to be wrong. Absolute is the fallback, and says so.

    `use_cached=False` skips the cached --calibrate median, and the pacing path passes it.
    That median is a median ACROSS weeks with no staleness check, and it short-circuits
    before both zero-point-independent methods; divided into this week's spend it printed
    "96% of cap | NEAR CAP" while the live meter read 79. It is still the right answer for
    the question --caps asks (what has the cap been?) and the wrong one for the question
    pacing asks (what is it THIS week?), which the live rate answers directly.
    """
    if kind == "all" and use_cached:
        c = cached_calibration()
        if c:
            lo, hi = c.get("lo"), c.get("hi")
            # The spread is part of the answer, not a footnote. Six periods of real data
            # imply caps from $1,979 to $2,870 -- a 1.45x span that the boost, the model
            # mix and the fit quality all fail to explain. Reporting only the median
            # presents +/-20% uncertainty as a precise number.
            rng = (f", range ${lo:,.0f}-${hi:,.0f}"
                   if isinstance(lo, (int, float)) and isinstance(hi, (int, float)) else "")
            age = f", measured {c['at'][:16]}" if isinstance(c.get("at"), str) else ""
            return (c["all"], f"regression over {c.get('periods', '?')} meter period(s) "
                              f"from the app's own 15-minute samples (R2 {c.get('r2', 0):.3f}"
                              f"{rng}{age}) -- zero-point independent", True)
    dcaps, _ = differential_caps(rows)
    if dcaps[kind]:
        v = sorted(dcaps[kind])
        med = v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2
        return med, f"differential of {len(v)} reading pair(s) -- zero-point independent", True
    caps = implied_caps(rows)[kind]
    if caps:
        caps = sorted(caps)
        med = caps[len(caps) // 2] if len(caps) % 2 else (caps[len(caps) // 2 - 1] + caps[len(caps) // 2]) / 2
        return med, (f"median of {len(caps)} single reading(s) -- ABSOLUTE, assumes the "
                     f"meter zeroed at the week open; wrong after an out-of-band reset"), True
    return (FALLBACK[kind], "derived elsewhere from other weeks' statistics, not measured "
            "on this machine and not this week's rate (record a reading pair to replace "
            "it, or read the live meter)", False)


# ---------------------------------------------------------------- pace

def derive(pct, anchor_sd, spend_at_pct, spend_since, burn_1h, burn_3h,
           hours_to_reset, min_moved=MIN_MOVED, has_meter=True):
    """Everything downstream of one percentage and the spend measured against it.

    `rate` is the self-calibrating cap: this week's own dollars per meter point. It is
    right by construction whatever the cap happens to be this week, which is the property
    no cached number has -- clean weekly endpoint caps measured $2,505 / $2,374 / $2,417 /
    $2,536, and this week reads ~$3,160 at its endpoint because of an anomaly in its first
    twenty points, while its marginal rate from 20 to 75 points sits inside the prior
    weeks' range.

    TWO instants, kept apart, because conflating them is what made the rate drift with the
    sample's age. `spend_at_pct` is the spend as of the moment the METER was read -- the
    only numerator that belongs over `pct` -- and `spend_since` is what has been burned in
    the sampling gap since. Dividing spend-to-now by a forty-minute-old percentage credited
    the gap's spend as headroom: measured on this machine at a 95-minute sample age, $2,334
    at sample time gave $28.46/pt and $512 left, while spend-to-now gave $29.76/pt and $536
    left -- $106 of consumption reported as room, in the direction that silences the
    lockout warning.

    `anchor_sd` is the meter's reading at the anchor, and the denominator is the points it
    has MOVED since. A fall of LIVE_DROP identifies the reset; it does not prove the meter
    landed on zero, and a 100 -> 40 anchor read against a current 82 prices 42 points of
    movement as 82.

    `pct_now` is `pct` carried forward over the gap at that rate. It is the meter
    EXTRAPOLATED, never the meter read, and the readout labels it as such -- everything
    that has to answer "where are we now" (the headroom, the wall, the landing) uses it,
    because the alternative is to answer with a number that was true forty minutes ago.

    ...but only once the meter has MOVED enough to have a rate worth extrapolating with.
    `pct` is an integer percentage eyeballed off a UI, so at `moved == 1` the rate is one
    rounded point: the true movement is anywhere in [0.5, 1.5) and the rate is therefore
    uncertain by a factor of three, before any question of whether the first points of a
    period cost what the rest do. Everything downstream inherits that -- pts_left,
    usd_left, hours_to_wall, landing -- and hours_to_wall is the sole input to the lockout
    warning, which says the rest of the week is lost. That sentence must never be produced
    by a one-point rate, and in the first hour after every reset a one-point rate is
    exactly what is on offer.

    So below MIN_MOVED the rate is marked `provisional`: `pct_now` stays at the meter's own
    reading rather than being extrapolated, the readout says the rate is provisional and
    how far the meter has moved, and `warnings_for` withholds the lockout line. The rate is
    still reported -- it is the best estimate available and the only one there is -- and the
    dollar figures built from it are still shown, because the alternative is a blank readout
    for the first hour of every week. What is withheld is the two things that require the
    rate to be TRUSTED: the extrapolation, and the warning.

    `landing` is where the meter ends up at the reset if the last three hours continue:
    the three-hour average is used rather than the one-hour one because a single hour of a
    long session is noisy. `hours_to_wall` uses the one-hour rate instead, because the
    question it answers is about right now.
    """
    moved = (pct or 0.0) - (anchor_sd or 0.0)
    rate = spend_at_pct / moved if moved > 0 and spend_at_pct > 0 else None
    # WHY there is no rate, because every figure built on it degrades to "?" and a readout
    # of bare question marks tells the reader nothing about whether to wait, to open /usage,
    # or to distrust the tool. Both causes are ordinary rather than exceptional: the meter
    # sits on one integer for the first stretch of a period, and a session can open with no
    # spend behind it at all.
    #
    # SPEND is tested first because the two conditions are not exclusive: a session opening
    # with nothing behind it has no spend AND no movement, and testing movement first made
    # "no spend recorded" unreachable in exactly that world -- the commonest one there is.
    # Of the two, the missing numerator is the one that names what the reader can do about
    # it (spend something, or wait), where "the meter has not moved" invites opening /usage
    # to refresh a reading that is already correct.
    #
    # And `has_meter` is what keeps the sentence honest: the DERIVED path has no meter at
    # all -- its percentage is `100 * spend / cap`, an arithmetic result -- so "the meter
    # has not moved (still 0%)" there is a claim about a reading the script never took.
    rate_reason = None if rate is not None else (
        "no spend recorded since the reset" if spend_at_pct <= 0
        else "the meter has not moved since the reset (still %.0f%%)" % (pct or 0.0)
        if has_meter
        else "the derived percentage is still %.0f%%, so there is nothing to divide by"
             % (pct or 0.0))
    provisional = rate is not None and moved < min_moved
    pct_now = (pct or 0.0) + (spend_since / rate
                              if rate and not provisional and spend_since > 0 else 0.0)
    pts_left = max(0.0, 100.0 - pct_now)
    usd_left = pts_left * rate if rate else None
    wall = (usd_left / burn_1h if usd_left is not None and burn_1h > 0
            else math.inf if usd_left is not None else None)
    return {
        "rate": rate, "pct_now": pct_now, "pts_left": pts_left, "usd_left": usd_left,
        "moved": moved, "provisional": provisional, "rate_reason": rate_reason,
        "hours_to_wall": wall,
        "landing": (pct_now + burn_3h * hours_to_reset / rate) if rate else None,
        "need_per_hour": (usd_left / hours_to_reset
                          if usd_left is not None and hours_to_reset > 0 else None),
    }


def fable_reading(rows, now):
    """The Fable meter as last read by hand: (pct, age, $/pt), or None.

    The app's sample file carries `sd` and `fh` and NO Fable field, so this ledger is the
    only source for the Fable percentage and it is exactly as fresh as the last --record.
    The rate comes from the newest usable PAIR, for the same reason differential_caps
    prefers pairs: a difference cancels the meter's zero.
    """
    rs = sorted([r for r in rows if r.get("fable_pct") is not None], key=_reading_instant)
    if not rs:
        return None
    last = rs[-1]
    kind, inst = _reading_instant(last)
    rate = None
    if len(rs) >= 2:
        a, b = rs[-2], rs[-1]
        dp = b["fable_pct"] - a["fable_pct"]
        dm = (b.get("fable_at") or 0.0) - (a.get("fable_at") or 0.0)
        if dp > 0 and dm > 0:
            rate = dm / dp
    return {"pct": last["fable_pct"], "rate": rate, "at": last.get("at"),
            "age_h": ((now.timestamp() - inst) / 3600.0) if kind == 0 else None}


def pace(now=None, force=False, prefer="live"):
    """The week as the METER sees it. Two modes, and the first is the point of this file.

    LIVE -- the desktop app has persisted a real meter percentage, so it is reported
    verbatim with its age, and this week's own $/pt turns the remaining points into
    dollars, hours and a landing percentage. No cap, cached or regressed, and no intercept
    enters this path.

    DERIVED -- there is no sample file at all (no desktop app on this machine). Only then
    does the old arithmetic run: week spend re-anchored by `meter_offset`, divided by
    `resolve_cap`. Everything built from it is labelled derived, every time, because a
    computed percentage presented as the percentage is the defect this rewrite removes.
    """
    now = now or datetime.now().astimezone()
    wk = week_close(now)
    open_, close = week_bounds(wk)
    # Convert to UTC before subtracting. `open_` and `close` share one tzinfo object,
    # and arithmetic on two aware datetimes with the SAME tzinfo diffs their naive
    # fields -- so the week containing a DST transition measures 604800s instead of
    # its true 608400s, skewing every elapsed fraction in it.
    _u = lambda d: d.astimezone(timezone.utc)
    now_ms = _u(now).timestamp() * 1000
    open_ms = _u(open_).timestamp() * 1000
    span = (_u(close) - _u(open_)).total_seconds()
    hours_to_reset = max(0.0, (_u(close) - _u(now)).total_seconds() / 3600.0)
    tot, bk = scan_detail(wk, force=force)
    rows = [r for r in read_readings() if r["week"] == wk]
    burn_1h = window_spend(bk, now_ms - 3600_000, now_ms)[0]
    burn_3h = window_spend(bk, now_ms - 3 * 3600_000, now_ms)[0] / 3.0
    p = {
        "week": wk, "now": now.astimezone(PT).isoformat(timespec="minutes"),
        "hours_to_reset": hours_to_reset,
        "week_all": tot.get("all", 0.0), "week_fable": tot.get("fable", 0.0),
        "main": tot.get("main", 0.0), "sub": tot.get("sub", 0.0),
        "sub_fable": tot.get("sub_fable", 0.0),
        "burn_1h": burn_1h, "burn_3h": burn_3h,
        "fable_reading": fable_reading(rows, now),
    }
    # ONE read of the sample file, shared by both readers of it. The sample and the anchor
    # are two facts about the same snapshot, and the whole live path turns on comparing
    # them: `samp["t"] < anchor_ms` refuses the sample as belonging to an older meter
    # period. Read twice, the app can write between the reads -- it writes at every /usage
    # poll, not on a clock -- and the comparison is then between two different files. The
    # damaging direction is the one that lands: the older read supplies the sample and the
    # newer read supplies an anchor from a reset it did not contain, so a perfectly good
    # live sample is refused as pre-period and the readout silently drops to `derived`.
    raw = _plan_raw()
    samp = live_sample(now_ms, samples=raw) if prefer == "live" else None
    anchor_ms, prev_ms, anchor_sd, label = observed_anchor(open_ms, samples=raw)
    # A sample taken BEFORE the anchor is not a reading of this meter period, and age alone
    # never disqualified it -- `stale` was a display flag and nothing else. The shape is
    # deterministic, not an edge case: after every Wednesday 15:59 PT reset the newest
    # persisted sample is still the prior week's, so the readout paired the OLD week's ~95%
    # with the NEW week's near-zero spend. Rate collapsed, headroom collapsed, hours_to_wall
    # went to minutes, and --hook injected "the rest of the week is lost" into the session
    # unattended. Reproduced with a sample two hours before the week open and $800 of
    # in-week spend: it printed sd 95%, $42 left, and warned -- against a true ~33%. The
    # window is every gap until the app's next /usage poll, and the record has a 29.7h one.
    rejected = None
    if samp and samp["t"] < anchor_ms:
        rejected = (f"newest sample predates this meter week "
                    f"(sd {samp['sd']:.0f}%, {samp['age_min']:,.0f}m old)")
        samp = None
    if samp:
        spend, fable = window_spend(bk, anchor_ms, now_ms)
        # Split at the sample, not at now: the rate belongs over the meter as it was READ.
        at_s, _ = window_spend(bk, anchor_ms, samp["t"])
        since, _ = window_spend(bk, samp["t"], now_ms)
        gap, gap_f = (window_spend(bk, prev_ms, anchor_ms) if prev_ms is not None
                      else (0.0, 0.0))
        lo = derive(samp["sd"], anchor_sd, at_s, since, burn_1h, burn_3h, hours_to_reset)
        hi = derive(samp["sd"], anchor_sd, at_s + gap, since,
                    burn_1h, burn_3h, hours_to_reset)
        p.update({
            "source": "live",
            "sd": samp["sd"], "fh": samp["fh"],
            "sample_at": samp["at"], "sample_age_min": samp["age_min"],
            "stale": samp["age_min"] > STALE_MIN,
            "pct": samp["sd"], "anchor_sd": anchor_sd,
            "spend_at_sample": at_s, "spend_since_sample": since,
            "anchor": datetime.fromtimestamp(anchor_ms / 1000, timezone.utc)
                      .isoformat(timespec="seconds"),
            "anchor_label": label,
            "spend": spend, "spend_hi": spend + gap,
            "fable": fable, "fable_hi": fable + gap_f,
            "gap_spend": gap,
            "elapsed": max(0.0, min(1.0, (now_ms - anchor_ms) / 1000.0
                                    / max(1.0, (_u(close).timestamp() - anchor_ms / 1000)))),
        })
        # Every derived figure carries both ends of the range the gap implies. When the
        # gap is empty -- the normal case, and the actual case for this meter week -- the
        # two ends are identical and the formatter collapses them to one number.
        for k, v in lo.items():
            p[k] = v
            p[k + "_hi"] = hi[k]
    else:
        off_all, off_fbl, zero_ms, anchor, anchor_exact = meter_offset(wk, force=force)
        elapsed = max(0.0, min(1.0, (now_ms / 1000 - _u(open_).timestamp()) / span))
        if zero_ms:
            zero_dt = datetime.fromtimestamp(zero_ms / 1000, PT)
            if open_ < zero_dt < close:
                z = _u(zero_dt).timestamp()
                elapsed = max(0.0, min(1.0, (now_ms / 1000 - z)
                                       / max(1.0, _u(close).timestamp() - z)))
        all_ = max(0.0, tot.get("all", 0.0) - off_all)
        fable = max(0.0, tot.get("fable", 0.0) - off_fbl)
        cap, basis, calibrated = resolve_cap("all", rows, use_cached=False)
        fcap, fbasis, fcalibrated = resolve_cap("fable", rows, use_cached=False)
        pct = 100.0 * all_ / cap if cap else 0.0
        # No sample, so there is no sampling gap and no anchor reading: one instant, and
        # `pct_now` comes back equal to `pct`.
        #
        # `min_moved=0` because the provisional gate would be a false label here. `pct` is
        # `100 * all_ / cap`, so `all_ / pct` is `cap / 100` ALGEBRAICALLY -- the rate is the
        # cap, not a measurement over points the meter moved, and how few points it is
        # divided by says nothing about its precision. Its uncertainty is the cap's, which
        # `all_cap_basis` states in the line. Gating on `moved` here would instead have
        # silenced the lockout warning through the whole early-week stretch where a derived
        # percentage is small, which is the opposite of the intent.
        #
        # `has_meter=False` for the same reason: there is no meter on this path, so a
        # missing rate here must not be explained as a meter that has not moved.
        d = derive(pct, 0.0, all_, 0.0, burn_1h, burn_3h, hours_to_reset, min_moved=0.0,
                   has_meter=False)
        p.update({
            "source": "derived", "sd": None, "fh": None,
            "sample_at": None, "sample_age_min": None, "stale": False,
            "anchor_sd": 0.0, "spend_at_sample": all_, "spend_since_sample": 0.0,
            "pct": pct, "spend": all_, "spend_hi": all_,
            "fable": fable, "fable_hi": fable, "gap_spend": 0.0,
            "offset_all": off_all, "offset_fable": off_fbl,
            "anchor": anchor, "anchor_exact": anchor_exact, "anchor_label": anchor or "",
            "elapsed": elapsed,
            "cap": fcap, "cap_basis": fbasis, "calibrated": fcalibrated,
            "all_cap": cap, "all_cap_basis": basis, "all_calibrated": calibrated,
            "consumed": fable / fcap if fcap else 0.0,
        })
        for k, v in d.items():
            p[k] = v
            p[k + "_hi"] = v
    p["live_rejected"] = rejected
    w = p.get("hours_to_wall")
    p["wall_at"] = (f"{(now + timedelta(hours=w)).astimezone(PT):%a %H:%M} PT"
                    if w is not None and math.isfinite(w) else None)
    p["warnings"] = [m for _, m in warnings_for(p)]
    return p


def warnings_for(p):
    """The only two things worth interrupting a session for: [(key, message), ...].

    Both are about the SHAPE of the week, never its size. There is nothing here about
    being ahead of pace or near the cap -- a week that paces to 100% is the system working,
    and the retired NEAR CAP line was a derived percentage over a cached median cap that
    read 96% while the meter read 79. Being at 90% of a cap is not a problem. Being locked
    out on Monday is, and so is destroying quota at the reset.

    Neither warning says what happens AT the wall. Lockout at 100% has never actually been
    observed on this account -- the "29 hours with nothing served" in the record was a
    closed laptop, and requests near 100% were served -- so these name the arrival time
    and stop there.

    Neither is gated on the sample's age, and does not need to be: `pace` refuses a sample
    from before this meter period (which is what made these fire on a post-reset week with
    the prior week's ~95% still in the file), and `derive` accounts for the remaining gap
    rather than ignoring it. A gate here would have silenced the warnings in the ordinary
    case -- the newest sample on this machine is routinely 40 to 95 minutes old.

    Evaluated on the low end of the range, which is the anchor the readout reports. That
    end gives the earliest wall and the highest landing, so it warns early about lockout
    and late about waste -- the intended asymmetry, since one costs the rest of the week
    and the other costs nothing to learn an hour later.

    One thing DOES gate warning (a), and it is not the sample's age: a `provisional` rate,
    which is one calibrated on fewer than MIN_MOVED points of meter movement. hours_to_wall
    is that rate's only consumer here, and in the first hour after a reset the rate is a
    single rounded point -- uncertain by a factor of three before any question of whether
    the first points of a period cost what the rest do. "The rest of the week is lost" is
    not a sentence to derive from that. Warning (b) is not gated the same way: its landing
    figure is no better founded, but the worst it can do is suggest spending quota that
    would otherwise be destroyed -- which is the whole argument, and the only one. It is
    NOT that a provisional rate implies an early week: `provisional` is `moved < MIN_MOVED`,
    a statement about the meter and not the clock, and an out-of-band mid-week reset or an
    anchor the app saw late (a 100 -> 40 fall) both put `moved` under 5 with `h` well inside
    24. An earlier version of this paragraph claimed warning (b) "cannot fire in the first
    hour of a week anyway", which is a different proposition, true of neither gate, and
    would have made the absent gate look accidental rather than decided.
    """
    out = []
    h, w = p.get("hours_to_reset"), p.get("hours_to_wall")
    if (h and w is not None and math.isfinite(w) and w < 0.5 * h
            and not p.get("provisional")):
        when = p.get("wall_at") or f"in {w:.1f}h"
        out.append(("lockout", f"At this burn you reach the wall around {when}, "
                               f"{h - w:.0f}h before the reset -- the rest of the "
                               f"week is lost."))
    land, rate = p.get("landing"), p.get("rate")
    if land is not None and land < 90 and h is not None and h < 24:
        pts = 100.0 - land
        usd = f" = ${pts * rate:,.0f}" if rate else ""
        out.append(("waste", f"On the last three hours' burn the week lands at "
                             f"{land:.0f}%: {pts:.0f} points{usd} will expire unspent "
                             f"at the reset."))
    return out


def _rng(lo, hi, f="${:,.0f}"):
    """One number when both ends format the same, `low-high` when they do not.

    Comparing the FORMATTED strings, not the values: a range narrower than the precision
    being printed is noise, and "$2,572-$2,572" reads as an error in the tool.

    The ends are ORDERED here rather than trusted from the caller, because "lo" and "hi"
    name the two ends of the reset-gap range -- the anchor's low and high spend -- and not
    every figure is increasing in that. `landing` is monotonically DECREASING in it (more
    spend attributed to the anchor means a higher $/pt, which buys fewer points per hour),
    so it printed "lands 43-40%", a range spelled backwards. `usd_left` and
    `need_per_hour` are products of one increasing and one decreasing factor and can fall
    either way depending on the world. Ordering one call site would have left the other
    two to be discovered separately.

    Sorting is right HERE and would be wrong for the cap range, and the difference is
    whether the ends are ordered by construction. `lo`/`hi` here are two ends of a
    computation whose direction varies by figure, so their order carries no information and
    ordering them destroys nothing. `--calibrate`'s `lo`/`hi` are a measured minimum and
    maximum: an inversion there means the writer swapped them, so it must stay visible
    rather than be tidied away, and it renders verbatim -- pinned, in both directions, at
    "the cached basis carries the range low-to-high" and "an inverted lo/hi renders
    verbatim" in the suite. Whoever reaches for this helper from that basis string will
    have removed the only evidence of the bug it would be hiding.
    """
    if lo is None:
        return "?"
    if hi is None:
        hi = lo
    lo, hi = min(lo, hi), max(lo, hi)
    a, b = f.format(lo), f.format(hi)
    return a if a == b else f"{a}-{b}"


def fmt(p, margin=None):
    """The one-liner. `margin` is accepted and ignored -- see hook()."""
    if p["source"] == "live":
        # `pct_now` is sd carried over the sampling gap at this week's own rate. Shown
        # only when it rounds to something else, and always as "≈ N% now" beside the read
        # value -- the reading is what the app recorded, and the extrapolation is labelled
        # rather than substituted for it.
        fwd = (f" ≈ {p['pct_now']:.0f}% now" if p.get("pct_now") is not None
               and f"{p['pct_now']:.0f}" != f"{p['sd']:.0f}" else "")
        parts = [f"sd {p['sd']:.0f}% (sample {p['sample_at']}, "
                 f"{p['sample_age_min']:,.0f}m old){fwd}",
                 f"fh {p['fh']:.0f}%" if p["fh"] is not None else "fh n/a"]
    else:
        # Two reasons to be here, and they are not the same reason. No sample file at all
        # is a machine without the desktop app; a sample that predates this meter period
        # is the app having missed the reset, which is the more dangerous of the two
        # because the number it would have supplied looks perfectly current.
        parts = [f"derived — {p['live_rejected']}" if p.get("live_rejected")
                 else "derived — no live sample",
                 f"all-models ~{p['pct']:.0f}% of cap ${p['all_cap']:,.0f} "
                 f"({p['all_cap_basis']})"]
    parts += [
        f"spent {_rng(p['spend'], p['spend_hi'])} since {p['anchor_label']}"
        if p["source"] == "live" else f"spent ${p['spend']:,.0f}",
        f"{_rng(p['fable'], p['fable_hi'])} fable",
    ]
    # With no rate there is no $/pt, no headroom in dollars, no wall and no landing, and
    # printing four of them as "?" -- "?/pt · 100 pts ≈ ? left · → lands ?%" -- says
    # nothing about whether to wait, to open /usage, or to distrust the tool. Both causes
    # are ordinary (the meter sits on one integer early in a period; a session can open
    # with no spend behind it), so the line names the cause once and drops the fields that
    # would only repeat it.
    if p.get("rate") is None:
        parts += [f"no $/pt yet — {p.get('rate_reason') or 'the rate is not computable'}",
                  f"{p['pts_left']:.0f} pts left, dollars unknown until it is",
                  f"reset in {p['hours_to_reset']:.1f}h",
                  f"burn ${p['burn_1h']:,.0f}/h (3h ${p['burn_3h']:,.0f}/h)",
                  "→ no landing or wall without a $/pt"]
    else:
        parts += [
            # A rate calibrated on fewer than MIN_MOVED points says so, in the field
            # itself. It is still the best estimate there is, and it is still what every
            # dollar figure on the line is built from -- but `pct_now` is not extrapolated
            # with it and the lockout warning is withheld, so the line must not read as
            # though it were trusted.
            (f"{_rng(p['rate'], p['rate_hi'], '${:,.1f}')}/pt"
             + (f" PROVISIONAL (the meter has moved {p['moved']:.0f} pt since the reset)"
                if p.get("provisional") else "")),
            f"{p['pts_left']:.0f} pts ≈ {_rng(p['usd_left'], p['usd_left_hi'])} left",
            f"reset in {p['hours_to_reset']:.1f}h",
            f"burn ${p['burn_1h']:,.0f}/h (3h ${p['burn_3h']:,.0f}/h)",
            # A landing above 100 is not a percentage of anything -- it means the wall
            # arrives first, which warning (a) states in hours. Printing "lands 544%"
            # invites exactly the arithmetic-dressed-as-a-reading reading this file is
            # trying to stop.
            (f"→ lands >100% (the wall comes first)" if (p["landing"] or 0) > 100
             else f"→ lands {_rng(p['landing'], p['landing_hi'], '{:,.0f}')}%"),
            f"need {_rng(p['need_per_hour'], p['need_per_hour_hi'])}/h to reach the wall",
        ]
    fr = p.get("fable_reading")
    if fr:
        age = f", {fr['age_h']:.0f}h old" if fr.get("age_h") is not None else ""
        rate = f", {_rng(fr['rate'], fr['rate'], '${:,.1f}')}/pt" if fr.get("rate") else ""
        parts.append(f"fable {fr['pct']:.0f}%{age}{rate}")
    else:
        parts.append("fable % unknown (no reading this week)")
    line = " · ".join(parts)
    if p.get("stale"):
        line += (f"  [SAMPLE STALE {p['sample_age_min']:,.0f}m — open /usage to refresh]")
    if p.get("gap_spend"):
        line += (f"  [${p['gap_spend']:,.0f} of spend sits inside the reset gap, so every "
                 f"figure above is a range]")
    if p["source"] == "derived" and not p.get("anchor_exact", True):
        line += f" | WARNING: {p['anchor']}"
    return line


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
    except (OSError, ValueError):
        st = {}
    if not isinstance(st, dict):        # valid JSON, wrong shape -- see _load_cache.
        st = {}                         # This path runs BEFORE the --every gate, so
    s = st.get(sid)                     # the crash it replaces hit EVERY prompt.
    if not isinstance(s, dict):
        s = {"turns": 0, "last_fire_turn": 0}
    s["turns"] = s.get("turns", 0) + 1

    due = s["turns"] - s.get("last_fire_turn", 0) >= args.every
    if not due:
        st[sid] = s
        _write_state(st)
        return 0

    p = pace()
    warns = warnings_for(p)
    v = "+".join(k for k, _ in warns)
    if not v:
        # Clear the acknowledgment: without this, warned -> quiet -> warned stays silent,
        # because `acked` still holds the verdict from before the situation cleared and
        # the `acked == v` check below suppresses the new alert.
        s.pop("acked", None)
        s["last_fire_turn"] = s["turns"]
        st[sid] = s
        _write_state(st)
        return 0

    # Re-surfacing the same verdict every N turns after an acknowledgment is nagging,
    # not information. A NEW warning joining the set changes the key and speaks again.
    if s.get("acked") == v:
        s["last_fire_turn"] = s["turns"]
        st[sid] = s
        _write_state(st)
        return 0

    s["last_fire_turn"] = s["turns"]
    s["acked"] = v
    st[sid] = s
    _write_state(st)

    body = "\n".join(f"  - {m}" for _, m in warns)
    breach = ("\n  RULE BREACH: $%.2f of fable spend is in SUBAGENTS, which the scope "
              "forbids outright." % p["sub_fable"]) if p["sub_fable"] > 0 else ""
    print(f"""<usage-pace>
THE METER, and what this burn does to it. Information, not a limit — continuing is
always allowed, and a week that paces to 100% is the system working. What is NOT fine
is arriving at the wall days early, or handing back quota the reset destroys.

  {fmt(p)}
{body}{breach}
Tell the user where the week stands in one line and what you propose to do about it.
Then do what they say. Do not re-raise this unprompted.
</usage-pace>""")
    return 0


def _write_state(st):
    try:
        # Create the parent: it does not exist on a freshly bootstrapped machine, and
        # the except-OSError below swallowed the failure -- so the turn counter never
        # persisted, `--every` never came due, and the pace check was permanently
        # silent exactly where a new machine needed it most.
        HIST.mkdir(parents=True, exist_ok=True)
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
    g.add_argument("--calibrate", action="store_true",
                   help="derive the all-models cap from the desktop app's meter samples")
    g.add_argument("--units", action="store_true",
                   help="which unit does the meter count? (needs >=2 readings)")
    g.add_argument("--record", nargs="*", metavar="VAL",
                   help="record a meter reading: [all-pct] [fable-pct] [note]; "
                        "with no values, prompts for them")
    ap.add_argument("--every", type=int, default=40, help="hook: turns between checks (default 40)")
    # Kept, accepted and ignored. It tuned "how far ahead of elapsed time before
    # speaking", and speaking is no longer a function of elapsed time at all -- the hook
    # warns about the wall arriving early and about quota expiring, neither of which has a
    # margin to tune. Removing the flag would break every settings.json and shell alias
    # already passing it, for no gain.
    ap.add_argument("--margin", type=float, default=0.15,
                    help="accepted and ignored (see --help notes); kept for callers")
    ap.add_argument("--force", action="store_true", help="ignore the incremental cache")
    # NOT in the mutually exclusive group above: `--json --derived` is a reasonable thing
    # to ask for, and argparse would have refused it there.
    ap.add_argument("--derived", action="store_true",
                    help="ignore the live sample and show the derived arithmetic instead")
    a = ap.parse_args()

    if a.hook:
        return hook(a)

    if a.calibrate:
        rowsc = sampled_caps()
        if not rowsc:
            print("no plan-usage samples available "
                  f"({PLAN_SAMPLES}) — this is macOS desktop-app state; fall back to "
                  "hand-recorded readings (--record).")
            return 1
        print(f"{'meter period (PT)':32}{'n':>5}{'implied cap':>13}{'R2':>8}")
        for label, cap, r2, n in rowsc:
            print(f"{label:32}{n:5d}{cap:>13,.0f}{(r2 if r2 is not None else 0):>8.3f}")
        good = [(c, r) for _, c, r, _ in rowsc if r is not None and r >= 0.95]
        if good:
            v = sorted(c for c, _ in good)
            med = v[len(v)//2] if len(v) % 2 else (v[len(v)//2-1]+v[len(v)//2])/2
            r2m = sum(r for _, r in good)/len(good)
            CALIB.parent.mkdir(parents=True, exist_ok=True)
            lo, hi = min(v), max(v)
            _merge_calib({"all": med, "periods": len(good), "r2": r2m,
                          "lo": lo, "hi": hi,
                          "at": datetime.now().astimezone().isoformat(timespec="minutes")})
            print(f"\nall-models cap ${med:,.0f} (median of {len(good)} well-fit period(s), "
                  f"mean R2 {r2m:.3f})  — cached for the pace check")
            if lo and hi / lo > 1.15:
                print(f"  CAUTION: the six periods span ${lo:,.0f}-${hi:,.0f} ({hi/lo:.2f}x). That "
                      f"spread is NOT explained by the\n  +50% boost (the two post-2026-09-01 "
                      f"periods are at the LOW end, not 1.5x high), nor by fit\n  quality (R2 is "
                      f"0.98+ throughout), nor by model mix. Treat ${med:,.0f} as a central "
                      f"estimate\n  with roughly +/-20% around it, not a measured constant.")
            print("NOTE: these samples carry no Fable meter, so the Fable cap still needs "
                  "a hand-recorded reading.")
        return 0

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
            print("no meter readings recorded — every cap below is derived from other "
                  "weeks' statistics, not measured here:")
            for k, v in FALLBACK.items():
                print(f"  {k:6s} ${v:,.0f}")
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
        dcaps, dnotes = differential_caps(rows)
        print()
        print("DIFFERENTIAL — cancels the meter's zero point, so an out-of-band reset")
        print("BEFORE the pair does not affect it. Conditions, stated because the guards")
        print("below enforce them: a reset or a week roll BETWEEN the two readings is")
        print("detected and the pair DROPPED, not survived; and the result is only valid")
        print("if the cap multiplier (e.g. a temporary boost) held steady across them:")
        if any(dcaps.values()):
            for k in ("all", "fable"):
                if dcaps[k]:
                    print(f"  {k:6s} " + "  ".join(f"${v:,.0f}" for v in sorted(dcaps[k])))
                else:
                    print(f"  {k:6s} no usable pair")
        else:
            print("  none — this needs TWO readings in one meter week, at least "
                  f"{MIN_DELTA_PCT:g} percentage points apart.")
        for n in dnotes:
            print(f"  note: {n}")
        print()
        for k in ("all", "fable"):
            cap, basis, cal = resolve_cap(k, rows)
            print(f"  {k:6s} cap ${cap:,.0f}  ({basis})")
        return 0

    p = pace(force=a.force, prefer="derived" if a.derived else "live")
    if a.json:
        print(json.dumps(p, indent=2))
    else:
        print(fmt(p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
