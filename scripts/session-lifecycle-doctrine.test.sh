#!/usr/bin/env bash
# Regression tests for the executable blocks in generic/session-lifecycle.md that
# decide the fate of the PREVIOUS session's handoff seed: End step 1's resolve
# and archive-on-collide blocks, and End step 3's authorship proof.
#
# These are NOT greps. Every block is EXTRACTED FROM THE DOC and executed, so an
# assertion can only be satisfied by code that actually behaves. The repo has been
# bitten twice by substring guards that prose satisfied while the mechanism was
# gone (see validate-registry.yml's own comments); a doc whose snippets are run is
# the version of that guard that cannot be talked past.
#
# THE HARNESS DEFINES NOTHING THE DOC IS RESPONSIBLE FOR DEFINING. Each runner
# supplies exactly three things, and every one of them is an input the doc reads
# from outside itself:
#
#   HOME                 — where usage-benchmark-row.py and this session's
#                          transcript live; the doc resolves its own id from them
#   CLAUDE_HANDOFF_DIR   — the doc's own documented env knob for the seed dir
#   the working directory — a real git worktree, which is where <scope> comes from
#
# SCOPE, HANDOFF_DIR, SEED and SID are the doc's to establish and no runner sets
# them. An earlier version of this file wrote `SID=$MINE` into both preambles, and
# that one line is why sixteen mutation-tested assertions stayed green while the
# doc assigned SID nowhere at all — the harness was supplying the doc's own
# precondition, so every mention of the session id could have been deleted from
# the doctrine without a single test noticing. A harness that supplies what the
# doc must define cannot test the doc. `set -u` is the other half: a variable the
# doc forgets is now a visible failure instead of an empty string.
#
# The runners deliberately do NOT `set -e`. The archive defects are "the guard
# failed and the script carried on regardless", and `set -e` would paper over
# exactly that — a harness that ran under it would pass on the broken doc.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DOC="$HERE/generic/session-lifecycle.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-lifecycle-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export GIT_CEILING_DIRECTORIES="$TMP"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

echo "session-lifecycle-doctrine.test.sh"

# ------------------------------------------------------------------ extraction
# Pull the blocks out by an anchor that names what they DO, not where they sit — a
# renumbered step or a reflowed paragraph must not silently stop testing the code.
# A missing block is a hard failure: the doctrine's whole claim is that these are
# runnable commands, so a block that has become prose is the regression.
python3 - "$DOC" "$TMP" <<'PY' || { echo "  FAIL could not extract the doc's bash blocks"; exit 1; }
import sys

doc, tmp = sys.argv[1], sys.argv[2]
blocks, cur, indent = [], None, 0
for ln in open(doc, encoding='utf-8').read().splitlines():
    s = ln.lstrip()
    if s.startswith('```'):
        if cur is None:
            cur, indent = [], len(ln) - len(s)
        else:
            blocks.append('\n'.join(cur))
            cur = None
        continue
    if cur is not None:
        cur.append(ln[indent:] if not ln[:indent].strip() else s)

want = {'resolve': 'REFUSE: this session has no id',
        'archive': 'mv "$SEED"',
        'prove':   'REFUSE: the seed is inside this worktree'}
missing = []
for name, anchor in want.items():
    hits = [b for b in blocks if anchor in b]
    if len(hits) != 1:
        missing.append(f'{name}: {len(hits)} blocks contain {anchor!r} (want exactly 1)')
        continue
    with open(f'{tmp}/{name}.block', 'w', encoding='utf-8') as f:
        f.write(hits[0] + '\n')
if missing:
    print('\n'.join('  ' + m for m in missing), file=sys.stderr)
    sys.exit(1)
PY

RESOLVE=$(cat "$TMP/resolve.block")
ARCHIVE=$(cat "$TMP/archive.block")
PROVE=$(cat "$TMP/prove.block")

# --------------------------------------------------------------- the id source
# The session id is the doc's to resolve, so the harness supplies only the SOURCE:
# a HOME holding this repo's real usage-benchmark-row.py and one transcript for it
# to read. The id is that transcript's basename truncated to 8 characters — the
# script's own rule — which is how this harness knows the answer without ever
# telling the doc what it is.
MINE=beefcafe
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/scripts" "$FAKE_HOME/.claude/projects/-demo"
cp "$HERE/assets/scripts/usage-benchmark-row.py" "$FAKE_HOME/.claude/scripts/" || {
  echo "  FAIL assets/scripts/usage-benchmark-row.py is missing — it is the doc's id source"
  exit 1
}
python3 - "$FAKE_HOME/.claude/projects/-demo/$MINE-0000-1111-2222-333344445555.jsonl" <<'PY'
import json, sys
# Over 50 KB and carrying real usage records, because that is what the script
# selects on when it is run with no argument — the way the doc runs it.
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    for i in range(400):
        f.write(json.dumps({
            "type": "assistant",
            "timestamp": "2026-08-11T%02d:%02d:00.000Z" % (i // 60, i % 60),
            "message": {"usage": {"input_tokens": 100, "cache_read_input_tokens": 1000,
                                  "cache_creation_input_tokens": 10, "output_tokens": 50}},
            "pad": "x" * 200,
        }) + "\n")
PY

# The coupling every id assertion below rests on, checked rather than assumed: the
# row artifact ① carries names this session, and for this fixture it names $MINE.
if HOME="$FAKE_HOME" python3 "$FAKE_HOME/.claude/scripts/usage-benchmark-row.py" 2>/dev/null |
     grep -q "| $MINE |"; then
  ok "fixture: the benchmark row names this session '$MINE'"
else
  bad "fixture: the benchmark row names this session '$MINE'" \
      "$(HOME="$FAKE_HOME" python3 "$FAKE_HOME/.claude/scripts/usage-benchmark-row.py" 2>&1 | tr '\n' '|')"
fi

# ------------------------------------------------------------------- fixtures
# A scenario gets a handoff dir and a real git repo whose main worktree is named
# `demo`, so the doc's own scope derivation resolves to `demo` and the canonical
# seed is NEXT-demo.md. Nothing tells it that; it works it out from git.
LOST='the thing that must not be lost'

new_case() {            # $1 = case dir
  local d="$TMP/$1"
  mkdir -p "$d/handoffs"
  git -c init.defaultBranch=main init -q "$d/demo"
  git -C "$d/demo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

put_seed() {            # $1 = case dir, $2 = filename, $3 = `session:` ('-' = no such line), $4 = marker
  local d="$TMP/$1"
  {
    echo '---'
    echo 'type: handoff'
    echo 'scope: demo'
    [ "$3" = '-' ] || echo "session: $3"
    echo 'sensitivity: vault'
    echo '---'
    echo '# Handoff — a previous session'
    echo
    echo "- **Picks up at:** $4"
  } > "$d/handoffs/$2"
}

run_end() {             # $1 = case dir, $2 = '' | 'nohome'; runs End step 1, echoes rc via $rc
  local d="$TMP/$1" home=$FAKE_HOME
  # `nohome` removes the id source and nothing else: the doc still has a scope, a
  # handoff dir and an incumbent — it just cannot name itself.
  if [ "${2:-}" = nohome ]; then home="$d/nohome"; mkdir -p "$home"; fi
  cat > "$d/run.sh" <<RUNNER
set -u
$RESOLVE
$ARCHIVE
# stands in for the doc's \`# then write \$SEED\`, with the header End step 1
# requires — \`session:\` is what step 3 reads back, so a stand-in without it
# would be testing a seed the doctrine does not permit. Every value it writes
# comes from the doc's own blocks.
printf -- '---\ntype: handoff\nscope: %s\nsession: %s\n---\nSEED WRITTEN BY %s\n' \\
  "\$SCOPE" "\$SID" "\$SID" > "\$SEED"
RUNNER
  out=$(cd "$d/demo" && HOME="$home" CLAUDE_HANDOFF_DIR="$d/handoffs" bash "$d/run.sh" 2>&1); rc=$?
}

run_prove() {           # $1 = case dir, $2 = worktree to run in (default demo), $3 = 'poison'
  local d="$TMP/$1" where="${2:-demo}"
  {
    echo 'set -u'
    if [ "${3:-}" = poison ]; then
      # Step 3 re-derives, so nothing step 1 computed may reach it intact. A check
      # that trusts an inherited value reads these instead and cannot pass.
      echo 'SCOPE=POISON; HANDOFF_DIR=/nonexistent/POISON'
      echo 'SEED=/nonexistent/POISON.md; SID=POISON'
    fi
    printf '%s\n' "$PROVE"
  } > "$d/prove.sh"
  out=$(cd "$d/$where" && HOME="$FAKE_HOME" CLAUDE_HANDOFF_DIR="$d/handoffs" \
        bash "$d/prove.sh" 2>&1); rc=$?
}

archives() { ls "$TMP/$1/handoffs" 2>/dev/null | grep -c '^NEXT-demo\..*\.md$'; }
preserved() {           # $1 = case dir, $2 = marker; the bytes exist somewhere under the handoff dir
  grep -Rql "${2:-$LOST}" "$TMP/$1/handoffs" 2>/dev/null
}

# =============================================================== FINDING 1 (a)
# The handoff dir is not writable, so rename(2) cannot create the archive — but
# overwriting an existing file inside it needs no directory write bit at all. The
# unguarded form archives nothing, writes anyway, and the incumbent is gone.
new_case f1a
put_seed f1a NEXT-demo.md d00dfeed "$LOST"
chmod a-w "$TMP/f1a/handoffs"
if { : > "$TMP/f1a/handoffs/.probe"; } 2>/dev/null; then
  rm -f "$TMP/f1a/handoffs/.probe"
  printf '  SKIP finding 1a: this user can write to a mode-555 dir (running as root?)\n'
else
  run_end f1a
  chmod u+w "$TMP/f1a/handoffs"
  if preserved f1a; then ok "1a unwritable dir: the incumbent seed survives"
  else bad "1a unwritable dir: the incumbent seed survives" "the previous session's handoff was destroyed"; fi
  if printf '%s' "$out" | grep -q 'REFUSE'; then ok "1a unwritable dir: the session REFUSES"
  else bad "1a unwritable dir: the session REFUSES" "no REFUSE in output: $(printf '%s' "$out" | tr '\n' '|')"; fi
  if [ "$rc" -ne 0 ]; then ok "1a unwritable dir: nonzero exit stops the write"
  else bad "1a unwritable dir: nonzero exit stops the write" "exit 0 — the write ran"; fi
fi

# =============================================================== FINDING 1 (b)
# The incumbent's OWN `session:` steers the archive path. usage-benchmark-row.py
# takes `[session-id-or-jsonl-path]`, so a path-valued id is a plausible thing to
# find in a seed — and interpolated raw it names a directory that does not exist,
# so `mv` fails and the unguarded write proceeds.
new_case f1b
put_seed f1b NEXT-demo.md 'sessions/2026-08-11/a1b2c3d4' "$LOST"
run_end f1b
if preserved f1b; then ok "1b '/' in session:: the incumbent seed survives"
else bad "1b '/' in session:: the incumbent seed survives" "the previous session's handoff was destroyed"; fi
if [ "$(archives f1b)" -ge 1 ]; then ok "1b '/' in session:: an archive was actually created"
else bad "1b '/' in session:: an archive was actually created" "zero archives on disk"; fi
if [ -z "$(find "$TMP/f1b/handoffs" -mindepth 2 2>/dev/null)" ]; then
  ok "1b '/' in session:: no path separator escaped into the archive name"
else bad "1b '/' in session:: no path separator escaped into the archive name" "$(find "$TMP/f1b/handoffs" -mindepth 2)"; fi
if grep -q 'SEED WRITTEN BY' "$TMP/f1b/handoffs/NEXT-demo.md" 2>/dev/null; then
  ok "1b '/' in session:: this session's seed still lands at the canonical name"
else bad "1b '/' in session:: this session's seed still lands at the canonical name" "$(ls "$TMP/f1b/handoffs")"; fi

# A `..`-only id must not climb out of the handoff dir either.
new_case f1b2
put_seed f1b2 NEXT-demo.md '../../etc/passwd' "$LOST"
run_end f1b2
if preserved f1b2 && [ "$(archives f1b2)" -ge 1 ]; then
  ok "1b traversal id: archived inside the handoff dir, incumbent intact"
else bad "1b traversal id: archived inside the handoff dir, incumbent intact" "$(ls -R "$TMP/f1b2/handoffs")"; fi

# Containment is structural, and this pins the structure: `$slug` is interpolated
# BEHIND the `NEXT-<scope>.<UTC>-` prefix, so it is never the leading component of
# a path element and a `..` inside it is just characters in a filename. Moving the
# id to the front of the template would make that false, which is why this is
# asserted rather than assumed. It must hold with or without the sanitiser.
new_case f1b3
put_seed f1b3 NEXT-demo.md '../escaped' "$LOST"
run_end f1b3
if [ -z "$(find "$TMP/f1b3" -maxdepth 1 -name '*.md' 2>/dev/null)" ]; then
  ok "1b '..' in session:: the archive never lands outside the handoff dir"
else bad "1b '..' in session:: the archive never lands outside the handoff dir" \
        "escaped to $(find "$TMP/f1b3" -maxdepth 1 -name '*.md')"; fi
# And the sanitiser's own job, which the guard cannot do: an id the archive path
# cannot be built from is a session that REFUSES forever — safe for the incumbent,
# but unable to hand off. Sanitised, the collision resolves normally.
if preserved f1b3 && [ "$(archives f1b3)" -ge 1 ]; then
  ok "1b '..' in session:: the handoff still completes, incumbent archived"
else bad "1b '..' in session:: the handoff still completes, incumbent archived" "$(ls -R "$TMP/f1b3")"; fi

# ============================================================== THE SESSION ID
# `$SID` is what archive-on-collide decides on and what step 3 gates on, so the
# doc has to establish it. Nothing here tells it the answer: the runner supplies a
# HOME with the script and one transcript, and the seed that comes out has to
# carry that transcript's id. This is the assertion the old harness could not
# make, because its own preamble set SID before the doc ran.
new_case sid
put_seed sid NEXT-demo.md f0f0f0f0 "$LOST"
run_end sid
if grep -q "^session: $MINE$" "$TMP/sid/handoffs/NEXT-demo.md" 2>/dev/null; then
  ok "session id: End step 1 resolves it from the transcript, not from the harness"
else bad "session id: End step 1 resolves it from the transcript, not from the harness" \
        "$(sed -n '1,6p' "$TMP/sid/handoffs/NEXT-demo.md" 2>/dev/null | tr '\n' '|')"; fi
if printf '%s' "$out" | grep -q 'unbound variable'; then
  bad "session id: End step 1 leaves no variable undefined" "$(printf '%s' "$out" | tr '\n' '|')"
else ok "session id: End step 1 leaves no variable undefined"; fi

# An id the session cannot resolve is not an empty string to carry on with: the
# seed's `session:` would be unarchivable by the NEXT session and unprovable by
# step 3, so the step stops while the incumbent is still intact.
new_case noid
put_seed noid NEXT-demo.md f0f0f0f0 "$LOST"
run_end noid nohome
if printf '%s' "$out" | grep -q 'REFUSE' && [ "$rc" -ne 0 ]; then
  ok "session id: an unresolvable id REFUSES instead of writing an anonymous seed"
else bad "session id: an unresolvable id REFUSES instead of writing an anonymous seed" \
        "rc=$rc, $(printf '%s' "$out" | tr '\n' '|')"; fi
if grep -q '^session: f0f0f0f0$' "$TMP/noid/handoffs/NEXT-demo.md" 2>/dev/null &&
   [ "$(archives noid)" -eq 0 ]; then
  ok "session id: the incumbent is left exactly where it was"
else bad "session id: the incumbent is left exactly where it was" "$(ls "$TMP/noid/handoffs")"; fi

# ================================================================= FINDING 2
# Step 3 must prove AUTHORSHIP, not existence. A stale foreign seed at the
# canonical path is a failed handoff whether it got there by a destroyed archive
# or by this session keying the seed on the wrong scope.
new_case f2
put_seed f2 NEXT-demo.md f0f0f0f0 "$LOST"
run_prove f2
if printf '%s' "$out" | grep -q 'REFUSE'; then ok "2 foreign seed: step 3 REFUSES"
else bad "2 foreign seed: step 3 REFUSES" "no REFUSE: $(printf '%s' "$out" | tr '\n' '|')"; fi
if printf '%s' "$out" | grep -q '^seed: '; then
  bad "2 foreign seed: step 3 does not print a pass" "it printed 'seed:' over another session's file"
else ok "2 foreign seed: step 3 does not print a pass"; fi

# A seed with no `session:` line at all is unidentifiable, which is not a pass.
new_case f2b
put_seed f2b NEXT-demo.md - "$LOST"
run_prove f2b
if printf '%s' "$out" | grep -q 'REFUSE' && ! printf '%s' "$out" | grep -q '^seed: '; then
  ok "2 unidentified seed: step 3 REFUSES"
else bad "2 unidentified seed: step 3 REFUSES" "$(printf '%s' "$out" | tr '\n' '|')"; fi

# ================================================================= FINDING 3
# The other mode step 3's paragraph names, and the one existence cannot see at
# all: this session keyed <scope> on the LINKED worktree's basename, wrote
# NEXT-demo-wt.md, and never touched the canonical NEXT-demo.md the next session
# will open. Its own seed is fine — it is just not the file anybody reads, and the
# previous session's stale seed is still sitting at the path that gets read.
#
# Nothing here hands step 3 a path: it runs in the linked worktree with the same
# three inputs as every other case, so the ONLY way to fail this is to re-derive
# <scope> from the main worktree. A step 3 given step 1's $SEED reads back step
# 1's own mistake and passes.
new_case f3
git -C "$TMP/f3/demo" worktree add -q "$TMP/f3/demo-wt" -b wt
put_seed f3 NEXT-demo.md 7c0ffee1 "$LOST"                    # stale, still canonical
put_seed f3 NEXT-demo-wt.md "$MINE" "my seed, at a path nobody reads"
run_prove f3 demo-wt
if printf '%s' "$out" | grep -q 'REFUSE' && ! printf '%s' "$out" | grep -q '^seed: '; then
  ok "3 wrong scope: a seed misfiled under the linked worktree's name does not pass"
else bad "3 wrong scope: a seed misfiled under the linked worktree's name does not pass" \
        "$(printf '%s' "$out" | tr '\n' '|')"; fi

# The positive half, without which the assertion above is satisfied by a check
# that always refuses from a linked worktree: correctly filed, the SAME layout
# passes, and the path it names is the main worktree's.
new_case f3b
git -C "$TMP/f3b/demo" worktree add -q "$TMP/f3b/demo-wt" -b wt
put_seed f3b NEXT-demo.md "$MINE" "my seed, correctly filed"
run_prove f3b demo-wt
if printf '%s' "$out" | grep -q '^seed: .*/NEXT-demo\.md$' && ! printf '%s' "$out" | grep -q 'REFUSE'; then
  ok "3 wrong scope: from a linked worktree the check reads the MAIN worktree's seed"
else bad "3 wrong scope: from a linked worktree the check reads the MAIN worktree's seed" \
        "$(printf '%s' "$out" | tr '\n' '|')"; fi

# And independence stated directly rather than inferred: hand step 3 a full set of
# step-1 variables, all wrong. Re-derivation overwrites every one of them.
run_prove f3b demo-wt poison
if printf '%s' "$out" | grep -q '^seed: .*/NEXT-demo\.md$'; then
  ok "3 wrong scope: step 3 discards inherited SCOPE/HANDOFF_DIR/SEED/SID"
else bad "3 wrong scope: step 3 discards inherited SCOPE/HANDOFF_DIR/SEED/SID" \
        "$(printf '%s' "$out" | tr '\n' '|')"; fi

# ============================================================ the happy paths
# The point of the fix is to keep these working, so they are asserted too.
new_case ok1
put_seed ok1 NEXT-demo.md aaaabbbb "$LOST"
run_end ok1
run_prove ok1
if printf '%s' "$out" | grep -q "^seed: " && ! printf '%s' "$out" | grep -q 'REFUSE'; then
  ok "happy path: this session's own seed passes step 3"
else bad "happy path: this session's own seed passes step 3" "$(printf '%s' "$out" | tr '\n' '|')"; fi
if [ "$(archives ok1)" -eq 1 ] && preserved ok1; then
  ok "happy path: an ordinary collision archives exactly one incumbent"
else bad "happy path: an ordinary collision archives exactly one incumbent" "$(ls "$TMP/ok1/handoffs")"; fi

new_case ok2
put_seed ok2 NEXT-demo.md "$MINE" "$LOST"
run_end ok2
if [ "$(archives ok2)" -eq 0 ] && [ "$rc" -eq 0 ]; then
  ok "happy path: re-running the same session's own write is not a collision"
else bad "happy path: re-running the same session's own write is not a collision" "rc=$rc, $(ls "$TMP/ok2/handoffs")"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
