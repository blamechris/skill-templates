#!/usr/bin/env bash
# check-bootstrap-order.test.sh — regression tests for scripts/check-bootstrap-order.py (#398).
#
# Run: ./scripts/check-bootstrap-order.test.sh
# Exit: 0 all pass · 1 a case failed or no case ran
#
# Every case builds a synthetic fixture tree (a template plus stub scripts) and
# asserts the exit code and, for failures, a message substring. The harness
# itself fails if PASS is 0 (a harness that reports success over zero cases is
# a known false-safety-guard class).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-bootstrap-order.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; if [ -n "${2:-}" ]; then echo "      $2"; fi; return 0; }

# run <label> <want-rc> <root> [substring ...]
run() {
  local label="$1" want="$2" root="$3"; shift 3
  local out rc
  out="$(python3 "$CHECK" --root "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$label" "expected exit $want, got $rc: $out"; return 0; fi
  local s
  for s in "$@"; do
    if ! grep -qF -- "$s" <<<"$out"; then bad "$label" "expected message to contain '$s', got: $out"; return 0; fi
  done
  ok "$label"
}

# tree — fresh fixture root: two callers that import the engine, one script that
# does not, and a test file that imports it but is never installed.
tree() {
  local d; d="$(mktemp -d "$TMP/t.XXXXXX")"
  mkdir -p "$d/generic" "$d/assets/scripts"
  printf 'RATES = {}\n' > "$d/assets/scripts/usage_accounting.py"
  printf 'import os\nfrom usage_accounting import RATES\n' > "$d/assets/scripts/usage-row.py"
  printf 'import usage_accounting\n' > "$d/assets/scripts/usage-trend.py"
  printf 'import os\n' > "$d/assets/scripts/seed.py"
  printf 'import usage_accounting\n' > "$d/assets/scripts/usage_accounting_test.py"
  echo "$d"
}
tpl() { printf '%s\n' "$2" > "$1/generic/session-lifecycle.md"; }   # tpl <root> <content>

SAME='The two copies of `usage_accounting.py` must be the same file version.'
FENCE='```'

GOOD="Intro.

${FENCE}bash
mkdir -p ~/.claude/scripts ~/.claude/usage-history
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/usage-history/
cp assets/scripts/seed.py assets/scripts/usage-row.py \\
   assets/scripts/usage-trend.py ~/.claude/scripts/
cp assets/scripts/usage-trend.py ~/.claude/usage-history/
${FENCE}

$SAME"

echo "check-bootstrap-order:"

R=$(tree); tpl "$R" "$GOOD"
run "engine to both directories before any caller passes" 0 "$R" "OK:" "2 importer(s)"

# The shape #398 reported: callers and engine in one command, trend's engine second.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage-row.py assets/scripts/usage_accounting.py \\
   assets/scripts/usage-trend.py ~/.claude/scripts/
cp assets/scripts/usage-trend.py assets/scripts/usage_accounting.py ~/.claude/usage-history/
${FENCE}
$SAME"
run "the pre-#398 block (engine inside the callers' copy) fails" 1 "$R" \
  "reaches ~/.claude/scripts/ in copy command 1, not before copy command 1" \
  "reaches ~/.claude/usage-history/ in copy command 2"

# Engine first to one place, but the second engine copy comes after the callers.
# With usage-trend.py symlinked into usage-history, the callers' copy has already
# written the trend beside the old engine.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage-row.py assets/scripts/usage-trend.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/usage-history/
cp assets/scripts/usage-trend.py ~/.claude/usage-history/
${FENCE}
$SAME"
run "second engine copy after the callers fails" 1 "$R" \
  "reaches ~/.claude/usage-history/ in copy command 3, not before copy command 2"

R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage-row.py assets/scripts/usage-trend.py ~/.claude/scripts/
cp assets/scripts/usage-trend.py ~/.claude/usage-history/
${FENCE}
$SAME"
run "a caller directory that never receives the engine fails" 1 "$R" \
  "a caller is copied to ~/.claude/usage-history/ but usage_accounting.py never is"

R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/usage-history/
cp assets/scripts/usage-row.py assets/scripts/usage-trend.py ~/.claude/scripts/
${FENCE}"
run "dropping the same-version sentence fails" 1 "$R" "must be the same file version"

# Prose that names an engine copy is not a copy.
R=$(tree); tpl "$R" "First run cp assets/scripts/usage_accounting.py ~/.claude/scripts/ by hand.

${FENCE}bash
cp assets/scripts/usage-row.py ~/.claude/scripts/
${FENCE}
$SAME"
run "an engine copy outside a code fence does not count" 1 "$R" \
  "a caller is copied to ~/.claude/scripts/ but usage_accounting.py never is"

# Importers are found structurally: a new caller is held to the rule unlisted.
R=$(tree)
printf 'from usage_accounting import RATES\n' > "$R/assets/scripts/usage-new.py"
tpl "$R" "${FENCE}bash
cp assets/scripts/usage-new.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
${FENCE}
$SAME"
run "a newly added importer is detected without a name list" 1 "$R" \
  "already copies its caller(s) usage-new.py"

# A non-importer copied first is fine, and a test file that imports the engine
# is not a caller (it is never installed).
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/seed.py assets/scripts/usage_accounting_test.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage-row.py ~/.claude/scripts/
${FENCE}
$SAME"
run "non-importers and test files before the engine pass" 0 "$R" "OK:"

# Imports inside a function, a try block or a comma list are still imports; a
# docstring that mentions one is not.
R=$(tree)
printf 'def f():\n    from usage_accounting import RATES\n' > "$R/assets/scripts/usage-fn.py"
printf 'try:\n    import os, usage_accounting\nexcept ImportError:\n    pass\n' > "$R/assets/scripts/usage-try.py"
printf '"""\nimport usage_accounting\n"""\n' > "$R/assets/scripts/usage-doc.py"
tpl "$R" "${FENCE}bash
cp assets/scripts/usage-doc.py ~/.claude/scripts/
cp assets/scripts/usage-fn.py assets/scripts/usage-try.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
${FENCE}
$SAME"
run "indented and comma-listed imports are callers, docstrings are not" 1 "$R" \
  "not before copy command 2, which already copies its caller(s) usage-fn.py, usage-try.py"

# A re-wrapped sentence still states the rule.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage-row.py ~/.claude/scripts/
${FENCE}
The two copies of \`usage_accounting.py\` must be the
same
file version."
run "a same-version sentence wrapped across lines passes" 0 "$R" "OK:"

# \$HOME and ~ name one directory; -t names the destination; && splits commands.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py \$HOME/.claude/scripts/ && cp -t \${HOME}/.claude/usage-history assets/scripts/usage_accounting.py
cp -p assets/scripts/usage-row.py ~/.claude/scripts/; cp assets/scripts/usage-trend.py ~/.claude/usage-history/
${FENCE}
$SAME"
run "\$HOME spellings, cp -t and && / ; splits read as one directory each" 0 "$R" \
  "reaches ~/.claude/scripts/, ~/.claude/usage-history/ before"

R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage-row.py ~/.claude/scripts/ && cp assets/scripts/usage_accounting.py ~/.claude/scripts/
${FENCE}
$SAME"
run "an && chain that copies the caller first fails" 1 "$R" "in copy command 2, not before copy command 1"

# An engine copy to a directory no caller uses is irrelevant to the order.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
cp assets/scripts/usage-row.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/backup/
${FENCE}
$SAME"
run "a late engine copy to a caller-free directory passes" 0 "$R" "OK:"

# Fail closed.
R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/*.py ~/.claude/scripts/
cp assets/scripts/usage_accounting.py ~/.claude/scripts/
${FENCE}
$SAME"
run "a glob copy of assets/scripts cannot be checked" 2 "$R" "is not plain sources and one destination"

R=$(tree)
run "a missing template cannot be checked" 2 "$R" "cannot check" "unreadable"

R=$(tree); rm "$R"/assets/scripts/usage-row.py "$R"/assets/scripts/usage-trend.py
tpl "$R" "$GOOD"
run "no importer in assets/scripts cannot be checked" 2 "$R" "no script in assets/scripts imports"

R=$(tree); tpl "$R" "${FENCE}bash
cp assets/scripts/seed.py ~/.claude/scripts/
${FENCE}
$SAME"
run "a block that copies no importer cannot be checked" 2 "$R" "no fenced \`cp\`"

R=$(tree); rm -r "$R/assets/scripts"; tpl "$R" "$GOOD"
run "a missing assets/scripts cannot be checked" 2 "$R" "assets/scripts/ is missing"

# The registry's own template.
run "this repository's session-lifecycle template passes" 0 "$ROOT" "OK:"

echo
echo "check-bootstrap-order: $PASS passed, $FAIL failed"
if [ "$PASS" -eq 0 ]; then echo "  NOT OK - no case ran"; exit 1; fi
[ "$FAIL" -eq 0 ]
