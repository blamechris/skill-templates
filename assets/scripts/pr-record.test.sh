#!/usr/bin/env bash
# Regression tests for assets/scripts/pr-record.py.
#
# Two fakes back every case: a fake `gh` on PATH (rework-lag.test.sh's
# style — logs every invocation, answers from fixture JSON files in
# $FAKE_GH_DIR, exits 1 loudly on anything unmocked) and a fake $HOME with a
# `~/.claude/projects/<proj>/<sid>/` tree (review-result.test.sh's style —
# built once, in Python, so every fixture is genuinely valid JSON/JSONL).
# pr-record.py needs both at once: gh for the PR/CI/thread/follow-on data,
# the fake HOME for session/subagent resolution.
#
# set -uo pipefail, no -e: several cases are "the REFUSE fired and nothing
# was written/printed", and a failed assertion must not abort the rest of
# the suite.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/pr-record.py"
PY=$(command -v python3) || { echo "python3 not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-record-test.XXXXXX")
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Unset unconditionally so an ambient CLAUDE_CODE_SESSION_ID on the author's
# own machine can never leak a false positive into the "no session" cases —
# review-result.test.sh's and session-seed.test.sh's discipline.
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PR_LEDGER

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

echo "pr-record.test.sh"

REPO="acme/widgets"

# =========================================================================
# 1. Fake `gh`, on PATH first.
# =========================================================================
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
FAKE_GH_DIR="$TMP/gh-fixtures"
mkdir -p "$FAKE_GH_DIR"
GH_LOG="$TMP/gh.log"
: > "$GH_LOG"
export FAKE_GH_DIR GH_LOG

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh for pr-record.test.sh: logs every invocation, answers from fixed
# JSON files in $FAKE_GH_DIR keyed by PR number/branch, and exits 1 on
# anything unmocked so a case that reaches an unmocked call fails visibly
# instead of silently returning "{}".
set -u
echo "$*" >> "$GH_LOG"

fail_flag() { [ -f "$FAKE_GH_DIR/$1" ]; }

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  fail_flag fail_repo_view && { echo "fake gh: repo view forced failure" >&2; exit 1; }
  cat "$FAKE_GH_DIR/repo_view.txt"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  n="${3:-}"
  fail_flag "fail_pr_view_$n" && { echo "fake gh: pr view $n forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/pr_view_$n.json"
  if [ -f "$f" ]; then cat "$f"; else echo "fake gh: no fixture for pr view $n" >&2; exit 1; fi
  exit 0
fi

if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
  branch=""
  shift 2
  while [ $# -gt 0 ]; do
    if [ "$1" = "--branch" ]; then branch="${2:-}"; fi
    shift
  done
  fail_flag "fail_run_list_$branch" && { echo "fake gh: run list forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/run_list_$branch.json"
  if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  search=""
  shift 2
  while [ $# -gt 0 ]; do
    if [ "$1" = "--search" ]; then search="${2:-}"; fi
    shift
  done
  n=$(echo "$search" | sed -E 's/.*Filed from: #([0-9]+).*/\1/')
  fail_flag "fail_issue_list_$n" && { echo "fake gh: issue list forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/issue_list_$n.json"
  if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  n=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      -F) case "${2:-}" in number=*) n="${2#number=}";; esac ;;
    esac
    shift
  done
  fail_flag "fail_graphql_$n" && { echo "fake gh: graphql forced failure" >&2; exit 1; }
  f="$FAKE_GH_DIR/graphql_$n.json"
  if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}'; fi
  exit 0
fi

echo "fake gh: unexpected invocation: $*" >&2
exit 1
SH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

echo "$REPO" > "$FAKE_GH_DIR/repo_view.txt"

# =========================================================================
# 2. Fake $HOME: ~/.claude/projects/-fake-proj/<sid>/... session dirs, and
#    all `gh` fixture JSON files. Built once, in Python (JSON-with-embedded-
#    JSON in a shell heredoc is exactly the quoting trap this avoids).
# =========================================================================
HOMEDIR="$TMP/home"
PROJ="$HOMEDIR/.claude/projects/-fake-proj"
mkdir -p "$PROJ"

"$PY" - "$PROJ" "$FAKE_GH_DIR" <<'PYEOF'
import json, os, sys

proj, ghdir = sys.argv[1], sys.argv[2]

def jsonl(path, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for o in objs:
            f.write(json.dumps(o) + "\n")

def jfile(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)

def user(text, ts=None):
    o = {"type": "user", "message": {"content": text}}
    if ts:
        o["timestamp"] = ts
    return o

def assistant(model, usage, ts=None, request_id=None):
    o = {"type": "assistant", "message": {"model": model, "usage": usage}}
    if request_id:
        o["requestId"] = request_id
    if ts:
        o["timestamp"] = ts
    return o

# ---------------------------------------------------------------- PR 501
# Happy path: pr_meta/commits/ci.final/closes, a review agent linked by
# RESULT (round 1, usage requestId-dedup pinned), four more agents linked
# by BRIEF via each of the three text grammars (#N / PR N / pull/N) and the
# branch-name fallback, two agents left UNLINKED (one a near-miss boundary
# case -- "#5010" must never match "#501" -- one with no mention at all),
# ci.runs filtered to the PR's own commit shas (a third run on an unrelated
# sha must be excluded, and one failing run pins runs_failed), and a real
# follow-on issue confirmed via filed-from.py's own `Filed from:` grammar.
jfile(os.path.join(ghdir, "pr_view_501.json"), {
    "number": 501, "state": "MERGED",
    "title": "Widget support", "author": {"login": "alice"},
    "mergedBy": {"login": "bob"}, "headRefName": "feat-501",
    "createdAt": "2026-01-09T09:00:00Z", "mergedAt": "2026-01-10T12:00:00Z",
    "mergeCommit": {"oid": "mmm999mmm999mmm999mmm999mmm999mmm999mmm9"},
    "additions": 120, "deletions": 4, "changedFiles": 3,
    "closingIssuesReferences": [{"number": 490}],
    "commits": [
        {"oid": "aaa111aaa111aaa111aaa111aaa111aaa111aaa1",
         "messageHeadline": "feat: widget (#501)", "authoredDate": "2026-01-10T10:00:00Z"},
        {"oid": "bbb222bbb222bbb222bbb222bbb222bbb222bbb2",
         "messageHeadline": "fix: typo", "authoredDate": "2026-01-10T11:30:00Z"},
    ],
    "reviews": [{"author": {"login": "botreviewer"}, "state": "COMMENTED",
                 "submittedAt": "2026-01-10T11:45:00Z"}],
    "statusCheckRollup": [{"name": "validate", "workflowName": "validate-registry",
                            "conclusion": "SUCCESS"}],
})
jfile(os.path.join(ghdir, "run_list_feat-501.json"), [
    {"databaseId": 1001, "workflowName": "validate-registry", "conclusion": "success",
     "headSha": "aaa111aaa111aaa111aaa111aaa111aaa111aaa1", "event": "pull_request",
     "createdAt": "2026-01-10T10:05:00Z"},
    {"databaseId": 1002, "workflowName": "validate-registry", "conclusion": "failure",
     "headSha": "bbb222bbb222bbb222bbb222bbb222bbb222bbb2", "event": "pull_request",
     "createdAt": "2026-01-10T11:35:00Z"},
    {"databaseId": 1003, "workflowName": "validate-registry", "conclusion": "success",
     "headSha": "ccc333ccc333ccc333ccc333ccc333ccc333ccc3", "event": "pull_request",
     "createdAt": "2026-01-09T08:00:00Z"},
])
jfile(os.path.join(ghdir, "graphql_501.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {
        "totalCount": 2,
        "nodes": [
            {"isResolved": True, "comments": {"nodes": [{"author": {"login": "botreviewer"}}]}},
            {"isResolved": True, "comments": {"nodes": [{"author": {"login": "botreviewer"}}]}},
        ],
    }}}}
})
jfile(os.path.join(ghdir, "issue_list_501.json"), [
    {"number": 520, "title": "Follow-on from PR501", "state": "OPEN",
     "body": "## Context\nFiled from: #501\n"},
])

sdir501 = os.path.join(proj, "sess-501")
jsonl(sdir501 + ".jsonl", [
    user("kicking off work for #501", ts="2026-01-10T11:00:00Z"),
    user("still on #501", ts="2026-01-10T13:00:00Z"),
])

# aaa00001: reviewer, linked ONLY by RESULT, round 1 -- its own brief names
# neither the PR nor its branch (the real PR276 shape: a reviewer found
# only via its .result.json). Its jsonl also pins the requestId dedup rule:
# two assistant lines share req-1 (a small partial, then the real
# completion -- the LAST record must win) and one line with no requestId at
# all counts on its own, never deduplicated against anything.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00001.meta.json"),
      {"agentType": "general-purpose", "description": "Review the changes", "model": "opus"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00001.jsonl"), [
    user("Please conduct a careful code review of the recent changes", ts="2026-01-10T11:10:00Z"),
    assistant("claude-opus-5", {"input_tokens": 2, "output_tokens": 3,
                                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 100},
              ts="2026-01-10T11:10:01Z", request_id="req-1"),
    assistant("claude-opus-5", {"input_tokens": 2, "output_tokens": 250,
                                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 100},
              ts="2026-01-10T11:10:02Z", request_id="req-1"),
    assistant("claude-opus-5", {"input_tokens": 5, "output_tokens": 7,
                                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
              ts="2026-01-10T11:15:00Z", request_id=None),
])
jfile(os.path.join(sdir501, "subagents", "agent-aaa00001.result.json"), {
    "schema": 1, "source": "record", "recorded_at": "2026-01-10T11:20:00Z",
    "session": "sess-501", "agent": "agent-aaa00001", "skill": "agent-review", "pr": 501,
    "result": {
        "kind": "review-result", "verdict": "request_changes", "body_matches_tree": True,
        "pr": 501, "repo": REPO if False else "acme/widgets", "skill": "agent-review", "round": 1,
        "findings": [
            {"severity": "critical", "title": "c1", "file": "a.py", "line": 1,
             "evidence": "e", "mutation_ran": True, "red_line": False},
            {"severity": "suggestion", "title": "s1", "file": None, "line": None,
             "evidence": "e", "mutation_ran": False, "red_line": False},
            {"severity": "nitpick", "title": "n1", "file": None, "line": None,
             "evidence": "e", "mutation_ran": False, "red_line": False},
        ],
    },
})

# aaa00002: linked by BRIEF via the head branch name only (no #N/PR N/pull/N
# anywhere in its brief). No models observed at all -- tier must fall back
# to meta.json's own `model`.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00002.meta.json"),
      {"agentType": "general-purpose", "description": "Implement widget", "model": "sonnet"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00002.jsonl"), [
    user("Work on branch feat-501, make it pass CI", ts="2026-01-10T11:05:00Z"),
])

# aaa00003: linked by BRIEF via the `#N` hash grammar. One assistant line
# with an observed model -- tier read directly from models_observed, not
# from meta fallback.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00003.meta.json"),
      {"agentType": "general-purpose", "description": "Small fix", "model": "haiku"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00003.jsonl"), [
    user("Please handle #501 today", ts="2026-01-10T11:06:00Z"),
    assistant("claude-haiku-4", {"input_tokens": 1, "output_tokens": 1,
                                  "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
              ts="2026-01-10T11:06:01Z", request_id="req-h1"),
])

# aaa00006: linked by BRIEF via the `PR N` grammar.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00006.meta.json"),
      {"agentType": "general-purpose", "description": "Docs", "model": "sonnet"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00006.jsonl"), [
    user("Update docs for PR 501", ts="2026-01-10T11:07:00Z"),
])

# aaa00007: linked by BRIEF via the `pull/N` grammar.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00007.meta.json"),
      {"agentType": "general-purpose", "description": "CI nudge", "model": "sonnet"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00007.jsonl"), [
    user("See github.com/acme/widgets/pull/501 for context", ts="2026-01-10T11:08:00Z"),
])

# aaa00004: UNLINKED near-miss -- "#5010" must never match "#501".
jfile(os.path.join(sdir501, "subagents", "agent-aaa00004.meta.json"),
      {"agentType": "general-purpose", "description": "Unrelated", "model": "sonnet"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00004.jsonl"), [
    user("Following up on issue #5010, unrelated to this PR", ts="2026-01-10T11:09:00Z"),
])

# aaa00005: UNLINKED, no mention of the PR or its branch at all.
jfile(os.path.join(sdir501, "subagents", "agent-aaa00005.meta.json"),
      {"agentType": "Explore", "description": "Unrelated recon", "model": "sonnet"})
jsonl(os.path.join(sdir501, "subagents", "agent-aaa00005.jsonl"), [
    user("Look for config files in the repo", ts="2026-01-10T11:11:00Z"),
])

# ---------------------------------------------------------------- PR 502
# flag-sourced session outside merged_within_span -- ACCEPTED, not a REFUSE.
jfile(os.path.join(ghdir, "pr_view_502.json"), {
    "number": 502, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-502",
    "createdAt": "2026-02-01T00:00:00Z", "mergedAt": "2026-02-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-502.json"), [])
jfile(os.path.join(ghdir, "graphql_502.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_502.json"), [])
sdir502 = os.path.join(proj, "sess-502")
os.makedirs(sdir502, exist_ok=True)
jsonl(sdir502 + ".jsonl", [
    user("working on #502", ts="2020-01-01T00:00:00Z"),
    user("still on #502", ts="2020-01-01T01:00:00Z"),
])

# ---------------------------------------------------------------- PR 503
# env-sourced session outside merged_within_span -- REFUSE.
jfile(os.path.join(ghdir, "pr_view_503.json"), {
    "number": 503, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-503",
    "createdAt": "2026-03-01T00:00:00Z", "mergedAt": "2026-03-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-503.json"), [])
jfile(os.path.join(ghdir, "graphql_503.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_503.json"), [])
sdir503 = os.path.join(proj, "sess-503")
os.makedirs(sdir503, exist_ok=True)
jsonl(sdir503 + ".jsonl", [
    user("working on #503", ts="2020-01-01T00:00:00Z"),
    user("still on #503", ts="2020-01-01T01:00:00Z"),
])

# ---------------------------------------------------------------- PR 504
# session given but never nominates the PR -- REFUSE regardless of source.
jfile(os.path.join(ghdir, "pr_view_504.json"), {
    "number": 504, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-504",
    "createdAt": "2026-04-01T00:00:00Z", "mergedAt": "2026-04-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-504.json"), [])
jfile(os.path.join(ghdir, "graphql_504.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_504.json"), [])
sdir504 = os.path.join(proj, "sess-504")
os.makedirs(sdir504, exist_ok=True)
jsonl(sdir504 + ".jsonl", [
    user("totally unrelated chatter", ts="2026-04-01T00:00:00Z"),
    user("more unrelated chatter", ts="2026-04-01T01:00:00Z"),
])

# ---------------------------------------------------------------- PR 505
# no session at all -- the whole agent half must read null, not [].
jfile(os.path.join(ghdir, "pr_view_505.json"), {
    "number": 505, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-505",
    "createdAt": "2026-05-01T00:00:00Z", "mergedAt": "2026-05-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-505.json"), [])
jfile(os.path.join(ghdir, "graphql_505.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_505.json"), [])

# ---------------------------------------------------------------- PR 506
# ci.runs: gh run list itself fails.
jfile(os.path.join(ghdir, "pr_view_506.json"), {
    "number": 506, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-506",
    "createdAt": "2026-06-01T00:00:00Z", "mergedAt": "2026-06-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
open(os.path.join(ghdir, "fail_run_list_feat-506"), "w").close()
jfile(os.path.join(ghdir, "graphql_506.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_506.json"), [])

# ---------------------------------------------------------------- PR 507
# ci.runs: truncated at the script's own --limit (100), all sharing the
# PR's own commit sha so every one of the 100 survives the sha filter.
SHA507 = "d" * 40
jfile(os.path.join(ghdir, "pr_view_507.json"), {
    "number": 507, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-507",
    "createdAt": "2026-07-01T00:00:00Z", "mergedAt": "2026-07-01T00:00:00Z",
    "mergeCommit": {"oid": SHA507}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [{"oid": SHA507, "messageHeadline": "h", "authoredDate": "2026-07-01T00:00:00Z"}],
    "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-507.json"), [
    {"databaseId": 2000 + i, "workflowName": "validate-registry", "conclusion": "success",
     "headSha": SHA507, "event": "pull_request", "createdAt": "2026-07-01T00:00:00Z"}
    for i in range(100)
])
jfile(os.path.join(ghdir, "graphql_507.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_507.json"), [])

# ---------------------------------------------------------------- PR 508
# review_rounds.threads: graphql call itself fails.
jfile(os.path.join(ghdir, "pr_view_508.json"), {
    "number": 508, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-508",
    "createdAt": "2026-08-01T00:00:00Z", "mergedAt": "2026-08-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-508.json"), [])
open(os.path.join(ghdir, "fail_graphql_508"), "w").close()
jfile(os.path.join(ghdir, "issue_list_508.json"), [])

# ---------------------------------------------------------------- PR 509
# review_rounds.threads: totalCount says more than the nodes returned.
jfile(os.path.join(ghdir, "pr_view_509.json"), {
    "number": 509, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-509",
    "createdAt": "2026-09-01T00:00:00Z", "mergedAt": "2026-09-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-509.json"), [])
jfile(os.path.join(ghdir, "graphql_509.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {
        "totalCount": 5,
        "nodes": [
            {"isResolved": True, "comments": {"nodes": [{"author": {"login": "x"}}]}},
            {"isResolved": False, "comments": {"nodes": [{"author": {"login": "x"}}]}},
        ],
    }}}}
})
jfile(os.path.join(ghdir, "issue_list_509.json"), [])

# ---------------------------------------------------------------- PR 510
# follow_ons: the issue-list search itself fails.
jfile(os.path.join(ghdir, "pr_view_510.json"), {
    "number": 510, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-510",
    "createdAt": "2026-10-01T00:00:00Z", "mergedAt": "2026-10-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-510.json"), [])
jfile(os.path.join(ghdir, "graphql_510.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
open(os.path.join(ghdir, "fail_issue_list_510"), "w").close()

# ---------------------------------------------------------------- PR 511
# unmerged PR -- REFUSE.
jfile(os.path.join(ghdir, "pr_view_511.json"), {
    "number": 511, "state": "OPEN", "title": "t", "author": {"login": "a"},
    "mergedBy": None, "headRefName": "feat-511",
    "createdAt": "2026-11-01T00:00:00Z", "mergedAt": None,
    "mergeCommit": None, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})

# ---------------------------------------------------------------- PR 512
# rounds_missing: only round 2 recorded -> missing [1].
jfile(os.path.join(ghdir, "pr_view_512.json"), {
    "number": 512, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-512",
    "createdAt": "2026-12-01T00:00:00Z", "mergedAt": "2026-12-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-512.json"), [])
jfile(os.path.join(ghdir, "graphql_512.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_512.json"), [])
sdir512 = os.path.join(proj, "sess-512")
jsonl(sdir512 + ".jsonl", [user("about #512", ts="2026-12-01T00:00:00Z")])
jfile(os.path.join(sdir512, "subagents", "agent-bbb00001.meta.json"),
      {"agentType": "general-purpose", "description": "Review", "model": "opus"})
jsonl(os.path.join(sdir512, "subagents", "agent-bbb00001.jsonl"), [user("about #512", ts="2026-11-30T23:00:00Z")])
jfile(os.path.join(sdir512, "subagents", "agent-bbb00001.result.json"), {
    "schema": 1, "source": "record", "session": "sess-512", "agent": "agent-bbb00001",
    "skill": "agent-review", "pr": 512,
    "result": {"kind": "review-result", "verdict": "approve", "body_matches_tree": True,
               "pr": 512, "skill": "agent-review", "round": 2, "findings": []},
})

# ---------------------------------------------------------------- PR 513
# rounds_missing: round 1 only -> missing [].
jfile(os.path.join(ghdir, "pr_view_513.json"), {
    "number": 513, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-513",
    "createdAt": "2027-01-01T00:00:00Z", "mergedAt": "2027-01-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-513.json"), [])
jfile(os.path.join(ghdir, "graphql_513.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_513.json"), [])
sdir513 = os.path.join(proj, "sess-513")
jsonl(sdir513 + ".jsonl", [user("about #513", ts="2027-01-01T00:00:00Z")])
jfile(os.path.join(sdir513, "subagents", "agent-ccc00001.meta.json"),
      {"agentType": "general-purpose", "description": "Review", "model": "opus"})
jsonl(os.path.join(sdir513, "subagents", "agent-ccc00001.jsonl"), [user("about #513", ts="2026-12-31T23:00:00Z")])
jfile(os.path.join(sdir513, "subagents", "agent-ccc00001.result.json"), {
    "schema": 1, "source": "record", "session": "sess-513", "agent": "agent-ccc00001",
    "skill": "agent-review", "pr": 513,
    "result": {"kind": "review-result", "verdict": "approve", "body_matches_tree": True,
               "pr": 513, "skill": "agent-review", "round": 1, "findings": []},
})

# ---------------------------------------------------------------- PR 515
# rounds_missing: rounds 1 AND 3 both recorded (two different agents) ->
# missing must be exactly [2] -- this is the case a "just enumerate every
# integer below the max" implementation gets right by accident whenever the
# max round happens to be the only one ever recorded (PR512/PR513 above
# can't tell that mistake apart from the real rule), so it needs its own
# fixture: only a genuine "subtract every round actually found" computation
# drops 1 and 3 from the missing set while still reporting 2.
jfile(os.path.join(ghdir, "pr_view_515.json"), {
    "number": 515, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-515",
    "createdAt": "2027-03-01T00:00:00Z", "mergedAt": "2027-03-01T00:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-515.json"), [])
jfile(os.path.join(ghdir, "graphql_515.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_515.json"), [])
sdir515 = os.path.join(proj, "sess-515")
os.makedirs(sdir515, exist_ok=True)
jsonl(sdir515 + ".jsonl", [user("about #515", ts="2027-03-01T00:00:00Z")])
jfile(os.path.join(sdir515, "subagents", "agent-ddd00001.meta.json"),
      {"agentType": "general-purpose", "description": "Review round 1", "model": "opus"})
jsonl(os.path.join(sdir515, "subagents", "agent-ddd00001.jsonl"), [user("about #515", ts="2027-02-28T23:00:00Z")])
jfile(os.path.join(sdir515, "subagents", "agent-ddd00001.result.json"), {
    "schema": 1, "source": "record", "session": "sess-515", "agent": "agent-ddd00001",
    "skill": "agent-review", "pr": 515,
    "result": {"kind": "review-result", "verdict": "request_changes", "body_matches_tree": True,
               "pr": 515, "skill": "agent-review", "round": 1, "findings": []},
})
jfile(os.path.join(sdir515, "subagents", "agent-ddd00002.meta.json"),
      {"agentType": "general-purpose", "description": "Review round 3", "model": "opus"})
jsonl(os.path.join(sdir515, "subagents", "agent-ddd00002.jsonl"), [user("about #515", ts="2027-02-28T23:30:00Z")])
jfile(os.path.join(sdir515, "subagents", "agent-ddd00002.result.json"), {
    "schema": 1, "source": "record", "session": "sess-515", "agent": "agent-ddd00002",
    "skill": "agent-review", "pr": 515,
    "result": {"kind": "review-result", "verdict": "approve", "body_matches_tree": True,
               "pr": 515, "skill": "agent-review", "round": 3, "findings": []},
})

def rawfile(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

# ---------------------------------------------------------------- PR 516
# C1 (malformed/invalid/null-pr result -> unknown[] + never linked-by-
# result) and C3b (bounded head_ref match) together, reproducing the
# reviewer's own review-281 fixture shape exactly (head_ref "fix", an
# agent whose brief is "find the prefix config"):
#   c1: .result.json is truncated/unparseable, but its raw text still
#       names #516 and round 2 -- unknown[] must name the file and note
#       the recoverable round, and it must NOT count as linked-by-result;
#       its brief ("Adversarial review of PR 516") still links it by BRIEF.
#   c2: .result.json parses but verdict "bogus" fails validate_document --
#       unknown[] + not linked-by-result; brief has no PR/branch mention,
#       so it is fully UNLINKED.
#   c3: .result.json is fully valid, pr=516, but repo is "other/repo" --
#       C3a: repo mismatch means no result link; brief has no mention,
#       fully UNLINKED. No unknown[] entry (this is not malformed, just a
#       genuinely different repo's record).
#   c4: .result.json has pr=null (parses, validates -- pr is nullable in
#       the schema) -- unknown[] (a null pr is always flagged) + not
#       linked-by-result; brief has no mention, fully UNLINKED.
#   c5: brief is "find the prefix config" -- "fix" must NOT match inside
#       "prefix" (C3b); fully UNLINKED.
#   c6: brief is "implement #516" -- the real, valid, linked-by-brief agent.
jfile(os.path.join(ghdir, "pr_view_516.json"), {
    "number": 516, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "fix",
    "createdAt": "2027-04-01T00:00:00Z", "mergedAt": "2027-04-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_fix.json"), [])
jfile(os.path.join(ghdir, "graphql_516.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_516.json"), [])
sdir516 = os.path.join(proj, "sess-516")
jsonl(sdir516 + ".jsonl", [user("work on #516", ts="2027-04-01T11:00:00Z"),
                           user("still on #516", ts="2027-04-01T13:00:00Z")])

jfile(os.path.join(sdir516, "subagents", "agent-c1.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
jsonl(os.path.join(sdir516, "subagents", "agent-c1.jsonl"),
      [user("Adversarial review of PR 516", ts="2027-04-01T11:10:00Z")])
rawfile(os.path.join(sdir516, "subagents", "agent-c1.result.json"),
        '{"schema":1,"result":{"kind":"review-result","pr":516,"round":2,')

jfile(os.path.join(sdir516, "subagents", "agent-c2.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
jsonl(os.path.join(sdir516, "subagents", "agent-c2.jsonl"),
      [user("review the changes", ts="2027-04-01T11:10:00Z")])
jfile(os.path.join(sdir516, "subagents", "agent-c2.result.json"), {
    "schema": 1, "source": "record",
    "result": {"kind": "review-result", "verdict": "bogus", "body_matches_tree": True,
               "pr": 516, "repo": "acme/widgets", "skill": "agent-review", "round": 3,
               "findings": [{"severity": "critical", "title": "c", "file": None, "line": None,
                             "evidence": "e", "mutation_ran": True, "red_line": False}]},
})

jfile(os.path.join(sdir516, "subagents", "agent-c3.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
jsonl(os.path.join(sdir516, "subagents", "agent-c3.jsonl"),
      [user("review the changes", ts="2027-04-01T11:10:00Z")])
jfile(os.path.join(sdir516, "subagents", "agent-c3.result.json"), {
    "schema": 1, "source": "record",
    "result": {"kind": "review-result", "verdict": "request_changes", "body_matches_tree": True,
               "pr": 516, "repo": "other/repo", "skill": "agent-review", "round": 1,
               "findings": [{"severity": "critical", "title": "c", "file": None, "line": None,
                             "evidence": "e", "mutation_ran": True, "red_line": False}]},
})

jfile(os.path.join(sdir516, "subagents", "agent-c4.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
jsonl(os.path.join(sdir516, "subagents", "agent-c4.jsonl"),
      [user("review the changes", ts="2027-04-01T11:10:00Z")])
jfile(os.path.join(sdir516, "subagents", "agent-c4.result.json"), {
    "schema": 1, "source": "record",
    "result": {"kind": "review-result", "verdict": "approve", "body_matches_tree": True,
               "pr": None, "repo": "acme/widgets", "skill": "agent-review", "round": 1,
               "findings": []},
})

jfile(os.path.join(sdir516, "subagents", "agent-c5.meta.json"),
      {"agentType": "general-purpose", "description": "unrelated", "model": "sonnet"})
jsonl(os.path.join(sdir516, "subagents", "agent-c5.jsonl"),
      [user("find the prefix config", ts="2027-04-01T11:10:00Z")])

jfile(os.path.join(sdir516, "subagents", "agent-c6.meta.json"),
      {"agentType": "general-purpose", "description": "impl", "model": "opus"})
jsonl(os.path.join(sdir516, "subagents", "agent-c6.jsonl"),
      [user("implement #516", ts="2027-04-01T11:10:00Z")])

# ---------------------------------------------------------------- PR 517
# C2: an unreadable (chmod 000) agent transcript and an unreadable (chmod
# 000) agent meta.json must each add their own unknown[] entry -- neither
# may silently look like "no evidence found". A THIRD agent's transcript
# carries a valid-JSON-but-non-object line (a bare number) mixed in with
# real ones -- also its own unknown[] entry, though it does not prevent
# the brief from still being read off the other, well-formed lines.
jfile(os.path.join(ghdir, "pr_view_517.json"), {
    "number": 517, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-517",
    "createdAt": "2027-05-01T00:00:00Z", "mergedAt": "2027-05-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-517.json"), [])
jfile(os.path.join(ghdir, "graphql_517.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_517.json"), [])
sdir517 = os.path.join(proj, "sess-517")
jsonl(sdir517 + ".jsonl", [user("work on #517", ts="2027-05-01T11:00:00Z"),
                           user("still on #517", ts="2027-05-01T13:00:00Z")])

jfile(os.path.join(sdir517, "subagents", "agent-d1.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
jsonl(os.path.join(sdir517, "subagents", "agent-d1.jsonl"),
      [user("review #517", ts="2027-05-01T11:10:00Z")])
os.chmod(os.path.join(sdir517, "subagents", "agent-d1.jsonl"), 0o000)

rawfile(os.path.join(sdir517, "subagents", "agent-d2.meta.json"),
        '{"agentType": "general-purpose"')  # deliberately truncated/unparseable meta.json
jsonl(os.path.join(sdir517, "subagents", "agent-d2.jsonl"),
      [user("review #517 too", ts="2027-05-01T11:11:00Z")])

jfile(os.path.join(sdir517, "subagents", "agent-d3.meta.json"),
      {"agentType": "general-purpose", "description": "review", "model": "opus"})
rawfile(os.path.join(sdir517, "subagents", "agent-d3.jsonl"),
        json.dumps(user("about #517", ts="2027-05-01T11:12:00Z")) + "\n"
        + "42\n"
        + json.dumps(user("wrapping up", ts="2027-05-01T11:13:00Z")) + "\n")

# ---------------------------------------------------------------- PR 518
# C3c: an agent with real linking evidence but started strictly AFTER the
# PR's own merged_at must be excluded from `agents[]` and counted in
# `agents_after_merge`, not `agents_unlinked` -- it is not "no evidence",
# it is "evidence that is temporally impossible". A second agent has
# linking evidence but NO started_at at all (an empty transcript) -- it
# cannot be placed in time either direction, so it does not link, is
# counted in `agents_unlinked`, and gets its own unknown[] entry.
jfile(os.path.join(ghdir, "pr_view_518.json"), {
    "number": 518, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-518",
    "createdAt": "2027-06-01T00:00:00Z", "mergedAt": "2027-06-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-518.json"), [])
jfile(os.path.join(ghdir, "graphql_518.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_518.json"), [])
sdir518 = os.path.join(proj, "sess-518")
# The SESSION's own transcript spans well past the merge (flag-sourced, so
# merged_within_span is recorded but not enforced) -- this is what lets an
# agent that ACTUALLY started after the merge exist in the same session at
# all.
jsonl(sdir518 + ".jsonl", [user("work on #518", ts="2027-06-01T11:00:00Z"),
                           user("still on #518, much later", ts="2027-06-02T09:00:00Z")])

jfile(os.path.join(sdir518, "subagents", "agent-e1.meta.json"),
      {"agentType": "general-purpose", "description": "late agent", "model": "opus"})
jsonl(os.path.join(sdir518, "subagents", "agent-e1.jsonl"),
      [user("implement #518", ts="2027-06-02T08:00:00Z")])  # merged_at is 2027-06-01T12:00:00Z -- this is after it

jfile(os.path.join(sdir518, "subagents", "agent-e2.meta.json"),
      {"agentType": "general-purpose", "description": "no timestamp", "model": "opus"})
rawfile(os.path.join(sdir518, "subagents", "agent-e2.jsonl"),
        json.dumps({"type": "user", "message": {"content": "implement #518 too"}}) + "\n")

# ---------------------------------------------------------------- PR 519
# S4: tier() reused from usage-pace.py by path -- an unrecognized model
# family ("claude-mythos-9"... no: use a genuinely unrecognized string)
# records "other", not null (null is reserved for NO model information at
# all). Usage dedup uses the (message.id, requestId) key exactly as
# usage-pace.py builds it, keeping the LAST record for that pair -- a
# message.id shared by two lines with DIFFERENT requestIds must not be
# collapsed together, and vice versa.
jfile(os.path.join(ghdir, "pr_view_519.json"), {
    "number": 519, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-519",
    "createdAt": "2027-07-01T00:00:00Z", "mergedAt": "2027-07-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-519.json"), [])
jfile(os.path.join(ghdir, "graphql_519.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_519.json"), [])
sdir519 = os.path.join(proj, "sess-519")
jsonl(sdir519 + ".jsonl", [user("work on #519", ts="2027-07-01T11:00:00Z"),
                           user("still on #519", ts="2027-07-01T13:00:00Z")])

jfile(os.path.join(sdir519, "subagents", "agent-f1.meta.json"),
      {"agentType": "general-purpose", "description": "impl", "model": "some-future-model"})
jsonl(os.path.join(sdir519, "subagents", "agent-f1.jsonl"), [
    user("implement #519", ts="2027-07-01T11:10:00Z"),
    {"type": "assistant", "requestId": "r1",
     "message": {"id": "msg-1", "model": "some-future-model-x1",
                 "usage": {"input_tokens": 2, "output_tokens": 3}},
     "timestamp": "2027-07-01T11:10:01Z"},
    {"type": "assistant", "requestId": "r1",
     "message": {"id": "msg-1", "model": "some-future-model-x1",
                 "usage": {"input_tokens": 2, "output_tokens": 300}},
     "timestamp": "2027-07-01T11:10:02Z"},
    {"type": "assistant", "requestId": "r2",
     "message": {"id": "msg-1", "model": "some-future-model-x1",
                 "usage": {"input_tokens": 5, "output_tokens": 5}},
     "timestamp": "2027-07-01T11:10:03Z"},
    # Same requestId (r2) as the line above, but a DIFFERENT message.id --
    # under the correct (message.id, requestId) key these are two distinct
    # records and both count; a requestId-only key would collapse them,
    # silently dropping the (msg-1, r2) contribution above.
    {"type": "assistant", "requestId": "r2",
     "message": {"id": "msg-2", "model": "some-future-model-x1",
                 "usage": {"input_tokens": 10, "output_tokens": 10}},
     "timestamp": "2027-07-01T11:10:04Z"},
])

# ---------------------------------------------------------------- PR 520
# S5: statusCheckRollup can carry legacy StatusContext entries
# (context/state) alongside or instead of CheckRun entries
# (name/workflowName/conclusion) -- both must map into ci.final's
# {name, workflow, conclusion} shape.
jfile(os.path.join(ghdir, "pr_view_520.json"), {
    "number": 520, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-520",
    "createdAt": "2027-08-01T00:00:00Z", "mergedAt": "2027-08-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [],
    "statusCheckRollup": [
        {"__typename": "CheckRun", "name": "validate", "workflowName": "validate-registry",
         "conclusion": "SUCCESS"},
        {"__typename": "StatusContext", "context": "ci/legacy-status", "state": "SUCCESS"},
    ],
})
jfile(os.path.join(ghdir, "run_list_feat-520.json"), [])
jfile(os.path.join(ghdir, "graphql_520.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_520.json"), [])

# ---------------------------------------------------------------- PR 521
# S2: a session whose main transcript exists but whose sidecar DIRECTORY
# does not exist AT ALL (not even created empty) -- this must read as
# `agents: []` (a real, confident zero), exit 0, never a REFUSE.
jfile(os.path.join(ghdir, "pr_view_521.json"), {
    "number": 521, "state": "MERGED", "title": "t", "author": {"login": "a"},
    "mergedBy": {"login": "a"}, "headRefName": "feat-521",
    "createdAt": "2027-09-01T00:00:00Z", "mergedAt": "2027-09-01T12:00:00Z",
    "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
    "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": [],
})
jfile(os.path.join(ghdir, "run_list_feat-521.json"), [])
jfile(os.path.join(ghdir, "graphql_521.json"), {
    "data": {"repository": {"pullRequest": {"reviewThreads": {"totalCount": 0, "nodes": []}}}}
})
jfile(os.path.join(ghdir, "issue_list_521.json"), [])
# Deliberately: sess-521-nodir.jsonl exists, sess-521-nodir/ never created.
jsonl(os.path.join(proj, "sess-521-nodir.jsonl"),
      [user("work on #521", ts="2027-09-01T11:00:00Z"),
       user("still on #521", ts="2027-09-01T13:00:00Z")])

# ---------------------------------------------------------------- sess-514
# A session for PR 514 (gh fixtures added separately below, in bash) with
# a real but EMPTY subagents/ directory -- used by the ledger group (G) to
# prove --replace genuinely swaps content (agents: [] on the second write)
# rather than silently leaving the first write's agents: null in place.
sdir514 = os.path.join(proj, "sess-514")
os.makedirs(os.path.join(sdir514, "subagents"), exist_ok=True)
jsonl(sdir514 + ".jsonl", [user("work on #514", ts="2027-02-01T00:00:00Z")])

print("fixtures built OK")
PYEOF

# ---------------------------------------------------------------- PR 514
# ledger idempotency fixture (reuses PR 502's minimal gh fixtures via a
# fresh --repo/pr pair so the ledger tests don't entangle with PR501's much
# larger happy-path assertions).
cat > "$FAKE_GH_DIR/pr_view_514.json" <<'JSON'
{"number": 514, "state": "MERGED", "title": "t", "author": {"login": "a"},
 "mergedBy": {"login": "a"}, "headRefName": "feat-514",
 "createdAt": "2027-02-01T00:00:00Z", "mergedAt": "2027-02-01T00:00:00Z",
 "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
 "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": []}
JSON
echo '[]' > "$FAKE_GH_DIR/run_list_feat-514.json"
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}' > "$FAKE_GH_DIR/graphql_514.json"
echo '[]' > "$FAKE_GH_DIR/issue_list_514.json"

# ---------------------------------------------------------------- PR 522/523
# C4's concurrent-writer test: two distinct PRs written to the SAME fresh
# ledger by two pr-record.py processes launched at once.
for n in 522 523; do
  cat > "$FAKE_GH_DIR/pr_view_$n.json" <<JSON
{"number": $n, "state": "MERGED", "title": "t", "author": {"login": "a"},
 "mergedBy": {"login": "a"}, "headRefName": "feat-$n",
 "createdAt": "2027-10-01T00:00:00Z", "mergedAt": "2027-10-01T00:00:00Z",
 "mergeCommit": {"oid": "z"}, "additions": 1, "deletions": 1, "changedFiles": 1,
 "closingIssuesReferences": [], "commits": [], "reviews": [], "statusCheckRollup": []}
JSON
  echo '[]' > "$FAKE_GH_DIR/run_list_feat-$n.json"
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}' > "$FAKE_GH_DIR/graphql_$n.json"
  echo '[]' > "$FAKE_GH_DIR/issue_list_$n.json"
done

# =========================================================================
# 3. Test helpers
# =========================================================================

# run [args...]                      -- no session env, stdout+stderr merged
run() { out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>&1); rc=$?; }
# run_env SID [args...]              -- $CLAUDE_CODE_SESSION_ID=SID
run_env() { local sid=$1; shift; out=$(HOME="$HOMEDIR" CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$SUT" "$@" 2>&1); rc=$?; }
# run_split [args...]                -- stdout and stderr captured separately
run_split() {
  local errf="$TMP/err.$$"
  out=$(HOME="$HOMEDIR" "$PY" "$SUT" "$@" 2>"$errf"); rc=$?
  err=$(cat "$errf"); rm -f "$errf"
}
snapshot() { find "$HOMEDIR" -type f 2>/dev/null | sort; find "$TMP/ledgers" -type f 2>/dev/null | sort; }

# =========================================================================
# GROUP A -- happy path (PR 501)
# =========================================================================
echo; echo "A. happy path fields (PR 501)"

run_split --repo "$REPO" --session sess-501 --stdout 501
if [ "$rc" -eq 0 ]; then ok "PR501 exits 0 (no unknown[])"; else bad "PR501 exit code" "rc=$rc err=$err"; fi

py_check() {
  # py_check <label> <python-expr-on-d> -- d is the parsed JSON from $out.
  # $out is written to a fixed temp file first and read back with open(),
  # never interpolated into the python source as a string literal -- $out
  # is real JSON that can itself contain quotes/backslashes/`$(...)`-shaped
  # substrings, any of which a naive '''$out''' embedding would mangle or
  # let bash re-expand.
  local label=$1 expr=$2
  printf '%s' "$out" > "$TMP/last_out.json"
  res=$("$PY" -c "
import json
with open('$TMP/last_out.json', encoding='utf-8') as f:
    d = json.load(f)
print(bool($expr))
" 2>&1)
  if [ "$res" = "True" ]; then ok "$label"; else bad "$label" "got: $res"; fi
}

py_check "pr_meta.title" "d['pr_meta']['title'] == 'Widget support'"
py_check "pr_meta.author" "d['pr_meta']['author'] == 'alice'"
py_check "pr_meta.merged_by" "d['pr_meta']['merged_by'] == 'bob'"
py_check "pr_meta.head_ref" "d['pr_meta']['head_ref'] == 'feat-501'"
py_check "pr_meta.closes" "d['pr_meta']['closes'] == [490]"
py_check "commits length" "len(d['commits']) == 2"
py_check "commits[0].oid" "d['commits'][0]['oid'].startswith('aaa111')"
py_check "ci.final" "d['ci']['final'] == [{'name': 'validate', 'workflow': 'validate-registry', 'conclusion': 'SUCCESS'}]"
py_check "review_rounds.github" "d['review_rounds']['github'] == [{'author': 'botreviewer', 'state': 'COMMENTED', 'submitted_at': '2026-01-10T11:45:00Z'}]"
py_check "review_rounds.threads" "d['review_rounds']['threads'] == {'total': 2, 'resolved': 2, 'by_author': {'botreviewer': 2}}"
py_check "follow_ons" "d['follow_ons'] == [{'number': 520, 'state': 'OPEN', 'title': 'Follow-on from PR501'}]"
py_check "ci.runs filtered by sha (2 of 3)" "len(d['ci']['runs']) == 2 and all(r['head_sha'] != 'ccc333ccc333ccc333ccc333ccc333ccc333ccc3' for r in d['ci']['runs'])"
py_check "ci.runs_failed" "d['ci']['runs_failed'] == 1"
py_check "session has no nominates_pr field (tautology removed)" "'nominates_pr' not in d['session']"
py_check "session.merged_within_span" "d['session']['merged_within_span'] is True"
py_check "session.source" "d['session']['source'] == 'flag'"
py_check "unknown is empty" "d['unknown'] == []"

echo; echo "A2. agent linkage (PR 501)"
py_check "agents_unlinked == 2" "d['agents_unlinked'] == 2"
py_check "5 agents linked" "len(d['agents']) == 5"
py_check "aaa00001 linked by result" "any(a['id']=='agent-aaa00001' and a['linked_by']==['result'] for a in d['agents'])"
py_check "aaa00002 linked by brief (branch)" "any(a['id']=='agent-aaa00002' and a['linked_by']==['brief'] for a in d['agents'])"
py_check "aaa00003 linked by brief (#N)" "any(a['id']=='agent-aaa00003' and a['linked_by']==['brief'] for a in d['agents'])"
py_check "aaa00006 linked by brief (PR N)" "any(a['id']=='agent-aaa00006' and a['linked_by']==['brief'] for a in d['agents'])"
py_check "aaa00007 linked by brief (pull/N)" "any(a['id']=='agent-aaa00007' and a['linked_by']==['brief'] for a in d['agents'])"
py_check "aaa00004/aaa00005 never appear (unlinked)" "not any(a['id'] in ('agent-aaa00004','agent-aaa00005') for a in d['agents'])"

echo; echo "A3. tier resolution (PR 501)"
py_check "aaa00001 tier from observed model (opus)" "next(a for a in d['agents'] if a['id']=='agent-aaa00001')['tier'] == 'opus'"
py_check "aaa00002 tier falls back to meta.json (sonnet)" "next(a for a in d['agents'] if a['id']=='agent-aaa00002')['tier'] == 'sonnet'"
py_check "aaa00003 tier from observed model (haiku)" "next(a for a in d['agents'] if a['id']=='agent-aaa00003')['tier'] == 'haiku'"

echo; echo "A4. usage requestId dedup (PR 501, agent-aaa00001)"
py_check "usage.output == 257 (250 final of req-1, kept; 6-partial dropped; +7 no-request-id)" \
  "next(a for a in d['agents'] if a['id']=='agent-aaa00001')['usage']['output'] == 257"
py_check "usage.input == 7 (2 final of req-1 + 5 no-request-id)" \
  "next(a for a in d['agents'] if a['id']=='agent-aaa00001')['usage']['input'] == 7"

echo; echo "A5. review rounds / findings (PR 501)"
py_check "review_rounds.agent: 1 row, round 1" \
  "len(d['review_rounds']['agent']) == 1 and d['review_rounds']['agent'][0]['round'] == 1"
py_check "review_rounds.agent[0] counts 1/1/1" \
  "d['review_rounds']['agent'][0]['critical'] == 1 and d['review_rounds']['agent'][0]['suggestion'] == 1 and d['review_rounds']['agent'][0]['nitpick'] == 1"
py_check "rounds_missing is per-skill, round 1 only -> {agent-review: []}" "d['review_rounds']['rounds_missing'] == {'agent-review': []}"
py_check "findings length == 3, tagged with agent+round" \
  "len(d['findings']) == 3 and all(f['agent']=='agent-aaa00001' and f['round']==1 for f in d['findings'])"

# =========================================================================
# GROUP B -- session validation
# =========================================================================
echo; echo "B. session validation"

run_split --repo "$REPO" --session sess-502 --stdout 502
if [ "$rc" -eq 0 ]; then ok "PR502 flag-sourced outside span: accepted (exit 0)"; else bad "PR502 exit" "rc=$rc err=$err"; fi
py_check "PR502 merged_within_span is false" "d['session']['merged_within_span'] is False"

run_env sess-503 --repo "$REPO" --stdout 503
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE'; then
  ok "PR503 env-sourced outside span: REFUSE (exit 2)"
else
  bad "PR503 env-sourced outside span" "rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q '^{'; then bad "PR503 REFUSE printed a record to stdout"; else ok "PR503 REFUSE printed nothing to stdout"; fi

run --repo "$REPO" --session sess-504 --stdout 504
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'never nominates'; then
  ok "PR504 no nomination: REFUSE (exit 2)"
else
  bad "PR504 no nomination" "rc=$rc out=$out"
fi

run_split --repo "$REPO" --stdout 505
if [ "$rc" -eq 0 ]; then ok "PR505 no session: exit 0"; else bad "PR505 exit" "rc=$rc out=$out"; fi
py_check "PR505 session is null" "d['session'] is None"
py_check "PR505 agents is null" "d['agents'] is None"
py_check "PR505 agents_unlinked is null" "d['agents_unlinked'] is None"
py_check "PR505 review_rounds.agent is null" "d['review_rounds']['agent'] is None"
py_check "PR505 rounds_missing is null" "d['review_rounds']['rounds_missing'] is None"
py_check "PR505 findings is null" "d['findings'] is None"
py_check "PR505 review_rounds.github/threads still populated" \
  "d['review_rounds']['github'] == [] and d['review_rounds']['threads'] == {'total': 0, 'resolved': 0, 'by_author': {}}"

# =========================================================================
# GROUP C -- per-source null vs [] on failure, unknown[] + exit 2
# =========================================================================
echo; echo "C. per-source failure -> null + unknown[] + exit 2"

run_split --repo "$REPO" --stdout 506
if [ "$rc" -eq 2 ]; then ok "PR506 ci.runs gh failure: exit 2"; else bad "PR506 exit" "rc=$rc"; fi
py_check "PR506 ci.runs is null" "d['ci']['runs'] is None"
py_check "PR506 ci.runs_failed is null" "d['ci']['runs_failed'] is None"
py_check "PR506 unknown names ci.runs" "any('ci.runs' in u for u in d['unknown'])"

run_split --repo "$REPO" --stdout 507
if [ "$rc" -eq 2 ]; then ok "PR507 ci.runs truncated: exit 2"; else bad "PR507 exit" "rc=$rc"; fi
py_check "PR507 ci.runs is null (a truncated list is as untrustworthy as a failed one, S1)" "d['ci']['runs'] is None"
py_check "PR507 ci.runs_failed is null too" "d['ci']['runs_failed'] is None"
py_check "PR507 unknown names truncation" "any('truncated' in u for u in d['unknown'])"

run_split --repo "$REPO" --stdout 508
if [ "$rc" -eq 2 ]; then ok "PR508 threads gh failure: exit 2"; else bad "PR508 exit" "rc=$rc"; fi
py_check "PR508 threads is null" "d['review_rounds']['threads'] is None"
py_check "PR508 unknown names threads" "any('review_rounds.threads' in u for u in d['unknown'])"

run_split --repo "$REPO" --stdout 509
if [ "$rc" -eq 2 ]; then ok "PR509 threads truncated: exit 2"; else bad "PR509 exit" "rc=$rc"; fi
py_check "PR509 threads still populated (total 5, resolved 1 of 2 nodes)" \
  "d['review_rounds']['threads'] == {'total': 5, 'resolved': 1, 'by_author': {'x': 2}}"
py_check "PR509 unknown names truncation" "any('truncated' in u for u in d['unknown'])"

run_split --repo "$REPO" --stdout 510
if [ "$rc" -eq 2 ]; then ok "PR510 follow_ons gh failure: exit 2"; else bad "PR510 exit" "rc=$rc"; fi
py_check "PR510 follow_ons is null" "d['follow_ons'] is None"
py_check "PR510 unknown names follow_ons" "any('follow_ons' in u for u in d['unknown'])"

# =========================================================================
# GROUP D -- unmerged PR REFUSEs
# =========================================================================
echo; echo "D. unmerged PR"
run --repo "$REPO" --stdout 511
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'not merged'; then
  ok "PR511 unmerged: REFUSE (exit 2)"
else
  bad "PR511 unmerged" "rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q '^{'; then bad "PR511 REFUSE printed a record"; else ok "PR511 REFUSE printed nothing"; fi

# =========================================================================
# GROUP E -- rounds_missing arithmetic
# =========================================================================
echo; echo "E. rounds_missing"
run_split --repo "$REPO" --session sess-512 --stdout 512
py_check "PR512 round 2 only -> rounds_missing {agent-review: [1]}" "d['review_rounds']['rounds_missing'] == {'agent-review': [1]}"

run_split --repo "$REPO" --session sess-513 --stdout 513
py_check "PR513 round 1 only -> rounds_missing {agent-review: []}" "d['review_rounds']['rounds_missing'] == {'agent-review': []}"

run_split --repo "$REPO" --session sess-515 --stdout 515
py_check "PR515 rounds 1 and 3 recorded -> rounds_missing {agent-review: [2]}" "d['review_rounds']['rounds_missing'] == {'agent-review': [2]}"

# =========================================================================
# GROUP F -- missing sibling REFUSEs
# =========================================================================
echo; echo "F. missing sibling"
ISOLATED="$TMP/isolated"
mkdir -p "$ISOLATED"
cp "$SUT" "$ISOLATED/pr-record.py"
out=$(HOME="$HOMEDIR" "$PY" "$ISOLATED/pr-record.py" --repo "$REPO" --stdout 501 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'filed-from.py'; then
  ok "missing filed-from.py sibling: REFUSE (exit 2), names it"
else
  bad "missing sibling" "rc=$rc out=$out"
fi

# =========================================================================
# GROUP F2 -- C1 (malformed/invalid/null-pr result) + C3a (repo mismatch)
# + C3b (bounded head_ref match), PR 516
# =========================================================================
echo; echo "F2. C1/C3a/C3b -- agent linkage hardening (PR 516)"

run_split --repo "$REPO" --session sess-516 --stdout 516
[ "$rc" -eq 2 ] && ok "PR516 exits 2 (unknown[] from malformed results)" || bad "PR516 exit" "rc=$rc err=$err"
py_check "c1 (unparseable result) linked ONLY by brief, never by result" \
  "next(a for a in d['agents'] if a['id']=='agent-c1')['linked_by'] == ['brief']"
py_check "c1's malformed result names the file + recovered round 2 in unknown[]" \
  "any('agent-c1' in u and 'round 2' in u for u in d['unknown'])"
py_check "c2 (invalid verdict, no brief match) is fully unlinked" \
  "not any(a['id']=='agent-c2' for a in d['agents'])"
py_check "c2's invalid result is named in unknown[]" \
  "any('agent-c2' in u for u in d['unknown'])"
py_check "c3 (valid but repo mismatch) is fully unlinked, no unknown[] noise" \
  "not any(a['id']=='agent-c3' for a in d['agents']) and not any('agent-c3' in u for u in d['unknown'])"
py_check "c4 (null pr, otherwise valid) is fully unlinked" \
  "not any(a['id']=='agent-c4' for a in d['agents'])"
py_check "c4's null pr is named in unknown[] unconditionally" \
  "any('agent-c4' in u and 'null' in u for u in d['unknown'])"
py_check "c5 (brief 'find the prefix config') does NOT link -- 'fix' must not match inside 'prefix'" \
  "not any(a['id']=='agent-c5' for a in d['agents'])"
py_check "c6 (brief 'implement #516') links normally" \
  "any(a['id']=='agent-c6' and a['linked_by']==['brief'] for a in d['agents'])"
py_check "agents_unlinked counts c2, c3, c4, c5 (4)" "d['agents_unlinked'] == 4"

# =========================================================================
# GROUP F3 -- C2 (unreadable transcript/meta.json, non-object JSON line)
# =========================================================================
echo; echo "F3. C2 -- unreadable agent files (PR 517)"

run_split --repo "$REPO" --session sess-517 --stdout 517
[ "$rc" -eq 2 ] && ok "PR517 exits 2 (unknown[] from unreadable agent files)" || bad "PR517 exit" "rc=$rc err=$err"
py_check "d1's chmod-000 transcript is named in unknown[]" \
  "any('agent-d1' in u and 'unreadable' in u for u in d['unknown'])"
py_check "d1 does not silently read as plain agents_unlinked with no signal" \
  "not any(a['id']=='agent-d1' for a in d['agents'])"
py_check "d2's unreadable (truncated) meta.json is named in unknown[]" \
  "any('agent-d2' in u and 'meta.json' in u for u in d['unknown'])"
py_check "d3's non-object JSON line (a bare 42) is named in unknown[]" \
  "any('agent-d3' in u and 'non-object' in u for u in d['unknown'])"
py_check "d3 still links normally off its other, well-formed lines" \
  "any(a['id']=='agent-d3' and a['linked_by']==['brief'] for a in d['agents'])"

# =========================================================================
# GROUP F4 -- C3c (started-after-merge, and no-started_at at all)
# =========================================================================
echo; echo "F4. C3c -- timing gate (PR 518)"

run_split --repo "$REPO" --session sess-518 --stdout 518
[ "$rc" -eq 2 ] && ok "PR518 exits 2 (unknown[] from the no-started_at agent)" || bad "PR518 exit" "rc=$rc err=$err"
py_check "e1 (started after merged_at) excluded from agents[]" \
  "not any(a['id']=='agent-e1' for a in d['agents'])"
py_check "agents_after_merge counts e1 (1)" "d['agents_after_merge'] == 1"
py_check "e2 (no started_at at all) excluded from agents[], counted unlinked" \
  "not any(a['id']=='agent-e2' for a in d['agents'])"
py_check "e2's missing started_at is named in unknown[]" \
  "any('agent-e2' in u and 'started_at' in u for u in d['unknown'])"
py_check "agents_unlinked counts e2 (1), disjoint from agents_after_merge" "d['agents_unlinked'] == 1"

# =========================================================================
# GROUP F5 -- S4 (tier() reused from usage-pace.py; usage dedup by
# (message.id, requestId))
# =========================================================================
echo; echo "F5. S4 -- tier reuse + usage dedup key (PR 519)"

run_split --repo "$REPO" --session sess-519 --stdout 519
[ "$rc" -eq 0 ] && ok "PR519 exits 0" || bad "PR519 exit" "rc=$rc err=$err"
py_check "an unrecognized model family records 'other', not null" \
  "next(a for a in d['agents'] if a['id']=='agent-f1')['tier'] == 'other'"
py_check "usage dedup by (message.id, requestId): r1's LAST record (output 300) wins, both r2 lines (different message.id) add on top" \
  "next(a for a in d['agents'] if a['id']=='agent-f1')['usage']['output'] == 315"
py_check "usage dedup: input totals 2 (r1 last) + 5 (msg-1,r2) + 10 (msg-2,r2) = 17" \
  "next(a for a in d['agents'] if a['id']=='agent-f1')['usage']['input'] == 17"

# =========================================================================
# GROUP F6 -- S5 (ci.final maps both CheckRun and StatusContext shapes)
# =========================================================================
echo; echo "F6. S5 -- ci.final StatusContext mapping (PR 520)"

run_split --repo "$REPO" --stdout 520
[ "$rc" -eq 0 ] && ok "PR520 exits 0" || bad "PR520 exit" "rc=$rc err=$err"
py_check "ci.final has both entries mapped to {name, workflow, conclusion}" \
  "d['ci']['final'] == [{'name': 'validate', 'workflow': 'validate-registry', 'conclusion': 'SUCCESS'}, {'name': 'ci/legacy-status', 'workflow': None, 'conclusion': 'SUCCESS'}]"

# =========================================================================
# GROUP F7 -- S2 (session resolved by transcript; sidecar directory may not
# exist at all)
# =========================================================================
echo; echo "F7. S2 -- session directory need not exist (PR 521)"

run_split --repo "$REPO" --session sess-521-nodir --stdout 521
[ "$rc" -eq 0 ] && ok "PR521 exits 0 (no REFUSE for a missing sidecar directory)" || bad "PR521 exit" "rc=$rc err=$err"
py_check "agents is [] (a real, confident zero), not null" "d['agents'] == []"
py_check "agents_unlinked is 0, not null" "d['agents_unlinked'] == 0"

# =========================================================================
# GROUP G -- ledger idempotency
# =========================================================================
echo; echo "G. ledger idempotency"
LEDGER="$TMP/ledgers/pr-records.jsonl"
mkdir -p "$(dirname "$LEDGER")"

run --repo "$REPO" --ledger "$LEDGER" 514
if [ "$rc" -eq 0 ] && [ -f "$LEDGER" ]; then ok "first write to a fresh ledger succeeds"; else bad "first write" "rc=$rc out=$out"; fi
lines1=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines1" = "1" ] && ok "ledger has exactly one line" || bad "ledger line count" "got $lines1"

run --repo "$REPO" --ledger "$LEDGER" 514
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'already recorded'; then
  ok "duplicate write without --replace REFUSEs"
else
  bad "duplicate write" "rc=$rc out=$out"
fi
lines2=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines2" = "1" ] && ok "REFUSE left the ledger untouched" || bad "ledger untouched after REFUSE" "got $lines2 lines"

echo '{"kind":"pr-record","schema_version":1,"repo":"other/repo","pr":999,"marker":"keep-me"}' >> "$LEDGER"
run --repo "$REPO" --ledger "$LEDGER" --replace 514
if [ "$rc" -eq 0 ]; then ok "--replace succeeds on an existing entry"; else bad "--replace" "rc=$rc out=$out"; fi
lines3=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines3" = "2" ] && ok "--replace rewrote atomically (still 2 lines)" || bad "--replace line count" "got $lines3"
grep -q '"marker":"keep-me"' "$LEDGER" && ok "--replace left the unrelated line untouched" || bad "--replace touched unrelated line"

run --repo "$REPO" --ledger "$LEDGER" --stdout 501
if printf '%s' "$out" | grep -q '^{'; then ok "--stdout never touches the ledger (prints instead)"; else bad "--stdout output"; fi
lines4=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines4" = "2" ] && ok "--stdout left the ledger line count unchanged" || bad "--stdout ledger side effect" "got $lines4"

# ----- C5: --replace must genuinely change content, not silently no-op ----
# The FIRST write above (no --session) left PR514's own line with
# `"agents": null`. Replacing it WITH --session sess-514 (a real session
# with an empty subagents/ dir) must flip that same line to
# `"agents": []` -- a mutation that makes --replace a no-op (e.g. writing
# the OLD record back, or writing the new one to the wrong line) leaves it
# `null` and this check catches it.
py_check_ledger() {
  local label=$1 expr=$2
  res=$("$PY" -c "
import json
target = None
with open('$LEDGER', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and obj.get('repo') == '$REPO' and obj.get('pr') == 514:
            target = obj
d = target
print(bool($expr))
" 2>&1)
  if [ "$res" = "True" ]; then ok "$label"; else bad "$label" "got: $res"; fi
}
py_check_ledger "before the session-bearing --replace, PR514's line has agents: null" "d['agents'] is None"

run --repo "$REPO" --ledger "$LEDGER" --session sess-514 --replace 514
[ "$rc" -eq 0 ] && ok "--replace with a session succeeds" || bad "--replace with session" "rc=$rc out=$out"
py_check_ledger "C5: --replace genuinely changed PR514's content (agents: [] now, not null)" "d['agents'] == []"
lines5=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines5" = "2" ] && ok "that --replace still did not change the line count" || bad "line count after content-changing replace" "got $lines5"

# ----- Copilot thread: --replace must collapse EVERY duplicate, not just one --
# A ledger already holding two lines for (repo, 514) -- a hand edit, or a race
# from before the lock existed -- must come out of --replace with exactly one.
grep "\"pr\": 514" "$LEDGER" | head -1 >> "$LEDGER"
dupcount=$(grep -c "\"pr\": 514" "$LEDGER" | tr -d ' ')
[ "$dupcount" = "2" ] && ok "fixture: ledger now holds two lines for PR514" || bad "dup fixture" "got $dupcount"
run --repo "$REPO" --ledger "$LEDGER" --session sess-514 --replace 514
[ "$rc" -eq 0 ] && ok "--replace over two duplicates succeeds" || bad "--replace over dups" "rc=$rc out=$out"
dupcount=$(grep -c "\"pr\": 514" "$LEDGER" | tr -d ' ')
[ "$dupcount" = "1" ] && ok "--replace collapsed both duplicates into one line" || bad "--replace left duplicates" "got $dupcount"
grep -q '"marker":"keep-me"' "$LEDGER" && ok "--replace over dups left the unrelated line" || bad "--replace over dups touched unrelated line"

# ----- C5: the duplicate key is (repo, pr), never pr alone -------------
run --repo "other/repo" --ledger "$LEDGER" 514
[ "$rc" -eq 0 ] && ok "C5: the SAME pr number (514) in a DIFFERENT repo is accepted, not treated as a duplicate" \
  || bad "C5: dup key must include repo" "rc=$rc out=$out"
lines6=$(wc -l < "$LEDGER" | tr -d ' ')
[ "$lines6" = "3" ] && ok "ledger now has 3 lines (both repos' PR 514, plus the unrelated marker line)" \
  || bad "line count after cross-repo write" "got $lines6"
grep -c '"repo": "other/repo", "pr": 514' "$LEDGER" | grep -q '^1$' \
  && ok "other/repo#514 is really present as its own line" || bad "other/repo#514 missing"
grep -c "\"repo\": \"$REPO\", \"pr\": 514" "$LEDGER" | grep -q '^1$' \
  && ok "$REPO#514 is still present, untouched by the cross-repo write" || bad "$REPO#514 missing after cross-repo write"

# =========================================================================
# GROUP G2 -- S3: --replace preserves blank lines and file mode, follows a
# symlink through to its target, and detects a POSSIBLE duplicate (an
# unparseable line whose raw text still names this repo+pr)
# =========================================================================
echo; echo "G2. S3 -- ledger structure preservation + possible-duplicate detection"

REALLEDGER="$TMP/ledgers/real-ledger.jsonl"
printf '%s\n' \
  '{"kind":"pr-record","repo":"x/y","pr":1}' \
  '' \
  '{"kind":"pr-record","repo":"acme/widgets","pr":501,"session":{"id":"s TRUNCATED' \
  '   ' \
  '{"kind":"pr-record","repo":"z/z","pr":2}' \
  > "$REALLEDGER"
printf 'no-trailing-newline-marker' >> "$REALLEDGER"
chmod 640 "$REALLEDGER"

run --repo "$REPO" --ledger "$REALLEDGER" 501
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'possibly.*already be a record\|unparseable'; then
  ok "S3: an unparseable line naming this repo+pr REFUSEs as a possible duplicate"
else
  bad "S3: possible-duplicate detection" "rc=$rc out=$out"
fi
grep -qx '' "$REALLEDGER" && ok "S3: the REFUSE left the blank line intact" || bad "S3: blank line lost on REFUSE"

run --repo "$REPO" --ledger "$REALLEDGER" --replace 501
[ "$rc" -eq 0 ] && ok "S3: --replace overwrites even a possible (unparseable) duplicate" || bad "S3: --replace on possible dup" "rc=$rc out=$out"
grep -qx '{"kind":"pr-record","repo":"x/y","pr":1}' "$REALLEDGER" && ok "S3: unrelated x/y#1 line still intact" || bad "S3: x/y#1 lost"
grep -qx '{"kind":"pr-record","repo":"z/z","pr":2}' "$REALLEDGER" && ok "S3: unrelated z/z#2 line still intact" || bad "S3: z/z#2 lost"
grep -qx '' "$REALLEDGER" && ok "S3: the blank line survived --replace too" || bad "S3: blank line lost on --replace"
grep -qx '   ' "$REALLEDGER" && ok "S3: the whitespace-only line survived --replace too" || bad "S3: whitespace line lost on --replace"
mode_after=$(stat -f '%Lp' "$REALLEDGER" 2>/dev/null || stat -c '%a' "$REALLEDGER" 2>/dev/null)
[ "$mode_after" = "640" ] && ok "S3: the ledger's file mode (640) survived --replace" || bad "S3: file mode not preserved" "got $mode_after"

# ----- symlink write-through -----
LINKTARGET="$TMP/ledgers/link-target.jsonl"
: > "$LINKTARGET"
LEDGERLINK="$TMP/ledgers/ledger-link.jsonl"
ln -s "$LINKTARGET" "$LEDGERLINK"
run --repo "$REPO" --ledger "$LEDGERLINK" 501
[ "$rc" -eq 0 ] && ok "S3: write through a symlinked ledger path succeeds" || bad "S3: symlink write" "rc=$rc out=$out"
[ -L "$LEDGERLINK" ] && ok "S3: the ledger path is still a symlink (not replaced by a plain file)" || bad "S3: symlink was replaced by a plain file"
lt_lines=$(wc -l < "$LINKTARGET" | tr -d ' ')
[ "$lt_lines" = "1" ] && ok "S3: the record was actually written to the symlink's TARGET file" || bad "S3: write did not reach the symlink target" "got $lt_lines lines in target"

# =========================================================================
# GROUP G3 -- C4: exclusive lock, append-only for a new record, and two
# concurrent writers both surviving
# =========================================================================
echo; echo "G3. C4 -- ledger locking and concurrent writers"

APPENDLEDGER="$TMP/ledgers/append-only.jsonl"
run --repo "$REPO" --ledger "$APPENDLEDGER" 501
before_mtime_inode=$(stat -f '%i' "$APPENDLEDGER" 2>/dev/null || stat -c '%i' "$APPENDLEDGER" 2>/dev/null)
run --repo "$REPO" --ledger "$APPENDLEDGER" 505
after_inode=$(stat -f '%i' "$APPENDLEDGER" 2>/dev/null || stat -c '%i' "$APPENDLEDGER" 2>/dev/null)
[ "$before_mtime_inode" = "$after_inode" ] && ok "C4: a brand-new (repo, pr) is APPENDED in place (same inode), never rewritten" \
  || bad "C4: append should not replace the file's inode" "before=$before_mtime_inode after=$after_inode"
[ -f "${APPENDLEDGER}.lock" ] && ok "C4: a sidecar <ledger>.lock file exists" || bad "C4: no lock file created"

RACELEDGER="$TMP/ledgers/race.jsonl"
: > "$RACELEDGER"
( HOME="$HOMEDIR" "$PY" "$SUT" --repo "$REPO" --ledger "$RACELEDGER" 522 >/tmp/race1.$$out 2>&1 ) &
PID1=$!
( HOME="$HOMEDIR" "$PY" "$SUT" --repo "$REPO" --ledger "$RACELEDGER" 523 >/tmp/race2.$$out 2>&1 ) &
PID2=$!
wait "$PID1"; RC1=$?
wait "$PID2"; RC2=$?
rm -f "/tmp/race1.$$out" "/tmp/race2.$$out"
[ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && ok "C4: both concurrent writers exit 0" || bad "C4: concurrent writer exit codes" "rc1=$RC1 rc2=$RC2"
race_lines=$(wc -l < "$RACELEDGER" | tr -d ' ')
[ "$race_lines" = "2" ] && ok "C4: both concurrent writers' records survive (2 lines, neither clobbered the other)" \
  || bad "C4: concurrent write line count" "got $race_lines"
"$PY" -c "
import json
prs = set()
with open('$RACELEDGER', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)  # must be valid JSON -- a torn/interleaved write would fail this
        prs.add(obj['pr'])
import sys
sys.exit(0 if prs == {522, 523} else 1)
"
[ $? -eq 0 ] && ok "C4: both records are valid JSON with the expected PR numbers (522 and 523)" \
  || bad "C4: concurrent write content"

# =========================================================================
# GROUP H -- no __pycache__ left behind anywhere in the checkout
# =========================================================================
echo; echo "H. no __pycache__"
found=$(find "$HERE" -maxdepth 1 -name '__pycache__' 2>/dev/null)
if [ -z "$found" ]; then ok "no __pycache__ under assets/scripts/"; else bad "__pycache__ present" "$found"; fi

echo
echo "pr-record.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
