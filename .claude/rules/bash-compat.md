paths: deploy.sh, sync.sh

- macOS ships bash 3.2. Do not use associative arrays (`declare -A`). Use parallel indexed arrays instead.
- For large multi-line string assignments, prefer `read -r -d '' var <<'DELIM' || true` over `var=$(cat <<'DELIM' ... DELIM)` — the latter works for simple content but can fail with complex escaping contexts in bash 3.2.
