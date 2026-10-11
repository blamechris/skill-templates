#!/usr/bin/env bash
# Never contacts GitHub. gh on PATH is a fixture that records every POST.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d /tmp/private-advisory-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' POST '* ]]; then
  cat > "$CASE/body.json"
  count=$(cat "$CASE/count" 2>/dev/null || printf 0)
  count=$((count + 1)); printf '%s' "$count" > "$CASE/count"
  case "${FAIL_POST:-}" in
    500) echo 'gh: failure (HTTP 500)' >&2; exit 1 ;;
    422) echo 'gh: invalid (HTTP 422)' >&2; exit 1 ;;
    once) if [ "$count" -eq 1 ]; then echo 'gh: conflict (HTTP 422)' >&2; exit 1; fi ;;
    concurrent) printf '[{"ghsa_id":"GHSA-existing","state":"draft","summary":"Neutral behavior"}]' > "$CASE/list.json"; echo 'gh: conflict (HTTP 422)' >&2; exit 1 ;;
    changed) printf '[{"ghsa_id":"GHSA-other","state":"draft","summary":"Other"}]' > "$CASE/list.json"; echo 'gh: conflict (HTTP 422)' >&2; exit 1 ;;
  esac
  echo GHSA-created
else
  [ "${FAIL_LIST:-}" != yes ] || { echo 'gh list failed' >&2; exit 1; }
  # --paginate --slurp returns one array per page.
  jq -s '.' "$CASE/list.json"
fi
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$out"; }
new_case() {
  export CASE="$TMP/$1"; mkdir "$CASE"; printf '[]' > "$CASE/list.json"
  printf 'Private fixture description\nwith newline and "quotes"\n' > "$CASE/finding.md"
  unset FAIL_POST FAIL_LIST
  out=$("$HERE/private-advisory.sh" --repo fixture/repo); rc=$?
  digest=$(printf '%s\n' "$out" | sed -n 's/^reviewed-list: //p')
}
create() {
  out=$("$HERE/private-advisory.sh" --repo fixture/repo --create --reviewed-list "$digest" \
    --summary 'Neutral behavior' --finding-file "$CASE/finding.md" \
    --severity high --ecosystem other --package fixture); rc=$?
}
count() { cat "$CASE/count" 2>/dev/null || printf 0; }
new_case list
[ "$rc" -eq 0 ] && [ "$(count)" -eq 0 ] && [ -n "$digest" ] && ok 'list only never posts' || bad 'list only never posts'
create
[ "$rc" -eq 0 ] && [ "$(count)" -eq 1 ] && \
  jq -e --rawfile text "$CASE/finding.md" '.description == $text and .severity == "high" and .vulnerabilities[0].package.name == "fixture"' "$CASE/body.json" >/dev/null &&
  ok 'one POST carries raw vault text and declared metadata' || bad 'one POST carries raw vault text and declared metadata'
new_case duplicate
printf '[{"ghsa_id":"GHSA-existing","state":"draft","summary":"Neutral behavior"}]' > "$CASE/list.json"
create
[ "$rc" -eq 0 ] && [ "$(count)" -eq 0 ] && [[ "$out" == *GHSA-existing* ]] && ok 'matching summary stops creation' || bad 'matching summary stops creation'
out=$("$HERE/private-advisory.sh" --repo fixture/repo --reuse GHSA-existing); rc=$?
[ "$rc" -eq 0 ] && [ "$(count)" -eq 0 ] && ok 'coordinator can reuse semantic match by ID' || bad 'coordinator can reuse semantic match by ID'
out=$("$HERE/private-advisory.sh" --repo fixture/repo --reuse GHSA-absent); rc=$?
[ "$rc" -eq 2 ] && [ "$(count)" -eq 0 ] && ok 'absent reuse never creates' || bad 'absent reuse never creates'
new_case digest
digest=wrong; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 0 ] && ok 'unreviewed list prevents creation' || bad 'unreviewed list prevents creation'
new_case missing
rm "$CASE/finding.md"; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 0 ] && ok 'missing body cannot POST' || bad 'missing body cannot POST'
new_case jqfailure
# Wrap jq to fail only body construction; list handling remains valid.
JQ_REAL=$(command -v jq); export JQ_REAL
cat > "$TMP/bin/jq" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -n ]; then exit 1; fi
exec "$JQ_REAL" "$@"
SH
chmod +x "$TMP/bin/jq"
create; rm "$TMP/bin/jq"
[ "$rc" -eq 2 ] && [ "$(count)" -eq 0 ] && ok 'jq body failure cannot POST' || bad 'jq body failure cannot POST'
new_case listfailure
export FAIL_LIST=yes; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 0 ] && ok 'list failure cannot POST' || bad 'list failure cannot POST'
new_case otherfailure
export FAIL_POST=500; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 1 ] && ok 'non-422 failure is final' || bad 'non-422 failure is final'
new_case retry
export FAIL_POST=once; create
[ "$rc" -eq 0 ] && [ "$(count)" -eq 2 ] && ok '422 retries once after unchanged relist' || bad '422 retries once after unchanged relist'
new_case twice
export FAIL_POST=422; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 2 ] && ok 'second 422 is final' || bad 'second 422 is final'
new_case concurrent
export FAIL_POST=concurrent; create
[ "$rc" -eq 0 ] && [ "$(count)" -eq 1 ] && [[ "$out" == *GHSA-existing* ]] && ok '422 relist discovers duplicate without retry' || bad '422 relist discovers duplicate without retry'
new_case changed
export FAIL_POST=changed; create
[ "$rc" -eq 2 ] && [ "$(count)" -eq 1 ] && ok 'changed relist needs coordinator review' || bad 'changed relist needs coordinator review'
printf '%s passed; %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
