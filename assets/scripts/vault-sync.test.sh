#!/usr/bin/env bash
# Regression tests for assets/scripts/vault-sync.py. Hermetic: a temp bare repo is the remote, a temp
# clone is the vault, `gh` is a fake on PATH, HOME is temp, nothing touches the network.
#
# The vault's remote URL is a github.com HTTPS URL, as production requires. The git wrapper below
# (outside the script) rewrites that literal URL to the local bare repo for fetch/push/ls-remote, so
# the script is exercised with no test seam in it. The wrapper also logs every invocation and the GIT_*
# environment it received, and can inject faults.
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
GITLOG="$TMP/git.log"; ENVLOG="$TMP/git.env"; GHLOG="$HOME/gh.log"
export GITLOG ENVLOG
GH="https://github.com/test-owner/vault.git"

for d in bin bin-nogh; do
  cat >"$TMP/$d/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GITLOG"
{ env | grep '^GIT_'; echo ---; } >>"$ENVLOG"
args=()
for a in "\$@"; do args+=("\${a//\$WRAP_FROM/\$WRAP_TO}"); done
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
case " \$* " in
  *" cat-file --batch-check "*)
    [ "\${WRAP_BC:-}" = fail ] && exit 1
    [ "\${WRAP_BC:-}" = short ] && { echo "0000000000000000000000000000000000000000 missing"; exit 0; } ;;
  *" ls-remote "*)
    [ -n "\${WRAP_LIE:-}" ] && { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'; exit 0; } ;;
esac
"$REAL_GIT" "\${args[@]}"; rc=\$?
case " \$* " in *" fetch "*) [ -n "\${WRAP_AFTER_FETCH:-}" ] && bash "\$WRAP_AFTER_FETCH" ;; esac
exit \$rc
EOF
  chmod +x "$TMP/$d/git"
done
cat >"$TMP/bin/gh" <<EOF
#!/bin/bash
{ echo "ARGS: \$*"; env | grep -E '^(GH_|GITHUB_)'; echo ---; } >>"$GHLOG"
[ -e "$TMP/gh.fail" ] && exit 1
case "\$*" in *public*) echo public; exit 0;; esac
cat "$TMP/gh.vis" 2>/dev/null || echo private
EOF
chmod +x "$TMP/bin/gh"
G() { "$REAL_GIT" "$@"; }
setvis() { echo "$1" >"$TMP/gh.vis"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

n=0
newcase() {
  n=$((n+1)); C="$TMP/case$n"; R="$C/remote.git"; V="$C/vault"; mkdir -p "$C"
  G init -q --bare "$R"
  G clone -q "$R" "$V" 2>/dev/null
  echo "start" >"$V/README.md"
  G -C "$V" add -- README.md; G -C "$V" commit -q -m "init"
  G -C "$V" push -q -u origin main 2>/dev/null
  G -C "$V" remote set-url origin "$GH"
  rm -f "$TMP/gh.fail" "$TMP/gh.vis"; : >"$GITLOG"; : >"$ENVLOG"; : >"$GHLOG"
  unset WRAP_BC WRAP_LIE WRAP_AFTER_FETCH SECRET
}
commit_file() { # name content [subject]
  mkdir -p "$V/$(dirname "$1")"; printf '%s\n' "$2" >"$V/$1"
  G -C "$V" add -- "$1"; G -C "$V" commit -q -m "${3:-add $1}"
}
refs() { G -C "$R" for-each-ref --format='%(refname) %(objectname)'; }
remote_main() { G -C "$R" rev-parse main; }
vault_head() { G -C "$V" rev-parse HEAD; }
vs() { # sets OUT and RC; extra env via XENV array-free: caller exports before
  OUT=$(env WRAP_FROM="${WFROM:-$GH}" WRAP_TO="$R" PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" "$@" 2>&1); RC=$?
}
has() { grep -qF -- "$1" <<<"$OUT"; }
refuses() { # name, args: exit 1, remote unchanged, no secret leak (SECRET)
  local name=$1; shift
  local before; before=$(refs)
  vs push "$@"
  if [ "$RC" = 1 ] && [ "$before" = "$(refs)" ] && has "REFUSED"; then ok "$name"; else bad "$name" "rc=$RC out=$OUT"; fi
  if [ -n "${SECRET:-}" ] && has "$SECRET"; then bad "$name: output leaked the value" "$OUT"; fi
  if grep -qE '(^| )push( |$)' "$GITLOG"; then bad "$name: a push was attempted" "$(grep push "$GITLOG")"; fi
}

echo "vault-sync.test.sh"

# ---- status ---------------------------------------------------------------
newcase
vs status
{ [ $RC = 0 ] && has "ahead 0 behind 0" && has "dirty: 0 modified, 0 untracked"; } && ok "status clean" || bad "status clean" "rc=$RC $OUT"
commit_file a.md "one" "SUBJECTMARK first"; commit_file b.md "two" "SUBJECTMARK second"
echo "x" >>"$V/README.md"; echo y >"$V/new.md"
vs status
oids=$(grep -cE '^  [0-9a-f]{8}$' <<<"$OUT")
{ [ $RC = 0 ] && has "ahead 2 behind 0" && [ "$oids" = 2 ] && ! has SUBJECTMARK && has "dirty: 1 modified, 1 untracked"; } \
  && ok "status ahead lists short oids only, no subjects, dirty counts" || bad "status ahead" "rc=$RC $OUT"
G -C "$V" checkout -q -- README.md; rm "$V/new.md"
: >"$GITLOG"; vs status
grep -qE '(^| )(fetch|push)( |$)' "$GITLOG" && bad "status never fetches or pushes" "$(cat "$GITLOG")" || ok "status never fetches or pushes"
grep -q -- '--no-optional-locks' "$GITLOG" && ok "status runs with --no-optional-locks" || bad "optional locks"

newcase
O="$C/other"; G clone -q "$R" "$O" 2>/dev/null
echo "remote" >"$O/r.md"; G -C "$O" add -- r.md; G -C "$O" commit -q -m "remote side"; G -C "$O" push -q origin main 2>/dev/null
G -C "$V" fetch -q "$R" +refs/heads/main:refs/remotes/origin/main
vs status; { [ $RC = 0 ] && has "ahead 0 behind 1"; } && ok "status behind" || bad "status behind" "$OUT"
commit_file l.md "local" "local side"
vs status; { [ $RC = 0 ] && has "ahead 1 behind 1"; } && ok "status diverged" || bad "status diverged" "$OUT"

newcase; G -C "$V" branch -q --unset-upstream
vs status; { [ $RC = 2 ] && has "no upstream"; } && ok "status no upstream -> 2" || bad "status no upstream" "rc=$RC $OUT"
newcase; G -C "$V" checkout -q --detach
vs status; { [ $RC = 2 ] && has "detached"; } && ok "status detached -> 2" || bad "status detached" "rc=$RC $OUT"
mkdir "$TMP/notrepo"; SAVE=$V; V="$TMP/notrepo"; vs status; r1=$RC; vs push; r2=$RC; V=$SAVE
{ [ $r1 = 2 ] && [ $r2 = 2 ]; } && ok "non-repo -> 2 for status and push" || bad "non-repo" "$r1 $r2"

# finding 16: the upstream is resolved with @{u}; a differently named local branch maps to the remote branch
newcase; G -C "$V" checkout -q -b work --track origin/main 2>/dev/null
commit_file w.md "work note" "work"
vs status; { [ $RC = 0 ] && has "branch: work -> origin/main" && has "ahead 1 behind 0"; } && ok "status maps @{u} for a renamed local branch" || bad "@{u} status" "$OUT"
vs push
{ [ $RC = 0 ] && [ "$(remote_main)" = "$(vault_head)" ]; } && ok "push of a renamed local branch updates the upstream branch" || bad "@{u} push" "rc=$RC $OUT"

# finding 16: a damaged index makes status fail instead of reporting a clean tree
newcase; printf 'garbage garbage' >"$V/.git/index"
vs status; { [ $RC = 2 ] && has "ERROR"; } && ok "status fails (2) on a corrupt index" || bad "corrupt index" "rc=$RC $OUT"

newcase
OUT=$(env CLAUDE_VAULT_DIR="$V" PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" status 2>&1); RC=$?
{ [ $RC = 0 ] && has "ahead 0 behind 0"; } && ok "CLAUDE_VAULT_DIR is honoured" || bad "CLAUDE_VAULT_DIR" "rc=$RC $OUT"

# ---- push: happy path, pinning, argv and refs -------------------------------
newcase; commit_file n1.md "hello there" "note one"; commit_file n2.md "more text" "note two"
vs push --dry-run
{ [ $RC = 0 ] && has "dry-run: would push" && has "scope: 2 commits, 2 paths, 2 files added"; } && ok "dry-run reports" || bad "dry-run" "rc=$RC $OUT"
[ "$(remote_main)" != "$(vault_head)" ] && ok "dry-run pushes nothing" || bad "dry-run pushed"
[ -z "$(G -C "$V" for-each-ref refs/vault-sync)" ] && ok "private base ref is deleted after a dry-run" || bad "base ref left behind"
HEAD0=$(vault_head); old=$(G -C "$V" rev-parse --short=8 origin/main)
: >"$GITLOG"; vs push
{ [ $RC = 0 ] && has "pushed: ${old}..$(G -C "$V" rev-parse --short=8 HEAD)"; } && ok "clean fast-forward pushes" || bad "push" "rc=$RC $OUT"
[ "$(remote_main)" = "$HEAD0" ] && ok "remote tip equals the pinned HEAD" || bad "remote tip"
[ -z "$(G -C "$V" for-each-ref refs/vault-sync)" ] && ok "private base ref is deleted after a push" || bad "base ref left behind"
pl=$(grep -E '(^| )push( |$)' "$GITLOG")
[[ "$pl" == *"--no-verify"*"--no-follow-tags"*"--recurse-submodules=no $GH $HEAD0:refs/heads/main" ]] \
  && ok "push targets the literal verified URL and the pinned oid" || bad "push argv" "$pl"
! grep -E '(^| )push( |$)' "$GITLOG" | grep -E -- '(^| )(--force[^ ]*|-f|\+[^ ]+)( |$)' >/dev/null && ok "no force flag or + refspec on push" || bad "force on push"
grep -E '(^| )fetch( |$)' "$GITLOG" | grep -q -- "--no-tags" && grep -E '(^| )fetch( |$)' "$GITLOG" | grep -q -- "$GH +refs/heads/main:refs/vault-sync/" \
  && ok "fetch uses the literal URL into a private ref, no tags" || bad "fetch argv" "$(grep fetch "$GITLOG")"
grep -q 'FETCH_HEAD' "$GITLOG" && bad "FETCH_HEAD used" || ok "FETCH_HEAD is not used"
grep -qE '(^| )(pull|merge|rebase|reset)( |$)' "$GITLOG" && bad "script ran pull/merge/rebase/reset" || ok "never pulls, merges, rebases or resets"
! grep -vE -- '--no-replace-objects' "$GITLOG" | grep . >/dev/null && ok "every git call passes --no-replace-objects" || bad "replace flag" "$(grep -v -- --no-replace-objects "$GITLOG" | head -3)"
grep -E '(^| )(fetch|push)( |$)' "$GITLOG" | grep -vq -- '-c core.hooksPath=/dev/null' && bad "hooksPath missing on fetch/push" || ok "fetch and push run with core.hooksPath=/dev/null"
vs push; { [ $RC = 0 ] && has "nothing to push"; } && ok "nothing to push exits 0" || bad "nothing to push" "$OUT"

# finding 2: GIT_* never reaches git (wholesale), only the three fixed ones
newcase; commit_file n.md "hello" "n"
OUT=$(env GIT_SSH_COMMAND="touch $TMP/ssh-ran" GIT_ASKPASS=/bin/false GIT_EXEC_PATH=/nonexistent GIT_DIR="$C/decoy" GIT_WORK_TREE="$C" GIT_INDEX_FILE="$C/idx" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/nonexistent \
      WRAP_FROM="$GH" WRAP_TO="$R" PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
seen=$(grep -E '^GIT_' "$ENVLOG" | sed 's/=.*//' | sort -u | tr '\n' ' ')
[ "$seen" = "GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_NO_REPLACE_OBJECTS GIT_TERMINAL_PROMPT " ] || [ "$seen" = "GIT_NO_REPLACE_OBJECTS GIT_TERMINAL_PROMPT " ] \
  && ok "only GIT_TERMINAL_PROMPT and GIT_NO_REPLACE_OBJECTS reach git (SSH_COMMAND, DIR, CONFIG_* dropped)" || bad "git env" "$seen"
grep -q '^GIT_TERMINAL_PROMPT=0' "$ENVLOG" && grep -q '^GIT_NO_REPLACE_OBJECTS=1' "$ENVLOG" && ok "GIT_TERMINAL_PROMPT=0 and GIT_NO_REPLACE_OBJECTS=1 are set" || bad "fixed env"
{ [ $RC = 0 ] && [ "$(remote_main)" = "$(vault_head)" ] && [ ! -e "$TMP/ssh-ran" ]; } && ok "hostile GIT_* does not redirect or run anything" || bad "hostile env" "rc=$RC $OUT"

# finding 1/2/3: destination identity
newcase; commit_file n.md "hello" "n"
G -C "$V" config --add remote.origin.pushurl "$GH"; G -C "$V" config --add remote.origin.pushurl "https://github.com/test-owner/public.git"
refuses "two push URLs (one public) are refused"; has "exactly one" && ok "multi-URL refusal says why" || bad "multi msg" "$OUT"
newcase; commit_file n.md "hello" "n"; G -C "$V" config remote.origin.pushurl "https://github.com/test-owner/other.git"
refuses "fetch and push URLs naming different repos are refused"
newcase; commit_file n.md "hello" "n"; G -C "$V" remote set-url origin "https://example.com/test-owner/vault.git"
refuses "a non-github.com host is refused"
newcase; commit_file n.md "hello" "n"; G -C "$V" remote set-url origin "http://github.com/test-owner/vault.git"
refuses "plain http is refused"
newcase; commit_file n.md "hello" "n"; G -C "$V" remote set-url origin "https://user:pw@github.com/test-owner/vault.git"
refuses "a URL with embedded credentials is refused"
newcase; commit_file n.md "hello" "n"; G -C "$V" remote set-url origin "git@github.com:test-owner/vault.git"
WFROM="git@github.com:test-owner/vault.git" vs push --dry-run; { [ $RC = 0 ] && has "private"; } && ok "scp-form ssh URL is accepted" || bad "scp url" "rc=$RC $OUT"
newcase; commit_file n.md "hello" "n"; G -C "$V" config remote.origin.mirror true
refuses "a mirror remote is refused"
newcase; commit_file n.md "hello" "n"; G -C "$V" remote set-url origin "$R"
refuses "a local-path remote (privacy unverifiable) is refused"
"$PY" -B - "$SUT" <<'PYEOF' && ok "github URL parsing" || bad "github URL parsing"
import importlib.util, sys
s = importlib.util.spec_from_file_location("vs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
for u in ("https://github.com/o/n.git", "https://github.com/o/n", "git@github.com:o/n.git", "ssh://git@github.com/o/n.git"):
    assert m.parse_github(u) == ("o", "n"), u
for u in ("/tmp/x.git", "https://example.com/o/n.git", "git@gitlab.com:o/n.git", "https://github.com/o", "http://github.com/o/n",
          "https://u:p@github.com/o/n", "https://github.com.evil.test/o/n", "git://github.com/o/n"):
    assert m.parse_github(u) is None, u
PYEOF
grep -qE 'VAULT_SYNC_TEST|skip-visibility|skip_visibility' "$SUT" && bad "a test bypass exists in the script" || ok "no bypass flag or test env var exists in the script"
newcase; commit_file n.md "hello" "n"
OUT=$(env VAULT_SYNC_TEST=1 VAULT_SYNC_TEST_REPO=test/vault WRAP_FROM="$GH" WRAP_TO="$R" PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push --skip-visibility-check 2>&1); RC=$?
{ [ $RC = 2 ] && [ "$(remote_main)" != "$(vault_head)" ]; } && ok "--skip-visibility-check is not an option (exit 2)" || bad "bypass flag" "rc=$RC $OUT"

# finding 1: gh runs against an explicit host with a controlled environment
newcase; commit_file n.md "hello" "n"
OUT=$(env GH_HOST=evil.example GH_REPO=evil/repo GH_ENTERPRISE_TOKEN=ent GITHUB_ENTERPRISE_TOKEN=ent GH_CONFIG_DIR="$C/cfg" GH_TOKEN=tok GITHUB_TOKEN=tok2 \
      WRAP_FROM="$GH" WRAP_TO="$R" PATH="$TMP/bin:/usr/bin:/bin" "$PY" -B "$SUT" --vault "$V" push --dry-run 2>&1); RC=$?
{ [ $RC = 0 ] && grep -q 'ARGS: api repos/test-owner/vault --hostname github.com --jq .visibility' "$GHLOG"; } && ok "gh api is called with an explicit github.com host" || bad "gh args" "rc=$RC $(cat "$GHLOG")"
! grep -qE '^(GH_HOST|GH_REPO|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|GH_CONFIG_DIR)=' "$GHLOG" && ok "GH_HOST, GH_REPO, enterprise tokens and GH_CONFIG_DIR are dropped" || bad "gh env" "$(cat "$GHLOG")"
grep -q '^GH_TOKEN=tok' "$GHLOG" && grep -q '^GITHUB_TOKEN=tok2' "$GHLOG" && ok "GH_TOKEN and GITHUB_TOKEN are kept for auth" || bad "gh token kept"

newcase; commit_file n.md "hello" "n"; setvis public
refuses "refuses a public repo"; has "public" && ok "public refusal names visibility" || bad "public msg" "$OUT"
newcase; commit_file n.md "hello" "n"; setvis internal; refuses "refuses an internal repo"
newcase; commit_file n.md "hello" "n"; : >"$TMP/gh.fail"; refuses "refuses when gh fails"; has "gh failed" && ok "gh failure uses the fixed category" || bad "gh msg" "$OUT"
newcase; commit_file n.md "hello" "n"; before=$(refs)
OUT=$(env WRAP_FROM="$GH" WRAP_TO="$R" PATH="$TMP/bin-nogh" "$PY" -B "$SUT" --vault "$V" push 2>&1); RC=$?
{ [ $RC = 1 ] && has "gh is not available" && [ "$before" = "$(refs)" ]; } && ok "refuses when gh is missing" || bad "gh missing" "rc=$RC $OUT"
[ ! -s "$GITLOG" ] || ! grep -qE '(^| )(fetch|push)( |$)' "$GITLOG" && ok "no network git call before visibility is verified" || bad "network before gate" "$(cat "$GITLOG")"

# ---- push: behind / diverged ------------------------------------------------
newcase; O="$C/other"; G clone -q "$R" "$O" 2>/dev/null
echo r >"$O/r.md"; G -C "$O" add -- r.md; G -C "$O" commit -q -m remote; G -C "$O" push -q origin main 2>/dev/null
commit_file l.md "local" "local"
refuses "refuses when diverged"; { has "diverged" && has "ahead 1 behind 1"; } && ok "diverged refusal prints counts" || bad "diverged msg" "$OUT"
G -C "$V" reset -q --hard origin/main
refuses "refuses when behind"; has "behind" && ok "behind refusal names the state" || bad "behind msg" "$OUT"
grep -qE '(^| )(pull|merge|rebase|reset)( |$)' "$GITLOG" && bad "script reconciled by itself" || ok "refusal ran no reconcile command"

# ---- finding 3: the scan is bound to the pinned oid -------------------------
newcase; commit_file n.md "hello" "n"; HEAD0=$(vault_head)
S1="gh""p_Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv"
cat >"$C/hook.sh" <<EOF
printf 'late %s\n' "$S1" >"$V/late.md"
$REAL_GIT -C "$V" add -- late.md
$REAL_GIT -C "$V" commit -q -m late
EOF
export WRAP_AFTER_FETCH="$C/hook.sh"; vs push; unset WRAP_AFTER_FETCH
{ [ $RC = 0 ] && [ "$(remote_main)" = "$HEAD0" ] && [ "$(vault_head)" != "$HEAD0" ]; } \
  && ok "a commit landing after the pin is neither scanned nor pushed" || bad "pinning" "rc=$RC remote=$(remote_main) head0=$HEAD0 $OUT"
! G -C "$R" cat-file -e "$(vault_head)" 2>/dev/null && ok "the late commit's objects never reached the remote" || bad "late objects pushed"

# ---- scan: credential shapes (built at run time), in file content ------------
AL="Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv"
cred() {
  newcase; SECRET="$2"
  commit_file notes.md "line one
carrying $2 inside
line three" "add note"
  refuses "refuses credential: $1"
  { has "notes.md:2" && ! has "$2"; } && ok "refusal for $1 names path and line only" || bad "$1 location" "$OUT"
}
cred "github ghp"  "gh""p_${AL}"
cred "github gho"  "gh""o_${AL}"
cred "github pat"  "github""_pat_${AL}${AL}"
cred "sk key"      "s""k-${AL}"
cred "stripe live" "s""k_live_${AL}"
cred "stripe test" "s""k_test_${AL}"
cred "slack"       "xo""xb-12345678-${AL}"
cred "aws"         "AK""IA""ABCD1234EFGH5678"
cred "pem"         "-----BEGIN RSA ""PRIVATE KEY-----"
cred "jwt"         "ey""JhbGciOiJIUzI1NiJ9.""ey""JzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
cred "password assignment" "password=""Hunter2Hunter2"
cred "api key assignment"  "api_key: ""x9y8z7w6v5u4"
cred "token assignment"    "token = ""AbCdEfGhIjKl"
cred "bearer"      "Bearer ""${AL}${AL}"

newcase; commit_file n.md "token: usage-checkpoint
the risk-assessment-of-things-in-general is fine
password: changeme-please" "benign"
vs push; [ $RC = 0 ] && ok "benign keyword-like text passes" || bad "benign text" "$OUT"

# finding 7/8/9: raw content, not diff text
newcase; SECRET="gh""p_${AL}"
commit_file t.md "++ b/innocent.md
$SECRET" "spoof"
refuses "a '++' content line cannot spoof the diff header"; has "t.md:2" && ok "spoof finding is attributed to the real path and line" || bad "spoof attribution" "$OUT"
newcase; SECRET="gh""p_${AL}"; G -C "$V" config core.bigFileThreshold 1
printf 'secret.md -diff\n*.dat binary\n' >"$V/.gitattributes"; G -C "$V" add -- .gitattributes; G -C "$V" commit -q -m attrs
commit_file secret.md "k $SECRET" "attr"
refuses "bigFileThreshold=1 and a -diff attribute do not hide content"
newcase; SECRET="gh""p_${AL}"; printf '%s\000binary\n' "$SECRET" >"$V/b.dat"; G -C "$V" add -- b.dat; G -C "$V" commit -q -m bin
refuses "a binary blob containing a token is still scanned"
newcase; SECRET="gh""p_${AL}"
commit_file t.md "key $SECRET" "oops"; commit_file t.md "clean" "fix"
refuses "scans every commit in the range, not only the tip"
newcase; SECRET="gh""p_${AL}"; printf 'caf\351 %s\n' "$SECRET" >"$V/l1.md"; G -C "$V" add -- l1.md; G -C "$V" commit -q -m latin
refuses "undecodable bytes are scanned as latin-1, not skipped"
# a replace ref must not substitute a benign blob for the real one
newcase; SECRET="gh""p_${AL}"
commit_file t.md "k $SECRET" "real"
real=$(G -C "$V" rev-parse HEAD:t.md); benign=$(printf 'benign\n' | G -C "$V" hash-object -w --stdin)
G -C "$V" replace "$real" "$benign"
refuses "a replace ref does not hide a secret"
# finding 8: NUL-delimited paths with tab, newline and quote
newcase; SECRET="gh""p_${AL}"
P=$(printf 'dir/a\tb"c\nd.md')
commit_file "$P" "k $SECRET" "odd"
refuses "tab/newline/quote filenames are scanned"; has 'a\x09b"c\x0ad.md:1' && ok "odd path is printed escaped" || bad "path escaping" "$OUT"

# findings 11/14: filenames and subjects with credentials
newcase; S2="gh""p_${AL}"; SECRET="$S2"; commit_file "k-$S2.md" "harmless text" "named"
refuses "a credential in a filename is refused"; { has "credential-in-path" && has "<redacted>"; } && ok "filename credential is redacted in output" || bad "path redaction" "$OUT"
newcase; SECRET="gh""p_${AL}"; commit_file n.md "harmless" "subject with $SECRET inside"
refuses "a credential in a commit message is refused"; has "(commit message):1" && ok "message finding names the message and line only" || bad "message finding" "$OUT"
newcase; SECRET="gh""p_${AL}"; commit_file n.md "harmless" "subj"; G -C "$V" commit -q --amend -m "subj

body line carries $SECRET"
refuses "a credential in a commit body is refused"

# finding 14: LFS pointer
newcase; commit_file big.bin "version https://git-lfs.github.com/spec/v1
oid sha256:$(printf '0%.0s' {1..64})
size 12345" "lfs"
refuses "an LFS pointer is refused"; has "lfs-pointer" && ok "LFS refusal names the rule" || bad "lfs msg" "$OUT"

# ---- scan: sensitive paths, size ---------------------------------------------
SECRET=
for p in .env .env.local conf/server.pem conf/x.key id_rsa id_ed25519.pub my-credentials.json a.p12 login.keychain-db; do
  newcase; commit_file "$p" "harmless text" "add $p"
  refuses "refuses sensitive path $p"; has "$p" && ok "refusal names $p" || bad "names $p" "$OUT"
done
newcase; head -c 53000000 /dev/zero >"$V/big.bin"; G -C "$V" add -- big.bin; G -C "$V" commit -q -m big
refuses "refuses a blob over 50 MB"; { has "big.bin" && has "blob-too-large"; } && ok "size refusal names path and rule" || bad "size msg" "$OUT"

# finding 12: the size gate fails closed
newcase; commit_file n.md "hello" "n"; export WRAP_BC=fail
refuses "a failing cat-file --batch-check refuses"; has "could not complete" && ok "batch-check failure is reported as an incomplete scan" || bad "bc msg" "$OUT"
newcase; commit_file n.md "hello" "n"; export WRAP_BC=short
refuses "a short or 'missing' batch-check answer refuses"
unset WRAP_BC

# ---- narrowed --allow-path (finding 14) ---------------------------------------
newcase; commit_file .env "harmless text" "add env"; oid=$(vault_head)
refuses "--allow-path with the wrong rule does not exempt" --allow-path "$oid:.env:jwt"
refuses "--allow-path with the wrong commit does not exempt" --allow-path "deadbeef:.env:sensitive-path"
refuses "--allow-path with the wrong path does not exempt" --allow-path "$oid:other.env:sensitive-path"
refuses "--allow-path is literal, not a pattern" --allow-path "$oid:.e*:sensitive-path"
vs push --allow-path "$oid:.env:sensitive-path"
{ [ $RC = 0 ] && has "allow-path in effect: $oid:.env:sensitive-path" && has "allowed (--allow-path): ${oid:0:8} .env [sensitive-path]" && [ "$(remote_main)" = "$oid" ]; } \
  && ok "the exact allow pushes and is echoed" || bad "allow" "rc=$RC $OUT"
newcase; commit_file .env "harmless text" "add env"; commit_file k.pem "x" "pem"; oid=$(G -C "$V" rev-parse HEAD~1)
refuses "one allow does not cover a second finding" --allow-path "$oid:.env:sensitive-path"
vs push --allow-path "bad-format"; [ $RC = 2 ] && ok "malformed --allow-path is a usage error (2)" || bad "allow format" "rc=$RC $OUT"

# ---- hooks, submodules, tags (finding 5/10) -----------------------------------
newcase; commit_file n.md "hello" "n"
mkdir -p "$V/.git/hooks" "$C/hp"
for d in "$V/.git/hooks" "$C/hp"; do printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 1\n' "$TMP" >"$d/pre-push"; cp "$d/pre-push" "$d/reference-transaction"; chmod +x "$d/"*; done
G -C "$V" config core.hooksPath "$C/hp"
vs push
{ [ $RC = 0 ] && [ ! -e "$TMP/hook-ran" ] && [ "$(remote_main)" = "$(vault_head)" ]; } && ok "no vault hook (pre-push, reference-transaction) ever runs" || bad "hooks" "rc=$RC $OUT"

newcase; commit_file n.md "hello" "n"
G -C "$V" tag -a v1 -m tag; G -C "$V" config push.followTags true; G -C "$V" config push.recurseSubmodules on-demand; G -C "$V" config submodule.recurse true
G -C "$V" update-index --add --cacheinfo "160000,$(printf '%040d' 7),sub"; G -C "$V" commit -q -m "gitlink"
vs push
{ [ $RC = 0 ] && [ "$(remote_main)" = "$(vault_head)" ] && ! refs | grep -q 'refs/tags'; } && ok "no tags are pushed and a gitlink does not trigger a submodule push" || bad "tags/submodule" "rc=$RC refs=$(refs) $OUT"
! grep -E '(^| )push( |$)' "$GITLOG" | grep -q 'follow-tags[^ ]*$' && ok "push passes --no-follow-tags" || bad "followtags"

# ---- finding 17: outcomes ----------------------------------------------------
newcase; commit_file n.md "hello" "n"
printf '#!/bin/sh\nexit 1\n' >"$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"; before=$(refs)
vs push; { [ $RC = 3 ] && has "partially succeeded" && [ "$before" = "$(refs)" ]; } && ok "a rejected push exits 3 with the indeterminate message" || bad "push fail" "rc=$RC $OUT"
newcase; commit_file n.md "hello" "n"; mv "$R" "$R.moved"
vs push; { [ $RC = 3 ] && has "fetch failed" && has "nothing was pushed"; } && ok "a failed fetch exits 3 with a fixed category" || bad "fetch fail" "rc=$RC $OUT"
mv "$R.moved" "$R"
newcase; commit_file n.md "hello" "n"; export WRAP_LIE=1
vs push; unset WRAP_LIE
{ [ $RC = 3 ] && has "could not be confirmed"; } && ok "a post-push tip mismatch exits 3" || bad "verify tip" "rc=$RC $OUT"
echo "$OUT" | grep -q "$R" && bad "stderr or paths relayed" || ok "failure output does not relay paths or stderr"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
