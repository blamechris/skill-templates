#!/usr/bin/env bash
# Regression tests for assets/scripts/fleet-check.py.
#
# Every assertion here is a property the check would otherwise be able to lose
# silently: the class split (floor fails, default reports), the direction naming,
# the whitespace/heading normalisation that stops it firing on formatting, and —
# the one that motivated the rewrite — that `git fetch` is a HARD precondition, so
# the check either sees origin's current copy or refuses to answer at all.
#
# No network: "origin" is a local bare repo, so a real `git fetch` really runs.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/fleet-check.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-check-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# assert <name> <expected-exit> <expected-substring|-> <machine-file> [extra args...]
assert() {
  local name=$1 want=$2 needle=$3 machine=$4; shift 4
  local out rc
  out=$(python3 "$SUT" --machine "$machine" --repo "$TMP/clone" "${CHECK_ARGS[@]}" "$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$name" "exit $rc, wanted $want — output: $(printf '%s' "$out" | tr '\n' '|')"
    return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -q -- "$needle"; then
    bad "$name" "exit $rc as wanted but output lacks '$needle' — $(printf '%s' "$out" | tr '\n' '|')"
    return
  fi
  ok "$name"
}

# ---------------------------------------------------------------- the fixture
# A miniature assets/AGENTS.md: five floor rules, two defaults, headings above each
# so the heading-insensitivity test has something to rename. The floor ids are real
# ones from FLOOR_IDS; the other three real floor ids are declared too, because the
# script checks the DECLARED floor set against its own list.
write_registry() {   # $1 = destination
  cat > "$1" <<'MD'
# Global instructions

## Attribution

<!--floor:no-agent-attribution-->
**NEVER** add a Co-Authored-By trailer or any AI/agent attribution.

## Writing to a shared working copy

<!--default:branch-assert-->
**Assert the branch before you write.** Re-check, never remember.

<!--floor:explicit-path-staging-->
**Stage explicit paths.** Never `git add -A`, `.`, `-u`, or a directory.

<!--floor:worktree-by-default-->
**Work in your own worktree.** It makes the collision structurally impossible.

<!--floor:no-secrets-in-committed-files-->
**Never commit a secret.** No tokens, no keys, no credentials, ever.

## Session boundaries

<!--floor:seed-written-outside-any-worktree-->
The seed is written outside any worktree, at an absolute path.

<!--default:model-tiering-->
Mechanical work runs on the cheapest adequate tier.
MD
}

mkdir -p "$TMP/origin"
git -c init.defaultBranch=main init --bare --quiet "$TMP/origin"
git -c init.defaultBranch=main clone --quiet "$TMP/origin" "$TMP/seed" 2>/dev/null
mkdir -p "$TMP/seed/assets"
write_registry "$TMP/seed/assets/AGENTS.md"
git -C "$TMP/seed" add assets/AGENTS.md
git -C "$TMP/seed" commit --quiet -m "registry copy"
git -C "$TMP/seed" push --quiet origin HEAD:main
git clone --quiet "$TMP/origin" "$TMP/clone"

M=$TMP/machine
mkdir -p "$M"
mkdir -p "$TMP/home/.claude" "$TMP/home/.codex" "$TMP/home/.gemini" "$TMP/home/.fleet"
cat > "$TMP/home/.claude/CLAUDE.md" <<'MD'
# Claude adapter
@~/.fleet/AGENTS.md
MD
write_registry "$TMP/home/.codex/AGENTS.md"
write_registry "$TMP/home/.gemini/GEMINI.md"
cat > "$TMP/home/.codex/config.toml" <<'TOML'
project_doc_max_bytes = 65536
TOML

CHECK_ARGS=(
  --claude "$TMP/home/.claude/CLAUDE.md"
  --codex "$TMP/home/.codex/AGENTS.md"
  --gemini "$TMP/home/.gemini/GEMINI.md"
  --codex-config "$TMP/home/.codex/config.toml"
  --project-dir "$TMP/clone"
)

echo "fleet-check.test.sh"

# 1. Identical copies: the only outcome that may print OK.
write_registry "$M/identical.md"
assert "identical copies agree" 0 "OK: machine and registry agree" "$M/identical.md"

# 2. Whitespace must never fire the check (#the amendment's explicit requirement).
write_registry "$M/ws.md"
python3 - "$M/ws.md" <<'PY'
import sys
p = sys.argv[1]
# Trailing whitespace on every non-empty line, runs of blank lines, and trailing
# blank lines at EOF: the three ways a copy-paste or an editor's "format on save"
# differs from the registry without a single rule having changed.
lines = [(ln + "   " if ln.strip() else ln) for ln in open(p).read().splitlines()]
t = "\n".join(lines).replace("## Session boundaries", "\n\n\n## Session boundaries\n\n")
open(p, "w").write(t + "\n\n\n")
PY
assert "trailing space + blank runs are not drift" 0 "OK: machine and registry agree" "$M/ws.md"

# 3. Headings are dropped before comparing — renaming an H2 is not a rule change.
write_registry "$M/heading.md"
sed -i.bak 's/^## Session boundaries$/## Session boundaries and restarts (all projects)/' "$M/heading.md"
assert "renamed heading is not drift" 0 "OK: machine and registry agree" "$M/heading.md"

# 4-6. DEFAULT differences: exit 0, direction named.
write_registry "$M/dflt-machine.md"
printf 'Prefer the cheapest tier that can do the job.\n' >> "$M/dflt-machine.md"
assert "default: machine-only line -> machine-ahead" 0 "machine-ahead" "$M/dflt-machine.md"

write_registry "$M/dflt-registry.md"
sed -i.bak '/Mechanical work runs on the cheapest adequate tier./d' "$M/dflt-registry.md"
assert "default: line only in registry -> registry-ahead" 0 "registry-ahead" "$M/dflt-registry.md"

write_registry "$M/dflt-both.md"
sed -i.bak 's/Mechanical work runs on the cheapest adequate tier./Mechanical work runs on haiku./' "$M/dflt-both.md"
assert "default: both sides moved -> both" 0 "both" "$M/dflt-both.md"

# A default difference must NOT be reported as floor drift, and must say the floor is intact.
assert "default drift says the floor is intact" 0 "The floor is intact" "$M/dflt-both.md"

# 7-8. FLOOR differences: exit 1.
write_registry "$M/floor-text.md"
sed -i.bak 's/Never `git add -A`, `.`, `-u`, or a directory./Never `git add -A`./' "$M/floor-text.md"
assert "floor: reworded rule -> exit 1" 1 "FLOOR DRIFT" "$M/floor-text.md"

write_registry "$M/floor-missing.md"
python3 - "$M/floor-missing.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("<!--floor:seed-written-outside-any-worktree-->\n"
              "The seed is written outside any worktree, at an absolute path.\n", "")
open(p, "w").write(t)
PY
assert "floor: rule deleted on the machine -> exit 1" 1 "seed-written-outside-any-worktree" "$M/floor-missing.md"

# 9. Duplicated floor id: the comparison is ambiguous, so it is a floor failure.
write_registry "$M/floor-dup.md"
cat >> "$M/floor-dup.md" <<'MD'

<!--floor:worktree-by-default-->
A second, conflicting copy of the same rule id.
MD
assert "floor: duplicated id -> exit 1" 1 "DUPLICATE" "$M/floor-dup.md"

# 10. A default rule promoted to floor on one node only is a class mismatch, not silence.
write_registry "$M/class-mismatch.md"
sed -i.bak 's|<!--default:model-tiering-->|<!--floor:model-tiering-->|' "$M/class-mismatch.md"
assert "floor: class promoted on one node -> exit 1" 1 "model-tiering" "$M/class-mismatch.md"
write_registry "$M/duplicate-promoted.md"
cat >> "$M/duplicate-promoted.md" <<'MD'

<!--floor:model-tiering-->
A conflicting floor-classed duplicate.
MD
assert "floor: duplicate promotion cannot hide in default rule" 1 "DUPLICATE" \
  "$M/duplicate-promoted.md"

# 11. Missing machine copy: cannot verify, never 0.
assert "missing machine copy -> exit 2" 2 "cannot verify" "$M/does-not-exist.md"

# Adapters are load-bearing. A missing or malformed adapter cannot claim agreement.
assert "missing Claude adapter -> exit 2" 2 "Claude adapter" "$M/identical.md" \
  --claude "$TMP/missing-claude.md"
assert "missing Codex adapter -> exit 2" 2 "Codex adapter" "$M/identical.md" \
  --codex "$TMP/missing-codex.md"
assert "missing Gemini adapter -> exit 2" 2 "Gemini adapter" "$M/identical.md" \
  --gemini "$TMP/missing-gemini.md"
printf '\377\n' > "$M/invalid-utf8.md"
assert "unreadable adapter text -> exit 2" 2 "invalid UTF-8" "$M/identical.md" \
  --gemini "$M/invalid-utf8.md"
printf '# No import\n' > "$M/bad-claude.md"
assert "Claude adapter without standalone import -> exit 2" 2 "standalone" "$M/identical.md" \
  --claude "$M/bad-claude.md"
printf '# Hidden in prose: @~/.fleet/AGENTS.md\n' > "$M/bad-claude.md"
assert "Claude prose mention is not an import" 2 "standalone" "$M/identical.md" \
  --claude "$M/bad-claude.md"
cat > "$M/fenced-claude.md" <<'MD'
```md
@~/.fleet/AGENTS.md
```
MD
assert "Claude import inside fence is inactive" 2 "active standalone" "$M/identical.md" \
  --claude "$M/fenced-claude.md"
cat > "$M/comment-claude.md" <<'MD'
<!--
@~/.fleet/AGENTS.md
-->
MD
assert "Claude import inside HTML comment is inactive" 2 "active standalone" "$M/identical.md" \
  --claude "$M/comment-claude.md"
cat > "$M/extra-import-claude.md" <<'MD'
@~/.fleet/AGENTS.md
@~/.claude/other-rules.md
MD
assert "unaccounted Claude import -> exit 2" 2 "additional" "$M/identical.md" \
  --claude "$M/extra-import-claude.md"
cat > "$M/extra-default-claude.md" <<'MD'
@~/.fleet/AGENTS.md

<!--default:claude-local-->
Claude-only local guidance.
MD
assert "Claude-only default is informational" 0 "DEFAULT drift only" "$M/identical.md" \
  --claude "$M/extra-default-claude.md"
cat > "$M/redefined-floor-claude.md" <<'MD'
@~/.fleet/AGENTS.md

<!--floor:no-agent-attribution-->
Claude-only wording contradicts the fleet floor.
MD
assert "Claude tagged floor redefinition -> exit 1" 1 "DUPLICATE" "$M/identical.md" \
  --claude "$M/redefined-floor-claude.md"
cat > "$M/fenced-floor-claude.md" <<'MD'
@~/.fleet/AGENTS.md

```md
<!--floor:no-agent-attribution-->
This is an example, not an active rule.
```
MD
assert "fenced floor example does not redefine rule" 0 "OK:" "$M/identical.md" \
  --claude "$M/fenced-floor-claude.md"

write_registry "$M/codex-floor.md"
sed -i.bak 's/No tokens, no keys, no credentials, ever./No tokens, no keys, ever./' "$M/codex-floor.md"
assert "Codex copied floor drift -> exit 1" 1 "FLOOR DRIFT" "$M/identical.md" \
  --codex "$M/codex-floor.md"
write_registry "$M/gemini-floor.md"
sed -i.bak 's/No tokens, no keys, no credentials, ever./No tokens, no keys, ever./' "$M/gemini-floor.md"
assert "Gemini copied floor drift -> exit 1" 1 "FLOOR DRIFT" "$M/identical.md" \
  --gemini "$M/gemini-floor.md"
write_registry "$M/codex-local.md"
cat >> "$M/codex-local.md" <<'MD'

<!--default:private-machine-note-->
Private machine-specific guidance stays local.
MD
assert "tokenized private addition is informational" 0 "machine-ahead" "$M/identical.md" \
  --codex "$M/codex-local.md"

printf 'shadow\n' > "$TMP/home/.codex/AGENTS.override.md"
assert "nonempty Codex global override -> exit 2" 2 "shadows" "$M/identical.md"
rm "$TMP/home/.codex/AGENTS.override.md"

printf 'project_doc_max_bytes = 32768\n' > "$M/small-config.toml"
assert "Codex default-sized cap -> exit 2" 2 "65536" "$M/identical.md" \
  --codex-config "$M/small-config.toml"
printf 'project_doc_max_bytes = broken\n' > "$M/bad-config.toml"
assert "malformed Codex cap -> exit 2" 2 "invalid project_doc_max_bytes" "$M/identical.md" \
  --codex-config "$M/bad-config.toml"
assert "missing Codex config -> exit 2" 2 "Codex config" "$M/identical.md" \
  --codex-config "$M/missing-config.toml"
cat > "$M/sections-config.toml" <<'TOML'
project_doc_max_bytes = 65536
[projects."/Users/example/Project"]
trust_level = "trusted"
TOML
assert "Codex config with quoted project section parses" 0 "OK:" "$M/identical.md" \
  --codex-config "$M/sections-config.toml"

out=$(CODEX_HOME="$TMP/home/.codex" python3 "$SUT" --machine "$M/identical.md" \
  --claude "$TMP/home/.claude/CLAUDE.md" --gemini "$TMP/home/.gemini/GEMINI.md" \
  --repo "$TMP/clone" --project-dir "$TMP/clone" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "CODEX_HOME selects Codex defaults"; else
  bad "CODEX_HOME selects Codex defaults" "exit $rc — $out"
fi

mkdir -p "$TMP/clone/sub"
python3 - "$TMP/clone/sub/AGENTS.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 65000)
PY
assert "effective project chain over cap -> exit 2" 2 "full loading cannot be verified" \
  "$M/identical.md" --project-dir "$TMP/clone/sub"
rm "$TMP/clone/sub/AGENTS.md"
python3 - "$TMP/clone/AGENTS.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 65000)
PY
assert "ancestor project instruction contributes to cap" 2 "full loading cannot be verified" \
  "$M/identical.md" --project-dir "$TMP/clone/sub"
rm "$TMP/clone/AGENTS.md"

cat > "$M/fallback-config.toml" <<'TOML'
project_doc_max_bytes = 65536
project_doc_fallback_filenames = ["LOCAL.md"]
TOML
python3 - "$TMP/clone/sub/LOCAL.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 65000)
PY
assert "selected fallback file contributes to cap" 2 "full loading cannot be verified" \
  "$M/identical.md" --codex-config "$M/fallback-config.toml" --project-dir "$TMP/clone/sub"
touch "$TMP/clone/sub/AGENTS.override.md"
assert "empty override must not hide oversized fallback" 2 "full loading cannot be verified" \
  "$M/identical.md" --codex-config "$M/fallback-config.toml" --project-dir "$TMP/clone/sub"
touch "$TMP/clone/sub/AGENTS.md"
assert "empty AGENTS must not hide oversized fallback" 2 "full loading cannot be verified" \
  "$M/identical.md" --codex-config "$M/fallback-config.toml" --project-dir "$TMP/clone/sub"
rm "$TMP/clone/sub/AGENTS.override.md" "$TMP/clone/sub/AGENTS.md"
printf 'small project file\n' > "$TMP/clone/sub/AGENTS.md"
assert "AGENTS.md takes precedence over fallback" 0 "OK:" "$M/identical.md" \
  --codex-config "$M/fallback-config.toml" --project-dir "$TMP/clone/sub"
python3 - "$TMP/clone/sub/AGENTS.override.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 65000)
PY
assert "selected project override contributes to cap" 2 "full loading cannot be verified" \
  "$M/identical.md" --codex-config "$M/fallback-config.toml" --project-dir "$TMP/clone/sub"
rm "$TMP/clone/sub/AGENTS.override.md" "$TMP/clone/sub/AGENTS.md" "$TMP/clone/sub/LOCAL.md"

assert "non-repository project directory uses only itself" 0 "OK:" "$M/identical.md" \
  --project-dir "$M"
mkdir -p "$TMP/git-shim"
cat > "$TMP/git-shim/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = rev-parse ] && [ "${4:-}" = --show-toplevel ]; then
  echo 'fatal: Git probe unavailable' >&2
  exit 128
fi
exec "$FLEET_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP/git-shim/git"
out=$(PATH="$TMP/git-shim:$PATH" FLEET_TEST_REAL_GIT="$(command -v git)" \
  python3 "$SUT" --machine "$M/identical.md" --repo "$TMP/clone" "${CHECK_ARGS[@]}" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'Git root probe failed'; then
  ok "failed Git root probe refuses to guess project chain"
else
  bad "failed Git root probe refuses to guess project chain" "exit $rc — $out"
fi

python3 - "$M/oversized-root.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('x' * 66000)
PY
assert "oversized fleet root -> exit 2" 2 "fleet root" "$M/oversized-root.md"

# 12. THE fetch precondition. origin moves a FLOOR rule; the clone is never pulled.
#     If the fetch were softened with `|| true`, this would compare against the stale
#     clone and print OK. It must instead see origin's new copy and fail.
write_registry "$M/identical2.md"
python3 - "$TMP/seed/assets/AGENTS.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("**Never commit a secret.** No tokens, no keys, no credentials, ever.",
              "**Never commit a secret.** No tokens, no keys, no credentials, and no seed content.")
open(p, "w").write(t)
PY
git -C "$TMP/seed" commit --quiet -am "registry moves a floor rule"
git -C "$TMP/seed" push --quiet origin HEAD:main
before=$(git -C "$TMP/clone" rev-parse origin/main)
assert "fetch is load-bearing: origin moved a floor rule -> exit 1" 1 "no-secrets-in-committed-files" "$M/identical2.md"
after=$(git -C "$TMP/clone" rev-parse origin/main)
if [ "$before" = "$after" ]; then
  bad "fetch actually updated the clone's origin/main" "origin/main did not move: $before"
else
  ok "fetch actually updated the clone's origin/main"
fi

# 13. Fetch failure must refuse rather than lie. Point origin at nothing.
git -C "$TMP/clone" remote set-url origin "$TMP/no-such-repo.git"
out=$(python3 "$SUT" --machine "$M/identical2.md" --repo "$TMP/clone" "${CHECK_ARGS[@]}" 2>&1); rc=$?
if [ "$rc" -ne 2 ]; then
  bad "unfetchable origin -> exit 2" "exit $rc"
elif printf '%s' "$out" | grep -q "OK:"; then
  bad "unfetchable origin must not claim agreement" "$out"
else
  ok "unfetchable origin -> exit 2, no agreement claimed"
fi
git -C "$TMP/clone" remote set-url origin "$TMP/origin"

# 14. The floor set is itself an invariant: a sixth floor token in the registry fails.
cat >> "$TMP/seed/assets/AGENTS.md" <<'MD'

<!--floor:invented-sixth-rule-->
A rule someone promoted to the floor without updating fleet-check.py.
MD
git -C "$TMP/seed" commit --quiet -am "registry grows a sixth floor rule"
git -C "$TMP/seed" push --quiet origin HEAD:main
write_registry "$M/identical3.md"
assert "a sixth floor rule in the registry -> exit 1" 1 "FLOOR-SET" "$M/identical3.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
