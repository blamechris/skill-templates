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
[ "$(field "$out" 9)" = "<workload note> · subagents: 0.0M/0 · work: 0pr/0iss" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "<workload note> · subagents: 6.2M/2 · work: 0pr/0iss" ] \
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
  printf '%s' "$(field "$o" 9)" | sed 's/.*· work: //'
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "$WANT_SPLIT" ] \
  && ok "a session split over two project dirs totals 6.2M/2 — section E's single-dir figure for the same messages" \
  || bad "a session split over two project dirs totals 6.2M/2 — section E's single-dir figure for the same messages" \
         "rc=$rc $(flat "$out")"

# The other direction. The OLD dir holds a foreign session's children, so a
# directory sweep inflates this row; and the foreign session, resolved by its own
# id, must be exactly what it would have been had no recycle ever happened.
out=$(rec_run 5fc4a59c 2>/dev/null)
[ "$(field "$out" 9)" = "$WANT_SPLIT" ] \
  && ok "another session's children in the same old dir are NOT swept in (still 6.2M/2)" \
  || bad "another session's children in the same old dir are NOT swept in (still 6.2M/2)" "$(flat "$out")"
out=$(rec_run 0d2a7f2c 2>/dev/null); rc=$?
err=$(rec_run 0d2a7f2c 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
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
  [ "$(field "$mrow" 9)" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "<workload note> · subagents: 3.1M/2 · work: 0pr/0iss" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
  && ok "an explicit .jsonl path outside ~/.claude/projects still counts its sibling subagents (3.1M/1)" \
  || bad "an explicit .jsonl path outside ~/.claude/projects still counts its sibling subagents (3.1M/1)" \
         "rc=$rc $(flat "$out")"
# ...and the mutant that proves it: a glob-only copy cannot find them at all.
if MUT=$(mutant glob-only usage_accounting.py 's|^    roots = \[os.path.join(base, "subagents")\]$|    roots = []|'); then
  mrow=$(HOME="$RECH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$MUT" "$OUTSIDE/$OUTID.jsonl" 2>/dev/null)
  [ "$(field "$mrow" 9)" = "<workload note> · subagents: 0.0M/0 · work: 0pr/0iss" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "$WANT_SPLIT" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "$WANT_SPLIT" ] \
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
[ "$rc" -eq 0 ] && [ "$(subcount "$rel")" = "$(subcount "$abs")" ] && [ "$(field "$rel" 9)" = "$WANT_SPLIT" ] \
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
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "<workload note> · subagents: 3.1M/1 · work: 0pr/0iss" ] \
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
    { [ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "$WANT_SPLIT" ]; } || TRI_BAD="$TRI_BAD $seed"
    [ "$list" = "$WANT_TRI" ] || TRI_INEXACT="$TRI_INEXACT $seed"
    [ "$(printf '%s\n' "$list" | LC_ALL=C sort)" = "$WANT_TRI_SET" ] || TRI_NOTSET="$TRI_NOTSET $seed"
    [ "$list" = "$WANT_TRI_FIRST2" ] || TRI_NOTFIRST2="$TRI_NOTFIRST2 $seed"
  done
}

out=$(HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$TRI" 2>/dev/null); rc=$?
err=$(HOME="$TRIH" env -u CLAUDE_CODE_SESSION_ID "$PY" "$SUT" "$TRI" 2>&1 >/dev/null)
[ "$rc" -eq 0 ] && [ "$(field "$out" 9)" = "$WANT_SPLIT" ] \
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


printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
