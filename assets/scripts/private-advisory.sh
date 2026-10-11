#!/usr/bin/env bash
# List first; creation requires the digest of the list the coordinator reviewed.
# All advisory data stays in gh/private vault output, never in repository files.
set -euo pipefail

repo=''
finding_file=''
summary=''
severity=''
ecosystem=''
package=''
reviewed_list=''
reuse=''
create=false
usage() {
  cat <<'EOF'
Usage: private-advisory.sh --repo OWNER/REPO
       private-advisory.sh --repo OWNER/REPO --reuse GHSA-ID
       private-advisory.sh --repo OWNER/REPO --create --reviewed-list SHA256
         --finding-file /absolute/vault/file --summary SUMMARY
         --severity low|medium|high|critical --ecosystem ECOSYSTEM --package NAME

Run list-only first and inspect the summaries. If one covers the finding, use
--reuse and create nothing. Otherwise pass that list's digest to --create.
Creation also stops on an exact summary match. A changed list requires review.
Only an HTTP 422 is retried, once, after a fresh list and duplicate check.
EOF
}
refuse() { printf 'REFUSE: %s\n' "$1" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --create) create=true; shift ;;
    --help) usage; exit 0 ;;
    --repo|--finding-file|--summary|--severity|--ecosystem|--package|--reviewed-list|--reuse)
      [ "$#" -ge 2 ] || refuse "missing value for $1"
      case "$1" in
        --repo) repo=$2 ;; --finding-file) finding_file=$2 ;;
        --summary) summary=$2 ;; --severity) severity=$2 ;;
        --ecosystem) ecosystem=$2 ;; --package) package=$2 ;;
        --reviewed-list) reviewed_list=$2 ;; --reuse) reuse=$2 ;;
      esac
      shift 2 ;;
    *) refuse "unknown argument $1" ;;
  esac
done
[[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || refuse 'provide --repo OWNER/REPO'
[ "$create" = false ] || [ -z "$reuse" ] || refuse '--create and --reuse are mutually exclusive'
endpoint="repos/$repo/security-advisories"
list=''
digest=''
matched=''
read_list() {
  # Slurp all pages, then canonicalize so API ordering cannot invalidate review.
  list=$(gh api --paginate --slurp "$endpoint" | jq -ce 'add | if type == "array" then sort_by(.ghsa_id) else error("invalid advisory list") end') || refuse 'could not list advisories; no draft created'
  digest=$(printf '%s' "$list" | shasum -a 256 | awk '{print $1}')
  printf '%s\n' "$list" | jq -r '.[] | [.ghsa_id, .state, .summary] | @tsv'
  printf 'reviewed-list: %s\n' "$digest"
  matched=$(printf '%s\n' "$list" | jq -r --arg summary "$summary" --arg reuse "$reuse" '.[] | select(($reuse != "" and .ghsa_id == $reuse) or ($summary != "" and .summary == $summary)) | .ghsa_id' | head -n 1)
}
read_list
if [ -n "$matched" ]; then
  printf 'Existing advisory: %s; no draft created.\n' "$matched"
  exit 0
fi
[ -z "$reuse" ] || refuse 'requested advisory is absent; no draft created'
[ "$create" = true ] || exit 0
[ "$reviewed_list" = "$digest" ] || refuse 'list differs from the reviewed digest; inspect it before creation'
[ -n "$summary" ] && [ -n "$ecosystem" ] && [ -n "$package" ] || refuse 'summary, ecosystem and package are required'
case "$severity" in low|medium|high|critical) ;; *) refuse 'invalid severity' ;; esac
case "$finding_file" in /*) ;; *) refuse 'finding file must be absolute' ;; esac
[ -r "$finding_file" ] && [ -f "$finding_file" ] || refuse 'finding file is not readable'
python3 - "$finding_file" "$HOME/Obsidian/no-it-all/security" <<'PY' || refuse 'finding file must remain beneath the security vault after resolving symlinks'
from pathlib import Path
import sys
try:
    finding, vault = (Path(p).resolve(strict=True) for p in sys.argv[1:])
    if not vault.is_dir() or not finding.is_file() or vault not in finding.parents:
        sys.exit(1)
except (OSError, RuntimeError):
    sys.exit(1)
PY

# The body and POST run in this invocation; failure to build never reaches gh.
body=$(jq -n --arg summary "$summary" --rawfile description "$finding_file" \
  --arg severity "$severity" --arg ecosystem "$ecosystem" --arg name "$package" \
  '{summary: $summary, description: $description, severity: $severity,
    vulnerabilities: [{package: {ecosystem: $ecosystem, name: $name}}]}') || refuse 'could not build advisory body'
error_file=$(mktemp "${TMPDIR:-/tmp}/private-advisory.XXXXXX")
chmod 600 "$error_file"
trap 'rm -f "$error_file"' EXIT
post() { printf '%s' "$body" | gh api -X POST "$endpoint" --input - --jq .ghsa_id 2>"$error_file"; }
if post; then exit 0; fi
if ! grep -Eq '(^|[^0-9])HTTP 422([^0-9]|$)' "$error_file"; then
  cat "$error_file" >&2
  refuse 'draft creation failed; retain the vault record; 1 finding withheld'
fi
read_list
if [ -n "$matched" ]; then
  printf 'Existing advisory: %s; no second draft created.\n' "$matched"
  exit 0
fi
[ "$reviewed_list" = "$digest" ] || refuse 'list changed after HTTP 422; review it; 1 finding withheld'
if post; then exit 0; fi
cat "$error_file" >&2
refuse 'retry failed; retain the vault record; 1 finding withheld'
