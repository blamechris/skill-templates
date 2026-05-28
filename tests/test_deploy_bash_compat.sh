#!/usr/bin/env bash
# tests/test_deploy_bash_compat.sh — Regression tests for bash 3.2 array
# guard patterns in deploy.sh. Issue #23 documented three crash classes;
# this harness exists per #25 to prevent regressions.
#
# Two test categories:
#   1. Runtime tests — invoke deploy.sh with controlled inputs (all --dry-run
#      so no API keys are required) and assert clean exit + no bash-internal
#      error patterns in output.
#   2. Static tests — grep deploy.sh for `for X in "${ARRAY[@]}"` patterns and
#      verify each is preceded by a `[ ${#ARRAY[@]} -gt 0 ]` length guard
#      within 10 lines. Catches a regression class that runtime tests miss
#      (a new unguarded iteration added to an array that's empty in
#      production but accidentally non-empty in tests).
#
# Run locally: bash tests/test_deploy_bash_compat.sh
# Exit code: 0 on all-pass, 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_SH="$REPO_ROOT/deploy.sh"
TESTS_RUN=0
TESTS_FAILED=0

if [ ! -f "$DEPLOY_SH" ]; then
    echo "ERROR: deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi

# ANSI colors only when stdout is a TTY (CI logs render \033 literally).
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

# ---- Assertion helpers ----

pass_test() {
    echo "  ${GREEN}PASS${RESET}  $1"
}

fail_test() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ${RED}FAIL${RESET}  $1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}

# run_deploy <test_name> <expected_exit> <expected_output_pattern_regex> [args...]
# Banned patterns are checked first — these signal a bash-internal crash and
# are never acceptable regardless of exit code.
run_deploy() {
    local test_name="$1" expected_exit="$2" expected_pattern="$3"
    shift 3
    TESTS_RUN=$((TESTS_RUN + 1))

    local tmp_out tmp_err
    tmp_out=$(mktemp)
    tmp_err=$(mktemp)

    # Run deploy.sh in a subshell to keep test-runner env isolated.
    # Empty ANTHROPIC_API_KEY so the script's prereq check exits cleanly
    # if a test accidentally reaches the API call path (it never should
    # with --dry-run, but defense in depth).
    local exit_code=0
    ANTHROPIC_API_KEY="" bash "$DEPLOY_SH" "$@" >"$tmp_out" 2>"$tmp_err" || exit_code=$?

    local stdout stderr combined
    stdout=$(cat "$tmp_out")
    stderr=$(cat "$tmp_err")
    combined="${stdout}
${stderr}"
    rm -f "$tmp_out" "$tmp_err"

    # Banned patterns — any of these means deploy.sh hit a bash-internal
    # crash that the array guards are supposed to prevent.
    local banned
    for banned in 'bad array subscript' 'unbound variable' 'syntax error' 'command not found'; do
        if printf '%s' "$combined" | grep -qi -- "$banned"; then
            fail_test "$test_name" "Output contains banned pattern: '$banned'
exit=$exit_code
stdout: $stdout
stderr: $stderr"
            return
        fi
    done

    # Exit code assertion
    if [ "$exit_code" != "$expected_exit" ]; then
        fail_test "$test_name" "Expected exit $expected_exit, got $exit_code
stdout: $stdout
stderr: $stderr"
        return
    fi

    # Output pattern assertion (combined stdout+stderr)
    if [ -n "$expected_pattern" ] && ! printf '%s' "$combined" | grep -qE -- "$expected_pattern"; then
        fail_test "$test_name" "Expected pattern '$expected_pattern' not found in output
output: $combined"
        return
    fi

    pass_test "$test_name"
}

# assert_guarded_iteration <array_name> <test_name>
# Verifies that every `for X in "${ARRAY[@]}"` iteration of the named array
# is preceded (within 10 lines) by a `[ ${#ARRAY[@]} -gt 0 ]` guard. Skips
# lines inside comments (#).
assert_guarded_iteration() {
    local array_name="$1" test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Match `for X in "${ARRAY[@]}"` patterns, ignoring lines that begin
    # with `#` (those are comments documenting the pattern, not code).
    local iter_lines
    iter_lines=$(grep -nE "^[[:space:]]*for [a-zA-Z_]+ in \"\\\$\\{${array_name}\\[@\\]" "$DEPLOY_SH" | cut -d: -f1)

    if [ -z "$iter_lines" ]; then
        pass_test "$test_name (no iteration of $array_name found — guard not required)"
        return
    fi

    local ln from
    for ln in $iter_lines; do
        from=$((ln - 10))
        [ "$from" -lt 1 ] && from=1
        # Accept any `${#ARRAY[@]}` length reference within 10 lines. Both the
        # "guard-and-iterate" pattern (`if [ ${#A[@]} -gt 0 ]; then for ... `)
        # and the "exit-if-empty" pattern (`if [ ${#A[@]} -eq 0 ]; then exit;
        # fi; for ...`) are safe — the lossy regex catches both.
        if ! sed -n "${from},${ln}p" "$DEPLOY_SH" | grep -qE "\\\$\\{#${array_name}\\[@\\]\\}"; then
            fail_test "$test_name" "Unguarded iteration of $array_name at deploy.sh:$ln
Expected a \${#${array_name}[@]} length check within 10 preceding lines
(either '-gt 0' guard or '-eq 0' early-exit pattern)."
            return
        fi
    done

    pass_test "$test_name"
}

# assert_guarded_subscript <array_name> <test_name>
# Verifies every `${ARRAY[$idx]}` indexing site is preceded (within 10
# lines) by an `[ "$idx" = "-1" ]` or `[ $idx = -1 ]` guard. This catches
# the conf_index = -1 crash class.
assert_guarded_subscript() {
    local array_name="$1" test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Match `${ARRAY[$idx]}` or `${ARRAY[$var]}`. Exclude `${#ARRAY[...]}`
    # (length expressions are safe; only value access can subscript-fault).
    local subscript_lines
    subscript_lines=$(grep -nE "[^#]\\\$\\{${array_name}\\[\\\$" "$DEPLOY_SH" | grep -v '\${#' | cut -d: -f1)

    if [ -z "$subscript_lines" ]; then
        pass_test "$test_name (no \${${array_name}[\$...]} subscript found — guard not required)"
        return
    fi

    local ln from
    for ln in $subscript_lines; do
        from=$((ln - 10))
        [ "$from" -lt 1 ] && from=1
        if ! sed -n "${from},${ln}p" "$DEPLOY_SH" | grep -qE "(\\\$idx[[:space:]]*=[[:space:]]*\"?-1\"?|idx[[:space:]]+=[[:space:]]+-1|=[[:space:]]*\"-1\")"; then
            fail_test "$test_name" "Unguarded \${${array_name}[\$idx]} subscript at deploy.sh:$ln
Expected an [ \"\$idx\" = \"-1\" ] or equivalent guard within 10 preceding lines."
            return
        fi
    done

    pass_test "$test_name"
}

# ---- Runtime tests (controlled-input invocations of deploy.sh --dry-run) ----

echo "${YELLOW}== Runtime tests ==${RESET}"

# T1 — unknown --repo triggers conf_index = -1, must hit the friendly error
# at deploy.sh:151 ("ERROR: repo 'X' not in deploy.conf") with exit 1,
# never a bash-internal "bad array subscript" from indexing CONF_SLUGS[-1].
run_deploy "unknown_repo_filter_friendly_error" 1 \
    "ERROR: repo 'NONEXISTENT-REPO' not in deploy\\.conf" \
    --dry-run --repo NONEXISTENT-REPO

# T2 — valid --repo but invalid --skill triggers the repo_has_skill check
# at deploy.sh:153-155.
run_deploy "valid_repo_invalid_skill" 1 \
    "ERROR: repo 'skill-templates' does not have skill 'nonexistent-skill'" \
    --dry-run --repo skill-templates --skill nonexistent-skill

# T3 — single valid combination — exercises the normal happy path of
# build_pairs and confirms DEPLOY_PAIRS construction works without crash.
run_deploy "valid_repo_skill_combo" 0 \
    "Dry run — no changes made" \
    --dry-run --repo skill-templates --skill check-pr

# T4 — repo-only filter — exercises iteration over all skills for one repo
# (build_pairs:166-169). Confirms the `for skill in "${skills[@]}"` is safe
# when the repo has many skills.
run_deploy "repo_only_filter" 0 \
    "Dry run — no changes made" \
    --dry-run --repo skill-templates

# T5 — skill-only filter — exercises iteration over all repos that have a
# skill (build_pairs:170-177). Confirms !CONF_NAMES[@] iteration works.
run_deploy "skill_only_filter" 0 \
    "Dry run — no changes made" \
    --dry-run --skill check-pr

# T6 — no filters at all (the all-pairs fallback at build_pairs:181-188).
# This exercises the largest DEPLOY_PAIRS construction path and the
# deduplicate loop at build_pairs:190-201 (which itself has a #DEPLOY_PAIRS
# > 0 guard that this test confirms doesn't crash).
run_deploy "no_filter_all_pairs" 0 \
    "Dry run — no changes made" \
    --dry-run

# T7 — --changed-templates mode is git-state-dependent (it diffs HEAD~1 to
# find changed templates). We deliberately don't assert on whether the
# resulting DEPLOY_PAIRS is empty or full — that depends on what the PR
# branch happens to touch. We DO assert exit 0 and no bash-internal crash,
# which is the property #23 was about: the script handles both empty and
# non-empty DEPLOY_PAIRS without subscript faults or unbound-variable
# errors. Static-analysis tests below catch the iteration-guard regression
# class directly.
run_deploy "changed_templates_no_crash" 0 "" \
    --dry-run --changed-templates

# T8 — --changed-customs mode, symmetric to T7.
run_deploy "changed_customs_no_crash" 0 "" \
    --dry-run --changed-customs

# T9 — unknown argument should reject cleanly, not hit a bash error from
# the case statement at deploy.sh:38-49.
run_deploy "unknown_argument_friendly_error" 1 \
    "Unknown argument" \
    --dry-run --not-a-real-flag

# ---- Static-analysis tests (array-guard pattern enforcement) ----

echo ""
echo "${YELLOW}== Static-analysis tests ==${RESET}"

# These tests catch a class of regression the runtime suite misses: an
# unguarded `for X in "${ARRAY[@]}"` that happens to be non-empty in test
# inputs but is empty in some production code path. By verifying the guard
# pattern exists in the source itself, any new iteration added in a future
# edit will be checked here before it ships.

assert_guarded_iteration DEPLOY_PAIRS "DEPLOY_PAIRS array iterations are guarded"
assert_guarded_iteration CI_CLONED_REPOS "CI_CLONED_REPOS array iterations are guarded"
assert_guarded_iteration FAILURES "FAILURES array iterations are guarded"
assert_guarded_iteration CONF_NAMES "CONF_NAMES array iterations are guarded"

# Subscript guards — conf_index returns -1 for unknown repos; indexing
# CONF_SLUGS/CONF_PATHS/CONF_SKILLS with -1 crashes under set -u + bash 3.2.
assert_guarded_subscript CONF_SLUGS "CONF_SLUGS subscripts are guarded against idx=-1"

# ---- Summary ----

echo ""
echo "${YELLOW}== Summary ==${RESET}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "${RED}FAIL${RESET}"
    exit 1
fi
echo "${GREEN}PASS${RESET}"
exit 0
