#!/usr/bin/env bash
# check-html-dark.test.sh — regression tests for scripts/check-html-dark.py.
#
# Run: ./scripts/check-html-dark.test.sh
# Exit: 0 all pass · 1 a case failed or no case ran
#
# Every case asserts the exit code and, for failures, a message substring. The
# harness itself fails if PASS is 0 (a harness that reports success over zero
# cases is a known false-safety-guard class).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-html-dark.py"

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

# tree <name> — fresh fixture root with an empty generic/
# (mktemp, not a counter: tree runs in a $(...) subshell, so a counter would not advance)
tree() { local d; d="$(mktemp -d "$TMP/t.XXXXXX")"; mkdir -p "$d/generic"; echo "$d"; }
put() { printf '%s\n' "$2" > "$1"; }   # put <file> <content>

GOOD='Writes `<slug>-<date>.html`. Style: `:root{color-scheme:dark;}` only.'

echo "real tree"
out="$(python3 "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then bad "real tree passes" "exit $rc: $out"
else
  miss=""
  for t in visual-brief smoke-form look-approve weekly-review; do
    grep -qF -- "$t" <<<"$out" || miss="$miss $t"
  done
  if [ -n "$miss" ]; then bad "real tree output names the four known templates" "missing:$miss in: $out"
  else ok "real tree passes and names the four known templates"; fi
fi

echo "stripped real template"
d="$(tree)"; cp "$ROOT"/generic/*.md "$d/generic/"
sed -i.bak '/color-scheme/d' "$d/generic/look-approve.md"; rm -f "$d/generic/look-approve.md.bak"
if cmp -s "$d/generic/look-approve.md" "$ROOT/generic/look-approve.md"; then bad "fixture mutation changed look-approve" "no-op"
else run "dark rule stripped from look-approve" 1 "$d" "generic/look-approve.md"; fi

echo "detection"
d="$(tree)"; put "$d/generic/a.md" 'Writes report-<date>.html for the reader.'
run "a .html output with no dark rule fails" 1 "$d" "generic/a.md"
d="$(tree)"; put "$d/generic/a.md" '<!DOCTYPE html><html><body>x</body></html>'
run "a DOCTYPE skeleton with no dark rule fails" 1 "$d" "generic/a.md"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"; put "$d/generic/b.md" 'No page here at all.'
run "a template with no HTML and no dark rule is not detected" 0 "$d" "1 HTML-rendering"
d="$(tree)"; put "$d/generic/b.md" 'No page here at all.'
run "no HTML-rendering template anywhere is nonzero (vacuity)" 2 "$d" "zero"

echo "rules"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''color-scheme: light dark;'
run "css 'light dark' fails even with a dark declaration" 1 "$d" "combined"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''color-scheme: dark light;'
run "css 'dark light' fails" 1 "$d" "combined"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''<meta name="color-scheme" content="light dark">'
run "meta 'light dark' fails even with a dark declaration" 1 "$d" "combined"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''<meta content="dark light" name="color-scheme">'
run "meta with reversed attribute order fails" 1 "$d" "combined"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''@media (prefers-color-scheme: light) { :root{} }'
run "a prefers-color-scheme media query fails" 1 "$d" "prefers-color-scheme"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''@media(  prefers-color-scheme :dark){}'
run "media query with odd whitespace fails" 1 "$d" "prefers-color-scheme"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n''Add no `prefers-color-scheme` light flip.'
run "prose forbidding prefers-color-scheme passes" 0 "$d"
d="$(tree)"; put "$d/generic/a.md" "$GOOD"$'\n'':root[data-theme="light"]{color-scheme:light;}'
run "opt-in color-scheme:light beside dark passes" 0 "$d"
d="$(tree)"; put "$d/generic/a.md" 'Writes page.html, light only.'$'\n'':root{color-scheme:light;}'
run "light alone with no dark declaration fails" 1 "$d" "no \`color-scheme: dark\`"

echo "cannot check"
d="$TMP/nogeneric"; mkdir -p "$d"
run "missing generic/ is exit 2" 2 "$d" "cannot check"
d="$(tree)"
run "empty generic/ is exit 2" 2 "$d" "cannot check"
d="$(tree)"; printf '\xff\xfe page.html' > "$d/generic/a.md"
run "non-UTF-8 file is exit 2" 2 "$d" "cannot read"

echo "reporting"
d="$(tree)"; put "$d/generic/a.md" 'Writes a.html'; put "$d/generic/b.md" 'Writes b.html'
run "two violating templates are both reported" 1 "$d" "generic/a.md" "generic/b.md"
d="$(tree)"; put "$d/generic/a.md" 'Writes a.html'$'\n''color-scheme: light dark;'$'\n''@media (prefers-color-scheme: dark){}'
run "all three violations of one file are reported" 1 "$d" "no \`color-scheme: dark\`" "combined" "@media"

echo
echo "$PASS passed, $FAIL failed"
if [ "$PASS" -eq 0 ]; then echo "FAIL: no cases ran"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
