#!/usr/bin/env bash
# guard-audit.test.sh — regression tests for scripts/guard-audit.py (#225).
#
# Run: ./scripts/guard-audit.test.sh
# Exit: 0 all pass · 1 a case failed or NO case ran
#
# guard-audit.py finds guards whose every alternate is satisfiable by non-rule
# content. classify() decides what counts as "rule" (prose) vs "scaffold", and
# #223 widened it so a ```markdown / ```text / untagged fence counts as prose.
# These cases pin both edges of that widening against a hermetic fixture, so a
# change that blinds the tool (every fence prose) or re-floods it (every fence
# code) goes red.
#
# The audit is a CANDIDATE reporter, not a gate: this file never asserts its
# count over the real registry (visual-brief/respects-reader-colour-scheme
# reports permanently and correctly).
#
# GUARD_AUDIT overrides the script under test; the mutation proofs use it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="${GUARD_AUDIT:-$ROOT/scripts/guard-audit.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; if [ -n "${2:-}" ]; then echo "      $2"; fi; return 0; }

FX="$TMP/fx"
mkdir -p "$FX/generic"
cat > "$FX/generic/fx.md" <<'MD'
# Fixture skill

## Rules

Real prose rule: PROSEANCHOR must hold.

## MIXED heading

Rule: MIXED is stated here in prose, between a heading and a table row.

| MIXED | x |
|-------|---|

## HEADONLY heading

| col | TABLEONLY |
|-----|-----------|

```python
CODEONLY = 1
```

```bash
BASHLINE --flag
```

```markdown
MDRULE stated inside a markdown fence.
```

```
UNTAGGEDRULE stated inside an untagged fence.
```

```text
TEXTRULE stated inside a text fence.
```

```Markdown
CAPMDRULE stated inside a capitalised Markdown fence.
```

```md
MDTAGRULE stated inside an md fence.
```

```txt
TXTTAGRULE stated inside a txt fence.
```

## Customization Points

- CUSTOMONLY bullet
MD
cat > "$FX/skill-guards.json" <<'JSON'
{
  "_comment": "hermetic fixture",
  "fx": [
    {"label": "v-heading",   "anyOf": ["HEADONLY"]},
    {"label": "v-table",     "anyOf": ["TABLEONLY"]},
    {"label": "v-codefence", "anyOf": ["CODEONLY"]},
    {"label": "v-custom",    "anyOf": ["CUSTOMONLY"]},
    {"label": "v-bashline",  "anyOf": ["BASHLINE"]},
    {"label": "ok-markdown", "anyOf": ["MDRULE"]},
    {"label": "ok-untagged", "anyOf": ["UNTAGGEDRULE"]},
    {"label": "ok-text",     "anyOf": ["TEXTRULE"]},
    {"label": "ok-prose-alt","anyOf": ["HEADONLY", "TABLEONLY", "PROSEANCHOR"]},
    {"label": "ok-mixed",    "anyOf": ["MIXED"]},
    {"label": "nomatch-only","anyOf": ["NOSUCHTEXT"]},
    {"label": "ok-capmarkdown", "anyOf": ["CAPMDRULE"]},
    {"label": "ok-md",       "anyOf": ["MDTAGRULE"]},
    {"label": "ok-txt",      "anyOf": ["TXTTAGRULE"]},
    {"label": "badrx-only",  "anyOf": ["(unclosed"]},
    {"label": "badrx-then-vacuous", "anyOf": ["(unclosed", "HEADONLY"]}
  ]
}
JSON

OUT="$(python3 "$AUDIT" "$FX" 2>&1)"; RC=$?

if [ "$RC" -eq 0 ]; then ok "audit exits 0 on the fixture"; else bad "audit exits 0 on the fixture" "rc=$RC: $OUT"; fi

reported() { grep -qE "^  fx / $1\$" <<<"$OUT"; }

for l in v-heading v-table v-codefence v-custom; do
  if reported "$l"; then ok "vacuity class reported: $l"; else bad "vacuity class reported: $l" "$OUT"; fi
done

if reported v-bashline; then ok "shell line in a bash fence is reported"; else bad "shell line in a bash fence is reported" "$OUT"; fi

for l in ok-markdown ok-untagged ok-text ok-capmarkdown ok-md ok-txt; do
  if reported "$l"; then bad "rule in prose fence NOT reported: $l" "$OUT"; else ok "rule in prose fence NOT reported: $l"; fi
done

if reported ok-prose-alt; then bad "guard with a prose-anchored alternate never reported" "$OUT"; else ok "guard with a prose-anchored alternate never reported"; fi
# One alternate hitting a heading, then prose, then a table row: the prose hit anchors it,
# whichever hit comes first or last (review of #479).
if reported ok-mixed; then bad "an alternate with a prose hit among non-rule hits is anchored" "$OUT"; else ok "an alternate with a prose hit among non-rule hits is anchored"; fi
# An alternate that matches nothing is no evidence of vacuity: the guard is not reported.
if reported nomatch-only; then bad "a guard whose alternates match nothing is not reported" "$OUT"; else ok "a guard whose alternates match nothing is not reported"; fi

if reported badrx-only; then bad "uncompilable regex alone is skipped, not reported" "$OUT"; else ok "uncompilable regex alone is skipped, not reported"; fi
if reported badrx-then-vacuous; then ok "uncompilable regex does not stop later alternates being audited"; else bad "uncompilable regex does not stop later alternates being audited" "$OUT"; fi

if grep -qE '^guards audited: 16$' <<<"$OUT"; then ok "audit counted all 16 fixture guards"; else bad "audit counted all 16 fixture guards" "$OUT"; fi

# Zero-case guard: a harness that ran nothing must not report success.
if [ $((PASS+FAIL)) -lt 18 ]; then
  echo "guard-audit.test: only $((PASS+FAIL)) cases ran (expected >= 18) — refusing to report success"
  exit 1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "guard-audit.test: ALL PASS ($PASS tests)"
  exit 0
fi
echo "guard-audit.test: $FAIL FAILED, $PASS passed"
exit 1
