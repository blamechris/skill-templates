#!/usr/bin/env bash
# Regression tests for assets/scripts/usage-benchmark-row.py.
#
# THE ROW IS A ROW IN A SHARED TABLE. Every assertion here is ultimately about one
# property: a row this script emits has to be comparable to the rows above it in
# ~/Obsidian/no-it-all/briefs/usage-benchmark.md. Nothing in a row records which
# version of this script produced it, and session-lifecycle's End step 2 is
# "neither append nor overwrite" once a session has a row — so a counting change
# does not produce a wrong row, it produces a corrupted column that cannot be
# repaired afterwards.
#
# That is why the dedup case below is the first one and the loudest. This script
# shipped in the registry WITHOUT the dedup while the machine copy had it
# (skill-templates#207), so the documented bootstrap —
# `cp assets/scripts/usage-benchmark-row.py ~/.claude/scripts/` — handed a new
# machine the ~2.2x version. The drift was found by reading the two files side by
# side; nothing could fail for it.
#
# Fixtures are synthesized here, never read from a real transcript: the script
# treats transcript text as opaque and so does the harness.
#
# The suite does NOT `set -e` — an assertion that fails must be reported and the
# rest still run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/usage-benchmark-row.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/usage-benchmark-row-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

UUID=5fc4a59c-394b-4c35-b512-d3a38e4c241c   # -> the id column prints `5fc4a59c`

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
flat(){ printf '%s' "$1" | tr '\n' '|'; }

echo "usage-benchmark-row.test.sh"

# ------------------------------------------------------------------- fixtures
# gen <path> <turns> <blocks-per-turn> <key-mode>
#   key-mode: msgid | requestid | none
# Each TURN carries one usage object; each BLOCK repeats that same line, which is
# exactly the shape a real transcript has and exactly what dedup exists for.
#
# Per-turn weights: 1000*1 + 100000*0.1 + 5000*2 + 2000*5 = 31000 effective units.
gen() {
  "$PY" - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, turns, blocks, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
usage = {"input_tokens": 1000, "cache_read_input_tokens": 100000,
         "cache_creation_input_tokens": 5000, "output_tokens": 2000}
with open(path, "w", encoding="utf-8") as f:
    for i in range(turns):
        # 100 turns spread over two hours, so the duration column is a fixed 2.0.
        ts = "2026-08-11T%02d:%02d:00.000Z" % (i * 2 // turns, (i * 120 // turns) % 60)
        for b in range(blocks):
            rec = {"type": "assistant", "timestamp": ts,
                   "message": {"usage": dict(usage)}, "pad": "x" * 400}
            if mode == "msgid":
                rec["message"]["id"] = "msg_%d" % i
                rec["requestId"] = "req_%d" % i
            elif mode == "requestid":
                rec["requestId"] = "req_%d" % i
            f.write(json.dumps(rec) + "\n")
PY
}

# field <row> <n> — the nth pipe-delimited cell, whitespace stripped
field() { printf '%s' "$1" | awk -F'|' -v n="$2" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'; }
# row <args...> — stdout only, so the caller sees exactly what End step 2 appends
row() { out=$("$PY" "$SUT" "$@" 2>/dev/null); rc=$?; }

# ============================================ A — one turn counts once (#207)
echo; echo "A. dedup: one turn, one count"

A="$TMP/$UUID.jsonl"
gen "$A" 100 3 msgid
row "$A"
n=$(field "$out" 5); eff=$(field "$out" 6); tok=$(field "$out" 7)
[ "$rc" -eq 0 ] && [ "$n" = 100 ] \
  && ok "100 turns written as 3 content-block lines each count as 100, not 300" \
  || bad "100 turns written as 3 content-block lines each count as 100, not 300" \
         "rc=$rc turns='$n' row='$(flat "$out")'"
# The turn count alone is not enough: the whole row is inflated with it, and the
# effective-units column is the one the benchmark is actually read for.
[ "$eff" = 3.1 ] && [ "$tok" = 200 ] \
  && ok "the effective-units and output columns are per-TURN totals (3.1M / 200k), not per-line" \
  || bad "the effective-units and output columns are per-TURN totals (3.1M / 200k), not per-line" \
         "eff='$eff' out='$tok' row='$(flat "$out")'"

# The mutation this pins, run as a mutant: the same fixture through a copy of the
# script with the dedup removed must produce a DIFFERENT, inflated row. Without
# this the assertions above are also satisfied by a fixture that has no duplicate
# lines in it — which is how the defect survived: every prior check read a
# transcript shape that could not distinguish the two implementations.
sed -e 's/^        key = msg.get("id") or rec.get("requestId")$/        key = None/' \
    "$SUT" > "$TMP/undeduped.py"
if grep -q '^        key = None$' "$TMP/undeduped.py"; then
  mrow=$("$PY" "$TMP/undeduped.py" "$A" 2>/dev/null)
  [ "$(field "$mrow" 5)" = 300 ] \
    && ok "the fixture DISTINGUISHES the two implementations (undeduped: 300 turns)" \
    || bad "the fixture DISTINGUISHES the two implementations (undeduped: 300 turns)" \
           "mutant row='$(flat "$mrow")' — a fixture both versions agree on proves nothing"
else
  bad "the fixture DISTINGUISHES the two implementations (undeduped: 300 turns)" \
      "could not build the mutant: the dedup key line is not where this expects it"
fi

# `requestId` is the fallback for lines that carry no message id, and it has to
# dedup on its own — a transcript with only request ids is the arm that never runs
# when the fixture always has both.
B="$TMP/b1b2c3d4-0000-0000-0000-000000000000.jsonl"
gen "$B" 10 3 requestid
row "$B"
[ "$(field "$out" 5)" = 10 ] \
  && ok "lines with no message.id dedup on requestId" \
  || bad "lines with no message.id dedup on requestId" "$(flat "$out")"

# The other direction, and the reason this is a dedup and not a divisor: DISTINCT
# turns must stay distinct. A mutant that collapses everything to one row passes
# every assertion above.
C="$TMP/c1c2c3c4-0000-0000-0000-000000000000.jsonl"
gen "$C" 7 1 msgid
row "$C"
[ "$(field "$out" 5)" = 7 ] \
  && ok "seven distinct turns stay seven (dedup is by key, not a fixed divisor)" \
  || bad "seven distinct turns stay seven (dedup is by key, not a fixed divisor)" "$(flat "$out")"

# A line carrying NEITHER key cannot be told from a distinct turn, so it is
# counted. Dropping it would undercount, which corrupts the column just as much.
D="$TMP/d1d2d3d4-0000-0000-0000-000000000000.jsonl"
gen "$D" 4 1 none
row "$D"
[ "$(field "$out" 5)" = 4 ] \
  && ok "a line with neither message.id nor requestId is counted, not dropped" \
  || bad "a line with neither message.id nor requestId is counted, not dropped" "$(flat "$out")"

# ================================================ B — the rest of the row
echo; echo "B. the row's other columns"

row "$A"
[ "$(field "$out" 3)" = 5fc4a59c ] \
  && ok "the id column is the transcript's first 8 chars — the string the seed's \`session:\` carries" \
  || bad "the id column is the transcript's first 8 chars — the string the seed's \`session:\` carries" \
         "$(flat "$out")"
[ "$(field "$out" 2)" = 08-11 ] \
  && ok "the date column comes from the FIRST timestamp in the transcript" \
  || bad "the date column comes from the FIRST timestamp in the transcript" "$(flat "$out")"
[ "$(field "$out" 4)" = 2.0 ] \
  && ok "the duration column spans first to last timestamp, in hours" \
  || bad "the duration column spans first to last timestamp, in hours" "$(flat "$out")"
[ "$(field "$out" 9)" = "<workload note>" ] \
  && ok "the note column is a placeholder the caller replaces" \
  || bad "the note column is a placeholder the caller replaces" "$(flat "$out")"

# End step 2 appends stdout to the benchmark file, so the "where to put this"
# reminder must NOT be on stdout or it lands in the table.
full=$("$PY" "$SUT" "$A" 2>/dev/null)
[ "$(printf '%s\n' "$full" | wc -l | tr -d ' ')" -eq 1 ] \
  && ok "stdout is the row and nothing else (the reminder goes to stderr)" \
  || bad "stdout is the row and nothing else (the reminder goes to stderr)" "$(flat "$full")"

# Lines that are not assistant turns, lines that are not JSON, and turns with a
# zero usage object are all noise — but the timestamps on them still bound the
# session, which is why they are read before they are skipped.
E="$TMP/e1e2e3e4-0000-0000-0000-000000000000.jsonl"
{
  echo '{"type":"user","timestamp":"2026-08-11T00:00:00.000Z","message":{"content":"hi"}}'
  echo 'not json at all'
  echo '{"type":"assistant","timestamp":"2026-08-11T00:30:00.000Z","message":{"id":"z","usage":{"input_tokens":0,"output_tokens":0}}}'
  echo '{"type":"assistant","timestamp":"2026-08-11T01:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":5000,"output_tokens":2000}}}'
} > "$E"
row "$E"
[ "$rc" -eq 0 ] && [ "$(field "$out" 5)" = 1 ] && [ "$(field "$out" 4)" = 1.0 ] \
  && ok "user lines, malformed lines and zero-usage turns are skipped; timestamps still bound the run" \
  || bad "user lines, malformed lines and zero-usage turns are skipped; timestamps still bound the run" \
         "rc=$rc $(flat "$out")"

# ============================================== C — picking the transcript
echo; echo "C. transcript selection"

HOMEDIR="$TMP/home"; mkdir -p "$HOMEDIR/.claude/projects/-demo"
cp "$A" "$HOMEDIR/.claude/projects/-demo/$UUID.jsonl"
gen "$HOMEDIR/.claude/projects/-demo/0f0f0f0f-1111-2222-3333-444455556666.jsonl" 5 1 msgid
touch "$HOMEDIR/.claude/projects/-demo/$UUID.jsonl"      # make ours the newest

out=$(HOME="$HOMEDIR" "$PY" "$SUT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(field "$out" 3)" = 5fc4a59c ] \
  && ok "no argument: the most recently modified transcript under ~/.claude/projects" \
  || bad "no argument: the most recently modified transcript under ~/.claude/projects" \
         "rc=$rc $(flat "$out")"

out=$(HOME="$HOMEDIR" "$PY" "$SUT" 0f0f0f0f 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(field "$out" 3)" = 0f0f0f0f ] \
  && ok "a session-id prefix selects that session's transcript, not the newest" \
  || bad "a session-id prefix selects that session's transcript, not the newest" \
         "rc=$rc $(flat "$out")"

# An id that matches nothing must NOT silently fall back to the newest transcript:
# a row attributed to the wrong session is the same corrupted column by another
# route, and the caller cannot see it happen.
out=$(HOME="$HOMEDIR" "$PY" "$SUT" nosuchid 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && ok "an id matching no transcript exits nonzero instead of falling back to the newest" \
  || bad "an id matching no transcript exits nonzero instead of falling back to the newest" \
         "rc=$rc $(flat "$out")"

EMPTY="$TMP/emptyhome"; mkdir -p "$EMPTY/.claude/projects/-demo"
out=$(HOME="$EMPTY" "$PY" "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "no transcripts at all exits nonzero" \
  || bad "no transcripts at all exits nonzero" "rc=$rc $(flat "$out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
