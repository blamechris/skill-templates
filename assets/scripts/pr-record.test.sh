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
jsonl(os.path.join(sdir512, "subagents", "agent-bbb00001.jsonl"), [user("about #512")])
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
jsonl(os.path.join(sdir513, "subagents", "agent-ccc00001.jsonl"), [user("about #513")])
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
jsonl(os.path.join(sdir515, "subagents", "agent-ddd00001.jsonl"), [user("about #515")])
jfile(os.path.join(sdir515, "subagents", "agent-ddd00001.result.json"), {
    "schema": 1, "source": "record", "session": "sess-515", "agent": "agent-ddd00001",
    "skill": "agent-review", "pr": 515,
    "result": {"kind": "review-result", "verdict": "request_changes", "body_matches_tree": True,
               "pr": 515, "skill": "agent-review", "round": 1, "findings": []},
})
jfile(os.path.join(sdir515, "subagents", "agent-ddd00002.meta.json"),
      {"agentType": "general-purpose", "description": "Review round 3", "model": "opus"})
jsonl(os.path.join(sdir515, "subagents", "agent-ddd00002.jsonl"), [user("about #515")])
jfile(os.path.join(sdir515, "subagents", "agent-ddd00002.result.json"), {
    "schema": 1, "source": "record", "session": "sess-515", "agent": "agent-ddd00002",
    "skill": "agent-review", "pr": 515,
    "result": {"kind": "review-result", "verdict": "approve", "body_matches_tree": True,
               "pr": 515, "skill": "agent-review", "round": 3, "findings": []},
})

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
py_check "session.nominates_pr" "d['session']['nominates_pr'] is True"
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
py_check "rounds_missing == [] (only round 1 exists)" "d['review_rounds']['rounds_missing'] == []"
py_check "findings length == 3, tagged with agent+round" \
  "len(d['findings']) == 3 and all(f['agent']=='agent-aaa00001' and f['round']==1 for f in d['findings'])"

# =========================================================================
# GROUP B -- session validation
# =========================================================================
echo; echo "B. session validation"

run_split --repo "$REPO" --session sess-502 --stdout 502
if [ "$rc" -eq 0 ]; then ok "PR502 flag-sourced outside span: accepted (exit 0)"; else bad "PR502 exit" "rc=$rc err=$err"; fi
py_check "PR502 merged_within_span is false" "d['session']['merged_within_span'] is False"
py_check "PR502 nominates_pr is true" "d['session']['nominates_pr'] is True"

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
py_check "PR507 ci.runs still populated (not null) despite truncation warning" "d['ci']['runs'] is not None and len(d['ci']['runs']) == 100"
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
py_check "PR512 round 2 only -> rounds_missing [1]" "d['review_rounds']['rounds_missing'] == [1]"

run_split --repo "$REPO" --session sess-513 --stdout 513
py_check "PR513 round 1 only -> rounds_missing []" "d['review_rounds']['rounds_missing'] == []"

run_split --repo "$REPO" --session sess-515 --stdout 515
py_check "PR515 rounds 1 and 3 recorded -> rounds_missing [2]" "d['review_rounds']['rounds_missing'] == [2]"

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

# =========================================================================
# GROUP H -- no __pycache__ left behind anywhere in the checkout
# =========================================================================
echo; echo "H. no __pycache__"
found=$(find "$HERE" -maxdepth 1 -name '__pycache__' 2>/dev/null)
if [ -z "$found" ]; then ok "no __pycache__ under assets/scripts/"; else bad "__pycache__ present" "$found"; fi

echo
echo "pr-record.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
