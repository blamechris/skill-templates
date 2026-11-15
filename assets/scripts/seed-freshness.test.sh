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

snap() { (cd "$TMP" && find . -path ./home -prune -o -type f -print0 | sort -z | xargs -0 shasum; find . -path ./home -prune -o -type d -print | sort); }
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

echo
echo "passed: $pass failed: $fail"
[ "$fail" = 0 ]
