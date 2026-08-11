#!/usr/bin/env bash
# Regression tests for the two executable blocks in generic/session-lifecycle.md
# that decide the fate of the PREVIOUS session's handoff seed: archive-on-collide
# (End step 1) and the authorship proof (End step 3).
#
# These are NOT greps. Both blocks are EXTRACTED FROM THE DOC and executed, so an
# assertion can only be satisfied by code that actually behaves. The repo has been
# bitten twice by substring guards that prose satisfied while the mechanism was
# gone (see validate-registry.yml's own comments); a doc whose snippets are run is
# the version of that guard that cannot be talked past.
#
# The runners deliberately do NOT `set -e`. Both defects below are "the guard
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
# Pull the two blocks out by an anchor that names what they DO, not where they
# sit — a renumbered step or a reflowed paragraph must not silently stop testing
# the code. A missing block is a hard failure: the doctrine's whole claim is that
# these are runnable commands, so a block that has become prose is the regression.
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

want = {'archive': 'mv "$SEED"',
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

ARCHIVE=$(cat "$TMP/archive.block")
PROVE=$(cat "$TMP/prove.block")

# ------------------------------------------------------------------- fixtures
# A scenario gets its own handoff dir, an incumbent seed with a chosen `session:`,
# and a run of "archive the incumbent, then write my own seed" — the doc's own
# sequence, with the write standing in for `# then write $SEED`.
INCUMBENT_BODY='# Handoff — the previous session

- **Picks up at:** the thing that must not be lost
'
MINE=beefcafe

new_case() {            # $1 = case dir, $2 = incumbent session: value ('-' for none)
  local d="$TMP/$1" prev=$2
  mkdir -p "$d/handoffs"
  {
    echo '---'
    echo 'type: handoff'
    echo 'scope: demo'
    [ "$prev" = '-' ] || echo "session: $prev"
    echo 'sensitivity: vault'
    echo '---'
    printf '%s' "$INCUMBENT_BODY"
  } > "$d/handoffs/NEXT-demo.md"
}

run_archive() {         # $1 = case dir; runs archive-then-write, echoes rc via $rc
  local d="$TMP/$1"
  cat > "$d/run.sh" <<RUNNER
set -u
SID=$MINE
SCOPE=demo
HANDOFF_DIR="$d/handoffs"
SEED="\$HANDOFF_DIR/NEXT-\$SCOPE.md"
$ARCHIVE
# stands in for the doc's \`# then write \$SEED\`, with the header End step 1
# requires — \`session:\` is what step 3 reads back, so a stand-in without it
# would be testing a seed the doctrine does not permit.
printf -- '---\ntype: handoff\nscope: demo\nsession: %s\n---\nSEED WRITTEN BY %s\n' "\$SID" "\$SID" > "\$SEED"
RUNNER
  out=$(cd "$d" && bash "$d/run.sh" 2>&1); rc=$?
}

run_prove() {           # $1 = case dir, $2 = path to check as $SEED
  local d="$TMP/$1"
  cat > "$d/prove.sh" <<RUNNER
set -u
SID=$MINE
SEED="$2"
$PROVE
RUNNER
  out=$(cd "$d" && bash "$d/prove.sh" 2>&1); rc=$?
}

archives() { ls "$TMP/$1/handoffs" 2>/dev/null | grep -c '^NEXT-demo\..*\.md$'; }
incumbent_preserved() { # the incumbent's bytes exist somewhere under the handoff dir
  grep -Rql 'the thing that must not be lost' "$TMP/$1/handoffs" 2>/dev/null
}

# =============================================================== FINDING 1 (a)
# The handoff dir is not writable, so rename(2) cannot create the archive — but
# overwriting an existing file inside it needs no directory write bit at all. The
# unguarded form archives nothing, writes anyway, and the incumbent is gone.
new_case f1a d00dfeed
chmod a-w "$TMP/f1a/handoffs"
if { : > "$TMP/f1a/handoffs/.probe"; } 2>/dev/null; then
  rm -f "$TMP/f1a/handoffs/.probe"
  printf '  SKIP finding 1a: this user can write to a mode-555 dir (running as root?)\n'
else
  run_archive f1a
  chmod u+w "$TMP/f1a/handoffs"
  if incumbent_preserved f1a; then ok "1a unwritable dir: the incumbent seed survives"
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
new_case f1b 'sessions/2026-08-11/a1b2c3d4'
run_archive f1b
if incumbent_preserved f1b; then ok "1b '/' in session:: the incumbent seed survives"
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
new_case f1b2 '../../etc/passwd'
run_archive f1b2
if incumbent_preserved f1b2 && [ "$(archives f1b2)" -ge 1 ]; then
  ok "1b traversal id: archived inside the handoff dir, incumbent intact"
else bad "1b traversal id: archived inside the handoff dir, incumbent intact" "$(ls -R "$TMP/f1b2/handoffs")"; fi

# Containment is structural, and this pins the structure: `$slug` is interpolated
# BEHIND the `NEXT-<scope>.<UTC>-` prefix, so it is never the leading component of
# a path element and a `..` inside it is just characters in a filename. Moving the
# id to the front of the template would make that false, which is why this is
# asserted rather than assumed. It must hold with or without the sanitiser.
new_case f1b3 '../escaped'
run_archive f1b3
if [ -z "$(find "$TMP/f1b3" -maxdepth 1 -name '*.md' 2>/dev/null)" ]; then
  ok "1b '..' in session:: the archive never lands outside the handoff dir"
else bad "1b '..' in session:: the archive never lands outside the handoff dir" \
        "escaped to $(find "$TMP/f1b3" -maxdepth 1 -name '*.md')"; fi
# And the sanitiser's own job, which the guard cannot do: an id the archive path
# cannot be built from is a session that REFUSES forever — safe for the incumbent,
# but unable to hand off. Sanitised, the collision resolves normally.
if incumbent_preserved f1b3 && [ "$(archives f1b3)" -ge 1 ]; then
  ok "1b '..' in session:: the handoff still completes, incumbent archived"
else bad "1b '..' in session:: the handoff still completes, incumbent archived" "$(ls -R "$TMP/f1b3")"; fi

# ================================================================= FINDING 2
# Step 3 must prove AUTHORSHIP, not existence. A stale foreign seed at $SEED is a
# failed handoff whether it got there by a destroyed archive or by this session
# keying the seed on the wrong scope.
new_case f2 f0f0f0f0
run_prove f2 "$TMP/f2/handoffs/NEXT-demo.md"
if printf '%s' "$out" | grep -q 'REFUSE'; then ok "2 foreign seed: step 3 REFUSES"
else bad "2 foreign seed: step 3 REFUSES" "no REFUSE: $(printf '%s' "$out" | tr '\n' '|')"; fi
if printf '%s' "$out" | grep -q '^seed: '; then
  bad "2 foreign seed: step 3 does not print a pass" "it printed 'seed:' over another session's file"
else ok "2 foreign seed: step 3 does not print a pass"; fi

# A seed with no `session:` line at all is unidentifiable, which is not a pass.
new_case f2b -
run_prove f2b "$TMP/f2b/handoffs/NEXT-demo.md"
if printf '%s' "$out" | grep -q 'REFUSE' && ! printf '%s' "$out" | grep -q '^seed: '; then
  ok "2 unidentified seed: step 3 REFUSES"
else bad "2 unidentified seed: step 3 REFUSES" "$(printf '%s' "$out" | tr '\n' '|')"; fi

# ============================================================ the happy paths
# The point of the fix is to keep these working, so they are asserted too.
new_case ok1 aaaabbbb
run_archive ok1
run_prove ok1 "$TMP/ok1/handoffs/NEXT-demo.md"
if printf '%s' "$out" | grep -q "^seed: " && ! printf '%s' "$out" | grep -q 'REFUSE'; then
  ok "happy path: this session's own seed passes step 3"
else bad "happy path: this session's own seed passes step 3" "$(printf '%s' "$out" | tr '\n' '|')"; fi
if [ "$(archives ok1)" -eq 1 ] && incumbent_preserved ok1; then
  ok "happy path: an ordinary collision archives exactly one incumbent"
else bad "happy path: an ordinary collision archives exactly one incumbent" "$(ls "$TMP/ok1/handoffs")"; fi

new_case ok2 "$MINE"
run_archive ok2
if [ "$(archives ok2)" -eq 0 ] && [ "$rc" -eq 0 ]; then
  ok "happy path: re-running the same session's own write is not a collision"
else bad "happy path: re-running the same session's own write is not a collision" "rc=$rc, $(ls "$TMP/ok2/handoffs")"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
