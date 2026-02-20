paths: deploy.sh, sync.sh

- macOS ships bash 3.2. Do not use associative arrays (`declare -A`) or heredocs inside command substitution (`$(cat <<'EOF' ... EOF)`). Use parallel indexed arrays and `read -r -d '' var <<'DELIM' || true` for multi-line strings.
