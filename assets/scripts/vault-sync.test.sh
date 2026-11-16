#!/usr/bin/env bash
# Regression tests for assets/scripts/vault-sync.py. Hermetic: a temp bare repo is the remote, a temp
# clone is the vault, `gh` is a fake, HOME and git config are temp, nothing touches the network.
# Credential-shaped fixtures are assembled at run time so this file holds no token-shaped literal.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/vault-sync.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
REAL_GIT=$(command -v git) || { echo "git not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vault-sync-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/bin-nogh"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
"$REAL_GIT" config --global user.name "Test Author"
"$REAL_GIT" config --global user.email "author@example.test"
"$REAL_GIT" config --global init.defaultBranch main
"$REAL_GIT" config --global commit.gpgsign false
export GITLOG="$TMP/git.log"
# git wrapper: logs every invocation, then runs the real git
for d in bin bin-nogh; do
  cat >"$TMP/$d/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GITLOG"
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$TMP/$d/git"
done
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
[ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo "gh: boom" >&2; exit 1; }
echo "${FAKE_GH_VIS:-PRIVATE}"
EOF
chmod +x "$TMP/bin/gh"
G() { "$REAL_GIT" "$@"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { # name, condition-exit, detail
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# fresh case: $R bare remote, $V vault clone with one pushed commit
n=0
newcase() {
  n=$((n+1)); C="$TMP/case$n"; R="$C/remote.git"; V="$C/vault"; mkdir -p "$C"
  G init -q --bare "$R"
  G clone -q "$R" "$V" 2>/dev/null
  echo "start" >"$V/README.md"
  G -C "$V" add -- README.md; G -C "$V" commit -q -m "init"
  G -C "$V" push -q -u origin main 2>/dev/null
  : >"$GITLOG"
}
commit_file() { # name content [subject]
  mkdir -p "$V/$(dirname "$1")"; printf '%s\n' "$2" >"$V/$1"
  G -C "$V" add -- "$1"; G -C "$V" commit -q -m "${3:-add $1}"
}
refs() { G -C "$R" for-each-ref --format='%(refname) %(objectname)'; }
vs() { # run the SUT against $V with the fake gh; sets OUT and RC
  OUT=$(env VAULT_SYNC_TEST=1 VAULT_SYNC_TEST_REPO=test/vault FAKE_GH_VIS="${VIS:-PRIVATE}" \
        PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" "$@" 2>&1); RC=$?
}
has() { grep -qF -- "$1" <<<"$OUT"; }
refuses() { # name, extra args: expects exit 1, unchanged remote, no secret leak (global SECRET)
  local name=$1; shift
  local before; before=$(refs)
  vs push "$@"
  local after; after=$(refs)
  if [ "$RC" = 1 ] && [ "$before" = "$after" ] && has "REFUSED"; then ok "$name"; else bad "$name" "rc=$RC out=$OUT"; fi
  if [ -n "${SECRET:-}" ] && has "$SECRET"; then bad "$name: output leaked the value" "$OUT"; fi
}

echo "vault-sync.test.sh"

# ---- status ---------------------------------------------------------------
newcase
vs status
{ [ $RC = 0 ] && has "ahead 0 behind 0" && has "dirty: 0 modified, 0 untracked"; } && ok "status clean" || bad "status clean" "rc=$RC $OUT"

commit_file a.md "one" "first local"; commit_file b.md "two" "second local"
echo "x" >>"$V/README.md"; echo y >"$V/new.md"
vs status
{ [ $RC = 0 ] && has "ahead 2 behind 0" && has "second local" && has "first local" && has "dirty: 1 modified, 1 untracked"; } \
  && ok "status ahead + dirty + list" || bad "status ahead" "rc=$RC $OUT"
G -C "$V" checkout -q -- README.md; rm "$V/new.md"
: >"$GITLOG"; vs status
grep -qE ' fetch( |$)|^fetch' "$GITLOG" && bad "status never fetches" "$(cat "$GITLOG")" || ok "status never fetches"
grep -qE '(^| )push( |$)' "$GITLOG" && bad "status never pushes" || ok "status never pushes"

newcase
O="$C/other"; G clone -q "$R" "$O" 2>/dev/null
echo "remote" >"$O/r.md"; G -C "$O" add -- r.md; G -C "$O" commit -q -m "remote side"; G -C "$O" push -q origin main 2>/dev/null
G -C "$V" fetch -q origin
vs status
{ [ $RC = 0 ] && has "ahead 0 behind 1"; } && ok "status behind" || bad "status behind" "$OUT"
commit_file l.md "local" "local side"
vs status
{ [ $RC = 0 ] && has "ahead 1 behind 1"; } && ok "status diverged" || bad "status diverged" "$OUT"

newcase; G -C "$V" branch -q --unset-upstream
vs status; { [ $RC = 2 ] && has "no upstream"; } && ok "status no upstream -> 2" || bad "status no upstream" "rc=$RC $OUT"
newcase; G -C "$V" checkout -q --detach
vs status; { [ $RC = 2 ] && has "detached"; } && ok "status detached -> 2" || bad "status detached" "rc=$RC $OUT"
mkdir "$TMP/notrepo"; V="$TMP/notrepo"; vs status
[ $RC = 2 ] && ok "status non-repo -> 2" || bad "status non-repo" "rc=$RC $OUT"
V="$TMP/notrepo"; vs push; [ $RC = 2 ] && ok "push non-repo -> 2" || bad "push non-repo" "rc=$RC $OUT"

# vault resolution: $CLAUDE_VAULT_DIR
newcase
OUT=$(env CLAUDE_VAULT_DIR="$V" "$PY" -B "$SUT" status 2>&1); RC=$?
{ [ $RC = 0 ] && has "ahead 0 behind 0"; } && ok "CLAUDE_VAULT_DIR is honoured" || bad "CLAUDE_VAULT_DIR" "rc=$RC $OUT"

# ---- push: happy path ------------------------------------------------------
newcase; commit_file n1.md "hello there" "note one"; commit_file n2.md "more text" "note two"
vs push --dry-run
{ [ $RC = 0 ] && has "dry-run: would push" && has "scope: 2 commits, 2 paths, 2 files added"; } && ok "dry-run reports" || bad "dry-run" "rc=$RC $OUT"
[ "$(G -C "$R" rev-parse main)" != "$(G -C "$V" rev-parse HEAD)" ] && ok "dry-run pushes nothing" || bad "dry-run pushed"
old=$(G -C "$V" rev-parse --short=8 origin/main)
vs push
{ [ $RC = 0 ] && has "pushed: ${old}..$(G -C "$V" rev-parse --short=8 HEAD)"; } && ok "clean fast-forward pushes" || bad "push" "rc=$RC $OUT"
[ "$(G -C "$R" rev-parse main)" = "$(G -C "$V" rev-parse HEAD)" ] && ok "remote tip equals vault HEAD" || bad "remote tip"
vs push; { [ $RC = 0 ] && has "nothing to push"; } && ok "nothing to push exits 0" || bad "nothing to push" "$OUT"
! grep -E -- '(^| )(--force[^ ]*|-f|\+[^ ]+)( |$)' "$GITLOG" >/dev/null && ok "no force flag or + refspec in any git call" || bad "force seen" "$(cat "$GITLOG")"
grep -qE '^push origin HEAD:refs/heads/main$' "$GITLOG" && ok "push uses HEAD:refs/heads/<branch>" || bad "push argv" "$(grep push "$GITLOG")"
grep -qE '(^| )(pull|merge|rebase|reset)( |$)' "$GITLOG" && bad "script ran pull/merge/rebase/reset" || ok "never pulls, merges, rebases or resets"
grep -E '(^| )fetch( |$)' "$GITLOG" | grep -q -- '--no-tags' && ok "fetch is the single branch, no tags" || bad "fetch argv" "$(grep fetch "$GITLOG")"

# benign text that resembles keywords must not trip the scan
newcase; commit_file n.md "token: usage-checkpoint
the risk-assessment-of-things-in-general is fine
password: changeme-please" "benign"
vs push; { [ $RC = 0 ]; } && ok "benign keyword-like text passes" || bad "benign text" "$OUT"

# ---- push: refusals ---------------------------------------------------------
newcase; O="$C/other"; G clone -q "$R" "$O" 2>/dev/null
echo r >"$O/r.md"; G -C "$O" add -- r.md; G -C "$O" commit -q -m remote; G -C "$O" push -q origin main 2>/dev/null
SECRET=; refuses "refuses when behind"
has "behind" && ok "behind refusal names the state" || bad "behind msg" "$OUT"
commit_file l.md "local" "local"
refuses "refuses when diverged"
{ has "diverged" && has "ahead 1 behind 1"; } && ok "diverged refusal prints counts" || bad "diverged msg" "$OUT"
grep -qE '(^| )(pull|merge|rebase|reset)( |$)' "$GITLOG" && bad "reconciled by itself" || ok "refusal ran no reconcile command"

newcase; commit_file n.md "hello" "n"
VIS=PUBLIC refuses "refuses on a PUBLIC repo"; has "PUBLIC" && ok "PUBLIC refusal names visibility" || bad "public msg" "$OUT"
VIS=INTERNAL refuses "refuses on INTERNAL"
n0=$n
OUT=$(env VAULT_SYNC_TEST=1 VAULT_SYNC_TEST_REPO=test/vault FAKE_GH_FAIL=1 PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
{ [ $RC = 1 ] && has "REFUSED"; } && ok "refuses when gh fails" || bad "gh fails" "rc=$RC $OUT"
before=$(refs)
OUT=$(env VAULT_SYNC_TEST=1 VAULT_SYNC_TEST_REPO=test/vault PATH="$TMP/bin-nogh" "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
{ [ $RC = 1 ] && has "gh is not available" && [ "$before" = "$(refs)" ]; } && ok "refuses when gh is missing" || bad "gh missing" "rc=$RC $OUT"
# a local-path remote is not a GitHub repo: privacy cannot be verified, so refuse (no test overrides)
OUT=$(env PATH="$TMP/bin:/usr/bin:/bin" FAKE_GH_VIS=PRIVATE "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
{ [ $RC = 1 ] && has "privacy cannot be verified" && [ "$before" = "$(refs)" ]; } && ok "refuses an unidentifiable remote" || bad "unidentifiable" "rc=$RC $OUT"
OUT=$(env PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push --skip-visibility-check 2>&1); RC=$?
{ [ $RC = 2 ] && [ "$before" = "$(refs)" ]; } && ok "--skip-visibility-check needs VAULT_SYNC_TEST=1" || bad "skip guard" "rc=$RC $OUT"
vs push --skip-visibility-check
{ [ $RC = 0 ] && has "SKIPPED"; } && ok "--skip-visibility-check works under the test guard" || bad "skip flag" "rc=$RC $OUT"

"$PY" -B - "$SUT" <<'PYEOF' && ok "remote URL parsing" || bad "remote URL parsing"
import importlib.util, sys
s = importlib.util.spec_from_file_location("vs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
want = "o/n"
for u in ("https://github.com/o/n.git", "https://github.com/o/n", "git@github.com:o/n.git",
          "ssh://git@github.com/o/n.git", "https://user@github.com/o/n.git/"):
    assert m.parse_slug(u) == want, u
for u in ("/tmp/x.git", "https://example.com/o/n.git", "git@gitlab.com:o/n.git", "https://github.com/o"):
    assert m.parse_slug(u) is None, u
PYEOF

# ---- push: scope check, credential shapes (built at run time) --------------
AL="Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv"
cred() { # name, value-builder output
  newcase
  SECRET="$2"
  commit_file notes.md "line one
carrying $2 inside
line three" "add note"
  refuses "refuses credential: $1"
  { has "notes.md:2" && has "[" && ! has "$2"; } && ok "refusal for $1 names path and line only" || bad "$1 location" "$OUT"
}
cred "github ghp"  "gh""p_${AL}"
cred "github gho"  "gh""o_${AL}"
cred "github pat"  "github""_pat_${AL}${AL}"
cred "sk key"      "s""k-${AL}"
cred "stripe live" "s""k_live_${AL}"
cred "stripe test" "s""k_test_${AL}"
cred "slack"       "xo""xb-12345678-${AL}"
cred "aws"         "AK""IA$(printf 'ABCD1234EFGH5678')"
cred "pem"         "-----BEGIN RSA ""PRIVATE KEY-----"
cred "jwt"         "ey""JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
cred "password assignment" "password=""Hunter2Hunter2"
cred "api key assignment"  "api_key: ""x9y8z7w6v5u4"
cred "token assignment"    "token = ""AbCdEfGhIjKl"
cred "bearer"      "Bearer ""${AL}${AL}"

# ---- push: sensitive paths and size ----------------------------------------
SECRET=
for p in .env .env.local conf/server.pem conf/x.key id_rsa id_ed25519.pub my-credentials.json a.p12 login.keychain-db; do
  newcase; commit_file "$p" "harmless text" "add $p"
  refuses "refuses sensitive path $p"
  has "$p" && ok "refusal names $p" || bad "names $p" "$OUT"
done

newcase; head -c 53000000 /dev/zero >"$V/big.bin"; G -C "$V" add -- big.bin; G -C "$V" commit -q -m big
refuses "refuses a blob over 50 MB"; has "big.bin" && ok "size refusal names the path" || bad "size msg" "$OUT"

# a secret hidden in an earlier commit of the range, removed in a later one, is still caught
newcase; SECRET="gh""p_${AL}"
commit_file t.md "key $SECRET" "oops"; commit_file t.md "clean" "fix"
refuses "scans every commit in the range, not only the tip"

# ---- allow-path escape ------------------------------------------------------
newcase; commit_file .env "harmless text" "add env"
vs push --allow-path .env
{ [ $RC = 0 ] && has "allow-path in effect: .env" && has "allowed (--allow-path)" && has "pushed:"; } && ok "--allow-path pushes and echoes its use" || bad "allow-path" "rc=$RC $OUT"
newcase; commit_file .env "harmless text" "add env"; commit_file other.pem "x" "pem"
refuses "--allow-path is literal, not a pattern" --allow-path '.e*'
refuses "--allow-path of one path does not cover another" --allow-path .env

# ---- hostile git environment ------------------------------------------------
newcase; commit_file n.md "hello" "n"
G init -q --bare "$C/decoy.git"; dbefore=$(G -C "$C/decoy.git" for-each-ref)
OUT=$(env GIT_DIR="$C/decoy.git" GIT_WORK_TREE="$C" GIT_INDEX_FILE="$C/idx" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/nonexistent \
      VAULT_SYNC_TEST=1 VAULT_SYNC_TEST_REPO=test/vault PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
{ [ $RC = 0 ] && [ "$(G -C "$R" rev-parse main)" = "$(G -C "$V" rev-parse HEAD)" ] && [ "$dbefore" = "$(G -C "$C/decoy.git" for-each-ref)" ]; } \
  && ok "hostile GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE do not redirect the push" || bad "hostile env" "rc=$RC $OUT"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
