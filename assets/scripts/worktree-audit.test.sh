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
# a false-safety guard (#7653-class). Every assertion is either counted as passed or
# explicitly counted as skipped (root cannot make a path unreadable), so the total
# must equal EXPECTED_TOTAL EXACTLY (a floor would let a deleted case hide behind an
# added skip, or a new case go uncounted), and skips are capped. Move EXPECTED_TOTAL
# whenever an assertion is added or removed.
EXPECTED_TOTAL=209
MAX_SKIPPED=10
TMP=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/worktree-audit-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
skip() { skipped=$((skipped+$1)); echo "  skip $2 ($1 assertions)"; }  # root cannot make a path unreadable
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
# fake gh: prints $FAKE_GH_FILE (a JSON array) for `pr list`; "[]" if unset.
# It ASSERTS its argv (`pr list -R <slug> --head <branch> --state all ...`) and fails
# loudly -- exit 64 plus a line in gh.mismatch -- on anything else, so a call that
# drops -R or --state all cannot be answered "no PRs" by a permissive fake.
echo "$*" >> "$GH_CALLS"
if [ "$1 $2 $3 $4 $5 $7 $8" != "pr list -R ${FAKE_GH_SLUG:-t/repo} --head --state all" ] || [ -z "$6" ]; then
  echo "BAD ARGS: $*" >> "$GH_MISMATCH"; echo "fake gh: unexpected args: $*" >&2; exit 64
fi
if [ "${FAKE_GH_FAIL:-}" = 1 ]; then exit 1; fi
if [ -n "${FAKE_GH_FILE:-}" ] && [ -f "$FAKE_GH_FILE" ]; then cat "$FAKE_GH_FILE"; else echo "[]"; fi
GH
cat > "$FAKEBIN/lsof" <<'LS'
#!/usr/bin/env bash
# fake lsof: prints $FAKE_LSOF_FILE verbatim (n<path> lines), nothing if unset
[ "${FAKE_LSOF_FAIL:-}" = 1 ] && exit 1
[ -n "${FAKE_LSOF_FILE:-}" ] && [ -f "$FAKE_LSOF_FILE" ] && cat "$FAKE_LSOF_FILE"
exit 0
LS
chmod +x "$FAKEBIN/gh" "$FAKEBIN/lsof"
export GH_CALLS="$TMP/gh.calls" GH_MISMATCH="$TMP/gh.mismatch"
: > "$GH_CALLS"
REALGIT=$(command -v git); export REALGIT
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
lacks "undated not listed" "$LO" plain; has "orphaned .git-file dir listed" "$LO" gitfile-20261003; has "with a note" "$(q "' '.join(str(x['note']) for x in d['leftovers'])")" "points at missing repo"; lacks "worktree not a leftover" "$LO" repo-one
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
audit; if [ "$(id -u)" = 0 ]; then skip 2 "unreadable repo (running as root)"; else eq "unreadable repo -> exit 2" "$RC" 2; has "names it" "$ERR" "$REPO"; fi
chmod 755 "$REPO/.git" 2>/dev/null
audit --repo "$REPO"; eq "--repo dedupes with --root" "$(q "len(d['repos'])")" 1

echo "16. human output"
fixture; mkwt one b1; age "$WT"
H=$("$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" 2>&1); RC=$?
eq "exit 0" "$RC" 0; has "summary line" "$H" "Summary:"; has "free on filesystem" "$H" "free on filesystem"
has "verdict shown" "$H" "A  "
H=$("$PY" "$SUT" --root "$ROOT" --seed-dir "$T/absent" 2>&1); RC=$?
eq "explicit absent seed dir: exit 2" "$RC" 2; has "seed note in human output" "$H" "seed check unavailable"; has "still has summary" "$H" "Summary:"

echo "17. seed check cannot be skipped silently"
fixture; mkwt one b1; age "$WT"
audit --seed-dir "$T/absent"
eq "explicit absent --seed-dir exit 2" "$RC" 2; eq "KEEP, not A" "$(V one)" KEEP; has "reason" "$(R one)" "seed check unavailable"
has "unverified names the dir" "$(q "' '.join(u['path'] for u in d['unverified'])")" "$T/absent"
eq "content class still shown" "$(C one)" A
OUT=$(CLAUDE_HANDOFF_DIR="$T/absent" "$PY" "$SUT" --root "$ROOT" --json 2>/dev/null); RC=$?
eq "default absent dir: exit 0" "$RC" 0; eq "default absent dir: KEEP" "$(V one)" KEEP; has "default absent reason" "$(R one)" "seed check unavailable"
OUT=$(CLAUDE_HANDOFF_DIR="$T/absent" "$PY" "$SUT" --root "$ROOT" --json --no-seeds 2>/dev/null); RC=$?
eq "--no-seeds exit 0" "$RC" 0; eq "--no-seeds skips the check -> A" "$(V one)" A
mkdir -p "$T/sd"; chmod 000 "$T/sd"
if [ "$(id -u)" = 0 ]; then skip 3 "unreadable seed dir (running as root)"; else
  audit --seed-dir "$T/sd"; eq "unreadable seed dir: no traceback, exit 2" "$RC" 2; eq "unreadable seed dir -> KEEP" "$(V one)" KEEP
  has "names the dir" "$ERR" "$T/sd"; fi
chmod 755 "$T/sd"
echo "see b1" > "$T/sd/NEXT-q.md"; chmod 000 "$T/sd/NEXT-q.md"
if [ "$(id -u)" = 0 ]; then skip 3 "unreadable seed file (running as root)"; else
  audit --seed-dir "$T/sd"; eq "unreadable seed file: exit 2" "$RC" 2; eq "unreadable seed file -> KEEP" "$(V one)" KEEP
  has "reason names file" "$(R one)" "NEXT-q.md"; fi
chmod 644 "$T/sd/NEXT-q.md"

echo "18. pid edge cases"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock --reason "agent pid 99999999999999999999" "$WT"
audit; eq "overflowing pid: no crash, exit 0" "$RC" 0; eq "overflowing pid -> KEEP" "$(V one)" KEEP
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock --reason "agent (pid 0)" "$WT"
audit; eq "pid 0 -> KEEP" "$(V one)" KEEP; has "pid 0 unparseable" "$(R one)" "unparseable pid"

echo "19. every git call is read-only-hardened (fsmonitor, untracked cache, optional locks)"
fixture; mkwt one b1; age "$WT"; WRAP="$T/wrapbin"; mkdir -p "$WRAP"; GITLOG="$T/git.log"; : > "$GITLOG"; export GITLOG
cat > "$WRAP/git" <<'W'
#!/usr/bin/env bash
echo "GOL=${GIT_OPTIONAL_LOCKS-unset} $*" >> "$GITLOG"
exec "$REALGIT" "$@"
W
chmod +x "$WRAP/git"
git -C "$REPO" config core.fsmonitor true
PATH="$WRAP:$PATH" audit
NCALL=$(wc -l < "$GITLOG" | tr -d ' ')
BADCALL=$(grep -v -c '^GOL=0 -c core.fsmonitor=false -c core.untrackedCache=false ' "$GITLOG")
[ "$NCALL" -ge 8 ] && ok "git wrapper saw the run ($NCALL calls)" || bad "git wrapper saw too few calls" "$NCALL"
eq "no git call lacks the hardening" "$BADCALL" 0
# Platform note: the daemon only exists where git ships the builtin fsmonitor (macOS,
# Windows); on Linux CI the artifact assertion is vacuous and the log check above is
# the real, platform-independent pin. For a LINKED worktree git writes the daemon
# files under .git/worktrees/<id>/, so glob the main .git and every admin dir.
FSM=$(ls -d "$REPO"/.git/fsmonitor--daemon* "$REPO"/.git/worktrees/*/fsmonitor--daemon* 2>/dev/null | wc -l | tr -d ' ')
git -C "$REPO" -c core.fsmonitor=false fsmonitor--daemon stop >/dev/null 2>&1
git -C "$WT" -c core.fsmonitor=false fsmonitor--daemon stop >/dev/null 2>&1
eq "no fsmonitor daemon artifacts" "$FSM" 0
eq "wt still classified" "$(V one)" A

echo "20. gh is called with the expected args"
fixture; mkwt one b1; age "$WT"; rm -f "$GH_MISMATCH"; : > "$GH_CALLS"; audit
has "gh args" "$(cat "$GH_CALLS")" "pr list -R t/repo --head b1 --state all"
[ -e "$GH_MISMATCH" ] && bad "fake gh saw bad args" "$(cat "$GH_MISMATCH")" || ok "no gh argument mismatch"
fixture; mkwt one b1; age "$WT"; ( cd "$REPO" && git remote add upstream https://github.com/o/up.git )
audit; eq "repo with upstream remote: PR unknown -> KEEP" "$(V one)" KEEP; has "reason" "$(R one)" "PR state unknown"
fixture; mkwt one b1; age "$WT"; ( cd "$REPO" && git config remote.origin.url https://gitlab.com/t/repo.git )
audit; eq "non-GitHub origin: PR unknown even though head is in base" "$(V one)" KEEP

echo "21. slug parsing (module import)"
SL=$("$PY" - "$SUT" <<'PYS'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("wa", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
for u in ("https://github.com/o/r.git", "https://github.com/o/r", "https://github.com/o/r/", "git@github.com:o/r.git",
          "ssh://git@github.com/o/r.git", "https://tok@github.com/o/r.git", "https://gitlab.com/o/r.git",
          "https://github.com.evil.com/o/r.git", "/local/path", ""):
    print(m.slug_from_url(u))
PYS
)
eq "slug forms" "$(echo $SL)" "o/r o/r o/r o/r o/r o/r None None None None"

echo "22. unknown default branch / stale-days / creation age"
fixture; mkwt one b1; age "$WT"
git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD; git -C "$REPO" update-ref -d refs/remotes/origin/main
audit; [ "$(C one)" != A ] && ok "no base ref: not class A" || bad "no base ref: not class A" "$(C one)"
has "needs names default branch unknown" "$(ND one)" "default branch unknown"; eq "in_base is null" "$(q "w['one']['in_base']")" None
fixture; mkwt one b1; age "$WT"
audit; eq "old creation, fresh head: not stale at 14d" "$(q "w['one']['stale']")" False
audit --stale-days=-1; eq "stale with a negative threshold" "$(q "w['one']['stale']")" True
# git hides a worktree whose admin gitdir file is gone, so "creation age unknown" is
# reachable only via a failed stat; pin the classifier branch directly.
CA=$("$PY" - "$SUT" <<'PYS'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("wa", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def fact(**kw):
    f = dict(path="/x/wt", branch="b", head="h", detached=False, locked=False, lock_reason="", lock_pid=None, missing=False,
             head_age_days=1.0, creation_age_days=None, tracked_dirty=0, untracked=0, ignored_nonrebuildable=0,
             in_base=False, in_remote_branch=False, merged_pr_head=False, pr=dict(known=True, open=False, merged_head=False, state="none"),
             in_use=False, seeds=[], seed_unavailable=None)
    f.update(kw); return f
a = fact(); m.classify(a, 14); print(a["verdict"], "creation age unknown" in " ".join(a["reasons"]))
b = fact(in_base=True); m.classify(b, 14); print(b["verdict"])
PYS
)
eq "creation age unknown + head unpreserved -> KEEP naming it" "$(echo $CA)" "KEEP True A"

echo "23. scan robustness"
fixture; mkwt one b1; age "$WT"; echo "only repo-one-20261101 here" > "$SEEDS/NEXT-b.md"
audit; eq "basename-only seed mention -> KEEP" "$(V one)" KEEP; has "names seed" "$(R one)" "NEXT-b.md"
fixture; mkwt one b1; age "$WT"; mkdir -p "$ROOT/sub"; chmod 000 "$ROOT/sub"
if [ "$(id -u)" = 0 ]; then skip 2 "unreadable subdir (running as root)"; else
  audit; eq "unreadable subdir: exit 2" "$RC" 2; has "named in unverified" "$(q "' '.join(u['path'] for u in d['unverified'])")" "$ROOT/sub"; fi
chmod 755 "$ROOT/sub"
fixture; mkwt one b1; age "$WT"; mkdir -p "$T/vol"; git -C "$REPO" worktree add -q -b b3 "$T/vol/repo-three-20261101" origin/main; rm -rf "$T/vol"
audit; eq "missing parent dir -> KEEP, not PRUNABLE" "$(q "w['three']['verdict']")" KEEP; has "reason" "$(q "w['three']['reasons'][0]")" "parent directory missing"
fixture; mkwt one b1; age "$WT"; NLWT="$ROOT/repo-nl
x-20261101"; git -C "$REPO" worktree add -q -b b4 "$NLWT" origin/main; age "$NLWT"
audit; eq "newline-in-path worktree is real, not PRUNABLE-REF" "$(q "[x['verdict'] for x in w.values() if '\n' in x['path']]")" "['A']"
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/packages/a/dist" "$WT/packages/a/node_modules/z" "$WT/src/node_modules"; echo 1 > "$WT/packages/a/dist/x.js"; echo 1 > "$WT/packages/a/node_modules/z/i.js"; echo 1 > "$WT/src/node_modules/x"
audit; eq "collapsed dir not covered by allowlist is expanded -> B" "$(V one)" B; eq "only the src one counts" "$(q "w['one']['ignored_nonrebuildable']")" 1

echo "25. remote preservation is verified live (stale tracking refs do not count)"
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin b1 2>/dev/null )
audit; eq "pushed + live -> A" "$(V one)" A; eq "in_remote_branch true" "$(q "w['one']['in_remote_branch']")" True
git --git-dir="$BARE" update-ref -d refs/heads/b1
audit; eq "branch deleted upstream, tracking ref stale -> not A" "$(V one)" B; has "needs commits" "$(ND one)" "commits"
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin b1 2>/dev/null )
git -C "$REPO" config --unset "url.$BARE.insteadOf"; git -C "$REPO" config "url.$T/nowhere.git.insteadOf" https://github.com/t/repo.git
audit; eq "ls-remote failing: remote does not count" "$(V one)" B; has "needs says not verified" "$(ND one)" "not verified live"
has "note in JSON" "$(q "' '.join(d['notes'])")" "not verified live"; eq "exit 0 (unknown is named, not an error)" "$RC" 0
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin b1 2>/dev/null ); : > "$GH_CALLS"
audit --offline; eq "--offline: remote unknown -> not A" "$(V one)" KEEP; has "PR unknown" "$(R one)" "PR state unknown"
eq "--offline made no gh call" "$(wc -c < "$GH_CALLS" | tr -d ' ')" 0
# A SEPARATE bare repo: $BARE is origin's own repository (via insteadOf), so pushing
# there would make the branch genuinely live on origin.
fixture; mkwt one b1; age "$WT"; OTHER="$T/other.git"; git init -q --bare -b main "$OTHER"
( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q "$OTHER" b1:b1 HEAD:refs/heads/main 2>/dev/null )
git -C "$REPO" remote add other "$OTHER"; git -C "$REPO" fetch -q other
eq "precondition: origin does not have b1" "$(git -C "$REPO" ls-remote origin refs/heads/b1 | wc -l | tr -d ' ')" 0
eq "precondition: other tracking ref exists" "$(git -C "$REPO" rev-parse --verify -q refs/remotes/other/b1 >/dev/null && echo yes)" yes
audit; eq "only a non-origin remote has it -> not counted" "$(V one)" B

echo "25b. live ref must be at the SAME sha; slash branch names"
fixture; mkwt one b1; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin b1 2>/dev/null )
git --git-dir="$BARE" update-ref refs/heads/b1 "$(git --git-dir="$BARE" rev-parse refs/heads/main)"
audit; eq "upstream branch rewound, stale tracking ref -> not A" "$(V one)" B
fixture; mkwt one feat/x; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin feat/x 2>/dev/null )
audit; eq "slash-named branch pushed and live -> A" "$(V one)" A
fixture; mkwt one a/b/c; age "$WT"; ( cd "$WT" && echo u > u.txt && git add u.txt && git commit -q -m u && git push -q origin a/b/c 2>/dev/null )
eq "precondition: a/b/c is live on origin at the worktree sha" "$(git -C "$REPO" ls-remote origin refs/heads/a/b/c | cut -f1)" "$(git -C "$WT" rev-parse HEAD)"
audit; eq "multi-level slash branch a/b/c pushed and live -> A" "$(V one)" A
# refs/remotes/origin/HEAD is excluded by an explicit guard, but a live ls-remote
# can never name a branch "HEAD" in practice, so the guard is redundant defence and
# has no cleanly observable effect; it is not separately pinned.

echo "26. near-miss names are not rebuildable"
fixture; mkwt one b1; age "$WT"; mkdir -p "$WT/packages/a/dist-evidence"; echo 1 > "$WT/packages/a/dist-evidence/x.log"
audit; eq "packages/a/dist-evidence -> B" "$(V one)" B
fixture; echo 'node_modules-old/' >> "$REPO/.git/info/exclude"; mkwt one b1; age "$WT"; mkdir -p "$WT/node_modules-old"; echo 1 > "$WT/node_modules-old/x"
audit; eq "node_modules-old -> B" "$(V one)" B

echo "27. --liveness lsof failures are reported"
fixture; mkwt one b1; age "$WT"
FAKE_LSOF_FAIL=1 audit --liveness lsof; eq "failing lsof: exit 2" "$RC" 2; eq "failing lsof: KEEP" "$(V one)" KEEP; has "liveness unknown" "$(R one)" "liveness unknown"
has "unverified names lsof" "$(q "' '.join(u['path'] for u in d['unverified'])")" lsof
NL="$T/nolsof"; mkdir -p "$NL"; ln -s "$REALGIT" "$NL/git"; ln -s "$FAKEBIN/gh" "$NL/gh"
OUT=$(PATH="$NL:/usr/bin-none" "$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --json --liveness lsof 2>/dev/null); RC=$?
eq "absent lsof: exit 2" "$RC" 2; eq "absent lsof: KEEP" "$(V one)" KEEP
OUT=$(PATH="$NL:/usr/bin-none" "$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --json 2>/dev/null); RC=$?
eq "absent lsof under auto: exit 0, KEEP" "$RC.$(V one)" "0.KEEP"

echo "28. inherited GIT_* variables are stripped"
fixture; mkwt one b1; age "$WT"
GIT_DIR=/nonexistent/bogus GIT_WORK_TREE=/nonexistent/wt GIT_INDEX_FILE=/nonexistent/idx audit
eq "bogus GIT_DIR/WORK_TREE/INDEX_FILE: same verdict" "$(V one).$RC" "A.0"

echo "29. linked worktree whose main checkout is outside every root"
fixture; OUTSIDE="$T/outside/main2"; mkdir -p "$OUTSIDE"; ( cd "$OUTSIDE" && git init -q -b main && echo 1 > f && git add f && git commit -q -m i && git worktree add -q -b bx "$ROOT/main2-x-20261101" )
age "$ROOT/main2-x-20261101"
audit; eq "outside main repo discovered" "$(q "any(r['path']=='$OUTSIDE' for r in d['repos'])")" True
eq "its worktree is listed" "$(q "sum(len(r['worktrees']) for r in d['repos'] if r['path']=='$OUTSIDE')")" 1
eq "repo not duplicated" "$(q "len([r for r in d['repos'] if r['path']=='$OUTSIDE'])")" 1

echo "30. notes and odd states"
fixture; mkwt one b1; age "$WT"
FAKE_GH_FAIL=1 audit; has "gh failure note" "$(q "' '.join(d['notes'])")" "gh calls failed: PR state unknown for 1 branch worktrees"; eq "gh failure: no exit change" "$RC" 0
OUT=$("$PY" "$SUT" --json --seed-dir "$SEEDS" 2>/dev/null); RC=$?
eq "absent default roots: exit 0" "$RC" 0; has "default roots note" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys;print(" ".join(json.load(sys.stdin)["notes"]))')" "default roots absent"
H=$("$PY" "$SUT" --seed-dir "$SEEDS" 2>&1); has "human default roots note" "$H" "default roots absent"
fixture; mkwt one b1; age "$WT"; git -C "$REPO" worktree lock "$WT"; mv "$WT" "$WT.gone"; rm -rf "$WT.gone"
audit; eq "locked + missing dir -> KEEP, not PRUNABLE" "$(V one)" KEEP; has "reason" "$(R one)" "locked"
fixture; mkwt one b1; age "$WT"; ln -s "$T/nope.md" "$SEEDS/NEXT-d.md"
audit; eq "dangling seed symlink: exit 2" "$RC" 2; eq "dangling seed symlink -> KEEP" "$(V one)" KEEP; has "reason" "$(R one)" "dangling symlink"
HU=$("$PY" - "$SUT" <<'PYS'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("wa", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
f = dict(path="/x/wt", branch="b", head=None, detached=False, locked=False, lock_reason="", lock_pid=None, missing=False, head_unreadable=True)
m.classify(f, 14); print(f["verdict"], f["reasons"][0])
PYS
)
eq "head unreadable -> KEEP, no crash" "$HU" "KEEP head unreadable"

echo "31. dangling .git file anywhere; relative gitdir"
fixture; mkwt one b1; age "$WT"; mkdir -p "$ROOT/sub/nodate"; echo "gitdir: /nonexistent/x" > "$ROOT/sub/nodate/.git"
audit; eq "undated nested orphan reported" "$(q "any(x['path'].endswith('sub/nodate') and 'missing repo' in x['note'] for x in d['leftovers'])")" True
eq "orphan REVIEW, exit 0" "$(q "[x['verdict'] for x in d['leftovers'] if x['path'].endswith('sub/nodate')]")|$RC" "['REVIEW']|0"
eq "not listed twice" "$(q "len(d['leftovers'])")" 1
fixture; mkwt one b1; age "$WT"; ADM=$(git -C "$WT" rev-parse --absolute-git-dir)
REL="$ROOT/rel-20261101"; mkdir -p "$REL"; echo "gitdir: ../repo/.git/worktrees/$(basename "$ADM")" > "$REL/.git"
( cd / && "$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --json > "$TMP/rel.json" 2>/dev/null )
eq "relative gitdir to a valid repo is not an orphan" "$("$PY" -c 'import json;print(len(json.load(open("'"$TMP"'/rel.json"))["leftovers"]))')" 0

echo "32. --write-cache: the only write; atomic, identical to --json, refused when unsafe (#435)"
fixture; mkwt one b1; age "$WT"; mkwt two b2; age "$WT"; echo c >> "$WT/a.txt"
CACHE="$TMP/cache32/state/worktree-audit.json"
B1=$(snap); audit --write-cache "$CACHE"; B2=$(snap)
eq "write-cache run: exit 0" "$RC" 0
eq "cache file written" "$([ -f "$CACHE" ] && echo yes)" yes
eq "cache equals the --json output byte for byte" "$(cat "$CACHE")" "$OUT"
eq "missing parent created mode 0700" "$("$PY" -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$(dirname "$CACHE")")" 0o700
eq "no temp files left beside the cache" "$(ls -A "$(dirname "$CACHE")")" "worktree-audit.json"
eq "fixture tree hash unchanged with --write-cache pointed outside it" "$B1" "$B2"
audit --write-cache "$CACHE"; eq "overwrite is atomic and identical again" "$(cat "$CACHE")" "$OUT"
OUT2=$("$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --write-cache "$CACHE" 2>/dev/null); RC=$?
has "human output combined with the cache" "$OUT2" "Summary:"; eq "human + cache exit 0" "$RC" 0
eq "cache is still JSON after a human-output run" "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"]["worktrees"])' "$CACHE")" 2
CD="$TMP/cache-env"; WORKTREE_AUDIT_CACHE="$CD/e.json" audit --write-cache
eq "bare --write-cache uses \$WORKTREE_AUDIT_CACHE" "$(cat "$CD/e.json")" "$OUT"
EH="$TMP/home-default"; mkdir -p "$EH"
OUT=$(env -u WORKTREE_AUDIT_CACHE HOME="$EH" "$PY" "$SUT" --root "$ROOT" --seed-dir "$SEEDS" --json --write-cache 2>/dev/null)
eq "bare --write-cache default is ~/.claude/state/worktree-audit.json" "$(cat "$EH/.claude/state/worktree-audit.json")" "$OUT"
# refusals: nothing written, exit 2, report still printed
INREPO="$REPO/inside.json"; audit --write-cache "$INREPO"
eq "inside the main working tree: exit 2" "$RC" 2; eq "inside the main working tree: absent" "$([ -e "$INREPO" ] && echo yes || echo no)" no
has "refusal named on stderr" "$ERR" "inside repository"; has "report still printed" "$(q "d['summary']['worktrees']")" 2
INWT="$WT/inside.json"; audit --write-cache "$INWT"
eq "inside a linked worktree: exit 2" "$RC" 2; eq "inside a linked worktree: absent" "$([ -e "$INWT" ] && echo yes || echo no)" no
INGIT="$REPO/.git/cache.json"; audit --write-cache "$INGIT"
eq "inside .git: exit 2" "$RC" 2; eq "inside .git: absent" "$([ -e "$INGIT" ] && echo yes || echo no)" no
ln -s "$REPO" "$TMP/repolink"; audit --write-cache "$TMP/repolink/viasymlinkdir.json"
eq "via a symlinked parent into the repo: exit 2" "$RC" 2; eq "via a symlinked parent: absent" "$([ -e "$REPO/viasymlinkdir.json" ] && echo yes || echo no)" no
audit --write-cache "$REPO/new/sub/x.json"
eq "nested missing dirs inside the repo are not created" "$([ -e "$REPO/new" ] && echo yes || echo no)" no
echo keep > "$TMP/target32"; ln -s "$TMP/target32" "$TMP/symcache.json"; audit --write-cache "$TMP/symcache.json"
eq "symlink path: exit 2" "$RC" 2; eq "symlink target untouched" "$(cat "$TMP/target32")" keep; has "symlink named" "$ERR" "symlink"
mkdir -p "$TMP/dircache"; audit --write-cache "$TMP/dircache"
eq "directory path: exit 2" "$RC" 2; has "directory named" "$ERR" "directory"
eq "failed write is listed in unverified" "$(q "any('cache not written' in u['reason'] for u in d['unverified'])")|$(q "d['summary']['unverified']")" "True|1"
if [ "$(id -u)" = 0 ]; then skip 3 "unwritable parent (root can write anywhere)"; else
  mkdir -p "$TMP/ro32"; chmod 555 "$TMP/ro32"; audit --write-cache "$TMP/ro32/c.json"
  eq "unwritable parent: exit 2" "$RC" 2; eq "unwritable parent: nothing written" "$(ls -A "$TMP/ro32")" ""
  has "write failure reported, not success" "$ERR" "cache not written"; chmod 755 "$TMP/ro32"
fi
printf 'old' > "$TMP/prior32.json"
audit --write-cache "$REPO/prior.json"; eq "refused write never touches an existing file elsewhere" "$(cat "$TMP/prior32.json")" old

echo "33. cache containment is by identity, not spelling (case-insensitive FS, aliases)"
fixture; mkwt one b1; age "$WT"
touch "$TMP/CaseProbe33"
if [ -e "$TMP/caseprobe33" ]; then
  UPPER="$ROOT/$(basename "$REPO" | tr a-z A-Z)"
  audit --write-cache "$UPPER/case.json"
  eq "case-variant path into the repo: exit 2" "$RC" 2; eq "case-variant path: file absent" "$([ -e "$REPO/case.json" ] && echo yes || echo no)" no
else
  skip 2 "case-variant cache path (case-sensitive filesystem)"
fi
ALIAS=$("$PY" - "$SUT" "$REPO" "$TMP/alias33" <<'PYS'
import importlib.util, os, sys, tempfile
sp = importlib.util.spec_from_file_location("wa", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
repo, alias = sys.argv[2], sys.argv[3]
os.symlink(repo, alias)
os.path.realpath = lambda p: p   # a filesystem whose realpath does not canonicalise (APFS case)
try:
    m.write_cache_file(os.path.join(alias, "x.json"), "{}", [repo]); print("WROTE")
except ValueError as e:
    print("refused" if "inside repository" in str(e) else "other:%s" % e)
PYS
)
eq "alias that string-compares differently is still refused by identity" "$ALIAS" refused
eq "alias write left nothing in the repo" "$([ -e "$REPO/x.json" ] && echo yes || echo no)" no

echo "24. gh was never given bad args anywhere in this run"
[ -e "$GH_MISMATCH" ] && bad "fake gh saw bad args during the suite" "$(cat "$GH_MISMATCH")" || ok "no gh mismatch recorded"

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -gt 0 ] && exit 1
TOTAL=$((pass + skipped))
if [ "$TOTAL" -lt "$EXPECTED_TOTAL" ]; then echo "FAIL: count too low: $TOTAL assertions accounted for, expected exactly $EXPECTED_TOTAL (zero-case guard)"; exit 1; fi
if [ "$TOTAL" -gt "$EXPECTED_TOTAL" ]; then echo "FAIL: count too high: $TOTAL assertions accounted for, expected exactly $EXPECTED_TOTAL; update EXPECTED_TOTAL (zero-case guard)"; exit 1; fi
if [ "$skipped" -gt "$MAX_SKIPPED" ]; then echo "FAIL: $skipped assertions skipped, at most $MAX_SKIPPED allowed"; exit 1; fi
exit 0
