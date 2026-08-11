#!/usr/bin/env bash
# Regression tests for assets/scripts/session-seed.py.
#
# These call the script. Nothing is extracted from a markdown file, and no
# assertion is satisfied by prose. The predecessor of this suite pulled fenced
# bash out of generic/session-lifecycle.md and ran it, because that was where the
# logic lived; five adversarial rounds of adding shell to a document is what moved
# the logic here, and the harness followed it.
#
# THE HARNESS DEFINES NOTHING THE SCRIPT IS RESPONSIBLE FOR DEFINING. Each case
# supplies only inputs that come from outside the script:
#
#   the working directory  — a real git repo (or none), which is where scope comes from
#   CLAUDE_HANDOFF_DIR     — the documented env knob for the seed dir (sometimes UNSET,
#                            because the default arm is code too)
#   CLAUDE_CODE_SESSION_ID — the harness's own session id, or --session
#   --now                  — the clock, pinned, so "two archives in one UTC second" is
#                            a property of the fixture rather than a race to win
#
# The suite does NOT `set -e`: half of these defects are "the guard failed and the
# run carried on regardless", and `set -e` would hide exactly that.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/session-seed.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-seed-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Keep every fixture repo self-contained: without this, a repo created inside a
# checkout of THIS repo would resolve its scope to the enclosing project.
export GIT_CEILING_DIRECTORIES="$TMP"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CLAUDE_HANDOFF_DIR CLAUDE_CODE_SESSION_ID

# The archive-vs-canonical discriminator, written out HERE rather than imported, so
# the script cannot satisfy these assertions by redefining its own rule. This is
# byte-for-byte the regex `/next` uses to skip archives when it ranks the fleet.
ARCHIVE_RE='^NEXT-[^/]*\.[0-9]{8}T[0-9]{6}Z-[^.]+\.md$'
STAMP=2026-08-11T00:00:00Z              # -> 20260811T000000Z in archive names
MINE=beefcafe
LOST='the thing that must not be lost'

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
skipt(){ skip=$((skip+1)); printf '  SKIP %s — %s\n' "$1" "$2"; }
flat() { printf '%s' "$1" | tr '\n' '|'; }
# Command substitution strips the trailing newline, so `printf '%s' "$out" | wc -l`
# is always one short. Count rows, not newlines.
nrows(){ [ -z "$1" ] && { echo 0; return; }; printf '%s\n' "$1" | wc -l | tr -d ' '; }

echo "session-seed.test.sh"

# ---------------------------------------------------------------------- fixtures
# `demo` is an ordinary repo whose main worktree basename is `demo`, so the scope
# derives to `demo` and the canonical seed is NEXT-demo.md. Nothing tells the
# script that; it works it out from git.
new_repo() {            # $1 = path
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}
new_case() {            # $1 = case name -> $TMP/<name>/{handoffs,demo}
  mkdir -p "$TMP/$1/handoffs"
  new_repo "$TMP/$1/demo"
}

put_seed() {            # $1 = case, $2 = filename, $3 = session ('-' = no line), $4 = marker
  {
    echo '---'
    echo 'type: handoff'
    echo 'date: 2026-08-10T10:00Z'
    echo 'scope: demo'
    [ "$3" = '-' ] || echo "session: $3"
    echo 'sensitivity: vault'
    echo '---'
    echo '# Handoff — a previous session'
    echo
    echo "- **Picks up at:** $4"
  } > "$TMP/$1/handoffs/$2"
}

# run <case> <cwd-relative-to-case> [args...] -> $out, $rc
run() {
  local c=$1 where=$2; shift 2
  out=$(cd "$TMP/$c/$where" && CLAUDE_HANDOFF_DIR="$TMP/$c/handoffs" \
        "$PY" "$SUT" "$@" 2>&1); rc=$?
}
# write <case> <cwd> [extra args...] — the ordinary end-of-session call
write() {
  local c=$1 where=$2; shift 2
  run "$c" "$where" write --session "$MINE" --now "$STAMP" \
      --picks-up-at 'the next thing' "$@"
}
archives() { ls "$TMP/$1/handoffs" 2>/dev/null | grep -Ec "$ARCHIVE_RE"; }
canon()    { ls "$TMP/$1/handoffs" 2>/dev/null | grep -E '^NEXT-.*\.md$' | grep -Evc "$ARCHIVE_RE"; }
preserved(){ grep -Rql "${2:-$LOST}" "$TMP/$1/handoffs" 2>/dev/null; }

# ============================================================ GROUP A — scope
# The scope key is the MAIN worktree's directory basename. Every one of these is a
# place a simpler rule ($PWD prefix, origin slug, `basename $PWD`) gets it wrong.
echo; echo "A. scope resolution"

new_case a1
mkdir -p "$TMP/a1/demo/deep/nested"
run a1 demo scope
[ "$rc" -eq 0 ] && [ "$out" = demo ] && ok "main worktree -> its basename" \
  || bad "main worktree -> its basename" "rc=$rc out=$(flat "$out")"

run a1 demo/deep/nested scope
[ "$out" = demo ] && ok "a nested subdirectory -> the same scope" \
  || bad "a nested subdirectory -> the same scope" "$(flat "$out")"

git -C "$TMP/a1/demo" worktree add -q "$TMP/a1/demo-wt" -b wt
run a1 demo-wt scope
[ "$out" = demo ] && ok "a linked worktree -> the MAIN worktree's basename, not its own" \
  || bad "a linked worktree -> the MAIN worktree's basename, not its own" "$(flat "$out")"

git -C "$TMP/a1/demo" checkout -q --detach HEAD
run a1 demo scope
[ "$out" = demo ] && ok "detached HEAD -> the same scope" \
  || bad "detached HEAD -> the same scope" "$(flat "$out")"
git -C "$TMP/a1/demo" checkout -q main

# Outside any git repo at all. The old harness never executed this arm: every case
# it had ran inside a repo, so `fleet` was reachable only in prose.
mkdir -p "$TMP/a2/handoffs" "$TMP/a2/nowhere"
run a2 nowhere scope
[ "$rc" -eq 0 ] && [ "$out" = fleet ] && ok "outside any repo -> fleet" \
  || bad "outside any repo -> fleet" "rc=$rc out=$(flat "$out")"
run a2 nowhere scope --topic marathon
[ "$out" = fleet-marathon ] && ok "outside any repo with a topic -> fleet-<topic>" \
  || bad "outside any repo with a topic -> fleet-<topic>" "$(flat "$out")"
run a2 nowhere scope --topic 'has spaces/'
printf '%s' "$out" | grep -q REFUSE && ok "a topic that is not one filename component REFUSES" \
  || bad "a topic that is not one filename component REFUSES" "$(flat "$out")"

# Two repos, ONE origin URL, different directory names. Keying on the remote merges
# their seeds and lets each overwrite the other's; this is the real pair.
mkdir -p "$TMP/a3/handoffs"
new_repo "$TMP/a3/chroxy"; new_repo "$TMP/a3/chroxy-daemon"
git -C "$TMP/a3/chroxy"        remote add origin https://github.com/blamechris/chroxy.git
git -C "$TMP/a3/chroxy-daemon" remote add origin https://github.com/blamechris/chroxy.git
run a3 chroxy scope;        s1=$out
run a3 chroxy-daemon scope; s2=$out
[ "$s1" = chroxy ] && [ "$s2" = chroxy-daemon ] \
  && ok "chroxy vs chroxy-daemon: one origin URL, two scopes" \
  || bad "chroxy vs chroxy-daemon: one origin URL, two scopes" "got '$s1' and '$s2'"

# --topic inside a repo would fork the repo's seed into a second file nobody reads.
run a1 demo scope --topic side
printf '%s' "$out" | grep -q 'REFUSE.*topic is only meaningful outside a repo' \
  && ok "--topic inside a repo REFUSES" || bad "--topic inside a repo REFUSES" "$(flat "$out")"

# A bare repo's common dir IS the repo, so its parent's basename is not a worktree
# name. Guessing here files the seed under a scope that does not exist.
mkdir -p "$TMP/a4/handoffs"; git init -q --bare "$TMP/a4/bare.git"
run a4 bare.git scope
printf '%s' "$out" | grep -q 'REFUSE.*bare repository' \
  && ok "a bare repository REFUSES rather than mis-scoping" \
  || bad "a bare repository REFUSES rather than mis-scoping" "rc=$rc $(flat "$out")"

# Any git failure that is NOT "not a git repository" is a question the script cannot
# answer — and answering `fleet` would misfile the seed while looking like success.
mkdir -p "$TMP/a5/handoffs" "$TMP/a5/stub"
cat > "$TMP/a5/stub/git" <<'STUB'
#!/bin/sh
echo "fatal: detected dubious ownership in repository" >&2
exit 128
STUB
chmod +x "$TMP/a5/stub/git"
out=$(cd "$TMP/a5" && PATH="$TMP/a5/stub:$PATH" CLAUDE_HANDOFF_DIR="$TMP/a5/handoffs" \
      "$PY" "$SUT" scope 2>&1); rc=$?
printf '%s' "$out" | grep -q 'REFUSE.*other than' \
  && ok "a git failure other than 'not a repository' REFUSES, never falls back to fleet" \
  || bad "a git failure other than 'not a repository' REFUSES, never falls back to fleet" "$(flat "$out")"

mkdir -p "$TMP/a6/handoffs" "$TMP/a6/empty-path"
out=$(cd "$TMP/a6" && PATH="$TMP/a6/empty-path" CLAUDE_HANDOFF_DIR="$TMP/a6/handoffs" \
      "$PY" "$SUT" scope 2>&1); rc=$?
printf '%s' "$out" | grep -q 'REFUSE.*git.*not on PATH' \
  && ok "no git on PATH REFUSES (it is 'I do not know', not 'this is the fleet')" \
  || bad "no git on PATH REFUSES (it is 'I do not know', not 'this is the fleet')" "$(flat "$out")"

# AN ORPHANED LINKED WORKTREE. Its `.git` is a FILE pointing at the main checkout;
# delete that checkout and git says "not a git repository" from inside a tree that
# is plainly still a repo session's workspace. This is the one not-a-repo answer
# that must not be `fleet` — silently, this repo's handoff overwrites the FLEET's
# seed, the repo's own seed is left stale, and the proof passes because it
# re-derives the same wrong scope. Every other case in group A reaches its verdict
# through git; this one is invisible to git by construction.
new_case a7
git -C "$TMP/a7/demo" worktree add -q "$TMP/a7/demo-wt" -b wt
run a7 demo-wt scope
[ "$out" = demo ] && ok "orphan check: a HEALTHY linked worktree still resolves normally" \
  || bad "orphan check: a HEALTHY linked worktree still resolves normally" "rc=$rc $(flat "$out")"
rm -rf "$TMP/a7/demo"                          # the main checkout is gone
run a7 demo-wt scope
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*main checkout is gone' \
  && ok "an ORPHANED linked worktree REFUSES — it is not the fleet" \
  || bad "an ORPHANED linked worktree REFUSES — it is not the fleet" "rc=$rc $(flat "$out")"
write a7 demo-wt
[ "$rc" -ne 0 ] && [ ! -f "$TMP/a7/handoffs/NEXT-fleet.md" ] \
  && ok "an orphaned linked worktree writes NO fleet seed" \
  || bad "an orphaned linked worktree writes NO fleet seed" \
         "rc=$rc $(ls "$TMP/a7/handoffs" 2>/dev/null | tr '\n' ' ')"
# The negative half: `fleet` must stay reachable from a directory that is genuinely
# outside every repo. A guard that refuses everywhere would satisfy the two above.
mkdir -p "$TMP/a7/outside"
run a7 outside scope
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "the orphan guard does not break the ordinary fleet case" \
  || bad "the orphan guard does not break the ordinary fleet case" "rc=$rc $(flat "$out")"

# ==================================================== GROUP B — the handoff dir
echo; echo "B. the handoff dir"

# THE DEFAULT ARM, EXECUTED. Every earlier suite set CLAUDE_HANDOFF_DIR in every
# case, so `${CLAUDE_HANDOFF_DIR:-~/Obsidian/no-it-all/handoffs}` was never once run
# — the one branch that fires on a real machine with no override set.
new_case b1
FAKE_HOME="$TMP/b1/home"; mkdir -p "$FAKE_HOME"
out=$(cd "$TMP/b1/demo" && env -u CLAUDE_HANDOFF_DIR HOME="$FAKE_HOME" \
      "$PY" "$SUT" write --session "$MINE" --now "$STAMP" --picks-up-at 'default dir' 2>&1); rc=$?
DEFAULT_SEED="$FAKE_HOME/Obsidian/no-it-all/handoffs/NEXT-demo.md"
if [ "$rc" -eq 0 ] && [ -f "$DEFAULT_SEED" ]; then
  ok "CLAUDE_HANDOFF_DIR unset: the seed lands under the default vault dir"
else bad "CLAUDE_HANDOFF_DIR unset: the seed lands under the default vault dir" "rc=$rc $(flat "$out")"; fi
printf '%s' "$out" | grep -q "^seed: $DEFAULT_SEED$" \
  && ok "CLAUDE_HANDOFF_DIR unset: the proof names the default path" \
  || bad "CLAUDE_HANDOFF_DIR unset: the proof names the default path" "$(flat "$out")"

# A missing handoff dir is a fresh machine, not an error.
new_case b2; rmdir "$TMP/b2/handoffs"
write b2 demo
[ "$rc" -eq 0 ] && [ -f "$TMP/b2/handoffs/NEXT-demo.md" ] \
  && ok "a missing handoff dir is created" \
  || bad "a missing handoff dir is created" "rc=$rc $(flat "$out")"

# rename(2) needs the write bit on the DIRECTORY; overwriting a file inside it does
# not. So an unwritable dir is exactly where "archive, then write" silently becomes
# "write over it" — with no race and no hostile actor.
new_case b3
put_seed b3 NEXT-demo.md d00dfeed "$LOST"
chmod a-w "$TMP/b3/handoffs"
if { : > "$TMP/b3/handoffs/.probe"; } 2>/dev/null; then
  rm -f "$TMP/b3/handoffs/.probe"; chmod u+w "$TMP/b3/handoffs"
  skipt "unwritable handoff dir" "this user can write to a mode-555 dir (root?)"
else
  write b3 demo
  chmod u+w "$TMP/b3/handoffs"
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q REFUSE \
    && ok "an unwritable handoff dir REFUSES with a nonzero exit" \
    || bad "an unwritable handoff dir REFUSES with a nonzero exit" "rc=$rc $(flat "$out")"
  preserved b3 && ok "an unwritable handoff dir: the incumbent seed survives intact" \
    || bad "an unwritable handoff dir: the incumbent seed survives intact" "the handoff was destroyed"
  grep -q "$LOST" "$TMP/b3/handoffs/NEXT-demo.md" \
    && ok "an unwritable handoff dir: the canonical name still holds the INCUMBENT" \
    || bad "an unwritable handoff dir: the canonical name still holds the INCUMBENT" \
           "$(head -8 "$TMP/b3/handoffs/NEXT-demo.md" | tr '\n' '|')"
fi

# A relative seed dir resolves against whatever cwd the session has — usually a
# worktree, i.e. the one place the seed may not live.
new_case b4
out=$(cd "$TMP/b4/demo" && CLAUDE_HANDOFF_DIR=relative/handoffs \
      "$PY" "$SUT" write --session "$MINE" --picks-up-at x 2>&1); rc=$?
printf '%s' "$out" | grep -q 'REFUSE.*relative' \
  && ok "a relative CLAUDE_HANDOFF_DIR REFUSES" \
  || bad "a relative CLAUDE_HANDOFF_DIR REFUSES" "$(flat "$out")"

# The floor rule, enforced where it is executable: a handoff dir inside the worktree
# is a seed that dies with `git worktree remove --force`.
new_case b5
out=$(cd "$TMP/b5/demo" && CLAUDE_HANDOFF_DIR="$TMP/b5/demo/in-tree-handoffs" \
      "$PY" "$SUT" write --session "$MINE" --picks-up-at x 2>&1); rc=$?
printf '%s' "$out" | grep -q 'REFUSE.*inside the worktree' \
  && ok "a handoff dir inside the worktree REFUSES" \
  || bad "a handoff dir inside the worktree REFUSES" "$(flat "$out")"
[ ! -f "$TMP/b5/demo/in-tree-handoffs/NEXT-demo.md" ] \
  && ok "a handoff dir inside the worktree: nothing was written there" \
  || bad "a handoff dir inside the worktree: nothing was written there" "the seed was written in-tree"

# ===================================================== GROUP C — the session id
echo; echo "C. the session id"

new_case c1
out=$(cd "$TMP/c1/demo" && CLAUDE_HANDOFF_DIR="$TMP/c1/handoffs" \
      CLAUDE_CODE_SESSION_ID=5fc4a59c-394b-4c35-b512-d3a38e4c241c \
      "$PY" "$SUT" write --now "$STAMP" --picks-up-at 'from the env' 2>&1); rc=$?
grep -q '^session: 5fc4a59c$' "$TMP/c1/handoffs/NEXT-demo.md" 2>/dev/null \
  && ok "\$CLAUDE_CODE_SESSION_ID supplies the id, truncated the way artifact ① prints it" \
  || bad "\$CLAUDE_CODE_SESSION_ID supplies the id, truncated the way artifact ① prints it" \
         "rc=$rc $(flat "$out")"

# The coupling stated as a test rather than a comment: the id the seed carries is
# the id usage-benchmark-row.py puts in artifact ①'s second column, for the same
# session. Both are computed here from the SAME uuid, by their own code.
UUID=5fc4a59c-394b-4c35-b512-d3a38e4c241c
BH="$TMP/c1/benchhome"; mkdir -p "$BH/.claude/scripts" "$BH/.claude/projects/-demo"
cp "$HERE/usage-benchmark-row.py" "$BH/.claude/scripts/" 2>/dev/null || \
  bad "fixture: usage-benchmark-row.py is present" "missing next to the SUT"
"$PY" - "$BH/.claude/projects/-demo/$UUID.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for i in range(400):
        f.write(json.dumps({"type": "assistant",
                            "timestamp": "2026-08-11T%02d:%02d:00.000Z" % (i // 60, i % 60),
                            "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 1000,
                                                  "cache_creation_input_tokens": 10, "output_tokens": 50}},
                            "pad": "x" * 200}) + "\n")
PY
row=$(HOME="$BH" "$PY" "$BH/.claude/scripts/usage-benchmark-row.py" 2>/dev/null |
      awk -F'|' 'NR==1 { gsub(/[[:space:]]/,"",$3); print $3 }')
seedid=$("$PY" "$SUT" header "$TMP/c1/handoffs/NEXT-demo.md" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["session"])')
[ -n "$row" ] && [ "$row" = "$seedid" ] \
  && ok "the seed's session: and the benchmark row's id are the same string ('$row')" \
  || bad "the seed's session: and the benchmark row's id are the same string" "row='$row' seed='$seedid'"

# No --session and no env var. THE NO-ID PATH IS REACHABLE, and it halts BEFORE the
# archive: an anonymous seed cannot be archived by the next session or proved by
# this one, so an unresolvable id is a reason to stop, not a value to carry.
new_case c2
put_seed c2 NEXT-demo.md f0f0f0f0 "$LOST"
out=$(cd "$TMP/c2/demo" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_HANDOFF_DIR="$TMP/c2/handoffs" \
      "$PY" "$SUT" write --now "$STAMP" --picks-up-at x 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*no id' \
  && ok "no id anywhere: REFUSE instead of writing an anonymous seed" \
  || bad "no id anywhere: REFUSE instead of writing an anonymous seed" "rc=$rc $(flat "$out")"
[ "$(archives c2)" -eq 0 ] && grep -q '^session: f0f0f0f0$' "$TMP/c2/handoffs/NEXT-demo.md" \
  && ok "no id anywhere: the incumbent is left exactly where it was" \
  || bad "no id anywhere: the incumbent is left exactly where it was" "$(ls "$TMP/c2/handoffs" | tr '\n' ' ')"

# There is no third source. The defect this replaces resolved the id by picking the
# most recently modified transcript under ~/.claude/projects — fleet-wide, so on a
# machine running several sessions it names whichever session last wrote a turn.
# Handed a HOME full of transcripts and no id, the script must still refuse.
mkdir -p "$TMP/c2/decoy/.claude/projects/-x"
"$PY" - "$TMP/c2/decoy/.claude/projects/-x/decafbad-1111-2222-3333-444455556666.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for i in range(400):
        f.write(json.dumps({"type": "assistant", "timestamp": "2026-08-11T00:00:00.000Z",
                            "message": {"usage": {"input_tokens": 1, "output_tokens": 1}},
                            "pad": "x" * 200}) + "\n")
PY
out=$(cd "$TMP/c2/demo" && env -u CLAUDE_CODE_SESSION_ID HOME="$TMP/c2/decoy" \
      CLAUDE_HANDOFF_DIR="$TMP/c2/handoffs" "$PY" "$SUT" write --picks-up-at x 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'decafbad' "$TMP/c2/handoffs/NEXT-demo.md" \
  && ok "a HOME full of other sessions' transcripts is NOT an id source" \
  || bad "a HOME full of other sessions' transcripts is NOT an id source" "rc=$rc $(flat "$out")"

new_case c3
run c3 demo write --session 'has#hash' --picks-up-at x
printf '%s' "$out" | grep -q "REFUSE.*'#'" \
  && ok "an id containing '#' REFUSES (it would not round-trip through YAML)" \
  || bad "an id containing '#' REFUSES (it would not round-trip through YAML)" "$(flat "$out")"
run c3 demo write --session "$(printf 'a\tb')" --picks-up-at x
printf '%s' "$out" | grep -q 'REFUSE.*control character' \
  && ok "an id containing a control character REFUSES" \
  || bad "an id containing a control character REFUSES" "$(flat "$out")"
run c3 demo write --session "$MINE" --picks-up-at x --now "$STAMP"
[ "$rc" -eq 0 ] && ok "--session overrides the environment" \
  || bad "--session overrides the environment" "rc=$rc $(flat "$out")"

# ================================================ GROUP D — archive on collide
echo; echo "D. archive on collide"

new_case d1
put_seed d1 NEXT-demo.md f0f0f0f0 "$LOST"
write d1 demo
[ "$rc" -eq 0 ] && [ "$(archives d1)" -eq 1 ] && preserved d1 \
  && ok "a foreign incumbent is archived, not overwritten" \
  || bad "a foreign incumbent is archived, not overwritten" "rc=$rc $(ls "$TMP/d1/handoffs" | tr '\n' ' ')"
grep -q "^session: $MINE\$" "$TMP/d1/handoffs/NEXT-demo.md" \
  && ok "after archiving, this session's seed holds the canonical name" \
  || bad "after archiving, this session's seed holds the canonical name" "$(ls "$TMP/d1/handoffs")"

# Re-running the same session's own write is not a collision: the canonical name is
# what makes "one line to paste" work, so a session overwrites itself in place.
new_case d2
put_seed d2 NEXT-demo.md "$MINE" "$LOST"
write d2 demo
[ "$rc" -eq 0 ] && [ "$(archives d2)" -eq 0 ] \
  && ok "re-running the same session's own write is not a collision" \
  || bad "re-running the same session's own write is not a collision" "rc=$rc $(ls "$TMP/d2/handoffs")"

# An incumbent with no `session:` at all is UNIDENTIFIABLE — which is a reason to
# keep it, not to clobber it. This arm had no coverage before.
new_case d3
put_seed d3 NEXT-demo.md - "$LOST"
write d3 demo
[ "$(archives d3)" -eq 1 ] && preserved d3 \
  && ok "an incumbent with no session: is archived, never clobbered" \
  || bad "an incumbent with no session: is archived, never clobbered" "$(ls "$TMP/d3/handoffs")"
ls "$TMP/d3/handoffs" | grep -q -- '-unknown\.md$' \
  && ok "an unidentifiable incumbent archives under the slug 'unknown'" \
  || bad "an unidentifiable incumbent archives under the slug 'unknown'" "$(ls "$TMP/d3/handoffs")"

# A quoted scalar is legal YAML, and an unstripped quote makes a same-session write
# look like a collision — archiving the session's own seed on every re-run.
new_case d4
put_seed d4 NEXT-demo.md "\"$MINE\"" "$LOST"
write d4 demo
[ "$(archives d4)" -eq 0 ] \
  && ok "a QUOTED session: scalar is unquoted before comparing (no phantom collision)" \
  || bad "a QUOTED session: scalar is unquoted before comparing (no phantom collision)" \
         "$(ls "$TMP/d4/handoffs")"

# The stamp resolves to a second and the slug is the incumbent's id, so two archives
# of one id inside one second name the same file. Overwriting there destroys the
# archive this step just made — the same loss the guard prevents, by the other door.
new_case d5
put_seed d5 NEXT-demo.md d00dfeed 'the FIRST incumbent'
write d5 demo
put_seed d5 NEXT-demo.md d00dfeed 'the SECOND incumbent'
write d5 demo
preserved d5 'the FIRST incumbent' && preserved d5 'the SECOND incumbent' \
  && ok "two archives in one UTC second: the earlier is not overwritten" \
  || bad "two archives in one UTC second: the earlier is not overwritten" \
         "$(ls "$TMP/d5/handoffs" | tr '\n' ' ')"
[ "$(archives d5)" -eq 2 ] && ok "two archives in one UTC second: two archives on disk" \
  || bad "two archives in one UTC second: two archives on disk" "$(ls "$TMP/d5/handoffs" | tr '\n' ' ')"
[ "$(canon d5)" -eq 1 ] \
  && ok "two archives in one UTC second: both still read as ARCHIVES to /next" \
  || bad "two archives in one UTC second: both still read as ARCHIVES to /next" \
         "$(ls "$TMP/d5/handoffs" | tr '\n' ' ')"

# THE PRE-EXISTING DEFECT, now in scope: the sanitiser used to keep `.`, but /next's
# discriminator forbids a dot in the id position (`[^.]+`) — because a scope key may
# legally contain dots. So an incumbent whose session: held a dot produced an
# archive that /next read back as a CANONICAL seed, hanging a phantom scope off the
# fleet listing.
new_case d6
put_seed d6 NEXT-demo.md 'a.b.c' "$LOST"
write d6 demo
[ "$(archives d6)" -eq 1 ] \
  && ok "a dotted incumbent id still produces a name /next reads as an archive" \
  || bad "a dotted incumbent id still produces a name /next reads as an archive" \
         "$(ls "$TMP/d6/handoffs" | tr '\n' ' ')"
[ "$(canon d6)" -eq 1 ] && [ "$(cd "$TMP/d6/demo" && CLAUDE_HANDOFF_DIR="$TMP/d6/handoffs" \
     "$PY" "$SUT" list | wc -l | tr -d ' ')" -eq 1 ] \
  && ok "a dotted incumbent id creates no phantom scope in \`list\`" \
  || bad "a dotted incumbent id creates no phantom scope in \`list\`" \
         "$(cd "$TMP/d6/demo" && CLAUDE_HANDOFF_DIR="$TMP/d6/handoffs" "$PY" "$SUT" list | tr '\n' '|')"

# The incumbent's OWN BYTES steer the path that protects it, so every one of these
# is a value read out of somebody else's file.
i=0
for id in 'sessions/2026-08-11/a1b2c3d4' '../../etc/passwd' '..' 'has spaces here' '-leading-dash' '.'; do
  i=$((i+1)); c="d7$i"
  new_case "$c"
  put_seed "$c" NEXT-demo.md "$id" "$LOST"
  write "$c" demo
  esc=$(find "$TMP/$c" -maxdepth 1 -name '*.md' 2>/dev/null; find "$TMP/$c/handoffs" -mindepth 2 2>/dev/null)
  if [ "$rc" -eq 0 ] && preserved "$c" && [ "$(archives "$c")" -eq 1 ] && [ -z "$esc" ] &&
     grep -q "^session: $MINE\$" "$TMP/$c/handoffs/NEXT-demo.md" 2>/dev/null; then
    ok "hostile incumbent id '$id': contained, archived, handoff still completes"
  else
    bad "hostile incumbent id '$id': contained, archived, handoff still completes" \
        "rc=$rc escaped='$esc' $(ls -R "$TMP/$c/handoffs" | tr '\n' ' ')"
  fi
done

# 100 taken archive names is not a licence to overwrite the 101st.
new_case d8
put_seed d8 NEXT-demo.md d00dfeed "$LOST"
"$PY" - "$TMP/d8/handoffs" <<'PY'
import os, sys
d = sys.argv[1]
for n in range(100):
    open(os.path.join(d, "NEXT-demo.20260811T000000Z-d00dfeed%s.md" % ("" if n == 0 else "-%d" % n)), "w").write("taken\n")
PY
write d8 demo
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*no free archive name' && preserved d8 \
  && ok "100 taken archive names: REFUSE, incumbent stays, nothing written" \
  || bad "100 taken archive names: REFUSE, incumbent stays, nothing written" "rc=$rc $(flat "$out")"

# ================================================ GROUP E — the seed the code writes
echo; echo "E. the seed body and header, round-tripped"

# The header is produced by the code under test and read back by the code under
# test. The harness never writes a seed it then asserts about — an earlier suite
# did, and the shape it asserted was therefore its own.
new_case e1
PICKS='issue #205 — the "doc" said: extract it'
run e1 demo write --session "$MINE" --now "$STAMP" --picks-up-at "$PICKS" \
    --title 'what landed' --boundary-reason 'wave boundary' --sensitivity public
[ "$rc" -eq 0 ] && ok "write with a full header succeeds" \
  || bad "write with a full header succeeds" "rc=$rc $(flat "$out")"
hdr=$("$PY" "$SUT" header "$TMP/e1/handoffs/NEXT-demo.md")
check_field() {         # $1 = key, $2 = expected
  local got
  got=$(printf '%s' "$hdr" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('$1',''))")
  [ "$got" = "$2" ] && ok "header round-trip: $1" || bad "header round-trip: $1" "got '$got' want '$2'"
}
check_field type handoff
check_field scope demo
check_field session "$MINE"
check_field sensitivity public
check_field date 2026-08-11T00:00Z
# The one field /next quotes verbatim — carrying a '#' (a YAML comment lead) and
# embedded double quotes, both of which a naive parser mangles.
check_field picks_up_at "$PICKS"

grep -q '^# Handoff — what landed$' "$TMP/e1/handoffs/NEXT-demo.md" \
  && ok "the H1 comes from --title" || bad "the H1 comes from --title" "$(head -12 "$TMP/e1/handoffs/NEXT-demo.md" | tr '\n' '|')"
grep -q '^\- \*\*Boundary reason:\*\* wave boundary$' "$TMP/e1/handoffs/NEXT-demo.md" \
  && ok "the boundary-reason bullet is written" || bad "the boundary-reason bullet is written" "missing"
for section in '## STATE' '## TL;DR' '## Left undone, deliberately'; do
  grep -qF "$section" "$TMP/e1/handoffs/NEXT-demo.md" \
    && ok "the default body carries '$section'" || bad "the default body carries '$section'" "missing"
done

new_case e2
printf '## MY OWN BODY\n\nverbatim\n' > "$TMP/e2/body.md"
run e2 demo write --session "$MINE" --now "$STAMP" --picks-up-at x --body-file "$TMP/e2/body.md"
grep -q '^## MY OWN BODY$' "$TMP/e2/handoffs/NEXT-demo.md" &&
  ! grep -q '## TL;DR' "$TMP/e2/handoffs/NEXT-demo.md" \
  && ok "--body-file replaces the skeleton, header still generated" \
  || bad "--body-file replaces the skeleton, header still generated" "$(flat "$(cat "$TMP/e2/handoffs/NEXT-demo.md")")"

run e2 demo write --session "$MINE" --picks-up-at '   '
printf '%s' "$out" | grep -q 'REFUSE.*picks-up-at is empty' \
  && ok "an empty --picks-up-at REFUSES (it is the only line /next quotes)" \
  || bad "an empty --picks-up-at REFUSES (it is the only line /next quotes)" "$(flat "$out")"
run e2 demo write --session "$MINE" --picks-up-at "$(printf 'a\nb')"
printf '%s' "$out" | grep -q 'REFUSE.*newline' \
  && ok "a multi-line --picks-up-at REFUSES (it is one frontmatter line)" \
  || bad "a multi-line --picks-up-at REFUSES (it is one frontmatter line)" "$(flat "$out")"

# ==================================================== GROUP F — the authorship proof
echo; echo "F. the proof"

new_case f1
put_seed f1 NEXT-demo.md aaaabbbb "$LOST"
write f1 demo
run f1 demo verify --session "$MINE"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^seed: .*/NEXT-demo\.md$' \
  && ok "this session's own seed passes the proof" \
  || bad "this session's own seed passes the proof" "rc=$rc $(flat "$out")"

# RIGHT FILE, WRONG AUTHOR: the archive was destroyed, so the canonical path holds
# someone else's seed. Existence calls this a pass; reading `session:` back does not.
new_case f2
put_seed f2 NEXT-demo.md f0f0f0f0 "$LOST"
run f2 demo verify --session "$MINE"
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q REFUSE && ! printf '%s' "$out" | grep -q '^seed: ' \
  && ok "a foreign seed at the canonical path REFUSES" \
  || bad "a foreign seed at the canonical path REFUSES" "rc=$rc $(flat "$out")"
put_seed f2 NEXT-demo.md - "$LOST"
run f2 demo verify --session "$MINE"
[ "$rc" -ne 0 ] && ok "a seed with no session: is not a proof of authorship" \
  || bad "a seed with no session: is not a proof of authorship" "rc=$rc $(flat "$out")"
rm -f "$TMP/f2/handoffs/NEXT-demo.md"
run f2 demo verify --session "$MINE"
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*no seed at' \
  && ok "no seed at all REFUSES" || bad "no seed at all REFUSES" "rc=$rc $(flat "$out")"

# WRONG FILE: run the proof from a LINKED worktree while a well-formed seed of ours
# sits under the linked worktree's basename and the previous session's stale seed
# occupies the canonical name. Only re-deriving the scope from the MAIN worktree
# catches this; a check handed the writer's path reads back the writer's own mistake.
new_case f3
git -C "$TMP/f3/demo" worktree add -q "$TMP/f3/demo-wt" -b wt
put_seed f3 NEXT-demo.md 7c0ffee1 "$LOST"
put_seed f3 NEXT-demo-wt.md "$MINE" 'my seed, at a path nobody reads'
run f3 demo-wt verify --session "$MINE"
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^seed: ' \
  && ok "a seed misfiled under the linked worktree's name does not pass" \
  || bad "a seed misfiled under the linked worktree's name does not pass" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -q 'NEXT-demo-wt\.md' \
  && ok "the REFUSE names where this session's seed actually landed" \
  || bad "the REFUSE names where this session's seed actually landed" "$(flat "$out")"

# THE WRITE'S OWN PROOF IS REAL — its verdict is the write's exit code, not a line
# the write prints about itself. This is what lets the checklist be ONE invocation,
# so a write that merely announced success would make the doc's central claim false.
#
# Induced with a stub `git` that changes the repo's identity the moment the seed
# exists: the write resolves `demo` (no seed yet), the proof re-resolves `other`
# (seed present) and finds no seed of ours there. A write whose proof is decorative
# exits 0 here; a write whose proof decides exits nonzero.
new_case f3b
mkdir -p "$TMP/f3b/stub" "$TMP/f3b/other"
GIT_REAL=$(command -v git)
cat > "$TMP/f3b/stub/git" <<STUB
#!/bin/sh
case "\$*" in
  *--git-common-dir*) [ -f "$TMP/f3b/handoffs/NEXT-demo.md" ] && { echo "$TMP/f3b/other/.git"; exit 0; } ;;
esac
exec "$GIT_REAL" "\$@"
STUB
chmod +x "$TMP/f3b/stub/git"
out=$(cd "$TMP/f3b/demo" && PATH="$TMP/f3b/stub:$PATH" CLAUDE_HANDOFF_DIR="$TMP/f3b/handoffs" \
      "$PY" "$SUT" write --session "$MINE" --now "$STAMP" --picks-up-at x 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*NEXT-other\.md' \
  && ok "write EXITS NONZERO when its own proof refuses (the proof is not decorative)" \
  || bad "write EXITS NONZERO when its own proof refuses (the proof is not decorative)" "rc=$rc $(flat "$out")"
out=$(cd "$TMP/f3b/demo" && PATH="$TMP/f3b/stub:$PATH" CLAUDE_HANDOFF_DIR="$TMP/f3b/handoffs" \
      "$PY" "$SUT" write --session "$MINE" --now "$STAMP" --picks-up-at x --no-verify 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^wrote (UNPROVED): ' \
  && ! printf '%s' "$out" | grep -q '^seed: ' \
  && ok "--no-verify says UNPROVED and never emits the proved form" \
  || bad "--no-verify says UNPROVED and never emits the proved form" "rc=$rc $(flat "$out")"

# The positive half — without it, the assertion above is satisfied by a proof that
# always refuses from a linked worktree.
new_case f4
git -C "$TMP/f4/demo" worktree add -q "$TMP/f4/demo-wt" -b wt
write f4 demo-wt
run f4 demo-wt verify --session "$MINE"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^seed: .*/NEXT-demo\.md$' \
  && ok "from a linked worktree the proof reads the MAIN worktree's seed" \
  || bad "from a linked worktree the proof reads the MAIN worktree's seed" "rc=$rc $(flat "$out")"

# ===================================== REGRESSION 1 — the topic-scoped fleet seed
# A fleet session with a named topic writes NEXT-fleet-<topic>.md. The version this
# replaces could never PROVE one: the proof's scope block had a bare `SCOPE=fleet`
# arm with no topic in it, so it looked at NEXT-fleet.md and refused every time. One
# resolve_scope(), called by the write and by the proof with the same --topic, is
# what makes the topic case first-class in both instead of remembered in one.
echo; echo "F2. topic-scoped fleet seeds (regression 1)"
mkdir -p "$TMP/g1/handoffs" "$TMP/g1/nowhere"
run g1 nowhere write --session "$MINE" --now "$STAMP" --topic marathon --picks-up-at 'the wave'
[ "$rc" -eq 0 ] && [ -f "$TMP/g1/handoffs/NEXT-fleet-marathon.md" ] \
  && ok "a topic-scoped fleet seed is written at NEXT-fleet-<topic>.md" \
  || bad "a topic-scoped fleet seed is written at NEXT-fleet-<topic>.md" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -q '^seed: .*/NEXT-fleet-marathon\.md$' \
  && ok "the write's BUILT-IN proof passes for a topic-scoped fleet seed" \
  || bad "the write's BUILT-IN proof passes for a topic-scoped fleet seed" "$(flat "$out")"
run g1 nowhere verify --session "$MINE" --topic marathon
[ "$rc" -eq 0 ] && ok "the standalone proof passes for a topic-scoped fleet seed" \
  || bad "the standalone proof passes for a topic-scoped fleet seed" "rc=$rc $(flat "$out")"
run g1 nowhere verify --session "$MINE"
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NEXT-fleet-marathon\.md' \
  && ok "proving without the topic REFUSES and names the topic seed, not a bare 'not yours'" \
  || bad "proving without the topic REFUSES and names the topic seed, not a bare 'not yours'" \
         "rc=$rc $(flat "$out")"
# An untopicked fleet seed is a separate scope and is untouched by the topic write.
run g1 nowhere write --session "$MINE" --now "$STAMP" --picks-up-at 'no topic'
[ -f "$TMP/g1/handoffs/NEXT-fleet.md" ] && [ -f "$TMP/g1/handoffs/NEXT-fleet-marathon.md" ] \
  && [ "$(archives g1)" -eq 0 ] \
  && ok "NEXT-fleet.md and NEXT-fleet-<topic>.md are separate scopes, neither archives the other" \
  || bad "NEXT-fleet.md and NEXT-fleet-<topic>.md are separate scopes, neither archives the other" \
         "$(ls "$TMP/g1/handoffs" | tr '\n' ' ')"

# ============================================================== GROUP G — list
echo; echo "G. list (what /next ranks)"

new_case h1
write h1 demo                                   # canonical NEXT-demo.md
put_seed h1 NEXT-demo.md f0f0f0f0 'incumbent'   # force one archive
write h1 demo
put_seed h1 NEXT-undated.md abcd1234 'no date'
"$PY" - "$TMP/h1/handoffs/NEXT-undated.md" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read().replace("date: 2026-08-10T10:00Z\n", "")
open(p, "w").write(s)
PY
run h1 demo list
[ "$(nrows "$out")" -eq 2 ] \
  && ok "list emits canonical seeds only (archives excluded)" \
  || bad "list emits canonical seeds only (archives excluded)" "$(flat "$out")"
printf '%s' "$out" | grep -q '^demo	2026-08-11T00:00Z	' \
  && ok "list emits scope<TAB>date<TAB>path" || bad "list emits scope<TAB>date<TAB>path" "$(flat "$out")"
printf '%s' "$out" | grep -q '^undated		' \
  && ok "a seed with no parseable date: reports an EMPTY date (UNDATED, never 'old')" \
  || bad "a seed with no parseable date: reports an EMPTY date (UNDATED, never 'old')" "$(flat "$out")"
run h1 demo list --archives
[ "$(nrows "$out")" -eq 1 ] && printf '%s' "$out" | grep -q '^demo	' \
  && ok "list --archives inverts the discriminator" \
  || bad "list --archives inverts the discriminator" "$(flat "$out")"

# A scope key may legally contain dots, and it must still rank as canonical — this
# is why the discriminator anchors on `.<UTC>-<slug>.md` rather than on "has a dot".
mkdir -p "$TMP/h2/handoffs"
new_repo "$TMP/h2/blamechris.github.io"
run h2 blamechris.github.io write --session "$MINE" --now "$STAMP" --picks-up-at 'dotted scope'
[ "$rc" -eq 0 ] && [ -f "$TMP/h2/handoffs/NEXT-blamechris.github.io.md" ] \
  && ok "a dotted scope key writes and proves normally" \
  || bad "a dotted scope key writes and proves normally" "rc=$rc $(flat "$out")"
run h2 blamechris.github.io list
printf '%s' "$out" | grep -q '^blamechris.github.io	' \
  && ok "a dotted scope key is listed as CANONICAL, not mistaken for an archive" \
  || bad "a dotted scope key is listed as CANONICAL, not mistaken for an archive" "$(flat "$out")"

# ...and the SAME key must survive `--archives`, which is the listing `/next` runs
# when a canonical seed is missing. The scope column there was cut at the first dot
# by a second, hand-rolled definition of where the scope key ends — six lines below
# the ARCHIVE_SUFFIX regex that is supposed to be the only one. It reported the
# scope `blamechris`, a scope that does not exist, at the one moment the user is
# being told where their unconsumed handoff went.
put_seed h2 NEXT-blamechris.github.io.md f0f0f0f0 'the dotted incumbent'
run h2 blamechris.github.io write --session "$MINE" --now "$STAMP" --picks-up-at 'collide'
run h2 blamechris.github.io list --archives
[ "$(nrows "$out")" -eq 1 ] && printf '%s' "$out" | grep -q '^blamechris.github.io	' \
  && ok "list --archives keeps a dotted scope key whole (no phantom scope)" \
  || bad "list --archives keeps a dotted scope key whole (no phantom scope)" "$(flat "$out")"
! printf '%s' "$out" | grep -q '^blamechris	' \
  && ok "list --archives reports no truncated scope that does not exist" \
  || bad "list --archives reports no truncated scope that does not exist" "$(flat "$out")"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
