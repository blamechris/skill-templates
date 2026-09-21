#!/usr/bin/env bash
# Regression tests for assets/scripts/rework-lag.py.
#
# The fixture is a real git repo: each "PR" is one commit, and mergedAt/
# closingIssuesReferences/etc. are supplied by a fake `gh` on PATH that
# answers from JSON files this script writes and logs every invocation (so
# --no-issues can be asserted by absence in the log, not by inference). Real
# `git show`/`git log` run against the fixture's real commits — only `gh` is
# faked. mergedAt is independent of the commits' own timestamps (gh's field,
# not git's), which is what lets one small fixture repo host PRs at whatever
# days-apart spacing each test case needs.
#
# set -uo pipefail, no -e: several cases are "the REFUSE fired and nothing
# else happened", and a failed assertion must not abort the rest of the suite.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/rework-lag.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rework-lag-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

echo "rework-lag.test.sh"

# =========================================================================
# 1. Fake `gh`, on PATH first.
# =========================================================================
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
FAKE_GH_DIR="$TMP/gh-fixtures"
mkdir -p "$FAKE_GH_DIR"
GH_LOG="$TMP/gh.log"
: > "$GH_LOG"
export FAKE_GH_DIR GH_LOG

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh for rework-lag.test.sh: logs every invocation, answers from fixed
# JSON files in $FAKE_GH_DIR, and exits 1 on anything unmocked so a case that
# reaches an unmocked call fails visibly instead of silently returning "{}".
set -u
echo "$*" >> "$GH_LOG"

fail_flag() { [ -f "$FAKE_GH_DIR/$1" ]; }

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  fail_flag fail_pr_list && { echo "fake gh: pr list forced failure" >&2; exit 1; }
  cat "$FAKE_GH_DIR/pr_list.json"
  exit 0
fi

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  fail_flag fail_repo_view && { echo "fake gh: repo view forced failure" >&2; exit 1; }
  cat "$FAKE_GH_DIR/repo_view.txt"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  n="${3:-}"
  fail_flag "fail_pr_view_$n" && { echo "fake gh: pr view $n forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/pr_view_$n.json"
  if [ -f "$f" ]; then cat "$f"; else echo '{"closingIssuesReferences":[]}'; fi
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  fail_flag fail_issue_list && { echo "fake gh: issue list forced failure" >&2; exit 1; }
  cat "$FAKE_GH_DIR/issue_list.json"
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  path="${2:-}"
  n=$(echo "$path" | sed -E 's#.*/issues/([0-9]+)/timeline#\1#')
  fail_flag "fail_timeline_$n" && { echo "fake gh: timeline $n forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/timeline_$n.json"
  if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
  exit 0
fi

echo "fake gh: unexpected invocation: $*" >&2
exit 1
SH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

echo "acme/widgets" > "$FAKE_GH_DIR/repo_view.txt"

# =========================================================================
# 2. Fixture git repo: one commit per "PR". mergedAt lives only in
#    pr_list.json, decoupled from the commits' own timestamps.
# =========================================================================
FIXTURE="$TMP/fixture-repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email t@t
git -C "$FIXTURE" config user.name t

sha_of() { git -C "$FIXTURE" rev-parse HEAD; }

# --- baseline (not a PR) ---
cat > "$FIXTURE/a.py" <<'EOF'
def base():
    return 1
EOF
git -C "$FIXTURE" add a.py
git -C "$FIXTURE" commit -q -m "baseline a.py"

# --- PR101/102: case 1, added-then-removed rework pair ---
cat >> "$FIXTURE/a.py" <<'EOF'
    unique_marker_line_pr101_added_this_line_here = True
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR101: add marker line"
PR101_SHA=$(sha_of)

sed -i.bak '/unique_marker_line_pr101_added_this_line_here/d' "$FIXTURE/a.py"; rm -f "$FIXTURE/a.py.bak"
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR102: remove marker line"
PR102_SHA=$(sha_of)

# --- PR103/104: case 2, same file, disjoint lines -- must NOT be rework ---
cat >> "$FIXTURE/a.py" <<'EOF'
    another_unique_marker_line_added_by_pr103_xyz = 2
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR103: add marker line"
PR103_SHA=$(sha_of)

cat >> "$FIXTURE/a.py" <<'EOF'
    yet_another_completely_different_marker_line_pr104 = 3
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR104: add a different marker line to the same file"
PR104_SHA=$(sha_of)

# --- PR105/106: case 3, trivial + comment-prefixed lines, excluded even when removed later ---
cat >> "$FIXTURE/a.py" <<'EOF'
    x=1
    # this is a comment line that is fairly long but is still a comment
    // not python but still a slash comment style line for the test
    * bullet-style comment prefix line included for the same test
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR105: add trivial/comment lines"
PR105_SHA=$(sha_of)

sed -i.bak \
  -e '/    x=1$/d' \
  -e '/this is a comment line that is fairly long/d' \
  -e '/not python but still a slash comment style line/d' \
  -e '/bullet-style comment prefix line included/d' \
  "$FIXTURE/a.py"
rm -f "$FIXTURE/a.py.bak"
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR106: remove trivial/comment lines"
PR106_SHA=$(sha_of)

# --- PR107/108: case 4, windows (10 days apart) ---
cat >> "$FIXTURE/a.py" <<'EOF'
    windows_test_marker_line_pr107_unique_content_here = 4
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR107: add marker line"
PR107_SHA=$(sha_of)

sed -i.bak '/windows_test_marker_line_pr107_unique_content_here/d' "$FIXTURE/a.py"; rm -f "$FIXTURE/a.py.bak"
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR108: remove marker line 10 days later"
PR108_SHA=$(sha_of)

# --- PR109: case 5, immature (merged 2 days before --until, never reworked) ---
cat >> "$FIXTURE/a.py" <<'EOF'
    maturity_test_marker_line_pr109_content_unique = 5
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR109: add marker line (stays immature)"
PR109_SHA=$(sha_of)

# --- PR110/111: case 5 (clean at first --until) + case 6 (reworked once --until moves) ---
cat >> "$FIXTURE/a.py" <<'EOF'
    maturity_test_marker_line_pr110_content_unique = 6
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR110: add marker line (clean, then reworked later)"
PR110_SHA=$(sha_of)

sed -i.bak '/maturity_test_marker_line_pr110_content_unique/d' "$FIXTURE/a.py"; rm -f "$FIXTURE/a.py.bak"
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR111: rework PR110, merged after the first --until"
PR111_SHA=$(sha_of)

# --- PR112/113: case 7, revert by message ---
cat > "$FIXTURE/b.py" <<'EOF'
def helper():
    revert_test_marker_line_pr112_added_content_here = True
    return revert_test_marker_line_pr112_added_content_here
EOF
git -C "$FIXTURE" add b.py; git -C "$FIXTURE" commit -q -m "PR112: add helper with marker line"
PR112_SHA=$(sha_of)

sed -i.bak '/revert_test_marker_line_pr112_added_content_here/d' "$FIXTURE/b.py"; rm -f "$FIXTURE/b.py.bak"
git -C "$FIXTURE" add b.py
git -C "$FIXTURE" commit -q -m "Revert \"PR112: add helper with marker line\"

This reverts commit $PR112_SHA."
PR113_SHA=$(sha_of)

# --- baseline + PR114/115: case 8a, revert by full inversion, no revert message ---
cat > "$FIXTURE/c.py" <<'EOF'
def marker():
    inversion_test_line_alpha_content_marker = 1
EOF
git -C "$FIXTURE" add c.py; git -C "$FIXTURE" commit -q -m "baseline c.py with alpha line"

sed -i.bak 's/inversion_test_line_alpha_content_marker = 1/inversion_test_line_beta_content_marker = 2/' "$FIXTURE/c.py"
rm -f "$FIXTURE/c.py.bak"
git -C "$FIXTURE" add c.py; git -C "$FIXTURE" commit -q -m "PR114: swap alpha line for beta line"
PR114_SHA=$(sha_of)

sed -i.bak 's/inversion_test_line_beta_content_marker = 2/inversion_test_line_alpha_content_marker = 1/' "$FIXTURE/c.py"
rm -f "$FIXTURE/c.py.bak"
git -C "$FIXTURE" add c.py; git -C "$FIXTURE" commit -q -m "PR115: swap back to alpha (full inversion, no revert wording)"
PR115_SHA=$(sha_of)

# --- PR117/118: case 8b, partial undo -- rework, but NOT inversion ---
cat > "$FIXTURE/d.py" <<'EOF'
def two_lines():
    partial_undo_test_marker_line_X1_content_here = 1
    partial_undo_test_marker_line_X2_content_here = 2
EOF
git -C "$FIXTURE" add d.py; git -C "$FIXTURE" commit -q -m "PR117: add two marker lines"
PR117_SHA=$(sha_of)

sed -i.bak '/partial_undo_test_marker_line_X1_content_here/d' "$FIXTURE/d.py"; rm -f "$FIXTURE/d.py.bak"
git -C "$FIXTURE" add d.py; git -C "$FIXTURE" commit -q -m "PR118: remove only X1 (partial undo of PR117)"
PR118_SHA=$(sha_of)

# --- PR119/120: equality-not-subset -- later PR removes ALL of the earlier
# PR's added lines but ALSO adds an unrelated non-trivial line in the same
# file -- rework (the removed line matches), but NOT a revert, because the
# later diff is not the exact inverse of the earlier one (subset would wrongly
# flag this; equality correctly rejects it). ---
cat > "$FIXTURE/e.py" <<'EOF'
def marker():
    equality_test_marker_line_pr119_content_here = 1
EOF
git -C "$FIXTURE" add e.py; git -C "$FIXTURE" commit -q -m "PR119: add marker line"
PR119_SHA=$(sha_of)

sed -i.bak '/equality_test_marker_line_pr119_content_here/d' "$FIXTURE/e.py"
cat >> "$FIXTURE/e.py" <<'EOF'
    equality_test_marker_line_pr120_extra_content_added_here = 2
EOF
rm -f "$FIXTURE/e.py.bak"
git -C "$FIXTURE" add e.py
git -C "$FIXTURE" commit -q -m "PR120: remove PR119's marker AND add an unrelated line (not a clean revert)"
PR120_SHA=$(sha_of)

# --- PR130: C1 -- a TRUE two-parent merge commit. Default `git show` for a
# merge is `--cc` (compact combined) and comes back EMPTY the instant the
# merge introduces no conflict against either parent -- --diff-merges=first-
# parent (or the -m --first-parent fallback) is required to see the change
# at all. PR131 (later, ordinary single-parent commit) removes that line. ---
cat > "$FIXTURE/m.py" <<'EOF'
def base():
    return 1
EOF
git -C "$FIXTURE" add m.py; git -C "$FIXTURE" commit -q -m "baseline m.py"
git -C "$FIXTURE" checkout -q -b branch-c1
cat >> "$FIXTURE/m.py" <<'EOF'
    merge_commit_test_marker_line_pr130_content_here = 1
EOF
git -C "$FIXTURE" add m.py; git -C "$FIXTURE" commit -q -m "branch-c1: add marker line"
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" merge --no-ff -q -m "Merge branch 'branch-c1'" branch-c1
PR130_SHA=$(sha_of)
git -C "$FIXTURE" branch -q -D branch-c1

# Meta-test on the fixture itself: PR130 must genuinely be a two-parent merge
# commit, or the whole C1 case is testing nothing. `rev-list --parents -n1`
# prints "<commit> <parent1> <parent2> ..." on one line.
PARENT_COUNT=$(($(git -C "$FIXTURE" rev-list --parents -n1 "$PR130_SHA" | wc -w) - 1))
[ "$PARENT_COUNT" -eq 2 ] && ok "fixture sanity: PR130 is a genuine two-parent merge commit" \
  || bad "fixture sanity: PR130 is a genuine two-parent merge commit" "parent count=$PARENT_COUNT"

sed -i.bak '/merge_commit_test_marker_line_pr130_content_here/d' "$FIXTURE/m.py"; rm -f "$FIXTURE/m.py.bak"
git -C "$FIXTURE" add m.py; git -C "$FIXTURE" commit -q -m "PR131: remove PR130's marker line"
PR131_SHA=$(sha_of)

# --- PR124/125/126: C2 -- deleted-file lines must key to the file's OWN
# path, never to whatever file the PREVIOUS diff block happened to be. PR124
# adds a file that PR126 later deletes outright; PR125 adds the EXACT SAME
# line text to a.py (a different file) that PR126 never touches. Diffs sort
# alphabetically, so a.py's block precedes zfile2.py's block in PR126's own
# diff -- exactly the ordering the original bug needed to mis-key zfile2's
# removed line onto a.py and manufacture a false pair against PR125. ---
cat > "$FIXTURE/zfile2.py" <<'EOF'
def marker():
    delete_file_test_marker_line_shared_text_content_here = 1
EOF
git -C "$FIXTURE" add zfile2.py; git -C "$FIXTURE" commit -q -m "PR124: add zfile2.py with marker line"
PR124_SHA=$(sha_of)

cat >> "$FIXTURE/a.py" <<'EOF'
    delete_file_test_marker_line_shared_text_content_here = 1
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR125: add the SAME line text to a.py (different file)"
PR125_SHA=$(sha_of)

cat >> "$FIXTURE/a.py" <<'EOF'
    modify_plus_delete_test_unrelated_extra_line_here = 2
EOF
git -C "$FIXTURE" rm -q zfile2.py
git -C "$FIXTURE" add a.py
git -C "$FIXTURE" commit -q -m "PR126: modify a.py AND delete zfile2.py in the same commit"
PR126_SHA=$(sha_of)

# --- PR127: C2 -- a delete-ONLY commit (no other file touched). ---
cat > "$FIXTURE/delfile.py" <<'EOF'
def marker():
    delete_only_test_marker_line_content_here = 1
EOF
git -C "$FIXTURE" add delfile.py; git -C "$FIXTURE" commit -q -m "PR128: add delfile.py"
PR128_SHA=$(sha_of)

git -C "$FIXTURE" rm -q delfile.py
git -C "$FIXTURE" commit -q -m "PR129: delete delfile.py (delete-only commit)"
PR129_SHA=$(sha_of)

# --- PR132/133: C2 -- rename + drop one line. Git's default rename
# detection (50% similarity) picks this up as a rename: `--- a/rfile_old.py`
# / `+++ b/rfilenew.py` with only the dropped line shown -- removed lines
# must key to the OLD path for the earlier PR's added lines to match. ---
printf 'rename_test_marker_line_R1_content_here = 1\nrename_test_marker_line_R2_content_here = 2\n' > "$FIXTURE/rfile_old.py"
git -C "$FIXTURE" add rfile_old.py; git -C "$FIXTURE" commit -q -m "PR132: add rfile_old.py with two marker lines"
PR132_SHA=$(sha_of)

git -C "$FIXTURE" mv rfile_old.py rfilenew.py
sed -i.bak '/rename_test_marker_line_R2_content_here/d' "$FIXTURE/rfilenew.py"; rm -f "$FIXTURE/rfilenew.py.bak"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "PR133: rename rfile_old.py -> rfilenew.py, dropping R2"
PR133_SHA=$(sha_of)

# --- PR140/141: S4(a) -- union-of-files in inversion. PR140/141 exactly
# invert file g.py (a genuine two-line swap), but PR141 ALSO touches an
# unrelated file h.py -- must NOT be flagged as a revert (touching a file the
# earlier PR never touched breaks the exact-inverse requirement), while still
# being ordinary rework on g.py. ---
cat > "$FIXTURE/g.py" <<'EOF'
def marker():
    union_test_line_alpha_content_marker = 1
EOF
git -C "$FIXTURE" add g.py; git -C "$FIXTURE" commit -q -m "baseline g.py with alpha line"

sed -i.bak 's/union_test_line_alpha_content_marker = 1/union_test_line_beta_content_marker = 2/' "$FIXTURE/g.py"
rm -f "$FIXTURE/g.py.bak"
git -C "$FIXTURE" add g.py; git -C "$FIXTURE" commit -q -m "PR140: swap alpha line for beta line in g.py"
PR140_SHA=$(sha_of)

sed -i.bak 's/union_test_line_beta_content_marker = 2/union_test_line_alpha_content_marker = 1/' "$FIXTURE/g.py"
rm -f "$FIXTURE/g.py.bak"
cat > "$FIXTURE/h.py" <<'EOF'
def unrelated():
    union_test_unrelated_line_in_a_different_file_here = 3
EOF
git -C "$FIXTURE" add g.py h.py
git -C "$FIXTURE" commit -q -m "PR141: swap back to alpha in g.py, AND touch an unrelated file h.py"
PR141_SHA=$(sha_of)

# --- PR142/143: S4(b) -- window inclusivity. Exactly 7 days apart (not
# 6.99, not 7.01): must land IN window 7. ---
cat >> "$FIXTURE/a.py" <<'EOF'
    boundary_test_marker_line_pr142_content_unique_here = 9
EOF
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR142: add marker line"
PR142_SHA=$(sha_of)

sed -i.bak '/boundary_test_marker_line_pr142_content_unique_here/d' "$FIXTURE/a.py"; rm -f "$FIXTURE/a.py.bak"
git -C "$FIXTURE" add a.py; git -C "$FIXTURE" commit -q -m "PR143: remove marker line exactly 7 days later"
PR143_SHA=$(sha_of)

# --- PR180/181: round-2 CRITICAL -- a REMOVED content line starting with
# `-- ` (a SQL comment) reads, once diffed, as `--- a sql comment...`, byte-
# for-byte matching a `--- ` header. PR180 adds a .sql file with such a
# comment line PLUS a real statement line; PR181 deletes the file outright,
# removing both. Both must be keyed to queries.sql, not to a bogus path built
# from the comment's own text (which is what a bare `startswith("--- ")`
# with no in-hunk gate does). ---
printf -- '-- this is a sql comment line that is quite long\nselect real_column_name_one from some_table_name;\n' > "$FIXTURE/queries.sql"
git -C "$FIXTURE" add queries.sql; git -C "$FIXTURE" commit -q -m "PR180: add queries.sql with a comment line and a statement line"
PR180_SHA=$(sha_of)

git -C "$FIXTURE" rm -q queries.sql
git -C "$FIXTURE" commit -q -m "PR181: delete queries.sql outright"
PR181_SHA=$(sha_of)

# --- PR182/183: round-2 CRITICAL, add-side mirror -- an ADDED content line
# starting with `++ ` reads, once diffed, as `+++ a counter...`, matching a
# `+++ ` header the same way. ---
printf '++ counter_increment_style_test_marker_line_here\ncounter_real_statement_line_that_is_also_long_enough\n' > "$FIXTURE/plusplus.txt"
git -C "$FIXTURE" add plusplus.txt; git -C "$FIXTURE" commit -q -m "PR182: add plusplus.txt with a ++-prefixed line and a statement line"
PR182_SHA=$(sha_of)

git -C "$FIXTURE" rm -q plusplus.txt
git -C "$FIXTURE" commit -q -m "PR183: delete plusplus.txt outright"
PR183_SHA=$(sha_of)

# --- PR190/191: round-2 SUGGESTION (a) -- a quoted, C-escaped non-ASCII
# path. `core.quotePath` is set explicitly (true is git's own default, but
# explicit keeps this deterministic regardless of the environment's config)
# so `--- "a/wei\303\237.txt"` is reproduced exactly, every time. ---
git -C "$FIXTURE" config core.quotePath true
printf 'quoted_path_test_marker_line_baseline_content_here = 1\n' > "$FIXTURE/weiß.txt"
git -C "$FIXTURE" add "weiß.txt"; git -C "$FIXTURE" commit -q -m "PR190: add wei\xc3\x9f.txt with a marker line"
PR190_SHA=$(sha_of)

git -C "$FIXTURE" rm -q "weiß.txt"
git -C "$FIXTURE" commit -q -m "PR191: delete wei\xc3\x9f.txt outright"
PR191_SHA=$(sha_of)

# =========================================================================
# 3. Timestamps: BASE=day0, all PR mergedAt values are offsets from it.
#    --since is day0 itself (strict `since < mergedAt` excludes nothing here).
# =========================================================================
iso() { "$PY" -c "import datetime,sys; print((datetime.datetime(2026,1,1,tzinfo=datetime.timezone.utc)+datetime.timedelta(days=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

SINCE=$(iso 0)
UNTIL0=$(iso 100)   # first --until: excludes PR111 (day 105), pr109 immature, pr110 clean
UNTIL2=$(iso 110)   # second --until: includes PR111 -- pr110 flips to reworked

D_PR101=$(iso 1);  D_PR102=$(iso 4)
D_PR103=$(iso 6);  D_PR104=$(iso 7)
D_PR105=$(iso 8);  D_PR106=$(iso 9)
D_PR107=$(iso 10); D_PR108=$(iso 20)
D_PR109=$(iso 98)
D_PR110=$(iso 60); D_PR111=$(iso 105)
D_PR112=$(iso 30); D_PR113=$(iso 32)
D_PR114=$(iso 40); D_PR115=$(iso 43)
D_PR117=$(iso 50); D_PR118=$(iso 52)
D_PR119=$(iso 44); D_PR120=$(iso 46)
D_PR130=$(iso 70); D_PR131=$(iso 73)
D_PR124=$(iso 74); D_PR125=$(iso 75); D_PR126=$(iso 76)
D_PR128=$(iso 77); D_PR129=$(iso 78)
D_PR132=$(iso 79); D_PR133=$(iso 80)
D_PR140=$(iso 81); D_PR141=$(iso 82)
D_PR142=$(iso 83); D_PR143=$(iso 90)
D_PR180=$(iso 84); D_PR181=$(iso 85)
D_PR182=$(iso 86); D_PR183=$(iso 87)
D_PR190=$(iso 88); D_PR191=$(iso 89)
D_PR150=$(iso 200)  # C3: unreadable -- bad/nonexistent sha; AFTER UNTIL0 so it never
                     # pollutes the main (UNTIL0) run -- exercised in its own dedicated run

"$PY" - "$FAKE_GH_DIR/pr_list.json" <<PYEOF
import json
prs = [
    (101, "PR101: add marker line", "$D_PR101", "$PR101_SHA", ""),
    (102, "PR102: remove marker line", "$D_PR102", "$PR102_SHA", ""),
    (103, "PR103: add marker line", "$D_PR103", "$PR103_SHA", ""),
    (104, "PR104: add a different marker line to the same file", "$D_PR104", "$PR104_SHA", ""),
    (105, "PR105: add trivial/comment lines", "$D_PR105", "$PR105_SHA", ""),
    (106, "PR106: remove trivial/comment lines", "$D_PR106", "$PR106_SHA", ""),
    (107, "PR107: add marker line", "$D_PR107", "$PR107_SHA", ""),
    (108, "PR108: remove marker line 10 days later", "$D_PR108", "$PR108_SHA", ""),
    (109, "PR109: add marker line (stays immature)", "$D_PR109", "$PR109_SHA", ""),
    (110, "PR110: add marker line (clean, then reworked later)", "$D_PR110", "$PR110_SHA", ""),
    (111, "PR111: rework PR110, merged after the first --until", "$D_PR111", "$PR111_SHA", ""),
    (112, "PR112: add helper with marker line", "$D_PR112", "$PR112_SHA", ""),
    (113, 'Revert "PR112: add helper with marker line"', "$D_PR113", "$PR113_SHA", "This reverts commit $PR112_SHA."),
    (114, "PR114: swap alpha line for beta line", "$D_PR114", "$PR114_SHA", ""),
    (115, "PR115: swap back to alpha (full inversion, no revert wording)", "$D_PR115", "$PR115_SHA", ""),
    (117, "PR117: add two marker lines", "$D_PR117", "$PR117_SHA", ""),
    (118, "PR118: remove only X1 (partial undo of PR117)", "$D_PR118", "$PR118_SHA", ""),
    (119, "PR119: add marker line", "$D_PR119", "$PR119_SHA", ""),
    (120, "PR120: remove PR119's marker AND add an unrelated line (not a clean revert)", "$D_PR120", "$PR120_SHA", ""),
    (130, "PR130: merge branch-c1 (true two-parent merge commit)", "$D_PR130", "$PR130_SHA", ""),
    (131, "PR131: remove PR130's marker line", "$D_PR131", "$PR131_SHA", ""),
    (124, "PR124: add zfile2.py with marker line", "$D_PR124", "$PR124_SHA", ""),
    (125, "PR125: add the SAME line text to a.py (different file)", "$D_PR125", "$PR125_SHA", ""),
    (126, "PR126: modify a.py AND delete zfile2.py in the same commit", "$D_PR126", "$PR126_SHA", ""),
    (128, "PR128: add delfile.py", "$D_PR128", "$PR128_SHA", ""),
    (129, "PR129: delete delfile.py (delete-only commit)", "$D_PR129", "$PR129_SHA", ""),
    (132, "PR132: add rfile_old.py with two marker lines", "$D_PR132", "$PR132_SHA", ""),
    (133, "PR133: rename rfile_old.py -> rfilenew.py, dropping R2", "$D_PR133", "$PR133_SHA", ""),
    (140, "PR140: swap alpha line for beta line in g.py", "$D_PR140", "$PR140_SHA", ""),
    (141, "PR141: swap back to alpha in g.py, AND touch an unrelated file h.py", "$D_PR141", "$PR141_SHA", ""),
    (142, "PR142: add marker line", "$D_PR142", "$PR142_SHA", ""),
    (143, "PR143: remove marker line exactly 7 days later", "$D_PR143", "$PR143_SHA", ""),
    (180, "PR180: add queries.sql with a comment line and a statement line", "$D_PR180", "$PR180_SHA", ""),
    (181, "PR181: delete queries.sql outright", "$D_PR181", "$PR181_SHA", ""),
    (182, "PR182: add plusplus.txt with a ++-prefixed line and a statement line", "$D_PR182", "$PR182_SHA", ""),
    (183, "PR183: delete plusplus.txt outright", "$D_PR183", "$PR183_SHA", ""),
    (190, "PR190: add a quoted non-ASCII filename with a marker line", "$D_PR190", "$PR190_SHA", ""),
    (191, "PR191: delete that non-ASCII file outright", "$D_PR191", "$PR191_SHA", ""),
    (150, "PR150: unreadable -- bad sha", "$D_PR150", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", ""),
]
out = [{"number": n, "title": t, "mergedAt": m, "mergeCommit": {"oid": sha}, "body": b}
       for (n, t, m, sha, b) in prs]
json.dump(out, open("$FAKE_GH_DIR/pr_list.json", "w"))
PYEOF

# --- issue fixtures: reopened issues (case 9) ---
D_ISSUE=$(iso 2)          # createdAt for follow-on issues, after --since
D_REOPEN_501=$(iso 15)    # after PR101's mergedAt (day1) -> reopened, listed
D_REOPEN_501B=$(iso 16)   # a SECOND reopened event for the same (issue, pr) -- dedup test
D_REOPEN_502=$(iso 2)     # before PR102's mergedAt (day4) -> not listed
D_REOPEN_503=$(iso 150)   # AFTER UNTIL0 (day100) -> not listed (S(b): <= until_dt bound)

echo '{"closingIssuesReferences":[{"number":501}]}' > "$FAKE_GH_DIR/pr_view_101.json"
echo '{"closingIssuesReferences":[{"number":502}]}' > "$FAKE_GH_DIR/pr_view_102.json"
echo '{"closingIssuesReferences":[{"number":503}]}' > "$FAKE_GH_DIR/pr_view_103.json"
# Two "reopened" events for the SAME (issue, closed_by_pr) pair -- both pass
# the bound check, so this pins the dedup: exactly one record must come out,
# not two, for the same pairing.
"$PY" - "$FAKE_GH_DIR/timeline_501.json" "$D_REOPEN_501" "$D_REOPEN_501B" <<'PYEOF'
import json, sys
json.dump([{"event": "reopened", "created_at": sys.argv[2]},
           {"event": "reopened", "created_at": sys.argv[3]}], open(sys.argv[1], "w"))
PYEOF
"$PY" - "$FAKE_GH_DIR/timeline_502.json" "$D_REOPEN_502" <<'PYEOF'
import json, sys
json.dump([{"event": "reopened", "created_at": sys.argv[2]}], open(sys.argv[1], "w"))
PYEOF
"$PY" - "$FAKE_GH_DIR/timeline_503.json" "$D_REOPEN_503" <<'PYEOF'
import json, sys
json.dump([{"event": "reopened", "created_at": sys.argv[2]}], open(sys.argv[1], "w"))
PYEOF

# --- issue fixtures: follow-on closure (case 10) + S1 (--until bounds) ---
D_ISSUE_CLOSED=$(iso 3)         # closedAt, within the UNTIL0 window
D_ISSUE_CLOSED_LATE=$(iso 150)  # closedAt AFTER --until -- not yet confirmed closed as of --until
D_ISSUE_CREATED_LATE=$(iso 150) # createdAt AFTER --until -- must be excluded entirely

"$PY" - "$FAKE_GH_DIR/issue_list.json" "$D_ISSUE" "$D_ISSUE_CLOSED" "$D_ISSUE_CLOSED_LATE" "$D_ISSUE_CREATED_LATE" <<'PYEOF'
import json, sys
d, closed, closed_late, created_late = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
issues = [
    {"number": 601, "state": "OPEN", "createdAt": d, "closedAt": None,
     "body": "## Context\nFiled from: #101\n\nsome open follow-on"},
    {"number": 602, "state": "CLOSED", "createdAt": d, "closedAt": closed,
     "body": "## Context\nFiled from: #101\n\nsome closed follow-on"},
    {"number": 603, "state": "OPEN", "createdAt": d, "closedAt": None,
     "body": "## Context\nFiled from: none\n\nstandalone, not attributed"},
    # S1: closed AFTER --until -- gh reports CLOSED (current state), but as of
    # --until this cannot be confirmed closed, so it must land in "open".
    {"number": 604, "state": "CLOSED", "createdAt": d, "closedAt": closed_late,
     "body": "## Context\nFiled from: #101\n\nclosed after --until"},
    # S1: created AFTER --until -- must be excluded from follow_ons entirely,
    # not merely bucketed -- an issue that could not have been known about at
    # --until must not appear at all.
    {"number": 605, "state": "OPEN", "createdAt": created_late, "closedAt": None,
     "body": "## Context\nFiled from: #101\n\ncreated after --until"},
]
json.dump(issues, open(sys.argv[1], "w"))
PYEOF

# =========================================================================
# helpers
# =========================================================================
flat() { printf '%s' "$1" | tr '\n' '|'; }

run() {  # run <extra rework-lag.py args...>  -- sets out/rc, resets gh log
  : > "$GH_LOG"
  out=$("$PY" "$SUT" --repo "$FIXTURE" "$@" 2>&1); rc=$?
}
run_split() {  # like run but keeps stdout/stderr separate in $sout/$serr
  : > "$GH_LOG"
  sout=$("$PY" "$SUT" --repo "$FIXTURE" "$@" 2>"$TMP/stderr"); rc=$?
  serr=$(cat "$TMP/stderr")
}

# =========================================================================
# GROUP A -- main run: cases 1-5, 7, 8, 9, 10, 14 (JSON)
# =========================================================================
echo; echo "A. main run (line matching, windows, maturity, reverts, issues)"

run_split --since "$SINCE" --until "$UNTIL0" --json
[ "$rc" -eq 0 ] && ok "main run exits 0" || bad "main run exits 0" "rc=$rc out=$(flat "$sout") err=$(flat "$serr")"
echo "$sout" > "$TMP/main.json"
"$PY" - "$TMP/main.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

ok = True
def check(name, cond):
    global ok
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        ok = False

check("prs == 37", d["prs"] == 37)

w7 = d["windows"]["7"]; w30 = d["windows"]["30"]; wall = d["windows"]["all"]

# case 1: 101->102 added-then-removed, in reworked, right lines/files
p = next((p for p in w7["pairs"] if p["earlier"] == 101 and p["later"] == 102), None)
check("case1: 101 in reworked (window 7)", 101 in w7["reworked"])
check("case1: pair 101->102 present with lines=1", p is not None and p["lines"] == 1)
check("case1: pair 101->102 files == ['a.py']", p is not None and p["files"] == ["a.py"])

# case 2: 103/104 touch the same file, disjoint lines -- neither is reworked, anywhere
check("case2: 103 never reworked (7)", 103 not in w7["reworked"])
check("case2: 103 never reworked (30)", 103 not in w30["reworked"])
check("case2: 103 never reworked (all)", 103 not in wall["reworked"])
check("case2: 104 never reworked (all)", 104 not in wall["reworked"])

# case 3: trivial/comment lines excluded even when removed later
check("case3: 105 never reworked (all)", 105 not in wall["reworked"])

# case 4: windows -- 107/108 are 10 days apart: in 30 and all, not in 7
check("case4: 107 reworked in 30", 107 in w30["reworked"])
check("case4: 107 reworked in all", 107 in wall["reworked"])
check("case4: 107 NOT reworked in 7", 107 not in w7["reworked"])

# case 5: maturity -- 109 immature at 7 and 30 (merged 2 days before --until,
# never reworked); 110 clean at both (merged 40 days before --until, not yet
# reworked as of this --until)
check("case5: 109 immature at 7", 109 in w7["immature"])
check("case5: 109 immature at 30", 109 in w30["immature"])
check("case5: 109 not clean at 7 or 30", 109 not in w7["clean"] and 109 not in w30["clean"])
check("case5: 110 clean at 7", 110 in w7["clean"])
check("case5: 110 clean at 30", 110 in w30["clean"])

# case 7: revert by message, 112 -> 113
rev = {(r["earlier"], r["later"]): r["kind"] for r in d["reverts"]}
check("case7: (112,113) reverts as 'message'", rev.get((112, 113)) == "message")
check("case7: 112 in reworked (all) exactly once (set semantics)",
      wall["reworked"].count(112) == 1)

# case 8a: revert by full inversion, 114 -> 115, no revert wording
check("case8a: (114,115) reverts as 'inversion'", rev.get((114, 115)) == "inversion")

# case 8b: partial undo, 117 -> 118 -- rework but NOT inversion, NOT in reverts
check("case8b: 117 reworked (all)", 117 in wall["reworked"])
check("case8b: (117,118) NOT in reverts", (117, 118) not in rev)

# case 8c: FIX 1 -- equality, not subset. 119 -> 120 removes ALL of 119's
# added lines but ALSO adds an unrelated line in the same file: rework
# (the removed line still matches), but the later diff is not the exact
# inverse of the earlier one, so it must NOT be flagged as a revert.
check("case8c: 119 reworked (all)", 119 in wall["reworked"])
check("case8c: (119,120) NOT in reverts (equality, not subset)", (119, 120) not in rev)

# C1: a TRUE two-parent merge commit (PR130) must still be readable and its
# added line still matched against PR131's removal -- the default --cc diff
# would read this as 0 files, 0 lines, no error, and PR130 would silently
# never appear reworked.
check("C1: PR130 (merge commit) reworked (all)", 130 in wall["reworked"])
p130 = next((p for p in wall["pairs"] if p["earlier"] == 130 and p["later"] == 131), None)
check("C1: pair 130->131 present with lines=1, files=['m.py']",
      p130 is not None and p130["lines"] == 1 and p130["files"] == ["m.py"])

# C2: deleted-file lines key to their OWN path, never to the previous file in
# the same diff. PR124 (added zfile2.py) must be reworked; PR125 (added the
# SAME text to a.py, a file PR126 never removes anything from) must NOT be --
# the old bug would key zfile2's removed line onto a.py (the alphabetically-
# earlier block in the same commit) and manufacture a false pair on PR125.
check("C2: PR124 (zfile2.py's adder) reworked (all) -- deleted file keyed to its own path",
      124 in wall["reworked"])
check("C2: PR125 (a.py's adder, same text, different file) NOT reworked -- no false pair",
      125 not in wall["reworked"])

# C2: delete-only commit (PR128 added delfile.py, PR129 deletes it outright).
check("C2: PR128 (delete-only target) reworked (all)", 128 in wall["reworked"])

# C2: rename + drop one line. PR132 added two lines to rfile_old.py; PR133
# renames it to rfilenew.py and drops one of them -- removed lines must key
# to the OLD path for this match to be found at all.
check("C2: PR132 (renamed file's adder) reworked (all) -- matched against the OLD path",
      132 in wall["reworked"])

# S4(a): union-of-files in inversion. PR140/141 exactly invert g.py, but
# PR141 ALSO touches an unrelated file h.py -- must be rework (g.py matches)
# but NOT a revert (h.py has no PR140 counterpart, breaking the exact-inverse
# requirement). Mutation this catches: `set(Ha) | set(Hb)` -> `set(Ha)` alone
# would only ever check g.py and wrongly flag this as an inversion.
check("S4a: PR140 reworked (all)", 140 in wall["reworked"])
check("S4a: (140,141) NOT in reverts (union-of-files)", (140, 141) not in rev)

# S4(b): window inclusivity. PR142/143 are EXACTLY 7 days apart -- must be
# counted IN window 7 (mutation `<=` -> `<` would exclude an exact boundary).
check("S4b: PR142 reworked in window 7 (exactly 7 days apart, boundary inclusive)",
      142 in w7["reworked"])

# ROUND 2 CRITICAL: a REMOVED line starting with `-- ` (SQL comment) reads,
# once diffed, as `--- ...`, byte-for-byte matching a `--- ` header. PR180
# adds queries.sql with such a line plus a real statement; PR181 deletes the
# file outright. Both lines must be keyed to queries.sql -- a bare
# startswith("--- ") test with no in-hunk gate steals the statement line by
# mis-keying it under a bogus path built from the comment's own text.
p180 = next((p for p in wall["pairs"] if p["earlier"] == 180 and p["later"] == 181), None)
check("round2 CRITICAL: PR180 (sql comment collision) reworked (all)", 180 in wall["reworked"])
check("round2 CRITICAL: pair 180->181 lines=2, files=['queries.sql'] (both lines correctly keyed)",
      p180 is not None and p180["lines"] == 2 and p180["files"] == ["queries.sql"])

# Mirror on the ADD side: a line starting with `++ ` reads as `+++ ` once
# diffed and added.
p182 = next((p for p in wall["pairs"] if p["earlier"] == 182 and p["later"] == 183), None)
check("round2 CRITICAL: PR182 (++ collision, add side) reworked (all)", 182 in wall["reworked"])
check("round2 CRITICAL: pair 182->183 lines=2, files=['plusplus.txt']",
      p182 is not None and p182["lines"] == 2 and p182["files"] == ["plusplus.txt"])

# S(a): a quoted, C-escaped non-ASCII path (`--- "a/wei\303\237.txt"`) must be
# unquoted and unescaped to the real filename before the prefix test, or the
# add/remove pair on the same file lands under two different bogus keys.
p190 = next((p for p in wall["pairs"] if p["earlier"] == 190 and p["later"] == 191), None)
check("Sa: PR190 (quoted non-ASCII path) reworked (all)", 190 in wall["reworked"])
check("Sa: pair 190->191 files == ['weiß.txt'] (correctly unquoted/unescaped)",
      p190 is not None and p190["files"] == ["weiß.txt"])

# case 9: reopened issues -- 501 listed (reopened after mergedAt), 502 not
reop = {r["issue"]: r for r in d["reopened_issues"]}
check("case9: issue 501 listed as reopened", 501 in reop and reop[501]["closed_by_pr"] == 101)
check("case9: issue 502 NOT listed (reopened before mergedAt)", 502 not in reop)

# S(b): the reopened-issue measure is bounded on --until too -- an event
# after --until must not be listed, the same as an event before mergedAt.
check("Sb: issue 503 NOT listed (reopened AFTER --until)", 503 not in reop)

# S(b): dedup on (issue, closed_by_pr) -- issue 501's timeline carries TWO
# valid reopened events for the same (501, 101) pairing; exactly one record
# must survive, not two.
reop_501_records = [r for r in d["reopened_issues"] if r["issue"] == 501 and r["closed_by_pr"] == 101]
check("Sb: two reopened events for the same (issue, pr) -> exactly one record",
      len(reop_501_records) == 1)

# case 10: follow-on closure
fo = d["follow_ons"].get("101", {"open": [], "closed": []})
check("case10: follow-on 601 open under #101", 601 in fo["open"])
check("case10: follow-on 602 closed under #101 (closedAt within --until)", 602 in fo["closed"])
check("case10: follow-on 603 (Filed from: none) not attributed anywhere",
      all(603 not in b["open"] and 603 not in b["closed"] for b in d["follow_ons"].values()))

# S1: --until bounds on follow-on closure
check("S1: follow-on 604 (closedAt AFTER --until) bucketed open, not closed",
      604 in fo["open"] and 604 not in fo["closed"])
check("S1: follow-on 605 (createdAt AFTER --until) excluded entirely",
      605 not in fo["open"] and 605 not in fo["closed"])

check("no unknown[] in a clean run", d["unknown"] == [])

sys.exit(0 if ok else 1)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] && ok "GROUP A: all JSON assertions" || bad "GROUP A: all JSON assertions" "see above"

# case 14a: --json output is valid JSON (already proven by the parse above)
ok "case14: --json output parses as JSON"

# case 14b: human mode prints the immature count
run --since "$SINCE" --until "$UNTIL0"
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'immature' \
  && ok "case14: human mode prints an immature count" \
  || bad "case14: human mode prints an immature count" "rc=$rc $(flat "$out")"

# =========================================================================
# GROUP B -- case 6: --until reproducibility (excludes/includes PR111)
# =========================================================================
echo; echo "B. --until reproducibility"

run --since "$SINCE" --until "$UNTIL0" --json
d1="$out"
run --since "$SINCE" --until "$UNTIL2" --json
d2="$out"
echo "$d1" > "$TMP/run1.json"
echo "$d2" > "$TMP/run2.json"

"$PY" - "$TMP/run1.json" "$TMP/run2.json" <<'PY'
import json, sys

def summarize(path):
    d = json.load(open(path))
    return {"prs": d["prs"], "reworked_all": sorted(d["windows"]["all"]["reworked"])}

before = summarize(sys.argv[1])
after = summarize(sys.argv[2])
ok = True
def check(name, cond):
    global ok
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        ok = False
check("--until excludes PR111 at UNTIL0: prs=37", before["prs"] == 37)
check("--until includes PR111 at UNTIL2: prs=38", after["prs"] == 38)
check("PR110 not reworked (all) before PR111 exists", 110 not in before["reworked_all"])
check("PR110 reworked (all) once PR111 exists (reproducible acceptance mechanism)",
      110 in after["reworked_all"])
sys.exit(0 if ok else 1)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] && ok "GROUP B: --until changes the PR set and the reworked set reproducibly" \
  || bad "GROUP B: --until changes the PR set and the reworked set reproducibly" "see above"

# =========================================================================
# GROUP B2 -- S4(c): --since is STRICT. A PR merged EXACTLY AT --since must
# be excluded (mutation `<` -> `<=` on the PR filter must fail this).
# =========================================================================
echo; echo "B2. --since strict exclusion (S4c)"

run --since "$D_PR101" --until "$UNTIL0" --json
[ "$rc" -eq 0 ] && ok "since-equals-PR101's-mergedAt run exits 0" \
  || bad "since-equals-PR101's-mergedAt run exits 0" "rc=$rc $(flat "$out")"
printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert 101 not in d["pr_numbers"], d["pr_numbers"]' \
  && ok "S4c: a PR merged EXACTLY AT --since is excluded" \
  || bad "S4c: a PR merged EXACTLY AT --since is excluded" "$(flat "$out")"

# =========================================================================
# GROUP C0 -- C3: a PR whose diff cannot be read lands in `unreadable`, is
# NEVER counted as `clean`, and its failure is named in unknown[] (exit 2).
# Kept in its own run (a wide --until, PR150 has a bad/nonexistent sha) so it
# does not poison the "no unknown[] in a clean run" assertion in Group A.
# =========================================================================
echo; echo "C0. unreadable diff (C3)"

run_split --since "$SINCE" --until "$D_PR150" --no-issues --json
[ "$rc" -eq 2 ] && ok "a PR with an unreadable diff -> exit 2" \
  || bad "a PR with an unreadable diff -> exit 2" "rc=$rc"
echo "$sout" > "$TMP/unreadable.json"
"$PY" - "$TMP/unreadable.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = True
def check(name, cond):
    global ok
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        ok = False
check("C3: unknown[] names PR150's diff failure",
      any("diff for #150" in u for u in d["unknown"]))
for w in ("7", "30", "all"):
    wd = d["windows"][w]
    check(f"C3: PR150 in windows.{w}.unreadable", 150 in wd["unreadable"])
    check(f"C3: PR150 NOT in windows.{w}.clean (mutation: deleting the unknown.append call)",
          150 not in wd["clean"])
    check(f"C3: PR150 NOT in windows.{w}.immature either", 150 not in wd["immature"])
    check(f"C3: PR150 NOT in windows.{w}.reworked", 150 not in wd["reworked"])
sys.exit(0 if ok else 1)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] && ok "GROUP C0: unreadable bucket is disjoint from clean, and the failure is named" \
  || bad "GROUP C0: unreadable bucket is disjoint from clean, and the failure is named" "$(cat "$TMP/unreadable.json")"

# Human mode: an unreadable PR must never be silently folded into "clean".
run --since "$SINCE" --until "$D_PR150" --no-issues
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unreadable' \
  && ok "C3: human mode prints an unreadable count" \
  || bad "C3: human mode prints an unreadable count" "rc=$rc $(flat "$out")"

# =========================================================================
# GROUP C2 -- S3: revert-by-title must use a word-boundary match, not a bare
# substring test ("#12" must not match inside "#123").
# =========================================================================
echo; echo "C2. revert-by-title word boundary (S3)"

git -C "$FIXTURE" checkout -q main
cat > "$FIXTURE/s3.py" <<'EOF'
def marker():
    word_boundary_test_marker_line_pr160_content_here = 1
EOF
git -C "$FIXTURE" add s3.py; git -C "$FIXTURE" commit -q -m "PR12: add marker line"
PR12_SHA=$(sha_of)
git -C "$FIXTURE" commit -q --allow-empty -m 'Revert "#123 some unrelated title"'
PR160_SHA=$(sha_of)

D_PR12=$(iso 92); D_PR160=$(iso 93)
"$PY" - "$FAKE_GH_DIR/pr_list.json" "$D_PR12" "$PR12_SHA" "$D_PR160" "$PR160_SHA" <<'PYEOF'
import json, sys
path, d12, sha12, d160, sha160 = sys.argv[1:6]
prs = json.load(open(path))
prs.append({"number": 12, "title": "PR12: add marker line", "mergedAt": d12,
            "mergeCommit": {"oid": sha12}, "body": ""})
prs.append({"number": 123, "title": "PR123: unrelated", "mergedAt": d12,
            "mergeCommit": {"oid": sha12}, "body": ""})
prs.append({"number": 160, "title": 'Revert "#123 some unrelated title"', "mergedAt": d160,
            "mergeCommit": {"oid": sha160}, "body": ""})
json.dump(prs, open(path, "w"))
PYEOF

run --since "$SINCE" --until "$D_PR160" --no-issues --json
[ "$rc" -eq 0 ] && ok "S3 fixture run exits 0" || bad "S3 fixture run exits 0" "rc=$rc $(flat "$out")"
printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); rev={(r["earlier"],r["later"]) for r in d["reverts"]}; assert (12,160) not in rev, rev' \
  && ok "S3: title \`Revert \"#123 ...\"\` does not revert PR #12 (word boundary)" \
  || bad "S3: title \`Revert \"#123 ...\"\` does not revert PR #12 (word boundary)" "$(flat "$out")"

# =========================================================================
# GROUP C3 -- S(b): follow-on truncation signal. `gh issue list` returning
# EXACTLY the --limit (500) rows must land a "possibly truncated" entry in
# unknown[] -- an untruncated real list never gets anywhere near 500 in this
# fixture, so this needs its own swapped-in fixture.
# =========================================================================
echo; echo "C3. follow-on truncation signal (Sb)"

cp "$FAKE_GH_DIR/issue_list.json" "$TMP/issue_list.json.orig"
"$PY" - "$FAKE_GH_DIR/issue_list.json" "$D_ISSUE" <<'PYEOF'
import json, sys
d = sys.argv[2]
# Exactly 500 -- the FOLLOWON_LIST_LIMIT constant -- none of them referencing
# any PR, so the only thing this run should produce is the truncation entry.
issues = [{"number": 700 + i, "state": "OPEN", "createdAt": d, "closedAt": None,
           "body": "## Context\nFiled from: none\n\npadding"} for i in range(500)]
json.dump(issues, open(sys.argv[1], "w"))
PYEOF

run_split --since "$SINCE" --until "$UNTIL0" --json
[ "$rc" -eq 2 ] && ok "gh issue list returning exactly --limit -> exit 2" \
  || bad "gh issue list returning exactly --limit -> exit 2" "rc=$rc"
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert any("follow-ons possibly truncated" in u for u in d["unknown"]), d["unknown"]' \
  && ok "Sb: unknown[] carries a 'follow-ons possibly truncated' entry" \
  || bad "Sb: unknown[] carries a 'follow-ons possibly truncated' entry" "$(flat "$sout")"

cp "$TMP/issue_list.json.orig" "$FAKE_GH_DIR/issue_list.json"

# =========================================================================
# GROUP C4 -- PR-list truncation signal (Copilot review on #276). `gh pr list`
# truncates silently at --limit, and a saturated list means older merged PRs
# inside [since, until] were never considered -- which would read as clean or
# immature, the silent-zero shape rejected everywhere else. Passing --limit
# equal to the fixture's own row count makes the list saturated without
# touching the fixture; the default limit must NOT trip it.
# =========================================================================
echo; echo "C4. PR-list truncation signal"

NPRS=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$FAKE_GH_DIR/pr_list.json")
run_split --since "$SINCE" --until "$UNTIL0" --json --no-issues --limit "$NPRS"
[ "$rc" -eq 2 ] && ok "gh pr list returning exactly --limit -> exit 2" \
  || bad "gh pr list returning exactly --limit -> exit 2" "rc=$rc"
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert any("PR list possibly truncated" in u for u in d["unknown"]), d["unknown"]; assert d["prs"] > 0' \
  && ok "C4: unknown[] carries a 'PR list possibly truncated' entry and the JSON is still emitted" \
  || bad "C4: unknown[] carries a 'PR list possibly truncated' entry and the JSON is still emitted" "$(flat "$sout")"
run_split --since "$SINCE" --until "$UNTIL0" --json --no-issues
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert not any("PR list possibly truncated" in u for u in d["unknown"]), d["unknown"]' \
  && ok "C4: default --limit does not trip the truncation signal" \
  || bad "C4: default --limit does not trip the truncation signal" "$(flat "$sout")"

# =========================================================================
# GROUP C -- case 11: gh failures
# =========================================================================
echo; echo "C. gh failures"

touch "$FAKE_GH_DIR/fail_timeline_501"
run_split --since "$SINCE" --until "$UNTIL0" --json
[ "$rc" -eq 2 ] && ok "a gh failure on one measure -> exit 2" \
  || bad "a gh failure on one measure -> exit 2" "rc=$rc"
echo "$sout" > "$TMP/fail1.json"
"$PY" - "$TMP/fail1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = True
def check(name, cond):
    global ok
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        ok = False
check("JSON still emitted on a partial gh failure", isinstance(d, dict))
check("the failing measure (timeline #501) is named in unknown[]",
      any("501" in u for u in d["unknown"]))
check("windows/reworked is still computed despite the unrelated gh failure",
      101 in d["windows"]["7"]["reworked"])
sys.exit(0 if ok else 1)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] && ok "gh failure: JSON still has the rest, names the failed measure" \
  || bad "gh failure: JSON still has the rest, names the failed measure" "$(cat "$TMP/fail1.json")"
rm -f "$FAKE_GH_DIR/fail_timeline_501"

touch "$FAKE_GH_DIR/fail_pr_list"
run_split --since "$SINCE" --until "$UNTIL0" --json
[ "$rc" -eq 2 ] && ok "gh pr list failure -> exit 2" || bad "gh pr list failure -> exit 2" "rc=$rc"
printf '%s' "$sout" | "$PY" -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1
if [ $? -ne 0 ]; then
  ok "gh pr list failure -> no JSON on stdout"
else
  bad "gh pr list failure -> no JSON on stdout" "stdout parsed as JSON: $(flat "$sout")"
fi
rm -f "$FAKE_GH_DIR/fail_pr_list"

# =========================================================================
# GROUP D -- case 12: --no-issues makes no pr-view/issue-list calls
# =========================================================================
echo; echo "D. --no-issues"

run --since "$SINCE" --until "$UNTIL0" --no-issues --json
[ "$rc" -eq 0 ] && ok "--no-issues run exits 0" || bad "--no-issues run exits 0" "rc=$rc $(flat "$out")"
if grep -Eq '^pr view |^issue list ' "$GH_LOG"; then
  bad "--no-issues makes no pr-view/issue-list calls" "log: $(cat "$GH_LOG")"
else
  ok "--no-issues makes no pr-view/issue-list calls"
fi
printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["reopened_issues"]==[]; assert d["follow_ons"]=={}' \
  && ok "--no-issues: reopened_issues/follow_ons are empty, not omitted" \
  || bad "--no-issues: reopened_issues/follow_ons are empty, not omitted" "$(flat "$out")"

# =========================================================================
# GROUP E -- case 13: --attribute
# =========================================================================
echo; echo "E. --attribute"

FAKEHOME="$TMP/fakehome"
PROJDIR="$FAKEHOME/.claude/projects/-fake-proj"
mkdir -p "$PROJDIR"

D_T0_IN=$(iso 0.5); D_T1_IN=$(iso 1.5)     # spans PR101's mergedAt (day 1)
D_T0_OUT=$(iso 50);  D_T1_OUT=$(iso 51)    # nowhere near it

jsonl_line() { "$PY" -c "import json,sys; print(json.dumps({'type':'user','message':{'content':[{'type':'text','text':sys.argv[1]}]},'timestamp':sys.argv[2]}))" "$1" "$2"; }
jsonl_line_no_ts() { "$PY" -c "import json,sys; print(json.dumps({'type':'user','message':{'content':[{'type':'text','text':sys.argv[1]}]}}))" "$1"; }

{ jsonl_line "session aaaaaaaa: landed #101 today" "$D_T0_IN"; \
  jsonl_line "session aaaaaaaa: wrapping up" "$D_T1_IN"; } > "$PROJDIR/aaaaaaaa-full-id.jsonl"

{ jsonl_line "session bbbbbbbb: just chatting, nothing filed" "$D_T0_IN"; \
  jsonl_line "session bbbbbbbb: still nothing" "$D_T1_IN"; } > "$PROJDIR/bbbbbbbb-full-id.jsonl"

{ jsonl_line "session cccccccc: landed #101 today too" "$D_T0_OUT"; \
  jsonl_line "session cccccccc: wrapping up" "$D_T1_OUT"; } > "$PROJDIR/cccccccc-full-id.jsonl"

{ jsonl_line "session dddddddd: also shipped #101" "$D_T0_IN"; \
  jsonl_line "session dddddddd: done" "$D_T1_IN"; } > "$PROJDIR/dddddddd-full-id.jsonl"

# eeeeeeee: the glob for this 8-char prefix matches TWO transcripts -- never
# opened (picking one would be a guess), so it must land in
# attribution_unresolved and credit no PR at all.
{ jsonl_line "session eeeeeeee copy 1: landed #101 today" "$D_T0_IN"; } > "$PROJDIR/eeeeeeee-full-id-1.jsonl"
{ jsonl_line "session eeeeeeee copy 2: landed #101 today" "$D_T0_IN"; } > "$PROJDIR/eeeeeeee-full-id-2.jsonl"

# ffffffff: no transcript matches this prefix at all -- "no transcript".

# 22222222: a transcript exists (single match) but carries no `timestamp`
# field on any line -- no [t0, t1] can be derived -- "no timestamps".
{ jsonl_line_no_ts "session 22222222: landed #101 today, but no timestamps here"; } > "$PROJDIR/22222222-full-id.jsonl"

# 11111111: in-window, but nominates #101 only via a DIFFERENT repo
# (otherowner/otherrepo#101) -- a qualified nomination is only honored
# against the TARGET repo's own nameWithOwner (acme/widgets here), so this
# must not credit #101.
{ jsonl_line "session 11111111: landed otherowner/otherrepo#101 today" "$D_T0_IN"; \
  jsonl_line "session 11111111: wrapping up" "$D_T1_IN"; } > "$PROJDIR/11111111-full-id.jsonl"

# S(b): a 6-char sid is BELOW the 8+ hex/dash minimum -- it must never even
# become a candidate. It gets its own resolvable, in-window, nominating
# transcript so that if the regex ever loosens, this would visibly (and
# wrongly) get credited instead of silently doing nothing either way.
{ jsonl_line "session abcdef: landed #101 today" "$D_T0_IN"; \
  jsonl_line "session abcdef: wrapping up" "$D_T1_IN"; } > "$PROJDIR/abcdef-full-id.jsonl"

cat > "$TMP/ledger.md" <<EOF
| Date | Session | Notes |
|---|---|---|
| 01-02 | aaaaaaaa | note |
| 01-02 | bbbbbbbb | note |
| 01-02 | cccccccc | note |
| 01-02 | dddddddd | note |
| 01-02 | eeeeeeee | note |
| 01-02 | ffffffff | note |
| 01-02 | 22222222 | note |
| 01-02 | 11111111 | note |
| 01-02 | abcdef | note |
EOF

: > "$GH_LOG"
out=$(HOME="$FAKEHOME" "$PY" "$SUT" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" \
      --no-issues --attribute "$TMP/ledger.md" --json 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--attribute run exits 0" || bad "--attribute run exits 0" "rc=$rc $(flat "$out")"
echo "$out" > "$TMP/attr.json"
"$PY" - "$TMP/attr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = True
def check(name, cond):
    global ok
    print(("  ok   " if cond else "  FAIL ") + name)
    if not cond:
        ok = False
bucket101 = d.get("attribution", {}).get("101", {})
sessions = set(bucket101.get("sessions", []))
check("in-window + nominated (aaaaaaaa) credited", "aaaaaaaa" in sessions)
check("in-window but not nominated (bbbbbbbb) NOT credited", "bbbbbbbb" not in sessions)
check("nominated but out-of-window (cccccccc) NOT credited", "cccccccc" not in sessions)
check("second in-window nominating session (dddddddd) also credited", "dddddddd" in sessions)
check("cross-repo qualified nomination (otherowner/otherrepo#101) NOT credited",
      "11111111" not in sessions)
check("exactly the two expected sessions, both listed", sessions == {"aaaaaaaa", "dddddddd"})
check("no per-PR 'ambiguous' key anywhere (FIX 2 shape)", "ambiguous" not in bucket101)

unresolved = {u["sid"]: u["reason"] for u in d.get("attribution_unresolved", [])}
check("ambiguous-transcript sid (eeeeeeee) -> attribution_unresolved, 'multiple transcripts match'",
      unresolved.get("eeeeeeee") == "multiple transcripts match")
check("ambiguous-transcript sid (eeeeeeee) credited to no PR",
      all("eeeeeeee" not in b.get("sessions", []) for b in d.get("attribution", {}).values()))
check("no-transcript sid (ffffffff) -> attribution_unresolved, 'no transcript'",
      unresolved.get("ffffffff") == "no transcript")
check("no-timestamps sid (22222222) -> attribution_unresolved, 'no timestamps'",
      unresolved.get("22222222") == "no timestamps")

# S(b): a 6-char sid is below the minimum and must never become a candidate
# at all -- not credited, and not even listed as unresolved (it was filtered
# out of the ledger parse itself, before any glob or file was touched).
check("Sb: 6-char sid (abcdef) is NOT credited to #101 despite a resolvable, "
      "in-window, nominating transcript", "abcdef" not in sessions)
check("Sb: 6-char sid (abcdef) never becomes a candidate at all (absent from attribution_unresolved)",
      "abcdef" not in unresolved)
sys.exit(0 if ok else 1)
PY
py_rc=$?
[ "$py_rc" -eq 0 ] && ok "GROUP E: attribution sessions match in-window+nominated exactly" \
  || bad "GROUP E: attribution sessions match in-window+nominated exactly" "$(cat "$TMP/attr.json")"

# S2: human mode prints an attribution section, not nothing.
: > "$GH_LOG"
out=$(HOME="$FAKEHOME" "$PY" "$SUT" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" \
      --no-issues --attribute "$TMP/ledger.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'aaaaaaaa' \
  && ok "S2: human mode with --attribute mentions the credited sid" \
  || bad "S2: human mode with --attribute mentions the credited sid" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -q 'attribution unresolved:' \
  && ok "S2: human mode prints an 'attribution unresolved:' line" \
  || bad "S2: human mode prints an 'attribution unresolved:' line" "$(flat "$out")"

# =========================================================================
# GROUP E2 -- C4: `gh repo view` failing must not silently degrade
# --attribute (or reopened-issue lookups): "repo resolution" must land in
# unknown[] (exit 2), and bare-#N attribution nominations must still run.
# =========================================================================
echo; echo "E2. gh repo view failure (C4)"

touch "$FAKE_GH_DIR/fail_repo_view"
: > "$GH_LOG"
sout=$(HOME="$FAKEHOME" "$PY" "$SUT" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" \
      --no-issues --attribute "$TMP/ledger.md" --json 2>"$TMP/e2-stderr"); rc=$?
serr=$(cat "$TMP/e2-stderr")
[ "$rc" -eq 2 ] && ok "gh repo view failure with --attribute -> exit 2" \
  || bad "gh repo view failure with --attribute -> exit 2" "rc=$rc $(flat "$sout") $(flat "$serr")"
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert any("repo resolution" in u for u in d["unknown"]), d["unknown"]' \
  && ok "C4: unknown[] names 'repo resolution'" \
  || bad "C4: unknown[] names 'repo resolution'" "$(flat "$sout")"
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["repo"] is None, d["repo"]' \
  && ok "C4: repo is null when gh repo view failed" \
  || bad "C4: repo is null when gh repo view failed" "$(flat "$sout")"
printf '%s' "$sout" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); s=set(d["attribution"].get("101",{}).get("sessions",[])); assert "aaaaaaaa" in s, s' \
  && ok "C4: bare #N attribution nominations still run when repo resolution fails" \
  || bad "C4: bare #N attribution nominations still run when repo resolution fails" "$(flat "$sout")"

# Nitpick: --no-issues means the reopened-issue measure was never REQUESTED
# at all -- a repo-resolution failure triggered by --attribute alone must
# not make human-mode output claim a failed ATTEMPT ("UNKNOWN (gh failure)")
# at a measure that was intentionally skipped.
out2=$(HOME="$FAKEHOME" "$PY" "$SUT" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" \
      --no-issues --attribute "$TMP/ledger.md" 2>&1); rc2=$?
[ "$rc2" -eq 2 ] && ok "gh repo view failure, --no-issues, human mode -> still exit 2" \
  || bad "gh repo view failure, --no-issues, human mode -> still exit 2" "rc=$rc2 $(flat "$out2")"
if printf '%s' "$out2" | grep -q 'reopened issues: UNKNOWN'; then
  bad "nitpick: --no-issues must not print 'reopened issues: UNKNOWN' for an unrequested measure" \
      "$(flat "$out2")"
else
  ok "nitpick: --no-issues does not print 'reopened issues: UNKNOWN' for an unrequested measure"
fi
printf '%s' "$out2" | grep -q 'reopened issues: (skipped, --no-issues)' \
  && ok "nitpick: --no-issues prints 'reopened issues: (skipped, --no-issues)', never a measured-looking 'none'" \
  || bad "nitpick: --no-issues prints 'reopened issues: (skipped, --no-issues)', never a measured-looking 'none'" "$(flat "$out2")"

rm -f "$FAKE_GH_DIR/fail_repo_view"

# =========================================================================
# GROUP F -- case 15: filed-from.py sibling missing
# =========================================================================
echo; echo "F. filed-from.py sibling missing"

ISO_DIR="$TMP/iso-no-sibling"
mkdir -p "$ISO_DIR"
cp "$SUT" "$ISO_DIR/rework-lag.py"

: > "$GH_LOG"
out=$("$PY" "$ISO_DIR/rework-lag.py" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "missing sibling, issue measure requested -> exit 2" \
  || bad "missing sibling, issue measure requested -> exit 2" "rc=$rc $(flat "$out")"
printf '%s' "$out" | grep -qi 'filed-from' \
  && ok "the REFUSE names the missing sibling (filed-from.py)" \
  || bad "the REFUSE names the missing sibling (filed-from.py)" "$(flat "$out")"

out=$("$PY" "$ISO_DIR/rework-lag.py" --repo "$FIXTURE" --since "$SINCE" --until "$UNTIL0" --no-issues 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "missing sibling, --no-issues -> still works" \
  || bad "missing sibling, --no-issues -> still works" "rc=$rc $(flat "$out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
