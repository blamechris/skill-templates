#!/usr/bin/env bash
# Regression tests for assets/scripts/worktree-audit.py (#432).
#
# Real git repos in a temp dir (bare origin + main clone + linked worktrees);
# `gh` and `lsof` are FAKES on PATH -- never the real ones, no network. Verdicts
# are asserted through --json. Each acceptance bullet of #432 has its own case:
# every KEEP reason, class A/B, the ignored-file gap (case 4), the name-anywhere
# allowlist gap (case 5), byte-identical read-only run (case 14) and exit 2 on
# an unreadable root (case 15). Does NOT `set -e`: a failing case is reported
# and the rest still run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
SUT="$HERE/worktree-audit.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
# Zero-case guard: a harness that reports success over zero (or too few) cases is
# a false-safety guard (#7653-class). Raise this when cases are added.
MIN_PASS=75
TMP=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/worktree-audit-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "'$2' lacks '$3'";; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "'$2' unexpectedly has '$3'";; *) ok "$1";; esac; }

# Hermetic git: no user/global config, fixed identity, so CI runners with none work.
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export CLAUDE_HANDOFF_DIR="$TMP/no-seeds"

FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
# fake gh: prints $FAKE_GH_FILE (a JSON array) for `pr list`; "[]" if unset
if [ "${FAKE_GH_FAIL:-}" = 1 ]; then exit 1; fi
if [ -n "${FAKE_GH_FILE:-}" ] && [ -f "$FAKE_GH_FILE" ]; then cat "$FAKE_GH_FILE"; else echo "[]"; fi
GH
cat > "$FAKEBIN/lsof" <<'LS'
#!/usr/bin/env bash
# fake lsof: prints $FAKE_LSOF_FILE verbatim (n<path> lines), nothing if unset
[ -n "${FAKE_LSOF_FILE:-}" ] && [ -f "$FAKE_LSOF_FILE" ] && cat "$FAKE_LSOF_FILE"
exit 0
LS
chmod +x "$FAKEBIN/gh" "$FAKEBIN/lsof"
export PATH="$FAKEBIN:$PATH"

N=0
fixture() { # fresh world: $T, $ROOT (scan root), $REPO (main clone), $BARE, $SEEDS
  N=$((N+1)); T="$TMP/c$N"; ROOT="$T/proj"; REPO="$ROOT/repo"; BARE="$T/origin.git"; SEEDS="$T/seeds"
  mkdir -p "$ROOT" "$SEEDS"; : > "$T/lsof.txt"
  export FAKE_LSOF_FILE="$T/lsof.txt"; unset FAKE_GH_FILE FAKE_GH_FAIL
  git init -q --bare -b main "$BARE"
  git init -q -b main "$REPO"
  ( cd "$REPO" && printf 'node_modules/\ndist/\ncoverage/\n*.log\n' > .gitignore \
      && echo hi > a.txt && git add .gitignore a.txt && git commit -q -m init \
      && git remote add origin "$BARE" && git push -q -u origin main \
      && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main \
      && git config remote.origin.url https://github.com/t/repo.git \
      && git config "url.$BARE.insteadOf" https://github.com/t/repo.git )
}
mkwt() { # name branch  -> $ROOT/repo-<name>-20261101 ; sets WT
  WT="$ROOT/repo-$1-20261101"
  git -C "$REPO" worktree add -q -b "$2" "$WT" origin/main 2>/dev/null
}
age() { touch -t 202601010000 "$(git -C "$1" rev-parse --absolute-git-dir)/gitdir"; }
audit() { # [args] -> OUT, ERR, RC
  OUT=$("$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --json "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
}
q() { printf '%s' "$OUT" | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
w={x["path"].rsplit("/",1)[-1].split("-")[1]:x for r in d["repos"] for x in r["worktrees"]}
print(eval(sys.argv[1]))' "$1"; }
V()  { q "w['$1']['verdict']"; }
C()  { q "w['$1']['content_class']"; }
R()  { q "' | '.join(w['$1']['reasons'])"; }
ND() { q "' | '.join(w['$1']['needs'])"; }

echo "1. clean, in base, old -> A (branch and detached)"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree add -q --detach "$ROOT/repo-det-20261101" origin/main; age "$ROOT/repo-det-20261101"
audit; eq "exit 0" "$RC" 0; eq "branch wt is A" "$(V one)" A; eq "detached wt is A" "$(V det)" A
eq "detached PR state n/a" "$(q "w['det']['pr']['state']")" "n/a"

echo "2. tracked edit -> B"
fixture; mkwt one b1; age "$WT"; echo changed >> "$WT/a.txt"
audit; eq "verdict B" "$(V one)" B; has "needs tracked edits" "$(ND one)" "tracked edits (1)"

echo "3. untracked file -> B"
fixture; mkwt one b1; age "$WT"; echo x > "$WT/new.txt"
audit; eq "verdict B" "$(V one)" B; has "needs untracked" "$(ND one)" "untracked files (1)"

echo "4. ignored *.log inside .evidence/ -> B (the --exclude-standard gap)"
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/.evidence"; echo log > "$WT/.evidence/run.log"
audit; eq "verdict B" "$(V one)" B; has "needs ignored" "$(ND one)" "ignored non-rebuildable files (1)"
eq "not counted as untracked" "$(q "w['one']['untracked']")" 0

echo "5. rooted allowlist: coverage/dist under .evidence are evidence, node_modules/dist at roots are not"
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/.evidence/coverage"; echo '{}' > "$WT/.evidence/coverage/x.json"
audit; eq "ignored .evidence/coverage -> B" "$(V one)" B
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/.evidence/run/dist"; echo 1 > "$WT/.evidence/run/dist/a.js"
audit; eq "ignored .evidence/run/dist -> B" "$(V one)" B
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/node_modules" "$WT/packages/a/dist" "$WT/packages/a/node_modules/z"
echo 1 > "$WT/node_modules/x"; echo 1 > "$WT/packages/a/dist/x.js"; echo 1 > "$WT/packages/a/node_modules/z/i.js"
audit; eq "rooted rebuildables alone -> A" "$(V one)" A; eq "none counted" "$(q "w['one']['ignored_nonrebuildable']")" 0
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/src/node_modules"; echo 1 > "$WT/src/node_modules/x"
audit; eq "node_modules not at a root -> B" "$(V one)" B

echo "6. unique unpushed commit -> B; pushed -> A"
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u )
audit; eq "unpushed -> B" "$(V one)" B; has "needs commits" "$(ND one)" "commits"
( cd "$WT" && git push -q origin b1 2>/dev/null ); audit; eq "pushed -> A" "$(V one)" A

echo "7. merged PR whose head == worktree head"
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u )
H=$(git -C "$WT" rev-parse HEAD); echo "[{\"number\":5,\"state\":\"MERGED\",\"headRefOid\":\"$H\"}]" > "$T/gh.json"; export FAKE_GH_FILE="$T/gh.json"
audit; eq "merged PR head -> A" "$(V one)" A
eq "merged_pr_head fact" "$(q "w['one']['merged_pr_head']")" True
echo "[{\"number\":5,\"state\":\"MERGED\",\"headRefOid\":\"0000000000000000000000000000000000000000\"}]" > "$T/gh.json"
audit; eq "merged PR with other head -> B" "$(V one)" B
audit --no-gh; eq "--no-gh -> KEEP" "$(V one)" KEEP; has "PR state unknown" "$(R one)" "PR state unknown"
eq "content class still shown" "$(C one)" B
FAKE_GH_FAIL=1 audit; eq "failing gh -> KEEP" "$(V one)" KEEP

echo "8. open PR -> KEEP"
fixture; mkwt one b1; age "$WT"; echo '[{"number":9,"state":"OPEN","headRefOid":"abc"}]' > "$T/gh.json"; export FAKE_GH_FILE="$T/gh.json"
audit; eq "open PR KEEP" "$(V one)" KEEP; has "reason open PR" "$(R one)" "open PR"; eq "class A shown" "$(C one)" A

echo "9. locks"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock --reason "agent (pid $$)" "$WT"
audit; eq "live pid -> KEEP" "$(V one)" KEEP; has "reason names live pid" "$(R one)" "live pid $$"
DEAD=$("$PY" -c 'import os
for p in range(90000,99990):
    try: os.kill(p,0)
    except ProcessLookupError: print(p); break')
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock --reason "agent (pid $DEAD)" "$WT"
audit; eq "dead pid, clean+in base -> A" "$(V one)" A; eq "lock parsed" "$(q "w['one']['lock_pid']")" "$DEAD"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock --reason "manual" "$WT"
audit; eq "no pid -> KEEP" "$(V one)" KEEP; has "unparseable" "$(R one)" "unparseable pid"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock "$WT"
audit; eq "lock without reason -> KEEP" "$(V one)" KEEP

echo "10. named in a seed"
fixture; mkwt one feat/zeta; age "$WT"; echo "Continue on feat/zeta next." > "$SEEDS/NEXT-x.md"
audit; eq "seed KEEP" "$(V one)" KEEP; has "names seed file" "$(R one)" "NEXT-x.md"
fixture; mkwt one b1; age "$WT"; echo "see $WT for state" > "$SEEDS/NEXT-y.md"
audit; eq "path mention KEEP" "$(V one)" KEEP
fixture; mkwt one b1; age "$WT"; echo "branch b10 and feat/b1x only" > "$SEEDS/NEXT-z.md"
audit; eq "partial-word branch is not a mention" "$(V one)" A
fixture; mkwt one b1; age "$WT"; audit --seed-dir "$T/absent"; eq "missing seed dir flagged" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["seed_dir_missing"])')" True

echo "11. fresh creation"
fixture; mkwt one b1; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u )
audit; eq "fresh + unpushed -> KEEP" "$(V one)" KEEP; has "fresh reason" "$(R one)" "<24h"
fixture; mkwt one b1; audit; eq "fresh but in base -> A" "$(V one)" A

echo "12. liveness"
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/sub"; echo "n$WT/sub" > "$T/lsof.txt"
audit; eq "cwd inside -> KEEP" "$(V one)" KEEP; has "in use" "$(R one)" "in use"
echo "n$ROOT/other" > "$T/lsof.txt"; audit; eq "unrelated cwd -> A" "$(V one)" A
echo "n$WT-sibling" > "$T/lsof.txt"; audit; eq "prefix sibling is not inside" "$(V one)" A
audit --liveness none; eq "liveness none -> KEEP" "$(V one)" KEEP; has "liveness unknown" "$(R one)" "liveness unknown"
eq "content class A shown" "$(C one)" A

echo "13. leftovers"
fixture; mkwt one b1; age "$WT"; mkdir -p "$ROOT/scratch-20261001/sub" "$ROOT/notes-2026-10-02-x" "$ROOT/plain"
mkdir -p "$ROOT/gitfile-20261003"; echo "gitdir: /nowhere" > "$ROOT/gitfile-20261003/.git"
audit; LO=$(q "' '.join(x['path'].rsplit('/',1)[-1] for x in d['leftovers'])")
has "dated dir listed" "$LO" scratch-20261001; has "dashed date listed" "$LO" notes-2026-10-02-x
lacks "undated not listed" "$LO" plain; lacks "dated dir with .git not listed" "$LO" gitfile; lacks "worktree not a leftover" "$LO" repo-one
eq "leftover verdict REVIEW" "$(q "d['leftovers'][0]['verdict']")" REVIEW

echo "14. read-only: byte-identical fixture, .git/index untouched"
fixture; mkwt one b1; age "$WT"; mkwt two b2; age "$WT"; echo c >> "$WT/a.txt"; echo u > "$WT/un.txt"
touch -t 202601020000 "$WT/a.txt" "$REPO/a.txt"; touch -t 202601030000 "$ROOT/repo-one-20261101/a.txt"
snap() { "$PY" - "$T" <<'PYS'
import hashlib, os, sys
h = hashlib.sha256()
for d, ds, fs in os.walk(sys.argv[1]):
    ds.sort()
    for n in sorted(fs + ds):
        p = os.path.join(d, n); st = os.lstat(p)
        h.update(("%s %o %d %d\n" % (os.path.relpath(p, sys.argv[1]), st.st_mode, st.st_size, st.st_mtime_ns)).encode())
        if os.path.islink(p): h.update(os.readlink(p).encode())
        elif os.path.isfile(p):
            with open(p, "rb") as f: h.update(f.read())
print(h.hexdigest())
PYS
}
B1=$(snap); audit --sizes; audit --sizes --liveness none --no-gh; B2=$(snap); audit
eq "tree hash unchanged by runs" "$B1" "$B2"
eq "dirty wt was classified B" "$(V two)" B
eq "sanity: snapshot is a sha256" "${#B1}" 64

echo "15. unreadable root / missing worktree dir"
fixture; mkwt one b1; age "$WT"
OUT2=$("$PY" "$SUT" --root /nonexistent-wa-root --seed-dir "$SEEDS" 2>&1); RC2=$?
eq "missing root exit 2" "$RC2" 2; has "names the root" "$OUT2" /nonexistent-wa-root
OUT2=$("$PY" "$SUT" --repo /nonexistent-wa-repo --seed-dir "$SEEDS" 2>&1); RC2=$?
eq "missing repo exit 2" "$RC2" 2; has "names the repo" "$OUT2" /nonexistent-wa-repo
audit --root /nonexistent-wa-root; eq "good root still read, exit 2" "$RC" 2; eq "good root's worktree still listed" "$(V one)" A
fixture; mkwt one b1; age "$WT"; mkwt two b2; rm -rf "$WT"
audit; eq "removed dir exit 0" "$RC" 0; eq "removed dir -> PRUNABLE-REF" "$(V two)" PRUNABLE-REF; eq "content class n/a" "$(C two)" "n/a"
fixture; mkwt one b1; age "$WT"; chmod 000 "$REPO/.git" 2>/dev/null
audit; if [ "$(id -u)" = 0 ]; then ok "unreadable worktree list (skipped as root)"; else eq "unreadable repo -> exit 2" "$RC" 2; has "names it" "$ERR" "repo"; fi
chmod 755 "$REPO/.git" 2>/dev/null
audit --repo "$REPO"; eq "--repo dedupes with --root" "$(q "len(d['repos'])")" 1

echo "16. human output"
fixture; mkwt one b1; age "$WT"
H=$("$PY" "$SUT" --root "$ROOT" --seed-dir "$T/absent" 2>&1); RC=$?
eq "exit 0" "$RC" 0; has "summary line" "$H" "Summary:"; has "free on filesystem" "$H" "free on filesystem"
has "verdict shown" "$H" "A  "; has "seed note" "$H" "does not exist"

echo
echo "$pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1
if [ "$pass" -lt "$MIN_PASS" ]; then echo "FAIL: only $pass cases ran, expected at least $MIN_PASS (zero-case guard)"; exit 1; fi
exit 0
