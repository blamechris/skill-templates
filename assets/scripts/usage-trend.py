#!/usr/bin/env python3
"""usage-trend: track Claude Code token spend over time, across machines.

Each machine scans its own ~/.claude/projects/**/*.jsonl (deduped globally by
message id + request id) and merges the per-day aggregates into its own
versioned snapshot file, daily-v2-<machine>.json, inside this directory. Because every
machine writes only its own file, git sync never conflicts. The printed
trend merges all machines' files.

Usage:
  python3 ~/.claude/scripts/usage-trend.py            # scan, sync, print last 30 days
  python3 ~/.claude/scripts/usage-trend.py --all      # print full recorded history
  python3 ~/.claude/scripts/usage-trend.py --json     # dump merged history as JSON
  python3 ~/.claude/scripts/usage-trend.py --no-sync  # skip git pull/push

Meter-week mode (buckets by the Wed 15:59 PT weekly-reset boundary, splits
main-thread vs subagent spend; never git-syncs and never touches the daily files):
  python3 ~/.claude/scripts/usage-trend.py --week [--weeks N]   # print rollup (default 8)
  python3 ~/.claude/scripts/usage-trend.py --week --write       # also persist weekly-<machine>.json
                                                                # and regenerate the vault table
  python3 ~/.claude/scripts/usage-trend.py --week --oneline     # one line for the open week
  python3 ~/.claude/scripts/usage-trend.py --week --close-label # print the open week's close date

Machine identity: first run derives a name from `scutil --get ComputerName`
and stores it in ~/.claude/machine-name — edit that file to rename. Keep
names unique across machines.

Costs are dated API-list-rate equivalents (subscription users: a proxy figure,
not a bill). Cache reads use the exact model rate; unknown write duration is
reported as a lower/upper valuation, never silently called a 5m write.

Partial periods (skill-templates#392): transcripts are pruned, so after a rate-card
change a past period is repriced from whatever transcripts are left. A period whose scan
read under 99.5% of the responses an earlier snapshot recorded for it is marked with `!`
(console) or `(partial N%)` (vault), and every console view and the vault list the counts
(read and on record); `--json` carries them per day. A week is bucketed on the fixed
US-Pacific reset boundary, so a shortfall there means pruned transcripts. A DAY is
bucketed in this machine's local time: a snapshot taken in another timezone files the same
responses under different days, which reads as a shortfall just as pruning does, so a
marked day names both causes. See "partial periods" below.
"""
import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from fractions import Fraction
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from usage_accounting import RATES, RATE_CARD_VERSION, Responses, price_usage, token_split

ROOT = Path.home() / ".claude" / "projects"
HIST_DIR = Path.home() / ".claude" / "usage-history"
MACHINE_FILE = Path.home() / ".claude" / "machine-name"

PRICING = [(model, (float(rate[0]), float(rate[1])))
           for model, rate in RATES.items()]

TIERS = ["fable", "opus", "sonnet", "haiku"]


def machine_name():
    if MACHINE_FILE.exists():
        name = MACHINE_FILE.read_text().strip()
        if name:
            return name
    raw = ""
    try:
        raw = subprocess.run(["scutil", "--get", "ComputerName"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        pass
    if not raw:
        import platform
        raw = platform.node()
    name = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", raw.lower())).strip("-")
    name = name or "unknown"
    MACHINE_FILE.write_text(name + "\n")
    return name


def rates(model):
    if model not in RATES:
        raise ValueError("unpriced model: %s" % model)
    rate = RATES[model]
    return float(rate[0]), float(rate[1])


def tier(model):
    for t in TIERS:
        if t in model:
            return t
    return "other"


def cost_usd(u, model):
    return float(price_usage(u, model)["lower_usd"])


def selected_responses():
    """One global pass over parent, child, streamed and copied assistant records."""
    selected = Responses()
    for path in ROOT.rglob("*.jsonl"):
        parts = path.parts
        if "memory" in parts or "tool-results" in parts:
            continue
        try:
            fh = open(path, "r", errors="replace")
        except OSError:
            continue
        with fh:
            for line_no, line in enumerate(fh, 1):
                try:
                    selected.add(json.loads(line), str(path), line_no,
                                 "child" if "subagents" in parts else "main")
                except json.JSONDecodeError:
                    continue
    selected.selected  # finalize one-ID aliases after every pair has been observed
    if (selected.conflicts or selected.unidentified or selected.cross_role_pairs or
            selected.ambiguous_identities or selected.without_terminal_metadata()):
        print("usage coverage: %d conflicting copies, %d unidentified records, "
              "%d cross-role copies, %d ambiguous IDs, %d selected responses without "
              "terminal metadata" % (selected.conflicts, selected.unidentified,
              selected.cross_role_pairs, selected.ambiguous_identities,
              selected.without_terminal_metadata()), file=sys.stderr)
    return selected


def root_session(source):
    path = Path(source)
    if "subagents" in path.parts:
        index = path.parts.index("subagents")
        return path.parts[index - 1]
    return path.stem


def scan():
    days = defaultdict(lambda: defaultdict(float))
    tiers = defaultdict(lambda: defaultdict(float))
    sessions = defaultdict(set)
    for item in selected_responses().rows():
        e = item["record"]
        msg = e.get("message") or {}
        u, model, ts = msg["usage"], msg.get("model"), e.get("timestamp")
        if not ts:
            continue
        try:
            day = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
        except ValueError:
            continue
        d = days[day]
        try:
            tokens = token_split(u)
        except (TypeError, ValueError):
            tokens = None
        if tokens is not None:
            d["output_tokens"] += tokens["output_tokens"]
            d["cache_read_tokens"] += tokens["cache_read_input_tokens"]
            d["token_observed_responses"] += 1
            sessions[day].add(root_session(item["source"]))
        try:
            priced = price_usage(u, model)
        except ValueError:
            d["unpriced_responses"] += 1
            continue
        c = float(priced["lower_usd"])
        d["cost"] += c
        d["cost_upper"] += float(priced["upper_usd"])
        d["geo_unknown_responses"] += int(priced["geography_uncertain"])
        d["cache_ttl_unknown_tokens"] += priced["tokens"]["cache_ttl_unknown_tokens"]
        d["requests"] += 1
        d["cache_read_cost"] += u.get("cache_read_input_tokens", 0) * float(RATES[model][4]) / 1e6
        tiers[day][tier(model)] += c
    result = {}
    for day, d in days.items():
        rec = {k: round(v, 4) for k, v in d.items()}
        rec["sessions"] = len(sessions[day])
        rec["tier_cost"] = {t: round(c, 2) for t, c in tiers[day].items()}
        rec["rate_card"] = RATE_CARD_VERSION
        result[day] = rec
    return result


# ---------------- partial periods (#392) ----------------
# A rate-card change starts new v2 files, so the first scan under a card is the only
# source of dollars for every past period. Transcripts are pruned whole files at a time
# (not on a clean time horizon), so a past period can be repriced from a fraction of its
# responses and shown as if it were whole. Dollars are not comparable across rate cards;
# COUNTS of responses are. So the largest count any earlier snapshot recorded for a
# period is a high-water mark, and the shortfall against what the scan read is persisted
# in the v2 record as `requests_not_rescanned` (absent when 0) and shown. A shortfall
# sums across machines; a raw high-water would not. Dollars are never carried over.
#
# A period is marked partial when the scan read under PARTIAL_BELOW of the requests on
# record. What the two series were measured to do on one machine's real history: WEEKS
# showed no counting difference (the closed weeks whose transcripts were all still on disk
# reconciled exactly once unpriced responses were counted); DAYS differed by at most 2
# responses (0.19% of that day) where a response's partial and complete records fall either
# side of local midnight, which the old first-record dedupe and the current complete-record
# rule file under different days, each loss matched by an equal gain on the next day.
# Pruning measured larger: 8 responses (0.32% of a day) was real, as was 413 (1.39% of a
# week). So the threshold sits between the two, and a shortfall under it is still
# persisted and listed, just not marked. Not an absolute minimum: a tiny day missing
# a few responses is genuinely partial.
PARTIAL_BELOW = 0.995
LIST_CAP = 10   # lines per listing in a console view; --json (and the vault table) carry all
READ_NOTE = ('("read" counts priced and unpriced responses; the reqs column counts priced '
             'ones only)')


def floor_pct(read, on_record):
    """Percent read, floored to one decimal in integer arithmetic: a marked period never
    prints as its own threshold, and a short one never rounds up to a whole."""
    return (1000 * read // on_record) / 10 if on_record else 100.0


def read_pct_label(read, on_record):
    """The one label every console view, the vault and --oneline print."""
    return f"{floor_pct(read, on_record):.1f}%"


def _count(rec, field):
    """A non-negative whole count from a persisted record; 0 when absent or malformed."""
    try:
        return max(0, int(round(float(rec.get(field) or 0))))
    except (AttributeError, TypeError, ValueError, OverflowError):
        return 0


def responses_read(rec):
    """Responses a record's dollars are built from: priced plus unpriced.

    Compared like with like: a pre-v2 record has only `requests`, and a v2 `requests`
    counts priced responses only, so `unpriced_responses` is added (on real data pre-v2
    `requests` equals v2 `requests + unpriced_responses` to within one).
    `token_observed_responses` is not used: pre-v2 records lack it, and it leaves out
    responses whose token counters are invalid."""
    return _count(rec, "requests") + _count(rec, "unpriced_responses")


def responses_on_record(rec):
    """Responses a record accounts for: those it read plus those it already knew it did not."""
    return responses_read(rec) + _count(rec, "requests_not_rescanned")


def read_records(path):
    """Persisted {period: record} from a snapshot file; {} when absent or unreadable."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):   # ValueError: a corrupt or non-UTF-8 file is ignored
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}


def merge_period_records(own_hist, fresh, earlier_hist):
    """Fold a scan into this machine's persisted v2 records, in place.

    Dollars and the read count follow the existing rule: transcripts prune whole files,
    so the same-card record that saw more requests wins, and a record under another
    card is replaced. The shortfall is then set against the high-water mark: the largest
    count among the pre-v2 snapshot (`earlier_hist`), a persisted record under another
    card (which hands its count on instead of losing it), and a same-card persisted
    record ONLY when it already carries a mark (read plus mark). A same-card record's read
    count alone is no earlier snapshot: the winner rule compares priced `requests`, so it
    cannot tell a pruned transcript from a rescan that priced fewer responses."""
    for period in sorted(set(fresh) | set(own_hist)):
        new, old = fresh.get(period), own_hist.get(period)
        same_card = old is not None and old.get("rate_card") == RATE_CARD_VERSION
        if new is not None and (not same_card or new.get("requests", 0) >= old.get("requests", 0)):
            chosen = dict(new)
        elif same_card:
            chosen = old
        else:
            continue   # another card's record and nothing fresh: left as it is
        recorded = [responses_on_record(r) for r in (earlier_hist.get(period),) if r is not None]
        if old is not None and (not same_card or _count(old, "requests_not_rescanned")):
            recorded.append(responses_on_record(old))
        short = max(0, max(recorded, default=0) - responses_read(chosen))
        if short:
            chosen["requests_not_rescanned"] = short
        else:
            chosen.pop("requests_not_rescanned", None)
        own_hist[period] = chosen


def unread_periods(own_hist, earlier_hist):
    """{period: count} for periods an earlier snapshot recorded that no v2 record of this
    machine covers (every transcript is gone). Derived on each run from the earlier
    snapshots, never persisted, and never carrying a dollar."""
    out = {}
    for period in set(own_hist) | set(earlier_hist):
        rec = own_hist.get(period)
        if isinstance(rec, dict) and rec.get("rate_card") == RATE_CARD_VERSION:
            continue
        count = max((responses_on_record(r) for r in (rec, earlier_hist.get(period))
                     if isinstance(r, dict)), default=0)
        if count:
            out[period] = count
    return out


def has_earlier_card(kind, machine):
    """True when this machine has records under another rate card: its pre-v2 snapshot,
    or v2 records stamped with a different card."""
    return bool(read_records(HIST_DIR / f"{kind}-{machine}.json")) or any(
        rec.get("rate_card") != RATE_CARD_VERSION
        for rec in read_records(HIST_DIR / f"{kind}-v2-{machine}.json").values())


def is_unread(rec):
    """A merged period with requests on record and nothing read: it has no row."""
    return responses_read(rec) == 0 and _count(rec, "requests_not_rescanned") > 0


def period_coverage(rec):
    """How much of the requests on record the scan read, for one merged day or week."""
    read, short = responses_read(rec), _count(rec, "requests_not_rescanned")
    on_record = read + short
    return {"read": read, "short": short, "on_record": on_record,
            "read_pct": floor_pct(read, on_record),
            "partial": short > 0 and Fraction(read) < Fraction(str(PARTIAL_BELOW)) * on_record}


def coverage_text(c):
    return f"read {c['read']:,} of {c['on_record']:,} requests on record ({read_pct_label(c['read'], c['on_record'])})"


def print_shortfall_lines(footer, lists):
    """The one printer for every console view's lists. `footer` is a line or None;
    `lists` is [(heading, items, earlier)]: items [(period, text, sort key)] sorted by key
    and cut at LIST_CAP, and `earlier` (count, first shown period, hint) for periods
    before the shown span, which are counted rather than listed. Prints nothing at all
    when there is nothing to say."""
    lists = [x for x in lists if x[1] or (x[2] and x[2][0])]
    if not footer and not lists:
        return
    print(READ_NOTE)
    if footer:
        print(footer)
    for heading, items, earlier in lists:
        print(heading)
        items = sorted(items, key=lambda x: x[2])
        for period, text, _ in items[:LIST_CAP]:
            print(f"  {period}: {text}")
        if len(items) > LIST_CAP:
            print(f"  ... and {len(items) - LIST_CAP} more")
        if earlier and earlier[0]:
            print(f"  {earlier[0]} more before {earlier[1]}{earlier[2]}")


def day_json(r):
    """One merged day for --json. A day with a shortfall also says what was read, what is on
    record, and whether it is marked: derived here and never persisted (the weekly merge
    sums every persisted field). `transcripts_left` means the scan read at least one
    response for the day. A day without a shortfall keeps exactly its merged keys."""
    out = {**r, "tier_cost": dict(r["tier_cost"])}
    if r.get("requests_not_rescanned"):
        c = period_coverage(r)
        out.update(requests_read=c["read"], requests_on_record=c["on_record"],
                   read_pct=c["read_pct"], partial=c["partial"], transcripts_left=c["read"] > 0)
    return out


def merge_own(fresh, own_file, earlier_file=None):
    hist = json.loads(own_file.read_text()) if own_file.exists() else {}
    merge_period_records(hist, fresh, read_records(earlier_file) if earlier_file else {})
    own_file.write_text(json.dumps(dict(sorted(hist.items())), indent=1))
    return hist


def git(*args, timeout=60):
    try:
        return subprocess.run(["git", "-C", str(HIST_DIR), *args],
                              capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def has_remote():
    if not (HIST_DIR / ".git").exists():
        return False
    r = git("remote")
    return bool(r and r.stdout.strip())


def sync_pull():
    r = git("pull", "--rebase", "--quiet", timeout=120)
    if r is None or r.returncode != 0:
        print("note: git pull failed (offline?) — using local data",
              file=sys.stderr)


def sync_push(own_file, machine):
    git("add", "--", own_file.name)
    weekly = HIST_DIR / f"weekly-v2-{machine}.json"
    if weekly.exists():
        git("add", "--", weekly.name)  # written by --week --write; synced by the daily run
    staged = git("diff", "--cached", "--quiet")
    if staged is not None and staged.returncode == 1:
        git("commit", "--quiet", "-m",
            f"usage: {machine} through {datetime.now().strftime('%Y-%m-%d')}")
    # push whenever local is ahead — covers commits stranded by an earlier
    # failed push, not just the commit made this run
    ahead = git("rev-list", "--count", "@{u}..HEAD")
    if ahead is None or ahead.returncode != 0 or ahead.stdout.strip() != "0":
        r = git("push", "--quiet", timeout=120)
        if r is None or r.returncode != 0:
            print("note: git push failed — snapshot committed locally",
                  file=sys.stderr)


def _day_bucket() -> dict:
    return {
        "cost": 0.0, "requests": 0, "sessions": 0, "output_tokens": 0,
        "cost_upper": 0.0, "cache_ttl_unknown_tokens": 0,
        "unpriced_responses": 0, "geo_unknown_responses": 0,
        "token_observed_responses": 0,
        "cache_read_tokens": 0, "cache_read_cost": 0.0,
        "tier_cost": defaultdict(float), "machines": [],
    }


def merged_history(machine=None):
    merged = defaultdict(_day_bucket)
    for f in sorted(HIST_DIR.glob("daily-v2-*.json")):
        m = f.stem[len("daily-v2-"):]
        try:
            hist = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for day, r in hist.items():
            if r.get("rate_card") != RATE_CARD_VERSION:
                continue
            g = merged[day]
            g["cost"] += r.get("cost", 0)
            g["cost_upper"] += r.get("cost_upper", r.get("cost", 0))
            g["cache_ttl_unknown_tokens"] += r.get("cache_ttl_unknown_tokens", 0)
            g["unpriced_responses"] += r.get("unpriced_responses", 0)
            g["geo_unknown_responses"] += r.get("geo_unknown_responses", 0)
            g["requests"] += int(r.get("requests", 0))
            g["token_observed_responses"] += int(r.get("token_observed_responses",
                                                        r.get("requests", 0)))
            g["sessions"] += r.get("sessions", 0)
            g["output_tokens"] += r.get("output_tokens", 0)
            g["cache_read_tokens"] += r.get("cache_read_tokens", 0)
            g["cache_read_cost"] += r.get("cache_read_cost", 0)
            for t, c in (r.get("tier_cost") or {}).items():
                g["tier_cost"][t] += c
            g["machines"].append(m)
            if _count(r, "requests_not_rescanned"):
                g["requests_not_rescanned"] = (g.get("requests_not_rescanned", 0) +
                                               _count(r, "requests_not_rescanned"))
    if machine:
        # days this machine's earlier snapshots recorded and no transcript still covers
        for day, count in unread_periods(read_records(HIST_DIR / f"daily-v2-{machine}.json"),
                                         read_records(HIST_DIR / f"daily-{machine}.json")).items():
            g = merged[day]
            g["requests_not_rescanned"] = g.get("requests_not_rescanned", 0) + count
    return dict(sorted(merged.items()))


# ---------------- meter-week rollup (--week) ----------------
# The subscription meters reset Wednesday 15:59 PT, so calendar-day buckets can
# never reconstruct the week that a meter reading describes. This mode re-scans
# transcripts, buckets each request by the Wed-15:59-PT boundary that CLOSES its
# week, and splits main-thread from subagent spend ("subagents" in the path).
# It never git-syncs and never writes the daily-*.json files.

PT_ZONE = "America/Los_Angeles"
WEEK_WD, WEEK_H, WEEK_MIN = 2, 15, 59  # Wednesday (Mon=0), 15:59
CAP_EST = {"all": 1900.0, "fable": 940.0}  # 2026-08-06 calibration ESTIMATES, not published caps
VAULT_WEEKS_MD = Path.home() / "Obsidian" / "no-it-all" / "briefs" / "usage-weeks.md"


def meter_week_close(dt):
    """The Wed-15:59-PT boundary that closes dt's meter week, as YYYY-MM-DD."""
    from zoneinfo import ZoneInfo
    loc = dt.astimezone(ZoneInfo(PT_ZONE))
    cand = (loc + timedelta(days=(WEEK_WD - loc.weekday()) % 7)).replace(
        hour=WEEK_H, minute=WEEK_MIN, second=0, microsecond=0)
    if cand <= loc:
        cand += timedelta(days=7)
    return cand.strftime("%Y-%m-%d")


def scan_weeks():
    weeks = defaultdict(lambda: defaultdict(float))
    for item in selected_responses().rows():
        e = item["record"]
        msg = e.get("message") or {}
        u, model, ts = msg["usage"], msg.get("model"), e.get("timestamp")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            continue
        w = weeks[meter_week_close(dt)]
        is_sub = item["role"] == "child"
        try:
            tokens = token_split(u)
        except (TypeError, ValueError):
            tokens = None
        if tokens is not None:
            w["token_observed_responses"] += 1
            if not is_sub:
                w["reqs_main"] += 1
                w["ctx_main"] += (tokens["input_tokens"] + tokens["cache_read_input_tokens"]
                                  + tokens["cache_5m_tokens"] + tokens["cache_1h_tokens"]
                                  + tokens["cache_ttl_unknown_tokens"])
        try:
            priced = price_usage(u, model)
        except ValueError:
            w["unpriced_responses"] += 1
            continue
        c = float(priced["lower_usd"])
        w["cost"] += c
        w["cost_upper"] += float(priced["upper_usd"])
        w["geo_unknown_responses"] += int(priced["geography_uncertain"])
        w["cache_ttl_unknown_tokens"] += priced["tokens"]["cache_ttl_unknown_tokens"]
        w["requests"] += 1
        w["cost_sub" if is_sub else "cost_main"] += c
        w["cost_sub_upper" if is_sub else "cost_main_upper"] += float(priced["upper_usd"])
        w[f"tier_{tier(model)}"] += c
        w["cache_read_cost"] += u.get("cache_read_input_tokens", 0) * float(RATES[model][4]) / 1e6
    return {k: {**{f: round(v, 4) for f, v in rec.items()},
                "rate_card": RATE_CARD_VERSION} for k, rec in weeks.items()}


def merged_weekly(fresh, machine, write):
    own_file = HIST_DIR / f"weekly-v2-{machine}.json"
    own_hist = {}
    if own_file.exists():
        try:
            own_hist = json.loads(own_file.read_text())
        except (OSError, ValueError):
            own_hist = {}
    # this machine's record for a week = whichever of (persisted, fresh scan) saw
    # more requests — transcripts prune whole files, so a shrunken re-scan must not win
    earlier = read_records(HIST_DIR / f"weekly-{machine}.json")
    merge_period_records(own_hist, fresh, earlier)
    if write:
        own_file.write_text(json.dumps(dict(sorted(own_hist.items())), indent=1))
    # printed view = other machines' persisted snapshots + this machine's best record.
    # Own fresh data must never be compared against (or replace) the cross-machine SUM.
    merged = {}
    for f in sorted(HIST_DIR.glob("weekly-v2-*.json")):
        if f.name == own_file.name:
            continue
        try:
            hist = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for wk, rec in hist.items():
            if rec.get("rate_card") != RATE_CARD_VERSION:
                continue
            g = merged.setdefault(wk, defaultdict(float))
            for field, v in rec.items():
                if field != "rate_card":
                    g[field] += v
    for wk, rec in own_hist.items():
        if rec.get("rate_card") != RATE_CARD_VERSION:
            continue
        g = merged.setdefault(wk, defaultdict(float))
        for field, v in rec.items():
            if field != "rate_card":
                g[field] += v
    # weeks this machine's earlier snapshots recorded and no transcript still covers
    for wk, count in unread_periods(own_hist, earlier).items():
        merged.setdefault(wk, defaultdict(float))["requests_not_rescanned"] += count
    return dict(sorted(merged.items()))


def week_rows(hist, n):
    rows = []
    for wk, r in [(k, v) for k, v in hist.items() if not is_unread(v)][-n:]:
        cost = r.get("cost", 0)
        rows.append({**period_coverage(r),
            "close": wk, "cost": cost, "cost_upper": r.get("cost_upper", cost),
            "cache_ttl_unknown_tokens": r.get("cache_ttl_unknown_tokens", 0),
            "unpriced_responses": r.get("unpriced_responses", 0),
            "geo_unknown_responses": r.get("geo_unknown_responses", 0),
            "main": r.get("cost_main", 0), "sub": r.get("cost_sub", 0),
            "sub_pct": 100 * r.get("cost_sub", 0) / cost if cost else 0,
            "fable": r.get("tier_fable", 0), "opus": r.get("tier_opus", 0),
            "sonnet": r.get("tier_sonnet", 0), "reqs": round(r.get("requests", 0)),
            "ctx": r.get("ctx_main", 0) / r.get("reqs_main", 1) / 1000 if r.get("reqs_main") else 0,
            "crp": 100 * r.get("cache_read_cost", 0) / cost if cost else 0,
            "all_cap": 100 * cost / CAP_EST["all"],
            "fable_cap": 100 * r.get("tier_fable", 0) / CAP_EST["fable"],
        })
    return rows


def unread_weeks(hist):
    """[(week close, requests on record)] for weeks with nothing left to read."""
    return [(wk, _count(r, "requests_not_rescanned")) for wk, r in hist.items() if is_unread(r)]


def week_amount(lower, upper):
    """Show a bounded week with enough precision to expose its endpoints."""
    if upper > lower:
        for decimals in range(2, 13):
            lo, hi = f"${lower:,.{decimals}f}", f"${upper:,.{decimals}f}"
            if lo != hi:
                return f"{lo}–{hi}"
        return f"${lower:.12g}–${upper:.12g}"
    if 0 < lower < .01:
        for decimals in range(2, 13):
            shown = f"${lower:,.{decimals}f}"
            if float(shown[1:].replace(",", "")) > 0:
                return shown
    return f"${lower:,.2f}" if lower < 1 else f"${lower:,.0f}"


def write_vault_weeks(rows, open_close=None, unread=(), earlier_card=False, machine="<machine>",
                      pre_v2_file=False):
    lines = [
        "---", "tags: [usage, meter-week]",
        "generated: regenerated in full by usage-trend.py --week --write; do not hand-edit", "---", "",
        "# Meter weeks (Wed 15:59 PT reset)", "",
        "Costs are API-list-rate equivalents from local transcripts (subscription proxy,",
        "this machine's scan merged with any other machines' snapshots). cap% columns are",
        "against the 2026-08-06 calibration ESTIMATES (~$1.9K all-models / ~$0.94K Fable),",
        "which the weekly meter reading (meter-readings.md) exists to recalibrate.",
        "A week marked (open) is still accumulating.",
    ]
    if earlier_card and pre_v2_file:
        lines.append(f"Priced under rate card {RATE_CARD_VERSION}; figures under an earlier rate card "
                     f"remain in weekly-{machine}.json and are not comparable with these.")
    elif earlier_card:
        lines.append(f"Priced under rate card {RATE_CARD_VERSION}; earlier-card v2 records for weeks "
                     "this scan repriced are no longer on disk, and any earlier-card figures that "
                     "remain are not comparable with these.")
    lines += [
        "",
        "| week close | total | main | subagents | sub% | fable | opus | reqs | ctx/req(main) | cacheR% | all-cap% | fable-cap% |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        label = (r["close"] + (" (open)" if r["close"] == open_close else "") +
                 (f" (partial {read_pct_label(r['read'], r['on_record'])})" if r.get("partial") else ""))
        total = week_amount(r["cost"], r["cost_upper"])
        lines.append(
            f"| {label} | {total} | ${r['main']:,.0f} | ${r['sub']:,.0f} "
            f"| {r['sub_pct']:.0f}% | ${r['fable']:,.0f} | ${r['opus']:,.0f} | {r['reqs']:,} "
            f"| {r['ctx']:.0f}K | {r['crp']:.0f}% | {r['all_cap']:.0f}% | {r['fable_cap']:.0f}% |")
    uncertain = [r for r in rows if (r["cache_ttl_unknown_tokens"] or
                 r["unpriced_responses"] or r["geo_unknown_responses"])]
    if uncertain:
        lines += ["", "Uncertain coverage by week (unpriced responses are omitted from dollars;"
                  " unknown geography spans global to US pricing):", ""]
        lines += [f"- {r['close']}: {r['cache_ttl_unknown_tokens']:,.0f} unknown-TTL "
                  f"tokens; {r['unpriced_responses']:,.0f} unpriced responses; "
                  f"{r['geo_unknown_responses']:,.0f} geography-unknown responses"
                  for r in uncertain]
    short = [(r["close"], coverage_text(r) + ("; partial" if r["partial"] else ""))
             for r in rows if r.get("short")]
    short += [(wk, f"not rescanned: {count:,} requests on record and no transcripts left "
               "(no row: no dollars on this card)") for wk, count in unread]
    if short:
        lines += ["", "Requests on record that the scan did not read (response counts, never dollars; "
                  f"{READ_NOTE[1:-1]}; a week is marked partial when the scan read under "
                  f"{PARTIAL_BELOW:.1%} of them, and the dollars above cover only what was read):", ""]
        lines += [f"- {wk}: {text}" for wk, text in sorted(short)]
    VAULT_WEEKS_MD.parent.mkdir(parents=True, exist_ok=True)
    VAULT_WEEKS_MD.write_text("\n".join(lines) + "\n")


def week_main():
    machine = machine_name()
    HIST_DIR.mkdir(parents=True, exist_ok=True)
    now_close = meter_week_close(datetime.now().astimezone())
    if "--close-label" in sys.argv:
        print(now_close)
        return
    n = 8
    if "--weeks" in sys.argv:
        try:
            n = max(1, int(sys.argv[sys.argv.index("--weeks") + 1]))
        except (IndexError, ValueError):
            sys.exit("--weeks needs a number")
    write = "--write" in sys.argv
    earlier_card = has_earlier_card("weekly", machine)   # before the merge can replace any record
    pre_v2_file = (HIST_DIR / f"weekly-{machine}.json").exists()
    fresh = scan_weeks()
    hist = merged_weekly(fresh, machine, write)
    rows = week_rows(hist, n)
    if "--oneline" in sys.argv:
        r = next((x for x in week_rows(hist, len(hist)) if x["close"] == now_close), None)
        if r:
            amount = week_amount(r["cost"], r["cost_upper"])
            print(f"week closing {r['close']}: {amount} total "
                  f"(main ${r['main']:,.0f} / sub ${r['sub']:,.0f}), fable ${r['fable']:,.0f} "
                  f"= {r['fable_cap']:.0f}% of est. cap; "
                  f"{r['cache_ttl_unknown_tokens']:,.0f} unknown-TTL tokens, "
                  f"{r['unpriced_responses']:,.0f} unpriced responses, "
                  f"{r['geo_unknown_responses']:,.0f} geography-unknown responses"
                  + (f"; partial: the scan read {read_pct_label(r['read'], r['on_record'])} of the "
                     f"{r['on_record']:,} requests on record" if r["partial"] else ""))
        else:
            print(f"week closing {now_close}: no activity recorded yet")
        return
    print(f"{'week close':<14}{'total$':>17}{'main$':>8}{'sub$':>7}{'sub%':>6}"
          f"{'fable$':>8}{'opus$':>7}{'reqs':>7}{'ctx/req':>9}{'cacheR%':>9}{'all-cap%':>10}{'fbl-cap%':>10}")
    for r in rows:
        markers = ("*" if r["close"] == now_close else "") + ("!" if r["partial"] else "")
        label = r["close"] + (" " + markers if markers else "")
        print(f"{label:<14}{week_amount(r['cost'], r['cost_upper']):>17}{r['main']:>8.0f}{r['sub']:>7.0f}{r['sub_pct']:>5.0f}%"
              f"{r['fable']:>8.0f}{r['opus']:>7.0f}{r['reqs']:>7}{r['ctx']:>8.0f}K{r['crp']:>8.0f}%"
              f"{r['all_cap']:>9.0f}%{r['fable_cap']:>9.0f}%")
    print("\n* = open (still accumulating). cap% vs 2026-08-06 ESTIMATES "
          "(~$1.9K all / ~$0.94K fable) — recalibrate from meter-readings.md")
    marked = [r for r in rows if r["partial"]]
    print_shortfall_lines(
        f"! = partial: the scan read under {PARTIAL_BELOW:.1%} of the requests on record "
        "(transcripts pruned since; the dollars cover only what was read): " +
        "; ".join(f"{r['close']} {read_pct_label(r['read'], r['on_record'])} "
                  f"({r['read']:,} of {r['on_record']:,})" for r in marked) if marked else None,
        [("shown weeks with a shortfall too small to mark:",
          [(r["close"], coverage_text(r), (r["read_pct"], r["close"]))
           for r in rows if r["short"] and not r["partial"]], None),
         # every run, not scoped to the shown span: there are only ever a few
         ("weeks with nothing read (no row: no dollars on this card):",
          [(wk, f"{count:,} requests on record, no transcripts left", (-count, wk))
           for wk, count in unread_weeks(hist)], None)])
    ttl = sum(r["cache_ttl_unknown_tokens"] for r in rows)
    unpriced = sum(r["unpriced_responses"] for r in rows)
    geo_unknown = sum(r["geo_unknown_responses"] for r in rows)
    print(f"coverage: {ttl:,.0f} unknown-TTL tokens; {unpriced:,.0f} unpriced responses; "
          f"{geo_unknown:,.0f} geography-unknown responses; displayed dollars are "
          "lower bounds where coverage is uncertain")
    if write:
        write_vault_weeks(week_rows(hist, len(hist)), now_close, unread_weeks(hist),
                          earlier_card, machine, pre_v2_file)  # vault gets FULL history
        print(f"persisted weekly-v2-{machine}.json and regenerated {VAULT_WEEKS_MD}")


def main():
    machine = machine_name()
    HIST_DIR.mkdir(parents=True, exist_ok=True)
    own_file = HIST_DIR / f"daily-v2-{machine}.json"

    do_sync = "--no-sync" not in sys.argv and has_remote()
    if do_sync:
        sync_pull()
    merge_own(scan(), own_file, HIST_DIR / f"daily-{machine}.json")
    if do_sync:
        sync_push(own_file, machine)

    hist = merged_history(machine)
    n_machines = len(set(m for r in hist.values() for m in r["machines"]))
    if "--json" in sys.argv:
        print(json.dumps({d: day_json(r) for d, r in hist.items()}, indent=1))
        return
    rows = [(d, r) for d, r in hist.items() if not is_unread(r)]
    if "--all" not in sys.argv:
        rows = rows[-30:]
    unread_days = [d for d, r in hist.items() if is_unread(r)]   # whole history: they never have a row
    mach_col = "mach" if n_machines > 1 else ""
    print(f"{'day':<12}{'cost$':>8}{'reqs':>7}{'sess':>6}{'cacheR%':>9}"
          f"{'ctx/req':>9}{'fable%':>8}{'opus%':>7}{'sonnet%':>8}"
          + (f"{mach_col:>6}" if mach_col else ""))
    marked_days = 0
    for day, r in rows:
        cost = r["cost"]
        crp = 100 * r["cache_read_cost"] / cost if cost else 0
        observed = r["token_observed_responses"]
        ctx = r["cache_read_tokens"] / observed / 1000 if observed else 0
        tc = r["tier_cost"]
        def pct(t):
            return 100 * tc.get(t, 0) / cost if cost else 0
        partial = period_coverage(r)["partial"]
        marked_days += partial
        line = (f"{day + '!' * partial:<12}{cost:>8.2f}{r['requests']:>7}{r['sessions']:>6}"
                f"{crp:>8.0f}%{ctx:>8.0f}K"
                f"{pct('fable'):>7.0f}%{pct('opus'):>6.0f}%{pct('sonnet'):>7.0f}%")
        if mach_col:
            line += f"{len(r['machines']):>6}"
        print(line)
    tot = sum(r["cost"] for _, r in rows)
    upper = sum(r["cost_upper"] for _, r in rows)
    amount = f"${tot:,.2f}–${upper:,.2f}" if upper > tot else f"${tot:,.2f}"
    print(f"\n{len(rows)} days shown, {amount} total (API-list-rate equivalent)"
          f" across {n_machines} machine(s)")
    ttl = sum(r["cache_ttl_unknown_tokens"] for _, r in rows)
    unpriced = sum(r["unpriced_responses"] for _, r in rows)
    geo_unknown = sum(r["geo_unknown_responses"] for _, r in rows)
    print(f"coverage: {ttl:,.0f} unknown-TTL tokens; {unpriced:,.0f} unpriced responses; "
          f"{geo_unknown:,.0f} geography-unknown responses")
    if marked_days or unread_days:
        # first shown day: the span the "before" count refers to; --all lists everything
        span = "" if "--all" in sys.argv or not rows else rows[0][0]
        unread_items = [(d, f"{_count(hist[d], 'requests_not_rescanned'):,} requests on record, nothing read",
                         (-_count(hist[d], "requests_not_rescanned"), d)) for d in unread_days]
        print_shortfall_lines(
            f"! = partial: {marked_days} of the {len(rows)} day(s) shown were read at under "
            f"{PARTIAL_BELOW:.1%} of the responses an earlier snapshot recorded for that local day; "
            f"{len(unread_days)} recorded day(s) in the whole history have nothing read. Either "
            "transcripts were pruned, or the snapshot was taken in another timezone (days are "
            "bucketed in this machine's local time).",
            [("partial days shown:",
              [(d, coverage_text(c), (c["read_pct"], d)) for d, c in
               ((d, period_coverage(r)) for d, r in rows) if c["partial"]], None),
             ("recorded days with nothing read (no row: no dollars on this card):",
              [x for x in unread_items if x[0] >= span],
              (len([x for x in unread_items if x[0] < span]), span, " (--all lists them)"))])
    print(f"this machine: {machine} -> {own_file.name}; history dir: {HIST_DIR}")


if __name__ == "__main__":
    if "--week" in sys.argv:
        week_main()
    else:
        # week-only flags without --week must fail loudly, not silently run the
        # git-syncing daily path (that silent-ignore is how flag typos corrupt data)
        stray = {"--weeks", "--oneline", "--close-label", "--write"} & set(sys.argv)
        if stray:
            sys.exit(f"{sorted(stray)} require --week")
        main()
