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

echo
echo "passed: $pass failed: $fail"
[ "$fail" = 0 ]
