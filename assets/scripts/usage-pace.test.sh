#!/usr/bin/env bash
# Regression tests for assets/scripts/usage-pace.py.
#
# These call the script. Every assertion is about behaviour a caller depends on,
# and several encode a defect this suite actually caught during development:
#
#   - `--caps` had an invalid format string (`'$%,.0f' % x`) and crashed outright.
#   - `last_model()` copied usage-trend.py's compact-separator fast path. That
#     filter is justified where it walks millions of lines; here it walks a few
#     hundred, so it bought nothing and would have made the hook go PERMANENTLY
#     SILENT on any writer spacing change — the one failure nobody notices.
#   - `--units` broke ties with min(), silently naming a unit that only tied.
#     Dollars and input-equivalent tokens differ ONLY by the per-model price
#     multiplier, so they are degenerate whenever readings share a model mix.
#   - the usage line printed `<all-pct>` placeholders, which a shell reads as a
#     redirection. A documented form that cannot be run as written is a defect.
#
# The suite does NOT `set -e`: several of these are "the guard failed and the run
# carried on anyway", which `set -e` would hide.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/usage-pace.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
# This is the only suite that IMPORTS the SUT rather than running it as a subprocess,
# so it is the only one that would drop __pycache__/ into the tracked source tree.
export PYTHONDONTWRITEBYTECODE=1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/usage-pace-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
skipt(){ skip=$((skip+1)); printf '  SKIP %s — %s\n' "$1" "$2"; }
flat() { printf '%s' "$1" | tr '\n' '|'; }

echo "usage-pace.test.sh"

# ------------------------------------------------------------------ unit helpers
# Import the script as a module so the pure functions can be exercised without a
# transcript tree. Nothing here redefines what the script is responsible for.
pymod() {
  "$PY" - "$SUT" "$@" <<'PYEOF'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("up", sys.argv[1])
up = importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
exec(sys.argv[2])
PYEOF
}

# ------------------------------------------------------- fixture HOME (the live meter)
# Builds a fake HOME whose live meter sample, transcripts and arithmetic are all KNOWN,
# and prints the expectations as JSON -- formatted exactly as the readout formats them.
# The script resolves the sample file under HOME, which is what makes the fixture possible
# at all; nothing here reaches machine state.
#
# The expectations are computed from the PRICES and the BUCKET RULE written out below, not
# from up.cost_usd / up.bucket_of. That is the whole point of the section: while the
# fixture called the script's own pricing, mutating Fable's output price from $50 to $70
# per million left the suite green on a CI-shaped HOME -- every dollar figure moved
# together and nothing outside the script disagreed.
FIXPY=$TMP/fixture-home.py
cat > "$FIXPY" <<'FIXEOF'
"""Build a fake HOME whose live meter, transcripts and arithmetic are all KNOWN.

Emits the expectations as JSON on stdout, formatted exactly as the readout formats them.

`reqs` places every request EXPLICITLY: [minutes_ago, output_tokens, model]. Explicit
because the figures now split at the sample -- the rate belongs over the meter as it was
READ, so spend before the sample and spend after it are different quantities, and a
fixture that scatters requests over a range cannot say which side each landed on.

Two things are reimplemented here rather than imported, and both are deliberate:
  - PRICES, from docs/the pricing table, as plain dollars per million output tokens;
  - the BUCKET rule (`ms // 60000`, windows `(lo, hi]` over those buckets -- the minute in
    progress counts, the minute containing the anchor does not), which is how the script
    documents its per-minute index.
Everything else about the world is stated in the config. `usable` is false when the meter
week opened too recently to place every request after the anchor -- the caller SKIPs
rather than asserting on a world it could not build.
"""
import importlib.util, json, pathlib, shutil, sys
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location("up", sys.argv[1])
up = importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
home = pathlib.Path(sys.argv[2]); cfg = json.loads(sys.argv[3])

# This builder rmtree's `home/Library` and `home/.claude/projects`, and `home` arrives as a
# command-line argument. One mistyped variable in a caller -- or an inherited $HOME reaching
# it -- and that is the real desktop app's sample history and the real transcript tree. So
# the caller must DECLARE the temp root it is working inside (argv[4]) and the builder
# refuses any home outside it, before touching anything. A guard placed after the first
# rmtree would be decoration.
tmproot = pathlib.Path(sys.argv[4]).resolve()
_h = home.resolve()
if not (_h == tmproot or tmproot in _h.parents):
    sys.exit("REFUSE: fixture HOME %s is not under the test temp dir %s" % (_h, tmproot))

# Dollars per million OUTPUT tokens. Independent of the script's PRICING table on purpose.
PRICES = {"claude-fable-5": 50.0, "claude-sonnet-4-5": 15.0, "claude-opus-5": 25.0}
FABLE = "claude-fable-5"
BUCKET = lambda ms: int(ms // 60000)      # the script's documented per-minute index

sd = float(cfg["sd"]); fh = cfg.get("fh", 8)
# What the meter READ at the anchor. Normally 0 -- but the app samples when its UI polls
# /usage, so the first post-reset sample can land after points are already burned, and a
# 100 -> 40 pair still passes the LIVE_DROP test. The denominator is then the points
# MOVED, not the current reading.
anchor_sd = float(cfg.get("anchor_sd", 0))
age_min = float(cfg.get("age_min", 5))
# [minutes_ago, output_tokens, model]. Default: one block before the sample and one after,
# so spend_at_sample and spend_since_sample are both non-zero in the ordinary case.
reqs = cfg.get("reqs") or [[40, 1_000_000, FABLE], [3, 200_000, FABLE]]
gap_n, gap_tok = int(cfg.get("gap_n", 0)), int(cfg.get("gap_tok", 400_000))
now = datetime.now(timezone.utc)
now_ms = now.timestamp() * 1000
wk = up.week_close(now)
open_ms = up.week_bounds(wk)[0].astimezone(timezone.utc).timestamp() * 1000
anchor = max(now_ms - 120 * 60_000, open_ms + 60_000)
samp_ms = now_ms - age_min * 60_000
# Every request, the gap request and the sample must sit strictly after the anchor, and
# the anchor's own two samples before it.
oldest = max([r[0] for r in reqs] + [age_min]) + 2
usable = (now_ms - anchor) > oldest * 60_000 and samp_ms > anchor

shutil.rmtree(home / ".claude" / "projects", ignore_errors=True)
shutil.rmtree(home / "Library", ignore_errors=True)
# The spend cache is derived from the transcripts about to be rewritten. _cache_stale
# would invalidate it, but leaving one behind makes every later assertion depend on that
# path instead of on the fixture, so it goes -- explicitly, and it is the ONLY thing
# under usage-history/ this builder may remove. It used to wipe the whole fake HOME, and
# ~/.claude/usage-history/pace-state.json went with it -- the hook's turn counter and its
# acknowledgment -- so the ack test rebuilt the world between runs and every run began
# with no state at all. A fixture that resets what the test measures is a test that
# cannot fail: deleting the acknowledgment logic outright left 116/116 green.
(home / ".claude" / "usage-history" / "pace-cache.json").unlink(missing_ok=True)
(home / ".claude" / "projects" / "p").mkdir(parents=True, exist_ok=True)
(home / "Library" / "Application Support" / "Claude").mkdir(parents=True, exist_ok=True)

# The gap request sits between the two samples the reset happened between: spend that
# cannot be attributed to either side of the meter's zero. The prev sample is 5 minutes
# back so that a one-minute bucket lands strictly inside the gap whatever the alignment.
ev = [(now_ms - m * 60_000, tok, model) for m, tok, model in reqs] \
     + [(anchor - 150_000, gap_tok, FABLE)] * gap_n
ev.sort()
lines = [json.dumps({"type": "assistant", "timestamp":
         datetime.fromtimestamp(t / 1000, timezone.utc).isoformat().replace("+00:00", "Z"),
         "message": {"id": "f%d" % i, "model": model,
                     "usage": {"output_tokens": tok}}}, separators=(",", ":"))
         for i, (t, tok, model) in enumerate(ev)]
(home / ".claude" / "projects" / "p" / "t.jsonl").write_text("\n".join(lines) + "\n")

samples = [{"t": int(anchor - 300_000), "u": {"sd": 100, "fh": 40}},
           {"t": int(anchor), "u": {"sd": anchor_sd, "fh": 0}},
           {"t": int(samp_ms), "u": {"sd": sd, "fh": fh}}]
(home / "Library" / "Application Support" / "Claude" / "plan-usage-history.json").write_text(
    json.dumps({"version": 2, "samples": samples}))

# --- the arithmetic, from PRICES and BUCKET only -------------------------------------
def total(lo_ms, hi_ms, fable_only=False):
    lo, hi = BUCKET(lo_ms), BUCKET(hi_ms)
    s = 0.0
    for t, tok, model in ev:
        if not (lo < BUCKET(t) <= hi):          # (lo, hi]: the minute in progress counts
            continue
        if fable_only and model != FABLE:
            continue
        s += tok * PRICES[model] / 1e6
    return s

spend = total(anchor, now_ms)                 # since the meter's zero, to now
at_s = total(anchor, samp_ms)                 # ...as of the instant the meter was READ
since = total(samp_ms, now_ms)                # ...burned in the sampling gap since
fable = total(anchor, now_ms, fable_only=True)
gap = total(anchor - 300_000, anchor)
burn1 = total(now_ms - 3600_000, now_ms)
burn3 = total(now_ms - 3 * 3600_000, now_ms) / 3.0
h_reset = (up.week_bounds(wk)[1].astimezone(timezone.utc) - now).total_seconds() / 3600.0

MIN_MOVED = 5.0   # below this the rate is provisional and the meter is NOT carried forward

def figures(at, gate=True):
    """The readout's chain, from a spend-at-sample figure.

    `gate=False` is the identical world with the PROVISIONAL GATE removed -- the mutant,
    computed here because "the lockout warning is withheld" is a vacuous claim unless the
    ungated world would have fired it. A caller asserting the gate reads `gate_matters`
    and SKIPs rather than passing on a world where nothing was being withheld.
    """
    moved = sd - anchor_sd
    rate = at / moved if moved > 0 and at > 0 else None
    prov = rate is not None and moved < MIN_MOVED and gate
    pct_now = sd + (since / rate if rate and not prov else 0.0)
    pts_left = max(0.0, 100.0 - pct_now)
    usd_left = pts_left * rate if rate else None
    wall = (usd_left / burn1 if usd_left is not None and burn1 > 0 else float("inf"))
    return {"rate": rate, "pct_now": pct_now, "pts_left": pts_left, "usd_left": usd_left,
            "wall": wall, "landing": pct_now + burn3 * h_reset / rate if rate else None,
            "need": usd_left / h_reset if usd_left is not None and h_reset > 0 else None,
            "prov": prov}

lo_f = figures(at_s)
hi_f = figures(at_s + gap)                    # the other end of the reset-gap range
lo_u = figures(at_s, gate=False)              # ...and the same world without the gate
fwd = (" ≈ %.0f%% now" % lo_f["pct_now"]) if "%.0f" % lo_f["pct_now"] != "%.0f" % sd else ""
print(json.dumps({
    "usable": usable, "sd": sd, "anchor_sd": anchor_sd,
    "spend": spend, "at_s": at_s, "since": since,
    "rate": lo_f["rate"], "pct_now": lo_f["pct_now"], "pts_left": lo_f["pts_left"],
    "gap": gap, "gap_s": "${:,.0f}".format(gap),
    "rate_rng_s": "${:,.1f}-${:,.1f}/pt".format(lo_f["rate"], hi_f["rate"]),
    # `landing` is DECREASING in the gap-spend end, so its range is the one that can print
    # backwards. Stated low-to-high here, which is how a range is read.
    "landing_rng_s": "→ lands {:,.0f}-{:,.0f}%".format(
        min(lo_f["landing"], hi_f["landing"]), max(lo_f["landing"], hi_f["landing"])),
    "landing_rng_ok": bool(
        lo_f["landing"] <= 100 and hi_f["landing"] <= 100
        and "{:,.0f}".format(lo_f["landing"]) != "{:,.0f}".format(hi_f["landing"])),
    "spend_rng_s": "spent ${:,.0f}-${:,.0f} since".format(spend, spend + gap),
    "usd_left": lo_f["usd_left"], "burn1": burn1, "burn3": burn3, "h_reset": h_reset,
    "wall": lo_f["wall"], "landing": lo_f["landing"], "need": lo_f["need"],
    "prov": lo_f["prov"],
    "prov_s": ("${:,.1f}/pt PROVISIONAL (the meter has moved {:,.0f} pt since the reset)"
               .format(lo_f["rate"], sd - anchor_sd) if lo_f["prov"] else ""),
    "warn_a": bool(lo_f["wall"] < 0.5 * h_reset and not lo_f["prov"]),
    # Would warning (a) fire in this world if the provisional gate were deleted? Only then
    # does asserting its absence assert anything.
    "gate_matters": bool(lo_u["wall"] < 0.5 * h_reset),
    "warn_b": bool(lo_f["landing"] < 90 and h_reset < 24),
    "sd_s": "sd %.0f%%" % sd, "fh_s": "fh %.0f%%" % float(fh), "fwd_s": fwd,
    "spend_s": "spent ${:,.0f} since".format(spend),
    "fable_s": "${:,.0f} fable".format(fable),
    "rate_s": "${:,.1f}/pt".format(lo_f["rate"]),
    "left_s": "{:.0f} pts ≈ ${:,.0f} left".format(lo_f["pts_left"], lo_f["usd_left"]),
    "burn_s": "burn ${:,.0f}/h (3h ${:,.0f}/h)".format(burn1, burn3),
    "reset_s": "reset in {:.1f}h".format(h_reset),
    "landing_s": ("→ lands >100% (the wall comes first)" if lo_f["landing"] > 100
                  else "→ lands {:,.0f}%".format(lo_f["landing"])),
    "need_s": "need ${:,.0f}/h to reach the wall".format(lo_f["need"]),
    "sample_s": "sample %s" % datetime.fromtimestamp(
        samp_ms / 1000, timezone.utc).strftime("%H:%M") + "Z",
}))
FIXEOF
mkfix() { "$PY" "$FIXPY" "$SUT" "$1" "$2" "$TMP"; }
fixf()  { printf '%s' "$1" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }

# ------------------------------------------------- 0. the fixture builder is fenced in
# It rmtree's home/Library and home/.claude/projects, and `home` is an argv. On the machine
# this suite runs on, those two paths under the real $HOME are the desktop app's sample
# history and every transcript ever written -- neither of which is recoverable, and the
# second of which is the only record the usage ledger is built from. So the builder is
# tested for REFUSING before it is trusted to build: a home outside the declared temp root
# must exit non-zero with nothing deleted.
DECOY=$TMP/decoy
mkdir -p "$DECOY/Library/Application Support/Claude" "$DECOY/.claude/projects/p"
printf 'irreplaceable' > "$DECOY/Library/sentinel.txt"
printf 'irreplaceable' > "$DECOY/.claude/projects/p/sentinel.jsonl"
out=$("$PY" "$FIXPY" "$SUT" "$DECOY" '{"sd":82}' "$TMP/somewhere-else" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ -f "$DECOY/Library/sentinel.txt" ] \
   && [ -f "$DECOY/.claude/projects/p/sentinel.jsonl" ]; then
  case "$out" in
    *REFUSE*) ok "the fixture builder refuses a HOME outside the declared temp dir, deleting nothing" ;;
    *) bad "the fixture builder refuses a HOME outside the temp dir" "rc=$rc says nothing: $(flat "$out")" ;;
  esac
else
  bad "the fixture builder refuses a HOME outside the declared temp dir, deleting nothing" \
      "rc=$rc sentinels: $([ -f "$DECOY/Library/sentinel.txt" ] && echo kept || echo DELETED)/$([ -f "$DECOY/.claude/projects/p/sentinel.jsonl" ] && echo kept || echo DELETED)"
fi

# ------------------------------------------------------------- 1. hook is inert
# The hook runs on EVERY prompt submit. Anything but a clean silent exit 0 on
# unexpected input degrades the prompt, so hostile stdin is tested first.
for label in 'empty object:{}' 'garbage:not json' 'empty string:' 'no transcript:{"session_id":"x"}'; do
  name=${label%%:*}; payload=${label#*:}
  out=$(printf '%s' "$payload" | "$PY" "$SUT" --hook 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] \
    && ok "hook exits 0 and silent on $name" \
    || bad "hook exits 0 and silent on $name" "rc=$rc out=$(flat "$out")"
done

# --------------------------------------------------- 2. last_model is format-agnostic
# Compact is what Claude Code writes today; the spaced form is the hypothetical
# that the removed fast path would have failed silently on.
t=$TMP/t.jsonl
"$PY" - "$t" <<'PYEOF'
import json, sys
rec={"type":"assistant","timestamp":"2026-09-02T20:00:00Z",
     "message":{"id":"m1","model":"claude-fable-5","usage":{"output_tokens":5}}}
open(sys.argv[1],"w").write(json.dumps(rec,separators=(",",":"))+"\n")
PYEOF
got=$(pymod "print(up.last_model(sys.argv[3]))" "$t" 2>&1)
[ "$got" = "claude-fable-5" ] && ok "last_model reads a compact-separator transcript" \
  || bad "last_model reads a compact-separator transcript" "got=$(flat "$got")"

"$PY" - "$t" <<'PYEOF'
import json, sys
rec={"type":"assistant","timestamp":"2026-09-02T20:00:00Z",
     "message":{"id":"m1","model":"claude-fable-5","usage":{"output_tokens":5}}}
open(sys.argv[1],"w").write(json.dumps(rec,separators=(", ",": "))+"\n")
PYEOF
got=$(pymod "print(up.last_model(sys.argv[3]))" "$t" 2>&1)
[ "$got" = "claude-fable-5" ] \
  && ok "last_model survives a spaced-separator writer (no fast-path filter)" \
  || bad "last_model survives a spaced-separator writer (no fast-path filter)" "got=$(flat "$got")"

printf '{"type":"assis' >> "$t"
got=$(pymod "print(up.last_model(sys.argv[3]))" "$t" 2>&1)
[ "$got" = "claude-fable-5" ] && ok "last_model ignores a truncated trailing line" \
  || bad "last_model ignores a truncated trailing line" "got=$(flat "$got")"

got=$(pymod "print(repr(up.last_model(sys.argv[3])))" "$TMP/missing.jsonl" 2>&1)
[ "$got" = "''" ] && ok "last_model returns empty for a missing transcript" \
  || bad "last_model returns empty for a missing transcript" "got=$(flat "$got")"

# ------------------------------------------------------- 3. the usage line is runnable
out=$("$PY" "$SUT" --record < /dev/null 2>&1); rc=$?
case "$out" in
  *"<"*) bad "usage line contains no shell-hostile placeholder" "$(flat "$out")" ;;
  *)     [ "$rc" -ne 0 ] && ok "usage line contains no shell-hostile placeholder" \
             || bad "usage line contains no shell-hostile placeholder" "rc=$rc" ;;
esac

# ------------------------------------------------------------ 4. reading round-trip
R=$TMP/readings.md
mk() {   # pct_all pct_fable $all $fable tok_all tok_fable ieq_all ieq_fable
  cat > "$R" <<'HDR'
| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok | all_ieq | fable_ieq | note |
|---|---|---|---|---|---|---|---|---|---|---|
HDR
  while [ $# -ge 8 ]; do
    printf '| 2026-09-09 | 2026-09-04T10:00-07:00 | %s%% | %s%% | %s | %s | %s | %s | %s | %s | t |\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$R"
    shift 8
  done
}

mk 38 24 1180.00 340.00 1400000000 400000000 180000000 40000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); r=up.read_readings(); print(len(r), r[0]['all_pct'], r[0]['all_at'], r[0]['all_raw'])" "$R" 2>&1)
[ "$got" = "1 38.0 1180.0 1400000000.0" ] \
  && ok "read_readings parses a full row by header name" \
  || bad "read_readings parses a full row by header name" "got=$(flat "$got")"

# A row from the pre-token schema must still parse, with the missing columns None
# rather than zero — "not measured" and "measured as nothing" are different claims.
cat > "$R" <<'HDR'
| week-close | read at | all% | fable% | all$ | fable$ | note |
|---|---|---|---|---|---|---|
| 2026-09-09 | 2026-09-04T10:00-07:00 | 38% | 24% | 1180.00 | 340.00 | old schema |
HDR
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); r=up.read_readings(); print(len(r), r[0]['all_at'], r[0]['all_raw'])" "$R" 2>&1)
[ "$got" = "1 1180.0 None" ] \
  && ok "read_readings tolerates the pre-token schema (missing cols are None)" \
  || bad "read_readings tolerates the pre-token schema (missing cols are None)" "got=$(flat "$got")"

# --------------------------------------------------------- 5. low-signal exclusion
mk 3 2 90.00 12.00 100000000 20000000 12000000 3000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); print(up.implied_caps(up.read_readings())['all'])" "$R" 2>&1)
[ "$got" = "[]" ] \
  && ok "a reading under MIN_PCT implies no cap (rounding would dominate)" \
  || bad "a reading under MIN_PCT implies no cap (rounding would dominate)" "got=$(flat "$got")"

got=$("$PY" - "$SUT" "$R" <<'PYEOF' 2>&1
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
up.READINGS=pathlib.Path(sys.argv[2]); sys.argv=["x","--caps"]; up.main()
PYEOF
); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$got" | grep -q 'n/a' \
  && ok "--caps renders a low-signal row as n/a instead of crashing" \
  || bad "--caps renders a low-signal row as n/a instead of crashing" "rc=$rc $(flat "$got")"

# ------------------------------------------------------ 6. --units reports ties as ties
# Dollars and input-eq move together (both double with the percentage) while raw
# tokens stay fixed. So dollars and input-eq BOTH imply a perfectly stable cap and
# raw does not — a genuine tie. Naming one winner here is the min() bug: those two
# units differ ONLY by the per-model price multiplier and cannot be separated by
# readings that do not vary the model mix.
mk 20 20 900.00 900.00 1400000000 1400000000 180000000 180000000 \
   40 40 1800.00 1800.00 1400000000 1400000000 360000000 360000000
got=$("$PY" - "$SUT" "$R" <<'PYEOF' 2>&1
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
up.READINGS=pathlib.Path(sys.argv[2]); up.units_report(up.read_readings())
PYEOF
)
printf '%s' "$got" | grep -q 'DEGENERATE' \
  && ok "--units reports a tie as DEGENERATE rather than guessing" \
  || bad "--units reports a tie as DEGENERATE rather than guessing" "$(flat "$got")"

# Vary the dollars only: raw and input-eq stay put, so dollars must NOT be named.
printf '%s' "$got" | grep -q 'meter counts \$?' \
  && ok "--units still shows every candidate unit for inspection" \
  || bad "--units still shows every candidate unit for inspection" "$(flat "$got")"

# One reading cannot discriminate anything, and must say so.
mk 38 24 1180.00 340.00 1400000000 400000000 180000000 40000000
got=$("$PY" - "$SUT" "$R" <<'PYEOF' 2>&1
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
up.READINGS=pathlib.Path(sys.argv[2]); up.units_report(up.read_readings())
PYEOF
)
printf '%s' "$got" | grep -qi 'at least 2' \
  && ok "--units refuses to conclude from a single reading" \
  || bad "--units refuses to conclude from a single reading" "$(flat "$got")"

# ------------------------------------------------------------- 7. token measures
got=$(pymod "print(up.token_measures({'input_tokens':100,'output_tokens':10,'cache_read_input_tokens':1000,'cache_creation_input_tokens':200}))" 2>&1)
# raw = 100+10+1000+200 = 1310 ; ieq = 100 + 1000*0.1 + 200*1.25 + 10*5 = 500
[ "$got" = "(1310, 500.0)" ] \
  && ok "token_measures weights cache reads at 0.1 and output at 5 for input-eq" \
  || bad "token_measures weights cache reads at 0.1 and output at 5 for input-eq" "got=$(flat "$got")"

got=$(pymod "print(up.token_measures({'input_tokens':0,'output_tokens':0,'cache_read_input_tokens':0,'cache_creation':{'ephemeral_1h_input_tokens':100}}))" 2>&1)
[ "$got" = "(100, 200.0)" ] \
  && ok "token_measures prices a 1h cache write at 2.0x" \
  || bad "token_measures prices a 1h cache write at 2.0x" "got=$(flat "$got")"

# --------------------------------------------- 8. week boundary is Wed 15:59 PT
got=$(pymod "
from datetime import datetime
from zoneinfo import ZoneInfo
PT=ZoneInfo('America/Los_Angeles')
print(up.week_close(datetime(2026,9,2,15,58,tzinfo=PT)), up.week_close(datetime(2026,9,2,16,0,tzinfo=PT)))" 2>&1)
[ "$got" = "2026-09-02 2026-09-09" ] \
  && ok "week_close puts 15:58 PT Wed in the closing week and 16:00 in the next" \
  || bad "week_close puts 15:58 PT Wed in the closing week and 16:00 in the next" "got=$(flat "$got")"

# ------------------------------------- 9. pricing agrees with usage-trend.py if present
# usage-trend.py is not in this registry; on a machine that has both, the two
# pricing tables MUST agree or the pace check and the benchmark disagree about
# what a week cost. Checked where it can be, skipped where it cannot.
TREND="$HOME/.claude/scripts/usage-trend.py"
if [ -f "$TREND" ]; then
  got=$("$PY" - "$SUT" "$TREND" <<'PYEOF' 2>&1
import importlib.util, sys
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s)
    s.loader.exec_module(m); return m
a=load("pace",sys.argv[1]); b=load("trend",sys.argv[2])
print("PRICING" if a.PRICING==b.PRICING else f"DRIFT {a.PRICING} != {b.PRICING}")
u={"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":50000,
   "cache_creation_input_tokens":2000}
for m in ("claude-opus-5","claude-fable-5","claude-sonnet-5","claude-haiku-4-5-20251001"):
    if abs(a.cost_usd(u,m)-b.cost_usd(u,m)) > 1e-12: print("COSTDRIFT",m); break
else: print("COST")
PYEOF
)
  [ "$got" = "PRICING
COST" ] && ok "pricing and cost_usd agree with usage-trend.py on this machine" \
    || bad "pricing and cost_usd agree with usage-trend.py on this machine" "$(flat "$got")"
else
  skipt "pricing agrees with usage-trend.py" "usage-trend.py not present (not in this registry)"
fi

# ------------------------------------- 10. REGRESSIONS (mutation-proven gaps)
# Each case below exists because a mutation that broke real behaviour left the suite
# fully green. They are the difference between a suite and a safety net.

# (a) --caps must format a REAL cap, not only the n/a branch. The previous fixture was
#     entirely sub-MIN_PCT, so the single line that formats a cap never ran -- and the
#     invalid format string named in this file's own header reintroduces with 20/20 green.
mk 38 24 1180.00 340.00 1400000000 400000000 180000000 40000000
got=$("$PY" - "$SUT" "$R" <<'CAPPY' 2>&1
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
up.READINGS=pathlib.Path(sys.argv[2]); sys.argv=["x","--caps"]; sys.exit(up.main() or 0)
CAPPY
); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$got" | grep -q '3,105' \
  && ok "--caps formats a real cap (1180/0.38), not just the n/a branch" \
  || bad "--caps formats a real cap (1180/0.38), not just the n/a branch" "rc=$rc $(flat "$got")"

# (b) The hook's speaking path had NO test at all: `due = False` (never fire, ever) left
#     the suite green. Drive it end to end against a fixture HOME whose live meter and
#     burn make a warning TRUE -- `--margin -1` used to force one, and no longer can:
#     speaking is a function of the wall's arrival time, not of elapsed time.
HOOKHOME=$TMP/hookhome
mkdir -p "$HOOKHOME/.claude/projects"
cat > "$TMP/fable.jsonl" <<'FABLEJ'
{"type":"assistant","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5","usage":{"output_tokens":1}}}
FABLEJ
# sd 95 with every request inside the last hour: the wall is minutes away and the reset
# is hours away, so warning (a) is true for any clock more than ~6 minutes from a reset.
fx=$(mkfix "$HOOKHOME" '{"sd":95,"fh":12,"age_min":3,"reqs":[[10,20000000,"claude-fable-5"],[2,1000,"claude-fable-5"]]}')
hookrun() { printf '{"session_id":"s1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$HOOKHOME" "$PY" "$SUT" --hook --every 1 2>&1; }
if [ "$(fixf "$fx" usable)" = "True" ] && [ "$(fixf "$fx" warn_a)" = "True" ]; then
  out=$(hookrun); rc=$?
  printf '%s' "$out" | grep -q 'usage-pace' \
    && ok "hook actually SPEAKS when due and a warning is true" \
    || bad "hook actually SPEAKS when due and a warning is true" "rc=$rc out=$(flat "$out")"
  printf '%s' "$out" | grep -q 'NEAR CAP' \
    && bad "the hook never prints NEAR CAP" "$(flat "$out")" \
    || ok "the hook block never prints NEAR CAP"
  printf '%s' "$out" | grep -qi 'ahead of' \
    && bad "the hook says nothing about being ahead of pace" "$(flat "$out")" \
    || ok "the hook block says nothing about being ahead of pace"
else
  skipt "hook speaks when a warning is true" "within minutes of a meter reset ($fx)"
  out=$(hookrun)
fi

# (c) ...and the state it wrote must persist, which requires creating ~/.claude/usage-history.
#     That dir is absent on a fresh machine and the write swallowed the OSError, so the
#     turn counter never persisted and the check was permanently silent.
[ -f "$HOOKHOME/.claude/usage-history/pace-state.json" ] \
  && ok "hook creates its own state dir on a fresh machine" \
  || bad "hook creates its own state dir on a fresh machine" "no pace-state.json written"

# (d) Malformed-but-valid JSON state must not crash the hook. This path runs BEFORE the
#     --every gate, so the uncaught AttributeError hit every prompt and no write path
#     was reached to heal it.
for shape in '[1,2,3]' 'null' '"a string"' '42'; do
  printf '%s' "$shape" > "$HOOKHOME/.claude/usage-history/pace-state.json"
  out=$(hookrun); rc=$?
  [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'Traceback' \
    && ok "hook survives a state file of shape $shape" \
    || bad "hook survives a state file of shape $shape" "rc=$rc $(flat "$out")"
done
printf '%s' '[1,2,3]' > "$HOOKHOME/.claude/usage-history/pace-cache.json"
out=$(hookrun); rc=$?
[ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'Traceback' \
  && ok "hook survives a malformed pace-cache.json" \
  || bad "hook survives a malformed pace-cache.json" "rc=$rc $(flat "$out")"

# (e) week_close on the EXACT boundary second: neither old fixture (15:58 / 16:00) could
#     tell `cand <= loc` from `cand < loc`.
got=$(pymod "
from datetime import datetime
from zoneinfo import ZoneInfo
PT=ZoneInfo('America/Los_Angeles')
print(up.week_close(datetime(2026,9,2,15,59,0,tzinfo=PT)))" 2>&1)
[ "$got" = "2026-09-09" ] \
  && ok "week_close at exactly 15:59:00 PT Wed belongs to the NEXT week" \
  || bad "week_close at exactly 15:59:00 PT Wed belongs to the NEXT week" "got=$(flat "$got")"

# (f) mythos is priced at the Fable rate, so it must tier as fable -- otherwise a
#     Fable-priced model is invisible to a Fable pace check.
got=$(pymod "print(up.tier('claude-mythos-1'), up.rates('claude-mythos-1')[0])" 2>&1)
[ "$got" = "fable 10.0" ] \
  && ok "mythos tiers as fable, matching the Fable rate it is priced at" \
  || bad "mythos tiers as fable, matching the Fable rate it is priced at" "got=$(flat "$got")"

# (g) The incremental cache must never keep a contribution from bytes that are gone.
#     Re-reading a shrunk file from zero ADDED to the stale total and inflated the week
#     permanently -- and record() scans without force, so that number could be written
#     into meter-readings.md and treated as ground truth.
got=$("$PY" - "$SUT" "$TMP" <<'SHRINKPY' 2>&1
import importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"proj"; root.mkdir(exist_ok=True)
up.ROOT=root; up.CACHE=tmp/"c.json"; up.STATE=tmp/"s.json"; up.HIST=tmp
from datetime import datetime
WK=up.week_close(datetime.fromisoformat("2026-09-04T00:00:00+00:00"))
def rec(i):
    return json.dumps({"type":"assistant","timestamp":"2026-09-04T00:00:00Z",
        "message":{"id":"m%d"%i,"model":"claude-opus-5","usage":{"output_tokens":1000}}},
        separators=(",",":"))
f=root/"t.jsonl"
f.write_text(rec(1)+"\n"+rec(2)+"\n"); a=up.scan(WK)["all"]
f.write_text(rec(1)+"\n"+rec(2)+"\n"+rec(3)+"\n"); b=up.scan(WK)["all"]
f.write_text(rec(9)+"\n"); c=up.scan(WK)["all"]
d=up.scan(WK, force=True)["all"]
print("%.4f %.4f %.4f %.4f"%(a,b,c,d), "MATCH" if abs(c-d)<1e-9 else "STALE")
SHRINKPY
)
printf '%s' "$got" | grep -q 'MATCH' \
  && ok "a shrunk transcript leaves no stale spend in the cached total" \
  || bad "a shrunk transcript leaves no stale spend in the cached total" "$(flat "$got")"


# ------------------------------- 11. COVERAGE FOR FIXES THE SUITE DID NOT PIN
# A refute pass showed the suite caught only 3 of the 7 fixes when each was reverted
# in ISOLATION. The four below had no coverage at all, so a future refactor could
# reintroduce any of them with CI fully green. Each case here fails if its fix is
# reverted alone.

# (h) The two HIST.mkdir calls must be pinned SEPARATELY. Removing either one alone
#     left 31/31 green, because whichever survives creates the directory first and
#     masks the other. --oneline writes the cache and never the state file, so it
#     isolates _save_cache's copy.
CACHEHOME=$TMP/cachehome
mkdir -p "$CACHEHOME/.claude/projects"
HOME="$CACHEHOME" "$PY" "$SUT" --oneline >/dev/null 2>&1
[ -f "$CACHEHOME/.claude/usage-history/pace-cache.json" ] \
  && ok "_save_cache creates HIST on a fresh machine (isolates it from _write_state)" \
  || bad "_save_cache creates HIST on a fresh machine" "no pace-cache.json under $CACHEHOME"

# (i) warned -> quiet -> warned must speak the second time. Reverting s.pop("acked") left
#     31/31 green because no scenario ever returned to quiet between two alerts. The
#     verdict is flipped by rewriting the fixture's WORLD, not by a margin flag: the
#     warning fixture puts all spend in the last hour (wall minutes away), the quiet one
#     puts $100 of it 71-100 minutes ago and 5c in the last hour, so the same 5 points
#     of headroom are 100+ hours away at the current burn.
ACKHOME=$TMP/ackhome
mkdir -p "$ACKHOME/.claude/projects"
ackrun() { printf '{"session_id":"s1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$ACKHOME" "$PY" "$SUT" --hook --every 1 2>&1; }
spoke() { printf '%s' "$1" | grep -q 'usage-pace' && echo yes || echo no; }
loud='{"sd":95,"fh":12,"age_min":3,"reqs":[[10,20000000,"claude-fable-5"],[2,1000,"claude-fable-5"]]}'
quiet='{"sd":95,"fh":12,"age_min":3,"reqs":[[95,20000000,"claude-fable-5"],[2,1000,"claude-fable-5"]]}'
f1=$(mkfix "$ACKHOME" "$loud"); a1=$(ackrun)
f2=$(mkfix "$ACKHOME" "$quiet"); a2=$(ackrun)
f3=$(mkfix "$ACKHOME" "$loud"); a3=$(ackrun)
if [ "$(fixf "$f2" usable)" = "True" ] \
   && [ "$(fixf "$f1" warn_a)$(fixf "$f1" warn_b)" = "TrueFalse" ] \
   && [ "$(fixf "$f2" warn_a)$(fixf "$f2" warn_b)" = "FalseFalse" ]; then
  [ "$(spoke "$a1")" = yes ] && [ "$(spoke "$a2")" = no ] && [ "$(spoke "$a3")" = yes ] \
    && ok "warned -> quiet -> warned speaks again (the acknowledgment is cleared)" \
    || bad "warned -> quiet -> warned speaks again" "spoke: $(spoke "$a1")/$(spoke "$a2")/$(spoke "$a3")"
else
  skipt "warned -> quiet -> warned speaks again" "the clock cannot build both worlds now"
fi

# (i2) ...and the OTHER half of the same mechanism: the SAME verdict twice must speak
#      once. Deleting the `acked == v` suppression outright left the suite green, because
#      the sequence above never repeats a verdict without a quiet turn between -- so the
#      clearing was pinned and the nagging was not. Without this, a session gets the same
#      <usage-pace> block injected every --every turns for the rest of the week.
NAGHOME=$TMP/naghome
mkdir -p "$NAGHOME/.claude/projects"
nagrun() { printf '{"session_id":"n1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$NAGHOME" "$PY" "$SUT" --hook --every 1 2>&1; }
f1=$(mkfix "$NAGHOME" "$loud"); n1=$(nagrun)
f2=$(mkfix "$NAGHOME" "$loud"); n2=$(nagrun)
if [ "$(fixf "$f1" warn_a)" = "True" ] && [ "$(fixf "$f2" warn_a)" = "True" ]; then
  [ "$(spoke "$n1")" = yes ] && [ "$(spoke "$n2")" = no ] \
    && ok "the same verdict twice speaks once (the acknowledgment suppresses the nag)" \
    || bad "the same verdict twice speaks once" "spoke: $(spoke "$n1")/$(spoke "$n2")"
else
  skipt "the same verdict twice speaks once" "the clock cannot build the warning world now"
fi

# (j) A record still being appended must be counted EXACTLY once — not zero times
#     (offset advanced past it) and not twice (re-read after being counted).
got=$("$PY" - "$SUT" "$TMP" <<'TORNPY' 2>&1
import importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"torn"; root.mkdir(exist_ok=True)
up.ROOT=root; up.CACHE=tmp/"tc.json"; up.STATE=tmp/"ts.json"; up.HIST=tmp
from datetime import datetime
WK=up.week_close(datetime.fromisoformat("2026-09-04T00:00:00+00:00"))
def rec(i):
    return json.dumps({"type":"assistant","timestamp":"2026-09-04T00:00:00Z",
        "message":{"id":"m%d"%i,"model":"claude-opus-5","usage":{"output_tokens":1000}}},
        separators=(",",":"))
f=root/"t.jsonl"
full=rec(1)+"\n"+rec(2)+"\n"
f.write_text(full[:len(full)-12])            # last record TORN mid-line
a=up.scan(WK).get("all",0.0)
f.write_text(full)                            # the rest lands
b=up.scan(WK).get("all",0.0)
c=up.scan(WK, force=True).get("all",0.0)      # ground truth: exactly 2 records
print("%.4f %.4f %.4f"%(a,b,c), "ONCE" if abs(b-c)<1e-9 else "WRONG")
TORNPY
)
printf '%s' "$got" | grep -q 'ONCE' \
  && ok "a torn trailing record is counted exactly once, once completed" \
  || bad "a torn trailing record is counted exactly once, once completed" "$(flat "$got")"

# (k) The DST week is 7 days AND an hour. Subtracting two datetimes that share one
#     tzinfo diffs their naive fields and silently loses that hour; no assertion
#     anywhere in this file covered it.
got=$(pymod "
o,c = up.week_bounds('2026-11-04')     # contains the Nov 1 2026 fall-back
n,d = up.week_bounds('2026-09-09')     # an ordinary week
u = lambda x: x.astimezone(up.timezone.utc)
print(int((u(c)-u(o)).total_seconds()), int((u(d)-u(n)).total_seconds()))" 2>&1)
[ "$got" = "608400 604800" ] \
  && ok "week span is DST-correct (608400s across the fall-back, 604800s otherwise)" \
  || bad "week span is DST-correct" "got=$(flat "$got")"


# (l) _write_state's mkdir must be pinned independently of _save_cache's. In the
#     speaking path _save_cache runs first and creates HIST, masking a revert here.
#     With --every huge the hook is never due: it writes state and never scans.
STHOME=$TMP/sthome
mkdir -p "$STHOME/.claude/projects"
printf '{"session_id":"s1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$STHOME" "$PY" "$SUT" --hook --every 999999 >/dev/null 2>&1
[ -f "$STHOME/.claude/usage-history/pace-state.json" ] \
  && ok "_write_state creates HIST when not due (isolates it from _save_cache)" \
  || bad "_write_state creates HIST when not due" "no pace-state.json under $STHOME"
[ ! -f "$STHOME/.claude/usage-history/pace-cache.json" ] \
  && ok "the not-due path writes state without scanning (the isolation holds)" \
  || bad "the not-due path writes state without scanning" "pace-cache.json exists — path not isolated"

# (m) A cache that IS a dict but whose `files` is the wrong type must be rejected.
#     A top-level list is caught by the exception tuple; this shape is not, and
#     reaches files.get() inside scan().
got=$("$PY" - "$SUT" "$TMP" <<'BADFILES' 2>&1
import importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"bf"; root.mkdir(exist_ok=True)
up.ROOT=root; up.CACHE=tmp/"bf.json"; up.STATE=tmp/"bs.json"; up.HIST=tmp
from datetime import datetime
WK=up.week_close(datetime.fromisoformat("2026-09-04T00:00:00+00:00"))
up.CACHE.write_text(json.dumps({"week":WK,"files":[1,2,3],"totals":"nope","seen":{}}))
try:
    up.scan(WK); print("OK")
except Exception as e:
    print("CRASH", type(e).__name__, e)
BADFILES
)
[ "$got" = "OK" ] \
  && ok "a cache dict with a malformed files/totals is rejected, not trusted" \
  || bad "a cache dict with a malformed files/totals is rejected, not trusted" "$(flat "$got")"

# (n) pace()'s own clock arithmetic must be DST-correct. The earlier DST case asserted on
#     week_bounds and computed the UTC diff itself, so reverting pace()'s arithmetic left
#     it green. `now` is placed BEFORE the transition (still PDT) while the week closes
#     after it (PST), so the naive and UTC answers differ. Expectations are derived here
#     from UTC arithmetic, independently of the SUT.
#     `days_left` is gone -- `hours_to_reset` is the field the readout and both warnings
#     are built on, so it is the one that has to be right -- and PLAN_SAMPLES is pointed at
#     nothing so this runs the derived path on every machine, not just a headless one.
got=$(pymod "
from datetime import datetime, timedelta, timezone
up.scan_detail = lambda *a, **k: ({}, {})
up.read_readings = lambda: []
up.PLAN_SAMPLES = pathlib.Path('/nonexistent/plan.json')
now = datetime(2026,10,30,12,0,tzinfo=up.PT)      # PDT; the week closes in PST
p = up.pace(now=now)
o, c = up.week_bounds('2026-11-04')
u = lambda d: d.astimezone(timezone.utc)
want_e = (u(now)-u(o)).total_seconds() / (u(c)-u(o)).total_seconds()
want_h = (u(c)-u(now)).total_seconds() / 3600
naive_e = (now.replace(tzinfo=None)-o.replace(tzinfo=None)).total_seconds() / 604800.0
naive_h = (c.replace(tzinfo=None)-now.replace(tzinfo=None)).total_seconds() / 3600
ok_e = abs(p['elapsed']-want_e) < 1e-9
ok_h = abs(p['hours_to_reset']-want_h) < 1e-9
print('OK' if ok_e and ok_h else 'BAD %r %r' % (p['elapsed'], p['hours_to_reset']),
      'discriminating' if abs(want_e-naive_e) > 1e-4 and abs(want_h-naive_h) > 1e-4
      else 'DEGENERATE')" 2>&1)
[ "$got" = "OK discriminating" ] \
  && ok "pace() elapsed and hours_to_reset are DST-correct across the fall-back" \
  || bad "pace() elapsed and hours_to_reset are DST-correct across the fall-back" "got=$(flat "$got")"


# ------------------------------------------- 12. DIFFERENTIAL CAP CALIBRATION
# Anthropic reset the quota out of band on 2026-09-04, moving the meter's zero to an
# unknown instant. The absolute method divides week-to-date spend by the percentage and
# so counts spend the meter no longer counts. A difference between two readings cancels
# the origin and is immune to it. These cases pin that.

# (a) The headline property: the SAME pair of readings yields the SAME cap no matter
#     where the zero sits, because the origin cancels. Two rows 40 points apart,
#     $1200 apart -> cap $3000, and shifting both spends by a constant (which is what
#     a moved zero does) must not change the answer.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   60 60 1800.00 1800.00 3000000000 3000000000 300000000 300000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,_=up.differential_caps(up.read_readings()); print('%.0f'%d['all'][0])" "$R" 2>&1)
[ "$got" = "3000" ] \
  && ok "differential cap = delta-spend / delta-pct (1200/0.40 = 3000)" \
  || bad "differential cap = delta-spend / delta-pct" "got=$(flat "$got")"

mk 20 20 5600.00 5600.00 1000000000 1000000000 100000000 100000000 \
   60 60 6800.00 6800.00 3000000000 3000000000 300000000 300000000
shifted=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,_=up.differential_caps(up.read_readings()); print('%.0f'%d['all'][0])" "$R" 2>&1)
[ "$shifted" = "3000" ] \
  && ok "the same cap survives a shifted origin (a reset moves the zero, not the slope)" \
  || bad "the same cap survives a shifted origin" "got=$(flat "$shifted")"

# (b) A percentage that went DOWN means the meter reset BETWEEN the two readings, so the
#     pair straddles two different zeros. Differencing it would produce a negative or
#     meaningless cap; it must be dropped with a note naming the reset.
mk 70 70 2100.00 2100.00 3000000000 3000000000 300000000 300000000 \
   5  5  2400.00 2400.00 3400000000 3400000000 340000000 340000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,n=up.differential_caps(up.read_readings()); print(len(d['all']), 'RESET' if any('went DOWN' in x for x in n) else 'NONOTE')" "$R" 2>&1)
[ "$got" = "0 RESET" ] \
  && ok "a pair straddling a mid-week reset is dropped and the reset is named" \
  || bad "a pair straddling a mid-week reset is dropped and the reset is named" "got=$(flat "$got")"

# (c) A small delta is dropped: both percentages are eyeballed integers, so at 5 points a
#     +/-1 point rounding is a 20% error in the cap.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   25 25 750.00 750.00 1200000000 1200000000 120000000 120000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,n=up.differential_caps(up.read_readings()); print(len(d['all']), 'FLOOR' if any('floor' in x for x in n) else 'NONOTE')" "$R" 2>&1)
[ "$got" = "0 FLOOR" ] \
  && ok "a sub-10-point delta is dropped as rounding-dominated" \
  || bad "a sub-10-point delta is dropped as rounding-dominated" "got=$(flat "$got")"

# (d) Readings in DIFFERENT meter weeks are never differenced: week-to-date spend resets
#     at the boundary, so the subtraction would be against two different origins.
cat > "$R" <<'HDR'
| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok | all_ieq | fable_ieq | note |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-09 | 2026-09-04T10:00-07:00 | 20% | 20% | 600.00 | 600.00 | 1 | 1 | 1 | 1 | a |
| 2026-09-16 | 2026-09-11T10:00-07:00 | 60% | 60% | 1800.00 | 1800.00 | 1 | 1 | 1 | 1 | b |
HDR
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,_=up.differential_caps(up.read_readings()); print(len(d['all']))" "$R" 2>&1)
[ "$got" = "0" ] \
  && ok "readings in different meter weeks are never differenced" \
  || bad "readings in different meter weeks are never differenced" "got=$(flat "$got")"

# (e) resolve_cap must PREFER the differential over the absolute. With both available and
#     deliberately disagreeing, the differential wins and the basis string says so.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   60 60 1800.00 1800.00 3000000000 3000000000 300000000 300000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); up.CALIB=pathlib.Path(sys.argv[3]+'.nope'); c,b,_=up.resolve_cap('all', up.read_readings()); print('%.0f'%c, 'DIFF' if 'differential' in b else b)" "$R" 2>&1)
[ "$got" = "3000 DIFF" ] \
  && ok "resolve_cap prefers the differential (3000) over the absolute (3000/3000)" \
  || bad "resolve_cap prefers the differential" "got=$(flat "$got")"

# (f) With only one reading there is nothing to difference, and the absolute fallback must
#     announce its own assumption rather than presenting itself as calibrated truth.
mk 38 24 1180.00 340.00 1400000000 400000000 180000000 40000000
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); up.CALIB=pathlib.Path(sys.argv[3]+'.nope'); c,b,_=up.resolve_cap('all', up.read_readings()); print('ABS' if 'ABSOLUTE' in b else b)" "$R" 2>&1)
[ "$got" = "ABS" ] \
  && ok "a lone reading falls back to ABSOLUTE and labels the assumption" \
  || bad "a lone reading falls back to ABSOLUTE and labels the assumption" "got=$(flat "$got")"


# (g) The sampled calibration outranks both. It is a regression over the desktop app's
#     own 15-minute meter samples, so it beats a hand-recorded pair on both sample size
#     and freshness. Pinned with a stub file so the test never reads machine state.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   60 60 1800.00 1800.00 3000000000 3000000000 300000000 300000000
printf '{"all": 4321.0, "periods": 5, "r2": 0.99}' > "$TMP/calib.json"
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); up.CALIB=pathlib.Path(sys.argv[4]); c,b,_=up.resolve_cap('all', up.read_readings()); print('%.0f'%c, 'SAMPLED' if 'regression' in b else b)" "$R" "$TMP/calib.json" 2>&1)
[ "$got" = "4321 SAMPLED" ] \
  && ok "the sampled calibration outranks the differential and the absolute" \
  || bad "the sampled calibration outranks the differential and the absolute" "got=$(flat "$got")"

# (h) A malformed or zero calibration must be ignored, not trusted -- it feeds the cap
#     the pace check divides by.
for bad_c in '{"all": 0}' '{"all": "x"}' '[1,2,3]' 'not json' '{}'; do
  printf '%s' "$bad_c" > "$TMP/calib.json"
  got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); up.CALIB=pathlib.Path(sys.argv[4]); c,b,_=up.resolve_cap('all', up.read_readings()); print('SAMPLED' if 'regression' in b else 'FELLBACK')" "$R" "$TMP/calib.json" 2>&1)
  [ "$got" = "FELLBACK" ] \
    && ok "a bad calibration file is ignored: $bad_c" \
    || bad "a bad calibration file is ignored: $bad_c" "got=$(flat "$got")"
done

# --------------------------------- 13. THE SAMPLED-CALIBRATION MATH ITSELF
# A reviewer found this math had NO direct coverage: only its downstream consumption
# via a pre-built cache file was tested, so a regression in _fit, _segments or
# sampled_caps would have shipped with the suite fully green.

# (a) _fit recovers a known slope and R2 exactly, and guards degenerate input.
got=$(pymod "
b,r = up._fit([0,1,2,3],[10,20,30,40])          # slope 10, perfect fit
b2,r2 = up._fit([5,5,5],[1,2,3])                # zero variance in x
b3,r3 = up._fit([],[])                          # empty
print('%.6f %.6f %s %s' % (b, r, b2 is None, b3 is None))" 2>&1)
[ "$got" = "10.000000 1.000000 True True" ] \
  && ok "_fit recovers a known slope/R2 and returns None on degenerate input" \
  || bad "_fit recovers a known slope/R2 and returns None on degenerate input" "got=$(flat "$got")"

# (b) The property the whole method rests on: adding a constant to every y (which is
#     exactly what a moved zero point does) must not move the slope.
got=$(pymod "
xs=[0,10,20,30,40]; ys=[100,300,500,700,900]
a,_ = up._fit(xs, ys)
b,_ = up._fit(xs, [y+99999 for y in ys])
print('SAME' if abs(a-b) < 1e-9 else 'MOVED %f %f' % (a,b))" 2>&1)
[ "$got" = "SAME" ] \
  && ok "the fitted slope is invariant to a shifted origin (the reset-proof property)" \
  || bad "the fitted slope is invariant to a shifted origin" "got=$(flat "$got")"

# (c) _segments splits on a big drop, on ANY fall to zero, and not on noise.
got=$(pymod "
seg = lambda v: [[y for _,y in s] for s in up._segments([(float(i),float(x)) for i,x in enumerate(v)])]
print(seg([10,50,90,0,20]), seg([1,2,0,3]), seg([10,9,11,40]))" 2>&1)
exp="[[10.0, 50.0, 90.0], [0.0, 20.0]] [[1.0, 2.0], [0.0, 3.0]] [[10.0, 9.0, 11.0, 40.0]]"
[ "$got" = "$exp" ] \
  && ok "_segments splits on a reset and on a fall to zero, but not on 1-point noise" \
  || bad "_segments splits on a reset and on a fall to zero, but not on 1-point noise" "got=$(flat "$got")"

# (d) plan_samples tolerates every malformed shape the desktop app could present.
PS=$TMP/plan.json
psrun() { printf '%s' "$1" > "$PS"; pymod "up.PLAN_SAMPLES=pathlib.Path(sys.argv[3]); print(len(up.plan_samples()))" "$PS" 2>&1; }
allok=yes
for shape in '{}' '[]' 'not json' '{"samples": {}}' '{"samples": [1,2,3]}' \
             '{"samples": [{"t": 1, "u": {"sd": "x"}}]}' '{"samples": [{"u": {"sd": 5}}]}' \
             '{"samples": [{"t": 1}]}' '{"samples": [{"t": 1, "u": null}]}'; do
  [ "$(psrun "$shape")" = "0" ] || { allok="no ($shape -> $(psrun "$shape"))"; break; }
done
[ "$allok" = yes ] \
  && ok "plan_samples returns nothing for every malformed shape, never raises" \
  || bad "plan_samples returns nothing for every malformed shape" "$allok"

got=$(psrun '{"samples": [{"t": 300, "u": {"sd": 9, "fh": 1}}, {"t": 100, "u": {"sd": 3}}]}')
[ "$got" = "2" ] && ok "plan_samples keeps well-formed entries" \
  || bad "plan_samples keeps well-formed entries" "got=$(flat "$got")"

got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3])
print([int(t) for t,_ in up.plan_samples()])" "$PS" 2>&1)
[ "$got" = "[100, 300]" ] \
  && ok "plan_samples sorts by the numeric epoch (not by insertion order)" \
  || bad "plan_samples sorts by the numeric epoch" "got=$(flat "$got")"

# (e) sampled_caps end to end against a synthetic meter + synthetic transcripts: a known
#     cap must come back out. Two periods at $20/point -> cap $2000.
got=$("$PY" - "$SUT" "$TMP" <<'CAPPY' 2>&1
import importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"sc"; 
import shutil; shutil.rmtree(root, ignore_errors=True); root.mkdir()
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"sc_c.json"
# one $2.00 request every 60s from t0; meter climbs 1 point per 10 requests => $20/point
t0=1788000000000
recs=[]
for i in range(400):
    recs.append(json.dumps({"type":"assistant","timestamp":
        up.datetime.fromtimestamp((t0+i*60000)/1000, up.timezone.utc).isoformat().replace("+00:00","Z"),
        "message":{"id":"m%d"%i,"model":"claude-opus-5",
                   "usage":{"output_tokens":80000}}}, separators=(",",":")))
(root/"t.jsonl").write_text("\n".join(recs)+"\n")
per_req = up.cost_usd({"output_tokens":80000}, "claude-opus-5")
samples=[{"t": t0+i*10*60000, "u": {"sd": i}} for i in range(40)]
up.PLAN_SAMPLES=tmp/"plan.json"; up.PLAN_SAMPLES.write_text(json.dumps({"version":2,"samples":samples}))
out=up.sampled_caps()
exp = per_req*10*100      # $/point x 100
print("%d %.2f %.2f" % (len(out), out[0][1], exp), "MATCH" if abs(out[0][1]-exp) < exp*0.02 else "OFF")
CAPPY
)
printf '%s' "$got" | grep -q 'MATCH' \
  && ok "sampled_caps recovers a known cap from a synthetic meter + transcripts" \
  || bad "sampled_caps recovers a known cap from a synthetic meter + transcripts" "$(flat "$got")"

# (f) Readings must sort chronologically, not lexicographically: ISO offsets change at a
#     DST transition, so the raw string order flips the pair and fakes a reset.
got=$(pymod "
A={'at':'2026-11-01T01:45-07:00'}   # PDT, 08:45 UTC, EARLIER
B={'at':'2026-11-01T01:30-08:00'}   # PST, 09:30 UTC, LATER
print([r['at'][-6:] for r in sorted([B,A], key=up._reading_instant)],
      up._reading_instant({'at':'garbage'}) > up._reading_instant(A))" 2>&1)
[ "$got" = "['-07:00', '-08:00'] True" ] \
  && ok "readings sort by instant, not ISO text (DST offsets flip the string order)" \
  || bad "readings sort by instant, not ISO text" "got=$(flat "$got")"

# (g) The cap the pace check divides by must be finite and must not be a bool.
#     json.loads accepts Infinity/NaN, and bool is an int subclass.
allok=yes
for shape in '{"all": Infinity}' '{"all": -Infinity}' '{"all": NaN}' '{"all": true}'; do
  printf '%s' "$shape" > "$TMP/calib.json"
  r=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); print('ACCEPTED' if up.cached_calibration() else 'rejected')" "$TMP/calib.json" 2>&1)
  [ "$r" = "rejected" ] || { allok="no ($shape -> $r)"; break; }
done
[ "$allok" = yes ] \
  && ok "Infinity/NaN/true are rejected as a cached cap" \
  || bad "Infinity/NaN/true are rejected as a cached cap" "$allok"


# (h) ...and differential_caps must actually USE that key. Reverting the call site to a
#     string sort left the direct _reading_instant test green, so this drives the real
#     path: two readings in one week whose ISO text order is the REVERSE of their true
#     order, straddling the 2026-11-01 PT fall-back. Sorted as text the meter appears to
#     fall 60% -> 20% and the pair is dropped as a reset that never happened.
#     The assertion matches the specific "went DOWN" note, NOT the substring "reset":
#     an unrelated advisory note also contains that word, and matching it made this case
#     pass locally and fail in CI, where no meter samples exist to suppress the advisory.
cat > "$R" <<'HDR'
| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok | all_ieq | fable_ieq | note |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-04 | 2026-11-01T01:45-07:00 | 20% | 20% | 600.00 | 600.00 | 1 | 1 | 1 | 1 | earlier (PDT, 08:45 UTC) |
| 2026-11-04 | 2026-11-01T01:30-08:00 | 60% | 60% | 1800.00 | 1800.00 | 1 | 1 | 1 | 1 | later (PST, 09:30 UTC) |
HDR
got=$(pymod "up.READINGS=pathlib.Path(sys.argv[3]); d,n=up.differential_caps(up.read_readings()); print(len(d['all']), ('%.0f'%d['all'][0]) if d['all'] else 'none', 'RESETNOTE' if any('went DOWN' in x for x in n) else 'clean')" "$R" 2>&1)
[ "$got" = "1 3000 clean" ] \
  && ok "differential_caps orders a DST-straddling pair correctly (no phantom reset)" \
  || bad "differential_caps orders a DST-straddling pair correctly (no phantom reset)" "got=$(flat "$got")"


# --------------------------- 14. THE SPREAD REPORTING (shipped without coverage)
# The refute pass found the CAUTION path, the "range $lo-$hi" note and the persistence
# of lo/hi had no test at all — so a lo/hi inversion, or dropping the range entirely,
# would ship green. That is the same "ships alongside its own fix, untested" gap this
# suite was extended to close twice already.

# (a) The range reaches the basis string, in the right order.
printf '{"all": 2363.0, "periods": 6, "r2": 0.994, "lo": 1978.0, "hi": 2870.0, "at": "2026-09-04T22:00"}' > "$TMP/calib.json"
got=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); c,b,_=up.resolve_cap('all', []); print('%.0f'%c, 'RANGE' if 'range \$1,978-\$2,870' in b else 'MISSING:'+b)" "$TMP/calib.json" 2>&1)
[ "$got" = "2363 RANGE" ] \
  && ok "the cached basis carries the range low-to-high, not inverted" \
  || bad "the cached basis carries the range low-to-high, not inverted" "got=$(flat "$got")"

# (b) An inverted range must be visible, not silently printed backwards.
printf '{"all": 2363.0, "periods": 6, "r2": 0.994, "lo": 2870.0, "hi": 1978.0}' > "$TMP/calib.json"
got=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); c,b,_=up.resolve_cap('all', []); print('INVERTED' if 'range \$2,870-\$1,978' in b else 'ok')" "$TMP/calib.json" 2>&1)
[ "$got" = "INVERTED" ] \
  && ok "an inverted lo/hi renders verbatim (so a swap is visible, not masked)" \
  || bad "an inverted lo/hi renders verbatim" "got=$(flat "$got")"

# (c) The measurement date is surfaced, so a stale calibration is not silently trusted.
printf '{"all": 2363.0, "periods": 6, "r2": 0.994, "at": "2026-09-04T22:00"}' > "$TMP/calib.json"
got=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); _,b,_=up.resolve_cap('all', []); print('DATED' if 'measured 2026-09-04' in b else 'MISSING')" "$TMP/calib.json" 2>&1)
[ "$got" = "DATED" ] \
  && ok "the basis says when the calibration was measured" \
  || bad "the basis says when the calibration was measured" "got=$(flat "$got")"

# (d) A cache written before the range existed must still resolve, not crash or print
#     a half-formed range.
printf '{"all": 2363.0, "periods": 6, "r2": 0.994}' > "$TMP/calib.json"
got=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); c,b,_=up.resolve_cap('all', []); print('%.0f'%c, 'NORANGE' if 'range' not in b else 'LEAKED')" "$TMP/calib.json" 2>&1)
[ "$got" = "2363 NORANGE" ] \
  && ok "a pre-range cache file still resolves, with no half-formed range" \
  || bad "a pre-range cache file still resolves" "got=$(flat "$got")"

printf '{"all": 2363.0, "lo": 1978.0}' > "$TMP/calib.json"
got=$(pymod "up.CALIB=pathlib.Path(sys.argv[3]); c,b,_=up.resolve_cap('all', []); print('%.0f'%c, 'NORANGE' if 'range' not in b else 'LEAKED')" "$TMP/calib.json" 2>&1)
[ "$got" = "2363 NORANGE" ] \
  && ok "lo without hi does not render a broken range" \
  || bad "lo without hi does not render a broken range" "got=$(flat "$got")"

# (e) NaN must not reach the fit. json.loads accepts it, and `b <= 0` cannot reject a
#     NaN slope because every NaN comparison is False.
got=$(pymod "
import json
p=pathlib.Path(sys.argv[3]); p.write_text(json.dumps({'samples':[{'t':1,'u':{'sd':1}}]}).replace('\"sd\": 1','\"sd\": NaN'))
up.PLAN_SAMPLES=p; print(len(up.plan_samples()))" "$TMP/plan_nan.json" 2>&1)
[ "$got" = "0" ] \
  && ok "a NaN meter percentage is dropped before it can reach the regression" \
  || bad "a NaN meter percentage is dropped before it can reach the regression" "got=$(flat "$got")"


# (f) --calibrate END TO END: it must actually persist lo/hi and print the CAUTION.
#     Every case above writes the cache by hand, so they test the READ side only —
#     removing `"lo": lo, "hi": hi` from the write left the suite green. This drives the
#     real command against a synthetic meter whose periods deliberately disagree.
got=$("$PY" - "$SUT" "$TMP" <<'E2E' 2>&1
import importlib.util, json, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"e2e"
shutil.rmtree(root, ignore_errors=True); root.mkdir()
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"e2e_c.json"; up.CALIB=tmp/"e2e_calib.json"
up.READINGS=tmp/"e2e_r.md"
t0=1788600000000
# Two periods with deliberately different $/point, so lo != hi and the CAUTION fires.
recs=[]; samples=[]; n=0
for period,(per_step,pts) in enumerate([(1,40),(2,40)]):
    base=t0+period*100*10*60000
    for i in range(pts):
        for _ in range(per_step):
            recs.append(json.dumps({"type":"assistant","timestamp":
                up.datetime.fromtimestamp((base+i*10*60000+n)/1000, up.timezone.utc)
                  .isoformat().replace("+00:00","Z"),
                "message":{"id":"m%d"%n,"model":"claude-opus-5",
                           "usage":{"output_tokens":80000}}}, separators=(",",":")))
            n+=1
        samples.append({"t": base+i*10*60000, "u": {"sd": i}})
(root/"t.jsonl").write_text("\n".join(recs)+"\n")
up.PLAN_SAMPLES=tmp/"e2e_plan.json"
up.PLAN_SAMPLES.write_text(json.dumps({"version":2,"samples":samples}))
import io, contextlib
out=io.StringIO()
sys.argv=["x","--calibrate"]
with contextlib.redirect_stdout(out): rc=up.main()
c=json.loads(up.CALIB.read_text())
has=all(k in c for k in ("all","lo","hi","periods","r2","at"))
ordered = c.get("lo",0) <= c.get("all",0) <= c.get("hi",0)
caution = "CAUTION" in out.getvalue()
print(f"rc={rc} keys={has} ordered={ordered} caution={caution} ratio={c['hi']/c['lo']:.2f}")
E2E
)
case "$got" in
  "rc=0 keys=True ordered=True caution=True"*) ok "--calibrate persists lo/hi in order and prints the CAUTION when they disagree" ;;
  *) bad "--calibrate persists lo/hi in order and prints the CAUTION when they disagree" "$(flat "$got")" ;;
esac


# ------------------------- 15. A PAIR THAT STRADDLES A RESET THE METER CLIMBED PAST
# The dp<0 guard only sees a reset when the LATER reading reads lower. The two real
# readings on file straddle the 2026-09-04 out-of-band reset and their delta is
# POSITIVE (+5), so that guard is blind to it; differencing them gives $20,598 against
# a measured $2,363. Only the 10-point floor dropped the pair, which was luck.

PLANF=$TMP/straddle-plan.json
mkplan() {   # $1 = json samples array
  printf '{"version":2,"samples":%s}' "$1" > "$PLANF"
}
# a reset at t=2000s: 34% -> 2%, then climbing back past the first reading
mkplan '[{"t":1000000,"u":{"sd":30}},{"t":2000000,"u":{"sd":34}},{"t":3000000,"u":{"sd":2}},{"t":4000000,"u":{"sd":20}}]'

got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3])
print(up.reset_between(1500, 3500), up.reset_between(3100, 4000), up.reset_between(500, 900))" "$PLANF" 2>&1)
[ "$got" = "True False False" ] \
  && ok "reset_between sees a reset inside the window and not outside it" \
  || bad "reset_between sees a reset inside the window and not outside it" "got=$(flat "$got")"

# the real shape: a pair whose delta is POSITIVE but which straddles a reset
cat > "$R" <<'HDR'
| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok | all_ieq | fable_ieq | note |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-09 | 1970-01-01T00:25:00+00:00 | 10% | 10% | 200.00 | 200.00 | 1 | 1 | 1 | 1 | before |
| 2026-09-09 | 1970-01-01T01:06:40+00:00 | 60% | 60% | 1200.00 | 1200.00 | 1 | 1 | 1 | 1 | after |
HDR
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[4]); up.READINGS=pathlib.Path(sys.argv[3])
d,n=up.differential_caps(up.read_readings())
print(len(d['all']), 'STRADDLE' if any('STRADDLES' in x for x in n) else 'MISSED')" "$R" "$PLANF" 2>&1)
[ "$got" = "0 STRADDLE" ] \
  && ok "a +50-point pair straddling a reset is dropped (the percentage guard is blind to it)" \
  || bad "a +50-point pair straddling a reset is dropped" "got=$(flat "$got")"

# and a clean pair over the SAME window with no reset must still compute
mkplan '[{"t":1000000,"u":{"sd":10}},{"t":2000000,"u":{"sd":30}},{"t":3000000,"u":{"sd":50}},{"t":4000000,"u":{"sd":60}}]'
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[4]); up.READINGS=pathlib.Path(sys.argv[3])
d,_=up.differential_caps(up.read_readings())
print(len(d['all']), ('%.0f'%d['all'][0]) if d['all'] else '-')" "$R" "$PLANF" 2>&1)
[ "$got" = "1 2000" ] \
  && ok "an equivalent pair with no reset in the window still computes (1000/0.50)" \
  || bad "an equivalent pair with no reset in the window still computes" "got=$(flat "$got")"

# without the app's samples the check cannot run, and that must be SAID, not implied
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3]+'.absent'); up.READINGS=pathlib.Path(sys.argv[3])
d,n=up.differential_caps(up.read_readings())
print(len(d['all']), 'DISCLOSED' if any('cannot be detected' in x for x in n) else 'SILENT')" "$R" 2>&1)
[ "$got" = "1 DISCLOSED" ] \
  && ok "with no samples the pair still computes but the missing check is disclosed" \
  || bad "with no samples the pair still computes but the missing check is disclosed" "got=$(flat "$got")"


# (e) A reset whose first post-reset SAMPLE lands after the reading window. At a
#     15-minute cadence the drop's exact instant is unknown, so the interval
#     (prev_sample, next_sample) is what must overlap the window — checking whether the
#     post-drop sample itself falls inside it misses this ordinary case.
mkplan '[{"t":1000000,"u":{"sd":30}},{"t":2000000,"u":{"sd":34}},{"t":4000000,"u":{"sd":2}},{"t":5000000,"u":{"sd":9}}]'
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3])
print(up.reset_between(2500, 3000), up.reset_between(1000, 1500), up.reset_between(4200, 4800))" "$PLANF" 2>&1)
[ "$got" = "True False False" ] \
  && ok "a reset inside the window with no sample in it is still detected (interval overlap)" \
  || bad "a reset inside the window with no sample in it is still detected" "got=$(flat "$got")"

# (f) One definition of "reset", not two. _segments gained the fall-to-zero clause after
#     review; reset_between was written later without it, so 2%->0% split a regression
#     period but did not disqualify a pair spanning it.
mkplan '[{"t":1000000,"u":{"sd":2}},{"t":2000000,"u":{"sd":0}}]'
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3])
print(up.reset_between(500, 2500), len(up._segments(up.plan_samples())),
      up._is_reset(2,0), up._is_reset(34,2), up._is_reset(30,29), up._is_reset(0,0))" "$PLANF" 2>&1)
[ "$got" = "True 2 True True False False" ] \
  && ok "reset_between and _segments share one predicate (2%->0% is a reset to both)" \
  || bad "reset_between and _segments share one predicate" "got=$(flat "$got")"


# ------------------------------- 16. THE FALLBACK IS A MEASUREMENT, NOT AN INFERENCE
# Until 2026-09-05 these were "observed-unclamped floors" — the highest week seen to run
# without a visible clamp, asserted as a LOWER bound on the cap. Both were falsified by
# measurement: all-models said >$2,920 against a measured $2,363, and Fable said >$963
# against a measured $920, i.e. BELOW the week that supposedly proved it.
got=$(pymod "print('%.0f %.0f' % (up.FALLBACK['fable'], up.FALLBACK['all']))" 2>&1)
[ "$got" = "920 2363" ] \
  && ok "the fallbacks are the measured caps, not the falsified floors" \
  || bad "the fallbacks are the measured caps, not the falsified floors" "got=$(flat "$got")"

# and the basis must not repeat the claim the measurement disproved
got=$(pymod "
up.READINGS=pathlib.Path(sys.argv[3]+'.absent'); up.CALIB=pathlib.Path(sys.argv[3]+'.absent2')
c,b,cal = up.resolve_cap('fable', [])
print('%.0f'%c, cal, 'CLAIMS_HIGHER' if 'HIGHER' in b else 'honest')" "$R" 2>&1)
[ "$got" = "920 False honest" ] \
  && ok "the fallback basis no longer claims the true cap is higher than it" \
  || bad "the fallback basis no longer claims the true cap is higher than it" "got=$(flat "$got")"

# a real reading must still win over the fallback. This case builds its OWN fixture:
# relying on whatever $R held from an earlier section made it read 2000 instead of 3000.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   60 60 1800.00 1800.00 3000000000 3000000000 300000000 300000000
got=$(pymod "
up.CALIB=pathlib.Path(sys.argv[3]+'.absent2'); up.READINGS=pathlib.Path(sys.argv[3])
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3]+'.nosamples')
print('%.0f'%up.resolve_cap('all', up.read_readings())[0])" "$R" 2>&1)
[ "$got" = "3000" ] \
  && ok "a measured reading pair still outranks the fallback" \
  || bad "a measured reading pair still outranks the fallback" "got=$(flat "$got")"



# ---------------------------------------------- 12. the meter's zero vs the week open
# The pace numerator was week-anchored while the cap describes a METER PERIOD. Those
# agree only while the meter zeroed at the week open, and Anthropic moved the zero out
# of band on 2026-09-04 -- after which the live check read 90% of the all-models cap
# against a meter showing 57%. resolve_cap already routed around this defect (it prefers
# the differential BECAUSE absolute assumes zero == week open); the numerator did not.
#
# Every case below builds a world with a KNOWN offset and asserts it comes back.
offworld() {   # $1 = python body, run with `up`, `mk(reset_at_pct)` in scope
  "$PY" - "$SUT" "$TMP" "$1" <<'OFFPY' 2>&1
import importlib.util, json, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2])

def mk(pre_reset_reqs, post_reqs, fable_pre=0, fable_post=0, n_samples=24, tag="ow",
       pre_step=60_000, post_step=60_000, curve=1.0):
    """A week that runs `pre_reset_reqs` requests, has the meter zeroed out of band,
    then runs `post_reqs` more. Returns (week, expected_all_offset, expected_fable_off)."""
    root=tmp/tag; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
    up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/(tag+"_c.json"); up.CALIB=tmp/(tag+"_k.json")
    week="2026-09-09"
    open_ms=up.week_bounds(week)[0].timestamp()*1000
    t0=open_ms+3_600_000                      # first request an hour into the week
    recs=[]; n=0; clock=[t0]
    def add(count, fable_n, step):
        """Fable requests are INTERLEAVED, not appended. Bunching them at the end of a
        stretch makes spend piecewise-linear against a meter that climbs with time, and
        a straight-line fit through a kink returns a biased intercept -- $298 against a
        true $320 when this helper appended them. That bias is real (a period whose
        model mix shifts is genuinely harder to anchor) but it is a property of the
        WORLD, so a test that wants to measure the estimator must not build it in."""
        nonlocal n
        fset={round(j*count/fable_n) for j in range(fable_n)} if fable_n else set()
        for i in range(count):
            recs.append(json.dumps({"type":"assistant","timestamp":
                up.datetime.fromtimestamp(clock[0]/1000, up.timezone.utc)
                  .isoformat().replace("+00:00","Z"),
                "message":{"id":"m%d"%n,
                           "model":"claude-fable-5-1" if i in fset else "claude-opus-5",
                           "usage":{"output_tokens":80000}}}, separators=(",",":")))
            n+=1; clock[0]+=step
    add(pre_reset_reqs, fable_pre, pre_step)
    reset_ms=clock[0]                         # the meter zeroes HERE
    add(post_reqs, fable_post, post_step)
    post_span=clock[0]-reset_ms
    (root/"t.jsonl").write_text("\n".join(recs)+"\n")
    opus=up.cost_usd({"output_tokens":80000},"claude-opus-5")
    fbl =up.cost_usd({"output_tokens":80000},"claude-fable-5-1")
    exp_all=(pre_reset_reqs-fable_pre)*opus + fable_pre*fbl
    exp_fbl=fable_pre*fbl
    # meter: climbs over the pre-reset stretch, drops to 0 at the reset, climbs again
    s=[{"t":int(open_ms+60_000),"u":{"sd":0}},{"t":int(reset_ms-pre_step),"u":{"sd":40}}]
    for i in range(n_samples):
        s.append({"t":int(reset_ms+(i+1)*post_span/n_samples),
                  "u":{"sd": int(round(60*(((i+1)/n_samples)**curve)))}})
    up.PLAN_SAMPLES=tmp/(tag+"_p.json")
    up.PLAN_SAMPLES.write_text(json.dumps({"version":2,"samples":s}))
    return week, exp_all, exp_fbl
exec(sys.argv[3])
OFFPY
}

# (a) the normal week -- no out-of-band reset, so the meter has forgotten nothing and
#     this path must stay EXACTLY as it was. A fix that perturbs the common case is a
#     regression however well it handles the rare one.
got=$(offworld '
week="2026-09-09"
root=tmp/"n"; import shutil; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"n_c.json"; up.CALIB=tmp/"n_k.json"
open_ms=up.week_bounds(week)[0].timestamp()*1000
recs=[json.dumps({"type":"assistant","timestamp":
    up.datetime.fromtimestamp((open_ms+60_000+i*60_000)/1000, up.timezone.utc)
      .isoformat().replace("+00:00","Z"),
    "message":{"id":"n%d"%i,"model":"claude-opus-5",
               "usage":{"output_tokens":80000}}}, separators=(",",":")) for i in range(300)]
(root/"t.jsonl").write_text("\n".join(recs)+"\n")
s=[{"t":int(open_ms+60_000+i*600_000),"u":{"sd":i*2}} for i in range(30)]
up.PLAN_SAMPLES=tmp/"n_p.json"; up.PLAN_SAMPLES.write_text(json.dumps({"version":2,"samples":s}))
a,f,z,note,exact=up.meter_offset(week)
print("%.4f %.4f %s %r %s" % (a,f,z,note,exact))')
[ "$got" = "0.0000 0.0000 None '' True" ] \
  && ok "no out-of-band reset: offset 0, no rebase, no note (the common case is untouched)" \
  || bad "no out-of-band reset leaves the common case alone" "got=$(flat "$got")"

# (b) a known offset must come back out, in BOTH meters. The samples carry no Fable
#     field, so the Fable offset can only come from inverting the all-models fit --
#     which is the half most likely to be silently wrong.
got=$(offworld '
week,exp_all,exp_fbl=mk(pre_reset_reqs=120, post_reqs=300, fable_pre=40, fable_post=60)
a,f,z,note,exact=up.meter_offset(week)
ok_all = abs(a-exp_all) <= max(2.0, exp_all*0.02)
ok_fbl = abs(f-exp_fbl) <= max(2.0, exp_fbl*0.04)
print("all %.2f want %.2f %s | fable %.2f want %.2f %s | exact=%s"
      % (a,exp_all,"OK" if ok_all else "OFF", f,exp_fbl,"OK" if ok_fbl else "OFF", exact))
print("VERDICT-OK" if ok_all and ok_fbl and exact else "VERDICT-BAD")')
printf '%s' "$got" | grep -qx 'VERDICT-OK' \
  && ok "a known out-of-band offset is recovered in both meters (fable via the inverted fit)" \
  || bad "a known out-of-band offset is recovered in both meters" "$(flat "$got")"

# (c) the reset is real but the period is too short to fit. Reporting 0 would state a
#     number known to be too high; a guess dressed as a measurement is what this file
#     keeps having to retract. It must say so and mark itself inexact.
got=$(offworld '
week,exp_all,exp_fbl=mk(pre_reset_reqs=120, post_reqs=12, n_samples=3, tag="sh")
a,f,z,note,exact=up.meter_offset(week)
print("%.2f %s %s | %s" % (a, z, exact, note))')
printf '%s' "$got" | grep -q '^0.00 None False | meter reset out of band .* reads high' \
  && ok "a reset too short to fit is DISCLOSED, not silently reported as anchored" \
  || bad "a short post-reset period discloses that the total reads high" "$(flat "$got")"

# (d) the offset is a constant once the reset is past, so it is cached per PERIOD --
#     but a NEW reset must invalidate it. A cache keyed only by week would serve the
#     stale offset for the rest of the week.
got=$(offworld '
week,exp_all,_=mk(pre_reset_reqs=120, post_reqs=300, tag="c1")
first=up.meter_offset(week)[0]
cached=up.meter_offset(week)[0]                      # served from the cache
seg_before=json.loads(up.CALIB.read_text())["anchor"]["seg"]
# A SECOND reset, WITH spend after it. A reset followed by nothing cannot be fitted
# at all -- the code refuses it by the (c) path -- so the case that exercises the
# cache key is the one where the new period has something to measure.
f=up.ROOT/"t.jsonl"; lines=f.read_text().strip().split("\n")
t_last=up.datetime.fromisoformat(
    json.loads(lines[-1])["timestamp"].replace("Z","+00:00")).timestamp()*1000
lines += [json.dumps({"type":"assistant","timestamp":
    up.datetime.fromtimestamp((t_last+(i+1)*60_000)/1000, up.timezone.utc)
      .isoformat().replace("+00:00","Z"),
    "message":{"id":"z%d"%i,"model":"claude-opus-5",
               "usage":{"output_tokens":80000}}}, separators=(",",":")) for i in range(300)]
f.write_text("\n".join(lines)+"\n")
s=json.loads(up.PLAN_SAMPLES.read_text())
s["samples"] += [{"t":int(t_last+30_000),"u":{"sd":0}}] + [
    {"t":int(t_last+(i+1)*60_000*12),"u":{"sd":(i+1)*3}} for i in range(20)]
up.PLAN_SAMPLES.write_text(json.dumps(s))
after=up.meter_offset(week)[0]
seg_after=json.loads(up.CALIB.read_text())["anchor"]["seg"]
print("stable=%s invalidated=%s grew=%s" % (abs(first-cached)<1e-9,
      seg_after!=seg_before, after>first+1.0))')
[ "$got" = "stable=True invalidated=True grew=True" ] \
  && ok "the anchor caches per period and a NEW reset invalidates it" \
  || bad "the anchor cache is keyed to the period, not the week" "got=$(flat "$got")"

# (e) elapsed must be measured over the window the METER is pacing over. An out-of-band
#     reset moves the ZERO and not the close -- the 2026-09-01 top-up was followed by
#     the regular Wednesday reset anyway -- so the budget is a full cap over a SHORTER
#     window. Leaving a 7-day denominator under a re-anchored numerator calls a
#     genuinely hot week "on pace".
got=$(offworld '
week,exp_all,_=mk(pre_reset_reqs=120, post_reqs=300, tag="el", pre_step=1_800_000)
a,f,z,note,exact=up.meter_offset(week)
open_,close=up.week_bounds(week)
zero=up.datetime.fromtimestamp(z/1000, up.PT)
now=zero+up.timedelta(hours=6)
p=up.pace(now=now, prefer="derived")
wk_frac=(now-open_).total_seconds()/(close-open_).total_seconds()
mt_frac=(now-zero).total_seconds()/(close-zero).total_seconds()
print("rebased=%s not_week=%s" % (abs(p["elapsed"]-mt_frac)<0.01, abs(p["elapsed"]-wk_frac)>0.02))')
[ "$got" = "rebased=True not_week=True" ] \
  && ok "elapsed is measured from the meter's zero, not the week open" \
  || bad "elapsed is re-based to the meter's zero" "got=$(flat "$got")"

# (f) verdict() is RETIRED, and these three cases replace its three. It graded a DERIVED
#     percentage against a cached median cap and said "NEAR CAP" at >=90% -- which read 96%
#     while the live meter read 79, and which was never actionable anyway: 90% of a cap
#     spent is the subscription working. The two conditions that remain are both about the
#     SHAPE of the week, and each is asserted to fire ONLY under its own condition.
#     (a) the wall arrives before half the remaining week is gone.
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":100.0,"hours_to_wall":40.0,"landing":150.0,"rate":20.0})))')
[ "$q" = "lockout" ] \
  && ok "warning (a) fires when the wall lands inside half the remaining week" \
  || bad "warning (a) fires when the wall lands inside half the remaining week" "got=$(flat "$q")"
# just the other side of the same boundary -- and nothing else changed
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":100.0,"hours_to_wall":51.0,"landing":150.0,"rate":20.0})))')
[ -z "$q" ] \
  && ok "warning (a) is silent just the other side of 0.5 x hours_to_reset" \
  || bad "warning (a) is silent just the other side of 0.5 x hours_to_reset" "got=$(flat "$q")"
# (b) quota that will expire unspent, and ONLY inside the last day of the week.
#     ...and (a) alone is withheld when the rate behind hours_to_wall is PROVISIONAL --
#     calibrated on fewer than MIN_MOVED points of meter movement, which is every reading
#     taken in the first hour after a reset. One rounded point of movement makes the rate
#     uncertain by a factor of three, and "the rest of the week is lost" must not come out
#     of that. The identical world with the flag off must still warn, or this asserts
#     nothing but that a key exists.
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":100.0,"hours_to_wall":40.0,"landing":150.0,"rate":20.0,
     "provisional":True})))')
[ -z "$q" ] \
  && ok "warning (a) is withheld while the rate is provisional (a one-point rate cannot say the week is lost)" \
  || bad "warning (a) is withheld while the rate is provisional" "got=$(flat "$q")"
# (b) is NOT gated the same way: at worst it suggests spending quota that would be
#     destroyed, and it cannot fire in the first hour of a week anyway (it needs h < 24).
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":20.0,"hours_to_wall":999.0,"landing":80.0,"rate":20.0,
     "provisional":True})))')
[ "$q" = "waste" ] \
  && ok "warning (b) still fires on a provisional rate (it can only suggest spending)" \
  || bad "warning (b) still fires on a provisional rate" "got=$(flat "$q")"
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":20.0,"hours_to_wall":999.0,"landing":80.0,"rate":20.0})))')
[ "$q" = "waste" ] \
  && ok "warning (b) fires on a sub-90% landing inside the last 24h" \
  || bad "warning (b) fires on a sub-90% landing inside the last 24h" "got=$(flat "$q")"
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":30.0,"hours_to_wall":999.0,"landing":80.0,"rate":20.0})))')
[ -z "$q" ] \
  && ok "warning (b) holds its tongue while there is still more than a day to spend it" \
  || bad "warning (b) holds its tongue while there is more than a day left" "got=$(flat "$q")"
q=$(pymod 'print(",".join(k for k,_ in up.warnings_for(
    {"hours_to_reset":20.0,"hours_to_wall":999.0,"landing":95.0,"rate":20.0})))')
[ -z "$q" ] \
  && ok "a week landing at 95% wastes nothing worth saying" \
  || bad "a week landing at 95% wastes nothing worth saying" "got=$(flat "$q")"
# neither warning mentions a cap, being ahead, or what happens past 100% -- lockout has
# never actually been observed on this account, so nothing here may claim it.
q=$(pymod 'print(" ".join(m for _,m in up.warnings_for(
    {"hours_to_reset":20.0,"hours_to_wall":1.0,"landing":80.0,"rate":20.0,
     "wall_at":"Tue 09:15 PT"})).lower())')
case "$q" in
  *"near cap"*|*"ahead"*|*"locked out"*|*"of cap"*)
     bad "the warnings never say NEAR CAP, ahead of pace, or what 100% does" "$(flat "$q")" ;;
  *"tue 09:15 pt"*"expire unspent"*)
     ok "the warnings name the wall's arrival time and the quota that would expire" ;;
  *) bad "the warnings name the wall's arrival time and the expiring quota" "$(flat "$q")" ;;
esac

# (g) and the DERIVED path must actually SUBTRACT the offset. meter_offset can be perfect
#     while the caller ignores it -- precisely the shape of the original defect, where
#     resolve_cap handled the moved zero and the numerator did not. This is asserted
#     against `prefer="derived"` now: where a live sample exists the readout reports the
#     meter's own percentage and needs no offset at all, and this world HAS one (it is
#     built from synthetic samples), so without the flag it would exercise the live path
#     and silently stop covering meter_offset's only consumer.
got=$(offworld '
week,exp_all,exp_fbl=mk(pre_reset_reqs=120, post_reqs=300, fable_pre=40, fable_post=60)
a,f,z,note,exact=up.meter_offset(week)
zero=up.datetime.fromtimestamp(z/1000, up.PT)
p=up.pace(now=zero+up.timedelta(hours=2), prefer="derived")
print("all=%s fable=%s lower=%s consumed=%s derived=%s" % (
  abs(p["week_all"]-p["spend"]-a)<0.01,
  abs(p["week_fable"]-p["fable"]-f)<0.01,
  p["spend"]<p["week_all"]-1.0 and p["fable"]<p["week_fable"]-1.0,
  abs(p["consumed"]-p["fable"]/p["cap"])<1e-9,
  p["source"]=="derived"))')
[ "$got" = "all=True fable=True lower=True consumed=True derived=True" ] \
  && ok "the derived path reports what the METER counts, not the week total" \
  || bad "the derived path subtracts the offset from both meters" "got=$(flat "$got")"

# (h) a machine with no usage history at all. Extracting the transcript walk out of
#     sampled_caps carried its single-list `return []` along, where the new caller
#     unpacks three -- so an empty ROOT raised ValueError instead of returning empty.
#     Reachable on a fresh bootstrap, and no other test has an empty ROOT.
got=$(pymod '
import tempfile
up.ROOT=pathlib.Path(tempfile.mkdtemp())
t,c,f=up._cum_events("$")
print("arity=3 times=%d cum=%s caps=%s" % (len(t), c, up.sampled_caps()))')
[ "$got" = "arity=3 times=0 cum=[0.0] caps=[]" ] \
  && ok "an empty transcript tree returns a 3-tuple (fresh machine does not crash)" \
  || bad "empty ROOT returns the documented shape" "got=$(flat "$got")"

# (i) the fit can FAIL rather than merely be imprecise. This period starts at a reset,
#     so the forgotten spend is spend that happened earlier this week and the intercept
#     cannot be meaningfully negative. Clamping it to zero applied NO correction while
#     reporting `exact` -- silently reproducing the defect this file exists to fix,
#     under a plausible R2 and no warning.
got=$(offworld '
week,exp_all,exp_fbl=mk(pre_reset_reqs=20, post_reqs=300, curve=0.5, tag="cv")
a,f,z,note,exact=up.meter_offset(week)
zero=up.week_bounds(week)[0]+up.timedelta(hours=30)
p=up.pace(now=zero, prefer="derived")
print("off=%.1f exact=%s zero=%s warned=%s | %s" % (
  a, exact, z, "WARNING" in up.fmt(p), note[:52]))')
printf '%s' "$got" | grep -q '^off=0.0 exact=False zero=None warned=True | meter reset out of band' \
  && ok "a failed fit is disclosed and WARNS, instead of silently correcting nothing" \
  || bad "a failed fit discloses rather than clamping to zero" "$(flat "$got")"

# (j) the cap calibration and the anchor share one file, so either writer must merge.
#     --calibrate used to overwrite it wholesale, discarding the anchor.
got=$(pymod '
import tempfile
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
up._merge_calib({"anchor": {"week":"2026-09-09","seg":1,"all":5.0,"fable":1.0}})
up._merge_calib({"all": 2415.0, "periods": 7, "r2": 0.99})   # what --calibrate writes
d=up.json.loads(up.CALIB.read_text())
print("anchor_kept=%s cap=%s" % ("anchor" in d, d.get("all")))')
[ "$got" = "anchor_kept=True cap=2415.0" ] \
  && ok "the cap calibration and the anchor share a file without clobbering each other" \
  || bad "--calibrate merges rather than overwriting the anchor" "got=$(flat "$got")"

# (k) a zero offset makes the crossing land on the week-open index, so `j - 1` names the
#     last event of the PREVIOUS week. A zero instant outside this week is not a zero
#     instant. Driven through a stubbed _cum_events because the series has to contain a
#     pre-week event, which no synthetic world above builds.
got=$(pymod '
import tempfile
week="2026-09-09"
O=up.week_bounds(week)[0].timestamp()*1000
# one event LAST week (cum 100 at the week open), then 40 events this week whose spend
# is exactly proportional to the meter -> the fitted intercept is 0, which is the case
# that exposes the index.
times=[O-1000.0]+[O+1000.0+i*60_000 for i in range(40)]
cum=[0.0,100.0]+[100.0+i*10.0 for i in range(40)]
up._cum_events=lambda unit="$": (times, cum, list(cum))
# a real out-of-band reset INSIDE the week, or the early return fires first and the
# index under test is never reached (this test did exactly that before).
smp=[{"t":int(O+200),"u":{"sd":30}},{"t":int(O+400),"u":{"sd":40}}]+[
     {"t":int(O+1000+i*60_000),"u":{"sd":i}} for i in range(40)]
up.PLAN_SAMPLES=pathlib.Path(tempfile.mkdtemp())/"p.json"
up.PLAN_SAMPLES.write_text(up.json.dumps({"version":2,"samples":smp}))
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
a,f,z,note,exact=up.meter_offset(week, force=True)
print("off=%.1f reached=%s zero_before_week=%s" % (
      a, note!="" or not exact, (z is not None and z < O)))')
[ "$got" = "off=0.0 reached=True zero_before_week=False" ] \
  && ok "a zero instant is never reported from before the week opened" \
  || bad "the zero instant stays inside the week" "got=$(flat "$got")"

# ------------------------- 16. A CAP CHANGE IS A RISE, AND THE RESET GUARD IS BLIND TO IT
# The +50% boost expires 2026-09-13, mid-week for the 09-09->09-16 meter week. A smaller
# cap makes the same spend read HIGHER, so a pair straddling it has a POSITIVE delta and
# passes every guard above -- and differences across two caps. skill-templates#248.

# (l) the predicate: overlap with the window, in either direction, including a reading
#     taken INSIDE it; nothing outside.
got=$(pymod '
D=lambda d,h: up.datetime(2026,9,d,h,0,tzinfo=up.PT).timestamp()
r=[up.multiplier_change_between(D(12,9), D(12,21)),   # both before
   up.multiplier_change_between(D(14,9), D(15,9)),    # both after
   up.multiplier_change_between(D(12,9), D(14,9)),    # straddles
   up.multiplier_change_between(D(14,9), D(12,9)),    # straddles, reversed
   up.multiplier_change_between(D(12,9), D(13,12)),   # second reading INSIDE the window
   up.multiplier_change_between(D(13,12), D(13,12))]  # a single instant inside it
print(" ".join("none" if x is None else ("boost" if "boost" in x else "?") for x in r))')
[ "$got" = "none none boost boost boost boost" ] \
  && ok "multiplier_change_between: overlap with the expiry window, either direction, else none" \
  || bad "multiplier_change_between overlap rule" "got=$(flat "$got")"

# (m) the differential: a +40-point pair straddling 09-13 is dropped with a note naming the
#     boost; the same pair shifted entirely past the window is kept. Meter samples are
#     flat-climbing with no reset, so this is the ONLY guard that can act.
BOOSTPLAN=$TMP/boost-plan.json
BOOSTR=$TMP/boost-readings.md
python3 - "$BOOSTPLAN" "$BOOSTR" <<'MK'
import json, sys
from datetime import datetime
from zoneinfo import ZoneInfo
PT=ZoneInfo("America/Los_Angeles")
T=lambda d,h: int(datetime(2026,9,d,h,0,tzinfo=PT).timestamp()*1000)
smp=[{"t":T(10,0)+i*3600_000,"u":{"sd":min(99,i)}} for i in range(24*6)]   # 09-10 -> 09-16, no reset
open(sys.argv[1],"w").write(json.dumps({"version":2,"samples":smp}))
def row(d,h,pct,usd): return f"| 2026-09-16 | 2026-09-{d:02d}T{h:02d}:00-07:00 | {pct}% | {pct}% | {usd:.2f} | {usd:.2f} | 1 | 1 | 1 | 1 | x |"
open(sys.argv[2],"w").write("\n".join([
 "| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok | all_ieq | fable_ieq | note |",
 "|---|---|---|---|---|---|---|---|---|---|---|",
 row(12,9,10,200.0), row(14,9,50,1200.0),     # straddles the 09-13 window
 row(14,12,55,1300.0), row(15,12,95,2300.0),  # entirely after it
])+"\n")
MK
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[4]); up.READINGS=pathlib.Path(sys.argv[3])
d,n=up.differential_caps(up.read_readings())
spans=[x for x in n if 'SPANS a cap change' in x and 'boost' in x]
print(len(d['all']), len(spans), 'reset-note' if any('STRADDLES' in x for x in n) else 'no-reset-note',
      round(d['all'][0]) if d['all'] else None)" "$BOOSTR" "$BOOSTPLAN" 2>&1)
# 2 notes, not 1: the loop runs once per meter (all, fable) and each drops its own
[ "$got" = "1 2 no-reset-note 2500" ] \
  && ok "a +40-point pair spanning the boost expiry is dropped and named; the pair after it is kept" \
  || bad "differential drops the pair spanning a cap change" "got=$(flat "$got")"

# (n) the regression sees the same event: a reset-free series across 09-13 is split into a
#     before and an after, and no sample from inside the window is in either.
got=$(pymod "
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3])
segs=up._segments(up.plan_samples())
w0,w1,_=up.MULTIPLIER_WINDOWS[0]
inside=sum(1 for seg in segs for t,_ in seg if w0 <= t/1000 < w1)
print(len(segs), inside, all(len(seg)>0 for seg in segs))" "$BOOSTPLAN" 2>&1)
[ "$got" = "2 0 True" ] \
  && ok "_segments splits a regression period at the cap change and discards the ambiguous day" \
  || bad "_segments splits at the cap change" "got=$(flat "$got")"

# (n2) a window that NO sample landed in -- a sampling gap over the whole day -- still splits.
got=$(pymod '
D=lambda d,h: int(up.datetime(2026,9,d,h,0,tzinfo=up.PT).timestamp()*1000)
smp=[(D(12,h),h) for h in range(0,24)]+[(D(14,h),24+h) for h in range(0,24)]
segs=up._segments(smp)
print(len(segs), [len(x) for x in segs])')
[ "$got" = "2 [24, 24]" ] \
  && ok "_segments splits at a cap change even when no sample fell inside the window" \
  || bad "_segments splits across a sampling gap over the window" "got=$(flat "$got")"

# (n3) the empty-input contract callers rely on ([-1] indexing) survives the rewrite.
got=$(pymod 'print(up._segments([]), up._segments([(1,1),(2,2)]))')
[ "$got" = "[[]] [[(1, 1), (2, 2)]]" ] \
  && ok "_segments still returns one (possibly empty) segment for empty input" \
  || bad "_segments empty-input contract" "got=$(flat "$got")"

# ------------------------- 17. A WINDOW SPLIT IS NOT A RESET (#250, items 1-2)
# (o) every sample of the week inside the window: _segments gives [[]], and meter_offset
#     used to index it. The hook calls pace() unwrapped, so that was a traceback per prompt.
got=$(pymod '
import tempfile
D=lambda d,h: int(up.datetime(2026,9,d,h,0,tzinfo=up.PT).timestamp()*1000)
smp=[{"t":D(13,h),"u":{"sd":h}} for h in range(1,20)]
up.PLAN_SAMPLES=pathlib.Path(tempfile.mkdtemp())/"p.json"
up.PLAN_SAMPLES.write_text(up.json.dumps({"version":2,"samples":smp}))
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
r=up.meter_offset("2026-09-16", force=True)
print(r[0], r[1], r[2], "quiet" if r[3]=="" else "NOTE", r[4])')
[ "$got" = "0.0 0.0 None quiet True" ] \
  && ok "a week sampled only inside the cap-change window anchors to nothing instead of crashing" \
  || bad "all-in-window week does not crash meter_offset" "got=$(flat "$got")"

# (p) a week that spans the window with NO reset: the last segment starts at the window
#     end, which is not a moved zero. It must take the quiet path and print no WARNING.
#     And a RESET hidden inside the window must still be seen as one.
got=$(pymod '
import tempfile
D=lambda d,h: int(up.datetime(2026,9,d,h,0,tzinfo=up.PT).timestamp()*1000)
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
up.PLAN_SAMPLES=pathlib.Path(tempfile.mkdtemp())/"p.json"
# spend series stubbed, as in (k): the reset half must reach the anchoring fit, and on a
# machine with no transcripts (CI) the real walk is empty and meter_offset returns quietly
# for the wrong reason -- which is exactly what happened on the first push of #251.
O=up.week_bounds("2026-09-16")[0].timestamp()*1000
times=[O+1000.0+i*3600_000 for i in range(24*7)]
cum=[0.0]+[(i+1)*10.0 for i in range(24*7)]
up._cum_events=lambda unit="$": (times, cum, list(cum))
cont=[{"t":D(10,h),"u":{"sd":h}} for h in range(0,24)]+[{"t":D(14,h),"u":{"sd":40+h}} for h in range(0,24)]
up.PLAN_SAMPLES.write_text(up.json.dumps({"version":2,"samples":cont}))
a=up.meter_offset("2026-09-16", force=True)
rst=[{"t":D(10,h),"u":{"sd":40+h}} for h in range(0,24)]+[{"t":D(14,h),"u":{"sd":h}} for h in range(0,24)]
up.PLAN_SAMPLES.write_text(up.json.dumps({"version":2,"samples":rst}))
b=up.meter_offset("2026-09-16", force=True)
print("continuous:", a[3]=="" and a[4], "| reset-in-window:", "reset" in b[3])')
[ "$got" = "continuous: True | reset-in-window: True" ] \
  && ok "a segment that begins at the window is a moved zero only if the meter fell across it" \
  || bad "window split vs reset in meter_offset" "got=$(flat "$got")"

# ------------------- 18. THE PER-MINUTE INDEX (what the live readout is measured from)
# The live readout needs spend since an ARBITRARY instant (the meter's observed zero) and
# over the last hour/three hours. The week totals cannot answer either, and a full
# transcript walk per invocation costs ~4s. So scan() carries a per-minute index -- and it
# must agree with the totals exactly, survive the incremental path, and not keep spend
# from bytes that are gone.
got=$("$PY" - "$SUT" "$TMP" <<'BKPY' 2>&1
import importlib.util, json, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"bk"
shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"bk_c.json"
week="2026-09-09"
open_ms=up.week_bounds(week)[0].timestamp()*1000
t0=open_ms+3_600_000
def rec(i, ms, model):
    return json.dumps({"type":"assistant","timestamp":
        up.datetime.fromtimestamp(ms/1000, up.timezone.utc).isoformat().replace("+00:00","Z"),
        "message":{"id":"b%d"%i,"model":model,"usage":{"output_tokens":80000}}},
        separators=(",",":"))
opus=up.cost_usd({"output_tokens":80000},"claude-opus-5")
fbl =up.cost_usd({"output_tokens":80000},"claude-fable-5")
# 10 opus at t0 + i minutes, then 4 fable at t0 + 100 minutes + i
lines=[rec(i, t0+i*60_000, "claude-opus-5") for i in range(10)]
lines+=[rec(100+i, t0+(100+i)*60_000, "claude-fable-5") for i in range(4)]
f=root/"t.jsonl"; f.write_text("\n".join(lines[:6])+"\n")
tot,bk=up.scan_detail(week)                      # first, partial
f.write_text("\n".join(lines)+"\n")
tot,bk=up.scan_detail(week)                      # incremental append
tot2,bk2=up.scan_detail(week, force=True)        # ground truth
sum_all=sum(v[0] for v in bk.values()); sum_fbl=sum(v[1] for v in bk.values())
# a window that must contain exactly the 4 fable requests and nothing else
w=up.window_spend(bk, t0+99*60_000, t0+110*60_000)
# ...and one over 3 minutes of the opus run: minutes 1, 2 and 3, NOT the first three.
# `(lo, hi]` gives up the bucket containing `lo`, so the request at t0 itself is outside it
# -- the count is 3 either way, which is exactly why a comment claiming "the first 3" could
# sit here being wrong while the arithmetic stayed right.
w2=up.window_spend(bk, t0, t0+3*60_000)
print("totals=%s fable=%s incr=%s win=%s win2=%s" % (
  abs(sum_all-tot["all"])<1e-9,
  abs(sum_fbl-tot.get("fable",0.0))<1e-9,
  bk==bk2,
  abs(w[0]-4*fbl)<1e-9 and abs(w[1]-4*fbl)<1e-9,
  abs(w2[0]-3*opus)<1e-9 and w2[1]==0.0))
BKPY
)
[ "$got" = "totals=True fable=True incr=True win=True win2=True" ] \
  && ok "the per-minute index agrees with the totals, and windows it exactly" \
  || bad "the per-minute index agrees with the totals" "got=$(flat "$got")"

# The WINDOW BOUNDARY, both ends, because `hi_ms` is almost always NOW and almost never on
# a minute boundary. Rounding the top end down dropped the minute in progress outright --
# the minute the newest request landed in -- so `spend since the reset`, the rate's
# numerator and `burn_1h` (the only input to the wall, and so to the lockout warning) each
# ran up to a minute behind. The partition property is asserted with it: a fix that simply
# included both ends would double-count the bucket a split instant falls in, and `pace`
# splits at the sample and prints `spend` beside the two halves it is made of.
got=$(pymod "
T = 1_000_000_000_000 + 37_123          # deliberately mid-minute, as now_ms always is
m = up.bucket_of(T)
bk = {m - 2: [5.0, 1.0], m - 1: [7.0, 2.0], m: [11.0, 3.0], m + 1: [13.0, 4.0]}
now_min = up.window_spend(bk, T - 5 * 60_000, T)[0]          # must include T's own minute
after  = up.window_spend(bk, T - 5 * 60_000, T)[1]
beyond = up.window_spend(bk, T - 5 * 60_000, T - 60_000)[0]   # must stop before it
S = T - 90_000                                                # a mid-minute split instant
whole = up.window_spend(bk, T - 5 * 60_000, T)[0]
lo_h  = up.window_spend(bk, T - 5 * 60_000, S)[0]
hi_h  = up.window_spend(bk, S, T)[0]
print('%.0f %.0f %.0f %s' % (now_min, after, beyond, abs(lo_h + hi_h - whole) < 1e-9))")
[ "$got" = "23 6 12 True" ] \
  && ok "window_spend counts the minute containing hi_ms, and adjacent windows partition" \
  || bad "window_spend counts the minute containing hi_ms and partitions" "got=$(flat "$got")"

# WHAT THE BOTTOM END GIVES UP, at the one `lo` that is not a reset: the week open. The
# docstring justified dropping that bucket by calling it "partly last week's", and it is
# not -- `scan_detail` keeps only events whose own week_close is this week, so no dollar of
# last week's is ever in this week's index to drop. What the drop actually costs is up to
# the first minute of THIS week's spend, which is the honest reason to accept it (one
# bucket, at the start of a week measured in hours, in exchange for the partition
# property). Asserted rather than reasoned about, because the docstring's claim is exactly
# the kind that survives by being plausible.
got=$("$PY" - "$SUT" "$TMP" <<'OPENPY' 2>&1
import importlib.util, json, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"bkopen"
shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"bkopen_c.json"
week="2026-09-09"
open_ms=up.week_bounds(week)[0].astimezone(up.timezone.utc).timestamp()*1000
b=up.bucket_of(open_ms)
def rec(i, ms, tok):
    return json.dumps({"type":"assistant","timestamp":
        up.datetime.fromtimestamp(ms/1000, up.timezone.utc).isoformat().replace("+00:00","Z"),
        "message":{"id":"o%d"%i,"model":"claude-opus-5","usage":{"output_tokens":tok}}},
        separators=(",",":"))
# 30 seconds BEFORE the open (last week's), and two after it -- the first in the open's own
# bucket, the second in the next one.
(root/"t.jsonl").write_text("\n".join([
    rec(0, open_ms - 30_000, 400_000), rec(1, open_ms + 30_000, 800_000),
    rec(2, open_ms + 90_000, 1_200_000)]) + "\n")
tot, bk = up.scan_detail(week, force=True)
c = lambda tok: up.cost_usd({"output_tokens": tok}, "claude-opus-5")
print("tot=%s before_open=%s in_bucket=%s window=%s" % (
    abs(tot["all"] - (c(800_000) + c(1_200_000))) < 1e-9,   # last week's is not counted
    [m for m in bk if m < b] == [],                         # ...and not in the index
    abs(bk[b][0] - c(800_000)) < 1e-9,                      # the open's bucket is in-week
    abs(up.window_spend(bk, open_ms, None)[0] - c(1_200_000)) < 1e-9))  # ...and is dropped
OPENPY
)
[ "$got" = "tot=True before_open=True in_bucket=True window=True" ] \
  && ok "the index holds only this week's spend, so the bucket at the week open is this week's to drop" \
  || bad "the bucket at the week open holds only this week's spend" "got=$(flat "$got")"

# A shrunk transcript must leave no stale spend in the INDEX either. The totals case is
# pinned above; the index is a second accumulator in the same file and a revert of its
# share of _cache_stale would leave that case green.
got=$("$PY" - "$SUT" "$TMP" <<'BKSHRINK' 2>&1
import importlib.util, json, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
tmp=pathlib.Path(sys.argv[2]); root=tmp/"bks"
shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=tmp; up.CACHE=tmp/"bks_c.json"
week="2026-09-09"
t0=up.week_bounds(week)[0].timestamp()*1000+3_600_000
def rec(i):
    return json.dumps({"type":"assistant","timestamp":
        up.datetime.fromtimestamp((t0+i*60_000)/1000, up.timezone.utc)
          .isoformat().replace("+00:00","Z"),
        "message":{"id":"s%d"%i,"model":"claude-opus-5","usage":{"output_tokens":80000}}},
        separators=(",",":"))
f=root/"t.jsonl"
f.write_text(rec(1)+"\n"+rec(2)+"\n"); up.scan_detail(week)
f.write_text(rec(9)+"\n")
_,bk=up.scan_detail(week)
_,bk2=up.scan_detail(week, force=True)
print("MATCH" if bk==bk2 else "STALE %s != %s" % (sorted(bk), sorted(bk2)))
BKSHRINK
)
[ "$got" = "MATCH" ] \
  && ok "a shrunk transcript leaves no stale minute in the index" \
  || bad "a shrunk transcript leaves no stale minute in the index" "got=$(flat "$got")"

# A malformed index in the cache must be dropped entry by entry, never raise.
got=$("$PY" - "$SUT" "$TMP" <<'BKBAD' 2>&1
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
for shape in ({"bk":[1,2]}, {"bk":{"x":[1,2]}}, {"bk":{"5":"nope"}}, {"bk":{"5":[1]}},
              {"bk":{"5":[float("nan"),0]}}, {}, {"bk":None}):
    assert up._load_buckets(shape) == {}, shape
print("OK", up._load_buckets({"bk":{"7":[1.5,0.5]}}))
BKBAD
)
[ "$got" = "OK {7: [1.5, 0.5]}" ] \
  && ok "a malformed per-minute index is dropped, not trusted, and never raises" \
  || bad "a malformed per-minute index is dropped" "got=$(flat "$got")"


# ----------------------- 19. THE LIVE READOUT (the percentage is READ, not computed)
# Every case here drives the real command against a fixture HOME: a known meter sample, a
# known transcript, and expectations computed OUTSIDE the script. The point of the section
# is that no number in the line is invented -- the old code had this same file open and
# printed week-spend-over-a-cached-cap beside it, reading 96% while the meter read 79.
LIVEHOME=$TMP/livehome
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[40,6000000,"claude-fable-5"],[30,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "the live readout reports the fixture's own meter" "too close to a meter reset"
else
  # Every printed field, and each one has to be distinguishable from its neighbours.
  # `spend_s` carries "spent ... since" rather than a bare dollar amount: while it was a
  # bare "$2,000", DOUBLING only the displayed spend left the suite green, because the
  # fixture's fable figure and its burn_1h happened to format the same string. So this
  # world also spends some SONNET (fable_s differs from spend_s) and puts a block outside
  # the one-hour window (burn_s differs from both).
  miss=""
  for k in sd_s fwd_s fh_s sample_s spend_s fable_s rate_s left_s burn_s \
           reset_s landing_s need_s; do
    want=$(fixf "$fx" "$k")
    case "$line" in *"$want"*) ;; *) miss="$miss [$k=$want]" ;; esac
  done
  [ -z "$miss" ] \
    && ok "--oneline reports every one of the fixture's own figures, field by field" \
    || bad "--oneline reports the fixture's own figures" "missing:$miss || $(flat "$line")"

  # ...and the NUMBERS behind them, from --json, to the cent. A string match cannot pin a
  # figure whose neighbour prints the same rounded text, and four of these were pinned by
  # nothing at all: doubling landing, need_per_hour or hours_to_wall each left the suite
  # green. hours_to_wall is the worst of those -- it is the ONLY input to warning (a), and
  # the warning itself was unit-tested exclusively with injected dictionaries, so the guard
  # was covered and its producer was not.
  got=$(HOME="$LIVEHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin); w = json.loads(sys.argv[1])
pairs = [("rate","rate"), ("pct_now","pct_now"), ("pts_left","pts_left"),
         ("usd_left","usd_left"), ("hours_to_wall","wall"), ("landing","landing"),
         ("need_per_hour","need"), ("burn_1h","burn1"), ("burn_3h","burn3"),
         ("hours_to_reset","h_reset"), ("spend","spend"), ("spend_at_sample","at_s"),
         ("spend_since_sample","since")]
off = [k for k, j in pairs
       if p.get(k) is None or abs(p[k] - w[j]) > max(0.01, abs(w[j]) * 1e-6)]
print("OFF", off or "none")' "$fx")
  [ "$got" = "OFF none" ] \
    && ok "--json's rate, pct_now, headroom, wall, landing and need match the fixture exactly" \
    || bad "--json's derived figures match the fixture" "got=$(flat "$got")"

  # The discriminating case: SAME transcripts, a different meter sample. A computed
  # percentage cannot move here and a read one must -- and \$/pt must move with it,
  # because the rate is this week's spend over this week's points.
  fx2=$(mkfix "$LIVEHOME" '{"sd":41,"fh":8,"age_min":5,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[40,6000000,"claude-fable-5"],[30,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
  line2=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
  w1=$(fixf "$fx2" sd_s); w2=$(fixf "$fx2" rate_s); w3=$(fixf "$fx2" left_s)
  case "$line2" in
    *"$w1"*"$w2"*"$w3"*) ok "halving the fixture's sd halves the meter and doubles \$/pt (it is READ)" ;;
    *) bad "the printed percentage follows the sample, not the spend" "want $w1/$w2/$w3 || $(flat "$line2")" ;;
  esac
fi

# NEAR CAP is gone from every path, whatever the fixture says.
case "$line" in
  *"NEAR CAP"*|*"AHEAD OF PACE"*) bad "--oneline never prints NEAR CAP or AHEAD OF PACE" "$(flat "$line")" ;;
  *) ok "--oneline never prints NEAR CAP or AHEAD OF PACE" ;;
esac

# The stale flag is a threshold, so both sides of it are asserted. A 48-minute-old sample
# read as current is the same defect as a computed one read as measured.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":48,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[60,6000000,"claude-fable-5"],[55,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
stale_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[40,6000000,"claude-fable-5"],[30,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
fresh_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
case "$stale_line$fresh_line" in
  *"SAMPLE STALE 48m"*) case "$fresh_line" in
      *"STALE"*) bad "the stale flag appears past 30m and not before" "fresh line is flagged: $(flat "$fresh_line")" ;;
      *) ok "the stale flag appears at 48m and not at 5m, and names the age" ;;
    esac ;;
  *) bad "the stale flag appears past 30m and not before" "$(flat "$stale_line")" ;;
esac

# Spend the meter's own samples cannot attribute to either side of the reset: the figures
# become a RANGE rather than being fitted. Fitting it is what took $215 off the week.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"gap_n":1,"gap_tok":4000000,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[40,6000000,"claude-fable-5"],[30,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
gap_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "spend inside the reset gap is carried as a range" "too close to a meter reset"
else
  w1=$(fixf "$fx" spend_rng_s); w2=$(fixf "$fx" rate_rng_s); w3=$(fixf "$fx" gap_s)
  case "$gap_line" in
    *"$w1"*"$w2"*"$w3 of spend sits inside the reset gap"*)
       ok "spend inside the reset gap makes every figure a range, and says why" ;;
    *) bad "spend inside the reset gap is carried as a range" "want $w1/$w2/$w3 || $(flat "$gap_line")" ;;
  esac
fi


# A landing BELOW 100 prints the number itself rather than the ">100% (the wall comes
# first)" branch, and only this world exercises that half of the formatter. Low sd, so
# the same burn buys many more points than it does at 82.
fx=$(mkfix "$LIVEHOME" '{"sd":8,"fh":2,"age_min":5,"reqs":[[40,4000000,"claude-fable-5"],[3,100000,"claude-fable-5"]]}')
land_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "a landing under 100% prints the number" "too close to a meter reset"
else
  w1=$(fixf "$fx" landing_s); w2=$(fixf "$fx" need_s)
  case "$land_line$w1" in
    *">100%"*) skipt "a landing under 100% prints the number" "this clock lands over 100" ;;
    *) case "$land_line" in
         *"$w1"*"$w2"*) ok "a landing under 100% prints the fixture's own percentage" ;;
         *) bad "a landing under 100% prints the number" "want $w1/$w2 || $(flat "$land_line")" ;;
       esac ;;
  esac
fi


# The reset the app SAW LATE: sd fell 100 -> 40, which passes LIVE_DROP, but the meter did
# not land on zero. Spend since that anchor bought (sd - 40) points, not sd of them, and
# dividing by the current reading priced 42 points of movement as 82 -- roughly half the
# true $/pt, which halves the headroom and fires the lockout warning spuriously. Every
# other fixture world anchors at 0, where the two are identical, so only this one can tell.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"anchor_sd":40,"reqs":[[40,20000000,"claude-fable-5"],[3,1000000,"claude-fable-5"]]}')
part_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "a reset the app saw late is differenced, not divided" "too close to a meter reset"
else
  w1=$(fixf "$fx" rate_s); w2=$(fixf "$fx" left_s)
  case "$part_line" in
    *"$w1"*"$w2"*) ok "an anchor the meter did not zero at is DIFFERENCED (sd - anchor_sd)" ;;
    *) bad "an anchor above zero is differenced, not divided by the current reading" \
          "want $w1/$w2 || $(flat "$part_line")" ;;
  esac
fi

# --- a range reads low-to-high, and `landing` is the end that falls the other way -------
# The two ends of every live figure are "the anchor's spend" and "the anchor's spend plus
# the reset gap", and `landing` is monotonically DECREASING in that: more spend attributed
# to the anchor means a higher $/pt, which buys fewer points per hour. So the one figure
# whose range could print backwards did, as "lands 43-40%". Needs a world with BOTH a gap
# and a landing under 100, which no other case in this file builds.
#
# THE CLOCK CANNOT SKIP THESE TWO, and until they existed it skipped the only assertion
# there was. The fixture world below needs a landing under 100 at BOTH ends, and
# `landing_lo = pct_now + burn_3h * h / rate` crosses 100 at h = 30.6 there -- so for 137
# of a meter week's 168 hours the case reported SKIP and the fix was asserted by nothing.
# The fixture cannot be made clock-independent either: every request it writes lands within
# the last three hours, so burn_3h is at least a third of the spend that bought the meter's
# movement, and extrapolating that over a full week's 168 hours always exceeds 100 unless
# the meter moved less than ~1.6 points -- which is the provisional world, not this one.
# So the property is pinned at the two levels that have no clock in them at all: the range
# formatter itself, and a pace() run over a FIXED now.
got=$(pymod "
p = dict(source='live', sd=8.0, sample_at='12:00Z', sample_age_min=5.0, pct_now=8.0,
         fh=2.0, spend=100.0, spend_hi=110.0, anchor_label='the reset', fable=100.0,
         fable_hi=110.0, rate=6.25, rate_hi=6.875, provisional=False, moved=8.0,
         pts_left=91.0, usd_left=570.0, usd_left_hi=628.0, hours_to_reset=6.0,
         burn_1h=5.0, burn_3h=20.0, landing=46.0, landing_hi=43.0,
         need_per_hour=95.0, need_per_hour_hi=105.0, fable_reading=None)
print('%s | %s' % (up._rng(46.0, 43.0, '{:,.0f}'),
                   [q for q in up.fmt(p).split(' · ') if q.startswith('→')][0]))" 2>&1)
[ "$got" = "43-46 | → lands 43-46%" ] \
  && ok "a descending pair of ends still prints low-to-high, in _rng and in the line it reaches" \
  || bad "a descending pair of ends prints low-to-high" "got=$(flat "$got")"

# ...and end to end through pace() on a fixed `now`, because the formatter being right is
# not the same claim as the two ends arriving in the order the defect produced: `landing`
# 28.0 with `landing_hi` 26.2, a range that reads backwards unless someone orders it.
got=$(pymod "
import json, shutil
tmp = pathlib.Path(sys.argv[3]); root = tmp / 'fixnow'
shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT = root; up.HIST = tmp; up.CACHE = tmp / 'fixnow_c.json'
up.STATE = tmp / 'fixnow_s.json'; up.READINGS = tmp / 'no-readings.md'
# A Wednesday six hours before its own reset: hours_to_reset is 6.0 by construction, so
# nothing in this world depends on when the suite runs.
close = up.week_bounds(up.week_close(
    up.datetime(2026, 9, 9, 12, 0, tzinfo=up.timezone.utc)))[1]
now = close.astimezone(up.timezone.utc) - up.timedelta(hours=6)
now_ms = now.timestamp() * 1000
a = now_ms - 120 * 60_000                     # the reset
samp = a + 60 * 60_000                        # the sample, an hour into the period
def rec(i, ms, tok):
    return json.dumps({'type': 'assistant', 'timestamp':
        up.datetime.fromtimestamp(ms / 1000, up.timezone.utc).isoformat()
          .replace('+00:00', 'Z'),
        'message': {'id': 'r%d' % i, 'model': 'claude-fable-5',
                    'usage': {'output_tokens': tok}}}, separators=(',', ':'))
(root / 't.jsonl').write_text('\n'.join([
    rec(0, a - 150_000, 100_000),             # \$5 inside the reset gap -> a range at all
    rec(1, a + 10 * 60_000, 1_000_000),       # \$50 before the sample  -> the rate
    rec(2, now_ms - 3 * 60_000, 100_000)]) + '\n')   # \$5 after it     -> the carry
up._plan_raw = lambda: [(a - 300_000, 100.0, 40.0), (a, 0.0, 0.0), (samp, 8.0, 2.0)]
p = up.pace(now=now)
print('%.1f %.1f | %s' % (p['landing'], p['landing_hi'],
      [q for q in up.fmt(p).split(' · ') if q.startswith('→')][0]))" "$TMP" 2>&1)
[ "$got" = "28.0 26.2 | → lands 26-28%" ] \
  && ok "pace() on a fixed now produces a descending pair and prints it ascending" \
  || bad "pace() on a fixed now prints its descending landing range low-to-high" \
        "got=$(flat "$got")"

# The same property once more through the real CLI and a real HOME, which is the only
# version of it a user sees -- and the one the clock can refuse to build.
fx=$(mkfix "$LIVEHOME" '{"sd":8,"fh":2,"age_min":5,"gap_n":1,"gap_tok":400000,"reqs":[[40,4000000,"claude-fable-5"],[3,100000,"claude-fable-5"]]}')
rng_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ] || [ "$(fixf "$fx" landing_rng_ok)" != "True" ]; then
  skipt "the landing range prints low-to-high (via the CLI)" "this clock does not build a sub-100 landing range"
else
  want=$(fixf "$fx" landing_rng_s)
  case "$rng_line" in
    *"$want"*) ok "the landing range prints low-to-high, not descending" ;;
    *) bad "the landing range prints low-to-high" "want $want || $(flat "$rng_line")" ;;
  esac
fi

# --- the first hour after a reset: one point of movement is not a calibrated rate -------
# The meter reads an integer percentage, so at `moved == 1` the rate is a single rounded
# point -- the true movement is anywhere in [0.5, 1.5), so the rate is uncertain by a factor
# of three before any question of whether the first points of a period cost what the rest
# do. pct_now, pts_left, usd_left, hours_to_wall and landing are all built on it, and
# hours_to_wall is the only input to the lockout warning. So below MIN_MOVED the meter is
# NOT carried forward, the line says the rate is provisional and how far the meter moved,
# and the warning is withheld. This world is every session started within an hour of a
# Wednesday reset.
#
# The world is chosen so that the GATE is what withholds the warning, and not the
# arithmetic: a small pre-sample spend ($5, so the one point of movement prices at $5/pt)
# and a large burst after it ($150 in the last hour). Ungated, the meter carries forward to
# ~31%, the headroom prices at $345 and the wall lands 2.3h out against a reset 12h away --
# so warning (a) fires. Gated, it is withheld. The previous world's wall was 49h against a
# 6.2h threshold, so `lost=False` held whether the gate existed or not and deleting the
# gate left that assertion green; the fixture now computes the ungated world too and the
# case SKIPs rather than asserting nothing.
fx=$(mkfix "$LIVEHOME" '{"sd":1,"fh":1,"age_min":5,"reqs":[[40,100000,"claude-fable-5"],[3,3000000,"claude-fable-5"]]}')
prov_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "a one-point rate is provisional and does not extrapolate" "too close to a meter reset"
elif [ "$(fixf "$fx" gate_matters)" != "True" ]; then
  skipt "a one-point rate is provisional and does not extrapolate" \
        "this clock is too near the reset for the ungated world to warn, so lost=False would prove nothing"
else
  w1=$(fixf "$fx" prov_s)
  got=$(HOME="$LIVEHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("prov=%s carried=%s lost=%s" % (
    p.get("provisional"), abs(p["pct_now"] - p["sd"]) < 1e-9,
    any("rest of the week is lost" in m for m in p["warnings"])))')
  case "$prov_line" in *"$w1"*) mark=named ;; *) mark="unnamed(want $w1)" ;; esac
  { [ "$got" = "prov=True carried=True lost=False" ] && [ "$mark" = named ]; } \
    && ok "a one-point rate is provisional: the meter is not carried forward, the line says so, and nothing claims the week is lost" \
    || bad "a one-point rate is provisional and does not extrapolate" \
          "got=$got mark=$mark || $(flat "$prov_line")"
fi

# ...and the gate is a threshold, so the other side of it is asserted too: a meter that HAS
# moved (every other world in this section moves 42 or more) extrapolates and is not marked.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"reqs":[[40,20000000,"claude-fable-5"],[3,1000000,"claude-fable-5"]]}')
moved_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
got=$(HOME="$LIVEHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("prov=%s carried=%s" % (p.get("provisional"), p["pct_now"] > p["sd"]))')
case "$moved_line$got" in
  *PROVISIONAL*) bad "a meter that has moved is not marked provisional" "$(flat "$moved_line")" ;;
  *"prov=False carried=True"*) ok "a meter that has moved past MIN_MOVED extrapolates and is not marked" ;;
  *) bad "a meter that has moved past MIN_MOVED extrapolates" "got=$(flat "$got")" ;;
esac

# --------- no rate at all: the line must say WHY, not print four question marks ---------
# The meter reads an integer, so between two of its points there is nothing to divide by:
# `moved == 0` and the rate is None. Everything built on it then degraded to "?" --
# "?/pt · 100 pts ≈ ? left · → lands ?%" -- which says nothing about whether to wait, to
# open /usage, or to distrust the tool. The fixture builder cannot make this world (its own
# arithmetic divides by `moved`), so the sample file is written directly: a reset the app
# saw at 40, and the newest sample still reading 40.
FLATHOME=$TMP/flathome
mkdir -p "$FLATHOME/.claude/projects/p" "$FLATHOME/Library/Application Support/Claude"
built=$("$PY" - "$SUT" "$FLATHOME" <<'FLATEOF'
import importlib.util, json, pathlib, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("up", sys.argv[1])
up = importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
home = pathlib.Path(sys.argv[2])
now = datetime.now(timezone.utc); now_ms = now.timestamp() * 1000
open_ms = up.week_bounds(up.week_close(now))[0].astimezone(timezone.utc).timestamp() * 1000
a = max(now_ms - 90 * 60_000, open_ms + 60_000)     # the reset, seen late at 40%
if now_ms - a < 4 * 60_000:
    print("skip"); raise SystemExit(0)
(home / "Library" / "Application Support" / "Claude" / "plan-usage-history.json").write_text(
    json.dumps({"version": 2, "samples": [
        {"t": int(a - 300_000), "u": {"sd": 100, "fh": 40}},
        {"t": int(a), "u": {"sd": 40, "fh": 4}},
        {"t": int((a + now_ms) / 2), "u": {"sd": 40, "fh": 4}}]}))   # ...and it has not moved
# real spend since the anchor, so the missing rate is the meter's fault and not the ledger's
mid = (a + now_ms) / 2
(home / ".claude" / "projects" / "p" / "t.jsonl").write_text("\n".join(
    json.dumps({"type": "assistant", "timestamp":
                datetime.fromtimestamp((mid + i * 1000) / 1000, timezone.utc)
                .isoformat().replace("+00:00", "Z"),
                "message": {"id": "z%d" % i, "model": "claude-fable-5",
                            "usage": {"output_tokens": 400_000}}}, separators=(",", ":"))
    for i in range(3)) + "\n")
print("built")
FLATEOF
)
if [ "$built" != "built" ]; then
  skipt "a missing rate names its cause instead of printing ?" "too close to a meter reset"
else
  flat_line=$(HOME="$FLATHOME" "$PY" "$SUT" --oneline 2>&1)
  got=$(HOME="$FLATHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("%s | rate=%s | %s" % (p["source"], p["rate"], p["rate_reason"]))')
  case "$got:$flat_line" in
    "live | rate=None | the meter has not moved since the reset (still 40%)":*"?"*)
       bad "a missing rate names its cause instead of printing ?" \
           "a bare ? survives: $(flat "$flat_line")" ;;
    "live | rate=None | the meter has not moved since the reset (still 40%)":*"no \$/pt yet — the meter has not moved since the reset (still 40%)"*)
       ok "with no rate the line names the cause and prints no bare ? fields" ;;
    *) bad "a missing rate names its cause instead of printing ?" "got=$got || $(flat "$flat_line")" ;;
  esac
fi

# --- ...and the reason must be the RIGHT one, which the world above cannot show --------
# The case above has spend and a meter that did not move, so it only ever exercises one of
# the two branches. The other two worlds are the common ones and both were mis-worded:
#   - neither spend nor movement (a session opening on a fresh week) satisfies BOTH
#     conditions, and with movement tested first "no spend recorded" was unreachable;
#   - the DERIVED path has no meter to have moved -- its percentage is `100 * spend / cap`
#     -- so any sentence about "the meter" there describes a reading never taken.
# Asserted as a function first, because all three branches are reachable in one call each
# and only two of them can be built as a world.
got=$(pymod "
d = lambda **kw: up.derive(**dict({'pct': 0.0, 'anchor_sd': 0.0, 'spend_at_pct': 0.0,
                                   'spend_since': 0.0, 'burn_1h': 0.0, 'burn_3h': 0.0,
                                   'hours_to_reset': 10.0}, **kw))['rate_reason']
print('%s | %s | %s' % (
    d(),                                       # no spend and no movement: BOTH conditions
    d(spend_at_pct=12.0),                      # a real meter sitting on one integer
    d(spend_at_pct=12.0, has_meter=False)))    # ...and a path with no meter at all
" 2>&1)
want="no spend recorded since the reset | the meter has not moved since the reset (still 0%) | the derived percentage is still 0%, so there is nothing to divide by"
[ "$got" = "$want" ] \
  && ok "the missing-rate reason names the missing numerator first, and never names a meter the path does not have" \
  || bad "the missing-rate reason is the right one for each of its three worlds" \
        "got=$(flat "$got") want=$(flat "$want")"

# Both halves as WORLDS, since the wording is what a session actually reads.
# (a) the derived path with nothing behind it: no sample file, no transcripts. This is a
# fresh week on a machine with no desktop app, and it printed "the meter has not moved
# since the reset (still 0%)" -- a meter reading, on the path defined by having none.
EMPTYHOME=$TMP/emptyhome
rm -rf "$EMPTYHOME"; mkdir -p "$EMPTYHOME/.claude/projects/p"
e_line=$(HOME="$EMPTYHOME" "$PY" "$SUT" --oneline 2>&1)
got=$(HOME="$EMPTYHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("%s | rate=%s | %s" % (p["source"], p["rate"], p["rate_reason"]))')
case "$got:$e_line" in
  *"meter has not moved"*)
     bad "the derived path does not explain a missing rate with a meter" \
         "got=$got || $(flat "$e_line")" ;;
  "derived | rate=None | no spend recorded since the reset":*"no \$/pt yet — no spend recorded since the reset"*)
     ok "the derived path with no spend says so, and says nothing about a meter" ;;
  *) bad "the derived path with no spend says so" "got=$got || $(flat "$e_line")" ;;
esac

# (b) the LIVE path with a real reading and no spend at all: the meter is genuinely flat
# AND there is no numerator, so both conditions hold here too and the branch order decides
# what is printed. The missing spend is the honest answer -- there is nothing to divide,
# whatever the meter did -- and it is the one the reader can act on.
ZEROHOME=$TMP/zerohome
rm -rf "$ZEROHOME"
mkdir -p "$ZEROHOME/.claude/projects/p" "$ZEROHOME/Library/Application Support/Claude"
built=$("$PY" - "$SUT" "$ZEROHOME" <<'ZEROEOF'
import importlib.util, json, pathlib, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("up", sys.argv[1])
up = importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
home = pathlib.Path(sys.argv[2])
now_ms = datetime.now(timezone.utc).timestamp() * 1000
open_ms = up.week_bounds(up.week_close(datetime.now(timezone.utc)))[0] \
            .astimezone(timezone.utc).timestamp() * 1000
a = max(now_ms - 90 * 60_000, open_ms + 60_000)      # the reset, seen late at 40%
if now_ms - a < 4 * 60_000:
    print("skip"); raise SystemExit(0)
(home / "Library" / "Application Support" / "Claude" / "plan-usage-history.json").write_text(
    json.dumps({"version": 2, "samples": [
        {"t": int(a - 300_000), "u": {"sd": 100, "fh": 40}},
        {"t": int(a), "u": {"sd": 40, "fh": 4}},
        {"t": int((a + now_ms) / 2), "u": {"sd": 40, "fh": 4}}]}))
(home / ".claude" / "projects" / "p" / "t.jsonl").write_text("")   # ...and no spend at all
print("built")
ZEROEOF
)
if [ "$built" != "built" ]; then
  skipt "a live reading with no spend behind it names the missing spend" "too close to a meter reset"
else
  z_line=$(HOME="$ZEROHOME" "$PY" "$SUT" --oneline 2>&1)
  got=$(HOME="$ZEROHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("%s | sd=%s | rate=%s | %s" % (p["source"], p["sd"], p["rate"], p["rate_reason"]))')
  case "$got" in
    "live | sd=40.0 | rate=None | no spend recorded since the reset")
       ok "a live meter with no spend behind it reports the missing spend, not the flat meter" ;;
    *) bad "a live reading with no spend behind it names the missing spend" \
          "got=$(flat "$got") || $(flat "$z_line")" ;;
  esac
fi

# ------ a sample from BEFORE this meter period is not a reading of this meter -------
# The deterministic shape: after every Wednesday 15:59 PT reset the newest persisted
# sample is still the PRIOR week's, until the app's next /usage poll -- 15 to 60 minutes
# normally, and the whole of any closed-laptop gap (the record has a 29.7h one). Pairing
# that ~95% with the new week's near-zero spend collapsed the rate, collapsed the
# headroom, put the wall minutes away and made --hook inject "the rest of the week is
# lost" into an unattended session. `stale` was a display flag and never disqualified
# anything, so nothing stopped it.
PREHOME=$TMP/prehome
mkdir -p "$PREHOME/.claude/projects/p" "$PREHOME/Library/Application Support/Claude"
"$PY" - "$SUT" "$PREHOME" <<'PREEOF'
import importlib.util, json, pathlib, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("up", sys.argv[1])
up = importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
home = pathlib.Path(sys.argv[2])
now = datetime.now(timezone.utc); now_ms = now.timestamp() * 1000
open_ms = up.week_bounds(up.week_close(now))[0].astimezone(timezone.utc).timestamp() * 1000
# the newest sample is two hours BEFORE the week opened, reading the old week's 95%
(home / "Library" / "Application Support" / "Claude" / "plan-usage-history.json").write_text(
    json.dumps({"version": 2, "samples": [
        {"t": int(open_ms - 3 * 3600_000), "u": {"sd": 94, "fh": 30}},
        {"t": int(open_ms - 2 * 3600_000), "u": {"sd": 95, "fh": 31}}]}))
# ...and there is real in-week fable spend, so the live path had something to divide
lines = [json.dumps({"type": "assistant", "timestamp":
         datetime.fromtimestamp((now_ms - (20 - i) * 60_000) / 1000, timezone.utc)
         .isoformat().replace("+00:00", "Z"),
         "message": {"id": "p%d" % i, "model": "claude-fable-5",
                     "usage": {"output_tokens": 800_000}}}, separators=(",", ":"))
         for i in range(15)]
(home / ".claude" / "projects" / "p" / "t.jsonl").write_text("\n".join(lines) + "\n")
PREEOF
pre_line=$(HOME="$PREHOME" "$PY" "$SUT" --oneline 2>&1)
case "$pre_line" in
  *"derived — newest sample predates this meter week"*)
     ok "a sample older than the meter period is refused as the live reading, and says why" ;;
  *) bad "a pre-period sample is refused as the live reading" "$(flat "$pre_line")" ;;
esac
# The refusal NAMES the percentage it refused -- that is the point of saying why -- so the
# property is positional: the meter field is the first thing on the line, and a refused
# sample must not be sitting in it.
case "$pre_line" in
  "sd "*) bad "the refused sample's percentage is not printed as the meter" "$(flat "$pre_line")" ;;
  *) ok "the refused sample's percentage is not printed as the meter" ;;
esac
# and the CONSEQUENCE, which is the reason this matters: the headroom must not be the five
# points the old week had left. The derived cap is in the thousands and the spend is $600,
# so anything under 50 points left means the pre-period sample still reached the arithmetic.
got=$(HOME="$PREHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("source=%s sd=%s roomy=%s" % (p["source"], p["sd"], p["pts_left"] > 50))')
[ "$got" = "source=derived sd=None roomy=True" ] \
  && ok "the headroom after refusing a pre-period sample is the week's, not the old week's" \
  || bad "the headroom after refusing a pre-period sample is this week's" "got=$(flat "$got")"

# ------- the sample and the anchor are two facts about ONE snapshot of the file -------
# The live path compares them (`samp["t"] < anchor_ms` refuses a sample from an older
# meter period), and the file is written at every /usage poll rather than on a clock. Read
# twice, a write can land between the reads and the comparison is then between two
# different files. The damaging direction is the one asserted here: the FIRST read supplies
# the sample and the SECOND supplies an anchor from a reset the first did not contain, so a
# good live sample is refused as pre-period and the readout drops silently to `derived`.
got=$(pymod "
tmp = pathlib.Path(sys.argv[3])
up.ROOT = tmp / 'rawroot'; up.ROOT.mkdir(parents=True, exist_ok=True)
up.HIST = tmp; up.CACHE = tmp / 'rawcache.json'; up.STATE = tmp / 'rawstate.json'
up.READINGS = tmp / 'no-readings.md'
now_ms = up.datetime.now(up.timezone.utc).timestamp() * 1000
open_ms = up.week_bounds(up.week_close(up.datetime.now(up.timezone.utc)))[0] \
             .astimezone(up.timezone.utc).timestamp() * 1000
a = max(now_ms - 90 * 60_000, open_ms + 60_000)     # the reset the meter actually had
s = a + 30 * 60_000                                 # ...and a sample well after it
A = [(a - 300_000, 100.0, 40.0), (a, 0.0, 0.0), (s, 60.0, 8.0)]
# the app's NEXT write: a further reset, recorded after the snapshot above was taken
B = A + [(s + 60_000, 100.0, 40.0), (s + 120_000, 0.0, 0.0)]
snaps, calls = [list(A), list(B)], []
def fake():
    calls.append(1)
    return snaps.pop(0) if snaps else list(B)
up._plan_raw = fake
p = up.pace()
print('%s %s reads=%d' % (p['source'], p['sd'], len(calls)))" "$TMP")
[ "$got" = "live 60.0 reads=1" ] \
  && ok "the live path reads the sample file once, so the sample and the anchor agree" \
  || bad "the live path reads the sample file once" "got=$(flat "$got")"

# ...and the OTHER side of that guard, which nothing pinned: a sample taken shortly AFTER
# the anchor is a reading OF this meter period and must be accepted, however old it is. The
# refusal above was the only tested side, so an over-strict guard -- `samp["t"] < anchor_ms
# + 3_600_000`, refusing anything inside the first hour of a period -- left the suite fully
# green while silently dropping the readout to `derived` for the first hour of every week,
# which is precisely the stretch the provisional-rate case above is also about. The sample
# here lands 10 minutes after the anchor and is 110 minutes old, so it is accepted AND
# flagged stale: the two are independent, and age alone never disqualifies a reading.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":110,"reqs":[[115,20000000,"claude-fable-5"],[3,1000000,"claude-fable-5"]]}')
post_line=$(HOME="$LIVEHOME" "$PY" "$SUT" --oneline 2>&1)
if [ "$(fixf "$fx" usable)" != "True" ]; then
  skipt "a sample just after the anchor is accepted as live" "too close to a meter reset"
else
  got=$(HOME="$LIVEHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json, sys
p = json.load(sys.stdin)
print("source=%s sd=%s stale=%s age=%d rejected=%s" % (
    p["source"], p["sd"], p["stale"], round(p["sample_age_min"]), p["live_rejected"]))')
  w1=$(fixf "$fx" rate_s)
  case "$got:$post_line" in
    "source=live sd=82.0 stale=True age=110 rejected=None":*"$w1"*)
       ok "a sample 10 minutes after the anchor is accepted as live (and flagged stale, which is a different claim)" ;;
    *) bad "a sample just after the anchor is accepted as live" "got=$got want rate $w1 || $(flat "$post_line")" ;;
  esac
fi

# ---------------- observed_anchor, directly: nothing named it before ----------------
# The PR body claims a fix here -- a drop counts when its LATER sample is in-week, because
# the scheduled reset lands BETWEEN two samples -- and re-introducing that bug left the
# suite green: the fixture cannot place the earlier sample before the week open. It takes
# an injectable `samples`, so test it as a function.
O=1000000000000
got=$(pymod "
o = $O
# the ordinary scheduled reset: the earlier sample sits BEFORE the week open
a = up.observed_anchor(o, [(o - 400_000, 100.0, 1.0), (o + 600_000, 0.0, 0.0)])
# no drop at all since the boundary -> the boundary IS the zero, and anchor_sd is 0
b = up.observed_anchor(o, [(o + 60_000, 40.0, 1.0), (o + 120_000, 55.0, 2.0)])
# a drop that does NOT land on zero: anchor_sd carries the 40 so the caller can difference
c = up.observed_anchor(o, [(o + 60_000, 100.0, 1.0), (o + 120_000, 40.0, 2.0)])
# a fall smaller than LIVE_DROP is noise, not a reset
d = up.observed_anchor(o, [(o + 60_000, 55.0, 1.0), (o + 120_000, 45.0, 2.0)])
print('%d %.0f | %d %.0f %s | %d %.0f | %d %.0f' % (
    a[0] - o, a[2], b[0] - o, b[2], b[1] is None, c[0] - o, c[2], d[0] - o, d[2]))")
[ "$got" = "600000 0 | 0 0 True | 120000 40 | 0 0" ] \
  && ok "observed_anchor: the reset between samples, the no-drop fallback, and anchor_sd" \
  || bad "observed_anchor handles its four cases" "got=$(flat "$got")"

# And with no sample file at all -- a headless or non-desktop machine -- the line must say
# the percentage is derived rather than presenting it as the meter.
NOSAMP=$TMP/nosamplehome
mkfix "$NOSAMP" '{"sd":82,"reqs":[[40,20000000,"claude-fable-5"],[3,1000000,"claude-fable-5"]]}' >/dev/null
rm -rf "$NOSAMP/Library"
d_line=$(HOME="$NOSAMP" "$PY" "$SUT" --oneline 2>&1)
case "$d_line" in
  *"derived — no live sample"*"of cap"*) ok "with no sample file the line says derived and names the cap it used" ;;
  *) bad "with no sample file the line says derived" "$(flat "$d_line")" ;;
esac
case "$d_line" in
  *"sd "*) bad "the derived line claims no live percentage" "$(flat "$d_line")" ;;
  *) ok "the derived line claims no live percentage" ;;
esac

# The cached --calibrate median must not reach the pacing path at ALL. It is a median
# ACROSS meter weeks with no staleness check, and it short-circuited resolve_cap before
# both zero-point-independent methods: divided into this week's spend it printed "96% of
# cap | NEAR CAP" while the live meter read 79. It is still the right answer to the
# question --caps asks, so the assertion is two-sided -- absent from the readout, present
# in --caps.
mkfix "$NOSAMP" '{"sd":82,"reqs":[[40,20000000,"claude-fable-5"],[3,1000000,"claude-fable-5"]]}' >/dev/null
rm -rf "$NOSAMP/Library"
mkdir -p "$NOSAMP/.claude/usage-history"
printf '{"all": 99999.0, "periods": 6, "r2": 0.99, "at": "2020-01-01T00:00"}'   > "$NOSAMP/.claude/usage-history/pace-calibration.json"
d_line=$(HOME="$NOSAMP" "$PY" "$SUT" --oneline 2>&1)
case "$d_line" in
  *99,999*) bad "the pacing path ignores the cached calibrate median" "$(flat "$d_line")" ;;
  *) ok "the pacing path ignores the cached calibrate median, however stale" ;;
esac
# ...and resolve_cap still serves it to the caller that WANTS a cross-week cap, so the
# distinction is in the argument and not in a deleted capability.
mk 20 20 600.00 600.00 1000000000 1000000000 100000000 100000000 \
   60 60 1800.00 1800.00 3000000000 3000000000 300000000 300000000
printf '{"all": 99999.0, "periods": 6, "r2": 0.99, "at": "2020-01-01T00:00"}' > "$TMP/calib.json"
got=$(pymod "
up.READINGS=pathlib.Path(sys.argv[3]); up.CALIB=pathlib.Path(sys.argv[4])
up.PLAN_SAMPLES=pathlib.Path(sys.argv[3]+'.absent')
print('%.0f %.0f' % (up.resolve_cap('all', up.read_readings())[0],
                     up.resolve_cap('all', up.read_readings(), use_cached=False)[0]))" \
  "$R" "$TMP/calib.json" 2>&1)
[ "$got" = "99999 3000" ] \
  && ok "resolve_cap serves the cached median on request and the pair without it" \
  || bad "resolve_cap serves the cached median on request and the pair without it" "got=$(flat "$got")"

# --json must carry the live fields, not only the formatted line: the hook consumes the
# payload and the previous payload had no live percentage in it at all.
fx=$(mkfix "$LIVEHOME" '{"sd":82,"fh":8,"age_min":5,"reqs":[[95,20000000,"claude-fable-5"],[80,10000000,"claude-fable-5"],[40,6000000,"claude-fable-5"],[30,10000000,"claude-sonnet-4-5"],[3,1000000,"claude-fable-5"]]}')
got=$(HOME="$LIVEHOME" "$PY" "$SUT" --json 2>&1 | "$PY" -c '
import json,sys
p=json.load(sys.stdin)
need=["sd","fh","sample_at","sample_age_min","stale","rate","pts_left","usd_left",
      "hours_to_reset","burn_1h","burn_3h","hours_to_wall","landing","warnings","source"]
print("MISSING",[k for k in need if k not in p] or "none", p.get("source"), p.get("sd"))')
[ "$got" = "MISSING none live 82.0" ] \
  && ok "--json carries the live percentage and every derived figure" \
  || bad "--json carries the live percentage and every derived figure" "got=$(flat "$got")"

# ------------------- 20. A RE-WRITTEN USAGE BLOCK SUPERSEDES ITS PARTIAL (#256)
# Claude Code writes ONE assistant message to the transcript twice under a single
# requestId: a partial record (output_tokens 2) when the turn starts, and the complete
# one minutes later. The dedup kept the FIRST, so every dollar this file ever printed was
# the stub's. Measured on this machine 2026-09-16: 10,696 of 21,285 keys superseded in the
# live meter week, $2,590.81 first-occurrence against $2,854.45 -- 10.2% low (9.0% when
# #256 was filed hours earlier, over 20,088 requests; the ratio grows with the week).
#
# The fixture below is the real pair's shape: the two records differ ONLY in
# output_tokens, they share their (message id, requestId), they land in DIFFERENT minutes,
# and the output token count is tuned so the complete record costs 1.0987x the partial --
# inside the measured range, so "moves by ~10%" asserts a number that was measured rather
# than a round one. Every case here fails on the first-occurrence policy.
FIX=$TMP/supersede
mkdir -p "$FIX"
cat > "$FIX/fixture.py" <<'FIXPY'
# Shared fixture: imported by each case with exec(open(...).read()).
PARTIAL = {"input_tokens": 4, "cache_read_input_tokens": 400000, "output_tokens": 2}
COMPLETE = {"input_tokens": 4, "cache_read_input_tokens": 400000, "output_tokens": 792}
MODEL = "claude-opus-5"

def iso(ms):
    return up.datetime.fromtimestamp(ms / 1000, up.timezone.utc).isoformat().replace("+00:00", "Z")

def rec(ms, usage, mid="m1", req="r1"):
    return up.json.dumps({"type": "assistant", "timestamp": iso(ms), "requestId": req,
                          "message": {"id": mid, "model": MODEL, "usage": usage}},
                         separators=(",", ":"))

A = up.cost_usd(PARTIAL, MODEL)     # what the old policy billed: the stub
C = up.cost_usd(COMPLETE, MODEL)    # what the meter actually bills
FIXPY

# (a) One key, two records in one file: the week total is the COMPLETE cost, once.
got=$("$PY" - "$SUT" "$FIX" <<'PY_A' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"a"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"a.json"
T=1788000000000
WK=up.week_close(up.datetime.fromtimestamp(T/1000, up.timezone.utc))
(root/"t.jsonl").write_text(rec(T, PARTIAL)+"\n"+rec(T+11*60000, COMPLETE)+"\n")
tot=up.scan(WK, force=True)
print("all=%.6f C=%.6f A=%.6f ratio=%.4f opus=%.6f main=%.6f" % (
    tot["all"], C, A, C/A, tot["opus"], tot["main"]),
    "COMPLETE" if abs(tot["all"]-C) < 1e-9 else ("STUB" if abs(tot["all"]-A) < 1e-9 else "OTHER"),
    "SPLITS" if abs(tot["opus"]-C) < 1e-9 and abs(tot["main"]-C) < 1e-9 else "SPLITS-WRONG",
    "9PCT" if 1.09 < C/A < 1.11 else "FIXTURE-OFF")
PY_A
)
case "$got" in
  *"COMPLETE SPLITS 9PCT"*) ok "two records for one key bill the COMPLETE cost, once, in every bucket" ;;
  *) bad "two records for one key bill the COMPLETE cost, once" "$(flat "$got")" ;;
esac

# (b) A later record that is SMALLER changes nothing. This is what separates "the greatest
#     cost wins" from "the last one wins": scan order is rglob order, a request lands in
#     more than one transcript, and an incremental scan sees the halves in separate passes,
#     so last-seen is not last-written.
got=$("$PY" - "$SUT" "$FIX" <<'PY_B' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"b"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"b.json"
T=1788000000000
WK=up.week_close(up.datetime.fromtimestamp(T/1000, up.timezone.utc))
f=root/"t.jsonl"
f.write_text(rec(T, COMPLETE)+"\n")                      # complete first
one=up.scan(WK, force=True)["all"]
f.write_text(rec(T, COMPLETE)+"\n"+rec(T+11*60000, PARTIAL)+"\n")   # stub arrives after
two=up.scan(WK)["all"]                                   # incremental, as it would happen
three=up.scan(WK, force=True)["all"]
print("one=%.6f two=%.6f three=%.6f C=%.6f" % (one, two, three, C),
      "HELD" if abs(two-C) < 1e-9 and abs(three-C) < 1e-9 else "REGRESSED")
PY_B
)
printf '%s' "$got" | grep -q 'HELD' \
  && ok "a smaller later record for the same key changes nothing (max wins, not last)" \
  || bad "a smaller later record for the same key changes nothing" "$(flat "$got")"

# (c) THE CACHE CASE. The two records land in different minutes and, in life, in different
#     scans: the first scan sees only the partial and writes its cost into the cached
#     totals, and the second must take that cost back OUT. Every bucket is compared, not
#     just "all" -- the tier and main/sub splits feed the Fable scope check.
got=$("$PY" - "$SUT" "$FIX" <<'PY_C' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"c"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"c.json"
T=1788000000000
WK=up.week_close(up.datetime.fromtimestamp(T/1000, up.timezone.utc))
f=root/"t.jsonl"
f.write_text(rec(T, PARTIAL)+"\n")
first=dict(up.scan(WK))
with open(f, "a") as fh: fh.write(rec(T+11*60000, COMPLETE)+"\n")   # pure append
second=dict(up.scan(WK))
up.CACHE.unlink()
once=dict(up.scan(WK, force=True))                                  # single-scan truth
same=set(second)==set(once) and all(abs(second[k]-once[k]) < 1e-9 for k in once)
print("first=%.6f second=%.6f once=%.6f C=%.6f keys=%d" % (
    first["all"], second["all"], once["all"], C, len(once)),
    "CONVERGED" if same and abs(second["all"]-C) < 1e-9 else "DIVERGED",
    "STUB-FIRST" if abs(first["all"]-A) < 1e-9 else "?")
PY_C
)
printf '%s' "$got" | grep -q 'CONVERGED STUB-FIRST' \
  && ok "the incremental path converges on the single-scan totals across two scans" \
  || bad "the incremental path converges on the single-scan totals" "$(flat "$got")"

# (d) ...and the cost is billed at the COMPLETE record's minute, which is the minute the
#     meter bills by evidence. This is the half that the week total cannot see: the cap
#     regression and the meter anchor index spend by instant, so keeping the partial put
#     ~10% of every dollar at the wrong minute as well as at the wrong value.
got=$("$PY" - "$SUT" "$FIX" <<'PY_D' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"d"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root
T=1788000000000
(root/"t.jsonl").write_text(rec(T, PARTIAL)+"\n"+rec(T+11*60000, COMPLETE)+"\n")
times, cum, _ = up._cum_events("$")
at = lambda ms: cum[up.bisect.bisect_right(times, ms)]
print("events=%d mid=%.6f after=%.6f C=%.6f" % (len(times), at(T+60000), at(T+12*60000), C),
      "AT-COMPLETE" if len(times)==1 and at(T+60000)==0.0 and abs(at(T+12*60000)-C) < 1e-12
      else "AT-PARTIAL")
PY_D
)
printf '%s' "$got" | grep -q 'AT-COMPLETE' \
  && ok "the spend series bills the request at the complete record's minute, not the stub's" \
  || bad "the spend series bills the request at the complete record's minute" "$(flat "$got")"

# (e) --calibrate's arithmetic moves by that ~10%, in the right direction. Every request in
#     this fixture is written twice, one minute apart, against a meter climbing one point
#     per ten requests: the cap is 1000x a request's cost, so the answer is $1,000*C under
#     supersession and $1,000*A -- 9.9% lower -- under first-occurrence. The real command is
#     then driven end to end, because the cached cap is what the pace check divides by.
got=$("$PY" - "$SUT" "$FIX" <<'PY_E' 2>&1
import contextlib, importlib.util, io, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"e"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"e_c.json"; up.CALIB=fix/"e_k.json"
up.READINGS=fix/"e_r.md"
T=1788000000000
lines=[]
for i in range(400):
    slot=T+i*60000
    lines.append(rec(slot+59000, PARTIAL,  "m%d"%i, "r%d"%i))
    lines.append(rec(slot+61000, COMPLETE, "m%d"%i, "r%d"%i))
(root/"t.jsonl").write_text("\n".join(lines)+"\n")
# Samples at +30s of the minute, so no partial/complete pair straddles one: the expected
# cap is exact, not approximate.
up.PLAN_SAMPLES=fix/"e_p.json"
up.PLAN_SAMPLES.write_text(up.json.dumps({"version":2,
    "samples":[{"t":T+j*600000+30000,"u":{"sd":j}} for j in range(40)]}))
caps=up.sampled_caps()
cap=caps[0][1] if caps else 0.0
out=io.StringIO(); sys.argv=["x","--calibrate"]
with contextlib.redirect_stdout(out): rc=up.main()
k=up.json.loads(up.CALIB.read_text())
print("n=%d cap=%.2f complete=%.2f stub=%.2f moved=%.4f cached=%.2f policy=%s" % (
    len(caps), cap, 1000*C, 1000*A, cap/(1000*A), k.get("all", 0), k.get("policy")),
    "COMPLETE" if abs(cap-1000*C) < 0.01 else "LOW",
    "MOVED-9PCT" if 1.09 < cap/(1000*A) < 1.11 else "UNMOVED",
    "STAMPED" if k.get("policy")==up.COST_POLICY and abs(k.get("all",0)-1000*C) < 0.01 else "UNSTAMPED")
PY_E
)
printf '%s' "$got" | grep -q 'COMPLETE MOVED-9PCT STAMPED' \
  && ok "--calibrate's cap rises with the fixed numerator and is stamped with the policy" \
  || bad "--calibrate's cap rises with the fixed numerator and is stamped" "$(flat "$got")"

# (f) ...and so does a recorded reading, which is where --caps gets its dollars. The row
#     record() appends IS the numerator a cap is implied from, so a reading taken under the
#     old policy understated the cap it implies by the same ~10%.
got=$("$PY" - "$SUT" "$FIX" <<'PY_F' 2>&1
import contextlib, importlib.util, io, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"f"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"f_c.json"; up.CALIB=fix/"f_k.json"
up.READINGS=fix/"f_r.md"; up.PLAN_SAMPLES=fix/"f_absent.json"
now=up.datetime.now().astimezone(); wk=up.week_close(now)
open_ms=up.week_bounds(wk)[0].timestamp()*1000
t=max(open_ms+1000, now.timestamp()*1000-60000)
lines=[]
for i in range(1000):
    lines.append(rec(t, PARTIAL, "m%d"%i, "r%d"%i))
    lines.append(rec(t+1000, COMPLETE, "m%d"%i, "r%d"%i))
(root/"t.jsonl").write_text("\n".join(lines)+"\n")
out=io.StringIO()
with contextlib.redirect_stdout(out): rc=up.record(10.0, 1.0, "fixture")
row=[r for r in up.read_readings() if r["week"]==wk][-1]
caps=up.implied_caps(up.read_readings())["all"]
print("rc=%s recorded=%.2f complete=%.2f stub=%.2f cap=%.2f moved=%.4f" % (
    rc, row["all_at"], 1000*C, 1000*A, caps[0] if caps else 0, row["all_at"]/(1000*A)),
    "COMPLETE" if abs(row["all_at"]-1000*C) < 0.01 else "STUB",
    "CAP" if caps and abs(caps[0]-1000*C*10) < 1.0 else "NOCAP")
PY_F
)
printf '%s' "$got" | grep -q 'COMPLETE CAP' \
  && ok "a recorded reading carries the complete-record total, so the cap it implies moves too" \
  || bad "a recorded reading carries the complete-record total" "$(flat "$got")"

# (g) A cache written under another counting policy must be DISCARDED, not read: trusting
#     its keys keeps the old policy alive for the rest of the week and trusting its totals
#     adds to them. TWO shapes, because they are guarded separately and the second masks
#     the first: a v1 cache whose `seen` is a bare LIST of keys (no per-key cost, so nothing
#     in it can be superseded in place), and one whose `seen` is a perfectly well-formed
#     map written at a version this code does not know. Only the version check rejects the
#     second, and a test using the first alone left removing that check fully green.
got=$("$PY" - "$SUT" "$FIX" <<'PY_G' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"g"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"g_c.json"
T=1788000000000
WK=up.week_close(up.datetime.fromtimestamp(T/1000, up.timezone.utc))
(root/"t.jsonl").write_text(rec(T, PARTIAL)+"\n"+rec(T+11*60000, COMPLETE)+"\n")
key=up.hashlib.md5(b"m1|r1").hexdigest()[:12]
def stale(seen):
    up.CACHE.write_text(up.json.dumps({"week":WK,"files":{},"totals":{"all":999.0},
                                       "seen":seen}))
    tot=up.scan(WK)
    fresh=up.json.loads(up.CACHE.read_text())
    return ("discarded" if abs(tot["all"]-C) < 1e-9 and fresh.get("v")==up.CACHE_V
            else "TRUSTED(%.4f)" % tot["all"])
v1=stale([key])                                       # bare key list: no cost to subtract
other=stale({key: [A, 0, 0.0, T, "opus", 0, 1]})      # well-formed map, unknown version
print("v1=%s other-version=%s C=%.6f" % (v1, other, C),
      "DISCARDED" if v1=="discarded" and other=="discarded" else "TRUSTED")
PY_G
)
printf '%s' "$got" | grep -q 'DISCARDED' \
  && ok "a pre-supersession cache is discarded rather than migrated or added to" \
  || bad "a pre-supersession cache is discarded" "$(flat "$got")"

# (h) A cached entry that cannot be trusted must neither crash the hook nor double-count.
#     Keeping the stub's cost for one key is a bounded error; unpacking garbage in a
#     UserPromptSubmit hook and adding a second copy of a cost are not.
got=$("$PY" - "$SUT" "$FIX" <<'PY_H' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"h"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root; up.HIST=fix; up.CACHE=fix/"h_c.json"
T=1788000000000
WK=up.week_close(up.datetime.fromtimestamp(T/1000, up.timezone.utc))
f=root/"t.jsonl"
f.write_text(rec(T, PARTIAL)+"\n")
up.scan(WK)
c=up.json.loads(up.CACHE.read_text())
key=next(iter(c["seen"]))
c["seen"][key]="corrupt"                      # externally mangled, cannot be subtracted
up.CACHE.write_text(up.json.dumps(c))
with open(f, "a") as fh: fh.write(rec(T+11*60000, COMPLETE)+"\n")
try:
    tot=up.scan(WK); v=tot["all"]
    print("all=%.6f A=%.6f sum=%.6f" % (v, A, A+C),
          "HELD" if abs(v-A) < 1e-9 else ("DOUBLED" if abs(v-(A+C)) < 1e-9 else "OTHER"))
except Exception as e:
    print("CRASH", type(e).__name__, e)
PY_H
)
printf '%s' "$got" | grep -q 'HELD' \
  && ok "an untrustworthy cached entry neither crashes the scan nor double-counts" \
  || bad "an untrustworthy cached entry neither crashes nor double-counts" "$(flat "$got")"

# (i) The meter anchor is DOLLARS, subtracted from a numerator counted under this policy.
#     One cached under the old one is ~10% low and, keyed only by week and period, would have
#     survived the rest of the meter period -- under-correcting a numerator just fixed.
got=$(pymod '
import tempfile
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
base={"week":"2026-09-16","seg":1,"all":100.0,"fable":10.0,"zero":None,"note":"n"}
def probe(extra):
    up.CALIB.write_text(up.json.dumps({"anchor":dict(base, **extra)}))
    return "used" if up._cached_anchor("2026-09-16", 1) else "recomputed"
print(probe({"policy": up.COST_POLICY}), probe({"policy":"supersede-none"}), probe({}))')
[ "$got" = "used recomputed recomputed" ] \
  && ok "an anchor cached under another counting policy is recomputed, not reused" \
  || bad "an anchor cached under another counting policy is recomputed" "got=$(flat "$got")"

# (j) A hand-run --calibrate is a MEASUREMENT with a date on it, so it is disclosed rather
#     than discarded: a cap measured low, divided into a numerator that is no longer low,
#     reads HIGH by the same margin -- a wrong verdict and not merely a wrong dollar figure.
got=$(pymod '
import tempfile
up.CALIB=pathlib.Path(tempfile.mkdtemp())/"k.json"
up.READINGS=up.CALIB.with_name("absent.md")
def basis(extra):
    up.CALIB.write_text(up.json.dumps(dict({"all":2363.0,"periods":6,"r2":0.994}, **extra)))
    return up.resolve_cap("all", [])[1]
old, new = basis({}), basis({"policy": up.COST_POLICY})
print("pre-#256" in old, "WARNING" in old, "pre-#256" in new or "WARNING" in new)')
[ "$got" = "True True False" ] \
  && ok "a cap measured under the old dedup is disclosed in the basis, not silently divided by" \
  || bad "a cap measured under the old dedup is disclosed in the basis" "got=$(flat "$got")"

# (k) The key is claimed only by a record that HAS a usable timestamp. It used to be
#     claimed first: a record with a missing or unparseable timestamp added its key to
#     `seen` and then skipped, so the good duplicate behind it was discarded as
#     already-seen and the request left the spend series entirely. Supersession makes that
#     ordering load-bearing -- the comparator IS the timestamp -- so it is pinned here.
got=$("$PY" - "$SUT" "$FIX" <<'PY_K' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
root=fix/"k"; shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
up.ROOT=root
T=1788000000000
stamped=up.json.loads(rec(T, COMPLETE)); stamped["timestamp"]="not-a-date"
(root/"t.jsonl").write_text(up.json.dumps(stamped, separators=(",",":"))+"\n"
                            +rec(T+60000, COMPLETE)+"\n")
times, cum, _ = up._cum_events("$")
print("events=%d total=%.6f C=%.6f" % (len(times), cum[-1], C),
      "COUNTED" if len(times)==1 and abs(cum[-1]-C) < 1e-12 else "SWALLOWED")
PY_K
)
printf '%s' "$got" | grep -q 'COUNTED' \
  && ok "a timestamp-less record does not swallow its key from the record that has one" \
  || bad "a timestamp-less record does not swallow its key" "$(flat "$got")"

# ------------- 19. THE DISCLOSURE HAS TO REACH THE LINE PEOPLE READ (#256 fix round)
# Section 18 pinned the supersession itself. This section pins the three places the FIRST
# cut of it did not reach: the one-liner and the hook (the disclosure lived in `--caps`
# alone), the append-only readings table (rows carried no policy stamp, so a cap
# differenced across the change reads HIGH -- the direction that silences the check), and
# the week close (remembering a key only when it was in-week made the total depend on scan
# order, and one order re-billed the stub).

# (a) THE ONE-LINER AND THE HOOK. A cap measured under the old dedup reads LOW, so the
#     percentage divided into it reads HIGH -- which is the whole argument for disclosing
#     instead of rejecting. The marker therefore has to appear where the percentage
#     appears: `fmt`'s derived branch prints `all_cap_basis` inline, so whatever
#     `resolve_cap` appends to that string is what reaches the line and, through `fmt(p)`
#     inside the printed block, the hook too. (#255 retired the cached-median verdict --
#     NEAR CAP/AHEAD OF PACE no longer exist -- so this pins the disclosure travelling
#     through the live derived line, not a flipped verdict.)
got=$(pymod '
import argparse, contextlib, io, tempfile
d = pathlib.Path(tempfile.mkdtemp())
up.CALIB = d/"k.json"; up.READINGS = d/"absent.md"; up.STATE = d/"s.json"
def basis(extra):
    up.CALIB.write_text(up.json.dumps(dict({"all":2414.94,"periods":7,"r2":0.997}, **extra)))
    return up.resolve_cap("all", [])
cap, b_old, _ = basis({})
_,   b_new, _ = basis({"policy": up.COST_POLICY})
# A minimal but complete "derived" p: no rate, and a landing that alone trips warning (b)
# ("waste") so the hook actually prints -- hook() is silent unless warnings_for(p) is
# non-empty, and fmt(p) is what it prints THROUGH.
mk = lambda b: {"source":"derived","pct":100.0*0.86*cap/cap,"all_cap":cap,
                "all_cap_basis":b,"spend":0.86*cap,"fable":0.0,"fable_hi":0.0,
                "rate":None,"rate_reason":None,"pts_left":10.0,"hours_to_reset":5.0,
                "burn_1h":0.0,"burn_3h":0.0,"landing":50.0,"anchor_exact":True,
                "anchor":"","sub_fable":0.0,"week":"2026-09-16","now":"x"}
line_old, line_new = up.fmt(mk(b_old)), up.fmt(mk(b_new))
up.pace = lambda *a, **k: mk(b_old)
up.last_model = lambda t: "claude-fable-5"
out = io.StringIO()
sys.stdin = io.StringIO(up.json.dumps({"session_id":"s1","transcript_path":"/x"}))
with contextlib.redirect_stdout(out):
    up.hook(argparse.Namespace(every=1))
hook_out = out.getvalue()
print("ONELINE" if up.STALE_CAP_NOTE in line_old else "oneline-silent",
      "HOOK" if up.STALE_CAP_NOTE in hook_out else "hook-silent",
      "QUIET-WHEN-STAMPED" if up.STALE_CAP_NOTE not in line_new else "always-warns")')
[ "$got" = "ONELINE HOOK QUIET-WHEN-STAMPED" ] \
  && ok "the stale-cap warning reaches the one-liner AND the hook, and goes quiet when stamped" \
  || bad "the stale-cap warning reaches the one-liner and the hook" "got=$(flat "$got")"

# (b) THE FABLE CAP CAN BE DISCLOSED AT ALL. The cached calibration is all-models only, so
#     every Fable cap comes from a reading, a reading pair, or FALLBACK -- and until this
#     round none of those three branches could carry the disclosure. The magnitude is
#     per-meter on purpose: the duplication is sidechain-only and Fable is main-thread
#     only, so the Fable numerator moved 0-5% where all-models moved 3.5-14.4%. One
#     figure for both would overstate the Fable case fivefold.
got=$(pymod '
import tempfile
d = pathlib.Path(tempfile.mkdtemp())
up.CALIB = d/"absent.json"; up.READINGS = d/"absent.md"; up.PLAN_SAMPLES = d/"absent.json"
fb, al = up.resolve_cap("fable", [])[1], up.resolve_cap("all", [])[1]
row = lambda pol: [{"week":"w","at":"t","note":"","policy":pol,"all_pct":50.0,
                    "fable_pct":50.0,"all_at":1000.0,"fable_at":100.0,
                    "all_raw":None,"fable_raw":None,"all_ieq":None,"fable_ieq":None}]
old_row = up.resolve_cap("fable", row(None))[1]
new_row = up.resolve_cap("fable", row(up.COST_POLICY))[1]
print("FB-FALLBACK" if up.STALE_CAP_NOTE in fb and "0-5%" in fb else "fable-undisclosed",
      "ALL-FALLBACK" if up.STALE_CAP_NOTE in al and "3.5-14.4%" in al else "all-undisclosed",
      "OLD-ROW" if up.STALE_CAP_NOTE in old_row else "row-undisclosed",
      "NEW-ROW-QUIET" if up.STALE_CAP_NOTE not in new_row else "row-always-warns")')
[ "$got" = "FB-FALLBACK ALL-FALLBACK OLD-ROW NEW-ROW-QUIET" ] \
  && ok "FALLBACK and the reading-derived branches disclose the policy, at the right magnitude" \
  || bad "FALLBACK and the reading-derived branches disclose the policy" "got=$(flat "$got")"

# (c) THE READINGS TABLE IS APPEND-ONLY AND TRANSCRIPTS GET PRUNED, so a row's numerator
#     can never be recomputed: an unstamped row is permanently unclassifiable. The column
#     has to be in the HEADER too -- the parser resolves by name, so a twelfth field under
#     an eleven-column header is written and never read. The rows already on file are NOT
#     rewritten: an empty cell is the true statement about them, and annotating history is
#     the maintainer's call (#260).
got=$("$PY" - "$SUT" "$TMP" <<'PY_19C' 2>&1
import contextlib, importlib.util, io, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
d=pathlib.Path(sys.argv[2])/"s19c"; shutil.rmtree(d, ignore_errors=True)
root=d/"proj"; root.mkdir(parents=True)
up.ROOT=root; up.HIST=d; up.CACHE=d/"c.json"; up.CALIB=d/"k.json"
up.READINGS=d/"r.md"; up.PLAN_SAMPLES=d/"absent.json"
U={"input_tokens":4,"cache_read_input_tokens":400000,"output_tokens":792}
now=up.datetime.now().astimezone(); wk=up.week_close(now)
t=max(up.week_bounds(wk)[0].timestamp()*1000+1000, now.timestamp()*1000-60000)
iso=up.datetime.fromtimestamp(t/1000, up.timezone.utc).isoformat().replace("+00:00","Z")
(root/"t.jsonl").write_text(up.json.dumps({"type":"assistant","timestamp":iso,
    "requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":U}})+"\n")
OLD=f"| {wk} | {wk}T00:14-07:00 | 79% | 5% | 2317.93 | 237.42 | 1 | 1 | 1 | 1 | old |"
up.READINGS.write_text(
 "| week-close | read at | all% | fable% | all$ | fable$ | all_tok | fable_tok "
 "| all_ieq | fable_ieq | note |\n"
 "|---|---|---|---|---|---|---|---|---|---|---|\n" + OLD + "\n")
with contextlib.redirect_stdout(io.StringIO()): up.record(90.0, 6.0, "after")
with contextlib.redirect_stdout(io.StringIO()): up.record(91.0, 7.0, "again")
lines=[l for l in up.READINGS.read_text().splitlines() if l.startswith("|")]
hdr=[x.strip() for x in lines[0].strip("|").split("|")]
sep=[x.strip() for x in lines[1].strip("|").split("|")]
pols=[r.get("policy") for r in up.read_readings()]
print("hdr_policy=%d sep=%d rows=%d pols=%s old_intact=%s" % (
    hdr.count("policy"), len(sep), len(lines)-2, pols, lines[2]==OLD),
    "STAMPED" if pols==[None, up.COST_POLICY, up.COST_POLICY] else "NO-STAMP",
    "HEADER-ONCE" if hdr.count("policy")==1 and len(sep)==len(hdr) else "HEADER-WRONG",
    "HISTORY-UNTOUCHED" if lines[2]==OLD else "HISTORY-REWRITTEN")
PY_19C
)
printf '%s' "$got" | grep -q 'STAMPED HEADER-ONCE HISTORY-UNTOUCHED' \
  && ok "a recorded row carries the policy stamp; the header gains the column once, history untouched" \
  || bad "a recorded row carries the policy stamp and the header gains the column once" "$(flat "$got")"

# (d) A PAIR THAT STRADDLES THE COUNTING CHANGE IS DROPPED AND NAMED, alongside the reset
#     and cap-multiplier guards -- and this one is the dangerous direction. The later
#     measure absorbs the whole step while the percentage delta does not, so the cap reads
#     HIGH, and a cap too high makes the pace check go QUIET. Numbers are this machine's:
#     the row on file reads 79% / $2,317.93 under the old dedup, and a post-merge row at
#     90% carries $2,890 -- the same week's spend counted the new way (+10.6% measured).
got=$(pymod '
base = {"week":"2026-09-16","note":"","all_raw":None,"fable_raw":None,
        "all_ieq":None,"fable_ieq":None,"fable_pct":5.0,"fable_at":237.42}
a = dict(base, at="2026-09-16T00:14", all_pct=79.0, all_at=2317.93, policy=None)
b = dict(base, at="2026-09-16T05:22", all_pct=90.0, all_at=2890.00,
         fable_pct=6.0, policy=up.COST_POLICY)
up.PLAN_SAMPLES = pathlib.Path("/nonexistent/samples.json")
mixed, notes = up.differential_caps([a, b])
same, _ = up.differential_caps([a, dict(b, policy=None)])
would = 100.0 * (b["all_at"] - a["all_at"]) / (b["all_pct"] - a["all_pct"])
consistent = 100.0 * (b["all_at"]/1.106 - a["all_at"]) / (b["all_pct"] - a["all_pct"])
print("DROPPED" if not mixed["all"] else "KEPT(%.0f)" % mixed["all"][0],
      "NAMED" if any("COUNTED" in n for n in notes) else "SILENT",
      "PAIRS-OTHERWISE" if same["all"] else "DROPPED-ANYWAY",
      "READS-HIGH" if would > 1.9 * consistent else "harmless",
      "would=%.0f consistent=%.0f" % (would, consistent))')
case "$got" in
  "DROPPED NAMED PAIRS-OTHERWISE READS-HIGH"*) ok "a reading pair spanning the counting change is dropped and named ($got)" ;;
  *) bad "a reading pair spanning the counting change is dropped and named" "got=$(flat "$got")" ;;
esac

# (e) THE WEEK CLOSE. Billing at the complete record's minute means a partial inside the
#     week whose completion lands past the close belongs to the NEXT week -- and that has
#     to hold whichever record the scan reaches first, because max-wins is justified by
#     being order-independent. Remembering the key only when it was in-week broke exactly
#     that: in complete-first order the out-of-week record claimed nothing, so the in-week
#     partial looked like a first sighting and was billed at the stub -- the #256 defect,
#     back, from scan order alone. Both orders must give $0 for the week and the complete
#     cost for the next, once.
got=$("$PY" - "$SUT" "$FIX" <<'PY_19E' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
base=fix/"e19"; shutil.rmtree(base, ignore_errors=True); base.mkdir(parents=True)
WK="2026-09-16"
close=up.week_bounds(WK)[1]; close_ms=close.timestamp()*1000
NXT=up.week_close(close+up.timedelta(seconds=1))
t_p, t_c = close_ms-60000, close_ms+6*60000      # 15:58 PT in WK, 16:05 PT in NXT
res={}
for label, lines in (("pf", [rec(t_p, PARTIAL), rec(t_c, COMPLETE)]),
                     ("cf", [rec(t_c, COMPLETE), rec(t_p, PARTIAL)])):
    root=base/label; root.mkdir(parents=True)
    up.ROOT=root; up.HIST=base; up.CACHE=base/(label+".json")
    (root/"t.jsonl").write_text("\n".join(lines)+"\n")
    res[label]=(up.scan(WK, force=True).get("all", 0.0),
                up.scan(NXT, force=True).get("all", 0.0))
print("pf=(%.4f,%.4f) cf=(%.4f,%.4f) A=%.4f C=%.4f" % (
    res["pf"][0], res["pf"][1], res["cf"][0], res["cf"][1], A, C),
    "ORDER-FREE" if res["pf"]==res["cf"] else "ORDER-DEPENDENT",
    "NEXT-WEEK" if all(abs(v[0]) < 1e-9 and abs(v[1]-C) < 1e-9 for v in res.values())
    else ("STUB-BILLED" if any(abs(v[0]-A) < 1e-9 for v in res.values()) else "WRONG"))
PY_19E
)
printf '%s' "$got" | grep -q 'ORDER-FREE NEXT-WEEK' \
  && ok "a pair straddling the week close bills the next week, in either scan order" \
  || bad "a pair straddling the week close bills the next week in either order" "$(flat "$got")"

# (f) ...and remembering out-of-week keys stays BOUNDED. Without a window `seen` would grow
#     from this week's keys to the whole corpus's, and it is written to the cache file on
#     every scan. A record far from the close cannot be the partner of an in-week one: the
#     measured partial-to-complete gap is 2.1s median, 661s at the widest on record.
got=$("$PY" - "$SUT" "$FIX" <<'PY_19F' 2>&1
import importlib.util, pathlib, shutil, sys
spec=importlib.util.spec_from_file_location("up", sys.argv[1])
up=importlib.util.module_from_spec(spec); spec.loader.exec_module(up)
fix=pathlib.Path(sys.argv[2]); exec(open(fix/"fixture.py").read())
base=fix/"f19"; shutil.rmtree(base, ignore_errors=True); root=base/"p"
root.mkdir(parents=True)
up.ROOT=root; up.HIST=base; up.CACHE=base/"c.json"
WK="2026-09-16"
close_ms=up.week_bounds(WK)[1].timestamp()*1000
lines=[rec(close_ms+6*60000, COMPLETE, "near", "near"),             # inside the grace
       rec(close_ms+5*86400000, COMPLETE, "far", "far")]            # five days later
(root/"t.jsonl").write_text("\n".join(lines)+"\n")
up.scan(WK, force=True)
seen=up.json.loads(up.CACHE.read_text())["seen"]
near=up.hashlib.md5(b"near|near").hexdigest()[:12]
far=up.hashlib.md5(b"far|far").hexdigest()[:12]
print("keys=%d near=%s far=%s" % (len(seen), near in seen, far in seen),
      "BOUNDED" if near in seen and far not in seen else "SEEN-GREW",
      "APPLIED-0" if all(e[up._C_APPLIED]==0 for e in seen.values()) else "APPLIED-1")
PY_19F
)
printf '%s' "$got" | grep -q 'BOUNDED APPLIED-0' \
  && ok "out-of-week keys are remembered only near the close, and contribute nothing" \
  || bad "out-of-week keys are remembered only near the close" "$(flat "$got")"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
