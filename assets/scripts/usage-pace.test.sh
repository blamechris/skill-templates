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
#     the suite green. Drive it end to end against a fresh HOME.
HOOKHOME=$TMP/hookhome
mkdir -p "$HOOKHOME/.claude/projects"
cat > "$TMP/fable.jsonl" <<'FABLEJ'
{"type":"assistant","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5","usage":{"output_tokens":1}}}
FABLEJ
hookrun() { printf '{"session_id":"s1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$HOOKHOME" "$PY" "$SUT" --hook --every 1 --margin -1 2>&1; }
out=$(hookrun); rc=$?
printf '%s' "$out" | grep -q 'usage-pace' \
  && ok "hook actually SPEAKS when due and off pace (margin -1 forces a verdict)" \
  || bad "hook actually SPEAKS when due and off pace" "rc=$rc out=$(flat "$out")"

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

# (i) ahead -> ok -> ahead must speak the second time. Reverting s.pop("acked") left
#     31/31 green because no scenario ever returned to ok between two alerts.
#     --margin -1 forces "ahead"; a huge margin forces "ok".
ACKHOME=$TMP/ackhome
mkdir -p "$ACKHOME/.claude/projects"
ackrun() { printf '{"session_id":"s1","transcript_path":"%s"}' "$TMP/fable.jsonl" \
  | HOME="$ACKHOME" "$PY" "$SUT" --hook --every 1 --margin "$1" 2>&1; }
a1=$(ackrun -1); a2=$(ackrun 999); a3=$(ackrun -1)
spoke() { printf '%s' "$1" | grep -q 'usage-pace' && echo yes || echo no; }
[ "$(spoke "$a1")" = yes ] && [ "$(spoke "$a2")" = no ] && [ "$(spoke "$a3")" = yes ] \
  && ok "ahead -> ok -> ahead speaks again (the acknowledgment is cleared on ok)" \
  || bad "ahead -> ok -> ahead speaks again" "spoke: $(spoke "$a1")/$(spoke "$a2")/$(spoke "$a3")"

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

# (n) pace() itself must report DST-correct elapsed and days_left. The earlier DST
#     case asserted on week_bounds and computed the UTC diff itself, so reverting
#     pace()'s own arithmetic left it green.
#     `now` is placed BEFORE the transition (still PDT) while the week closes after
#     it (PST), so the naive and UTC answers differ for both fields. The expected
#     values are derived here from UTC arithmetic, independently of the SUT.
got=$(pymod "
from datetime import datetime, timedelta, timezone
up.scan = lambda *a, **k: {}
up.read_readings = lambda: []
now = datetime(2026,10,30,12,0,tzinfo=up.PT)      # PDT; the week closes in PST
p = up.pace(now=now)
o, c = up.week_bounds('2026-11-04')
u = lambda d: d.astimezone(timezone.utc)
want_e = (u(now)-u(o)).total_seconds() / (u(c)-u(o)).total_seconds()
want_d = (u(c)-u(now)).total_seconds() / 86400
naive_e = (now.replace(tzinfo=None)-o.replace(tzinfo=None)).total_seconds() / 604800.0
ok_e = abs(p['elapsed']-want_e) < 1e-9
ok_d = abs(p['days_left']-want_d) < 1e-9
print('OK' if ok_e and ok_d else 'BAD', 'discriminating' if abs(want_e-naive_e) > 1e-4 else 'DEGENERATE')" 2>&1)
[ "$got" = "OK discriminating" ] \
  && ok "pace() elapsed and days_left are DST-correct across the fall-back" \
  || bad "pace() elapsed and days_left are DST-correct across the fall-back" "got=$(flat "$got")"


printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
