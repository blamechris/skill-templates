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
  local before; before=$(shasum "$L" 2>/dev/null)
  local err; err=$(run "$@" 2>&1 >/dev/null); local rc=$?
  local after; after=$(shasum "$L" 2>/dev/null)
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

# ---- raw-value validation, credentials, line separators
expect_refuse "session with raw newline/tab" add --scope demo --session $'\ns1\t' --question Q --answer-verbatim r1
expect_refuse "whitespace-only relay_via" "${BASE[@]}" --answer-verbatim r2 --channel relay --relay-via "   "
expect_refuse "whitespace-only answer" "${BASE[@]}" --answer-verbatim "   "
expect_refuse "U+2028 in answer" "${BASE[@]}" --answer-verbatim $'a\xe2\x80\xa8b'
expect_refuse "U+2029 in question" "${BASE[@]}" --question $'a\xe2\x80\xa9b' --answer-verbatim r3
expect_refuse "U+0085 in answer" "${BASE[@]}" --answer-verbatim $'a\xc2\x85b'
expect_refuse "lowercase bearer" "${BASE[@]}" --answer-verbatim "use bearer abcdefghijklmnopqrstuvwxyz123"
expect_refuse "stripe live key" "${BASE[@]}" --answer-verbatim "sk_live_abcdefgh12345678"
expect_refuse "pk_live key" "${BASE[@]}" --answer-verbatim "pk_live_abcdefgh12345678"
expect_refuse "JWT" "${BASE[@]}" --answer-verbatim "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4"
expect_refuse "password assignment" "${BASE[@]}" --answer-verbatim "password: hunter2"
expect_refuse "api_key assignment" "${BASE[@]}" --answer-verbatim "API_KEY=abc"

# ---- canonical timestamps
run add --scope ts --session s1 --question Q --answer-verbatim A --received-at 2026-2-1T1:2:3Z >/dev/null
run add --scope ts --session s1 --question Q --answer-verbatim A2 --received-at 2026-02-01T03:00:00+02:00 >/dev/null
run list --scope ts --json | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
assert [r['received_at'] for r in d]==['2026-02-01T01:02:03Z','2026-02-01T01:00:00Z'], d" \
  && ok "unpadded and offset timestamps are canonicalized" || bad "canonical ts"
expect_refuse "same instant, other spelling, is a duplicate" add --scope ts --session s1 --question Q --answer-verbatim A --received-at 2026-02-01T01:02:03+00:00
expect_refuse "naive timestamp" "${BASE[@]}" --answer-verbatim r4 --received-at 2026-02-01T01:02:03
[ "$(run list --scope ts --since 2026-2-1T1:1:0Z | wc -l | tr -d ' ')" = 1 ] && ok "--since compares parsed values" || bad "since parsed"

# ---- append integrity
cp "$L" "$TMP/ledger.bak"
printf '%s' "$(tail -1 "$L")" > "$TMP/lastline"; head -n -1 "$L" > "$TMP/rest" 2>/dev/null || sed '$d' "$L" > "$TMP/rest"
cat "$TMP/rest" "$TMP/lastline" > "$L"                      # now ends without a newline
n_before=$(wc -l < "$L" | tr -d ' ')
run add --scope nl --session s1 --question Q --answer-verbatim "after missing newline" >/dev/null 2>&1 && ok "add after missing final newline" || bad "missing newline add"
"$PY" - "$L" "$n_before" <<'PYEOF' && ok "prior record preserved, no joined line" || bad "newline repair"
import json, sys
lines = open(sys.argv[1], 'rb').read().split(b"\n")
assert lines[-1] == b"" , lines[-1]
rows = [json.loads(l) for l in lines[:-1]]
assert rows[-1]["scope"] == "nl" and len(rows) == int(sys.argv[2]) + 2
PYEOF
cat > "$TMP/inject.py" <<'PYEOF'
import os, runpy, sys, hashlib
mode, ledger = sys.argv[1], sys.argv[2]
g = runpy.run_path(os.environ["SUT"])
real = os.write
calls = {"n": 0}
def short(fd, data):
    calls["n"] += 1
    return real(fd, data[:len(data) // 2]) if calls["n"] == 1 else real(fd, data)
def boom(fd, data):
    real(fd, data[:len(data) // 2])
    raise OSError(28, "No space left on device")
os.write = short if mode == "short" else boom
rec = {"kind": "decision-record", "schema_version": 1, "id": "dec-inject" + mode, "scope": "inj", "received_at": "2026-11-01T00:00:00Z",
       "answer_verbatim": "x" * 200, "supersedes": None}
h = lambda: hashlib.sha256(open(ledger, "rb").read()).hexdigest() if os.path.exists(ledger) and os.path.getsize(ledger) else "none"
before = h()
try:
    g["append_locked"](ledger, rec)
    rc = 0
except SystemExit as e:
    rc = e.code
print(rc, "same" if h() == before else "changed")
PYEOF
export SUT
SUT="$SUT" "$PY" "$TMP/inject.py" short "$L" | grep -q '^0 changed$' && "$PY" -c "
import json;[json.loads(l) for l in open('$L')]" && ok "short write is continued to a whole line" || bad "short write"
SUT="$SUT" "$PY" "$TMP/inject.py" boom "$L" 2>/dev/null | grep -q '^2 same$' && ok "write error restores the ledger bytes, exit 2" || bad "write error"
SUT="$SUT" "$PY" "$TMP/inject.py" boom "$TMP/fresh/new.jsonl" 2>/dev/null | grep -q '^2 same$' && ok "write error on a new ledger leaves it empty" || bad "write error new"

# ---- corruption policy: one bad line never bricks list or add
cp "$L" "$TMP/good.bak"
printf 'not json\n' >> "$L"; printf '\xff\xfe\n' >> "$L"
printf '{"kind":"decision-record","id":"dec-x","scope":"demo","received_at":"nope"}\n' >> "$L"
out=$(run list 2>"$TMP/err"); rc=$?
[ $rc = 2 ] && [ -n "$out" ] && ok "list prints good rows and exits 2" || bad "list corrupt" "rc=$rc"
grep -q "line [0-9]*: unreadable" "$TMP/err" && grep -q "no parseable received_at" "$TMP/err" && ok "list names bad lines on stderr" || bad "list errors" "$(cat "$TMP/err")"
run add --scope after --session s1 --question Q --answer-verbatim "after corruption" >/dev/null 2>"$TMP/err"; rc=$?
[ $rc = 0 ] && grep -q '^warning:' "$TMP/err" && ok "add appends and warns past bad lines" || bad "add corrupt" "rc=$rc"

# ---- printed commands are shell-quoted
SP="$TMP/dir with space & \$x;/led ger.jsonl"
out=$(run "${BASE[@]}" --answer-verbatim quote --ledger "$SP")
line=$(echo "$out" | grep 'git -C' | head -1)
eval "set -- $line"; [ "$1 $2" = "git -C" ] && [ "$3" = "$(cd "$(dirname "$SP")" && pwd)" ] && [ "$6" = "led ger.jsonl" ] \
  && ok "git lines survive shell parsing with spaces and metacharacters" || bad "shlex" "$line"

# ---- ledger privacy: refused inside a worktree
wt=$(cd "$TMP/myrepo" && run add --scope demo --session s1 --question Q --answer-verbatim priv --ledger "$TMP/myrepo/docs/decisions.jsonl" 2>&1)
[[ "$wt" == *"inside the worktree"* ]] && [ ! -e "$TMP/myrepo/docs/decisions.jsonl" ] && ok "ledger inside a repo worktree is refused" || bad "worktree refusal" "$wt"

echo
echo "passed: $pass failed: $fail"
[ "$fail" = 0 ]
