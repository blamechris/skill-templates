#!/usr/bin/env bash
# check-index-fresh.test.sh — regression tests for scripts/check-index-fresh.py
# and for the two workflow invariants that cannot be exercised any other way
# without pushing to main.
#
# Run: ./scripts/check-index-fresh.test.sh
# Exit: 0 all pass · 1 a case failed
#
# The case this file exists for: a PR branch and main legitimately disagree on
# the two git-derived fields (`generatedFromCommit`, `skills[].hash`), because
# main squash-merges and the squash rewrites the commit the branch pinned. A
# naive `git diff --exit-code registry.json` freshness gate would fail every
# honest template PR on that alone. The gate must ignore exactly those two
# fields and nothing else — "branch vs main, same content" below is the
# false-positive test, and the stale-* cases are the true-positive tests.
#
# Uses `set -uo pipefail`, not -euo: the harness deliberately captures a
# non-zero rc from every "stale" case (same convention as skill-lint.test.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-index-fresh.py"
REINDEX_WF="$ROOT/.github/workflows/reindex-after-merge.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  NOT OK - $1"; if [ -n "${2:-}" ]; then echo "      $2"; fi; return 0; }

# expect <fresh|stale> <label> <committed.json> <rebuilt.json> [-m substring]
expect() {
  local want="$1" label="$2" committed="$3" rebuilt="$4"; shift 4
  local want_msg=""
  if [ "${1:-}" = "-m" ]; then want_msg="${2:-}"; fi
  local out rc
  out="$(python3 "$CHECK" "$committed" "$rebuilt" 2>&1)"; rc=$?
  if [ "$want" = fresh ]; then
    if [ "$rc" -ne 0 ]; then bad "$label" "expected exit 0, got $rc: $out"; return; fi
  else
    if [ "$rc" -ne 1 ]; then bad "$label" "expected exit 1, got $rc: $out"; return; fi
    if [ -n "$want_msg" ] && ! grep -qF -- "$want_msg" <<<"$out"; then
      bad "$label" "expected message to contain '$want_msg', got: $out"; return
    fi
  fi
  ok "$label"
}

# mutate <src> <dst> <python-expr-on-`reg`> — edit a copy of an index doc.
mutate() {
  local src="$1" dst="$2" expr="$3"
  python3 - "$src" "$dst" "$expr" <<'PY'
import json, sys
src, dst, expr = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as f:
    reg = json.load(f)
exec(expr)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(reg, f, indent=2, ensure_ascii=False)
PY
}

echo "comparator: the committed registry.json against a rebuild"

# Real data: the index this repo actually ships. Everything below is a mutation
# of it, so the fixtures carry real descriptions, line counts and guards.
REAL="$ROOT/registry.json"
[ -f "$REAL" ] || { echo "FATAL: $REAL missing"; exit 1; }

expect fresh "byte-identical index is fresh" "$REAL" "$REAL"

# THE false-positive case. A PR branch's index pins the branch commit in both
# git-derived fields; after the squash, main's rebuild pins the squash commit.
# Content is identical. This must pass, or the gate blocks every template PR.
mutate "$REAL" "$TMP/squashed.json" '
reg["generatedFromCommit"] = "c1bc870"
for s in reg["skills"]:
    s["hash"] = "deadbee"
'
expect fresh "branch vs main: only generatedFromCommit + every hash moved" \
  "$REAL" "$TMP/squashed.json"

mutate "$REAL" "$TMP/onehash.json" 'reg["skills"][0]["hash"] = "0000000"'
expect fresh "a single per-skill hash moved (the squash-merge case)" \
  "$REAL" "$TMP/onehash.json"

# True positives: content drifted, so the committed index really is stale.
mutate "$REAL" "$TMP/desc.json" '
reg["skills"][0]["description"] = reg["skills"][0]["description"] + " Now with extra prose."
'
expect stale "a description edited without reindexing" \
  "$REAL" "$TMP/desc.json" -m "description"

mutate "$REAL" "$TMP/lines.json" 'reg["skills"][1]["lines"] += 12'
expect stale "a template grew lines without reindexing" \
  "$REAL" "$TMP/lines.json" -m ".lines"

mutate "$REAL" "$TMP/added.json" '
reg["skills"].append({"name": "zzz-new", "hash": "abc1234", "lines": 5, "description": "d"})
reg["skillCount"] += 1
'
expect stale "a new template not added to the registry" \
  "$REAL" "$TMP/added.json" -m "no entry"

mutate "$REAL" "$TMP/removed.json" '
reg["skills"] = [s for s in reg["skills"] if s["name"] != reg["skills"][0]["name"]]
reg["skillCount"] -= 1
'
expect stale "a deleted template still in the registry" \
  "$REAL" "$TMP/removed.json" -m "no template exists"

mutate "$REAL" "$TMP/count.json" 'reg["skillCount"] = 999'
expect stale "skillCount drifted" "$REAL" "$TMP/count.json" -m "skillCount"

mutate "$REAL" "$TMP/guards.json" '
for s in reg["skills"]:
    if "guards" in s:
        s["guards"][0]["anyOf"].append("NEW MARKER"); break
'
expect stale "a guard changed in skill-guards.json without reindexing" \
  "$REAL" "$TMP/guards.json" -m "guards"

mutate "$REAL" "$TMP/guardgain.json" '
for s in reg["skills"]:
    if "guards" not in s:
        s["guards"] = [{"label": "x", "anyOf": ["X"]}]; break
'
expect stale "a skill gained guards without reindexing" \
  "$REAL" "$TMP/guardgain.json" -m "guards"

mutate "$REAL" "$TMP/order.json" 'reg["skills"].reverse()'
expect stale "skills[] reordered away from build-index.sh's sort" \
  "$REAL" "$TMP/order.json" -m "order"

mutate "$REAL" "$TMP/registryname.json" 'reg["registry"] = "someone-else/skill-templates"'
expect stale "the registry name changed" \
  "$REAL" "$TMP/registryname.json" -m "registry"

# Combined: real staleness that ALSO carries squash noise must still be caught.
mutate "$REAL" "$TMP/both.json" '
reg["generatedFromCommit"] = "c1bc870"
for s in reg["skills"]:
    s["hash"] = "deadbee"
reg["skills"][2]["description"] = "drifted"
'
expect stale "squash noise does not mask a real description drift" \
  "$REAL" "$TMP/both.json" -m "description"

echo
echo "anti-loop: the reindex workflow's push trigger"

# reindex-after-merge.yml pushes registry.json to a branch and opens a PR.
# Merging that PR is a push to main touching ONLY registry.json. If
# registry.json were ever listed under the trigger's `paths:`, that merge would
# retrigger the workflow forever. Lock the invariant here rather than
# discovering it in production.
if [ ! -f "$REINDEX_WF" ]; then
  bad "reindex workflow exists" "missing $REINDEX_WF"
else
  ok "reindex workflow exists"

  # The `paths:` block: list items between `paths:` and the next key at or
  # above its indentation.
  PATHS="$(awk '
    /^[[:space:]]*paths:[[:space:]]*$/ { inb=1; ind=match($0,/[^ ]/); next }
    inb {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) next
      cur = match($0,/[^ ]/)
      if (cur <= ind) { inb=0; next }
      if ($0 ~ /^[[:space:]]*-[[:space:]]*/) { sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/^['\''"]|['\''"]$/,""); print }
    }
  ' "$REINDEX_WF")"

  if [ -z "$PATHS" ]; then
    bad "push trigger has a paths: filter" "no paths: entries parsed from $REINDEX_WF"
  else
    ok "push trigger has a paths: filter ($(echo "$PATHS" | tr '\n' ' '))"
  fi

  if grep -qE '(^|/)registry\.json$' <<<"$PATHS"; then
    bad "registry.json is NOT in paths:" \
        "registry.json is listed — merging the reindex PR would retrigger this workflow (loop)"
  else
    ok "registry.json is NOT in paths: (a registry.json-only push cannot retrigger)"
  fi

  for want in 'generic/**' 'skill-guards.json'; do
    if grep -qxF "$want" <<<"$PATHS"; then
      ok "paths: covers the index input '$want'"
    else
      bad "paths: covers the index input '$want'" "not found in: $(echo "$PATHS" | tr '\n' ' ')"
    fi
  done

  # A GITHUB_TOKEN-authored PR does not trigger other workflows. A reader WILL
  # notice the reindex PR has no validate run; the file must say why.
  if grep -qi 'GITHUB_TOKEN' "$REINDEX_WF" && grep -qi 'do not trigger\|does not trigger' "$REINDEX_WF"; then
    ok "workflow documents that GITHUB_TOKEN PRs do not trigger other workflows"
  else
    bad "workflow documents that GITHUB_TOKEN PRs do not trigger other workflows"
  fi

  for perm in 'contents: write' 'pull-requests: write'; do
    if grep -qF "$perm" "$REINDEX_WF"; then
      ok "workflow declares '$perm'"
    else
      bad "workflow declares '$perm'"
    fi
  done
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "check-index-fresh.test: ALL PASS ($PASS tests)"
  exit 0
fi
echo "check-index-fresh.test: $FAIL FAILED, $PASS passed"
exit 1
