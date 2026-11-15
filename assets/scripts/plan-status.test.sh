#!/usr/bin/env bash
# Tests for assets/scripts/plan-status.py (contract: docs/plan-lifecycle.md).
# Hermetic: every file lives in a temp dir, HOME and CLAUDE_PLAN_DIR point there,
# no network. Does NOT `set -e`: a failing assertion is reported and the rest run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
export TZ=UTC
SUT="$HERE/plan-status.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-status-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export CLAUDE_PLAN_DIR="$TMP/plans"; mkdir -p "$CLAUDE_PLAN_DIR"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
# expect_eq <name> <expected> <actual>
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in [$2]" ;; *) ok "$1" ;; esac; }
run() { "$PY" "$SUT" "$@"; }

mk() { # mk <name> <frontmatter-lines...>; body is fixed
  local f="$TMP/$1.md"; shift
  { echo '---'; for l in "$@"; do printf '%s\n' "$l"; done; echo '---'
    printf '# Plan\n\nBody text with  odd   spacing\t\nlast line, no newline'; } > "$f"
  echo "$f"
}

echo "plan-status.test.sh"

echo "== check"
f=$(mk good 'type: plan' 'status: in-delivery' 'status_updated: 2026-11-15T09:30Z')
out=$(run check "$f"); rc=$?
expect_eq "OK file exit 0" 0 "$rc"; expect_eq "OK line" "OK $f" "$out"

f=$(mk nostatus 'type: plan' 'status_updated: 2026-11-15T09:30Z')
out=$(run check "$f"); rc=$?
expect_eq "WARN does not change exit" 0 "$rc"; has "missing status" "$out" "WARN $f missing status"

f=$(mk badstatus 'type: plan' 'status: proposal-awaiting-owner-review' 'status_updated: 2026-11-15T09:30Z')
has "unknown status" "$(run check "$f")" "unknown status 'proposal-awaiting-owner-review'"

f=$(mk nots 'type: plan' 'status: accepted')
has "missing status_updated" "$(run check "$f")" "missing status_updated"

f=$(mk badts 'type: plan' 'status: accepted' 'status_updated: 2026-11-15')
has "malformed status_updated" "$(run check "$f")" "not YYYY-MM-DDTHH:MMZ"

f=$(mk nosup 'type: plan' 'status: superseded' 'status_updated: 2026-11-15T09:30Z')
has "superseded without superseded_by" "$(run check "$f")" "superseded_by is missing"
f=$(mk sup 'type: plan' 'status: superseded' 'status_updated: 2026-11-15T09:30Z' 'superseded_by: other-plan')
expect_eq "superseded with superseded_by OK" "OK $f" "$(run check "$f")"

f="$TMP/nofm.md"; printf '# no frontmatter\n' > "$f"
has "no frontmatter" "$(run check "$f")" "no frontmatter block"

# body stamp heuristic
f="$TMP/stale.md"
printf -- '---\ntype: plan\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n> **Update 2026-11-16T08:00Z** merged\n' > "$f"
has "stale vs timed stamp" "$(run check "$f")" "older than the newest body update 2026-11-16T08:00"
printf -- '---\ntype: plan\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n> **Update 2026-11-16** merged\n' > "$f"
has "stale vs date-only stamp" "$(run check "$f")" "older than the newest body update 2026-11-16"
printf -- '---\ntype: plan\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n> **Update 2026-11-15** same day\n> **Update 2026-11-15T09:30Z** equal\n' > "$f"
expect_eq "same-day and equal stamps are not stale" "OK $f" "$(run check "$f")"
printf -- '---\ntype: plan\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n```\n> **Update 2027-01-01** example\n```\nprose > **Update 2027-01-01** inline\n' > "$f"
expect_eq "stamps in fences or mid-line ignored" "OK $f" "$(run check "$f")"

out=$(run check "$TMP/absent.md" 2>&1); rc=$?
expect_eq "unreadable input exit 2" 2 "$rc"; has "unreadable names file" "$out" "absent.md"
run check >/dev/null 2>&1; expect_eq "check usage error exit 2" 2 "$?"
run bogus >/dev/null 2>&1; expect_eq "unknown subcommand exit 2" 2 "$?"

echo "== scan"
D="$TMP/scandir"; mkdir -p "$D"
printf -- '---\nstatus: proposal-awaiting-owner-review\n---\nlegacy\n' > "$D/legacy.md"
touch -t 202606010000 "$D/legacy.md"
printf -- '---\nstatus: draft-not-filed\ndate: 2026-05-01\n---\nlegacy dated\n' > "$D/legacy-dated.md"
touch -t 202606010000 "$D/legacy-dated.md"
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-20T00:00Z\n---\nnew\n' > "$D/new.md"
touch -t 202611200000 "$D/new.md"
printf -- '---\nstatus: wat\n---\nnew bad\n' > "$D/newbad.md"
touch -t 202611210000 "$D/newbad.md"
printf 'x\n' > "$D/notes.txt"
out=$(run scan --dir "$D"); rc=$?
expect_eq "scan exit 0 despite WARN" 0 "$rc"
hasnt "legacy excluded by default since" "$out" "legacy.md"
hasnt "legacy dated excluded" "$out" "legacy-dated.md"
has "new plan checked" "$out" "OK $D/new.md"
has "new bad plan warned" "$out" "WARN $D/newbad.md"
hasnt "non-md ignored" "$out" "notes.txt"
has "summary counts" "$out" "2 checked, 1 with warnings, 2 before 2026-11-15 skipped"
out=$(run scan --dir "$D" --since 2026-01-01)
has "--since widens" "$out" "WARN $D/legacy.md"
out=$(run scan --dir "$D" --since 2026-11-21)
hasnt "--since narrows" "$out" "new.md"; has "--since keeps newest" "$out" "newbad.md"
# date: later than an old mtime counts
printf -- '---\nstatus: wat\ndate: 2026-12-01\n---\nx\n' > "$D/datenew.md"; touch -t 202606010000 "$D/datenew.md"
has "date: frontmatter later than mtime is included" "$(run scan --dir "$D")" "WARN $D/datenew.md"
# env default dir
cp "$D/new.md" "$CLAUDE_PLAN_DIR/envplan.md"
has "default dir is CLAUDE_PLAN_DIR" "$(run scan)" "envplan.md"
run scan --dir "$TMP/nodir" >/dev/null 2>&1; expect_eq "missing dir exit 2" 2 "$?"
run scan --since notadate >/dev/null 2>&1; expect_eq "bad --since exit 2" 2 "$?"

echo "== set"
NOW=2026-11-15T10:00Z
f=$(mk s1 'type: plan' 'status: proposal' 'status_updated: 2026-11-14T00:00Z' 'tags: [a, b]')
cp "$f" "$TMP/s1.orig"
out=$(run set "$f" --status accepted --now $NOW); rc=$?
expect_eq "set success exit 0" 0 "$rc"
has "prints git add" "$out" "git -C "; has "prints add pathspec" "$out" "add -- s1.md"; has "prints commit" "$out" "commit -m"
expect_eq "status rewritten" "accepted" "$(sed -n 's/^status: //p' "$f")"
expect_eq "status_updated rewritten" "$NOW" "$(sed -n 's/^status_updated: //p' "$f")"
# byte-exact: only the status line changes (status_updated has the same length text here)
expect_eq "byte-exact result" "$(printf -- '---\ntype: plan\nstatus: accepted\nstatus_updated: %s\ntags: [a, b]\n---\n# Plan\n\nBody text with  odd   spacing\t\nlast line, no newline' "$NOW" | shasum | cut -c1-40)" "$(shasum < "$f" | cut -c1-40)"
expect_eq "no trailing newline preserved" "line" "$(tail -c 4 "$f" | tr -d '\n')"
[ -z "$(ls -a "$TMP" | grep '^\.plan-status\.')" ] && ok "no temp file left" || bad "temp file left"

run set "$f" --status in-delivery --now $NOW >/dev/null; expect_eq "accepted -> in-delivery" "in-delivery" "$(sed -n 's/^status: //p' "$f")"
run set "$f" --status proposal >/dev/null 2>&1; expect_eq "illegal in-delivery -> proposal exit 1" 1 "$?"
expect_eq "illegal transition leaves file" "in-delivery" "$(sed -n 's/^status: //p' "$f")"
run set "$f" --status delivered --now $NOW >/dev/null; expect_eq "in-delivery -> delivered" "delivered" "$(sed -n 's/^status: //p' "$f")"
run set "$f" --status accepted >/dev/null 2>&1; expect_eq "terminal -> accepted refused" 1 "$?"
run set "$f" --status abandoned >/dev/null 2>&1; expect_eq "delivered -> abandoned refused" 1 "$?"
run set "$f" --status superseded >/dev/null 2>&1; expect_eq "superseded without --superseded-by refused" 1 "$?"
expect_eq "refusal leaves status" "delivered" "$(sed -n 's/^status: //p' "$f")"
run set "$f" --status superseded --superseded-by "plans/next-plan.md" --now $NOW >/dev/null; expect_eq "terminal -> superseded ok" 0 "$?"
expect_eq "superseded_by inserted" "plans/next-plan.md" "$(sed -n 's/^superseded_by: //p' "$f")"
expect_eq "result passes check" "OK $f" "$(run check "$f")"

g=$(mk s2 'type: plan' 'status: proposal')
run set "$g" --status in-delivery >/dev/null 2>&1; expect_eq "proposal -> in-delivery refused" 1 "$?"
run set "$g" --status superseded --superseded-by x >/dev/null 2>&1; expect_eq "proposal -> superseded refused" 1 "$?"
run set "$g" --status accepted --superseded-by x >/dev/null 2>&1; expect_eq "--superseded-by with other status refused" 1 "$?"
run set "$g" --status bogus >/dev/null 2>&1; expect_eq "unknown status refused" 1 "$?"
run set "$g" --status accepted --now yesterday >/dev/null 2>&1; expect_eq "bad --now refused" 1 "$?"
run set "$g" --status accepted --decision 'bad id' >/dev/null 2>&1; expect_eq "bad decision id refused" 1 "$?"
run set "$g" --status accepted --decision DEC-1 --decision DEC-2 --now $NOW >/dev/null; expect_eq "decisions written" "[DEC-1, DEC-2]" "$(sed -n 's/^decisions: //p' "$g")"
expect_eq "status_updated inserted when absent" "$NOW" "$(sed -n 's/^status_updated: //p' "$g")"
run set "$g" --status in-delivery --decision DEC-2 --decision DEC-3 --now $NOW >/dev/null
expect_eq "decisions merged, no duplicates" "[DEC-1, DEC-2, DEC-3]" "$(sed -n 's/^decisions: //p' "$g")"
run set "$g" --status in-delivery --now $NOW >/dev/null; expect_eq "same status refreshes (exit 0)" 0 "$?"
expect_eq "decisions untouched without --decision" "[DEC-1, DEC-2, DEC-3]" "$(sed -n 's/^decisions: //p' "$g")"
b=$(mk s3 'type: plan' 'status: accepted' 'decisions:' '  - DEC-9' 'owner: me')
run set "$b" --status in-delivery --decision DEC-10 --now $NOW >/dev/null
expect_eq "block list extended in place" "$(printf -- '---\ntype: plan\nstatus: in-delivery\ndecisions:\n  - DEC-9\n  - DEC-10\nowner: me\nstatus_updated: %s\n---\n# Plan\n\nBody text with  odd   spacing\t\nlast line, no newline' "$NOW" | shasum | cut -c1-40)" "$(shasum < "$b" | cut -c1-40)"

# legacy free-text status may move to any status
for legacy in "proposal-awaiting-owner-review" "proposed — awaiting Chris's go on Phase 1" "draft-not-filed"; do
  l=$(mk legacy 'type: plan' "status: $legacy")
  run set "$l" --status delivered --now $NOW >/dev/null; rc=$?
  expect_eq "legacy '$legacy' -> delivered" "0:delivered" "$rc:$(sed -n 's/^status: //p' "$l")"
done
l=$(mk legacy2 'type: plan' 'title: no status key')
run set "$l" --status in-delivery --now $NOW >/dev/null; expect_eq "missing status key can be set" "in-delivery" "$(sed -n 's/^status: //p' "$l")"

# CRLF preserved
c="$TMP/crlf.md"; printf -- '---\r\nstatus: proposal\r\n---\r\nbody\r\n' > "$c"
run set "$c" --status accepted --now $NOW >/dev/null
expect_eq "CRLF preserved" 0 "$(tr -d '\r' < "$c" | wc -c | awk -v t="$(wc -c < "$c")" '{print ($1 + 5 == t) ? 0 : 1}')"
expect_eq "inserted key also CRLF" "status_updated: $NOW"$'\r' "$(grep '^status_updated' "$c")"

# refusals: missing file, no frontmatter
run set "$TMP/absent.md" --status accepted >/dev/null 2>&1; expect_eq "missing file refused exit 1" 1 "$?"
n="$TMP/nofm2.md"; printf '# nothing\n' > "$n"; cp "$n" "$n.orig"
run set "$n" --status accepted >/dev/null 2>&1; expect_eq "no frontmatter refused exit 1" 1 "$?"
cmp -s "$n" "$n.orig" && ok "no-frontmatter file untouched" || bad "no-frontmatter file modified"
run set "$g" >/dev/null 2>&1; expect_eq "set usage error exit 2" 2 "$?"

# mode preserved
m=$(mk mode 'status: proposal'); chmod 640 "$m"
run set "$m" --status accepted >/dev/null
expect_eq "file mode preserved" "640" "$("$PY" -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777)[2:])' "$m")"

echo "== strict subset, comments, CRLF, duplicates (round-1 regressions)"
sha() { shasum < "$1" | cut -c1-40; }
# refuse <name> <file> <set-args...>: exit 1 and the file is byte-identical afterwards
refuse() { local n=$1 fl=$2; shift 2; local b; b=$(sha "$fl"); run set "$fl" "$@" >/dev/null 2>&1; local rc=$?
  expect_eq "$n: refused exit 1" 1 "$rc"; expect_eq "$n: file untouched" "$b" "$(sha "$fl")"; }
# fixture <name> <exact bytes via printf format>
fixture() { printf -- "$2" > "$TMP/$1.md"; echo "$TMP/$1.md"; }
# expect_file <name> <file> <exact expected bytes via printf format>
expect_file() { local e="$TMP/expected.$$"; printf -- "$3" > "$e"; if cmp -s "$e" "$2"; then ok "$1"; else bad "$1" "$(diff "$e" "$2" | head -6 | tr '\n' '|')"; fi; }

# 1. inline comments
f=$(fixture c1 '---\nstatus: delivered # merged\nstatus_updated: 2026-11-15T09:30Z\n---\nb\n')
refuse "terminal with comment cannot skip the check" "$f" --status accepted
out=$(run check "$f"); expect_eq "comment stripped for check" "OK $f" "$out"
f=$(fixture c2 '---\nstatus: accepted # ok\nstatus_updated: 2026-11-15T09:30Z\n---\n')
expect_eq "no false WARN on a status comment" "OK $f" "$(run check "$f")"
f=$(fixture c3 '---\nstatus: superseded\nstatus_updated: 2026-11-15T09:30Z\nsuperseded_by:   # required when superseded\n---\n')
has "comment-only superseded_by is empty" "$(run check "$f")" "superseded_by is missing"
refuse "comment-only superseded_by does not satisfy set" "$f" --status superseded
f=$(fixture c4 '---\nstatus: proposal # why\nstatus_updated: 2026-11-14T00:00Z  # when\n---\nb\n')
run set "$f" --status accepted --now $NOW >/dev/null
expect_file "scalar rewrite keeps comment bytes" "$f" '---\nstatus: accepted # why\nstatus_updated: 2026-11-15T10:00Z  # when\n---\nb\n'
f=$(fixture c5 '---\nstatus: delivered\nstatus_updated: 2026-11-14T00:00Z\nsuperseded_by:   # who\n---\n')
run set "$f" --status superseded --superseded-by "plan-b" --now $NOW >/dev/null
expect_file "empty value with comment is filled, comment kept" "$f" '---\nstatus: superseded\nstatus_updated: 2026-11-15T10:00Z\nsuperseded_by: plan-b   # who\n---\n'

# 2. span detection
f=$(fixture s4 '---\nstatus: proposal\n  # indented note\nstatus_updated: 2026-11-14T00:00Z\n---\n')
refuse "indented comment after a key" "$f" --status accepted
f=$(fixture s5 '---\nstatus: accepted\ndecisions:\n  - DEC-1\n\n  - DEC-2\n---\n')
refuse "block list with a blank line" "$f" --status in-delivery --decision DEC-3
f=$(fixture s6 '---\nstatus: accepted\ndecisions:\n  - DEC-1\n  # note\n  - DEC-2\n---\n')
refuse "block list with a comment" "$f" --status in-delivery --decision DEC-3
f=$(fixture s7 '---\nstatus: accepted\ndecisions: [DEC-1,\n  DEC-2]\n---\n')
refuse "multi-line flow list" "$f" --status in-delivery --decision DEC-3
f=$(fixture s8 '---\nstatus: accepted\ndecisions: [[DEC-1]]\n---\n')
refuse "nested brackets" "$f" --status in-delivery --decision DEC-3
f=$(fixture s9 '---\nstatus: accepted\ndecisions: DEC-1\n---\n')
refuse "scalar decisions" "$f" --status in-delivery --decision DEC-3
f=$(fixture s10 '---\nstatus: accepted\nstatus_updated: 2026-11-14T00:00Z\ndecisions: [DEC-42]  # optional\n---\n')
run set "$f" --status in-delivery --decision DEC-43 --now $NOW >/dev/null
expect_file "flow list: trailing comment kept after the list" "$f" '---\nstatus: in-delivery\nstatus_updated: 2026-11-15T10:00Z\ndecisions: [DEC-42, DEC-43]  # optional\n---\n'
f=$(fixture s11 '---\nstatus: accepted\ndecisions: []\n---\n')
run set "$f" --status in-delivery --decision DEC-1 --now $NOW >/dev/null
expect_file "empty flow list" "$f" '---\nstatus: in-delivery\ndecisions: [DEC-1]\nstatus_updated: 2026-11-15T10:00Z\n---\n'
f=$(fixture s12 '---\nstatus: accepted\ndecisions:\nowner: me\n---\n')
run set "$f" --status in-delivery --decision DEC-1 --now $NOW >/dev/null
expect_file "empty decisions key" "$f" '---\nstatus: in-delivery\ndecisions: [DEC-1]\nowner: me\nstatus_updated: 2026-11-15T10:00Z\n---\n'
f=$(fixture s13 '---\nstatus: accepted\nstatus_notes: keep me\n---\nstatus report: not a key\n')
run set "$f" --status in-delivery --now $NOW >/dev/null
expect_file "similar keys and body lines untouched" "$f" '---\nstatus: in-delivery\nstatus_notes: keep me\nstatus_updated: 2026-11-15T10:00Z\n---\nstatus report: not a key\n'
f=$(fixture s14 '---\nstatus: proposal\n  more\n---\n')
refuse "multi-line scalar status" "$f" --status accepted
f=$(fixture bom "\xef\xbb\xbf---\nstatus: proposal\n---\n")
refuse "BOM before frontmatter" "$f" --status accepted
has "check reports BOM" "$(run check "$f")" "BOM"

# 3. CRLF
f=$(fixture crlf2 '---\r\nstatus: accepted\r\ndecisions:\r\nowner: me\r\n---\r\nb\r\n')
run set "$f" --status in-delivery --decision DEC-1 --now $NOW >/dev/null
expect_file "CRLF empty decisions: no duplicate key" "$f" '---\r\nstatus: in-delivery\r\ndecisions: [DEC-1]\r\nowner: me\r\nstatus_updated: 2026-11-15T10:00Z\r\n---\r\nb\r\n'
f=$(fixture crlf3 '---\r\nstatus: accepted\r\ndecisions:\r\n  - DEC-1\r\n---\r\n')
run set "$f" --status in-delivery --decision DEC-2 --now $NOW >/dev/null
expect_file "CRLF block list" "$f" '---\r\nstatus: in-delivery\r\ndecisions:\r\n  - DEC-1\r\n  - DEC-2\r\nstatus_updated: 2026-11-15T10:00Z\r\n---\r\n'
f=$(fixture crlf4 '---\r\nstatus: accepted # ok\r\nstatus_updated: 2026-11-15T09:30Z\r\n---\r\n')
expect_eq "CRLF comment value parses" "OK $f" "$(run check "$f")"

# 4. duplicate lifecycle keys
f=$(fixture dup '---\nstatus: proposal\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n')
has "check warns on duplicate key" "$(run check "$f")" "duplicate key 'status'"
refuse "set refuses duplicate keys" "$f" --status accepted

# 5. lost update (a writer changes the file between read and rename)
f=$(fixture lost '---\nstatus: proposal\n---\n'); cp "$f" "$f.orig"
out=$("$PY" - "$SUT" "$f" <<'PYEOF' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
real = os.fsync
def racing(fd):
    real(fd)
    with open(sys.argv[2], "a") as h: h.write("concurrent edit\n")
os.fsync = racing
print("rc=%s" % ps.main(["set", sys.argv[2], "--status", "accepted"]))
PYEOF
)
has "lost update refused" "$out" "rc=1"
expect_eq "concurrent edit survives" "concurrent edit" "$(tail -1 "$f")"
expect_eq "no temp left after lost update" 0 "$(ls -a "$TMP" | grep -c '^\.plan-status\.' || true)"

# 6. fences
f="$TMP/fence1.md"
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n```\n~~~\n> **Update 2027-01-01** inside\n```\n' > "$f"
expect_eq "tilde line inside a backtick fence does not close it" "OK $f" "$(run check "$f")"
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n````\n```\n> **Update 2027-01-01** inside\n````\n' > "$f"
expect_eq "3-backtick line inside a 4-backtick fence does not close it" "OK $f" "$(run check "$f")"
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n```\ncode\n```\n> **Update 2027-01-01** after\n' > "$f"
has "stamp after a closed fence counts" "$(run check "$f")" "older than the newest body update 2027-01-01"

# 7. malformed stamps
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n> **Update 2026-11-20T08:00Z** real\n> **Update 2026-99-99** junk\n> **Update 2027-01-01T25:00Z** junk\n' > "$f"
out=$(run check "$f")
has "malformed stamps do not hide a valid one" "$out" "newest body update 2026-11-20T08:00"
printf -- '---\nstatus: accepted\nstatus_updated: 2026-11-15T09:30Z\n---\n> **Update 2026-99-99** junk\n' > "$f"
expect_eq "malformed stamp alone is ignored" "OK $f" "$(run check "$f")"

# 8. scan since / enumeration errors
run scan --dir "$D" --since 2026-99-99 >/dev/null 2>&1; expect_eq "impossible calendar date exit 2" 2 "$?"
if [ "$(id -u)" != 0 ]; then
  P="$TMP/locked"; mkdir "$P"; chmod 000 "$P"
  out=$(run scan --dir "$P" 2>&1); rc=$?; chmod 755 "$P"
  expect_eq "unlistable dir exit 2" 2 "$rc"; has "ERROR names the dir" "$out" "ERROR $P"; hasnt "no traceback" "$out" "Traceback"
fi

# 9. --superseded-by whitespace
f=$(fixture ws '---\nstatus: accepted\n---\n')
refuse "whitespace-only --superseded-by" "$f" --status superseded --superseded-by "   "

# 10. read-only file
if [ "$(id -u)" != 0 ]; then
  f=$(fixture ro '---\nstatus: proposal\n---\n'); chmod 444 "$f"
  refuse "read-only plan" "$f" --status accepted
  chmod 644 "$f"
fi

# snapshots: check and scan never modify their inputs
SN=$(for x in "$D"/*.md "$TMP"/c1.md "$TMP"/dup.md; do shasum < "$x"; done | shasum)
run check "$TMP"/c1.md "$TMP"/dup.md >/dev/null; run scan --dir "$D" --since 2026-01-01 >/dev/null
expect_eq "check and scan leave inputs byte-identical" "$SN" "$(for x in "$D"/*.md "$TMP"/c1.md "$TMP"/dup.md; do shasum < "$x"; done | shasum)"

echo "== atomic write"
a=$(mk atomic 'status: proposal'); cp "$a" "$a.orig"
out=$("$PY" - "$SUT" "$a" <<'PYEOF' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
def boom(*a, **k): raise OSError(28, "No space left on device")
os.replace = boom
rc = ps.main(["set", sys.argv[2], "--status", "accepted"])
print("rc=%s" % rc)
PYEOF
)
has "failed rename reports refusal exit 1" "$out" "rc=1"
cmp -s "$a" "$a.orig" && ok "original intact after failed rename" || bad "original changed after failed rename"
left=$(ls -a "$TMP" | grep -c '^\.plan-status\.' || true)
expect_eq "temp file cleaned after failure" 0 "$left"
# same-dir temp: observed via the temp name used
out=$("$PY" - "$SUT" "$a" <<'PYEOF' 2>&1
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
seen = []
orig = os.replace
def spy(src, dst): seen.append(os.path.dirname(src) == os.path.dirname(os.path.realpath(dst))); return orig(src, dst)
os.replace = spy
ps.main(["set", sys.argv[2], "--status", "accepted"])
print("samedir=%s" % seen)
PYEOF
)
has "temp file lives in the target dir" "$out" "samedir=[True]"

echo "== set never runs git"
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho git-was-called >> "%s/git.called"\nexit 99\n' "$TMP" > "$FAKE/git"; chmod +x "$FAKE/git"
gg=$(mk nogit 'status: proposal')
PATH="$FAKE:$PATH" run set "$gg" --status accepted >/dev/null 2>&1; rc=$?
expect_eq "set succeeds with failing git on PATH" 0 "$rc"
[ ! -e "$TMP/git.called" ] && ok "fake git never invoked" || bad "git was invoked"
grep -n "subprocess\|os\.system\|os\.popen\|import git" "$SUT" >/dev/null && bad "script imports process execution" || ok "script has no process execution"

echo
echo "plan-status.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
