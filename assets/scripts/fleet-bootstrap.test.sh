#!/usr/bin/env bash
# End-to-end regression checks for fleet-bootstrap.py. Every target is under TMP.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REGISTRY=$(cd "$HERE/../.." && pwd)
SUT="$HERE/fleet-bootstrap.py"
PY=$(command -v python3.12 || command -v python3.11 || command -v python3.13 || command -v python3.14 || command -v python3)
"$PY" -c 'import sys; assert sys.version_info >= (3, 11)' || {
  echo 'Python 3.11+ required'
  exit 1
}
TMP=$(mktemp -d /tmp/fleet-bootstrap-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -z "$2" ] || printf '       %s\n' "$2"; }
new_case() { mkdir -p "$TMP/$1/home"; }
run() {
  local name=$1
  shift
  out=$("$PY" "$SUT" --registry "$REGISTRY" --home "$TMP/$name/home" "$@" 2>&1)
  rc=$?
}
empty_home() { [ -z "$(ls -A "$TMP/$1/home")" ]; }
no_install() { [ ! -e "$TMP/$1/home/.fleet/AGENTS.md" ] && [ ! -e "$TMP/$1/home/.codex/AGENTS.md" ]; }

echo 'fleet-bootstrap.test.sh'

# Planning a fresh install must leave even the destination directories absent.
new_case dry
run dry
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PLAN: ' &&
  printf '%s' "$out" | grep -q 'Dry run; no files changed.' &&
  empty_home dry &&
  ok 'dry-run plans a fresh install without writing any file or directory' ||
  bad 'dry-run plans a fresh install without writing any file or directory' "rc=$rc $out"

# A late differing file must be detected before the first planned file is written.
new_case refuse
mkdir -p "$TMP/refuse/home/.gemini"
printf 'incumbent Gemini\n' > "$TMP/refuse/home/.gemini/GEMINI.md"
run refuse --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE: .*GEMINI.md differs' &&
  no_install refuse &&
  [ "$(cat "$TMP/refuse/home/.gemini/GEMINI.md")" = 'incumbent Gemini' ] &&
  [ ! -d "$TMP/refuse/home/.fleet/backups" ] &&
  ok 'existing-file refusal happens before any mutation or backup' ||
  bad 'existing-file refusal happens before any mutation or backup' "rc=$rc $out"

# Replacement preserves all incumbents in a private backup, retains unrelated
# TOML keys and table values, and leaves Claude untouched without live proof.
new_case replace
home="$TMP/replace/home"
mkdir -p "$home/.fleet" "$home/.gemini" "$home/.codex" "$home/.claude"
printf 'incumbent root\n' > "$home/.fleet/AGENTS.md"
printf 'incumbent Gemini\n' > "$home/.gemini/GEMINI.md"
printf 'incumbent Claude\n' > "$home/.claude/CLAUDE.md"
cat > "$home/.codex/config.toml" <<'TOML'
model = "gpt-existing"
project_doc_max_bytes = 8192
[sandbox_workspace_write]
network_access = true
TOML
run replace --replace-existing --apply
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^Backups: ' &&
  ok 'replacement applies after explicit reconciliation flag' ||
  bad 'replacement applies after explicit reconciliation flag' "rc=$rc $out"
backup_paths=$(find "$home/.fleet/backups" -name paths.txt -print)
backup=$(dirname "$backup_paths")
[ -f "$backup/0-AGENTS.md" ] &&
  [ "$(cat "$backup/0-AGENTS.md")" = 'incumbent root' ] &&
  [ "$(cat "$backup/1-GEMINI.md")" = 'incumbent Gemini' ] &&
  grep -q 'project_doc_max_bytes = 8192' "$backup/2-config.toml" &&
  [ "$(wc -l < "$backup/paths.txt")" -eq 3 ] &&
  "$PY" -c 'import pathlib, stat, sys; assert stat.S_IMODE(pathlib.Path(sys.argv[1]).stat().st_mode) == 0o700' "$backup" &&
  ok 'all replaced files have private, readable backups' ||
  bad 'all replaced files have private, readable backups' "$backup_paths"
"$PY" -c 'import pathlib, sys, tomllib; d=tomllib.loads(pathlib.Path(sys.argv[1]).read_text()); assert d["project_doc_max_bytes"] == 65536; assert d["model"] == "gpt-existing"; assert d["sandbox_workspace_write"]["network_access"] is True' "$home/.codex/config.toml"
config_rc=$?
[ "$config_rc" -eq 0 ] &&
  ok 'instruction cap rises while model and table settings survive' ||
  bad 'instruction cap rises while model and table settings survive' "rc=$config_rc"
cmp -s "$home/.fleet/AGENTS.md" "$home/.codex/AGENTS.md" &&
  cmp -s "$home/.fleet/AGENTS.md" "$home/.gemini/GEMINI.md" &&
  cmp -s "$home/.fleet/AGENTS.md" "$REGISTRY/assets/AGENTS.md" &&
  ok 'provider copies equal the published root' ||
  bad 'provider copies equal the published root' 'provider copies differ'
[ "$(cat "$home/.claude/CLAUDE.md")" = 'incumbent Claude' ] &&
  printf '%s' "$out" | grep -q 'HOLD: Claude adapter unchanged' &&
  ok 'Claude stays untouched without the live import proof flag' ||
  bad 'Claude stays untouched without the live import proof flag' "$out"

# Explicit proof activates Claude. Private additions are retained in the root
# and the Claude-only adapter respectively, without changing the source assets.
new_case activate
home="$TMP/activate/home"
printf 'Machine-only rule: keep private notes local.\n' > "$TMP/activate/local.md"
printf 'Claude-only machine line.\n' > "$TMP/activate/claude-extra.md"
run activate --local-rules "$TMP/activate/local.md" \
  --claude-extra "$TMP/activate/claude-extra.md" \
  --claude-import-verified --apply
[ "$rc" -eq 0 ] && [ -f "$home/.claude/CLAUDE.md" ] &&
  grep -q 'Claude-only machine line.' "$home/.claude/CLAUDE.md" &&
  ok 'explicit live-proof flag activates the Claude import' ||
  bad 'explicit live-proof flag activates the Claude import' "rc=$rc $out"
grep -q '<!--default:machine-local-->' "$home/.fleet/AGENTS.md" &&
  grep -q 'Machine-only rule: keep private notes local.' "$home/.fleet/AGENTS.md" &&
  cmp -s "$home/.fleet/AGENTS.md" "$home/.codex/AGENTS.md" &&
  cmp -s "$home/.fleet/AGENTS.md" "$home/.gemini/GEMINI.md" &&
  ok 'reviewed local additions remain in every root copy' ||
  bad 'reviewed local additions remain in every root copy' 'root copies or additions differ'

# Reapplying identical inputs needs no replacement flag and creates no backups.
run activate --local-rules "$TMP/activate/local.md" \
  --claude-extra "$TMP/activate/claude-extra.md" \
  --claude-import-verified --apply
[ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q '^WRITE: ' &&
  [ ! -d "$home/.fleet/backups" ] &&
  ok 'a second identical apply is idempotent' ||
  bad 'a second identical apply is idempotent' "rc=$rc $out"

# Configuration parsing and override validation must fail before any install.
new_case malformed
mkdir -p "$TMP/malformed/home/.codex"
printf '[broken\n' > "$TMP/malformed/home/.codex/config.toml"
run malformed --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE:' &&
  no_install malformed &&
  [ "$(cat "$TMP/malformed/home/.codex/config.toml")" = '[broken' ] &&
  ok 'malformed config refuses without installing files' ||
  bad 'malformed config refuses without installing files' "rc=$rc $out"

new_case override
mkdir -p "$TMP/override/home/.codex"
printf 'shadowing instructions\n' > "$TMP/override/home/.codex/AGENTS.override.md"
run override --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE: .*shadows the Codex adapter' &&
  no_install override &&
  [ ! -d "$TMP/override/home/.fleet/backups" ] &&
  ok 'nonempty override refuses before mutation' ||
  bad 'nonempty override refuses before mutation' "rc=$rc $out"

# A symlink is not a regular incumbent to back up and replace.
new_case symlink
mkdir -p "$TMP/symlink/home/.codex"
printf 'external target\n' > "$TMP/symlink/target.md"
ln -s "$TMP/symlink/target.md" "$TMP/symlink/home/.codex/AGENTS.md"
run symlink --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE: .*is a symlink' &&
  [ -L "$TMP/symlink/home/.codex/AGENTS.md" ] &&
  [ "$(cat "$TMP/symlink/target.md")" = 'external target' ] &&
  [ ! -e "$TMP/symlink/home/.fleet/AGENTS.md" ] &&
  ok 'symlink adapter refuses without touching its target' ||
  bad 'symlink adapter refuses without touching its target' "rc=$rc $out"

# Directory symlinks can redirect an apparently regular adapter file outside
# the requested home. The whole destination path must remain within that home.
new_case symlink_parent
mkdir -p "$TMP/symlink_parent/external"
ln -s "$TMP/symlink_parent/external" "$TMP/symlink_parent/home/.codex"
run symlink_parent --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE: .*symlink' &&
  [ ! -e "$TMP/symlink_parent/external/AGENTS.md" ] &&
  [ ! -e "$TMP/symlink_parent/home/.fleet/AGENTS.md" ] &&
  ok 'symlinked destination directory refuses before any write' ||
  bad 'symlinked destination directory refuses before any write' "rc=$rc $out"

# Private additions must not smuggle rule tokens into installed adapters.
# fleet-check accepts whitespace around the token class, so bootstrap must too.
new_case spaced_floor
printf '<!-- floor:rogue-floor -->\nA second floor.\n' > "$TMP/spaced_floor/local.md"
run spaced_floor --local-rules "$TMP/spaced_floor/local.md" --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE:' &&
  no_install spaced_floor &&
  ok 'spaced floor token in local additions refuses before installation' ||
  bad 'spaced floor token in local additions refuses before installation' "rc=$rc $out"

new_case duplicate_default
printf '<!--default:rule-precedence-->\nA duplicate default.\n' > "$TMP/duplicate_default/local.md"
run duplicate_default --local-rules "$TMP/duplicate_default/local.md" --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE:' &&
  no_install duplicate_default &&
  ok 'duplicate default ID in local additions refuses' ||
  bad 'duplicate default ID in local additions refuses' "rc=$rc $out"

new_case claude_floor
printf '<!--floor:rogue-floor-->\nA Claude-only floor.\n' > "$TMP/claude_floor/extra.md"
run claude_floor --claude-extra "$TMP/claude_floor/extra.md" --claude-import-verified --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE:' &&
  no_install claude_floor &&
  [ ! -e "$TMP/claude_floor/home/.claude/CLAUDE.md" ] &&
  ok 'Claude-only floor token refuses before activation' ||
  bad 'Claude-only floor token refuses before activation' "rc=$rc $out"

new_case claude_spaced_floor
printf '<!-- floor:rogue-floor -->\nA Claude-only floor.\n' > "$TMP/claude_spaced_floor/extra.md"
run claude_spaced_floor --claude-extra "$TMP/claude_spaced_floor/extra.md" --claude-import-verified --apply
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE:' &&
  no_install claude_spaced_floor &&
  [ ! -e "$TMP/claude_spaced_floor/home/.claude/CLAUDE.md" ] &&
  ok 'spaced Claude-only floor token refuses before activation' ||
  bad 'spaced Claude-only floor token refuses before activation' "rc=$rc $out"

new_case backup_link
mkdir -p "$TMP/backup_link/home/.fleet" "$TMP/backup_link/external"
printf 'private incumbent\n' > "$TMP/backup_link/home/.fleet/AGENTS.md"
ln -s "$TMP/backup_link/external" "$TMP/backup_link/home/.fleet/backups"
run backup_link --replace-existing --apply
[ "$rc" -eq 2 ] && [ -z "$(ls -A "$TMP/backup_link/external")" ] &&
  [ "$(cat "$TMP/backup_link/home/.fleet/AGENTS.md")" = 'private incumbent' ] &&
  [ ! -e "$TMP/backup_link/home/.codex" ] &&
  ok 'symlinked backup directory refuses before any mutation' ||
  bad 'symlinked backup directory refuses before any mutation' "rc=$rc $out"

new_case inactive_gemini
mkdir -p "$TMP/inactive_gemini/home/.gemini"
printf '{"context":{"fileName":["AGENTS.md"]}}\n' > "$TMP/inactive_gemini/home/.gemini/settings.json"
run inactive_gemini --apply
[ "$rc" -eq 2 ] && no_install inactive_gemini &&
  ok 'inactive Gemini filename refuses before installation' ||
  bad 'inactive Gemini filename refuses before installation' "rc=$rc $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
