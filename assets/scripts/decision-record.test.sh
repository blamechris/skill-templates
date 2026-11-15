#!/usr/bin/env bash
# Regression tests for assets/scripts/decision-record.py. Hermetic: temp dirs only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/decision-record.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/decision-record-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_HANDOFF_DIR="$TMP/handoffs" CLAUDE_DECISION_LEDGER="$TMP/ledger/decisions.jsonl" \
  CLAUDE_PR_LEDGER="$TMP/prs.jsonl" CHROXY_SEED_ANNOUNCE=0
mkdir -p "$HOME" "$CLAUDE_HANDOFF_DIR"
unset CLAUDE_CODE_SESSION_ID
L="$CLAUDE_DECISION_LEDGER"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
run() { "$PY" -B "$SUT" "$@"; }
expect_refuse() { # name, then args; expects exit 2 and an unchanged ledger
  local name=$1; shift
  local before; before=$(cat "$L" 2>/dev/null | wc -c)
  local err; err=$(run "$@" 2>&1 >/dev/null); local rc=$?
  local after; after=$(cat "$L" 2>/dev/null | wc -c)
  if [ "$rc" = 2 ] && [ "$before" = "$after" ] && [[ "$err" == REFUSE* ]]; then ok "$name"; else bad "$name" "rc=$rc err=$err"; fi
}
BASE=(add --scope demo --session s1 --question "Merge?" --answer-verbatim "yes, merge it")

echo "decision-record.test.sh"

out=$(run "${BASE[@]}" --received-at 2026-11-01T10:00:00Z --authorizes "merge PR 9115" --limit "no force push" \
  --pin pr=9115 --pin head=abc123 --ref https://example.test/pr/9115 2>&1); rc=$?
[ $rc = 0 ] && [[ "$out" == decision:\ dec-*"$L"* ]] && ok "add prints decision line" || bad "add" "$out"
[[ "$out" == *"git -C "*" add -- decisions.jsonl"* && "$out" == *"commit -m"* ]] && ok "add prints git lines" || bad "git lines" "$out"
"$PY" - "$L" <<'PYEOF' && ok "record fields round-trip" || bad "record fields"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 1, r
r = r[0]
assert r["kind"] == "decision-record" and r["schema_version"] == 1
assert r["id"].startswith("dec-") and r["scope"] == "demo" and r["session"] == "s1"
assert r["received_at"] == "2026-11-01T10:00:00Z" and r["recorded_at"].endswith("Z")
assert r["decided_by"] == "Chris" and r["channel"] == "direct" and r["relay_via"] is None
assert r["answer_verbatim"] == "yes, merge it" and r["question"] == "Merge?"
assert r["authorizes"] == ["merge PR 9115"] and r["limits"] == ["no force push"]
assert r["pins"] == {"pr": "9115", "head": "abc123"} and r["refs"] == ["https://example.test/pr/9115"]
assert r["supersedes"] is None
PYEOF
ID=$("$PY" -c "import json;print(json.loads(open('$L').readline())['id'])")

run add --scope demo --session s1 --question "Start?" --answer-verbatim "go" --channel relay --relay-via dot \
  --received-at 2026-11-02T10:00:00Z --supersedes "$ID" >/dev/null 2>&1 && ok "relay + supersedes accepted" || bad "relay add"
run add --scope other --session s1 --question "Q" --answer-verbatim "A" --received-at 2026-11-03T10:00:00Z >/dev/null
[ "$(wc -l < "$L" | tr -d ' ')" = 3 ] && ok "three lines" || bad "line count"
[ "$(run list | wc -l | tr -d ' ')" = 3 ] && ok "list all" || bad "list all"
[ "$(run list --scope demo | wc -l | tr -d ' ')" = 2 ] && ok "list --scope" || bad "list scope"
[ "$(run list --since 2026-11-02T00:00:00Z | wc -l | tr -d ' ')" = 2 ] && ok "list --since" || bad "list since"
run list --scope demo --json | "$PY" -c "import json,sys;d=json.load(sys.stdin);assert len(d)==2 and d[1]['relay_via']=='dot'" \
  && ok "list --json" || bad "list json"
[ "$(run list --ledger "$TMP/none.jsonl" | wc -l | tr -d ' ')" = 0 ] && ok "list on missing ledger is empty" || bad "missing ledger"

expect_refuse "missing session" add --scope demo --question Q --answer-verbatim A2
expect_refuse "relay without relay_via" "${BASE[@]}" --answer-verbatim a3 --channel relay
expect_refuse "relay_via with direct" "${BASE[@]}" --answer-verbatim a4 --relay-via dot
expect_refuse "newline in answer" "${BASE[@]}" --answer-verbatim $'line1\nline2'
expect_refuse "control char in question" "${BASE[@]}" --question $'bad\x01q' --answer-verbatim a5
expect_refuse "control char in list item" "${BASE[@]}" --answer-verbatim a6 --authorizes $'x\ty'
expect_refuse "ghp token" "${BASE[@]}" --answer-verbatim "use ghp_abcdefghijklmnopqrstuvwxyz0123456789"
expect_refuse "sk token" "${BASE[@]}" --answer-verbatim "key sk-abcdefghijklmnopqrstuvwxyz"
expect_refuse "xox token in ref" "${BASE[@]}" --answer-verbatim a7 --ref "https://x.test/?t=xoxb-1234567890-abcdef"
expect_refuse "PEM header" "${BASE[@]}" --answer-verbatim "-----BEGIN RSA PRIVATE KEY-----"
expect_refuse "bad timestamp" "${BASE[@]}" --answer-verbatim a8 --received-at yesterday
expect_refuse "bad pin" "${BASE[@]}" --answer-verbatim a9 --pin nokey
expect_refuse "duplicate id" "${BASE[@]}" --received-at 2026-11-01T10:00:00Z
expect_refuse "unknown supersedes" "${BASE[@]}" --answer-verbatim a10 --supersedes dec-000000000000
expect_refuse "empty answer" "${BASE[@]}" --answer-verbatim ""
run add --scope demo --question Q >/dev/null 2>&1; [ $? = 2 ] && ok "usage error exits 2" || bad "usage exit"

CLAUDE_CODE_SESSION_ID=envsid run add --scope demo --question "E?" --answer-verbatim "env ok" >/dev/null 2>&1 \
  && tail -1 "$L" | grep -q '"session": "envsid"' && ok "session from env" || bad "env session"

# default scope comes from session-seed.py scope, in a throwaway git repo
mkdir "$TMP/myrepo" && git -C "$TMP/myrepo" init -q -b main 2>/dev/null
(cd "$TMP/myrepo" && run add --session s1 --question "S?" --answer-verbatim "scope default" >/dev/null 2>&1)
tail -1 "$L" | grep -q '"scope": "myrepo"' && ok "default scope from git" || bad "default scope" "$(tail -1 "$L")"

# concurrency: 24 racing writers, every line must be whole JSON
for i in $(seq 1 24); do
  run add --scope race --session s1 --question "Q$i" --answer-verbatim "$(printf 'answer-%s-%0200d' "$i" 0)" \
    --received-at 2026-11-04T10:00:00Z >/dev/null 2>&1 &
done
wait
"$PY" - "$L" <<'PYEOF' && ok "concurrent appends never interleave" || bad "concurrent appends"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
race = [r for r in rows if r["scope"] == "race"]
assert len(race) == 24 and len({r["id"] for r in race}) == 24
PYEOF

echo
echo "passed: $pass failed: $fail"
[ "$fail" = 0 ]
