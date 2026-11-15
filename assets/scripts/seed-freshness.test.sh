#!/usr/bin/env bash
# Regression tests for assets/scripts/seed-freshness.py. Hermetic: temp dirs only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/seed-freshness.py"
DR="$HERE/decision-record.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/seed-freshness-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_HANDOFF_DIR="$TMP/handoffs" CLAUDE_DECISION_LEDGER="$TMP/decisions.jsonl" \
  CLAUDE_PR_LEDGER="$TMP/prs.jsonl" CHROXY_SEED_ANNOUNCE=0
mkdir -p "$HOME" "$CLAUDE_HANDOFF_DIR"
unset CLAUDE_CODE_SESSION_ID
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
run() { "$PY" -B "$SUT" "$@"; }

seed() { # scope session date picks_up_at
  cat > "$CLAUDE_HANDOFF_DIR/NEXT-$1.md" <<SEED
---
type: handoff
date: $3
scope: $1
session: $2
picks_up_at: "$4"
sensitivity: vault
---
# Handoff - $1
SEED
}
decision() { "$PY" -B "$DR" add --scope "$1" --session x --question Q --answer-verbatim "$2" --received-at "$3" >/dev/null; }
prrec() { # repo sid recorded_at merged_at
  printf '{"kind":"pr-record","schema_version":1,"repo":"%s","pr":7,"recorded_at":"%s","pr_meta":{"merged_at":"%s"},"session":{"id":"%s"}}\n' \
    "$1" "$3" "$4" "$2" >> "$CLAUDE_PR_LEDGER"
}

echo "seed-freshness.test.sh"
T0=2026-11-01T10:00:00Z; T1=2026-11-01T11:00:00Z

seed alpha aaaaaaaa $T0 "issue 5"
seed beta  bbbbbbbb $T0 "OWNER: Chris decide the merge"
seed gamma cccccccc $T0 "issue 6"
seed delta dddddddd $T0 "OWNER: Chris paste the seed"
seed eps   eeeeeeee $T0 "issue 7"
decision alpha "later" $T1                       # (a)
decision beta  "later" $T1                       # (a) + (c)
decision delta "earlier" 2026-11-01T09:00:00Z    # before seed: no effect
prrec acme/gamma zzzzzzzz $T1 $T1                # (b) repo basename
prrec acme/other eeeeeeee-1234 $T1 $T1           # (b) session prefix
prrec acme/other ffffffff 2026-11-01T09:00:00Z 2026-11-01T09:00:00Z   # old: no effect
# an archived seed must be ignored
cp "$CLAUDE_HANDOFF_DIR/NEXT-alpha.md" "$CLAUDE_HANDOFF_DIR/NEXT-alpha.20261001T000000Z-old.md"

mkdir -p "$HOME/Obsidian/no-it-all/ledgers" "$HOME/Obsidian/no-it-all/handoffs"
snap() { (cd "$TMP" && find . -type f -print0 | sort -z | xargs -0 shasum; find . -type d -print | sort); }
before=$(snap)
out=$(run); rc=$?
after=$(snap)
[ $rc = 0 ] && ok "exit 0 on completed check" || bad "exit" "rc=$rc"
[ "$before" = "$after" ] && ok "writes nothing" || bad "dir changed"
echo "$out" | grep -q '^STALE alpha .*decision' && ok "(a) decision after seed is STALE" || bad "(a)" "$out"
echo "$out" | grep -q '^STALE gamma .*PR 7' && ok "(b) pr-record by repo basename" || bad "(b) repo" "$out"
echo "$out" | grep -q '^STALE eps .*PR 7' && ok "(b) pr-record by session prefix" || bad "(b) session" "$out"
echo "$out" | grep -q '^STALE beta .*asks the owner for something a later decision may have answered' && ok "(c) owner ask" || bad "(c)" "$out"
echo "$out" | grep -q '^FRESH delta$' && ok "FRESH: owner ask but only an earlier decision" || bad "fresh delta" "$out"
echo "$out" | grep -q 'alpha.2026' && bad "archive listed" || ok "archives ignored"
echo "$out" | grep -q '^STALE alpha .*asks the owner' && bad "(c) fired without OWNER:" || ok "(c) needs OWNER:"

run --scope delta | grep -q '^FRESH delta$' && ok "--scope single" || bad "--scope"
run --json | "$PY" -c "
import json,sys
d={r['scope']:r for r in json.load(sys.stdin)}
assert d['beta']['status']=='STALE' and {x['code'] for x in d['beta']['reasons']}=={'decision','owner-ask'}
assert d['delta']['status']=='FRESH' and d['delta']['reasons']==[]
assert {x['code'] for x in d['gamma']['reasons']}=={'pr-record'}" && ok "--json" || bad "--json"

# no ledgers at all: everything FRESH, exit 0
out=$(CLAUDE_DECISION_LEDGER="$TMP/none1" CLAUDE_PR_LEDGER="$TMP/none2" run); rc=$?
[ $rc = 0 ] && ! echo "$out" | grep -q STALE && ok "absent ledgers are FRESH" || bad "no ledgers" "$out"

# exit 2 cases
run --scope nosuch >/dev/null 2>&1; [ $? = 2 ] && ok "unknown scope exits 2" || bad "unknown scope"
run --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "usage error exits 2" || bad "usage"
echo 'not json' >> "$CLAUDE_DECISION_LEDGER"
out=$(run 2>/dev/null); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q '^FRESH delta\|^STALE' && ok "corrupt ledger exits 2 yet prints verdicts" || bad "corrupt ledger" "rc=$rc"
sed -i.bak '$d' "$CLAUDE_DECISION_LEDGER"; rm -f "$CLAUDE_DECISION_LEDGER.bak"
printf -- '---\ntype: handoff\nscope: nodate\n---\n' > "$CLAUDE_HANDOFF_DIR/NEXT-nodate.md"
run >/dev/null 2>&1; [ $? = 2 ] && ok "seed without date exits 2" || bad "no date"
rm "$CLAUDE_HANDOFF_DIR/NEXT-nodate.md"
CLAUDE_HANDOFF_DIR=relative run >/dev/null 2>&1; [ $? = 2 ] && ok "relative handoff dir exits 2" || bad "relative dir"


# ---- same-minute resolution, in the real renderer's date format (no seconds)
seed minute mmmmmmmm 2026-11-02T10:45Z "issue 8"
decision minute "same minute, before the write" 2026-11-02T10:45:20Z
run --scope minute | grep -q '^FRESH minute$' && ok "event earlier in the seed's minute is FRESH" || bad "same minute before"
decision minute "next minute" 2026-11-02T10:46:00Z
run --scope minute | grep -q '^STALE minute' && ok "event in the next minute is STALE" || bad "next minute"
seed secs ssssssss 2026-11-02T10:45:30Z "issue 9"
decision secs "before, same minute" 2026-11-02T10:45:20Z
run --scope secs | grep -q '^FRESH secs$' && ok "seconds date: earlier event FRESH" || bad "secs before"
decision secs "after, same minute" 2026-11-02T10:45:40Z
run --scope secs | grep -q '^STALE secs' && ok "seconds date used exactly: later event STALE" || bad "secs after"
prrec acme/minute mmmmmmmm-1 2026-11-02T10:45:10Z 2026-11-02T10:45:10Z
rm -f "$CLAUDE_DECISION_LEDGER"; : > "$CLAUDE_PR_LEDGER"
prrec acme/minute zzzzzzzz 2026-11-02T10:45:10Z 2026-11-02T10:45:10Z
run --scope minute | grep -q '^FRESH minute$' && ok "pr-record in the seed's minute is FRESH" || bad "pr same minute"
prrec acme/minute zzzzzzzz 2026-11-02T10:47:00Z 2026-11-02T10:47:00Z
run --scope minute | grep -q '^STALE minute' && ok "pr-record in a later minute is STALE" || bad "pr later minute"

# ---- UUID session ids match case-insensitively on the seed's 8-char prefix
: > "$CLAUDE_PR_LEDGER"
seed uu 7613cec0 2026-11-02T10:45Z "issue 10"
prrec acme/zzz 7613CEC0-38A1-41FB-84A7-F3BC43823911 2026-11-02T11:00:00Z 2026-11-02T11:00:00Z
run --scope uu | grep -q '^STALE uu' && ok "uppercase UUID session id matches the seed" || bad "uuid case"

# ---- malformed rows: skipped, line-numbered, exit 2, valid rows still counted
: > "$CLAUDE_PR_LEDGER"; : > "$CLAUDE_DECISION_LEDGER"
printf '{"kind":"pr-record","repo":"acme/minute","pr":1,"pr_meta":"oops","recorded_at":"2026-11-02T12:00:00Z"}\n' >> "$CLAUDE_PR_LEDGER"
printf '{"kind":"pr-record","repo":"acme/minute","pr":2,"session":[1],"recorded_at":"2026-11-02T12:00:00Z"}\n' >> "$CLAUDE_PR_LEDGER"
printf '{"kind":"pr-record","repo":"acme/minute","pr":3}\n' >> "$CLAUDE_PR_LEDGER"
printf '\xff\xfe not utf8\n' >> "$CLAUDE_PR_LEDGER"
printf '{"kind":"decision-record","id":"dec-1","scope":"minute","received_at":"garbage"}\n' >> "$CLAUDE_DECISION_LEDGER"
prrec acme/minute zzzzzzzz 2026-11-02T13:00:00Z 2026-11-02T13:00:00Z
out=$(run --scope minute 2>"$TMP/err"); rc=$?
[ $rc = 2 ] && ok "malformed rows exit 2" || bad "malformed exit" "rc=$rc"
echo "$out" | grep -q '^STALE minute .*PR 7' && ok "valid rows still counted" || bad "valid rows" "$out"
for n in "line 1:" "line 2:" "line 3:" "line 4:" ; do grep -q "prs.jsonl $n" "$TMP/err" && ok "error names pr ledger $n" || bad "err $n" "$(cat "$TMP/err")"; done
grep -q "decisions.jsonl line 1:" "$TMP/err" && ok "undatable decision is an error, not FRESH" || bad "undatable decision"

# ======================= round 2 =======================
: > "$CLAUDE_PR_LEDGER"; : > "$CLAUDE_DECISION_LEDGER"
settime() { "$PY" -c "import os,sys,calendar,time;t=calendar.timegm(time.strptime(sys.argv[2],'%Y-%m-%dT%H:%M:%SZ'));os.utime(sys.argv[1],(t,t))" "$CLAUDE_HANDOFF_DIR/NEXT-$1.md" "$2"; }

# ---- fractional seconds are compared exactly
seed frac ffffffff 2026-11-03T10:45:30Z "issue 11"
settime frac 2026-11-03T10:45:30Z
decision frac "half a second later" 2026-11-03T10:45:30.500Z
run --scope frac | grep -q '^STALE frac' && ok "fractional second after a seed with seconds is STALE" || bad "fraction"

# ---- offsets beyond +14:59 are errors, not silent
printf '{"kind":"decision-record","id":"dec-o","scope":"frac","received_at":"2026-11-03T10:00:00+00:99"}\n' >> "$CLAUDE_DECISION_LEDGER"
printf '{"kind":"decision-record","id":"dec-p","scope":"frac","received_at":"2026-11-03T10:00:00+99:00"}\n' >> "$CLAUDE_DECISION_LEDGER"
run --scope frac >/dev/null 2>"$TMP/err"; rc=$?
[ $rc = 2 ] && grep -q "line 2:" "$TMP/err" && grep -q "line 3:" "$TMP/err" && ok "bad offsets are line-numbered errors" || bad "offsets" "rc=$rc $(cat "$TMP/err")"
: > "$CLAUDE_DECISION_LEDGER"

# ---- decoder-limit rows are per-line errors; a later valid row still counts
"$PY" -c "print('{\"kind\":\"pr-record\",\"pr\":' + '9'*6000 + '}')" >> "$CLAUDE_DECISION_LEDGER"
"$PY" -c "print('['*200000)" >> "$CLAUDE_DECISION_LEDGER"
decision frac "valid after bad" 2026-11-03T11:00:00Z
out=$(run --scope frac 2>"$TMP/err"); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q '^STALE frac' && grep -q "line 1:" "$TMP/err" && grep -q "line 2:" "$TMP/err" && ok "decoder errors reported, valid row used" || bad "decoder" "rc=$rc $out"
: > "$CLAUDE_DECISION_LEDGER"

# ---- the seed's mtime is the exact write instant inside the seed's own minute
seed mt mmtttttt 2026-11-03T12:30Z "issue 12"
settime mt 2026-11-03T12:30:45Z
decision mt "same minute, before the write" 2026-11-03T12:30:20Z
run --scope mt | grep -q '^FRESH mt$' && ok "mtime: earlier in the minute is FRESH" || bad "mtime before"
decision mt "same minute, after the write" 2026-11-03T12:30:50Z
run --scope mt | grep -q '^STALE mt' && ok "mtime: a later event in the same minute is STALE (closes the window)" || bad "mtime after"
: > "$CLAUDE_DECISION_LEDGER"
settime mt 2026-11-05T09:00:00Z   # mtime outside the seed's minute: end-of-minute rule
decision mt "same minute, after" 2026-11-03T12:30:50Z
run --scope mt | grep -q '^FRESH mt$' && ok "mtime outside the minute: end-of-minute rule" || bad "mtime outside"

# ---- session id matching
: > "$CLAUDE_PR_LEDGER"
seed ci abc12345 2026-11-03T10:00Z "issue 13"; settime ci 2026-11-03T10:00:10Z
prrec acme/zz ABC12345-ffff 2026-11-03T11:00:00Z 2026-11-03T11:00:00Z
run --scope ci | grep -q '^FRESH ci$' && ok "custom (non-UUID) ids compare case-sensitively" || bad "custom case"
: > "$CLAUDE_PR_LEDGER"
prrec acme/zz abc12345-ffff 2026-11-03T11:00:00Z 2026-11-03T11:00:00Z
run --scope ci | grep -q '^STALE ci' && ok "custom id prefix matches case-sensitively" || bad "custom prefix"
seed short abc 2026-11-03T10:00Z "issue 14"; settime short 2026-11-03T10:00:10Z
: > "$CLAUDE_PR_LEDGER"; prrec acme/zz abcdef 2026-11-03T11:00:00Z 2026-11-03T11:00:00Z
run --scope short | grep -q '^FRESH short$' && ok "a seed session shorter than 8 never prefix-matches" || bad "short sid"
: > "$CLAUDE_PR_LEDGER"; prrec acme/zz abc 2026-11-03T11:00:00Z 2026-11-03T11:00:00Z
run --scope short | grep -q '^STALE short' && ok "a short seed session still matches exactly" || bad "short exact"

# ---- datetime.max boundary goes through the normal error path
seed maxd mmmmmmmm 9999-12-31T23:59Z "issue 15"
err=$(run --scope maxd 2>&1 >/dev/null); rc=$?
[ $rc = 2 ] && [[ "$err" != *Traceback* ]] && ok "9999-12-31T23:59Z is a normal error, not OverflowError" || bad "datetime.max" "rc=$rc $err"

echo
echo "passed: $pass failed: $fail"
[ "$fail" = 0 ]
