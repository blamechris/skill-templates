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
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
# No __pycache__ beside the scripts: every run, mutants included, imports usage_accounting.
export PYTHONDONTWRITEBYTECODE=1
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/usage-benchmark-row-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# HERMETIC HOME. The script now looks for a session's subagents under
# ~/.claude/projects/*/<full uuid>/subagents (#254), so any case that does not
# redirect HOME reads whatever the machine running the suite happens to hold — and
# $UUID below is a REAL session id on the author's machine (65 real child files,
# 37.2M), which turned the note-column case in section B into a failure that only
# that machine could see. Cases that need a populated home still set HOME per
# command; everything else gets an empty one.
export HOME="$TMP/nohome"; mkdir -p "$HOME"

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
prefix = path.rsplit("/", 1)[-1]
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
                rec["message"]["id"] = "%s_msg_%d" % (prefix, i)
                rec["requestId"] = "%s_req_%d" % (prefix, i)
            elif mode == "requestid":
                rec["requestId"] = "%s_req_%d" % (prefix, i)
            f.write(json.dumps(rec) + "\n")
PY
}

# field <row> <n> — the nth pipe-delimited cell, whitespace stripped
field() { printf '%s' "$1" | awk -F'|' -v n="$2" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'; }
# wl <row> — the workload cell up to, and NOT including, the `· cost:` suffix. Sections
# A-G pin the placeholder, subagents and work suffixes; their fixtures carry no `model`,
# so every response is unpriced and the cost suffix is `$0.00–0.00 (<n> unpriced)` with a
# count that only echoes the fixture size. Section H pins the cost suffix itself.
wl() { field "$1" 9 | sed 's/ · cost: .*//'; }
# cost_of <row> — the cost suffix's text, after `· cost: `
cost_of() { field "$1" 9 | sed -n 's/.* · cost: //p'; }
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
[ "$(wl "$out")" = "<workload note> · subagents: 0.0M/0 · work: 0pr/0iss" ] \
  && ok "the note column is a placeholder plus a measured subagents suffix (one format, 0.0M/0 when none)" \
  || bad "the note column is a placeholder plus a measured subagents suffix (one format, 0.0M/0 when none)" "$(flat "$out")"

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

# CLAUDE_CODE_SESSION_ID is explicitly unset for these cases: this suite is
# normally run FROM a Claude session, where the variable is set and points at
# a transcript outside $HOMEDIR — so leaving it inherited would make these cases
# assert the environment rather than the script.
#
# No argument and no session id is a REFUSE, not a guess: the newest-mtime
# fallback that lived here resolved the WRONG session three times in the week
# of 2026-08-17, against a table that cannot be repaired once appended.
out=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && printf '%s' "$out" | grep -q '^REFUSE: ' \
  && ok "no argument and no session id REFUSES (prefix on stderr, no row emitted)" \
  || bad "no argument and no session id REFUSES (prefix on stderr, no row emitted)" \
         "rc=$rc $(flat "$out")"

out=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" 0f0f0f0f 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(field "$out" 3)" = 0f0f0f0f ] \
  && ok "a session-id prefix selects that session's transcript, not the newest" \
  || bad "a session-id prefix selects that session's transcript, not the newest" \
         "rc=$rc $(flat "$out")"

# An empty argument would wildcard the id glob into "every transcript, newest
# wins" — the removed fallback through a side door. Same for glob metacharacters.
out=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && ok "an empty argument REFUSES instead of matching every transcript" \
  || bad "an empty argument REFUSES instead of matching every transcript" "rc=$rc $(flat "$out")"
out=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" '*' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && ok "a glob-metachar argument REFUSES instead of wildcarding the id glob" \
  || bad "a glob-metachar argument REFUSES instead of wildcarding the id glob" "rc=$rc $(flat "$out")"

# An id that matches nothing must NOT silently fall back to the newest transcript:
# a row attributed to the wrong session is the same corrupted column by another
# route, and the caller cannot see it happen.
out=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" nosuchid 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && ok "an id matching no transcript exits nonzero instead of falling back to the newest" \
  || bad "an id matching no transcript exits nonzero instead of falling back to the newest" \
         "rc=$rc $(flat "$out")"

EMPTY="$TMP/emptyhome"; mkdir -p "$EMPTY/.claude/projects/-demo"
out=$(HOME="$EMPTY" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "no transcripts at all exits nonzero" \
  || bad "no transcripts at all exits nonzero" "rc=$rc $(flat "$out")"

# ====================== D — the row belongs to the session that ASKED for it
echo; echo "D. session resolution: concurrency"

# The defect: with no argument the script took the newest mtime across EVERY
# project and called it "the session you are ending". That is only true when one
# session runs at a time. Measured 2026-08-20 on a machine that routinely runs
# several: an Aeolus session ending at 01:21Z resolved a concurrently-active
# chroxy session and wrote a row carrying Aeolus's workload note with chroxy's
# id and chroxy's five counters. Wrong in the id AND every number, and by End
# step 2 ("neither append nor overwrite") the caller could not repair it.
#
# $HOMEDIR already holds two transcripts with $UUID (5fc4a59c) as the NEWEST,
# so "honours the session id" and "takes the newest" give different answers here
# — which is what makes these cases able to fail.

out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=0f0f0f0f-1111-2222-3333-444455556666 \
      "$PY" "$SUT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(field "$out" 3)" = 0f0f0f0f ] \
  && ok "CLAUDE_CODE_SESSION_ID wins over the newest transcript" \
  || bad "CLAUDE_CODE_SESSION_ID wins over the newest transcript" \
         "rc=$rc $(flat "$out")"

# The mutant, in this suite's own idiom: the same fixture through a copy that
# ignores the variable must produce a DIFFERENT row. Without this the case above
# is also satisfied by a script that happens to pick 0f0f0f0f for another reason
# — and "the fixture cannot distinguish the two implementations" is exactly how
# the dedup defect in section A survived.
sed -e 's/^    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()$/    sid = ""/' \
    "$SUT" > "$TMP/env-blind.py"
if grep -q '^    sid = ""$' "$TMP/env-blind.py"; then
  mrow=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=0f0f0f0f-1111-2222-3333-444455556666 \
         "$PY" "$TMP/env-blind.py" 2>/dev/null); mrc=$?
  # An env-blind script used to fall back to the newest transcript and emit a
  # WRONG row (5fc4a59c). The fallback is gone, so the mutant must now REFUSE —
  # a different observable from the real script's 0f0f0f0f row, and the stronger
  # property: blindness can no longer corrupt the table, only stop.
  [ "$mrc" -ne 0 ] && [ -z "$mrow" ] \
    && ok "the fixture DISTINGUISHES the two implementations (env-blind: REFUSES, no row)" \
    || bad "the fixture DISTINGUISHES the two implementations (env-blind: REFUSES, no row)" \
           "mrc=$mrc mutant row='$(flat "$mrow")' — a fixture both versions agree on proves nothing"
else
  bad "the fixture DISTINGUISHES the two implementations (env-blind: REFUSES, no row)" \
      "could not build the mutant: the env lookup is not where this expects it"
fi

# Set-but-unresolvable must NOT fall through to the newest transcript. That
# fall-through is the defect wearing a seatbelt: it still emits a plausible row
# for the wrong session, and the caller cannot see it happen.
out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=deadbeef-0000-0000-0000-000000000000 \
      "$PY" "$SUT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^| ' \
  && ok "a set-but-unresolvable session id exits nonzero instead of guessing" \
  || bad "a set-but-unresolvable session id exits nonzero instead of guessing" \
         "rc=$rc $(flat "$out")"

# An explicit argument still outranks the variable — the repair path for a row
# that has to be regenerated for some OTHER session.
out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=0f0f0f0f-1111-2222-3333-444455556666 \
      "$PY" "$SUT" 5fc4a59c 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(field "$out" 3)" = 5fc4a59c ] \
  && ok "an explicit argument outranks CLAUDE_CODE_SESSION_ID" \
  || bad "an explicit argument outranks CLAUDE_CODE_SESSION_ID" \
         "rc=$rc $(flat "$out")"

# Which transcript was chosen, and how, has to reach the caller — a silent right
# answer and a silent wrong answer look identical, and this script's failure mode
# is unrepairable once appended.
err=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=0f0f0f0f-1111-2222-3333-444455556666 \
      "$PY" "$SUT" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'resolved 0f0f0f0f via .CLAUDE_CODE_SESSION_ID' \
  && ok "stderr names the resolved session AND how it was resolved" \
  || bad "stderr names the resolved session AND how it was resolved" "$(flat "$err")"

# ...and the provenance line must not contaminate the row itself, which End
# step 2 appends verbatim.
printf '%s' "$err" | grep -q '^| ' \
  && bad "the provenance line goes to stderr, not into the row" "$(flat "$err")" \
  || ok "the provenance line goes to stderr, not into the row"

# ==================== E — the subagents suffix is measured, not hand-typed
echo; echo "E. subagents suffix"

# A session directory sits NEXT to its transcript: <dir>/<uuid>.jsonl plus
# <dir>/<uuid>/subagents/**/*.jsonl (workflow agents one level deeper). The
# suffix must count files and sum eff with the SAME dedup as the main loop.
SUBH="$TMP/subhome"; SDIR="$SUBH/.claude/projects/-demo"
mkdir -p "$SDIR/$UUID/subagents/workflows/wf_x"
cp "$A" "$SDIR/$UUID.jsonl"
# agent 1: 100 turns x 3 content-block lines — dedup must yield 3.1M, not 9.3M.
gen "$SDIR/$UUID/subagents/agent-1.jsonl" 100 3 msgid
# agent 2 (nested under workflows/): distinct keys so it does not collide with
# agent 1's msg_0..99 — real message ids are globally unique; gen's are not.
"$PY" - "$SDIR/$UUID/subagents/workflows/wf_x/agent-2.jsonl" <<'PY'
import json, sys
usage = {"input_tokens": 1000, "cache_read_input_tokens": 100000,
         "cache_creation_input_tokens": 5000, "output_tokens": 2000}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for i in range(100):
        rec = {"type": "assistant", "timestamp": "2026-08-11T03:00:00.000Z",
               "message": {"id": "wf_msg_%d" % i, "usage": dict(usage)}}
        f.write(json.dumps(rec) + "\n")
PY
out=$(HOME="$SUBH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$SDIR/$UUID.jsonl" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "<workload note> · subagents: 6.2M/2 · work: 0pr/0iss" ] \
  && ok "subagent transcripts are found (incl. nested workflows/), deduped, and emitted as 6.2M/2" \
  || bad "subagent transcripts are found (incl. nested workflows/), deduped, and emitted as 6.2M/2" \
         "rc=$rc $(flat "$out")"

# The main columns must NOT absorb the subagent numbers — the eff column stays
# main-only for comparability with every prior row.
[ "$(field "$out" 5)" = 100 ] && [ "$(field "$out" 6)" = 3.1 ] \
  && ok "main-thread columns are unchanged by subagent measurement (100 turns / 3.1M)" \
  || bad "main-thread columns are unchanged by subagent measurement (100 turns / 3.1M)" "$(flat "$out")"

# ============ F — the work numerator: nominated AND adjudicated, or nothing
echo; echo "F. work numerator"

# The numerator exists because the denominator was measured to death while the
# thing it was meant to improve was not measured at all: $/merged-PR doubled
# ($17 -> $34) across the five weeks in which wave restarts, tiering and the
# pace check were all built. Every assertion below is about ATTRIBUTION, which
# is the only hard part — three sessions overlap on this machine routinely, so
# a numerator that credits by time window alone credits all three for one PR.
#
# gh is stubbed. These tests must not depend on a network, on credentials, or on
# what happens to be merged today; the point is the FILTER, not GitHub.
GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = 1 ] && exit 1
[ "$1" = api ] && { printf 'testowner\n'; exit 0; }
if [ "$1" = search ]; then
  case "$2" in
    prs)    printf '%s\n' "${GH_PRS:-[]}"; exit 0 ;;
    issues) printf '%s\n' "${GH_ISS:-[]}"; exit 0 ;;
  esac
fi
exit 1
SH
chmod +x "$GHBIN/gh"

PRS='[{"number":7658,"repository":{"nameWithOwner":"blamechris/chroxy"}}]'
ISS='[{"number":7647,"repository":{"nameWithOwner":"blamechris/chroxy"}}]'

# gen_ref <path> <text embedded in every line> — a transcript that MENTIONS things
gen_ref() {
  "$PY" - "$1" "$2" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
usage = {"input_tokens": 1000, "cache_read_input_tokens": 100000,
         "cache_creation_input_tokens": 5000, "output_tokens": 2000}
with open(path, "w", encoding="utf-8") as f:
    for i in range(10):
        f.write(json.dumps({"type": "assistant",
                            "timestamp": "2026-08-11T0%d:00:00.000Z" % (i % 10),
                            "message": {"id": "msg_%d" % i, "usage": dict(usage)},
                            "pad": text}) + "\n")
PY
}
# work <path> — the work cell only, with the gh stub first on PATH
work() {
  local o
  o=$(PATH="$GHBIN:$PATH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$1" 2>/dev/null)
  printf '%s' "$(field "$o" 9)" | sed 's/.*· work: //; s/ · cost: .*//'
}

F="$TMP/$UUID.jsonl"

# Nominated AND merged in-window: the only case that scores.
gen_ref "$F" "shipped #7658 today, closing #7647"
got=$(GH_PRS="$PRS" GH_ISS="$ISS" work "$F")
[ "$got" = "1pr/1iss" ] \
  && ok "a PR and issue this session named, merged/closed in its window, are credited" \
  || bad "a PR and issue this session named, merged/closed in its window, are credited" "got=$got"

# ADJUDICATION WITHOUT NOMINATION — the concurrency case. Another session merged
# it inside this session's window; this session never mentioned it. Crediting it
# here is the same collision class as the newest-mtime fallback in pick_transcript.
gen_ref "$F" "a session that shipped nothing and named nothing"
got=$(GH_PRS="$PRS" GH_ISS="$ISS" work "$F")
[ "$got" = "0pr/0iss" ] \
  && ok "a PR merged in-window that this session never named is NOT credited" \
  || bad "a PR merged in-window that this session never named is NOT credited" "got=$got"

# NOMINATION WITHOUT ADJUDICATION — the reading-the-ledger case. gh IS consulted
# here and still credits nothing, which is the discrimination that matters: a
# report-only session naming a dozen open PRs must score zero.
gen_ref "$F" "reviewing open issues #999 and #1000, merging none"
got=$(GH_PRS="$PRS" GH_ISS="$ISS" work "$F")
[ "$got" = "0pr/0iss" ] \
  && ok "numbers this session named but did not merge/close are NOT credited" \
  || bad "numbers this session named but did not merge/close are NOT credited" "got=$got"

# A qualified reference carries a repo and must match it. Same number, different
# repo, is a different piece of work — #7658 exists in every repo eventually.
gen_ref "$F" "see https://github.com/blamechris/other-repo/pull/7658"
got=$(GH_PRS="$PRS" GH_ISS="$ISS" work "$F")
[ "$got" = "0pr/0iss" ] \
  && ok "a repo-qualified reference does not credit the same number in another repo" \
  || bad "a repo-qualified reference does not credit the same number in another repo" "got=$got"

# gh unreachable WITH candidates: genuinely unknown, and must say so. A 0 here
# would silently understate the numerator and corrupt the $/PR series.
gen_ref "$F" "shipped #7658 today"
got=$(GH_FAIL=1 work "$F")
[ "$got" = "n/a" ] \
  && ok "gh unreachable with candidates pending yields n/a, never a fabricated 0" \
  || bad "gh unreachable with candidates pending yields n/a, never a fabricated 0" "got=$got"

# gh unreachable WITHOUT candidates: NOT unknown. A session that named nothing
# is credited with nothing by definition, and no network can change that. This
# is why nomination runs before the gh call.
gen_ref "$F" "a session that named nothing at all"
got=$(GH_FAIL=1 work "$F")
[ "$got" = "0pr/0iss" ] \
  && ok "gh unreachable with NO candidates is a certain 0, not n/a" \
  || bad "gh unreachable with NO candidates is a certain 0, not n/a" "got=$got"

# The numerator must never disturb the columns above it — the whole file is one
# table read across sessions.
gen_ref "$F" "shipped #7658 today"
out=$(GH_PRS="$PRS" GH_ISS="$ISS" PATH="$GHBIN:$PATH" env -u CLAUDE_CODE_SESSION_ID \
      "$PY" "$SUT" "$F" 2>/dev/null)
[ "$(field "$out" 5)" = 10 ] && [ "$(field "$out" 6)" = 0.3 ] \
  && ok "the work suffix leaves the usage columns untouched" \
  || bad "the work suffix leaves the usage columns untouched" "$(flat "$out")"

# ======= G — one session, two project dirs: the subagent scan keys on the id (#254)
echo; echo "G. subagent scan across project dirs (worktree recycle)"

# The harness can recycle a session's worktree mid-run, and every worktree has its
# own project dir under ~/.claude/projects/. The main transcript is carried to the
# NEW dir; the subagent transcripts written before the recycle stay in the OLD one.
# A scan of only the dir beside the main transcript then undercounts silently —
# measured on session 5ae4397b: 1 of 22 child files, and a plausible-looking row.
# The old dir also holds OTHER sessions' transcripts (three, 124 files), so the fix
# is scoped by the session's full uuid and not by directory: sweeping that dir
# inflated the figure several-fold (88.4M against 14.3M under the pre-#259 dedup
# policy; the true session reads 18.2M under today's). Both halves are pinned below,
# plus a mutant for each property the scan advertises — sibling root, session-scoped
# glob, exact-uuid match, realpath dedupe, and the empty-dir holder check — so none
# of them can regress behind a fixture that happens to put everything in one dir.
#
# The discovery (which dirs to scan) and the split rule (when to warn) now live in
# usage_accounting.py, shared with usage-checkpoint.py (#377), so the mutants that
# edit them are built from a scratch copy of the script plus the helper — `mutant`
# below — and never from the real files.
#
# Project dirs are printed as REALPATHS, and $TMP sits under a symlinked /var on
# macOS, so expected dir strings are built with `pwd -P`, never from $TMP.
#
# Section F's last gen_ref REWROTE $A (F="$TMP/$UUID.jsonl" is the same path), so
# the 100-turn x 3-block main transcript is regenerated here, byte-identical to A.

# gen_distinct <path> <key-prefix> — 100 one-line turns whose message ids no other
# fixture shares (gen's ids are only unique per file NAME; real ones are global).
gen_distinct() {
  "$PY" - "$1" "$2" <<'PY'
import json, sys
usage = {"input_tokens": 1000, "cache_read_input_tokens": 100000,
         "cache_creation_input_tokens": 5000, "output_tokens": 2000}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for i in range(100):
        rec = {"type": "assistant", "timestamp": "2026-08-11T03:00:00.000Z",
               "message": {"id": "%s%d" % (sys.argv[2], i), "usage": dict(usage)}}
        f.write(json.dumps(rec) + "\n")
PY
}

RECH="$TMP/rechome"; GP="$RECH/.claude/projects"
OTHER=0d2a7f2c-aaaa-4bbb-8ccc-dddddddddddd    # a different session living in the OLD dir
mkdir -p "$GP/-demo-new/$UUID/subagents" "$GP/-demo-old/$UUID/subagents/workflows/wf_x" \
         "$GP/-demo-old/$OTHER/subagents"
GPR=$(cd "$GP" && pwd -P)    # the realpath form the script prints
# The NEW dir: the main transcript the recycle carried over, plus the one child
# written after it. The OLD dir: the children written before it — and NO main
# transcript, which is the real shape of a recycle.
gen "$GP/-demo-new/$UUID.jsonl" 100 3 msgid
gen "$GP/-demo-new/$UUID/subagents/agent-1.jsonl" 100 3 msgid
gen_distinct "$GP/-demo-old/$UUID/subagents/workflows/wf_x/agent-2.jsonl" wf_msg_
# A foreign session's children AND main transcript, in the same OLD dir.
gen "$GP/-demo-old/$OTHER/subagents/agent-x.jsonl" 100 3 msgid
gen "$GP/-demo-old/$OTHER.jsonl" 100 1 msgid

# mutant <name> <file> <sed-expr> — a scratch copy of the row script AND its helper
# (the script imports usage_accounting from its own directory, so the copy sees the
# edited one) with one sed edit applied to <file>. Prints the copy's row-script path;
# fails when the edit changed nothing, so a drifted pattern is a loud "could not build
# the mutant" and not a mutant that silently equals the original.
mutant() {
  local d="$TMP/mut-$1"
  mkdir -p "$d" && cp "$HERE/usage-benchmark-row.py" "$HERE/usage_accounting.py" "$d/" || return 1
  sed -e "$3" "$d/$2" > "$d/$2.new" && mv "$d/$2.new" "$d/$2" || return 1
  cmp -s "$d/$2" "$HERE/$2" && return 1
  printf '%s' "$d/usage-benchmark-row.py"
}

# Session-id mode is the acceptance mode: nothing names the OLD dir, only the uuid.
rec_run() { HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$@"; }
WANT_SPLIT="<workload note> · subagents: 6.2M/2 · work: 0pr/0iss"

out=$(rec_run 5fc4a59c 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "$WANT_SPLIT" ] \
  && ok "a session split over two project dirs totals 6.2M/2 — section E's single-dir figure for the same messages" \
  || bad "a session split over two project dirs totals 6.2M/2 — section E's single-dir figure for the same messages" \
         "rc=$rc $(flat "$out")"

# The other direction. The OLD dir holds a foreign session's children, so a
# directory sweep inflates this row; and the foreign session, resolved by its own
# id, must be exactly what it would have been had no recycle ever happened.
out=$(rec_run 5fc4a59c 2>/dev/null)
[ "$(wl "$out")" = "$WANT_SPLIT" ] \
  && ok "another session's children in the same old dir are NOT swept in (still 6.2M/2)" \
  || bad "another session's children in the same old dir are NOT swept in (still 6.2M/2)" "$(flat "$out")"
out=$(rec_run 0d2a7f2c 2>/dev/null); rc=$?
err=$(rec_run 0d2a7f2c 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
  && ! printf '%s' "$err" | grep -q 'WARNING: subagent transcripts' \
  && ok "a non-recycled session in a dir that also holds a recycled one is unchanged (3.1M/1, no warning)" \
  || bad "a non-recycled session in a dir that also holds a recycled one is unchanged (3.1M/1, no warning)" \
         "rc=$rc $(flat "$out") stderr=$(flat "$err")"

# The signal a reader needs: the figure is right, but the session was split. It has
# to name BOTH dirs — sorted, as realpaths, with the transcript's own dir marked so
# the reader can see where it moved to — and it has to be stderr: End step 2
# appends stdout verbatim.
err=$(rec_run 5fc4a59c 2>&1 >/dev/null)
blk=$(printf '%s\n' "$err" | sed -n '/^WARNING:/,/^  transcript:/p' | sed '1d;$d')
want_blk=$(printf '  %s\n  %s' "$GPR/-demo-new  (main transcript)" "$GPR/-demo-old")
printf '%s\n' "$err" | grep -q '^WARNING: subagent transcripts for 5fc4a59c found in 2 project dirs' \
  && printf '%s\n' "$err" | grep -qF 'skill-templates#254' \
  && [ "$blk" = "$want_blk" ] \
  && ok "a two-dir session warns on stderr and names BOTH project dirs (sorted, transcript's dir marked)" \
  || bad "a two-dir session warns on stderr and names BOTH project dirs (sorted, transcript's dir marked)" \
         "block='$(flat "$blk")' want='$(flat "$want_blk")' stderr=$(flat "$err")"

full=$(rec_run 5fc4a59c 2>/dev/null)
[ "$(printf '%s\n' "$full" | wc -l | tr -d ' ')" -eq 1 ] && ! printf '%s' "$full" | grep -q WARNING \
  && ok "the warning is not on stdout: it is still exactly one row line" \
  || bad "the warning is not on stdout: it is still exactly one row line" "$(flat "$full")"

err=$(HOME="$SUBH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$SDIR/$UUID.jsonl" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'WARNING: subagent transcripts' \
  && bad "a single-dir session (section E's fixture) does not warn" "$(flat "$err")" \
  || ok "a single-dir session (section E's fixture) does not warn"

# THE MUTANT. The same fixture through a copy whose glob is replaced by nothing —
# the old sibling-only behaviour — must read a DIFFERENT, lower figure with no
# warning. Without this, case one is also satisfied by a fixture that happens to
# put everything in one dir.
if MUT=$(mutant sibling-only usage_accounting.py 's|^    roots += sorted(glob.glob(.*$|    roots += []|'); then
  mrow=$(HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" 5fc4a59c 2>/dev/null)
  merr=$(HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" 5fc4a59c 2>&1 >/dev/null)
  [ "$(wl "$mrow")" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
    && ! printf '%s' "$merr" | grep -q 'WARNING: subagent transcripts' \
    && ok "the fixture DISTINGUISHES the two implementations (sibling-only: 3.1M/1, silently)" \
    || bad "the fixture DISTINGUISHES the two implementations (sibling-only: 3.1M/1, silently)" \
           "mutant row='$(flat "$mrow")' — a fixture both versions agree on proves nothing"
else
  bad "the fixture DISTINGUISHES the two implementations (sibling-only: 3.1M/1, silently)" \
      "could not build the mutant: the project-glob line is not where this expects it in usage_accounting.py"
fi

# Messages dedup across dirs by KEY, while FILES are counted as found: the same
# agent file present in both dirs is one set of messages (3.1M, not 6.2M) read
# from two files (count 2). The main transcript lives in one dir only.
DUP=3c3c3c3c-5555-4666-8777-888899990000
mkdir -p "$GP/-demo-new/$DUP/subagents" "$GP/-demo-old/$DUP/subagents"
gen "$GP/-demo-new/$DUP.jsonl" 100 1 msgid
gen "$GP/-demo-new/$DUP/subagents/agent-d.jsonl" 100 3 msgid
cp "$GP/-demo-new/$DUP/subagents/agent-d.jsonl" "$GP/-demo-old/$DUP/subagents/agent-d.jsonl"
out=$(rec_run 3c3c3c3c 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "<workload note> · subagents: 3.1M/2 · work: 0pr/0iss" ] \
  && ok "the same child messages in both dirs dedup by key across dirs (3.1M), files counted as found (2)" \
  || bad "the same child messages in both dirs dedup by key across dirs (3.1M), files counted as found (2)" \
         "rc=$rc $(flat "$out")"

# Explicit-path mode for a transcript that lives OUTSIDE ~/.claude/projects: the
# only place its children can be is beside it, so the sibling root must survive
# the move to a session-scoped glob. $RECH's projects dir holds no such uuid.
OUTSIDE="$TMP/outside"; OUTID=a4a4a4a4-9999-4aaa-8bbb-ccccddddeeee
mkdir -p "$OUTSIDE/$OUTID/subagents"
gen "$OUTSIDE/$OUTID.jsonl" 100 3 msgid
gen "$OUTSIDE/$OUTID/subagents/agent.jsonl" 100 3 msgid
out=$(rec_run "$OUTSIDE/$OUTID.jsonl" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
  && ok "an explicit .jsonl path outside ~/.claude/projects still counts its sibling subagents (3.1M/1)" \
  || bad "an explicit .jsonl path outside ~/.claude/projects still counts its sibling subagents (3.1M/1)" \
         "rc=$rc $(flat "$out")"
# ...and the mutant that proves it: a glob-only copy cannot find them at all.
if MUT=$(mutant glob-only usage_accounting.py 's|^    roots = \[os.path.join(base, "subagents")\]$|    roots = []|'); then
  mrow=$(HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$OUTSIDE/$OUTID.jsonl" 2>/dev/null)
  [ "$(wl "$mrow")" = "<workload note> · subagents: 0.0M/0 · work: 0pr/0iss" ] \
    && ok "the fixture DISTINGUISHES the two implementations (glob-only: 0.0M/0 outside projects)" \
    || bad "the fixture DISTINGUISHES the two implementations (glob-only: 0.0M/0 outside projects)" \
           "mutant row='$(flat "$mrow")'"
else
  bad "the fixture DISTINGUISHES the two implementations (glob-only: 0.0M/0 outside projects)" \
      "could not build the mutant: the sibling-root line is not where this expects it in usage_accounting.py"
fi

# subcount <row> — the file-count half of the subagents suffix (`<eff>M/<count>`)
subcount() { printf '%s' "$1" | sed -n 's/.*subagents: [0-9.]*M\/\([0-9]*\) .*/\1/p'; }

# ---- children ONLY in the old dir: the commonest recycle shape. Every subagent ran
# before the recycle, so the dir the main transcript moved to holds no children at
# all. The figure is right either way; the WARNING is the part a holder-only check
# loses, because it listed only dirs that held children — one dir, so no warning.
OLDONLY=7e7e7e7e-1111-4222-8333-444455556666
mkdir -p "$GP/-demo-old/$OLDONLY/subagents"
gen "$GP/-demo-new/$OLDONLY.jsonl" 100 3 msgid
gen "$GP/-demo-old/$OLDONLY/subagents/agent-a.jsonl" 100 3 msgid
gen "$GP/-demo-old/$OLDONLY/subagents/agent-b.jsonl" 100 3 msgid
out=$(rec_run 7e7e7e7e 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "$WANT_SPLIT" ] \
  && ok "children found only in the old dir (none beside the transcript) still total 6.2M/2" \
  || bad "children found only in the old dir (none beside the transcript) still total 6.2M/2" \
         "rc=$rc $(flat "$out")"
err=$(rec_run 7e7e7e7e 2>&1 >/dev/null)
printf '%s\n' "$err" | grep -q '^WARNING: subagent transcripts for 7e7e7e7e found in 2 project dirs' \
  && printf '%s\n' "$err" | grep -qxF "  $GPR/-demo-new  (main transcript)" \
  && printf '%s\n' "$err" | grep -qxF "  $GPR/-demo-old" \
  && ok "children only in the old dir WARN, naming both dirs, the transcript's own dir marked" \
  || bad "children only in the old dir WARN, naming both dirs, the transcript's own dir marked" "$(flat "$err")"

# ---- a near-miss uuid: the script prints sid[:8] everywhere, so an 8-char-prefix
# glob is the natural way to get this wrong. A complete foreign session sharing the
# first 8 chars lives in the old dir, in a home of its own: putting it in $RECH
# would make every prefix-argument case above resolve between two transcripts by
# mtime. The target is invoked by its FULL uuid, which matches only itself.
NEARH="$TMP/nearhome"; NP="$NEARH/.claude/projects"
NEAR=5fc4a59c-ffff-ffff-ffff-ffffffffffff
mkdir -p "$NP/-demo-new/$UUID/subagents" "$NP/-demo-old/$UUID/subagents/workflows/wf_x" \
         "$NP/-demo-old/$NEAR/subagents"
gen "$NP/-demo-new/$UUID.jsonl" 100 3 msgid
gen "$NP/-demo-new/$UUID/subagents/agent-1.jsonl" 100 3 msgid
gen_distinct "$NP/-demo-old/$UUID/subagents/workflows/wf_x/agent-2.jsonl" wf_msg_
gen "$NP/-demo-old/$NEAR.jsonl" 100 1 msgid
gen "$NP/-demo-old/$NEAR/subagents/agent.jsonl" 100 3 msgid
out=$(HOME="$NEARH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$UUID" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "$WANT_SPLIT" ] \
  && ok "a foreign session sharing the first 8 uuid chars is NOT swept in (6.2M/2 by full uuid)" \
  || bad "a foreign session sharing the first 8 uuid chars is NOT swept in (6.2M/2 by full uuid)" \
         "rc=$rc $(flat "$out")"
if MUT=$(mutant prefix-glob usage_accounting.py 's|glob.escape(sid), "subagents"|glob.escape(sid[:8]) + "*", "subagents"|'); then
  mrow=$(HOME="$NEARH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$UUID" 2>/dev/null)
  [ "$(subcount "$mrow")" -gt "$(subcount "$out")" ] 2>/dev/null \
    && ok "the fixture DISTINGUISHES the two implementations (8-char-prefix glob: sweeps the near-miss, count rises)" \
    || bad "the fixture DISTINGUISHES the two implementations (8-char-prefix glob: sweeps the near-miss, count rises)" \
           "real='$(flat "$out")' mutant='$(flat "$mrow")'"
else
  bad "the fixture DISTINGUISHES the two implementations (8-char-prefix glob: sweeps the near-miss, count rises)" \
      "could not build the mutant: the project-glob line is not where this expects it in usage_accounting.py"
fi

# ---- a relative explicit path: the sibling root (`./<uuid>/subagents`) and the glob
# hit for the SAME dir (`$HOME/.claude/projects/-demo-new/<uuid>/subagents`) are
# spelled differently, so only a realpath dedupe walks that dir once. The dir names
# the warning prints have to be absolute too — a bare `.` names nothing.
rel_run() { ( cd "$GP/-demo-new" && HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "${1:-$SUT}" "./$UUID.jsonl" ); }
abs=$(rec_run "$GP/-demo-new/$UUID.jsonl" 2>/dev/null)
rel=$(rel_run 2>/dev/null); rc=$?
relerr=$(rel_run 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(subcount "$rel")" = "$(subcount "$abs")" ] && [ "$(wl "$rel")" = "$WANT_SPLIT" ] \
  && ok "a relative explicit path counts the same files as the absolute one (spelling-independent dedupe, 6.2M/2)" \
  || bad "a relative explicit path counts the same files as the absolute one (spelling-independent dedupe, 6.2M/2)" \
         "rc=$rc rel='$(flat "$rel")' abs='$(flat "$abs")'"
printf '%s\n' "$relerr" | grep -q '^WARNING: subagent transcripts for 5fc4a59c' \
  && printf '%s\n' "$relerr" | grep -qxF "  $GPR/-demo-new  (main transcript)" \
  && printf '%s\n' "$relerr" | grep -qxF "  $GPR/-demo-old" \
  && ! printf '%s\n' "$relerr" | grep -q '^  \.' \
  && ok "a relative explicit path warns with ABSOLUTE project dirs (no bare \`.\`)" \
  || bad "a relative explicit path warns with ABSOLUTE project dirs (no bare \`.\`)" "$(flat "$relerr")"
if MUT=$(mutant spelling-dedupe usage_accounting.py 's|^        real = os.path.realpath(root)$|        real = root|'); then
  mrow=$(rel_run "$MUT" 2>/dev/null)
  [ "$(subcount "$mrow")" -gt "$(subcount "$rel")" ] 2>/dev/null \
    && ok "the fixture DISTINGUISHES the two implementations (spelling dedupe: walks the same dir twice, count rises)" \
    || bad "the fixture DISTINGUISHES the two implementations (spelling dedupe: walks the same dir twice, count rises)" \
           "real='$(flat "$rel")' mutant='$(flat "$mrow")'"
else
  bad "the fixture DISTINGUISHES the two implementations (spelling dedupe: walks the same dir twice, count rises)" \
      "could not build the mutant: the realpath line is not where this expects it in usage_accounting.py"
fi

# ---- an EMPTY subagents dir is not a holder: a session that otherwise lives in one
# dir must not be reported as split because an unrelated dir happens to carry an
# empty <uuid>/subagents/ (the harness creates them eagerly).
EMP=9d9d9d9d-aaaa-4bbb-8ccc-eeeeeeeeeeee
mkdir -p "$GP/-demo-new/$EMP/subagents" "$GP/-demo-empty/$EMP/subagents"
gen "$GP/-demo-new/$EMP.jsonl" 100 3 msgid
gen "$GP/-demo-new/$EMP/subagents/agent-e.jsonl" 100 3 msgid
out=$(rec_run 9d9d9d9d 2>/dev/null); rc=$?
err=$(rec_run 9d9d9d9d 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
  && ! printf '%s' "$err" | grep -q 'WARNING: subagent transcripts' \
  && ok "an empty <uuid>/subagents dir elsewhere is not a holder: count unchanged (3.1M/1), no warning" \
  || bad "an empty <uuid>/subagents dir elsewhere is not a holder: count unchanged (3.1M/1), no warning" \
         "rc=$rc $(flat "$out") stderr=$(flat "$err")"
if MUT=$(mutant empty-holder usage_accounting.py 's|^        if len(files) > before:$|        if True:|'); then
  merr=$(HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" 9d9d9d9d 2>&1 >/dev/null)
  printf '%s' "$merr" | grep -q 'WARNING: subagent transcripts for 9d9d9d9d found in 2 project dirs' \
    && ok "the fixture DISTINGUISHES the two implementations (empty-dir holder: the mutant warns)" \
    || bad "the fixture DISTINGUISHES the two implementations (empty-dir holder: the mutant warns)" \
           "mutant stderr=$(flat "$merr")"
else
  bad "the fixture DISTINGUISHES the two implementations (empty-dir holder: the mutant warns)" \
      "could not build the mutant: the holder check is not where this expects it in usage_accounting.py"
fi

# ---- three dirs: the WHOLE listing, in sorted order (#377). Every fixture above has
# two dirs, so none of them can tell a listing truncated to two entries from the real
# one, and with two dirs a missing sort() shows only when the hash order happens to
# invert (7 runs in 8). Three dirs, with the transcript's own dir the MIDDLE one
# alphabetically, pin the full list, the order and the marker's position at once.
# The order is a property of set iteration, which varies with the hash seed — and the
# paths carry a random mktemp suffix — so the listing is read under 12 seeds: a
# sort-less mutant then comes out sorted in all 12 with probability 6^-12, not 1/6.
TRI=2b2b2b2b-6666-4777-8888-999900001111
TRIH="$TMP/trihome"; TP="$TRIH/.claude/projects"
mkdir -p "$TP/-demo-mid/$TRI" "$TP/-demo-zzz/$TRI/subagents" "$TP/-demo-aaa/$TRI/subagents"
gen "$TP/-demo-mid/$TRI.jsonl" 100 3 msgid
gen_distinct "$TP/-demo-zzz/$TRI/subagents/agent-1.jsonl" z_msg_
gen_distinct "$TP/-demo-aaa/$TRI/subagents/agent-2.jsonl" a_msg_
TPR=$(cd "$TP" && pwd -P)
WANT_TRI=$(printf '  %s\n  %s\n  %s' "$TPR/-demo-aaa" "$TPR/-demo-mid  (main transcript)" "$TPR/-demo-zzz")

# tri_scan <row-script> — run the three-dir session under 12 hash seeds and sort each
# seed's outcome into four lists of seeds (space-separated, set as globals):
#   TRI_BAD       exit status not 0, or the row's workload cell is not WANT_SPLIT
#   TRI_INEXACT   the warning's dir lines are not WANT_TRI (all three, sorted, main marked)
#   TRI_NOTSET    the dir lines are not the three expected lines in SOME order
#   TRI_NOTFIRST2 the dir lines are not the first two expected lines, in order
# A mutant that merely crashes lands in TRI_BAD, so it cannot pass for a mutant that
# misbehaves in the specific way a case is about.
WANT_TRI_SET=$(printf '%s\n' "$WANT_TRI" | LC_ALL=C sort)
WANT_TRI_FIRST2=$(printf '%s\n' "$WANT_TRI" | head -2)
tri_scan() {
  local seed out rc err list
  TRI_BAD=""; TRI_INEXACT=""; TRI_NOTSET=""; TRI_NOTFIRST2=""
  for seed in 0 1 2 3 4 5 6 7 8 9 10 11; do
    out=$(PYTHONHASHSEED=$seed HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$1" "$TRI" 2>/dev/null); rc=$?
    err=$(PYTHONHASHSEED=$seed HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$1" "$TRI" 2>&1 >/dev/null)
    list=$(printf '%s\n' "$err" | sed -n '/^WARNING:/,/^  transcript:/p' | sed '1d;$d')
    { [ "$rc" -eq 0 ] && [ "$(wl "$out")" = "$WANT_SPLIT" ]; } || TRI_BAD="$TRI_BAD $seed"
    [ "$list" = "$WANT_TRI" ] || TRI_INEXACT="$TRI_INEXACT $seed"
    [ "$(printf '%s\n' "$list" | LC_ALL=C sort)" = "$WANT_TRI_SET" ] || TRI_NOTSET="$TRI_NOTSET $seed"
    [ "$list" = "$WANT_TRI_FIRST2" ] || TRI_NOTFIRST2="$TRI_NOTFIRST2 $seed"
  done
}

out=$(HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$TRI" 2>/dev/null); rc=$?
err=$(HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$TRI" 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = "$WANT_SPLIT" ] \
  && printf '%s\n' "$err" | grep -q '^WARNING: subagent transcripts for 2b2b2b2b found in 3 project dirs' \
  && ok "a three-dir session totals 6.2M/2 and the warning says 3 project dirs" \
  || bad "a three-dir session totals 6.2M/2 and the warning says 3 project dirs" \
         "rc=$rc $(flat "$out") stderr=$(flat "$err")"
tri_scan "$SUT"
[ -z "$TRI_BAD$TRI_INEXACT" ] \
  && ok "all three dirs are listed, sorted, the transcript's own (middle) dir marked — under 12 hash seeds" \
  || bad "all three dirs are listed, sorted, the transcript's own (middle) dir marked — under 12 hash seeds" \
         "bad seeds:$TRI_BAD; inexact seeds:$TRI_INEXACT; want='$(flat "$WANT_TRI")'"

# The mutants this pins. Each must still exit 0 and report the right total under EVERY
# seed (a crash is not the defect these are about), and then show its own defect:
# truncating the loop to two dirs lists the first two lines under every seed and never
# the third; removing the sort lists all three dirs, in an order the hash seed picks.
if MUT=$(mutant truncated-listing usage-benchmark-row.py 's|^    for d in split:$|    for d in split[:2]:|'); then
  tri_scan "$MUT"
  [ -z "$TRI_BAD" ] && [ -z "$TRI_NOTFIRST2" ] && [ -n "$TRI_INEXACT" ] \
    && ok "the fixture DISTINGUISHES the two implementations (listing truncated to 2 dirs: exit 0, right total, the third line lost under every seed)" \
    || bad "the fixture DISTINGUISHES the two implementations (listing truncated to 2 dirs: exit 0, right total, the third line lost under every seed)" \
           "bad seeds:$TRI_BAD; not-first-two seeds:$TRI_NOTFIRST2; inexact seeds:$TRI_INEXACT"
else
  bad "the fixture DISTINGUISHES the two implementations (listing truncated to 2 dirs: exit 0, right total, the third line lost under every seed)" \
      "could not build the mutant: the listing loop is not where this expects it"
fi
if MUT=$(mutant unsorted-listing usage_accounting.py 's#sorted(holders | {main_dir})#list(holders | {main_dir})#'); then
  tri_scan "$MUT"
  [ -z "$TRI_BAD" ] && [ -z "$TRI_NOTSET" ] && [ -n "$TRI_INEXACT" ] \
    && ok "the fixture DISTINGUISHES the two implementations (no sort: exit 0, right total, all three dirs listed, in an order the hash seed picks)" \
    || bad "the fixture DISTINGUISHES the two implementations (no sort: exit 0, right total, all three dirs listed, in an order the hash seed picks)" \
           "bad seeds:$TRI_BAD; not-the-three-dirs seeds:$TRI_NOTSET; inexact seeds:$TRI_INEXACT (empty = sorted under all 12, about a 6^-12 chance)"
else
  bad "the fixture DISTINGUISHES the two implementations (no sort: exit 0, right total, all three dirs listed, in an order the hash seed picks)" \
      "could not build the mutant: the split rule's return line is not where this expects it in usage_accounting.py"
fi

# ===== H — the cost suffix, and what it is set against (the tier's reference figure)
echo; echo "H. cost suffix and tier reference figures"

# The row used to carry two measured suffixes and the dollars sat on stderr, where they
# were copied into the workload note by hand. The cost is now the third suffix, and a
# package that names its risk tier sees it set against that tier's reference figure.
#
# NOTHING IN THIS SECTION TYPES A FIGURE. Every number — the four dollar figures and the
# 1.5 factor — is read from `--figures`, because the figures are a decision that gets
# revised and a test that hard-codes them turns each revision into a test edit. What is
# typed here is only fixture arithmetic that is true whatever the figures are: at the
# claude-opus-5 input rate ($5 per million tokens) a token count converts to dollars
# exactly, so a fixture can be built to land on a boundary to the token.
#
# Fixtures carry `"model": "claude-opus-5"` — sections A-G's carry none, which prices
# nothing — and omit inference_geo, so the upper bound is the lower bound x 1.1 and a
# test that confused the two would see it.

# ---- precondition: the rate card these fixtures are built on. About thirty assertions below
# turn a token count into exact dollars at claude-opus-5's input rate and read the upper
# bound as 1.1x the lower (no inference_geo on the fixtures), and they need a made-up model
# to be unpriced. If the card moves, those assertions fail for a reason that has nothing to
# do with the cost suffix; this one says so first.
pre=$("$PY" - <<'PY'
from decimal import Decimal as D
import usage_accounting as u
got = u.price_usage({"input_tokens": 1000000}, "claude-opus-5")
try:
    u.price_usage({"input_tokens": 1000}, "claude-mystery-9"); mystery = "priced"
except ValueError:
    mystery = "unpriced"
if got["lower_usd"] != D(5) or got["upper_usd"] != D("5.5") or mystery != "unpriced":
    print("claude-opus-5 x 1,000,000 input tokens priced %s-%s (want 5-5.5); claude-mystery-9 is %s (want unpriced)"
          % (got["lower_usd"], got["upper_usd"], mystery))
PY
)
[ -z "$pre" ] \
  && ok "precondition: the rate card prices claude-opus-5 input at \$5/M with a 1.1x upper bound, and claude-mystery-9 is unpriced" \
  || bad "precondition: the rate card prices claude-opus-5 input at \$5/M with a 1.1x upper bound, and claude-mystery-9 is unpriced" \
         "$pre — section H's fixtures assume exactly this and must be rebuilt if the rate card changed"

FIG=$("$PY" "$SUT" --figures 2>/dev/null)
fig() { printf '%s\n' "$FIG" | awk -v t="$1" '$1 == t { print $2 }'; }
OVER=$(fig over)
TIERS="low medium high-single high-panel"

COSTD="$TMP/cost"; mkdir -p "$COSTD"
P="$COSTD/c1c1c1c1-0000-4000-8000-000000000000.jsonl"

# gen_priced <path> <parent-input-tokens> <child-input-tokens> <unpriced-parent> [<unpriced-child>]
# The priced parent response (when tokens > 0), one priced child response (when tokens > 0,
# in the sibling <uuid>/subagents dir), N parent responses naming a model the rate card has
# no price for, and M such responses in the child transcript (default 0; the subagents dir
# is made when there are child tokens or child unpriced responses). Message ids are unique
# within the fixture.
gen_priced() {
  "$PY" - "$@" <<'PY'
import json, os, shutil, sys
path, ptok, ctok, nun = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
cun = int(sys.argv[5]) if len(sys.argv) > 5 else 0
base = path[:-len(".jsonl")]
shutil.rmtree(base, ignore_errors=True)
def line(tag, i, tokens, model):
    msg = {"id": "%s_%s_%d" % (os.path.basename(base), tag, i), "model": model,
           "usage": {"input_tokens": tokens}}
    return json.dumps({"type": "assistant", "timestamp": "2026-08-11T01:00:00.000Z",
                       "message": msg}) + "\n"
with open(path, "w", encoding="utf-8") as f:
    if ptok:
        f.write(line("p", 0, ptok, "claude-opus-5"))
    for i in range(nun):
        f.write(line("u", i, 1000, "claude-mystery-9"))
if ctok or cun:
    os.makedirs(base + "/subagents")
    with open(base + "/subagents/agent-1.jsonl", "w", encoding="utf-8") as f:
        if ctok:
            f.write(line("c", 0, ctok, "claude-opus-5"))
        for i in range(cun):
            f.write(line("cu", i, 1000, "claude-mystery-9"))
PY
}

# tok <figure> <over-factor> <ratio-base> <ratio-offset> <delta-tokens> — the fixture
# arithmetic, in the test's own Python: prints "<parent tokens> <child tokens> <ratio
# shown> <over|ok>" for a session whose all-in lower bound is figure x (base + offset)
# dollars plus delta input tokens. The ratio is rounded half up to two places and "over"
# is strict on the exact values — the rule, restated here so the script is checked
# against a second statement of it. NONINTEGRAL means the figure cannot be hit with
# whole tokens.
tok() {
  "$PY" - "$@" <<'PY'
import sys
from decimal import Decimal as D, ROUND_HALF_UP
fig, over, base, off, delta = D(sys.argv[1]), D(sys.argv[2]), D(sys.argv[3]), D(sys.argv[4]), int(sys.argv[5])
exact = fig * (base + off) * 200000          # $5 per million input tokens
if exact != exact.to_integral_value():
    print("NONINTEGRAL NONINTEGRAL NONINTEGRAL NONINTEGRAL"); sys.exit(0)
t = int(exact) + delta
shown = (D(t) / 200000 / fig).quantize(D("0.01"), ROUND_HALF_UP)
print(t // 2, t - t // 2, format(shown, "f"), "over" if D(t) > over * fig * 200000 else "ok")
PY
}

# vs_of <row> — the " vs $<figure> <tier> (<ratio>)" tail of the cost suffix, or empty
vs_of() { cost_of "$1" | sed -n 's/.*\( vs .*\)$/\1/p'; }
# vs_text <tier> <figure> <shown> <over|ok> [≥] — that tail, as it must read
vs_text() { printf ' vs $%s %s (%s%sx%s)' "$2" "$1" "${5:-}" "$3" "$([ "$4" = over ] && printf ', over %sx' "$OVER")"; }

# ---- the table the rest of this section stands on
printf '%s\n' "$FIG" | awk 'BEGIN { split("low medium high-single high-panel over", w, " ") }
  NF == 2 && $1 == w[NR] && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { n++ } END { exit !(NR == 5 && n == 5) }' \
  && ok "--figures prints the four tiers in order and then the factor, one 'name number' pair per line" \
  || bad "--figures prints the four tiers in order and then the factor, one 'name number' pair per line" "$(flat "$FIG")"

# ---- the suffix with no tier
gen_priced "$P" 1000000 2000000 0
row "$P"
[ "$rc" -eq 0 ] && [ "$(wl "$out")" = '<workload note> · subagents: 2.0M/1 · work: 0pr/0iss' ] \
  && ok "the subagents and work suffixes are unchanged in front of the cost suffix" \
  || bad "the subagents and work suffixes are unchanged in front of the cost suffix" "rc=$rc $(flat "$out")"
[ "$(field "$out" 9)" = '<workload note> · subagents: 2.0M/1 · work: 0pr/0iss · cost: $15.00–16.50' ] \
  && ok "no tier: the cost suffix is the all-in range, parent plus children (\$5+\$10 .. \$5.50+\$11), en dash, last in the cell" \
  || bad "no tier: the cost suffix is the all-in range, parent plus children (\$5+\$10 .. \$5.50+\$11), en dash, last in the cell" "$(flat "$out")"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
  && ok "stdout is still exactly the one row line" \
  || bad "stdout is still exactly the one row line" "$(flat "$out")"

# Half up, on the cent: 1000 input tokens = $0.005 exactly (upper $0.0055). Half even
# would print 0.00 for the lower bound.
gen_priced "$COSTD/c2c2c2c2-0000-4000-8000-000000000000.jsonl" 1000 0 0
row "$COSTD/c2c2c2c2-0000-4000-8000-000000000000.jsonl"
[ "$(cost_of "$out")" = '$0.01–0.01' ] \
  && ok "dollars round half up to the cent (\$0.005 -> 0.01, \$0.0055 -> 0.01)" \
  || bad "dollars round half up to the cent (\$0.005 -> 0.01, \$0.0055 -> 0.01)" "$(flat "$out")"

# ---- each tier: the figure named, the ratio on the LOWER bound, "over" only past the factor
HFAIL_UNDER=""; HFAIL_ABOVE=""; HFAIL_HALF=""; HFAIL_NOTOK=""
B="$COSTD/c3c3c3c3-0000-4000-8000-000000000000.jsonl"
for t in $TIERS; do
  f=$(fig "$t")
  # a ratio comfortably under the factor
  read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" -0.70 0)"
  if [ "$pt" = NONINTEGRAL ]; then HFAIL_NOTOK="$HFAIL_NOTOK $t"; continue; fi
  gen_priced "$B" "$pt" "$ct" 0; row "$B" --tier "$t"
  [ "$rc" -eq 0 ] && [ "$(vs_of "$out")" = "$(vs_text "$t" "$f" "$shown" "$flag")" ] \
    || HFAIL_UNDER="$HFAIL_UNDER $t(got '$(vs_of "$out")')"
  # a ratio above it
  read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" 0.11 0)"
  gen_priced "$B" "$pt" "$ct" 0; row "$B" --tier "$t"
  [ "$rc" -eq 0 ] && [ "$flag" = over ] && [ "$(vs_of "$out")" = "$(vs_text "$t" "$f" "$shown" over)" ] \
    || HFAIL_ABOVE="$HFAIL_ABOVE $t(got '$(vs_of "$out")')"
  # a ratio of ...5 in the third place, which half up and half even round differently
  read -r pt ct shown flag <<< "$(tok "$f" "$OVER" 0 1.625 0)"
  gen_priced "$B" "$pt" "$ct" 0; row "$B" --tier "$t"
  [ "$rc" -eq 0 ] && [ "$shown" = 1.63 ] && [ "$(vs_of "$out")" = "$(vs_text "$t" "$f" 1.63 "$flag")" ] \
    || HFAIL_HALF="$HFAIL_HALF $t(got '$(vs_of "$out")')"
done
[ -z "$HFAIL_NOTOK" ] \
  && ok "fixtures: every figure converts to whole tokens (the arithmetic below is exact)" \
  || bad "fixtures: every figure converts to whole tokens (the arithmetic below is exact)" \
         "not whole for:$HFAIL_NOTOK — a figure that is not a multiple of \$0.000005 needs a different fixture rate"
[ -z "$HFAIL_UNDER" ] \
  && ok "each tier, under the factor: ' vs \$<figure> <tier> (<ratio>x)' with no 'over'" \
  || bad "each tier, under the factor: ' vs \$<figure> <tier> (<ratio>x)' with no 'over'" "$HFAIL_UNDER"
[ -z "$HFAIL_ABOVE" ] \
  && ok "each tier, past the factor: the ratio is followed by ', over <factor>x'" \
  || bad "each tier, past the factor: the ratio is followed by ', over <factor>x'" "$HFAIL_ABOVE"
[ -z "$HFAIL_HALF" ] \
  && ok "each tier: a ratio of 1.625 reads 1.63x (rounded half up, not half even)" \
  || bad "each tier: a ratio of 1.625 reads 1.63x (rounded half up, not half even)" "$HFAIL_HALF"

# ---- the boundary. Exactly the factor times the figure is NOT over; a token above is.
# One input token is $0.000005, so the ratio reads the SAME at both ends (1.50x) while the
# verdict flips: "over" is decided on the unrounded values, not on the number printed.
# Split between parent and child, so the all-in sum is on the boundary too.
BFAIL=""
for t in $TIERS; do
  f=$(fig "$t")
  for spec in -1:ok 0:ok 1:over 2000:over; do   # 2000 tokens = one cent
    d=${spec%%:*}; want=${spec##*:}
    read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" 0 "$d")"
    gen_priced "$B" "$pt" "$ct" 0; row "$B" --tier "$t"
    [ "$rc" -eq 0 ] && [ "$flag" = "$want" ] && [ "$(vs_of "$out")" = "$(vs_text "$t" "$f" "$shown" "$want")" ] \
      || BFAIL="$BFAIL $t@$d(want $want, got '$(vs_of "$out")')"
  done
done
[ -z "$BFAIL" ] \
  && ok "the boundary: a token under and exactly 1.5x the figure are NOT over; a token and a cent above ARE (all four tiers, parent+child split)" \
  || bad "the boundary: a token under and exactly 1.5x the figure are NOT over; a token and a cent above ARE (all four tiers, parent+child split)" "$BFAIL"

# ---- unpriced responses: the range is a subtotal and must not read as a total
U="$COSTD/c4c4c4c4-0000-4000-8000-000000000000.jsonl"
gen_priced "$U" 1000000 0 3
row "$U"
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = '$5.00–5.50 (3 unpriced)' ] \
  && ok "unpriced, no tier: the range is followed by ' (3 unpriced)'" \
  || bad "unpriced, no tier: the range is followed by ' (3 unpriced)'" "rc=$rc $(flat "$out")"
f=$(fig high-panel)
shown=$("$PY" -c 'import sys; from decimal import Decimal as D, ROUND_HALF_UP; print((D(5) / D(sys.argv[1])).quantize(D("0.01"), ROUND_HALF_UP))' "$f")
row "$U" --tier high-panel
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = "\$5.00–5.50 (3 unpriced) vs \$$f high-panel (≥${shown}x)" ] \
  && ok "unpriced, with a tier: the marker follows the range and the ratio reads '≥'" \
  || bad "unpriced, with a tier: the marker follows the range and the ratio reads '≥'" "rc=$rc $(flat "$out")"
read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" 0 1)"
gen_priced "$U" "$pt" "$ct" 3; row "$U" --tier high-panel
[ "$rc" -eq 0 ] && [ "$flag" = over ] \
  && [ "$(vs_of "$out")" = "$(vs_text high-panel "$f" "$shown" over '≥')" ] \
  && cost_of "$out" | grep -q ' (3 unpriced) vs ' \
  && ok "unpriced and over: '(3 unpriced) vs ... (≥<ratio>x, over <factor>x)' — a subtotal past the factor is still over" \
  || bad "unpriced and over: '(3 unpriced) vs ... (≥<ratio>x, over <factor>x)' — a subtotal past the factor is still over" "rc=$rc $(flat "$out")"
gen_priced "$B" 1000000 2000000 0; row "$B" --tier low
case "$(cost_of "$out")" in
  *unpriced*|*"≥"*) bad "a fully priced session carries neither the marker nor the '≥'" "$(flat "$out")" ;;
  *) ok "a fully priced session carries neither the marker nor the '≥'" ;;
esac

# ratio_of <dollars> <figure> — dollars / figure, rounded half up to two places
ratio_of() { "$PY" -c 'import sys; from decimal import Decimal as D, ROUND_HALF_UP; print((D(sys.argv[1]) / D(sys.argv[2])).quantize(D("0.01"), ROUND_HALF_UP))' "$1" "$2"; }

# An unpriced response in a CHILD transcript counts like one in the parent: the loop that
# prices responses is shared, but a count that skipped children would still read as a
# total for every session whose unpriced responses were subagent work.
fhp=$(fig high-panel); r5=$(ratio_of 5 "$fhp")
C1="$COSTD/c5c5c5c5-0000-4000-8000-000000000000.jsonl"
gen_priced "$C1" 1000000 0 0 1
row "$C1"
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = '$5.00–5.50 (1 unpriced)' ] \
  && ok "an unpriced response only in a child transcript still reads ' (1 unpriced)'" \
  || bad "an unpriced response only in a child transcript still reads ' (1 unpriced)'" "rc=$rc $(flat "$out")"
row "$C1" --tier high-panel
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = "\$5.00–5.50 (1 unpriced) vs \$$fhp high-panel (≥${r5}x)" ] \
  && ok "an unpriced child response, with a tier: the marker follows the range and the ratio reads '≥'" \
  || bad "an unpriced child response, with a tier: the marker follows the range and the ratio reads '≥'" "rc=$rc $(flat "$out")"
gen_priced "$C1" 1000000 2000000 0 1
row "$C1"
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = '$15.00–16.50 (1 unpriced)' ] \
  && ok "a priced child and an unpriced child response together: the range is the priced sum, marked (1 unpriced)" \
  || bad "a priced child and an unpriced child response together: the range is the priced sum, marked (1 unpriced)" "rc=$rc $(flat "$out")"

# Exactly ONE unpriced response, in the parent: a count of one is a count (a test of
# 'more than one' would pass every fixture above, which all have three or a child's one).
S1="$COSTD/c6c6c6c6-0000-4000-8000-000000000000.jsonl"
gen_priced "$S1" 1000000 0 1
row "$S1"
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = '$5.00–5.50 (1 unpriced)' ] \
  && ok "exactly one unpriced parent response reads ' (1 unpriced)'" \
  || bad "exactly one unpriced parent response reads ' (1 unpriced)'" "rc=$rc $(flat "$out")"
row "$S1" --tier high-panel
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = "\$5.00–5.50 (1 unpriced) vs \$$fhp high-panel (≥${r5}x)" ] \
  && ok "exactly one unpriced response, with a tier: '(1 unpriced) vs ... (≥<ratio>x)'" \
  || bad "exactly one unpriced response, with a tier: '(1 unpriced) vs ... (≥<ratio>x)'" "rc=$rc $(flat "$out")"
# Nothing priced at all: the range is a subtotal of nothing, and must still say so.
N0="$COSTD/c7c7c7c7-0000-4000-8000-000000000000.jsonl"
gen_priced "$N0" 0 0 1
row "$N0"
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = '$0.00–0.00 (1 unpriced)' ] \
  && ok "nothing priced and one unpriced response: '\$0.00–0.00 (1 unpriced)'" \
  || bad "nothing priced and one unpriced response: '\$0.00–0.00 (1 unpriced)'" "rc=$rc $(flat "$out")"
fl=$(fig low)
row "$N0" --tier low
[ "$rc" -eq 0 ] && [ "$(cost_of "$out")" = "\$0.00–0.00 (1 unpriced) vs \$$fl low (≥0.00x)" ] \
  && ok "nothing priced, one unpriced response, with a tier: '\$0.00–0.00 (1 unpriced) vs \$<figure> low (≥0.00x)'" \
  || bad "nothing priced, one unpriced response, with a tier: '\$0.00–0.00 (1 unpriced) vs \$<figure> low (≥0.00x)'" "rc=$rc $(flat "$out")"

# ---- argument order and spelling
gen_priced "$P" 1000000 2000000 0
row "$P" --tier medium;   r1=$out
row --tier medium "$P";   r2=$out
row --tier=medium "$P";   r3=$out
row "$P" --tier=medium;   r4=$out
fm=$(fig medium)
[ -n "$r1" ] && [ "$r1" = "$r2" ] && [ "$r1" = "$r3" ] && [ "$r1" = "$r4" ] \
  && case "$(vs_of "$r1")" in " vs \$$fm medium ("*) true ;; *) false ;; esac \
  && ok "'<path> --tier X', '--tier X <path>', '--tier=X <path>' and '<path> --tier=X' emit the same row" \
  || bad "'<path> --tier X', '--tier X <path>', '--tier=X <path>' and '<path> --tier=X' emit the same row" \
         "1='$(flat "$r1")' 2='$(flat "$r2")' 3='$(flat "$r3")' 4='$(flat "$r4")'"
fh=$(fig high-single)
a=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" --tier high-single 0f0f0f0f 2>/dev/null)
b=$(HOME="$HOMEDIR" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" 0f0f0f0f --tier high-single 2>/dev/null)
c=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID=0f0f0f0f-1111-2222-3333-444455556666 "$PY" "$SUT" --tier high-single 2>/dev/null)
[ "$(field "$a" 3)" = 0f0f0f0f ] && [ "$a" = "$b" ] && [ "$a" = "$c" ] \
  && case "$(vs_of "$a")" in " vs \$$fh high-single ("*) true ;; *) false ;; esac \
  && ok "a session id works in either order, and with only \$CLAUDE_CODE_SESSION_ID set" \
  || bad "a session id works in either order, and with only \$CLAUDE_CODE_SESSION_ID set" \
         "a='$(flat "$a")' b='$(flat "$b")' c='$(flat "$c")'"

# ---- every unreadable argument shape is a REFUSE: exit 1, nothing on stdout
# refuses <label> <text the message must carry> <args...>
refuses() {
  local label=$1 want=$2 o e rc2; shift 2
  o=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$@" 2>"$TMP/refuse.err"); rc2=$?
  e=$(cat "$TMP/refuse.err")
  [ "$rc2" -eq 1 ] && [ -z "$o" ] && printf '%s\n' "$e" | grep -q '^REFUSE: ' && printf '%s' "$e" | grep -qF -- "$want" \
    && ok "REFUSES $label (exit 1, empty stdout, 'REFUSE:' naming the problem)" \
    || bad "REFUSES $label (exit 1, empty stdout, 'REFUSE:' naming the problem)" \
           "rc=$rc2 stdout='$(flat "$o")' stderr='$(flat "$e")' want '$want'"
}
refuses "an unknown tier" "unknown tier" --tier nope "$P"
# the message lists every valid tier, so a typo is repaired from it
o=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" --tier nope "$P" 2>&1)
miss=""; for t in $TIERS; do printf '%s' "$o" | grep -qF "$t" || miss="$miss $t"; done
[ -z "$miss" ] \
  && ok "the unknown-tier message lists all four valid tiers" \
  || bad "the unknown-tier message lists all four valid tiers" "missing:$miss in '$(flat "$o")'"
refuses "an upper-case tier" "unknown tier" --tier LOW "$P"
refuses "--tier with no value (last argument)" "needs a value" "$P" --tier
refuses "--tier with no value (only argument)" "needs a value" --tier
refuses "--tier= with nothing after it" "needs a value" --tier= "$P"
refuses "--tier followed by an option instead of a value" "needs a value" --tier --figures
refuses "--tier given twice" "twice" --tier low --tier low "$P"
refuses "--tier given twice, in both spellings" "twice" --tier=low --tier medium "$P"
refuses "an unknown option" "unknown option" --bogus "$P"
refuses "a short option" "unknown option" -t low "$P"
refuses "more than one session argument" "more than one" "$P" "$P"
refuses "--figures beside a session argument" "--figures" --figures "$P"
refuses "--figures given twice" "given twice" --figures --figures
refuses "--figures beside a tier" "--figures" --figures --tier low
# nothing on stdout also means no row for a valid session when the shape is wrong
o=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" --tier nope "$P" 2>/dev/null)
[ -z "$o" ] \
  && ok "a bad tier never leaves a row on stdout, even for a transcript that resolves" \
  || bad "a bad tier never leaves a row on stdout, even for a transcript that resolves" "$(flat "$o")"

# ---- --figures: before any transcript is resolved
NOFIG="$TMP/nofig"; mkdir -p "$NOFIG"
o=$(HOME="$NOFIG" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" --figures 2>"$TMP/fig.err"); rc2=$?
[ "$rc2" -eq 0 ] && [ -z "$(cat "$TMP/fig.err")" ] && [ "$o" = "$FIG" ] \
  && ok "--figures exits 0 with no session id, an empty HOME and nothing on stderr" \
  || bad "--figures exits 0 with no session id, an empty HOME and nothing on stderr" \
         "rc=$rc2 stderr='$(cat "$TMP/fig.err")' stdout='$(flat "$o")'"
printf '%s\n' "$o" | grep -qvE '^[a-z-]+ [0-9.]+$' \
  && bad "--figures lines are lower-case 'name<space>number' and nothing else" "$(flat "$o")" \
  || ok "--figures lines are lower-case 'name<space>number' and nothing else"

# ---- stderr: the dollars stay, a reference line follows, and the closing line says three
gen_priced "$P" 1000000 2000000 0
e0=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$P" 2>&1 >/dev/null)
e1=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$P" --tier high-panel 2>&1 >/dev/null)
# (Decimal keeps the exponent it was built with, so the raw sums read 15.00–16.500: the line is
# the script's existing one and prints them raw, hence the optional zeros.)
printf '%s\n' "$e1" | grep -qF 'model-priced USD (' && printf '%s\n' "$e1" | grep -qE 'all-in 15(\.0+)?–16\.5(0+)?; 0 unpriced responses' \
  && ok "the model-priced USD line is still on stderr, unchanged" \
  || bad "the model-priced USD line is still on stderr, unchanged" "$(flat "$e1")"
fp=$(fig high-panel)
printf '%s\n' "$e1" | grep -qF "reference: high-panel figure \$$fp;" && ! printf '%s' "$e1" | grep -q 'must say why' \
  && ok "with a tier: stderr names the tier, its figure and the lower bound (and no 'must say why' while under)" \
  || bad "with a tier: stderr names the tier, its figure and the lower bound (and no 'must say why' while under)" "$(flat "$e1")"
n1=$(printf '%s\n' "$e1" | grep -n 'model-priced USD' | cut -d: -f1); n2=$(printf '%s\n' "$e1" | grep -n 'reference: ' | cut -d: -f1)
[ -n "$n1" ] && [ "$n2" = "$((n1 + 1))" ] \
  && ok "the reference line comes straight after the model-priced USD line" \
  || bad "the reference line comes straight after the model-priced USD line" "model-priced at $n1, reference at $n2"
read -r pt ct shown flag <<< "$(tok "$fp" "$OVER" "$OVER" 0.11 0)"
gen_priced "$B" "$pt" "$ct" 0
eo=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$B" --tier high-panel 2>&1 >/dev/null)
printf '%s' "$eo" | grep -qF "passed $OVER times its reference figure" && printf '%s' "$eo" | grep -qF 'workload note must say why' \
  && ok "past the factor: stderr says the package passed $OVER times its figure and the workload note must say why" \
  || bad "past the factor: stderr says the package passed $OVER times its figure and the workload note must say why" "$(flat "$eo")"
miss=""; for t in $TIERS; do printf '%s' "$e0" | grep -qF "$t" || miss="$miss $t"; done
printf '%s' "$e0" | grep -qF 'no --tier given' && printf '%s' "$e0" | grep -qF 'no reference comparison' && [ -z "$miss" ] \
  && ! printf '%s' "$e0" | grep -q 'reference: ' \
  && ok "no tier: stderr says nothing was compared and names the four tiers" \
  || bad "no tier: stderr says nothing was compared and names the four tiers" "missing:$miss $(flat "$e0")"
printf '%s' "$e0" | grep -qF 'three measured suffixes' \
  && ok "the closing line says the measured suffixes are three" \
  || bad "the closing line says the measured suffixes are three" "$(flat "$e0")"

# ---- the WHOLE reference line, not its prefix. The prefix checks above pass a line that
# prints the upper bound where the lower belongs, a wrong ratio, a dropped '≥', a dropped or
# miscounted subtotal note, or no 'must say why' sentence for a package that is both over and
# unpriced. The expected line is built from `--figures` (the figure and the factor), from
# the row's OWN stdout (the lower bound) and from the test's own ratio arithmetic (`tok`),
# never from typed dollars.
REFU="$COSTD/d1d1d1d1-0000-4000-8000-000000000000.jsonl"   # fully priced, under the factor
REFO="$COSTD/d2d2d2d2-0000-4000-8000-000000000000.jsonl"   # fully priced, over
REFN="$COSTD/d3d3d3d3-0000-4000-8000-000000000000.jsonl"   # over, ONE unpriced response (a child's)
fp=$(fig high-panel)
read -r pt ct shown flag <<< "$(tok "$fp" "$OVER" "$OVER" -0.70 0)"; gen_priced "$REFU" "$pt" "$ct" 0 0; SHOWN_U=$shown
read -r pt ct shown flag <<< "$(tok "$fp" "$OVER" "$OVER" 0.11 0)";  gen_priced "$REFO" "$pt" "$ct" 0 0; SHOWN_O=$shown
gen_priced "$REFN" "$pt" "$ct" 0 1; SHOWN_N=$shown

# ref_exact <row-script> <fixture> <ratio shown> <'≥' or ''> <unpriced count> <over|ok>
# Returns 0 when the stderr 'reference:' line is exactly the expected one, 1 when it is not
# (REF_GOT / REF_WANT then hold both), 2 when the script produced no row at all.
ref_exact() {
  local script=$1 fx=$2 shown=$3 geq=$4 un=$5 isover=$6 o lower
  o=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$script" "$fx" --tier high-panel 2>"$TMP/ref.err")
  [ -n "$o" ] || { REF_GOT="(no row)"; REF_WANT=""; return 2; }
  REF_GOT=$(grep '^  reference: ' "$TMP/ref.err")
  lower=$(cost_of "$o" | sed -n 's/^\$\([0-9.]*\)–.*/\1/p')
  REF_WANT="  reference: high-panel figure \$$fp; all-in lower bound \$$lower; ratio ${geq}${shown}x"
  [ "$un" -gt 0 ] && REF_WANT="$REF_WANT ($un unpriced, so the lower bound is a subtotal)"
  [ "$isover" = over ] && REF_WANT="$REF_WANT. This package passed $OVER times its reference figure: the workload note must say why."
  [ "$REF_GOT" = "$REF_WANT" ]
}
# ref_caught <row-script> — the cases (U, O, N) whose line is NOT exact, then "!" and the
# cases that produced no row at all
ref_caught() {
  local mism="" norow="" r
  ref_exact "$1" "$REFU" "$SHOWN_U" "" 0 ok;  r=$?; [ $r = 1 ] && mism="${mism}U"; [ $r = 2 ] && norow="${norow}U"
  ref_exact "$1" "$REFO" "$SHOWN_O" "" 0 over; r=$?; [ $r = 1 ] && mism="${mism}O"; [ $r = 2 ] && norow="${norow}O"
  ref_exact "$1" "$REFN" "$SHOWN_N" "≥" 1 over; r=$?; [ $r = 1 ] && mism="${mism}N"; [ $r = 2 ] && norow="${norow}N"
  printf '%s!%s' "$mism" "$norow"
}
for c in "U:$REFU:$SHOWN_U::0:ok:under the factor and fully priced" \
         "O:$REFO:$SHOWN_O::0:over:over and fully priced" \
         "N:$REFN:$SHOWN_N:≥:1:over:over with ONE unpriced response"; do
  IFS=: read -r _ fx sh gq un ov label <<< "$c"
  if ref_exact "$SUT" "$fx" "$sh" "$gq" "$un" "$ov"; then
    ok "the whole stderr reference line is exact: $label"
  else
    bad "the whole stderr reference line is exact: $label" "got  '$REF_GOT'" 
    printf '       want %s\n' "'$REF_WANT'"
  fi
done

# ---- the doctrine sync. The `reference-figures` rule in assets/global-CLAUDE.md states the
# four dollar amounts and the factor in prose; the script's table is where they live. Prose
# that drifts from the table is a rule nobody can check a row against, so the rule's own
# paragraph is held to `--figures` here.
DOC="$HERE/../global-CLAUDE.md"
# doctrine_problems <file> <figures-text> — one line per disagreement, nothing when they agree
doctrine_problems() {
  "$PY" - "$1" "$2" <<'PY'
import re, sys
from decimal import Decimal
doc, figs = sys.argv[1], sys.argv[2]
want = {}
for line in figs.splitlines():
    parts = line.split()
    if len(parts) == 2:
        want[parts[0]] = Decimal(parts[1])
try:
    lines = open(doc, encoding="utf-8").read().splitlines()
except OSError as e:
    print("cannot read %s: %s" % (doc, e)); sys.exit(0)
at = [i for i, l in enumerate(lines) if l.strip() == "<!--default:reference-figures-->"]
if len(at) != 1:
    print("token: <!--default:reference-figures--> appears %d times, want exactly 1" % len(at)); sys.exit(0)
para = []
for l in lines[at[0] + 1:]:
    if not l.strip():
        break
    para.append(l.strip())
para = " ".join(para)
N = r"(\d+(?:\.\d+)?)"
for anchor, pat, keys in (
        ("LOW or MEDIUM package:", r"LOW or MEDIUM package:\s*\*\*\$" + N + r"\*\*", ("low", "medium")),
        ("one-reviewer exception:", r"one-reviewer exception:\s*\*\*\$" + N + r"\*\*", ("high-single",)),
        ("panel depth:", r"panel depth:\s*\*\*\$" + N + r"\*\*", ("high-panel",)),
        ("N times", r"\*\*" + N + r" times\*\*", ("over",))):
    found = re.findall(pat, para)
    if len(found) != 1:
        print("%s: found %d bold amounts after the anchor, want exactly 1" % (anchor, len(found))); continue
    for key in keys:
        if key not in want:
            print("%s: --figures has no '%s' line" % (anchor, key))
        elif Decimal(found[0]) != want[key]:
            print("%s: the rule says %s, --figures says %s %s" % (anchor, found[0], key, want[key]))
# The names the rule and the script share: every tier --figures prints is named, in
# backticks, in this paragraph, and the paragraph shows the flag they go with. A tier renamed
# on either side is a rule that tells a session to pass a value the script refuses.
for name in want:
    if name != "over" and "`%s`" % name not in para:
        print("tier name: `%s` (a tier --figures prints) does not appear backticked in the rule's first paragraph" % name)
if "usage-benchmark-row.py --tier" not in para:
    print("flag: the literal 'usage-benchmark-row.py --tier' does not appear in the rule's first paragraph")
PY
}
# mutate_doc <in> <out> <which> [<tier name>] — a copy of the rule with ONE thing broken
mutate_doc() {
  "$PY" - "$1" "$2" "$3" "${4:-}" <<'PY'
import re, sys
from decimal import Decimal
src, dst, what, tier = sys.argv[1:5]
tok = "<!--default:reference-figures-->"
head, sep, rest = open(src, encoding="utf-8").read().partition(tok)
if not sep:
    sys.exit(2)
N = r"(\d+(?:\.\d+)?)"
def bump(m):
    return m.group(1) + format(Decimal(m.group(2)) + 1, "f") + m.group(3)
if what == "token":
    out = head + "<!--default:reference-figure-->" + rest
elif what in ("tier", "flag"):
    # every occurrence inside the first paragraph (up to the first blank line)
    cut = rest.find("\n\n")
    first, after = (rest, "") if cut < 0 else (rest[:cut], rest[cut:])
    if what == "tier":
        new = first.replace("`%s`" % tier, "`%s-renamed`" % tier)
    else:
        new = first.replace("usage-benchmark-row.py --tier", "usage-benchmark-row.py --level")
    if new == first:
        sys.exit(2)
    out = head + tok + new + after
else:
    pat = {"low": r"(LOW or MEDIUM package:\s*\*\*\$)" + N + r"()",
           "single": r"(one-reviewer exception:\s*\*\*\$)" + N + r"()",
           "panel": r"(panel depth:\s*\*\*\$)" + N + r"()",
           "factor": r"(\*\*)" + N + r"( times\*\*)",
           "anchor": r"(panel depth)(:)()"}[what]
    if what == "anchor":
        new, n = re.subn(pat, r"\1 -", rest, count=1)
    else:
        new, n = re.subn(pat, bump, rest, count=1)
    if n != 1:
        sys.exit(2)
    out = head + tok + new
open(dst, "w", encoding="utf-8").write(out)
PY
}

got=$(doctrine_problems "$DOC" "$FIG")
[ -z "$got" ] \
  && ok "doctrine sync: the reference-figures rule's three dollar amounts and its '1.5 times' agree with --figures" \
  || bad "doctrine sync: the reference-figures rule's three dollar amounts and its '1.5 times' agree with --figures" "$(flat "$got")"

# ---- every test above must be able to fail. Each mutant breaks one property in a local
# copy under $TMP; the case it targets must then see the break.
# the boundary: three ways to get "over" wrong
f=$(fig high-panel)
read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" 0 0)";  gen_priced "$COSTD/m1m1m1m1-0000-4000-8000-000000000000.jsonl" "$pt" "$ct" 0
read -r pt ct shown flag <<< "$(tok "$f" "$OVER" "$OVER" 0 1)";  gen_priced "$COSTD/m2m2m2m2-0000-4000-8000-000000000000.jsonl" "$pt" "$ct" 0
EXACT="$COSTD/m1m1m1m1-0000-4000-8000-000000000000.jsonl"; HAIR="$COSTD/m2m2m2m2-0000-4000-8000-000000000000.jsonl"
OVERLINE='^    over = lower > OVER_FACTOR \* figure$'
if MUT=$(mutant over-ge usage-benchmark-row.py "s/$OVERLINE/    over = lower >= OVER_FACTOR * figure/"); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$EXACT" --tier high-panel 2>/dev/null)
  case "$(vs_of "$mrow")" in *", over "*) ok "the fixture DISTINGUISHES the two implementations (>= instead of >: exactly 1.5x reads over)" ;;
    *) bad "the fixture DISTINGUISHES the two implementations (>= instead of >: exactly 1.5x reads over)" "mutant row='$(flat "$mrow")'" ;; esac
else
  bad "the fixture DISTINGUISHES the two implementations (>= instead of >: exactly 1.5x reads over)" "could not build the mutant: the 'over' line is not where this expects it"
fi
if MUT=$(mutant over-rounded usage-benchmark-row.py "s/$OVERLINE/    over = ratio > OVER_FACTOR/"); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$HAIR" --tier high-panel 2>/dev/null)
  rrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$HAIR" --tier high-panel 2>/dev/null)
  case "$(vs_of "$rrow")" in *", over "*) real_over=1 ;; *) real_over="" ;; esac
  case "$(vs_of "$mrow")" in *", over "*) mut_over=1 ;; *) mut_over="" ;; esac
  [ -n "$real_over" ] && [ -z "$mut_over" ] && [ -n "$mrow" ] \
    && ok "the fixture DISTINGUISHES the two implementations (verdict on the rounded ratio: a token past 1.5x reads 1.50x and loses its 'over')" \
    || bad "the fixture DISTINGUISHES the two implementations (verdict on the rounded ratio: a token past 1.5x reads 1.50x and loses its 'over')" \
           "real='$(vs_of "$rrow")' mutant='$(vs_of "$mrow")'"
else
  bad "the fixture DISTINGUISHES the two implementations (verdict on the rounded ratio: a token past 1.5x reads 1.50x and loses its 'over')" "could not build the mutant: the 'over' line is not where this expects it"
fi
if MUT=$(mutant over-upper usage-benchmark-row.py "s/$OVERLINE/    over = upper > OVER_FACTOR * figure/"); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$EXACT" --tier high-panel 2>/dev/null)
  case "$(vs_of "$mrow")" in *", over "*) ok "the fixture DISTINGUISHES the two implementations (verdict on the UPPER bound: exactly 1.5x lower reads over)" ;;
    *) bad "the fixture DISTINGUISHES the two implementations (verdict on the UPPER bound: exactly 1.5x lower reads over)" "mutant row='$(flat "$mrow")'" ;; esac
else
  bad "the fixture DISTINGUISHES the two implementations (verdict on the UPPER bound: exactly 1.5x lower reads over)" "could not build the mutant: the 'over' line is not where this expects it"
fi
# rounding: half even instead of half up, on the cent and on the ratio
if MUT=$(mutant half-even usage-benchmark-row.py 's/ROUND_HALF_UP/ROUND_HALF_EVEN/g'); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$COSTD/c2c2c2c2-0000-4000-8000-000000000000.jsonl" 2>/dev/null)
  read -r pt ct shown flag <<< "$(tok "$f" "$OVER" 0 1.625 0)"; gen_priced "$B" "$pt" "$ct" 0
  mrat=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$B" --tier high-panel 2>/dev/null)
  [ "$(cost_of "$mrow")" = '$0.00–0.01' ] && [ "$(vs_of "$mrat")" != "$(vs_text high-panel "$f" 1.63 "$flag")" ] \
    && ok "the fixture DISTINGUISHES the two implementations (half even: \$0.005 reads 0.00 and 1.625x does not read 1.63x)" \
    || bad "the fixture DISTINGUISHES the two implementations (half even: \$0.005 reads 0.00 and 1.625x does not read 1.63x)" \
           "cents='$(cost_of "$mrow")' ratio='$(vs_of "$mrat")'"
else
  bad "the fixture DISTINGUISHES the two implementations (half even: \$0.005 reads 0.00 and 1.625x does not read 1.63x)" "could not build the mutant: ROUND_HALF_UP is not in the script"
fi
# the unpriced marker, and the '≥'
gen_priced "$U" 1000000 0 3
if MUT=$(mutant no-marker usage-benchmark-row.py 's/^    cost_note += f" ({unpriced} unpriced)"$/    pass/'); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$U" --tier high-panel 2>/dev/null)
  case "$(cost_of "$mrow")" in *unpriced*) bad "the fixture DISTINGUISHES the two implementations (no marker: the range reads as a total)" "mutant row='$(flat "$mrow")'" ;;
    '') bad "the fixture DISTINGUISHES the two implementations (no marker: the range reads as a total)" "the mutant emitted no cost suffix" ;;
    *) ok "the fixture DISTINGUISHES the two implementations (no marker: the range reads as a total)" ;; esac
else
  bad "the fixture DISTINGUISHES the two implementations (no marker: the range reads as a total)" "could not build the mutant: the marker line is not where this expects it"
fi
if MUT=$(mutant no-geq usage-benchmark-row.py 's|^    ratio_note = ("[^"]*" if unpriced else "")|    ratio_note = ("")|'); then
  mrow=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$U" --tier high-panel 2>/dev/null)
  case "$(cost_of "$mrow")" in
    *'(3 unpriced)'*'≥'*|'') bad "the fixture DISTINGUISHES the two implementations (no '≥': a subtotal's ratio reads as exact)" "mutant row='$(flat "$mrow")'" ;;
    *'(3 unpriced)'*) ok "the fixture DISTINGUISHES the two implementations (no '≥': a subtotal's ratio reads as exact)" ;;
    *) bad "the fixture DISTINGUISHES the two implementations (no '≥': a subtotal's ratio reads as exact)" "mutant row='$(flat "$mrow")'" ;; esac
else
  bad "the fixture DISTINGUISHES the two implementations (no '≥': a subtotal's ratio reads as exact)" "could not build the mutant: the ratio line is not where this expects it"
fi
# the count itself: an unpriced response in a CHILD, and a count of exactly one. Each mutant
# must still print a row; the defect is read off the cost cell it prints.
# mut_cost <name> <sed-expr> <fixture> [args...] — the mutant's cost cell, or BUILD-FAILED /
# NO-ROW, so a mutant that did not build (or crashed) can never pass for one that misbehaves.
mut_cost() {
  local name=$1 expr=$2 m o; shift 2
  m=$(mutant "$name" usage-benchmark-row.py "$expr") || { printf 'BUILD-FAILED'; return; }
  o=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$m" "$@" 2>/dev/null)
  [ -n "$o" ] || { printf 'NO-ROW'; return; }
  cost_of "$o"
}
gen_priced "$C1" 1000000 0 0 1
got=$(mut_cost child-unpriced 's/^        unpriced += 1$/        unpriced += 0 if item["role"] == "child" else 1/' "$C1")
[ "$got" = '$5.00–5.50' ] \
  && ok "the fixture DISTINGUISHES the two implementations (children's unpriced responses not counted: the marker vanishes)" \
  || bad "the fixture DISTINGUISHES the two implementations (children's unpriced responses not counted: the marker vanishes)" "mutant cost='$got'"
got=$(mut_cost marker-gt1 's/^if unpriced:$/if unpriced > 1:/' "$S1")
[ "$got" = '$5.00–5.50' ] \
  && ok "the fixture DISTINGUISHES the two implementations (marker only for MORE than one unpriced: a single one vanishes)" \
  || bad "the fixture DISTINGUISHES the two implementations (marker only for MORE than one unpriced: a single one vanishes)" "mutant cost='$got'"
# ...and the '≥' lost only at a count of one, judged on the row it prints (marker kept, '≥' gone)
GEQ1='s/^\(    ratio_note = ("[^"]*" if unpriced\) else/\1 > 1 else/'
got=$(mut_cost geq-gt1-one "$GEQ1" "$S1" --tier high-panel)
[ "$got" = "\$5.00–5.50 (1 unpriced) vs \$$fhp high-panel (${r5}x)" ] \
  && ok "the fixture DISTINGUISHES the two implementations ('≥' only for MORE than one unpriced: one unpriced response reads as an exact ratio)" \
  || bad "the fixture DISTINGUISHES the two implementations ('≥' only for MORE than one unpriced: one unpriced response reads as an exact ratio)" "mutant cost='$got'"
got=$(mut_cost geq-gt1-none "$GEQ1" "$N0" --tier low)
[ "$got" = "\$0.00–0.00 (1 unpriced) vs \$$fl low (0.00x)" ] \
  && ok "the fixture DISTINGUISHES the two implementations ('≥' only for MORE than one unpriced: nothing priced reads as an exact 0.00x)" \
  || bad "the fixture DISTINGUISHES the two implementations ('≥' only for MORE than one unpriced: nothing priced reads as an exact 0.00x)" "mutant cost='$got'"

# the whole stderr reference line: seven ways to get it wrong, each caught by the cases that
# should see it and by no others (U/O/N = the three fixtures above), and every mutant still
# prints a row for all three.
RM_NAME=(up-for-low wrong-ratio geq-dropped note-dropped note-count note-gt1 no-why-unpriced)
RM_EXPR=(
  's/all-in lower bound \${cents(lower)}/all-in lower bound ${cents(upper)}/'
  's/{fmt(ratio)}x")$/{fmt(ratio + CENT)}x")/'
  "s/{'[^']*' if unpriced else ''}//"
  's/^        line += f" ({unpriced} unpriced, so the lower bound is a subtotal)"$/        pass/'
  's/ ({unpriced} unpriced, so/ ({unpriced + 1} unpriced, so/'
  's/^    if unpriced:$/    if unpriced > 1:/'
  's/line += (f". This package/line += ("" if unpriced else f". This package/'
)
RM_WANT=(UON UON N N N N N)
RM_WHAT=("the upper bound printed as the lower bound" "a wrong ratio" "the '≥' dropped" "the subtotal note dropped"
         "the subtotal note's count wrong" "the subtotal note only for MORE than one unpriced"
         "no 'must say why' sentence once the package is also unpriced")
for i in 0 1 2 3 4 5 6; do
  if MUT=$(mutant "ref-${RM_NAME[$i]}" usage-benchmark-row.py "${RM_EXPR[$i]}"); then
    res=$(ref_caught "$MUT"); mism=${res%%!*}; norow=${res##*!}
    [ -z "$norow" ] && [ "$mism" = "${RM_WANT[$i]}" ] \
      && ok "the fixture DISTINGUISHES the two implementations (reference line, ${RM_WHAT[$i]}: caught by case ${RM_WANT[$i]})" \
      || bad "the fixture DISTINGUISHES the two implementations (reference line, ${RM_WHAT[$i]}: caught by case ${RM_WANT[$i]})" \
             "cases with a wrong line: '$mism'; cases with no row: '$norow'"
  else
    bad "the fixture DISTINGUISHES the two implementations (reference line, ${RM_WHAT[$i]}: caught by case ${RM_WANT[$i]})" \
        "could not build the mutant: the line is not where this expects it"
  fi
done
# --figures given twice: a copy that lets the repeat through prints the table instead of refusing
if MUT=$(mutant figures-twice usage-benchmark-row.py 's/^            if figures:$/            if False:/'); then
  mout=$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" --figures --figures 2>/dev/null); mrc=$?
  [ "$mrc" -eq 0 ] && [ "$mout" = "$FIG" ] \
    && ok "the fixture DISTINGUISHES the two implementations (--figures --figures let through: it prints the table)" \
    || bad "the fixture DISTINGUISHES the two implementations (--figures --figures let through: it prints the table)" "rc=$mrc out='$(flat "$mout")'"
else
  bad "the fixture DISTINGUISHES the two implementations (--figures --figures let through: it prints the table)" "could not build the mutant: the repeat check is not where this expects it"
fi
# the doctrine sync: the rule's paragraph, broken six ways, and the table, broken two
LASTTIER=${TIERS##* }
for what in token low single panel factor anchor tier flag; do
  case "$what" in tier) must="tier name: \`$LASTTIER\`" ;; flag) must="flag: " ;; *) must="" ;; esac
  if mutate_doc "$DOC" "$TMP/doc-$what.md" "$what" "$LASTTIER"; then
    got=$(doctrine_problems "$TMP/doc-$what.md" "$FIG")
    [ -n "$got" ] && printf '%s\n' "$got" | grep -qF -- "$must" \
      && ok "the fixture DISTINGUISHES the two implementations (rule paragraph broken: $what)" \
      || bad "the fixture DISTINGUISHES the two implementations (rule paragraph broken: $what)" "the sync check passed a broken rule, or did not name it: '$(flat "$got")'"
  else
    bad "the fixture DISTINGUISHES the two implementations (rule paragraph broken: $what)" \
        "could not build the mutant: the rule's token or anchor is not where this expects it in $DOC"
  fi
done
if MUT=$(mutant fig-table usage-benchmark-row.py 's/\("high-single": Decimal("\)[0-9.]*/\1999/'); then
  got=$(doctrine_problems "$DOC" "$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" --figures 2>/dev/null)")
  [ -n "$got" ] \
    && ok "the fixture DISTINGUISHES the two implementations (script table changed: the sync check sees the rule disagree)" \
    || bad "the fixture DISTINGUISHES the two implementations (script table changed: the sync check sees the rule disagree)" "passed"
else
  bad "the fixture DISTINGUISHES the two implementations (script table changed: the sync check sees the rule disagree)" "could not build the mutant: the table row is not where this expects it"
fi
if MUT=$(mutant fig-name usage-benchmark-row.py 's/"high-single": Decimal/"high-one": Decimal/'); then
  got=$(doctrine_problems "$DOC" "$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" --figures 2>/dev/null)")
  printf '%s\n' "$got" | grep -qF 'tier name: `high-one`' \
    && ok "the fixture DISTINGUISHES the two implementations (script tier renamed: the sync check wants the new name backticked in the rule)" \
    || bad "the fixture DISTINGUISHES the two implementations (script tier renamed: the sync check wants the new name backticked in the rule)" "$(flat "$got")"
else
  bad "the fixture DISTINGUISHES the two implementations (script tier renamed: the sync check wants the new name backticked in the rule)" "could not build the mutant: the table row is not where this expects it"
fi
if MUT=$(mutant fig-factor usage-benchmark-row.py 's/^OVER_FACTOR = Decimal("[0-9.]*")/OVER_FACTOR = Decimal("2")/'); then
  got=$(doctrine_problems "$DOC" "$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" --figures 2>/dev/null)")
  [ -n "$got" ] \
    && ok "the fixture DISTINGUISHES the two implementations (script factor changed: the sync check sees the rule disagree)" \
    || bad "the fixture DISTINGUISHES the two implementations (script factor changed: the sync check sees the rule disagree)" "passed"
else
  bad "the fixture DISTINGUISHES the two implementations (script factor changed: the sync check sees the rule disagree)" "could not build the mutant: the factor line is not where this expects it"
fi


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
