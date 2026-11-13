#!/usr/bin/env bash
# check-skill-pins.test.sh — regression tests for scripts/check-skill-pins.py (#375).
#
# Run: ./scripts/check-skill-pins.test.sh
# Exit: 0 all pass · 1 a case failed or FEWER cases ran than expected
#
# Each case builds a hermetic git repo under mktemp -d and runs the checker from
# inside it. Cases that depend on reachability stay checked out on a side branch
# while --base is main, so a checker that walks HEAD instead of BASE goes red.
# CHECK_SKILL_PINS overrides the script under test; the mutation proofs use it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK_SKILL_PINS:-$ROOT/scripts/check-skill-pins.py}"
EXPECTED=17
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; if [ -n "${2:-}" ]; then echo "      $2"; fi; return 0; }

N=0
H1=""; H2=""; H3=""; FX=""
# fresh fixture: main has H1,H2 touching generic/foo.md and H3 touching only other.txt
fixture() {
  N=$((N+1)); FX="$TMP/fx$N"
  mkdir -p "$FX/generic" "$FX/.claude/commands"
  git -C "$FX" init -q -b main
  echo v1 > "$FX/generic/foo.md"; echo '{}' > "$FX/registry.json"
  git -C "$FX" add -A; git -C "$FX" commit -qm c1
  echo v2 > "$FX/generic/foo.md"
  git -C "$FX" add -A; git -C "$FX" commit -qm c2
  echo x > "$FX/other.txt"
  git -C "$FX" add -A; git -C "$FX" commit -qm c3
  H1=$(git -C "$FX" rev-parse HEAD~2); H2=$(git -C "$FX" rev-parse HEAD~1); H3=$(git -C "$FX" rev-parse HEAD)
}
# install NAME LOCKHASH STAMPNAME STAMPHASH
install() {
  printf '{"registry":"x/y","skills":{"%s":{"hash":"%s","installed":"2026-01-01"}}}\n' "$1" "$2" > "$FX/.claude/skills.lock"
  printf '# /%s\n\nbody\n\n<!-- skill-templates: %s %s 2026-01-01 -->\n' "$1" "$3" "$4" > "$FX/.claude/commands/$1.md"
}
RC=0; OUT=""
run() { OUT=$(cd "$FX" && python3 "$CHECK" --base "${1:-main}" 2>&1); RC=$?; }
expect() { # label want_rc
  if [ "$RC" -eq "$2" ]; then ok "$1 (exit $RC)"; else bad "$1" "wanted exit $2, got $RC: $OUT"; fi
}

fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; run; expect "1 current pin passes" 0
fixture; install foo "${H1:0:7}" foo "${H1:0:7}"; run; expect "2 older pin passes" 0
fixture; install foo "${H3:0:7}" foo "${H3:0:7}"; run; expect "3 commit that did not touch template fails" 1
fixture
git -C "$FX" checkout -q -b side; echo v3 > "$FX/generic/foo.md"; git -C "$FX" add -A; git -C "$FX" commit -qm side
HS=$(git -C "$FX" rev-parse HEAD); install foo "${HS:0:7}" foo "${HS:0:7}"; run
expect "4 pre-squash hash (unreachable from base) fails" 1
fixture; install foo "${H2:0:7}" foo "${H1:0:7}"; run; expect "5 stamp hash differs from lock fails" 1
fixture; install foo "${H2:0:7}" bar "${H2:0:7}"; run; expect "6 stamp naming another skill fails" 1
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; sed -i.bak '/skill-templates:/d' "$FX/.claude/commands/foo.md"; rm "$FX/.claude/commands/foo.md.bak"
run; expect "7a missing stamp fails" 1
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; echo "<!-- skill-templates: foo ${H2:0:7} 2026-01-01 -->" >> "$FX/.claude/commands/foo.md"
run; expect "7b two stamp lines fail" 1
fixture
git -C "$FX" checkout -q -b feat; echo n > "$FX/generic/bar.md"; git -C "$FX" add -A; git -C "$FX" commit -qm bar
HB=$(git -C "$FX" rev-parse HEAD); install bar "${HB:0:7}" bar "${HB:0:7}"; run
expect "8 new template + install in one change fails" 1
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; echo '{"reindexed":true}' > "$FX/registry.json"; run
expect "9 reindex-only change passes" 0
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; run nosuchrev; expect "10a unresolvable base exits 2" 2
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; git -C "$FX" add -A; git -C "$FX" commit -qm inst
SH="$TMP/shallow$N"; git clone -q --depth 1 "file://$FX" "$SH" 2>/dev/null
OUT=$(cd "$SH" && python3 "$CHECK" --base HEAD 2>&1); RC=$?; expect "10b shallow clone exits 2" 2
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; echo '{not json' > "$FX/.claude/skills.lock"; run
expect "11a malformed lock exits 2" 2
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; rm "$FX/.claude/skills.lock"; run
expect "11b missing lock exits 2" 2
fixture; install foo "zzzzzzz" foo "zzzzzzz"; run; expect "12 non-hex hash fails" 1
fixture; install foo "${H2:0:6}" foo "${H2:0:6}"; run; expect "13 hash shorter than 7 fails" 1
fixture; install foo "${H2:0:7}" foo "${H2:0:7}"; rm "$FX/.claude/commands/foo.md"; run; expect "14 missing command file fails" 1

echo "passed=$PASS failed=$FAIL expected_cases=$EXPECTED"
if [ $((PASS+FAIL)) -lt "$EXPECTED" ]; then
  echo "FAIL: only $((PASS+FAIL)) cases ran, expected at least $EXPECTED"; exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
