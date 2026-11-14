#!/usr/bin/env bash
# Regression test for the label blocks in generic/decompose-issue.md (#365).
#
# Section 5 ("Verify labels exist") filters SUB_LABELS against the repo's labels;
# section 6 applies the parent-marker label `decomposed`. Both are prose in a
# template, so nothing else executes them, and each rests on properties a one-word
# edit breaks: `--limit 500` (gh lists only 30 labels, oldest first, so a recent
# label reads as missing), a case-insensitive match (GitHub's label names are), and
# a failed listing that is never read as "no labels exist". This test extracts both
# blocks FRESH from the template on every run, by content, and executes each as a
# script (section 5 uses `exit`) under bash AND zsh against a fake `gh` on PATH --
# never the real gh, never the network.
#
# Zero or several matches for either block is a hard failure, so the test can never
# silently test nothing.
#
# Does NOT `set -e`: a failed assertion is reported and the rest still run.
# DECOMPOSE_TEMPLATE=<path> points the test at a copy (used only by mutation proofs).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="${DECOMPOSE_TEMPLATE:-$HERE/../generic/decompose-issue.md}"
EXPECTED_TOTAL=82       # 2 extraction asserts + 4 assertions x 10 cases x 2 shells (exact, not a floor)
PER_CASE=4
NCASES=10
TMP=$(mktemp -d "${TMPDIR:-/tmp}/decompose-label-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
die() { printf 'FATAL: %s\n' "$1"; exit 1; }

echo "decompose-issue-label-blocks.test.sh"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

# ---- extract every bash fence, then pick the two blocks by content ----------
mkdir -p "$TMP/blocks"
awk -v dir="$TMP/blocks" '
  !infence && /^ *```bash[ \t]*$/ { infence=1; n++; f=sprintf("%s/%d.sh", dir, n); next }
  infence && /^ *```[ \t]*$/ { infence=0; close(f); next }
  infence { print $0 > f }
' "$TEMPLATE"
S5=(); S6=()
for f in "$TMP"/blocks/*.sh; do
  [ -e "$f" ] || continue
  if grep -qF 'SUB_LABELS=' "$f" && grep -qF 'gh label list' "$f"; then S5+=("$f"); fi
  if grep -qF 'gh label list' "$f" && grep -qF 'gh issue edit' "$f"; then S6+=("$f"); fi
done
[ "${#S5[@]}" -eq 1 ] || die "expected exactly 1 section-5 label block in $TEMPLATE, found ${#S5[@]}"
[ "${#S6[@]}" -eq 1 ] || die "expected exactly 1 section-6 parent-marker block in $TEMPLATE, found ${#S6[@]}"
# The blocks are run as scripts; a trailing line reports the result variable.
{ cat "${S5[0]}"; printf '%s\n' 'printf "RESULT=%s\n" "$SUB_LABELS"'; } > "$TMP/block5.sh"
cp "${S6[0]}" "$TMP/block6.sh"
ok "located exactly one section-5 label block"
ok "located exactly one section-6 parent-marker block"

# ---- fake gh -----------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Fake gh. State: $FAKE_DIR/labels (one name per line). Logs: all.log, edit.log.
# Honours --limit like the real gh: with none, only the first 30 labels come back.
printf '%s\n' "$*" >> "$FAKE_DIR/all.log"
if [ "${1:-}" = label ] && [ "${2:-}" = list ]; then
  shift 2
  limit=30
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) limit=$2; shift 2 ;;
      --json) [ "$2" = name ] || { echo "fake gh: unexpected --json $2" >&2; exit 97; }; shift 2 ;;
      -q) [ "$2" = '.[].name' ] || { echo "fake gh: unexpected -q $2" >&2; exit 97; }; shift 2 ;;
      *) printf 'UNEXPECTED\n' >> "$FAKE_DIR/unexpected.log"; echo "fake gh: unexpected arg: $1" >&2; exit 97 ;;
    esac
  done
  [ -n "${GH_LIST_FAIL:-}" ] && { echo "fake gh: list failed" >&2; exit 1; }
  head -n "$limit" "$FAKE_DIR/labels"; exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
  printf '%s\n' "$*" >> "$FAKE_DIR/edit.log"; exit 0
fi
printf 'UNEXPECTED\n' >> "$FAKE_DIR/unexpected.log"
echo "fake gh: unexpected invocation: $*" >&2; exit 97
GHEOF
chmod +x "$FAKEBIN/gh"

# ---- shells ------------------------------------------------------------------
SHELLS=(bash)
if command -v zsh >/dev/null 2>&1; then SHELLS+=(zsh)
elif [ -n "${CI:-}" ]; then
  bad "zsh present (CI is set; zsh is required there)" "install zsh (apt-get install zsh)"
else
  echo "  SKIP zsh not installed -- zsh assertions are counted as skipped (local only; fails under CI)"
  skipped=$((skipped + PER_CASE * NCASES))
fi

# run_case <shell> <name> <block> <list-fail> <sub-labels> <expect-result|expect-edits> <expected-rc> <msg|-> <labels...>
# block 5: 6th arg is the expected RESULT= value; block 6: the expected edit.log ("" = none).
run_case() {
  local sh=$1 name=$2 blk=$3 lf=$4 sub=$5 exp=$6 erc=$7 msg=$8; shift 8
  local d="$TMP/run-$sh-$name"; mkdir -p "$d"
  : > "$d/all.log"; : > "$d/edit.log"; : > "$d/unexpected.log"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$d/labels"; else : > "$d/labels"; fi
  local out rc
  out=$(env PATH="$FAKEBIN:$PATH" FAKE_DIR="$d" GH_LIST_FAIL="$lf" SUB_LABELS="$sub" PARENT_NUM=42 \
        "$sh" "$TMP/block$blk.sh" </dev/null 2>&1); rc=$?
  local got
  if [ "$blk" = 5 ]; then got=$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p'); else got=$(paste -sd'|' "$d/edit.log"); fi
  [ "$got" = "$exp" ] && ok "[$sh] $name: result = '${exp:-none}'" || bad "[$sh] $name: result" "expected '$exp' got '$got'"
  if [ -s "$d/unexpected.log" ]; then bad "[$sh] $name: no unexpected gh call" "$(tr '\n' '|' < "$d/all.log")"
  else ok "[$sh] $name: no unexpected gh call"; fi
  [ "$rc" = "$erc" ] && ok "[$sh] $name: exit $erc" || bad "[$sh] $name: exit" "expected $erc got $rc; out: $(printf '%s' "$out" | tr '\n' '|')"
  if [ "$msg" = - ]; then
    if printf '%s' "$out" | grep -qE 'Warning|REFUSE'; then bad "[$sh] $name: silent" "$(printf '%s' "$out" | tr '\n' '|')"
    else ok "[$sh] $name: silent (no warning, no refusal)"; fi
  else
    if printf '%s' "$out" | grep -qF -- "$msg"; then ok "[$sh] $name: output has '$msg'"
    else bad "[$sh] $name: output has '$msg'" "$(printf '%s' "$out" | tr '\n' '|')"; fi
  fi
}

# 61 labels; the wanted ones sit past position 30 (the fake gh hides them without --limit).
mk61() { # $1 = name to plant at position 40, $2 = name to plant at position 55
  many=(); for i in $(seq 1 61); do many+=("filler-$i"); done
  [ -n "${1:-}" ] && many[39]=$1
  [ -n "${2:-}" ] && many[54]=$2
}
for sh in "${SHELLS[@]}"; do
  mk61 late-label complexity:low
  run_case "$sh" 5a-past-position-30 5 "" "enhancement,late-label,complexity:low" "enhancement,late-label,complexity:low" 0 - enhancement "${many[@]}"
  run_case "$sh" 5b-case-differs 5 "" "enhancement,bug" "enhancement,bug" 0 - Enhancement BUG
  run_case "$sh" 5c-missing-dropped 5 "" "enhancement,nope" "enhancement" 0 "'nope' label not found" enhancement bug
  run_case "$sh" 5d-list-fails 5 1 "enhancement,bug" "" 1 "REFUSE: could not list labels" enhancement bug
  # 5e: a regex metacharacter must match literally (-F: 'v1.0' is not 'v1x0'), a label
  # beginning with '-' must not be read as a grep option (--), and a trailing comma
  # must not leave a stray comma in the result.
  run_case "$sh" 5e-literal-dash-empty 5 "" "v1.0,-weird,enhancement," "-weird,enhancement" 0 "'v1.0' label not found" v1x0 -weird enhancement
  # 5f: an empty element is skipped silently, not warned about as a missing label ''.
  # It sits in the middle: command substitution strips a trailing empty element first.
  run_case "$sh" 5f-empty-element-silent 5 "" "enhancement,,bug" "enhancement,bug" 0 - enhancement bug
  mk61 decomposed ""
  run_case "$sh" 6a-marker-past-position-30 6 "" "" "issue edit 42 --add-label decomposed" 0 - "${many[@]}"
  mk61 Decomposed ""
  run_case "$sh" 6b-marker-case-differs 6 "" "" "issue edit 42 --add-label decomposed" 0 - "${many[@]}"
  mk61 "" ""
  run_case "$sh" 6c-marker-absent 6 "" "" "" 0 - "${many[@]}"
  run_case "$sh" 6d-list-fails 6 1 "" "" 0 "could not list labels" enhancement decomposed
done

# ---- count guard -------------------------------------------------------------
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ] || exit 1
ACCOUNTED=$((pass + skipped))
if [ "$ACCOUNTED" -ne "$EXPECTED_TOTAL" ]; then
  echo "FAIL: $ACCOUNTED assertions accounted for (pass+skipped), expected exactly $EXPECTED_TOTAL (zero-case guard)"; exit 1
fi
exit 0
