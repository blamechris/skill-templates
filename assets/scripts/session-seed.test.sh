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
# These offline fixtures must never discover a developer's running daemon.
export CHROXY_SEED_ANNOUNCE=0
# Never read the developer's HOME or global git config, and never let the commit
# step see a real identity: a temp HOME and an empty global config.
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1

# The archive-vs-canonical discriminator, written out HERE rather than imported, so
# the script cannot satisfy these assertions by redefining its own rule. This is
# byte-for-byte the regex `/next` uses to skip archives when it ranks the fleet.
ARCHIVE_RE='^NEXT-[^/]*\.[0-9]{8}T[0-9]{6}Z-[^.]+\.md$'
STAMP=2026-08-11T00:00:00Z              # -> 20260811T000000Z in archive names
MINE=beefcafe
LOST='the thing that must not be lost'
# Filled inputs are external fixture data, not an implementation of validation.
GOOD_PICKS='Add seed validation (agent Sol)'
GOOD_NEXT='Add seed validation. Acceptance: hollow writes and verifies refuse.'
cat > "$TMP/filled-body.md" <<'BODY'
## STATE

- Branch main is clean; no PR is open. Prior seed checks passed.
- Read assets/scripts/session-seed.py and its sibling regression suite first.

## TL;DR — what shipped

The session seed path and archive checks are usable; filled-content checks remain.

## Left undone, deliberately

No owner QA is needed before implementing the validator.
BODY
FILLED=(--boundary-reason 'package complete' --next "$GOOD_NEXT" --body-file "$TMP/filled-body.md")

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
run_raw() {
  local c=$1 where=$2; shift 2
  out=$(cd "$TMP/$c/$where" && CLAUDE_HANDOFF_DIR="$TMP/$c/handoffs" \
        "$PY" "$SUT" "$@" 2>&1); rc=$?
}
# Legacy path/session/archive cases supply valid content so a content refusal
# cannot accidentally satisfy the behavior each of those cases targets.
run() {
  local c=$1 where=$2; shift 2
  if [ "${1:-}" = write ]; then
    shift
    run_raw "$c" "$where" write "${FILLED[@]}" "$@"
  else
    run_raw "$c" "$where" "$@"
  fi
}
# write <case> <cwd> [extra args...] — the ordinary end-of-session call
write() {
  local c=$1 where=$2; shift 2
  run "$c" "$where" write --session "$MINE" --now "$STAMP" \
      --picks-up-at 'the next thing (agent Sol)' "$@"
}
archives() { ls "$TMP/$1/handoffs" 2>/dev/null | grep -Ec "$ARCHIVE_RE"; }
canon()    { ls "$TMP/$1/handoffs" 2>/dev/null | grep -E '^NEXT-.*\.md$' | grep -Evc "$ARCHIVE_RE"; }
preserved(){ grep -Rql "${2:-$LOST}" "$TMP/$1/handoffs" 2>/dev/null; }

# ============================================================ GROUP A — scope
# Ordinary repo scopes use the MAIN worktree's directory basename. The handoff
# repository is the fleet exception. These cases catch simpler rules such as a
# $PWD prefix, origin slug, or `basename $PWD`.
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
# New Git versions report an invalid gitfile instead of "not a git repository".
# The real orphan fixture must reach the same specific guard under either wording.
mkdir -p "$TMP/a7/gitfile-stub"
cat > "$TMP/a7/gitfile-stub/git" <<'STUB'
#!/bin/sh
echo 'fatal: gitfile does not point to a valid repository' >&2
exit 128
STUB
chmod +x "$TMP/a7/gitfile-stub/git"
out=$(cd "$TMP/a7/demo-wt" && PATH="$TMP/a7/gitfile-stub:$PATH" \
      CLAUDE_HANDOFF_DIR="$TMP/a7/handoffs" "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'REFUSE.*main checkout is gone' \
  && ok 'an orphaned worktree gets the specific refusal with the newer gitfile diagnostic' \
  || bad 'an orphaned worktree gets the specific refusal with the newer gitfile diagnostic' "rc=$rc $(flat "$out")"
mkdir -p "$TMP/a7/not-an-orphan"
out=$(cd "$TMP/a7/not-an-orphan" && PATH="$TMP/a7/gitfile-stub:$PATH" \
      CLAUDE_HANDOFF_DIR="$TMP/a7/handoffs" "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'REFUSE.*other than' \
  && ok 'an unfamiliar git failure without an orphan remains a generic refusal' \
  || bad 'an unfamiliar git failure without an orphan remains a generic refusal' "rc=$rc $(flat "$out")"
# The negative half: `fleet` must stay reachable from a directory that is genuinely
# outside every repo. A guard that refuses everywhere would satisfy the two above.
mkdir -p "$TMP/a7/outside"
run a7 outside scope
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "the orphan guard does not break the ordinary fleet case" \
  || bad "the orphan guard does not break the ordinary fleet case" "rc=$rc $(flat "$out")"

# The versioned handoff vault is a git repository, but its sessions own the
# fleet seed. A separate app checkout with the same basename remains app-scoped.
mkdir -p "$TMP/a8/vault" "$TMP/a8/app"
new_repo "$TMP/a8/vault/no-it-all"
new_repo "$TMP/a8/app/no-it-all"
VAULT="$TMP/a8/vault/no-it-all"
VAULT_HANDOFFS="$VAULT/handoffs"
mkdir -p "$VAULT_HANDOFFS" "$VAULT/deep/nested"
out=$(cd "$VAULT" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "the repository holding the handoff dir resolves to fleet" \
  || bad "the repository holding the handoff dir resolves to fleet" "rc=$rc $(flat "$out")"
out=$(cd "$VAULT/deep/nested" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "nested path in the handoff repository resolves to fleet" \
  || bad "nested path in the handoff repository resolves to fleet" "rc=$rc $(flat "$out")"
out=$(cd "$TMP/a8/app/no-it-all" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = no-it-all ] \
  && ok "an app named no-it-all keeps its own scope" \
  || bad "an app named no-it-all keeps its own scope" "rc=$rc $(flat "$out")"

git -C "$VAULT" worktree add -q "$TMP/a8/vault-linked" -b vault-linked
mkdir -p "$TMP/a8/vault-linked/deep"
out=$(cd "$TMP/a8/vault-linked/deep" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "a linked worktree of the handoff repository resolves to fleet" \
  || bad "a linked worktree of the handoff repository resolves to fleet" "rc=$rc $(flat "$out")"

# Probe the nearest existing parent when a custom handoff dir does not yet exist.
out=$(cd "$VAULT" && CLAUDE_HANDOFF_DIR="$VAULT/custom/missing/handoffs" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "a missing custom handoff dir in the same repository resolves to fleet" \
  || bad "a missing custom handoff dir in the same repository resolves to fleet" "rc=$rc $(flat "$out")"
ln -s "$VAULT" "$TMP/a8/vault-alias"
out=$(cd "$VAULT" && CLAUDE_HANDOFF_DIR="$TMP/a8/vault-alias/handoffs" \
      "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "a symlinked handoff path keeps repository identity" \
  || bad "a symlinked handoff path keeps repository identity" "rc=$rc $(flat "$out")"
out=$(cd "$VAULT" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" scope --topic planning 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet-planning ] \
  && ok "a topic in the handoff repository uses fleet-topic" \
  || bad "a topic in the handoff repository uses fleet-topic" "rc=$rc $(flat "$out")"

# Resolving a fleet scope does not waive the floor: writing from inside the
# vault would put a session seed in that session's own worktree.
out=$(cd "$VAULT" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" \
      --picks-up-at 'vault floor (agent Sol)' 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*inside the worktree' \
  && [ ! -f "$VAULT_HANDOFFS/NEXT-fleet.md" ] \
  && ok "writing from the vault still REFUSES an in-worktree seed" \
  || bad "writing from the vault still REFUSES an in-worktree seed" "rc=$rc $(flat "$out")"
out=$(cd "$TMP/a8/vault-linked" && CLAUDE_HANDOFF_DIR="$VAULT_HANDOFFS" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" \
      --picks-up-at 'vault floor (agent Sol)' 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*inside the worktree' \
  && [ ! -f "$VAULT_HANDOFFS/NEXT-fleet.md" ] \
  && ok "writing from a linked vault worktree still REFUSES" \
  || bad "writing from a linked vault worktree still REFUSES" "rc=$rc $(flat "$out")"

# The default path also identifies the vault, with no environment override.
FAKE_VAULT_HOME="$TMP/a9/home"
mkdir -p "$FAKE_VAULT_HOME/Obsidian"
new_repo "$FAKE_VAULT_HOME/Obsidian/no-it-all"
out=$(cd "$FAKE_VAULT_HOME/Obsidian/no-it-all" && env -u CLAUDE_HANDOFF_DIR \
      HOME="$FAKE_VAULT_HOME" "$PY" "$SUT" scope 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = fleet ] \
  && ok "the default handoff path identifies its repository as fleet" \
  || bad "the default handoff path identifies its repository as fleet" "rc=$rc $(flat "$out")"

# ==================================================== GROUP B — the handoff dir
echo; echo "B. the handoff dir"

# THE DEFAULT ARM, EXECUTED. Every earlier suite set CLAUDE_HANDOFF_DIR in every
# case, so `${CLAUDE_HANDOFF_DIR:-~/Obsidian/no-it-all/handoffs}` was never once run
# — the one branch that fires on a real machine with no override set.
new_case b1
FAKE_HOME="$TMP/b1/home"; mkdir -p "$FAKE_HOME"
out=$(cd "$TMP/b1/demo" && env -u CLAUDE_HANDOFF_DIR HOME="$FAKE_HOME" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'default dir (agent Sol)' 2>&1); rc=$?
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
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --picks-up-at 'x (agent Sol)' 2>&1); rc=$?
printf '%s' "$out" | grep -q 'REFUSE.*relative' \
  && ok "a relative CLAUDE_HANDOFF_DIR REFUSES" \
  || bad "a relative CLAUDE_HANDOFF_DIR REFUSES" "$(flat "$out")"

# The floor rule, enforced where it is executable: a handoff dir inside the worktree
# is a seed that dies with `git worktree remove --force`.
new_case b5
out=$(cd "$TMP/b5/demo" && CLAUDE_HANDOFF_DIR="$TMP/b5/demo/in-tree-handoffs" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --picks-up-at 'x (agent Sol)' 2>&1); rc=$?
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
      "$PY" "$SUT" write "${FILLED[@]}" --now "$STAMP" --picks-up-at 'from the env (agent Sol)' 2>&1); rc=$?
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
cp "$HERE/usage_accounting.py" "$BH/.claude/scripts/" 2>/dev/null || \
  bad "fixture: usage_accounting.py is present" "missing next to the SUT"
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
# Resolved the way a real End step does — via $CLAUDE_CODE_SESSION_ID. (The row
# script's old no-id fallback is gone: with neither an argument nor the env var
# it now REFUSES, per its own suite.)
row=$(HOME="$BH" CLAUDE_CODE_SESSION_ID="$UUID" "$PY" "$BH/.claude/scripts/usage-benchmark-row.py" 2>/dev/null |
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
      "$PY" "$SUT" write "${FILLED[@]}" --now "$STAMP" --picks-up-at 'x (agent Sol)' 2>&1); rc=$?
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
      CLAUDE_HANDOFF_DIR="$TMP/c2/handoffs" "$PY" "$SUT" write "${FILLED[@]}" --picks-up-at 'x (agent Sol)' 2>&1); rc=$?
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
run c3 demo write --session "$MINE" --picks-up-at 'x (agent Sol)' --now "$STAMP"
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
PICKS='issue #205 — the "doc" said: extract it (agent Sol)'
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
    && ok "the filled body carries '$section'" || bad "the filled body carries '$section'" "missing"
done

new_case e2
printf '## MY OWN BODY\n\nverbatim\n\n## STATE\n\nBranch main is clean.\n\n## TL;DR\n\nThe custom body was retained.\n' > "$TMP/e2/body.md"
run e2 demo write --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' --body-file "$TMP/e2/body.md"
grep -q '^## MY OWN BODY$' "$TMP/e2/handoffs/NEXT-demo.md" &&
  grep -q '^The custom body was retained'  "$TMP/e2/handoffs/NEXT-demo.md" \
  && ok "--body-file retains filled custom content, header still generated" \
  || bad "--body-file retains filled custom content, header still generated" "$(flat "$(cat "$TMP/e2/handoffs/NEXT-demo.md")")"

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
# The handoff repository probe uses git -C. Only alter the session repository.
[ "\$1" = -C ] && exec "$GIT_REAL" "\$@"
case "\$*" in
  *--git-common-dir*) [ -f "$TMP/f3b/handoffs/NEXT-demo.md" ] && { echo "$TMP/f3b/other/.git"; exit 0; } ;;
esac
exec "$GIT_REAL" "\$@"
STUB
chmod +x "$TMP/f3b/stub/git"
out=$(cd "$TMP/f3b/demo" && PATH="$TMP/f3b/stub:$PATH" CLAUDE_HANDOFF_DIR="$TMP/f3b/handoffs" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSE.*NEXT-other\.md' \
  && ok "write EXITS NONZERO when its own proof refuses (the proof is not decorative)" \
  || bad "write EXITS NONZERO when its own proof refuses (the proof is not decorative)" "rc=$rc $(flat "$out")"
out=$(cd "$TMP/f3b/demo" && PATH="$TMP/f3b/stub:$PATH" CLAUDE_HANDOFF_DIR="$TMP/f3b/handoffs" \
      "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' --no-verify 2>&1); rc=$?
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
run g1 nowhere write --session "$MINE" --now "$STAMP" --topic marathon --picks-up-at 'the wave (agent Sol)'
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
run g1 nowhere write --session "$MINE" --now "$STAMP" --picks-up-at 'no topic (agent Sol)'
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
run h2 blamechris.github.io write --session "$MINE" --now "$STAMP" --picks-up-at 'dotted scope (agent Sol)'
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
run h2 blamechris.github.io write --session "$MINE" --now "$STAMP" --picks-up-at 'collide (agent Sol)'
run h2 blamechris.github.io list --archives
[ "$(nrows "$out")" -eq 1 ] && printf '%s' "$out" | grep -q '^blamechris.github.io	' \
  && ok "list --archives keeps a dotted scope key whole (no phantom scope)" \
  || bad "list --archives keeps a dotted scope key whole (no phantom scope)" "$(flat "$out")"
! printf '%s' "$out" | grep -q '^blamechris	' \
  && ok "list --archives reports no truncated scope that does not exist" \
  || bad "list --archives reports no truncated scope that does not exist" "$(flat "$out")"

# ======================================================= GROUP H — filled content
echo; echo "H. filled content and pre-archive refusal"
new_case i1
run i1 demo write --session "$MINE" --picks-up-at "$GOOD_PICKS" --now "$STAMP" \
    --alt 'Review the documentation (agent Sol)' --alt 'Inspect the queued tests (agent Sol)'
[ "$rc" -eq 0 ] && grep -q '^## Today' "$TMP/i1/handoffs/NEXT-demo.md" \
  && grep -q '^## Alternatives$' "$TMP/i1/handoffs/NEXT-demo.md" \
  && [ "$(grep -Ec '^\- (Review|Inspect)' "$TMP/i1/handoffs/NEXT-demo.md")" -eq 2 ] \
  && ok "filled content with --next and two --alt values writes and proves" \
  || bad "filled content with --next and two --alt values writes and proves" "rc=$rc $(flat "$out")"
cp "$TMP/i1/handoffs/NEXT-demo.md" "$TMP/valid-seed.md"

# A proposed invalid replacement may not move even a hollow legacy incumbent.
new_case i2
put_seed i2 NEXT-demo.md previous-session "$LOST"
cp "$TMP/i2/handoffs/NEXT-demo.md" "$TMP/incumbent.md"
refused_unchanged() {
  local label=$1; shift
  run i2 demo write --session "$MINE" --now "$STAMP" --picks-up-at "$GOOD_PICKS" "$@"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
     && cmp -s "$TMP/incumbent.md" "$TMP/i2/handoffs/NEXT-demo.md" \
     && [ "$(archives i2)" -eq 0 ]; then
    ok "$label: refuses before moving the incumbent"
  else bad "$label: refuses before moving the incumbent" "rc=$rc $(flat "$out")"; fi
}
refused_unchanged 'unstated boundary' --boundary-reason unstated
refused_unchanged 'empty boundary' --boundary-reason ''
for picks in 'Add tests or review docs (agent Sol)' 'Add tests; review docs (agent Sol)' \
             'Add tests · review docs (agent Sol)' 'Review CANDIDATE tests (agent Sol)' \
             'NEXT RUNS add tests (agent Sol)'; do
  refused_unchanged "multiple task marker '$picks'" --picks-up-at "$picks"
done
long_picks=$("$PY" -c 'print("x" * 129 + " (agent Sol)")')
[ "${#long_picks}" -eq 141 ] || bad 'fixture: overlong dispatch has 141 characters'
refused_unchanged 'dispatch longer than 140 characters' --picks-up-at "$long_picks"
refused_unchanged 'missing executor' --picks-up-at 'Add the remaining script tests'
refused_unchanged 'empty agent executor' --picks-up-at 'Add the remaining script tests (agent )'
refused_unchanged 'empty owner executor' --picks-up-at 'Add the remaining script tests OWNER:'
refused_unchanged 'missing next task' --next ''
refused_unchanged 'missing acceptance' --next 'Add the remaining script tests.'
refused_unchanged 'empty acceptance' --next 'Add the remaining script tests. Acceptance: '
refused_unchanged 'two next tasks' --next 'Add tests or review docs. Acceptance: the suite passes.'
refused_unchanged 'three alternatives' --alt one --alt two --alt three
refused_unchanged 'empty alternative' --alt ''
: > "$TMP/empty-body.md"
refused_unchanged 'empty context body' --body-file "$TMP/empty-body.md"
printf '## STATE\n\n## TL;DR\n\n\n' > "$TMP/empty-sections.md"
refused_unchanged 'unfilled context headings' --body-file "$TMP/empty-sections.md"
cp "$TMP/filled-body.md" "$TMP/placeholder-body.md"
printf '\nRead <issue description> next.\n' >> "$TMP/placeholder-body.md"
refused_unchanged 'generic angle placeholder in prose' --body-file "$TMP/placeholder-body.md"
cp "$TMP/filled-body.md" "$TMP/skeleton-body.md"
printf '\n```bash\ngh pr view <n> --json state\n```\n' >> "$TMP/skeleton-body.md"
refused_unchanged 'retired skeleton hole even in a code fence' --body-file "$TMP/skeleton-body.md"
cp "$TMP/filled-body.md" "$TMP/duplicate-task.md"
printf "\n## Today's task\n\nAdd tests. Acceptance: suites pass.\n" >> "$TMP/duplicate-task.md"
refused_unchanged 'body duplicates generated task' --body-file "$TMP/duplicate-task.md"

# Missing switches use the raw runner, so fixture defaults cannot fill omissions.
for missing in body next boundary; do
  args=(--session "$MINE" --picks-up-at "$GOOD_PICKS")
  [ "$missing" = body ] || args+=(--body-file "$TMP/filled-body.md")
  [ "$missing" = next ] || args+=(--next "$GOOD_NEXT")
  [ "$missing" = boundary ] || args+=(--boundary-reason 'package complete')
  run_raw i2 demo write "${args[@]}"
  [ "$rc" -eq 1 ] && cmp -s "$TMP/incumbent.md" "$TMP/i2/handoffs/NEXT-demo.md" \
    && [ "$(archives i2)" -eq 0 ] \
    && ok "omitting $missing refuses without a skeleton or archive" \
    || bad "omitting $missing refuses without a skeleton or archive" "rc=$rc $(flat "$out")"
done

# Positive controls: exact length boundary, OWNER dispatch, stdin context,
# zero/one alternatives and generic bracket syntax inside real code samples.
new_case i3
picks_140=$("$PY" -c 'print("x" * 128 + " (agent Sol)")')
run i3 demo write --session "$MINE" --picks-up-at "$picks_140"
[ "$rc" -eq 0 ] && ok '140-character dispatch is accepted' \
  || bad '140-character dispatch is accepted' "rc=$rc $(flat "$out")"
cp "$TMP/filled-body.md" "$TMP/code-body.md"
cat >> "$TMP/code-body.md" <<'BODY'

```typescript
const sample = '<example value>';
~~~
```

~~~~text
<other sample>
~~~
~~~~
BODY
run i3 demo write --session "$MINE" --picks-up-at 'OWNER: Chris — Review the smoke result' \
    --body-file "$TMP/code-body.md" --alt 'Inspect the queued docs (agent Sol)'
[ "$rc" -eq 0 ] && ok 'OWNER executor, one alternative and fenced generic angles are accepted' \
  || bad 'OWNER executor, one alternative and fenced generic angles are accepted' "rc=$rc $(flat "$out")"
out=$(cd "$TMP/i3/demo" && CLAUDE_HANDOFF_DIR="$TMP/i3/handoffs" \
      "$PY" "$SUT" write --session "$MINE" --picks-up-at "$GOOD_PICKS" \
      --boundary-reason 'package complete' --next "$GOOD_NEXT" --body-file - < "$TMP/filled-body.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^## Alternatives$' "$TMP/i3/handoffs/NEXT-demo.md" \
  && ok 'filled stdin body and zero alternatives are accepted' \
  || bad 'filled stdin body and zero alternatives are accepted' "rc=$rc $(flat "$out")"

# Mutate a filled seed to ensure canonical and archive verification check content.
new_case i4
"$PY" - "$TMP/valid-seed.md" "$TMP/i4/handoffs" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
def picks(value):
    import re
    return re.sub(r'^picks_up_at:.*$', 'picks_up_at: "' + value + '"', text, flags=re.M)
cases = {
    'hollow': text[:text.index('## STATE')],
    'no-boundary': text.replace('- **Boundary reason:** package complete\n', ''),
    'unstated': text.replace('**Boundary reason:** package complete', '**Boundary reason:** unstated'),
    'no-executor': picks('Add tests'),
    'overlong': picks('x' * 129 + ' (agent Sol)'),
    'missing-picks': text.replace('picks_up_at:', 'old_picks_up_at:'),
    'placeholder': text + '\n<state description>\n',
    'skeleton': text + '\n```\ngh pr view <n>\n```\n',
    'no-task': text.replace("## Today's task", '## Old task'),
    'no-acceptance': text.replace('Acceptance:', 'Result:'),
    'empty-state': text[:text.index('## STATE')] + '## STATE\n\n' + text[text.index('## TL;DR'):],
    'empty-tldr': text[:text.index('## TL;DR')] + '## TL;DR\n\n' + text[text.index('## Left undone'):],
    'three-alts': text.replace('- Review the documentation (agent Sol)', '- Third alternative\n- Review the documentation (agent Sol)'),
}
for index, marker in enumerate((' OR ', ';', '·', 'Candidate', 'nExT rUnS')):
    cases['marker-%d' % index] = picks('Add tests' + marker + 'review docs (agent Sol)')
for name, value in cases.items():
    pathlib.Path(sys.argv[2], name + '.md').write_text(value)
PY
for invalid in "$TMP/i4/handoffs/"*.md; do
  cp "$invalid" "$TMP/i4/handoffs/NEXT-demo.md"
  run i4 demo verify --session "$MINE"
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
    && ! printf '%s' "$out" | grep -q '^seed:' \
    && ok "canonical verify refuses $(basename "$invalid")" \
    || bad "canonical verify refuses $(basename "$invalid")" "rc=$rc $(flat "$out")"
  run_raw i4 demo verify --file "$invalid"
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
    && ok "content-only verify refuses $(basename "$invalid")" \
    || bad "content-only verify refuses $(basename "$invalid")" "rc=$rc $(flat "$out")"
done
archive_file="$TMP/i4/handoffs/NEXT-demo.20260811T000000Z-previous.md"
cp "$TMP/valid-seed.md" "$archive_file"
run_raw i4 demo verify --file "$archive_file"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^content valid (NOT canonical proof):' \
  && ! printf '%s' "$out" | grep -q '^seed:' \
  && ok 'a filled archive validates without canonical proof or a session argument' \
  || bad 'a filled archive validates without canonical proof or a session argument' "rc=$rc $(flat "$out")"
run_raw i4 demo verify --file "$archive_file" --session "$MINE"
[ "$rc" -eq 1 ] && ok '--file cannot be combined with canonical session proof' \
  || bad '--file cannot be combined with canonical session proof' "rc=$rc $(flat "$out")"

# Demonstrate the new assertion detects a broken validator. Disable only content
# checks; the mutant still resolves the canonical path and session identity.
"$PY" - "$SUT" "$TMP/mutant.py" <<'PY'
import ast, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
node = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'validate_content')
lines = source.splitlines(keepends=True)
lines[node.lineno - 1:node.end_lineno] = ['def validate_content(text):\n    return\n']
pathlib.Path(sys.argv[2]).write_text(''.join(lines))
PY
cp "$TMP/i4/handoffs/hollow.md" "$TMP/i4/handoffs/NEXT-demo.md"
run i4 demo verify --session "$MINE"
real_rc=$rc
out=$(cd "$TMP/i4/demo" && CLAUDE_HANDOFF_DIR="$TMP/i4/handoffs" \
      "$PY" "$TMP/mutant.py" verify --session "$MINE" 2>&1); rc=$?
[ "$real_rc" -eq 1 ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^seed:' \
  && ok 'negative control: hollow-seed refusal assertion fails with disabled-validator mutant' \
  || bad 'negative control: hollow-seed refusal assertion fails with disabled-validator mutant' "real=$real_rc mutant=$rc $(flat "$out")"

# ====================================================== GROUP I — pulse metadata
echo; echo "I. structured decisions and pulse metadata"
new_case j1
cat > "$TMP/decisions.json" <<'JSON'
[{"text":"Approve issue #123","opened_at":"2026-08-11T00:00:00Z","default":"Keep the recommendation pending an answer"}]
JSON
cat > "$TMP/pulse.json" <<'JSON'
{"at":"2026-08-11T00:00:00Z","line":"delta: no baseline | WARN: none","state":{"scope":"demo","tests":"PASS #123"}}
JSON
run j1 demo write --session "$MINE" --now "$STAMP" --picks-up-at "$GOOD_PICKS" \
  --decisions-file "$TMP/decisions.json" --pulse-file "$TMP/pulse.json"
[ "$rc" -eq 0 ] && ok 'full seed write accepts structured decisions and pulse' \
  || bad 'full seed write accepts structured decisions and pulse' "rc=$rc $(flat "$out")"
hdr=$("$PY" "$SUT" header "$TMP/j1/handoffs/NEXT-demo.md")
printf '%s' "$hdr" | "$PY" -c 'import json,sys; h=json.load(sys.stdin); assert json.loads(h["decisions"])[0]["text"] == "Approve issue #123"; assert json.loads(h["last_pulse"])["state"]["tests"] == "PASS #123"'
[ "$?" -eq 0 ] && ok 'JSON-flow metadata round-trips embedded # without YAML-comment truncation' \
  || bad 'JSON-flow metadata round-trips embedded # without YAML-comment truncation'
cp "$TMP/j1/handoffs/NEXT-demo.md" "$TMP/before-refresh.md"
run_raw j1 demo write --session next-session --now "$STAMP" --refresh-pulse "$TMP/pulse.json"
"$PY" - "$TMP/before-refresh.md" "$TMP/j1/handoffs/NEXT-demo.md" <<'PY'
from pathlib import Path
import sys
before, after = (Path(p).read_text() for p in sys.argv[1:])
assert before.split('\n---\n', 1)[1] == after.split('\n---\n', 1)[1]
assert 'date: 2026-08-11T00:00Z\n' in after
assert 'session: next-session\n' in after
assert 'Approve issue #123' in after
PY
metadata_rc=$?
[ "$rc" -eq 0 ] && [ "$metadata_rc" -eq 0 ] && [ "$(archives j1)" -eq 1 ] \
  && ok 'refresh preserves body/date/decisions, archives foreign session and proves actual session' \
  || bad 'refresh preserves body/date/decisions, archives foreign session and proves actual session' "rc=$rc $(flat "$out")"
run_raw j1 demo write --session next-session --now "$STAMP" --refresh-pulse "$TMP/pulse.json"
[ "$rc" -eq 0 ] && [ "$(archives j1)" -eq 1 ] \
  && ok 'same-session refresh does not create a spurious archive' \
  || bad 'same-session refresh does not create a spurious archive' "rc=$rc $(flat "$out")"

# Every malformed metadata input refuses before moving the existing i2 seed.
for invalid in '{}' '[{}]' \
 '[{"text":"Approve","opened_at":"yesterday","default":"Hold"}]' \
 '[{"text":"Approve","opened_at":"2026-08-11T00:00:00Z","default":""}]' \
 '[{"text":false,"opened_at":"2026-08-11T00:00:00Z","default":"Hold"}]'; do
  printf '%s\n' "$invalid" > "$TMP/invalid-decisions.json"
  refused_unchanged 'invalid decisions metadata' --decisions-file "$TMP/invalid-decisions.json"
done
for invalid in '{}' \
 '{"at":"yesterday","line":"readout","state":{"scope":"demo"}}' \
 '{"at":"2026-08-11T00:00:00Z","line":false,"state":{"scope":"demo"}}' \
 '{"at":"2026-08-11T00:00:00Z","line":"readout","state":{"scope":"other-repo"}}'; do
  printf '%s\n' "$invalid" > "$TMP/invalid-pulse.json"
  refused_unchanged 'invalid or wrong-scope pulse metadata' --pulse-file "$TMP/invalid-pulse.json"
done
run_raw j1 demo write --session next-session --refresh-pulse "$TMP/pulse.json" --next "$GOOD_NEXT"
[ "$rc" -eq 1 ] && ok 'refresh refuses full-write input switches' \
  || bad 'refresh refuses full-write input switches' "rc=$rc $(flat "$out")"
run_raw j1 demo write --refresh-pulse "$TMP/pulse.json"
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'REFUSE.*no id' \
  && ok 'refresh never guesses the actual session identity' \
  || bad 'refresh never guesses the actual session identity' "rc=$rc $(flat "$out")"

# Existing metadata is revalidated by canonical proof, not trusted because a
# previous writer accepted the rest of the seed.
cp "$TMP/j1/handoffs/NEXT-demo.md" "$TMP/filled-metadata-seed.md"
"$PY" - "$TMP/j1/handoffs/NEXT-demo.md" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); p.write_text(re.sub(r'^decisions:.*$', 'decisions: [{}]', p.read_text(), flags=re.M))
PY
run_raw j1 demo verify --session next-session
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'REFUSE.*each decision' \
  && ok 'canonical verify rejects malformed existing decision metadata' \
  || bad 'canonical verify rejects malformed existing decision metadata' "rc=$rc $(flat "$out")"
cp "$TMP/filled-metadata-seed.md" "$TMP/j1/handoffs/NEXT-demo.md"
"$PY" - "$TMP/j1/handoffs/NEXT-demo.md" <<'PY'
from pathlib import Path
import json, re, sys
p=Path(sys.argv[1]); text=p.read_text()
m=re.search(r'^last_pulse: (.*)$', text, flags=re.M)
snapshot=json.loads(m.group(1)); snapshot['state']['scope']='other-repo'
p.write_text(text[:m.start(1)]+json.dumps(snapshot)+text[m.end(1):])
PY
run_raw j1 demo verify --session next-session
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'REFUSE.*scope does not match' \
  && ok 'canonical verify rejects a snapshot belonging to another scope' \
  || bad 'canonical verify rejects a snapshot belonging to another scope' "rc=$rc $(flat "$out")"

# =================================================== GROUP J — visible content
echo; echo "J. invisible comments cannot fill required content"
cat > "$TMP/comment-only-body.md" <<'BODY'
## STATE
<!-- Fill current state here -->
## TL;DR
<!-- Fill shipped changes here -->
BODY
refused_unchanged 'comment-only boundary reason' --boundary-reason '<!-- pending -->'
refused_unchanged 'comment-hidden dispatch executor' --picks-up-at 'Add checks <!-- (agent Sol) -->'
refused_unchanged 'comment-only STATE and TLDR' --body-file "$TMP/comment-only-body.md"
refused_unchanged 'comment-only task and acceptance' --next '<!-- Add checks. Acceptance: suites pass. -->'
refused_unchanged 'comment-only acceptance' --next 'Add checks. Acceptance: <!-- fill result here -->'
refused_unchanged 'comment-only action' --next '<!-- Add checks. --> Acceptance: suites pass.'
refused_unchanged 'comment-hidden Acceptance marker' --next 'Add checks. <!-- Acceptance: suites pass. -->'
cp "$TMP/filled-body.md" "$TMP/comment-skeleton-body.md"
printf '\n<!-- <n> -->\n' >> "$TMP/comment-skeleton-body.md"
refused_unchanged 'explicit skeleton hole remains invalid inside a comment' --body-file "$TMP/comment-skeleton-body.md"

new_case k1
cat > "$TMP/visible-comment-body.md" <<'BODY'
<!--
```markdown
## STATE
Fake heading inside an invisible comment.
-->
## STATE

The main branch is clean. <!-- Ordinary note alongside visible state. -->

```html
<!-- This is literal code, not an unclosed prose comment.
```

## TL;DR — what shipped

Visible checks passed. <!-- Ordinary note alongside visible delivery. -->
BODY
run k1 demo write --session "$MINE" --picks-up-at "$GOOD_PICKS <!-- note -->" \
  --boundary-reason 'package complete <!-- ordinary note -->' \
  --body-file "$TMP/visible-comment-body.md" \
  --next 'Add checks. <!-- Ordinary task note. --> Acceptance: the suites pass.'
[ "$rc" -eq 0 ] && ok 'visible content with ordinary comments and literal code delimiters writes and proves' \
  || bad 'visible content with ordinary comments and literal code delimiters writes and proves' "rc=$rc $(flat "$out")"
run_raw k1 demo verify --file "$TMP/k1/handoffs/NEXT-demo.md"
[ "$rc" -eq 0 ] && ok 'content-only verify accepts filled prose with ordinary comments' \
  || bad 'content-only verify accepts filled prose with ordinary comments' "rc=$rc $(flat "$out")"

# Mutate filled seeds so both verify modes must independently reject hidden holes.
new_case k2
"$PY" - "$TMP/valid-seed.md" "$TMP/k2/handoffs" <<'PY'
from pathlib import Path
import re, sys
text=Path(sys.argv[1]).read_text()
def section(name, body):
    return re.sub(r'(^## '+name+r'[^\n]*\n)[\s\S]*?(?=^## |\Z)',
                  lambda m:m.group(1)+'\n'+body+'\n\n', text, count=1, flags=re.M)
cases={
 'boundary-comment': text.replace('**Boundary reason:** package complete', '**Boundary reason:** <!-- pending -->'),
 'executor-comment': re.sub(r'^picks_up_at:.*$', 'picks_up_at: "Add checks <!-- (agent Sol) -->"', text, flags=re.M),
 'state-comment': section('STATE', '<!-- Fill current state here -->'),
 'tldr-comment': section('TL;DR', '<!-- Fill shipped changes here -->'),
 'task-comment': section("Today's task", '<!-- Add checks. Acceptance: suites pass. -->'),
 'acceptance-comment': section("Today's task", 'Add checks. Acceptance: <!-- fill result here -->'),
 'action-comment': section("Today's task", '<!-- Add checks. --> Acceptance: suites pass.'),
 'hidden-acceptance-marker': section("Today's task", 'Add checks. <!-- Acceptance: suites pass. -->'),
}
for name,value in cases.items():
    Path(sys.argv[2],name+'.md').write_text(value)
PY
for invalid in "$TMP/k2/handoffs/"*.md; do
  cp "$invalid" "$TMP/k2/handoffs/NEXT-demo.md"
  run_raw k2 demo verify --session "$MINE"
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
    && ok "canonical verify refuses $(basename "$invalid")" \
    || bad "canonical verify refuses $(basename "$invalid")" "rc=$rc $(flat "$out")"
  run_raw k2 demo verify --file "$invalid"
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
    && ok "content-only verify refuses $(basename "$invalid")" \
    || bad "content-only verify refuses $(basename "$invalid")" "rc=$rc $(flat "$out")"
done
"$PY" - "$SUT" "$TMP/comment-mutant.py" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
needle='parts = sections(visible)'
assert needle in source
Path(sys.argv[2]).write_text(source.replace(needle,'parts = sections(prose)'))
PY
cp "$TMP/k2/handoffs/state-comment.md" "$TMP/k2/handoffs/NEXT-demo.md"
run_raw k2 demo verify --session "$MINE"
real_rc=$rc
out=$(cd "$TMP/k2/demo" && CLAUDE_HANDOFF_DIR="$TMP/k2/handoffs" \
  "$PY" "$TMP/comment-mutant.py" verify --session "$MINE" 2>&1); rc=$?
[ "$real_rc" -eq 1 ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^seed:' \
  && ok 'negative control: hidden-content assertion fails when comments count as filled prose' \
  || bad 'negative control: hidden-content assertion fails when comments count as filled prose' "real=$real_rc mutant=$rc $(flat "$out")"

# ================================================= GROUP K — literal inline code
echo; echo "K. matched inline backticks preserve literal comment delimiters"
new_case l1
mkdir -p "$TMP/inline-positive-bodies"
"$PY" - "$TMP/inline-positive-bodies" <<'PY'
from pathlib import Path
import sys
cases={
 'single': 'The literal token `<!--` is supported.',
 'double': 'The literal token ``<!-- ` nested`` is supported.',
 'triple': 'The literal token ```<!-- `` nested``` is supported.',
 'at-line-start': '```<!--``` is the literal token.',
 'multiline-double': 'The literal token ``<!--\ncontinues here`` is supported.',
 'multiline-single': 'The token `first\nthen <!--` is supported.',
 'ordered-two-dot': 'The token `first\n2. <!--` is supported.',
 'ordered-two-paren': 'The token `first\n2) <!--` is supported.',
 'ordered-zero': 'The token `first\n0. <!--` is supported.',
 'ordered-ten-digit-one': 'The token `first\n0000000001. <!--` is supported.',
}
for name,state in cases.items():
    Path(sys.argv[1],name+'.md').write_text('## STATE\n\n'+state+'\n\n## TL;DR\n\nVisible checks passed.\n')
PY
for body in "$TMP/inline-positive-bodies/"*.md; do
  name=$(basename "$body")
  run l1 demo write --session "$MINE" --picks-up-at "$GOOD_PICKS" --body-file "$body" \
    --next 'Add checks for `<!--` tokens. Acceptance: the suites pass.'
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^seed:' \
    && ok "writer accepts literal inline delimiters in $name" \
    || bad "writer accepts literal inline delimiters in $name" "rc=$rc $(flat "$out")"
  run_raw l1 demo verify --session "$MINE"
  [ "$rc" -eq 0 ] && ok "canonical verify accepts literal inline delimiters in $name" \
    || bad "canonical verify accepts literal inline delimiters in $name" "rc=$rc $(flat "$out")"
  run_raw l1 demo verify --file "$TMP/l1/handoffs/NEXT-demo.md"
  [ "$rc" -eq 0 ] && ok "content-only verify accepts literal inline delimiters in $name" \
    || bad "content-only verify accepts literal inline delimiters in $name" "rc=$rc $(flat "$out")"
done
cp "$TMP/l1/handoffs/NEXT-demo.md" "$TMP/inline-positive-seed.md"

# Backticks that do not match within the paragraph are literal punctuation, not
# permission to expose a real comment as filled content. Refusal must precede archive.
mkdir -p "$TMP/inline-negative-bodies"
"$PY" - "$TMP/inline-negative-bodies" "$TMP/valid-seed.md" <<'PY'
from pathlib import Path
import re, sys
base=Path(sys.argv[2]).read_text()
cases={
 'unmatched': '` <!-- Fill current state here -->',
 'mismatched': '`` <!-- Fill current state here --> `',
 'different-runs': '``` <!-- Fill current state here --> ``',
 'blank-line-boundary': '` <!-- Fill current state here -->\n\n`',
 'comment-before-span': '<!-- ` Fill current state here --> `',
 'real-comment-after-span': '`<!--` <!-- Fill current state here -->',
 'ordered-one-dot': 'The token `first\n1. <!--` is supported.',
 'ordered-one-paren': 'The token `first\n1) <!--` is supported.',
 'ordered-leading-zero-one': 'The token `first\n01. <!--` is supported.',
 'ordered-nine-digit-one': 'The token `first\n000000001) <!--` is supported.',
}
for name,state in cases.items():
    body='## STATE\n\n'+state+'\n\n## TL;DR\n\nVisible checks passed.\n'
    Path(sys.argv[1],name+'.body.md').write_text(body)
    text=re.sub(r'(^## STATE[^\n]*\n)[\s\S]*?(?=^## )',
                lambda m:m.group(1)+'\n'+state+'\n\n',base,count=1,flags=re.M)
    Path(sys.argv[1],name+'.seed.md').write_text(text)
PY
new_case l2
for body in "$TMP/inline-negative-bodies/"*.body.md; do
  name=$(basename "$body" .body.md)
  refused_unchanged "real comment with $name backtick control" --body-file "$body"
  fixture="$TMP/inline-negative-bodies/$name.seed.md"
  cp "$fixture" "$TMP/l2/handoffs/NEXT-demo.md"
  run_raw l2 demo verify --session "$MINE"
  [ "$rc" -eq 1 ] && ok "canonical verify refuses real comment in $name" \
    || bad "canonical verify refuses real comment in $name" "rc=$rc $(flat "$out")"
  run_raw l2 demo verify --file "$fixture"
  [ "$rc" -eq 1 ] && ok "content-only verify refuses real comment in $name" \
    || bad "content-only verify refuses real comment in $name" "rc=$rc $(flat "$out")"
done

# Disable only inline recognition to show that the valid-input assertion detects
# the reported regression, while leaving comment and fenced-code behavior intact.
"$PY" - "$SUT" "$TMP/inline-mutant.py" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
needle='tick = BACKTICK_RUN.search(line, offset, start if start != -1 else len(line))'
assert needle in source
Path(sys.argv[2]).write_text(source.replace(needle,'tick = None'))
PY
cp "$TMP/inline-positive-seed.md" "$TMP/l1/handoffs/NEXT-demo.md"
run_raw l1 demo verify --session "$MINE"
real_rc=$rc
out=$(cd "$TMP/l1/demo" && CLAUDE_HANDOFF_DIR="$TMP/l1/handoffs" \
  "$PY" "$TMP/inline-mutant.py" verify --session "$MINE" 2>&1); rc=$?
[ "$real_rc" -eq 0 ] && [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^REFUSE:' \
  && ok 'negative control: valid inline-literal assertion fails without inline recognition' \
  || bad 'negative control: valid inline-literal assertion fails without inline recognition' "real=$real_rc mutant=$rc $(flat "$out")"

# ============================================================ GROUP M — commit step
# `write` commits exactly its own paths (the seed, plus the archive on a collide)
# after the proof, and never pushes. The vault here is a REAL temp git repo.
echo; echo "M. commit own paths"

new_vault() {           # $1 = case -> $TMP/<case>/{vault/handoffs,demo}; vault has an initial commit
  mkdir -p "$TMP/$1/vault/handoffs"
  git -c init.defaultBranch=main init -q "$TMP/$1/vault"
  echo keep > "$TMP/$1/vault/README"
  git -C "$TMP/$1/vault" add -- README
  git -C "$TMP/$1/vault" commit -q -m init
  new_repo "$TMP/$1/demo"
}
mrun() {                # <case> [args...] -> $out (stdout) $err (stderr) $rc ; handoff dir defaults to the vault's
  local c=$1; shift
  local o="$TMP/$c.stdout" e="$TMP/$c.stderr"
  (cd "${MCWD:-$TMP/$c/demo}" && PATH="${FAKE_GIT_LOG:+$FAKEBIN:}$PATH" \
     CLAUDE_HANDOFF_DIR="${MHD:-$TMP/$c/vault/handoffs}" \
     "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" \
     --picks-up-at 'the next thing (agent Sol)' "$@" >"$o" 2>"$e"); rc=$?
  out=$(cat "$o"); err=$(cat "$e")
}
# A fake `git` on PATH that logs "<subcommand> <args>" and can misbehave on one subcommand:
#   FAKE_GIT_BADERR=<sub>   -> invalid UTF-8 on stderr, exit 1
#   FAKE_GIT_SLEEP=<sub>    -> sleep 5 before running
#   FAKE_GIT_PRE_SUB=<sub> + FAKE_GIT_PRE_CMD=<sh> -> run <sh> just before the real call
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
export REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<'FAKE'
#!/bin/sh
sub=""; skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C) skip=1 ;; -*) ;; *) sub=$a; break ;; esac
done
[ -n "${FAKE_GIT_LOG:-}" ] && echo "$sub $*" >> "$FAKE_GIT_LOG"
if [ -n "${FAKE_GIT_PRE_SUB:-}" ] && [ "$sub" = "$FAKE_GIT_PRE_SUB" ]; then eval "$FAKE_GIT_PRE_CMD"; fi
if [ -n "${FAKE_GIT_BADERR:-}" ] && [ "$sub" = "$FAKE_GIT_BADERR" ]; then printf 'bad \377\376 bytes\n' >&2; exit 1; fi
if [ -n "${FAKE_GIT_SLEEP:-}" ] && [ "$sub" = "$FAKE_GIT_SLEEP" ]; then exec sleep 5; fi
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$FAKEBIN/git"
V() { git -C "$TMP/$1/vault" "${@:2}"; }

# M1 first write commits the seed, and only the seed
new_vault m1
mrun m1
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V m1 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && [ -z "$(V m1 status --porcelain)" ] \
  && ok "M1 first write commits the seed and nothing else" \
  || bad "M1 first write commits the seed and nothing else" "rc=$rc $(flat "$out") $(flat "$err") $(flat "$(V m1 status --porcelain)")"
[ "$(V m1 log -1 --format=%s)" = "handoffs: seed demo (beefcafe)" ] \
  && ok "M1 commit message names scope and session slug" \
  || bad "M1 commit message names scope and session slug" "$(V m1 log -1 --format=%s)"
[ "$(V m1 log -1 --format=%B | grep -ci 'co-authored')" -eq 0 ] \
  && ok "M1 commit carries no attribution trailer" || bad "M1 commit carries no attribution trailer"

# M2 collide-archive write commits both paths
new_vault m2
mkdir -p "$TMP/m2/handoffs"; put_seed m2 NEXT-demo.md other-session "$LOST"
mv "$TMP/m2/handoffs/NEXT-demo.md" "$TMP/m2/vault/handoffs/NEXT-demo.md"
V m2 add -- handoffs/NEXT-demo.md; V m2 commit -q -m "other seed" -- handoffs/NEXT-demo.md
mrun m2
files=$(V m2 show --name-only --format= HEAD | sort | tr '\n' '|')
[ "$rc" -eq 0 ] && [ "$(printf '%s' "$files" | tr '|' '\n' | grep -c .)" -eq 2 ] \
  && printf '%s' "$files" | grep -Eq 'handoffs/NEXT-demo\.20260811T000000Z-other-session\.md' \
  && printf '%s' "$files" | grep -q 'handoffs/NEXT-demo\.md|' \
  && [ -z "$(V m2 status --porcelain)" ] \
  && ok "M2 collide-archive write commits the seed and the archive" \
  || bad "M2 collide-archive write commits the seed and the archive" "rc=$rc files=$files $(flat "$err") $(flat "$(V m2 status --porcelain)")"

# M3 another session's staged file stays staged and out of the commit;
# M4 an unrelated dirty file stays untouched
new_vault m3
echo theirs > "$TMP/m3/vault/handoffs/NEXT-other.md"; V m3 add -- handoffs/NEXT-other.md
echo dirty >> "$TMP/m3/vault/README"
mrun m3
[ "$rc" -eq 0 ] \
  && [ "$(V m3 diff --cached --name-only)" = "handoffs/NEXT-other.md" ] \
  && [ "$(V m3 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && ok "M3 another session's staged file stays staged and uncommitted" \
  || bad "M3 another session's staged file stays staged and uncommitted" "rc=$rc staged=$(V m3 diff --cached --name-only | tr '\n' '|') head=$(V m3 show --name-only --format= HEAD | tr '\n' '|')"
[ "$(V m3 diff --name-only)" = "README" ] && [ "$(V m3 diff --cached --name-only | grep -c README)" -eq 0 ] \
  && [ "$(tail -1 "$TMP/m3/vault/README")" = dirty ] \
  && ok "M4 an unrelated modified file stays unstaged, uncommitted and intact" \
  || bad "M4 an unrelated modified file stays unstaged, uncommitted and intact" "$(V m3 status --porcelain | tr '\n' '|')"

# M5 handoff dir outside git -> skipped, exit 0, seed present
new_case m5
run_raw m5 demo write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)'
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^commit: skipped (handoff dir is not in a git repository)$' \
  && [ -f "$TMP/m5/handoffs/NEXT-demo.md" ] \
  && ok "M5 handoff dir outside git: skipped, exit 0, seed present" \
  || bad "M5 handoff dir outside git: skipped, exit 0, seed present" "rc=$rc $(flat "$out")"

# M6 ignored seed -> UNCOMMITTED, exit 0, seed present, nothing committed
new_vault m6
echo 'handoffs/NEXT-*.md' > "$TMP/m6/vault/.gitignore"; V m6 add -- .gitignore; V m6 commit -q -m ign
before=$(V m6 rev-parse HEAD)
mrun m6
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: .*git-ignored' \
  && [ -f "$TMP/m6/vault/handoffs/NEXT-demo.md" ] && [ "$(V m6 rev-parse HEAD)" = "$before" ] \
  && printf '%s' "$out" | grep -q '^seed: ' \
  && ok "M6 ignored seed: UNCOMMITTED on stderr, exit 0, seed present and proved" \
  || bad "M6 ignored seed: UNCOMMITTED on stderr, exit 0, seed present and proved" "rc=$rc $(flat "$out") $(flat "$err")"

# M7 commit hooks never run: a pre-commit that stages README and a post-commit that
# leaves a marker are both inert, and README is not committed (plumbing commit)
new_vault m7
echo dirty >> "$TMP/m7/vault/README"
printf '#!/bin/sh\necho ran > "%s/m7-pre"\ngit add README\nexit 1\n' "$TMP" > "$TMP/m7/vault/.git/hooks/pre-commit"
printf '#!/bin/sh\necho ran > "%s/m7-post"\n' "$TMP" > "$TMP/m7/vault/.git/hooks/post-commit"
chmod +x "$TMP/m7/vault/.git/hooks/pre-commit" "$TMP/m7/vault/.git/hooks/post-commit"
mrun m7
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ ! -e "$TMP/m7-pre" ] && [ ! -e "$TMP/m7-post" ] \
  && [ "$(V m7 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && [ -z "$(V m7 diff --cached --name-only | grep README)" ] && [ "$(V m7 diff --name-only)" = README ] \
  && ok "M7 no commit hook runs; README is neither staged nor committed" \
  || bad "M7 no commit hook runs; README is neither staged nor committed" "rc=$rc $(flat "$out") $(flat "$err") pre=$([ -e "$TMP/m7-pre" ] && echo ran)"

# M8 opt-outs
new_vault m8
before=$(V m8 rev-parse HEAD)
mrun m8 --no-commit
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^commit: skipped (opted out)$' \
  && [ "$(V m8 rev-parse HEAD)" = "$before" ] && [ -f "$TMP/m8/vault/handoffs/NEXT-demo.md" ] \
  && ok "M8 --no-commit skips the commit" || bad "M8 --no-commit skips the commit" "rc=$rc $(flat "$out")"
new_vault m9
before=$(V m9 rev-parse HEAD)
CLAUDE_SEED_COMMIT=0 mrun m9
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^commit: skipped (opted out)$' \
  && [ "$(V m9 rev-parse HEAD)" = "$before" ] \
  && ok "M9 CLAUDE_SEED_COMMIT=0 skips the commit" || bad "M9 CLAUDE_SEED_COMMIT=0 skips the commit" "rc=$rc $(flat "$out")"

# M10 --no-verify never commits
new_vault m10
before=$(V m10 rev-parse HEAD)
mrun m10 --no-verify
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^wrote (UNPROVED)' \
  && [ "$(V m10 rev-parse HEAD)" = "$before" ] && ! printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}' \
  && ok "M10 --no-verify (unproved) is never committed" \
  || bad "M10 --no-verify (unproved) is never committed" "rc=$rc $(flat "$out")"

# M11 identical content -> unchanged
new_vault m11
mrun m11; first=$(V m11 rev-parse HEAD)
mrun m11
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^commit: unchanged$' && [ "$(V m11 rev-parse HEAD)" = "$first" ] \
  && ok "M11 identical rewrite reports unchanged and makes no commit" \
  || bad "M11 identical rewrite reports unchanged and makes no commit" "rc=$rc $(flat "$out") $(flat "$err")"

# M12 a scope containing `*` does not widen the commit
mkdir -p "$TMP/m12/vault/handoffs" "$TMP/m12/we*rd"
git -c init.defaultBranch=main init -q "$TMP/m12/vault"
git -C "$TMP/m12/we*rd" init -q -b main 2>/dev/null || git -c init.defaultBranch=main init -q "$TMP/m12/we*rd"
git -C "$TMP/m12/we*rd" commit -q --allow-empty -m init
echo r > "$TMP/m12/vault/README"; git -C "$TMP/m12/vault" add -- README; git -C "$TMP/m12/vault" commit -q -m init
echo a > "$TMP/m12/vault/handoffs/NEXT-weXrd.md"; echo b > "$TMP/m12/vault/handoffs/NEXT-weYYrd.md"
git -C "$TMP/m12/vault" add -- handoffs/NEXT-weXrd.md handoffs/NEXT-weYYrd.md
git -C "$TMP/m12/vault" commit -q -m siblings
echo a2 > "$TMP/m12/vault/handoffs/NEXT-weXrd.md"; echo b2 > "$TMP/m12/vault/handoffs/NEXT-weYYrd.md"
(cd "$TMP/m12/we*rd" && CLAUDE_HANDOFF_DIR="$TMP/m12/vault/handoffs" "$PY" "$SUT" write "${FILLED[@]}" \
   --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' >"$TMP/m12.out" 2>"$TMP/m12.err"); rc=$?
files=$(git -C "$TMP/m12/vault" show --name-only --format= HEAD | tr '\n' '|')
[ "$rc" -eq 0 ] && [ "$files" = 'handoffs/NEXT-we*rd.md|' ] \
  && [ "$(git -C "$TMP/m12/vault" diff --name-only | sort | tr '\n' '|')" = 'handoffs/NEXT-weXrd.md|handoffs/NEXT-weYYrd.md|' ] \
  && ok "M12 a '*' in the scope commits only the literal path" \
  || bad "M12 a '*' in the scope commits only the literal path" "rc=$rc files=$files $(cat "$TMP/m12.out" "$TMP/m12.err" | tr '\n' '|')"

# M13 an invalid pulse snapshot is refused and leaves the vault alone
new_vault m13
mrun m13
pulse="$TMP/m13-pulse.json"
"$PY" - "$pulse" <<'PY'
import json,sys
json.dump({"state":{"scope":"demo"}},open(sys.argv[1],"w"))
PY
# the snapshot schema is owned by validate_pulse_snapshot; only assert that a refused
# refresh leaves the vault untouched, which is the property this case needs
head_before=$(V m13 rev-parse HEAD)
(cd "$TMP/m13/demo" && CLAUDE_HANDOFF_DIR="$TMP/m13/vault/handoffs" "$PY" "$SUT" write --session "$MINE" \
   --now "$STAMP" --refresh-pulse "$pulse" >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$(V m13 rev-parse HEAD)" = "$head_before" ] \
  && ok "M13 an invalid pulse snapshot is refused before any commit" || bad "M13 an invalid pulse snapshot is refused before any commit" "rc=$rc"

# M14 hostile GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE: the decoy repo is untouched
new_vault m14
new_repo "$TMP/m14/decoy"
decoy_before="$(cat "$TMP/m14/decoy/.git/HEAD") $(git -C "$TMP/m14/decoy" rev-parse HEAD) $(shasum "$TMP/m14/decoy/.git/index" 2>/dev/null | cut -d' ' -f1)"
GIT_DIR="$TMP/m14/decoy/.git" GIT_INDEX_FILE="$TMP/m14/decoy/.git/index" GIT_WORK_TREE="$TMP/m14/decoy" mrun m14
decoy_after="$(cat "$TMP/m14/decoy/.git/HEAD") $(git -C "$TMP/m14/decoy" rev-parse HEAD) $(shasum "$TMP/m14/decoy/.git/index" 2>/dev/null | cut -d' ' -f1)"
[ "$rc" -eq 0 ] && [ "$decoy_before" = "$decoy_after" ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V m14 log -1 --format=%s | cut -c1-9)" = "handoffs:" ] && [ "handoffs/$(basename "$(printf '%s\n' "$out" | sed -n 's/^seed: //p')")" = "$(V m14 show --name-only --format= HEAD)" ] \
  && ok "M14 hostile GIT_DIR/GIT_INDEX_FILE: decoy HEAD and index byte-identical, vault committed" \
  || bad "M14 hostile GIT_DIR/GIT_INDEX_FILE: decoy HEAD and index byte-identical, vault committed" "rc=$rc before=$decoy_before after=$decoy_after $(flat "$out") $(flat "$err")"

# M15 v0 (HEAD) / v1 (staged) / v2 (worktree) / v3 (this write): UNCOMMITTED, v1 survives
new_vault m15
mkdir -p "$TMP/m15/handoffs"; put_seed m15 NEXT-demo.md "$MINE" v0
cp "$TMP/m15/handoffs/NEXT-demo.md" "$TMP/m15/vault/handoffs/NEXT-demo.md"
V m15 add -- handoffs/NEXT-demo.md; V m15 commit -q -m v0
put_seed m15 NEXT-demo.md "$MINE" v1; cp "$TMP/m15/handoffs/NEXT-demo.md" "$TMP/m15/vault/handoffs/NEXT-demo.md"
V m15 add -- handoffs/NEXT-demo.md
put_seed m15 NEXT-demo.md "$MINE" v2; cp "$TMP/m15/handoffs/NEXT-demo.md" "$TMP/m15/vault/handoffs/NEXT-demo.md"
idx_before=$(V m15 ls-files -s -- handoffs/NEXT-demo.md); head_before=$(V m15 rev-parse HEAD)
mrun m15
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: handoffs/NEXT-demo.md has separately staged changes' \
  && [ "$(V m15 ls-files -s -- handoffs/NEXT-demo.md)" = "$idx_before" ] && [ "$(V m15 rev-parse HEAD)" = "$head_before" ] \
  && grep -q 'the next thing' "$TMP/m15/vault/handoffs/NEXT-demo.md" && printf '%s' "$out" | grep -q '^seed: ' \
  && ok "M15 separately staged seed: UNCOMMITTED, shared-index blob and HEAD unchanged, v3 on disk" \
  || bad "M15 separately staged seed: UNCOMMITTED, shared-index blob and HEAD unchanged, v3 on disk" "rc=$rc $(flat "$out") $(flat "$err")"

# M16 a tracked file with staged AND unstaged edits is untouched (entry and bytes)
new_vault m16
echo staged >> "$TMP/m16/vault/README"; V m16 add -- README; echo unstaged >> "$TMP/m16/vault/README"
e1=$(V m16 ls-files -s -- README); b1=$(shasum "$TMP/m16/vault/README")
mrun m16
[ "$rc" -eq 0 ] && [ "$(V m16 ls-files -s -- README)" = "$e1" ] && [ "$(shasum "$TMP/m16/vault/README")" = "$b1" ] \
  && ok "M16 staged+unstaged README: index entry and worktree bytes byte-identical" \
  || bad "M16 staged+unstaged README: index entry and worktree bytes byte-identical" "rc=$rc"

# M17 a clean filter that strips frontmatter does not change the committed bytes
new_vault m17
echo 'handoffs/*.md filter=strip' > "$TMP/m17/vault/.gitattributes"
V m17 config filter.strip.clean "sed '1,/^---\$/d'"
V m17 add -- .gitattributes; V m17 commit -q -m attrs
mrun m17
V m17 show HEAD:handoffs/NEXT-demo.md > "$TMP/m17.blob"
[ "$rc" -eq 0 ] && cmp -s "$TMP/m17.blob" "$TMP/m17/vault/handoffs/NEXT-demo.md" && head -1 "$TMP/m17.blob" | grep -q '^---$' \
  && ok "M17 clean filter: the committed blob equals the proved bytes" \
  || bad "M17 clean filter: the committed blob equals the proved bytes" "rc=$rc $(flat "$out") $(flat "$err")"

# M18 the seed replaced between proof and commit (injected before the re-read)
new_vault m18
head_before=$(V m18 rev-parse HEAD)
FAKE_GIT_LOG="$TMP/m18.log" FAKE_GIT_PRE_SUB=check-ignore FAKE_GIT_PRE_CMD="echo tamper >> '$TMP/m18/vault/handoffs/NEXT-demo.md'" mrun m18
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: seed changed after proof' \
  && [ "$(V m18 rev-parse HEAD)" = "$head_before" ] && [ -f "$TMP/m18/vault/handoffs/NEXT-demo.md" ] \
  && ok "M18 seed changed after proof: UNCOMMITTED, nothing committed" \
  || bad "M18 seed changed after proof: UNCOMMITTED, nothing committed" "rc=$rc $(flat "$out") $(flat "$err")"

# M19 non-UTF-8 stderr from git -> UNCOMMITTED, exit 0 (no UnicodeDecodeError)
new_vault m19
FAKE_GIT_LOG="$TMP/m19.log" FAKE_GIT_BADERR=write-tree mrun m19
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: git write-tree failed' && ! printf '%s' "$err" | grep -q Traceback \
  && printf '%s' "$out" | grep -q '^seed: ' \
  && ok "M19 non-UTF-8 git stderr: UNCOMMITTED, exit 0, no traceback" \
  || bad "M19 non-UTF-8 git stderr: UNCOMMITTED, exit 0, no traceback" "rc=$rc $(flat "$out") $(flat "$err")"

# M20 a git call that outlives the timeout -> UNCOMMITTED, exit 0
new_vault m20
FAKE_GIT_LOG="$TMP/m20.log" FAKE_GIT_SLEEP=write-tree CLAUDE_SEED_GIT_TIMEOUT=1 mrun m20
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: git write-tree timed out' \
  && [ -f "$TMP/m20/vault/handoffs/NEXT-demo.md" ] \
  && ok "M20 git timeout: UNCOMMITTED, exit 0, seed present" \
  || bad "M20 git timeout: UNCOMMITTED, exit 0, seed present" "rc=$rc $(flat "$out") $(flat "$err")"

# M21 the branch moves under EVERY update-ref (plumbing, so the index is not swept in): after
# the retries it is UNCOMMITTED, the other commits are kept and the shared index was never touched
new_vault m21
MOVE="\"\$REAL_GIT\" -C '$TMP/m21/vault' update-ref refs/heads/main \$(\"\$REAL_GIT\" -C '$TMP/m21/vault' commit-tree 'HEAD^{tree}' -p HEAD -m other)"
FAKE_GIT_LOG="$TMP/m21.log" FAKE_GIT_PRE_SUB=update-ref FAKE_GIT_PRE_CMD="$MOVE" mrun m21
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: branch moved' \
  && [ "$(V m21 log -1 --format=%s)" = other ] && [ "$(V m21 log --format=%s | grep -c '^other$')" -eq 5 ] \
  && [ -f "$TMP/m21/vault/handoffs/NEXT-demo.md" ] \
  && [ -z "$(V m21 ls-files -s -- handoffs)" ] && [ -z "$(V m21 status --porcelain | grep -E '^[ADMR]|^.[DM]')" ] \
  && ok "M21 branch moved on every try: UNCOMMITTED after 5 attempts, other commits kept, shared index untouched" \
  || bad "M21 branch moved on every try: UNCOMMITTED after 5 attempts, other commits kept, shared index untouched" "rc=$rc $(flat "$out") $(flat "$err") $(V m21 log --format=%s | tr '\n' ' ') idx=$(V m21 ls-files -s -- handoffs)"

# M21b the branch moves once: the build is redone on the new HEAD and commits
new_vault m21b
MOVE_B="${MOVE//m21/m21b}"
FAKE_GIT_LOG="$TMP/m21b.log" FAKE_GIT_PRE_SUB=update-ref \
  FAKE_GIT_PRE_CMD="[ -e '$TMP/m21b.once' ] || { : > '$TMP/m21b.once'; $MOVE_B; }" mrun m21b
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V m21b show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] && [ "$(V m21b log --format=%s | sed -n 2p)" = other ] \
  && [ -z "$(V m21b status --porcelain | grep -E '^[ADMR]|^.[DM]')" ] \
  && ok "M21b branch moved once: rebuilt on the new HEAD, committed, index clean" \
  || bad "M21b branch moved once: rebuilt on the new HEAD, committed, index clean" "rc=$rc $(flat "$out") $(flat "$err") $(V m21b log --format=%s | tr '\n' ' ')"

# M29 a held index.lock: UNCOMMITTED, nothing moves
new_vault m29
: > "$TMP/m29/vault/.git/index.lock"
head_before=$(V m29 rev-parse HEAD); idx_before=$(V m29 ls-files -s | shasum)
CLAUDE_SEED_LOCK_WAIT=1 mrun m29
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: shared index locked' \
  && [ "$(V m29 rev-parse HEAD)" = "$head_before" ] && [ "$(V m29 ls-files -s | shasum)" = "$idx_before" ] \
  && [ -f "$TMP/m29/vault/handoffs/NEXT-demo.md" ] && printf '%s' "$out" | grep -q '^seed: ' \
  && ok "M29 held index.lock: UNCOMMITTED, HEAD and shared index unchanged, seed on disk" \
  || bad "M29 held index.lock: UNCOMMITTED, HEAD and shared index unchanged, seed on disk" "rc=$rc $(flat "$out") $(flat "$err")"

# M30 a lock released mid-backoff: commits, and nothing is left staged or modified
new_vault m30
: > "$TMP/m30/vault/.git/index.lock"
( sleep 1; rm -f "$TMP/m30/vault/.git/index.lock" ) &
CLAUDE_SEED_LOCK_WAIT=10 mrun m30
wait
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V m30 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && [ -z "$(V m30 status --porcelain | grep -E '^[ADMR]|^.[DM]')" ] \
  && ok "M30 lock released mid-backoff: commits and status shows nothing staged or modified" \
  || bad "M30 lock released mid-backoff: commits and status shows nothing staged or modified" "rc=$rc $(flat "$out") $(flat "$err") $(V m30 status --porcelain | tr '\n' '|')"

# M31 an executable seed keeps its mode
new_vault m31
mkdir -p "$TMP/m31/handoffs"; put_seed m31 NEXT-demo.md "$MINE" v0
cp "$TMP/m31/handoffs/NEXT-demo.md" "$TMP/m31/vault/handoffs/NEXT-demo.md"; chmod +x "$TMP/m31/vault/handoffs/NEXT-demo.md"
V m31 add -- handoffs/NEXT-demo.md; V m31 commit -q -m exec
mrun m31
[ "$rc" -eq 0 ] && [ "$(V m31 ls-tree HEAD -- handoffs/NEXT-demo.md | cut -c1-6)" = 100755 ] \
  && [ "$(V m31 ls-files -s -- handoffs/NEXT-demo.md | cut -c1-6)" = 100755 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ -x "$TMP/m31/vault/handoffs/NEXT-demo.md" ] && [ -z "$(V m31 status --porcelain)" ] \
  && ok "M31 existing mode (100755) is preserved in the commit, the index and the worktree; status is clean" \
  || bad "M31 existing mode (100755) is preserved in the commit, the index and the worktree; status is clean" "rc=$rc $(flat "$out") $(flat "$err") $(V m31 status --porcelain | tr '\n' '|')"

# M33 a successful --refresh-pulse commits the seed (and the archive of the previous session's)
new_vault m33
mrun m33
head_before=$(V m33 rev-parse HEAD)
(cd "$TMP/m33/demo" && CLAUDE_HANDOFF_DIR="$TMP/m33/vault/handoffs" "$PY" "$SUT" write --session next-session \
   --now "$STAMP" --refresh-pulse "$TMP/pulse.json" >"$TMP/m33.out" 2>"$TMP/m33.err"); rc=$?
[ "$rc" -eq 0 ] && grep -Eq '^commit: [0-9a-f]{7,}$' "$TMP/m33.out" && [ "$(V m33 rev-parse HEAD)" != "$head_before" ] \
  && V m33 show --name-only --format= HEAD | grep -qx 'handoffs/NEXT-demo.md' \
  && [ -z "$(V m33 status --porcelain | grep -E '^[ADMR]|^.[DM]')" ] \
  && ok "M33 successful --refresh-pulse prints commit: <sha> and HEAD touches the seed" \
  || bad "M33 successful --refresh-pulse prints commit: <sha> and HEAD touches the seed" "rc=$rc $(cat "$TMP/m33.out" "$TMP/m33.err" | tr '\n' '|')"

# M22 detached HEAD, M23 unborn branch
new_vault m22
V m22 checkout -q --detach
mrun m22
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: detached HEAD' \
  && ok "M22 detached HEAD: UNCOMMITTED" || bad "M22 detached HEAD: UNCOMMITTED" "rc=$rc $(flat "$err")"
mkdir -p "$TMP/m23/vault/handoffs"; git -c init.defaultBranch=main init -q "$TMP/m23/vault"; new_repo "$TMP/m23/demo"
mrun m23
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V m23 rev-list --count HEAD)" = 1 ] && [ -z "$(V m23 status --porcelain)" ] \
  && ok "M23 unborn branch: root commit, clean status" \
  || bad "M23 unborn branch: root commit, clean status" "rc=$rc $(flat "$out") $(flat "$err")"

# M24 symlinked handoff dir, subdirectory, nested repo, linked worktree
new_vault m24
ln -s "$TMP/m24/vault/handoffs" "$TMP/m24/link"
MHD="$TMP/m24/link" mrun m24
[ "$rc" -eq 0 ] && [ "$(V m24 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && ok "M24a symlinked handoff dir commits the real path" || bad "M24a symlinked handoff dir commits the real path" "rc=$rc $(flat "$out") $(flat "$err")"
new_vault m25
mkdir -p "$TMP/m25/vault/deep/sub"
MHD="$TMP/m25/vault/deep/sub" mrun m25
[ "$rc" -eq 0 ] && [ "$(V m25 show --name-only --format= HEAD)" = "deep/sub/NEXT-demo.md" ] \
  && ok "M24b subdirectory handoff dir commits its repo-relative path" || bad "M24b subdirectory handoff dir commits its repo-relative path" "rc=$rc $(flat "$out") $(flat "$err")"
mkdir -p "$TMP/m26"; new_repo "$TMP/m26/outer"; mkdir -p "$TMP/m26/outer/vault/handoffs"
git -c init.defaultBranch=main init -q "$TMP/m26/outer/vault"; git -C "$TMP/m26/outer/vault" commit -q --allow-empty -m init; new_repo "$TMP/m26/demo"
outer_before=$(git -C "$TMP/m26/outer" rev-parse HEAD)
MHD="$TMP/m26/outer/vault/handoffs" mrun m26
[ "$rc" -eq 0 ] && [ "$(git -C "$TMP/m26/outer/vault" show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && [ "$(git -C "$TMP/m26/outer" rev-parse HEAD)" = "$outer_before" ] \
  && ok "M24c nested repo: the inner repo gets the commit, the outer is untouched" || bad "M24c nested repo: the inner repo gets the commit, the outer is untouched" "rc=$rc $(flat "$out") $(flat "$err")"
new_vault m27
V m27 worktree add -q -b wt "$TMP/m27/wt"; mkdir -p "$TMP/m27/wt/handoffs"
main_before=$(V m27 rev-parse main)
MHD="$TMP/m27/wt/handoffs" mrun m27
[ "$rc" -eq 0 ] && [ "$(git -C "$TMP/m27/wt" show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] \
  && [ "$(V m27 rev-parse main)" = "$main_before" ] && [ -z "$(git -C "$TMP/m27/wt" status --porcelain)" ] \
  && ok "M24d linked worktree: its own branch advances, main does not" || bad "M24d linked worktree: its own branch advances, main does not" "rc=$rc $(flat "$out") $(flat "$err")"

# M28 the invocation log: only plumbing, never a porcelain add/commit or a network/mutating verb
new_vault m28
mkdir -p "$TMP/m28/handoffs"; put_seed m28 NEXT-demo.md other-session "$LOST"; mv "$TMP/m28/handoffs/NEXT-demo.md" "$TMP/m28/vault/handoffs/NEXT-demo.md"
V m28 add -- handoffs/NEXT-demo.md; V m28 commit -q -m other
FAKE_GIT_LOG="$TMP/m28.log" mrun m28
[ "$rc" -eq 0 ] && [ "$(V m28 show --name-only --format= HEAD | wc -l | tr -d ' ')" -eq 2 ] && [ -s "$TMP/m28.log" ] && grep -q '^commit-tree ' "$TMP/m28.log" && grep -q '^update-ref ' "$TMP/m28.log" \
  && ! grep -Eq '^(push|fetch|pull|reset|stash|checkout|commit|add|restore|rebase|read-tree .*--reset) ' "$TMP/m28.log" \
  && ! grep -Eq '^read-tree .*(-u|--reset)' "$TMP/m28.log" \
  && ok "M28 invocation log: plumbing only, no push/fetch/pull/reset/stash/checkout/commit/add" \
  || bad "M28 invocation log: plumbing only, no push/fetch/pull/reset/stash/checkout/commit/add" "rc=$rc log=$(cut -d' ' -f1 "$TMP/m28.log" | sort -u | tr '\n' ' ')"

# ============================================================ GROUP N — the lock protocol
# Deterministic interleavings come from a Python driver that imports the script and
# injects the OTHER session's action at one exact point (no sleeps, no races to win).
echo; echo "N. index.lock protocol"
DRIVER="$TMP/driver.py"
cat > "$DRIVER" <<'PY'
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("ss", os.environ["SUT"])
ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
mode, V, RG = os.environ["DRV_MODE"], os.environ["DRV_VAULT"], os.environ["REAL_GIT"]
def g(*a, env=None, inp=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run([RG, "-C", V, *a], capture_output=True, text=True, env=e, input=inp)
def move(content=None):
    """Another session moves the branch with plumbing; optionally to a commit holding `content` as the seed."""
    tree = g("rev-parse", "HEAD^{tree}").stdout.strip()
    if content is not None:
        path = os.path.join(V, "handoffs", "NEXT-demo.md")
        open(path, "w").write(content)
        blob = g("hash-object", "-w", "--stdin", inp=content).stdout.strip()
        idx = os.path.join(V, ".git", "drv-index")
        g("read-tree", "HEAD", env={"GIT_INDEX_FILE": idx})
        g("update-index", "--add", "--cacheinfo", "100644,%s,handoffs/NEXT-demo.md" % blob, env={"GIT_INDEX_FILE": idx})
        tree = g("write-tree", env={"GIT_INDEX_FILE": idx}).stdout.strip()
        os.unlink(idx)
    new = g("commit-tree", tree, "-p", "HEAD", "-m", "moved").stdout.strip()
    g("update-ref", "refs/heads/main", new)
state = {"ur": 0, "acq": 0, "sleep": 0}
real_cg, real_acq, real_sleep, real_replace = ss._cg, ss._acquire_index_lock, ss.time.sleep, ss.os.replace
def cg(args, *a, **k):
    if args[0] == "update-ref":
        state["ur"] += 1
        if state["ur"] == 1 and mode in ("plain_between", "newer_seed"):
            move()
    return real_cg(args, *a, **k)
def acq(gitdir):
    state["acq"] += 1
    if mode == "plain_between" and state["acq"] == 2:      # between the lost CAS and the retry: lock is free
        open(os.path.join(V, "other.txt"), "w").write("plain\n")
        g("add", "other.txt"); g("commit", "-q", "-m", "plain")
    if mode == "newer_seed" and state["acq"] == 2:         # B writes AND commits a newer seed, with a plain commit
        open(os.path.join(V, "handoffs", "NEXT-demo.md"), "w").write("seed written by B\n")
        g("add", "handoffs/NEXT-demo.md"); g("commit", "-q", "-m", "moved")
    return real_acq(gitdir)
def sleep(t):
    state["sleep"] += 1
    if mode == "staged_backoff" and state["sleep"] == 1:   # B stages the seed while we wait on the lock
        os.unlink(os.path.join(V, ".git", "index.lock"))
        blob = g("hash-object", "-w", "--stdin", inp="B staged this\n").stdout.strip()
        g("update-index", "--add", "--cacheinfo", "100644,%s,handoffs/NEXT-demo.md" % blob)
    return real_sleep(t)
def replace(src, dst):
    if mode == "publish_fail" and str(src).endswith("index.lock"):
        raise OSError("injected publish failure")
    return real_replace(src, dst)
ss._cg, ss._acquire_index_lock, ss.time.sleep, ss.os.replace = cg, acq, sleep, replace
sys.exit(ss.main(["write"] + sys.argv[1:]))
PY
drun() {                # <case> <mode> [args...] -> $out $err $rc
  local c=$1 m=$2; shift 2
  (cd "$TMP/$c/demo" && DRV_MODE=$m DRV_VAULT="$TMP/$c/vault" SUT="$SUT" CLAUDE_HANDOFF_DIR="$TMP/$c/vault/handoffs" \
     "$PY" "$DRIVER" "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'the next thing (agent Sol)' "$@" \
     >"$TMP/$c.stdout" 2>"$TMP/$c.stderr"); rc=$?
  out=$(cat "$TMP/$c.stdout"); err=$(cat "$TMP/$c.stderr")
}
staged_or_modified() { V "$1" status --porcelain | grep -E '^[ADMRC]|^.[DM]'; }

# N1 (a) a plain commit lands between the lost CAS and the retry: no staged deletion or revert
new_vault n1
drun n1 plain_between
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$(V n1 ls-tree HEAD -- handoffs/NEXT-demo.md | wc -l | tr -d ' ')" -eq 1 ] \
  && [ -n "$(V n1 ls-tree HEAD -- other.txt)" ] && [ -z "$(staged_or_modified n1)" ] \
  && ok "N1 (a) plain commit between CAS loss and retry: seed and the other commit both in HEAD, nothing staged" \
  || bad "N1 (a) plain commit between CAS loss and retry: seed and the other commit both in HEAD, nothing staged" "rc=$rc $(flat "$out") $(flat "$err") $(V n1 status --porcelain | tr '\n' '|')"

# N2 while we hold the lock another `git add` fails and leaves the index alone
new_vault n2
echo o > "$TMP/n2/vault/other.txt"
FAKE_GIT_LOG="$TMP/n2.log" FAKE_GIT_PRE_SUB=update-ref \
  FAKE_GIT_PRE_CMD="\"\$REAL_GIT\" -C '$TMP/n2/vault' add other.txt 2>'$TMP/n2.adderr'; echo \$? > '$TMP/n2.addrc'" mrun n2
[ "$rc" -eq 0 ] && [ "$(cat "$TMP/n2.addrc")" -ne 0 ] && grep -q 'index.lock' "$TMP/n2.adderr" \
  && [ -z "$(V n2 diff --cached --name-only | grep other.txt)" ] \
  && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' && [ ! -e "$TMP/n2/vault/.git/index.lock" ] \
  && ok "N2 while we hold index.lock a concurrent git add fails, the index is untouched, the lock is gone after" \
  || bad "N2 while we hold index.lock a concurrent git add fails, the index is untouched, the lock is gone after" "rc=$rc addrc=$(cat "$TMP/n2.addrc" 2>/dev/null) $(flat "$out") $(flat "$err")"

# N3 (b) B stages the seed while we wait for the lock: UNCOMMITTED and B's entry is intact
new_vault n3
: > "$TMP/n3/vault/.git/index.lock"
blobB=$(printf 'B staged this\n' | git -C "$TMP/n3/vault" hash-object -w --stdin)
head_before=$(V n3 rev-parse HEAD)
CLAUDE_SEED_LOCK_WAIT=10 drun n3 staged_backoff
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: handoffs/NEXT-demo.md has separately staged changes' \
  && [ "$(V n3 ls-files -s -- handoffs/NEXT-demo.md | awk '{print $2}')" = "$blobB" ] && [ "$(V n3 rev-parse HEAD)" = "$head_before" ] \
  && [ ! -e "$TMP/n3/vault/.git/index.lock" ] \
  && ok "N3 (b) staged by B during our backoff: UNCOMMITTED, B's entry and HEAD intact, lock released" \
  || bad "N3 (b) staged by B during our backoff: UNCOMMITTED, B's entry and HEAD intact, lock released" "rc=$rc $(flat "$out") $(flat "$err")"

# N4 (c) B commits a newer seed before our retry: UNCOMMITTED, HEAD is B's, the worktree is B's
new_vault n4
drun n4 newer_seed
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: seed changed' \
  && [ "$(V n4 log -1 --format=%s)" = moved ] && [ "$(V n4 show HEAD:handoffs/NEXT-demo.md)" = "seed written by B" ] \
  && [ "$(cat "$TMP/n4/vault/handoffs/NEXT-demo.md")" = "seed written by B" ] && [ -z "$(staged_or_modified n4)" ] \
  && ok "N4 (c) newer seed committed by B: UNCOMMITTED, HEAD and worktree are B's, nothing stale committed" \
  || bad "N4 (c) newer seed committed by B: UNCOMMITTED, HEAD and worktree are B's, nothing stale committed" "rc=$rc $(flat "$out") $(flat "$err") $(V n4 status --porcelain | tr '\n' '|')"

# N5 publish failure after the CAS: loud message with repair commands, exit 0, lock removed
new_vault n5
drun n5 publish_fail
[ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: committed [0-9a-f]\{7,\} but shared index not refreshed' \
  && printf '%s' "$err" | grep -q 'update-index --add --cacheinfo 100644,' \
  && [ "$(V n5 show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] && [ ! -e "$TMP/n5/vault/.git/index.lock" ] \
  && ok "N5 publish failure after CAS: loud UNCOMMITTED with repair commands, exit 0, lock removed" \
  || bad "N5 publish failure after CAS: loud UNCOMMITTED with repair commands, exit 0, lock removed" "rc=$rc $(flat "$out") $(flat "$err")"

# N6 split index + index v4 + untracked cache: committed, readable, clean, and a second write works
new_vault n6
V n6 config core.splitIndex true; V n6 config index.version 4; V n6 config core.untrackedCache true
V n6 update-index --split-index; echo more > "$TMP/n6/vault/more.txt"; V n6 add -- more.txt; V n6 commit -q -m more
mrun n6
first_rc=$rc; first_out=$out
(cd "$TMP/n6/demo" && CLAUDE_HANDOFF_DIR="$TMP/n6/vault/handoffs" "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" \
   --now 2026-08-12T00:00:00Z --picks-up-at 'the next thing (agent Sol)' >"$TMP/n6.2.out" 2>"$TMP/n6.2.err"); rc2=$?
[ "$first_rc" -eq 0 ] && printf '%s' "$first_out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
  && [ "$rc2" -eq 0 ] && grep -Eq '^commit: [0-9a-f]{7,}$' "$TMP/n6.2.out" \
  && [ "$(V n6 rev-list --count HEAD)" -eq 4 ] && V n6 status --porcelain >/dev/null && [ -z "$(staged_or_modified n6)" ] \
  && ok "N6 split index, index v4, untracked cache: two writes commit and the index stays readable and clean" \
  || bad "N6 split index, index v4, untracked cache: two writes commit and the index stays readable and clean" "rc=$first_rc/$rc2 $(flat "$first_out") $(cat "$TMP/n6.2.err" | tr '\n' '|') $(V n6 status --porcelain | tr '\n' '|')"

# N7 organic: 8 parallel writers + a looping `git add; git commit` session, 3 rounds
new_vault n7
for i in 1 2 3 4 5 6 7 8; do new_repo "$TMP/n7/w$i"; done
echo 0 > "$TMP/n7/vault/other.txt"; V n7 add -- other.txt; V n7 commit -q -m other
( while [ ! -e "$TMP/n7.stop" ]; do echo x >> "$TMP/n7/vault/other.txt"; \
    git -C "$TMP/n7/vault" add -- other.txt 2>/dev/null && git -C "$TMP/n7/vault" commit -q -m loop 2>/dev/null; done ) &
looper=$!
committed=0; allok=1; detail=
for r in 1 2 3; do
  pids=
  for i in 1 2 3 4 5 6 7 8; do
    ( cd "$TMP/n7/w$i" && CLAUDE_HANDOFF_DIR="$TMP/n7/vault/handoffs" "$PY" "$SUT" write "${FILLED[@]}" \
        --session "$MINE" --now "2026-08-1${r}T00:00:00Z" --picks-up-at 'x (agent Sol)' \
        >"$TMP/n7.$r.$i.out" 2>"$TMP/n7.$r.$i.err"; echo $? > "$TMP/n7.$r.$i.rc" ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  for i in 1 2 3 4 5 6 7 8; do
    [ "$(cat "$TMP/n7.$r.$i.rc")" -eq 0 ] || { allok=0; detail="$detail rc($r,$i)"; }
    if grep -Eq '^commit: [0-9a-f]{7,}$' "$TMP/n7.$r.$i.out"; then
      committed=$((committed+1))
      V n7 show "HEAD:handoffs/NEXT-w$i.md" > "$TMP/n7.blob" 2>/dev/null
      cmp -s "$TMP/n7.blob" "$TMP/n7/vault/handoffs/NEXT-w$i.md" || { allok=0; detail="$detail stale($r,$i)"; }
    else
      grep -q '^UNCOMMITTED:' "$TMP/n7.$r.$i.err" || { allok=0; detail="$detail silent($r,$i)"; }
    fi
  done
done
touch "$TMP/n7.stop"; wait "$looper"
deleted=$(V n7 log --diff-filter=D --name-only --format= -- handoffs | wc -l | tr -d ' ')
stagedseed=$(V n7 status --porcelain | grep -E '^[ADMRC] +handoffs' | wc -l | tr -d ' ')
[ "$allok" -eq 1 ] && [ "$deleted" -eq 0 ] && [ "$stagedseed" -eq 0 ] && [ "$committed" -ge 18 ] \
  && ok "N7 8 writers x 3 rounds beside a commit loop: $committed/24 committed, none stale, none deleted or left staged" \
  || bad "N7 8 writers x 3 rounds beside a commit loop: $committed/24 committed, none stale, none deleted or left staged" "allok=$allok$detail deleted=$deleted staged=$stagedseed committed=$committed"

# ============================================================ GROUP P — signals and modes
echo; echo "P. signals during the locked transaction; archive modes"
# srun <case> <signal> <pre|during> -> $rc $out $err. Starts the write in the background (exec, so $! is
# the python process), waits for a marker that proves where it is, sends the signal, then WAITS for it.
srun() {
  local c=$1 sig=$2 where=$3
  local o="$TMP/$c.stdout" e="$TMP/$c.stderr" marker="$TMP/$c.marker"
  rm -f "$marker"
  if [ "$where" = pre ]; then          # parked inside the lock, before the CAS: commit-tree sleeps
    ( cd "$TMP/$c/demo" && exec env PATH="$FAKEBIN:$PATH" FAKE_GIT_LOG="$TMP/$c.log" FAKE_GIT_PRE_SUB=commit-tree \
        FAKE_GIT_PRE_CMD=": > '$marker'" FAKE_GIT_SLEEP=commit-tree CLAUDE_HANDOFF_DIR="$TMP/$c/vault/handoffs" \
        "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' >"$o" 2>"$e" ) &
  else                                  # parked inside update-ref: a reference-transaction hook sleeps
    printf '#!/bin/sh\n[ "$1" = prepared ] && { : > "%s"; sleep 2; }\nexit 0\n' "$marker" > "$TMP/$c/vault/.git/hooks/reference-transaction"
    chmod +x "$TMP/$c/vault/.git/hooks/reference-transaction"
    ( cd "$TMP/$c/demo" && exec env CLAUDE_HANDOFF_DIR="$TMP/$c/vault/handoffs" \
        "$PY" "$SUT" write "${FILLED[@]}" --session "$MINE" --now "$STAMP" --picks-up-at 'x (agent Sol)' >"$o" 2>"$e" ) &
  fi
  local pid=$! n=0
  while [ ! -e "$marker" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done
  kill -"$sig" "$pid" 2>/dev/null
  wait "$pid"; rc=$?
  out=$(cat "$o"); err=$(cat "$e")
}
clean_after() {   # no lock, no index copy, nothing staged or modified
  [ ! -e "$TMP/$1/vault/.git/index.lock" ] && ! ls "$TMP/$1/vault/.git"/index.seed.* >/dev/null 2>&1 \
    && [ -z "$(V "$1" status --porcelain | grep -E '^[ADMRC]|^.[DM]')" ]
}
for pair in "TERM:143" "INT:130"; do
  sig=${pair%%:*}; code=${pair##*:}
  new_vault p_pre_$sig
  head_before=$(V p_pre_$sig rev-parse HEAD)
  srun p_pre_$sig "$sig" pre
  [ "$rc" -eq "$code" ] && printf '%s' "$err" | grep -q '^UNCOMMITTED: interrupted before commit' \
    && ! printf '%s' "$err" | grep -q Traceback && [ "$(V p_pre_$sig rev-parse HEAD)" = "$head_before" ] \
    && clean_after p_pre_$sig && [ -f "$TMP/p_pre_$sig/vault/handoffs/NEXT-demo.md" ] \
    && ok "P SIG$sig before the CAS: exit $code, UNCOMMITTED, no commit, no lock, no copy, status clean" \
    || bad "P SIG$sig before the CAS: exit $code, UNCOMMITTED, no commit, no lock, no copy, status clean" "rc=$rc $(flat "$out") $(flat "$err") $(V p_pre_$sig status --porcelain | tr '\n' '|')"
  new_vault p_dur_$sig
  srun p_dur_$sig "$sig" during
  [ "$rc" -eq "$code" ] && ! printf '%s' "$err" | grep -q Traceback \
    && [ "$(V p_dur_$sig show --name-only --format= HEAD)" = "handoffs/NEXT-demo.md" ] && clean_after p_dur_$sig \
    && printf '%s' "$out" | grep -Eq '^commit: [0-9a-f]{7,}$' \
    && ok "P SIG$sig during update-ref: exit $code, the commit lands AND the index is published, no lock, status clean" \
    || bad "P SIG$sig during update-ref: exit $code, the commit lands AND the index is published, no lock, status clean" "rc=$rc $(flat "$out") $(flat "$err") $(V p_dur_$sig status --porcelain | tr '\n' '|')"
done

# P9 an executable incumbent's archive is committed at its own mode, so status stays clean
new_vault p9
mkdir -p "$TMP/p9/handoffs"; put_seed p9 NEXT-demo.md other-session "$LOST"
cp "$TMP/p9/handoffs/NEXT-demo.md" "$TMP/p9/vault/handoffs/NEXT-demo.md"; chmod +x "$TMP/p9/vault/handoffs/NEXT-demo.md"
V p9 add -- handoffs/NEXT-demo.md; V p9 commit -q -m exec-incumbent
mrun p9
arch=$(ls "$TMP/p9/vault/handoffs" | grep -E "$ARCHIVE_RE" | head -1)
[ "$rc" -eq 0 ] && [ -n "$arch" ] && [ "$(V p9 ls-tree HEAD -- "handoffs/$arch" | cut -c1-6)" = 100755 ] \
  && [ -z "$(V p9 status --porcelain)" ] \
  && ok "P9 executable incumbent: its archive is committed 100755 and status is clean" \
  || bad "P9 executable incumbent: its archive is committed 100755 and status is clean" "rc=$rc arch=$arch $(flat "$out") $(flat "$err") $(V p9 status --porcelain | tr '\n' '|')"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
