#!/usr/bin/env bash
# Regression test for the `--audit` label block in generic/project-genesis.md (#360).
#
# The block creates `tech-debt` / `from-audit` in an audited repo when missing. It
# is prose in a template, so nothing else executes it, and its safety rests on
# properties that are easy to break by a one-word edit: never `--force` (an
# existing label keeps its colour), a case-insensitive name match (GitHub's label
# names are), a re-check that turns a silent create failure into a STOP, and a
# listing deep enough to see label #48 of 61. This test extracts the block FRESH
# from the template on every run and executes it, as a script (the block uses
# `exit`), under bash AND zsh against a fake `gh` on PATH -- never the real gh,
# never the network.
#
# The block is located by CONTENT inside the `### Mode: --audit` section (a bash
# fence containing both `grep -qixF` and `gh label create`); zero or several
# matches is a hard failure, so the test can never silently test nothing.
#
# Does NOT `set -e`: a failed assertion is reported and the rest still run.
# GENESIS_TEMPLATE=<path> points the test at a copy (used only by mutation proofs).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="${GENESIS_TEMPLATE:-$HERE/../generic/project-genesis.md}"
LABELS_SRC="$HERE/../assets/genesis/labels.json"
EXPECTED_TOTAL=74       # 2 extraction asserts + 4 assertions x 9 cases x 2 shells (exact, not a floor)
PER_CASE=4
TMP=$(mktemp -d "${TMPDIR:-/tmp}/genesis-audit-label-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
die() { printf 'FATAL: %s\n' "$1"; exit 1; }

echo "genesis-audit-label-block.test.sh"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
[ -f "$LABELS_SRC" ] || die "labels.json not found: $LABELS_SRC"
command -v jq >/dev/null 2>&1 || die "jq not found (the block under test needs it)"
command -v git >/dev/null 2>&1 || die "git not found"

# ---- extract the block -------------------------------------------------------
mkdir -p "$TMP/blocks"
awk -v dir="$TMP/blocks" -v starts="$TMP/starts" '
  /^### Mode: `--audit`/ { insec=1; next }
  insec && /^### / { insec=0 }
  insec && !infence && /^ *```bash[ \t]*$/ { infence=1; n++; f=sprintf("%s/%d.sh", dir, n); print n, NR+1 >> starts; next }
  insec && infence && /^ *```[ \t]*$/ { infence=0; close(f); next }
  insec && infence { line=$0; sub(/^   /, "", line); print line > f }
' "$TEMPLATE"
MATCHES=(); START=
for f in "$TMP"/blocks/*.sh; do
  [ -e "$f" ] || continue
  if grep -qE 'grep -q[a-z]*F' "$f" && grep -qF 'gh label create' "$f"; then MATCHES+=("$f"); fi
done
[ "${#MATCHES[@]}" -eq 1 ] || die "expected exactly 1 label block in the --audit section of $TEMPLATE, found ${#MATCHES[@]}"
BLOCK=${MATCHES[0]}
START=$(awk -v n="$(basename "$BLOCK" .sh)" '$1==n {print $2}' "$TMP/starts")
END=$((START + $(wc -l < "$BLOCK") - 1))
ok "located exactly one label block (template lines ~$START-$END)"
[ "$(grep -c 'gh label create' "$BLOCK")" -eq 1 ] && ok "block has a single gh label create call" \
  || bad "block has a single gh label create call"

# ---- fake gh -----------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Fake gh. State: $FAKE_DIR/labels (one name per line). Logs: all.log, create.log.
printf '%s\n' "$*" >> "$FAKE_DIR/all.log"
if [ "${1:-}" = repo ] && [ "$*" = "repo view --json nameWithOwner -q .nameWithOwner" ]; then
  echo "owner/repo"; exit 0
fi
if [ "$*" = "label list -R owner/repo --limit 500 --json name -q .[].name" ]; then
  [ -n "${GH_LIST_FAIL:-}" ] && { echo "fake gh: list failed" >&2; exit 1; }
  head -n 500 "$FAKE_DIR/labels"; exit 0
fi
if [ "${1:-}" = label ] && [ "${2:-}" = create ] && [ "$#" -eq 9 ] && [ "$4" = --color ] \
   && [ "$6" = --description ] && [ "owner/repo" = "$9" ] && [ "$8" = -R ]; then
  printf '%s %s\n' "$3" "$5" >> "$FAKE_DIR/create.log"
  # GH_CREATE_FAIL=1 fails every create; any other value fails only that label name.
  if [ -n "${GH_CREATE_FAIL:-}" ] && { [ "$GH_CREATE_FAIL" = 1 ] || [ "$GH_CREATE_FAIL" = "$3" ]; }; then
    echo "fake gh: create failed" >&2; exit 1
  fi
  printf '%s\n' "$3" >> "$FAKE_DIR/labels"; exit 0
fi
printf 'UNEXPECTED\n' >> "$FAKE_DIR/unexpected.log"
echo "fake gh: unexpected invocation: $*" >&2; exit 97
GHEOF
chmod +x "$FAKEBIN/gh"

# ---- fixture registries ------------------------------------------------------
mkreg() { # $1 dir, $2 = good|nofile
  git init -q "$1" && mkdir -p "$1/assets/genesis" || die "git init $1"
  if [ "$2" = good ]; then cp "$LABELS_SRC" "$1/assets/genesis/labels.json"
  else echo '[]' > "$1/assets/genesis/other.json"; fi
  git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture || die "commit $1"
  git -C "$1" update-ref refs/remotes/origin/main HEAD || die "update-ref $1"
}
mkreg "$TMP/reg-good" good
mkreg "$TMP/reg-bad" nofile
mkdir -p "$TMP/work"

# ---- shells ------------------------------------------------------------------
SHELLS=(bash)
ZSH_OK=1
if command -v zsh >/dev/null 2>&1; then SHELLS+=(zsh)
elif [ -n "${CI:-}" ]; then
  bad "zsh present (CI is set; zsh is required there)" "install zsh (apt-get install zsh)"
else
  ZSH_OK=0; echo "  SKIP zsh not installed -- zsh assertions are counted as skipped (local only; fails under CI)"
  skipped=$((skipped + PER_CASE * 9))
fi

# run_case <shell> <name> <registry> <list-fail> <create-fail> <expected-creates> <expected-rc> <msg|-> <labels...>
# expected-creates: "|"-joined "name colour" pairs, sorted; msg: substring that must appear, or "-" for none of STOP/created
run_case() {
  local sh=$1 name=$2 reg=$3 lf=$4 cf=$5 exp=$6 erc=$7 msg=$8; shift 8
  local d="$TMP/run-$sh-$name"; mkdir -p "$d"
  : > "$d/all.log"; : > "$d/create.log"; : > "$d/unexpected.log"
  printf '%s\n' "$@" > "$d/labels"; [ "$#" -eq 0 ] && : > "$d/labels"
  local out rc
  out=$(cd "$TMP/work" && env PATH="$FAKEBIN:$PATH" FAKE_DIR="$d" SKILL_REGISTRY_DIR="$reg" \
        GH_LIST_FAIL="$lf" GH_CREATE_FAIL="$cf" "$sh" "$BLOCK" </dev/null 2>&1); rc=$?
  local got; got=$(sort "$d/create.log" | paste -sd'|' -)
  [ "$got" = "$exp" ] && ok "[$sh] $name: creates = '${exp:-none}'" || bad "[$sh] $name: creates" "expected '$exp' got '$got'"
  if grep -qF -- '--force' "$d/all.log" || [ -s "$d/unexpected.log" ]; then
    bad "[$sh] $name: no --force, no unexpected gh call" "$(cat "$d/all.log" | tr '\n' '|')"
  else ok "[$sh] $name: no --force, no unexpected gh call"; fi
  [ "$rc" = "$erc" ] && ok "[$sh] $name: exit $erc" || bad "[$sh] $name: exit" "expected $erc got $rc; out: $(printf '%s' "$out" | tr '\n' '|')"
  if [ "$msg" = - ]; then
    if printf '%s' "$out" | grep -qE 'STOP|created label'; then bad "[$sh] $name: silent" "$(printf '%s' "$out" | tr '\n' '|')"
    else ok "[$sh] $name: silent (no STOP, nothing created)"; fi
  else
    if printf '%s' "$out" | grep -qF -- "$msg"; then ok "[$sh] $name: output has '$msg'"
    else bad "[$sh] $name: output has '$msg'" "$(printf '%s' "$out" | tr '\n' '|')"; fi
  fi
}

BOTH='from-audit d4c5f9|tech-debt fbca04'
many=(); for i in $(seq 1 61); do many+=("filler-$i"); done
many[47]=tech-debt   # position 48 of 61
for sh in "${SHELLS[@]}"; do
  run_case "$sh" 1-both-missing "$TMP/reg-good" "" "" "$BOTH" 0 "created label from-audit in owner/repo" bug enhancement
  run_case "$sh" 2-one-present-offcolour "$TMP/reg-good" "" "" "from-audit d4c5f9" 0 "created label from-audit in owner/repo" tech-debt bug
  run_case "$sh" 3-case-variants "$TMP/reg-good" "" "" "" 0 - Tech-Debt FROM-AUDIT bug
  run_case "$sh" 4-create-fails "$TMP/reg-good" "" 1 "$BOTH" 2 "STOP: tech-debt or from-audit is still missing" bug
  run_case "$sh" 5-tech-debt-at-48-of-61 "$TMP/reg-good" "" "" "from-audit d4c5f9" 0 "created label from-audit in owner/repo" "${many[@]}"
  run_case "$sh" 6-list-fails "$TMP/reg-good" 1 "" "" 2 "STOP: could not list labels" bug
  # 8a/8b pin BOTH halves of the final re-check (`has tech-debt && has from-audit`): with
  # only one create failing, dropping either operand of the && leaves exit 0 instead of 2.
  run_case "$sh" 8a-only-from-audit-create-fails "$TMP/reg-good" "" from-audit "$BOTH" 2 "STOP: tech-debt or from-audit is still missing" bug
  run_case "$sh" 8b-only-tech-debt-create-fails "$TMP/reg-good" "" tech-debt "$BOTH" 2 "STOP: tech-debt or from-audit is still missing" bug
  run_case "$sh" 7-registry-unreadable "$TMP/reg-bad" "" "" "" 2 "STOP: tech-debt or from-audit is still missing" bug
done

# ---- count guard -------------------------------------------------------------
TOTAL=$((pass + fail + skipped))
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ] || exit 1
ACCOUNTED=$((pass + skipped))
if [ "$ACCOUNTED" -ne "$EXPECTED_TOTAL" ]; then
  echo "FAIL: $ACCOUNTED assertions accounted for (pass+skipped), expected exactly $EXPECTED_TOTAL (zero-case guard)"; exit 1
fi
exit 0
