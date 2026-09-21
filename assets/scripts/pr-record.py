#!/usr/bin/env python3
"""Join table for epic #266: one JSON line per merged PR, joining the leading
review signals with who did the work and at what tier.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/pr-record.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/pr-record.py PR [--repo OWNER/NAME] [--session SID]
      [--ledger PATH] [--replace] [--stdout]

THE PROBLEM (#270): review-result.py and session-distill.py are the leading
signals, rework-lag.py the lagging one, and all three key on (repo, pr) --
but until now nothing wrote that key down together with who did the work, at
what tier, and in how many rounds. pr-record.py runs at merge time, in the
session that merged (or later, for backfill, with --session given
explicitly), and writes exactly the record documented in
docs/pr-record-shape.md -- read that file first; this docstring is the
field-by-field/exit-code reference, not the design rationale.

THE RECORD (schema_version 1) -- one line per (repo, pr):
  kind, schema_version, repo, pr, recorded_at
  pr_meta          {title, author, merged_by, head_ref, created_at,
                    merged_at, merge_commit, additions, deletions,
                    changed_files, closes[]} from one `gh pr view --json`
                   call. The PR not existing, gh being unable to answer, or
                   the PR not being merged is a REFUSE -- no PR, no record.
  commits[]        {oid, headline, authored_at}, from the same call.
  session          {id, source ("flag"|"env"), transcript, nominates_pr,
                    merged_within_span, main_models} or null when no
                   session id was given and none was found in
                   $CLAUDE_CODE_SESSION_ID -- the whole agent half of the
                   record is null in that case (see SESSION VALIDATION).
  agents[]         {id, linked_by[], description, agent_type,
                    model_requested, models_observed, tier, started_at,
                    ended_at, usage} -- one per subagent LINKED to this PR
                   (see AGENT LINKAGE); null when session is null.
  agents_unlinked  count of subagents seen in the session but not linked to
                   this PR; null when session is null.
  review_rounds    {agent[], rounds_missing[], github[], threads} --
                   agent[] and rounds_missing[] are null when session is
                   null; github[] (from the PR view call's own `reviews`)
                   and threads (from a GraphQL reviewThreads call) do not
                   depend on session and are always attempted.
  findings[]       every finding from every linked agent's review-result
                   document, tagged with its agent id and round; null when
                   session is null.
  follow_ons[]     filed-from.py's descendants(pr, repo, depth=1) -- null +
                   an unknown[] entry on a `?` (gh failure) node anywhere
                   in the walk.
  ci               {final[], runs[], runs_failed} -- final[] is read
                   straight off the PR view call's own statusCheckRollup;
                   runs[] comes from `gh run list --branch <head_ref>`,
                   filtered down to runs whose headSha is one of this PR's
                   own commit oids; either half is null (with an
                   unknown[] entry) on a gh failure or a run list
                   truncated at its own --limit.
  unknown[]        every source above that could not be answered, in
                   prose -- never a silent null with no explanation.

SESSION VALIDATION (design call 1 of docs/pr-record-shape.md): a session id
is never searched for, only validated once given, by --session or
$CLAUDE_CODE_SESSION_ID (in that order; neither may contain `/` or `..` --
same discipline review-result.py's resolve_session_id applies, since a
session id is a directory NAME under ~/.claude/projects/*/, not a path).
Its resolved session directory's own main transcript
(<session-dir>.jsonl, a SIBLING of the session directory, not inside it)
must NOMINATE this PR -- the same URL_RE/REF_RE/BARE_RE grammar
usage-benchmark-row.py's scan_work and rework-lag.py's --attribute use,
imported from rework-lag.py rather than re-implemented -- or the run
REFUSES entirely (exit 2, nothing written): a record filed under the wrong
session is worse than one filed under none. A session id sourced from
$CLAUDE_CODE_SESSION_ID (source: "env") additionally REFUSES unless the
PR's own mergedAt falls inside the transcript's own [first, last]
timestamp span (merged_within_span) -- the env var only proves which
session is running, not that it was running when the merge happened. A
session id given with --session (source: "flag") records
merged_within_span but does not enforce it -- naming a session by hand is
a deliberate claim the caller is making.

AGENT LINKAGE (design call 2): an agent belongs to this PR only with
evidence, recorded in linked_by -- "result" (a sidecar `.result.json`
whose own `pr` field equals this PR) and/or "brief" (the agent's first
user-turn message names this PR by `#N`, `PR N`, or `pull/N` -- each
word-boundaried so `#2780` never matches `#278` -- or names the PR's own
head branch as a substring). Neither the sidecar meta.json nor the
transcript carries a PR number directly (gitBranch/cwd read HEAD/~ for
every line), which is why both signals exist; an agent matching neither is
counted in agents_unlinked, never silently attributed.

REVIEW ROUNDS (design call 3): review-result.py's `record` command REFUSES
to overwrite an existing `.result.json` without --force, so only the
LATEST round an agent's result was recorded at ever survives on disk -- a
PR reviewed three times by the same agent shows one row with `round: 3`,
and `rounds_missing` lists every integer below the highest recorded round
that has no row of its own ([1, 2] in that example), so the record never
silently reads as "one round of review" when there were more.

REUSE -- nothing here is re-implemented that a sibling already owns:
review-result.py's resolve_session_dir, sidecar_dirs, find_sidecar_dir,
validate_document (session/sidecar walking, and the review-result schema
check); filed-from.py's descendants/_has_error (the `Filed from:`
follow-on walk); rework-lag.py's URL_RE/REF_RE/BARE_RE and
_transcript_span_and_text (session nomination). Each is imported BY PATH
-- the same importlib.util.spec_from_file_location pattern rework-lag.py
uses for filed-from.py -- with sys.dont_write_bytecode toggled around the
import so no stray __pycache__/ appears in the checkout. Importing
rework-lag.py this way only runs its module top level (constants, regexes,
function/class definitions); its own `if __name__ == "__main__"` guard
means `main()` -- and its own internal filed-from.py dependency -- never
runs. A missing sibling REFUSES (exit 2, naming it): filed-from.py is
needed unconditionally (follow_ons is always attempted); review-result.py
and rework-lag.py are only needed, and only loaded, once a session id is
actually being validated.

LEDGER: one record per (repo, pr), one JSON object per line, default path
~/Obsidian/no-it-all/ledgers/pr-records.jsonl ($CLAUDE_PR_LEDGER, then
--ledger, each overriding the one before). The parent directory is
created if missing. Writing a PR already present in the ledger REFUSES
(exit 2, nothing written) unless --replace, which rewrites the ledger
atomically (temp file + os.replace) with the old line swapped out and
every other line untouched byte-for-byte. --stdout prints the record to
stdout and does not touch the ledger at all -- no duplicate check runs,
because nothing is written.

Exit codes:
  0   every requested source answered (unknown[] is empty) and the record
      was emitted (to stdout or the ledger).
  2   REFUSE -- no such PR, gh could not answer, the PR is not merged, a
      named session that does not nominate this PR or (env-sourced only)
      falls outside merged_within_span, a session id containing `/` or
      `..`, a duplicate ledger entry without --replace, or a missing
      required sibling script. Nothing is written in any REFUSE case.
      OR unknown[] is non-empty -- the record IS still emitted/written in
      this case, matching rework-lag.py's own contract: an incomplete
      answer is not a failure to produce output, only a reason the exit
      code says so.
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

GH_TIMEOUT = 30
CI_RUN_LIMIT = 100
THREADS_PAGE = 100
DEFAULT_LEDGER = "~/Obsidian/no-it-all/ledgers/pr-records.jsonl"

PR_VIEW_FIELDS = (
    "number,title,author,mergedBy,headRefName,createdAt,mergedAt,"
    "mergeCommit,additions,deletions,changedFiles,closingIssuesReferences,"
    "commits,reviews,statusCheckRollup,state"
)

TIER_ORDER = ("fable", "opus", "sonnet", "haiku")
TIER_ALIASES = {"mythos": "fable"}


def die(msg, code=2):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# time helpers
# ---------------------------------------------------------------------------

def parse_iso(s):
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def fmt_iso(dt):
    if dt is None:
        return None
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso():
    return fmt_iso(datetime.now(timezone.utc))


# ---------------------------------------------------------------------------
# sibling reuse -- imported BY PATH, never re-implemented
# ---------------------------------------------------------------------------

def _load_sibling(filename, modname):
    """Import assets/scripts/<filename> by path, the same
    importlib.util.spec_from_file_location pattern rework-lag.py uses for
    filed-from.py. REFUSEs (exit 2) if the sibling is missing -- this
    script never re-implements what a sibling already owns."""
    sib = Path(__file__).resolve().parent / filename
    if not sib.exists():
        die(
            f"sibling assets/scripts/{filename} is missing. pr-record.py "
            f"reuses its logic rather than re-implementing it, and refuses "
            f"to run without it (expected at {sib})."
        )
    # Importing a sibling script by path would otherwise leave a stray
    # assets/scripts/__pycache__/ in the checkout every time this runs --
    # disabled for this one load, restored immediately after (rework-lag.py's
    # own pattern for filed-from.py).
    prev = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(modname, str(sib))
        if spec is None or spec.loader is None:
            die(f"sibling {sib} exists but importlib could not build a loader for it")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = prev
    return mod


def load_review_result():
    return _load_sibling("review-result.py", "pr_record_review_result")


def load_filed_from():
    return _load_sibling("filed-from.py", "pr_record_filed_from")


def load_rework_lag():
    return _load_sibling("rework-lag.py", "pr_record_rework_lag")


def _call_refuse(fn, *a, **kw):
    """Call a sibling's die()-based function. Its own REFUSE message is
    already on stderr by the time it raises SystemExit; only the exit code
    needs remapping to pr-record's own convention (2), so pr-record's exit
    semantics hold regardless of what a sibling's own die() uses."""
    try:
        return fn(*a, **kw)
    except SystemExit:
        sys.exit(2)


# ---------------------------------------------------------------------------
# gh plumbing
# ---------------------------------------------------------------------------

def _run(args, timeout=GH_TIMEOUT):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 1, "", f"{args[0]}: command not found"
    except subprocess.TimeoutExpired:
        return 1, "", f"{args[0]}: timed out after {timeout}s"
    except OSError as e:
        return 1, "", f"{args[0]}: {e}"


def gh_json(args):
    rc, out, err = _run(["gh"] + args)
    if rc != 0:
        return None, err.strip() or f"gh exited {rc}"
    try:
        return json.loads(out), None
    except ValueError as e:
        return None, f"gh returned non-JSON output: {e}"


def current_repo():
    rc, out, _ = _run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    out = out.strip()
    return out if rc == 0 and out else None


# ---------------------------------------------------------------------------
# model tier (fable > opus > sonnet > haiku), mirroring usage-pace.py's
# tier() substring match -- not imported (usage-pace.py is not in this
# script's required-reuse set and carries unrelated pricing state), but
# kept in step with it: same order, same "mythos prices as fable" alias.
# ---------------------------------------------------------------------------

def model_tier(model):
    if not model:
        return None
    m = model.lower()
    for alias, fam in TIER_ALIASES.items():
        if alias in m:
            return fam
    for fam in TIER_ORDER:
        if fam in m:
            return fam
    return None


# ---------------------------------------------------------------------------
# PR meta / commits / ci.final / review_rounds.github
# ---------------------------------------------------------------------------

def fetch_pr(repo, pr):
    """(pr_data, err) from one `gh pr view --json ...` call."""
    return gh_json(["pr", "view", str(pr), "--repo", repo, "--json", PR_VIEW_FIELDS])


def build_pr_meta(pr_data):
    closes = sorted(
        r["number"] for r in (pr_data.get("closingIssuesReferences") or [])
        if isinstance(r, dict) and r.get("number") is not None
    )
    return {
        "title": pr_data.get("title") or "",
        "author": (pr_data.get("author") or {}).get("login"),
        "merged_by": (pr_data.get("mergedBy") or {}).get("login"),
        "head_ref": pr_data.get("headRefName"),
        "created_at": pr_data.get("createdAt"),
        "merged_at": pr_data.get("mergedAt"),
        "merge_commit": (pr_data.get("mergeCommit") or {}).get("oid"),
        "additions": pr_data.get("additions"),
        "deletions": pr_data.get("deletions"),
        "changed_files": pr_data.get("changedFiles"),
        "closes": closes,
    }


def build_commits(pr_data):
    out = []
    for c in pr_data.get("commits") or []:
        if not isinstance(c, dict) or not c.get("oid"):
            continue
        out.append({
            "oid": c["oid"],
            "headline": c.get("messageHeadline") or "",
            "authored_at": c.get("authoredDate"),
        })
    return out


def build_ci_final(pr_data):
    out = []
    for c in pr_data.get("statusCheckRollup") or []:
        if not isinstance(c, dict):
            continue
        out.append({
            "name": c.get("name"),
            "workflow": c.get("workflowName"),
            "conclusion": c.get("conclusion"),
        })
    return out


def build_reviews_github(pr_data):
    out = []
    for r in pr_data.get("reviews") or []:
        if not isinstance(r, dict):
            continue
        out.append({
            "author": (r.get("author") or {}).get("login"),
            "state": r.get("state"),
            "submitted_at": r.get("submittedAt"),
        })
    return out


# ---------------------------------------------------------------------------
# ci.runs
# ---------------------------------------------------------------------------

def ci_runs_for(repo, head_ref, commit_oids, unknown):
    runs_raw, err = gh_json([
        "run", "list", "--repo", repo, "--branch", head_ref,
        "--limit", str(CI_RUN_LIMIT),
        "--json", "databaseId,workflowName,conclusion,headSha,event,createdAt",
    ])
    if runs_raw is None:
        unknown.append(f"ci.runs (`gh run list` failed: {err})")
        return None, None
    if len(runs_raw) >= CI_RUN_LIMIT:
        unknown.append(
            f"ci.runs possibly truncated (gh run list returned the full "
            f"--limit of {CI_RUN_LIMIT})"
        )
    runs = [
        {
            "id": r.get("databaseId"),
            "workflow": r.get("workflowName"),
            "conclusion": r.get("conclusion"),
            "head_sha": r.get("headSha"),
            "event": r.get("event"),
            "created_at": r.get("createdAt"),
        }
        for r in runs_raw
        if isinstance(r, dict) and r.get("headSha") in commit_oids
    ]
    failed = sum(1 for r in runs if (r["conclusion"] or "").lower() == "failure")
    return runs, failed


# ---------------------------------------------------------------------------
# review_rounds.threads (GraphQL)
# ---------------------------------------------------------------------------

_THREADS_QUERY = (
    "query($owner: String!, $name: String!, $number: Int!) {"
    " repository(owner: $owner, name: $name) {"
    "  pullRequest(number: $number) {"
    "   reviewThreads(first: 100) {"
    "    totalCount"
    "    nodes { isResolved comments(first: 1) { nodes { author { login } } } }"
    "   }"
    "  }"
    " }"
    "}"
)


def review_threads_for(repo, pr, unknown):
    if "/" not in repo:
        unknown.append(f"review_rounds.threads (repo {repo!r} is not OWNER/NAME)")
        return None
    owner, name = repo.split("/", 1)
    data, err = gh_json([
        "api", "graphql",
        "-f", "query=" + _THREADS_QUERY,
        "-f", "owner=" + owner,
        "-f", "name=" + name,
        "-F", "number=" + str(pr),
    ])
    if data is None:
        unknown.append(f"review_rounds.threads (gh api graphql failed: {err})")
        return None
    try:
        rt = data["data"]["repository"]["pullRequest"]["reviewThreads"]
    except (KeyError, TypeError):
        unknown.append("review_rounds.threads (unexpected graphql response shape)")
        return None
    if rt is None:
        unknown.append("review_rounds.threads (graphql returned no reviewThreads)")
        return None
    nodes = rt.get("nodes") or []
    total = rt.get("totalCount") or 0
    if total > len(nodes):
        unknown.append(
            f"review_rounds.threads possibly truncated (totalCount {total} "
            f"> {len(nodes)} nodes returned)"
        )
    resolved = 0
    by_author = {}
    for n in nodes:
        if not isinstance(n, dict):
            continue
        if n.get("isResolved"):
            resolved += 1
        comments = ((n.get("comments") or {}).get("nodes")) or []
        author = None
        if comments and isinstance(comments[0], dict):
            author = (comments[0].get("author") or {}).get("login")
        if author:
            by_author[author] = by_author.get(author, 0) + 1
    return {"total": total, "resolved": resolved, "by_author": by_author}


# ---------------------------------------------------------------------------
# follow_ons -- filed-from.py's descendants(), reused, not re-implemented
# ---------------------------------------------------------------------------

def follow_ons_for(repo, pr, filed_from_mod, unknown):
    children = filed_from_mod.descendants(pr, repo, 1, {pr})
    if filed_from_mod._has_error(children):
        unknown.append(f"follow_ons (gh failure while searching for issues filed from #{pr})")
        return None
    return [
        {"number": c.get("number"), "state": c.get("state"), "title": c.get("title") or ""}
        for c in children
    ]


# ---------------------------------------------------------------------------
# session nomination -- rework-lag.py's URL_RE/REF_RE/BARE_RE, reused
# ---------------------------------------------------------------------------

def nominates_pr(rework_lag_mod, text, pr, target_repo):
    qualified = set()
    if target_repo:
        for rgx in (rework_lag_mod.URL_RE, rework_lag_mod.REF_RE):
            for mo in rgx.finditer(text):
                if mo.group(1) == target_repo:
                    qualified.add(int(mo.group(2)))
    bare = {int(mo.group(1)) for mo in rework_lag_mod.BARE_RE.finditer(text)}
    return pr in (qualified | bare)


def tally_models(jsonl_path):
    """{model: count} over every `assistant` line's message.model in
    JSONL_PATH -- a raw distribution, not deduplicated by requestId (that
    dedup is for `usage`'s token totals; this is "how many turns used which
    model")."""
    counts = {}
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "assistant":
                    continue
                m = (obj.get("message") or {}).get("model")
                if m:
                    counts[m] = counts.get(m, 0) + 1
    except OSError:
        return {}
    return counts


# ---------------------------------------------------------------------------
# agent brief / span / usage
# ---------------------------------------------------------------------------

def first_user_text(jsonl_path):
    """The first `type: "user"` line's message content in JSONL_PATH -- a
    plain string, or the concatenated text blocks of a content-block list.
    None if the file is unreadable or carries no such line."""
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "user":
                    continue
                content = (obj.get("message") or {}).get("content")
                if isinstance(content, str):
                    return content
                if isinstance(content, list):
                    parts = [
                        b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text"
                    ]
                    text = "\n".join(p for p in parts if p)
                    return text or None
                return None
    except OSError:
        return None
    return None


def brief_names_pr(text, pr, head_ref):
    """True if TEXT names PR number PR as `#N`, `PR N`, or `pull/N` (each
    word-boundaried so `#2780` never matches `#278`), or contains HEAD_REF
    as a substring."""
    if not text:
        return False
    if re.search(r"(?<![\w/#])#%d\b" % pr, text):
        return True
    if re.search(r"\bPR\s+%d\b" % pr, text, re.IGNORECASE):
        return True
    if re.search(r"pull/%d\b" % pr, text):
        return True
    if head_ref and head_ref in text:
        return True
    return False


def agent_span(jsonl_path):
    """(started_at, ended_at) ISO strings from the first/last `timestamp`
    seen across every line of JSONL_PATH, or (None, None)."""
    t0 = t1 = None
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                ts = obj.get("timestamp")
                if not ts:
                    continue
                try:
                    dt = parse_iso(ts)
                except ValueError:
                    continue
                if t0 is None or dt < t0:
                    t0 = dt
                if t1 is None or dt > t1:
                    t1 = dt
    except OSError:
        return None, None
    return fmt_iso(t0), fmt_iso(t1)


def agent_usage(jsonl_path):
    """Token totals from every `assistant` line's message.usage in
    JSONL_PATH, deduplicated by requestId keeping the LAST record for each
    (the first is always a partial -- the #259 lesson). A line with no
    requestId is never deduplicated against anything: it counts once,
    always."""
    by_request = {}
    no_request = []
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "assistant":
                    continue
                usage = (obj.get("message") or {}).get("usage")
                if not isinstance(usage, dict):
                    continue
                rid = obj.get("requestId")
                if rid:
                    by_request[rid] = usage  # last write wins
                else:
                    no_request.append(usage)
    except OSError:
        return None

    totals = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}

    def add(u):
        totals["input"] += u.get("input_tokens") or 0
        totals["output"] += u.get("output_tokens") or 0
        totals["cache_read"] += u.get("cache_read_input_tokens") or 0
        totals["cache_creation"] += u.get("cache_creation_input_tokens") or 0

    for u in by_request.values():
        add(u)
    for u in no_request:
        add(u)
    return totals


# ---------------------------------------------------------------------------
# agents[] / review_rounds.agent[] / findings[] / rounds_missing[]
# ---------------------------------------------------------------------------

def enumerate_agent_names(session_dir, rr_mod):
    names = set()
    for d in rr_mod.sidecar_dirs(session_dir):
        for p in glob.glob(os.path.join(d, "agent-*.meta.json")):
            names.add(os.path.basename(p)[: -len(".meta.json")])
        for p in glob.glob(os.path.join(d, "agent-*.jsonl")):
            names.add(os.path.basename(p)[: -len(".jsonl")])
    return sorted(names)


def collect_agents(session_dir, pr, head_ref, rr_mod):
    """(agents, agents_unlinked) -- AGENTS carries one internal dict per
    LINKED agent (public fields plus `_result_doc`/`_result_wrapper`/
    `_result_path`, stripped before the record is emitted, used by
    collect_rounds_and_findings). agents_unlinked counts every agent seen
    that matched neither linkage signal."""
    agents = []
    unlinked = 0

    for name in enumerate_agent_names(session_dir, rr_mod):
        sidecar_dir = rr_mod.find_sidecar_dir(session_dir, name)
        if sidecar_dir is None:
            continue
        meta_path = os.path.join(sidecar_dir, name + ".meta.json")
        jsonl_path = os.path.join(sidecar_dir, name + ".jsonl")
        result_path = os.path.join(sidecar_dir, name + ".result.json")

        meta = None
        if os.path.isfile(meta_path):
            try:
                with open(meta_path, encoding="utf-8") as f:
                    meta = json.load(f)
            except (OSError, json.JSONDecodeError):
                meta = None

        result_wrapper = None
        result_doc = None
        if os.path.isfile(result_path):
            try:
                with open(result_path, encoding="utf-8") as f:
                    result_wrapper = json.load(f)
                if isinstance(result_wrapper, dict):
                    result_doc = result_wrapper.get("result")
            except (OSError, json.JSONDecodeError):
                result_wrapper = None
                result_doc = None

        linked_by = []
        if isinstance(result_doc, dict) and result_doc.get("pr") == pr:
            linked_by.append("result")
        brief = first_user_text(jsonl_path) if os.path.isfile(jsonl_path) else None
        if brief_names_pr(brief, pr, head_ref):
            linked_by.append("brief")

        if not linked_by:
            unlinked += 1
            continue

        started_at = ended_at = None
        models_observed = {}
        usage = None
        if os.path.isfile(jsonl_path):
            started_at, ended_at = agent_span(jsonl_path)
            models_observed = tally_models(jsonl_path)
            usage = agent_usage(jsonl_path)

        model_requested = (meta or {}).get("model")
        observed_model = max(models_observed, key=models_observed.get) if models_observed else None
        tier = model_tier(observed_model) or model_tier(model_requested)

        agents.append({
            "id": name,
            "linked_by": linked_by,
            "description": (meta or {}).get("description"),
            "agent_type": (meta or {}).get("agentType"),
            "model_requested": model_requested,
            "models_observed": models_observed,
            "tier": tier,
            "started_at": started_at,
            "ended_at": ended_at,
            "usage": usage,
            "_result_doc": result_doc,
            "_result_wrapper": result_wrapper,
            "_result_path": result_path if isinstance(result_doc, dict) else None,
        })

    return agents, unlinked


def public_agent(a):
    return {k: v for k, v in a.items() if not k.startswith("_")}


def collect_rounds_and_findings(agents, pr, rr_mod):
    """(review_rounds_agent, findings, rounds_missing) from every linked
    agent whose .result.json genuinely belongs to this PR (result.pr == pr)
    and validates against review-result.py's own schema."""
    rounds = []
    findings = []
    round_nums = []

    for a in agents:
        doc = a.get("_result_doc")
        wrapper = a.get("_result_wrapper")
        if not isinstance(doc, dict) or doc.get("pr") != pr:
            continue
        if rr_mod.validate_document(doc):
            continue  # corrupted/invalid -- never crash on it, just skip

        counts = {"critical": 0, "suggestion": 0, "nitpick": 0}
        mutated = 0
        for f in doc.get("findings") or []:
            if not isinstance(f, dict):
                continue
            sev = f.get("severity")
            if sev in counts:
                counts[sev] += 1
            if f.get("mutation_ran") is True:
                mutated += 1
            findings.append({
                "agent": a["id"],
                "round": doc.get("round"),
                "severity": sev,
                "title": f.get("title"),
                "file": f.get("file"),
                "line": f.get("line"),
                "mutation_ran": f.get("mutation_ran"),
                "red_line": f.get("red_line"),
            })

        rnd = doc.get("round")
        if isinstance(rnd, int) and not isinstance(rnd, bool):
            round_nums.append(rnd)

        rounds.append({
            "agent": a["id"],
            "skill": doc.get("skill"),
            "round": rnd,
            "verdict": doc.get("verdict"),
            "source": wrapper.get("source") if isinstance(wrapper, dict) else None,
            "critical": counts["critical"],
            "suggestion": counts["suggestion"],
            "nitpick": counts["nitpick"],
            "mutation_ran": mutated,
            "result_path": os.path.abspath(a["_result_path"]) if a.get("_result_path") else None,
        })

    rounds.sort(key=lambda r: (r["round"] if r["round"] is not None else -1, r["agent"]))
    max_round = max(round_nums) if round_nums else 0
    rounds_missing = sorted(set(range(1, max_round)) - set(round_nums)) if max_round > 0 else []
    return rounds, findings, rounds_missing


# ---------------------------------------------------------------------------
# session block
# ---------------------------------------------------------------------------

def resolve_session(explicit):
    """(sid, source) -- "flag" from --session, "env" from
    $CLAUDE_CODE_SESSION_ID, or (None, None) when neither is set. A session
    id containing `/` or `..` REFUSES: it names a directory under
    ~/.claude/projects/*/, not a path (review-result.py's own
    resolve_session_id discipline, applied the same way here)."""
    if explicit:
        sid, source = explicit.strip(), "flag"
    else:
        env = os.environ.get("CLAUDE_CODE_SESSION_ID")
        if not env or not env.strip():
            return None, None
        sid, source = env.strip(), "env"
    if "/" in sid or ".." in sid:
        die(
            f"session id {sid!r} must not contain '/' or '..' -- it names a "
            f"directory under ~/.claude/projects/*/, not a path"
        )
    return sid, source


def build_session_block(sid, source, pr, repo, merged_dt):
    """Loads review-result.py and rework-lag.py (only needed once a session
    id is actually being validated) and returns the `session` block, or
    REFUSEs per the SESSION VALIDATION rules in this module's docstring."""
    rr_mod = load_review_result()
    rl_mod = load_rework_lag()

    session_dir = _call_refuse(rr_mod.resolve_session_dir, sid)
    main_transcript = session_dir + ".jsonl"
    if not os.path.isfile(main_transcript):
        die(
            f"session {sid!r} has no main transcript at {main_transcript} -- "
            f"cannot verify it nominates PR #{pr}"
        )

    t0, t1, text = rl_mod._transcript_span_and_text(main_transcript)
    if t0 is None or t1 is None:
        die(
            f"session {sid!r}'s main transcript at {main_transcript} carries "
            f"no timestamps -- cannot verify merged_within_span"
        )

    if not nominates_pr(rl_mod, text, pr, repo):
        die(
            f"session {sid!r} never nominates PR #{pr} in its main transcript "
            f"({main_transcript}) -- a record filed under the wrong session "
            f"is worse than one filed under none"
        )

    merged_within_span = t0 <= merged_dt <= t1
    if source == "env" and not merged_within_span:
        die(
            f"session {sid!r} (from $CLAUDE_CODE_SESSION_ID) is not "
            f"merged_within_span for PR #{pr}: merged at "
            f"{fmt_iso(merged_dt)}, transcript spans "
            f"[{fmt_iso(t0)}, {fmt_iso(t1)}]"
        )

    session_block = {
        "id": sid,
        "source": source,
        "transcript": os.path.abspath(main_transcript),
        "nominates_pr": True,
        "merged_within_span": merged_within_span,
        "main_models": tally_models(main_transcript),
    }
    return session_block, session_dir, rr_mod


# ---------------------------------------------------------------------------
# ledger
# ---------------------------------------------------------------------------

def ledger_path_for(args):
    return os.path.expanduser(
        args.ledger or os.environ.get("CLAUDE_PR_LEDGER") or DEFAULT_LEDGER
    )


def write_ledger(ledger_path, repo, pr, record, replace):
    """Atomic rewrite (temp file + os.replace) whether appending a new
    record or swapping an existing one out under --replace -- one code
    path, so "other lines untouched" holds for both. REFUSEs (nothing
    written) if (repo, pr) is already present and --replace was not
    given."""
    parent = os.path.dirname(ledger_path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    existing_lines = []
    dup_index = None
    if os.path.exists(ledger_path):
        with open(ledger_path, encoding="utf-8") as f:
            for raw in f:
                stripped = raw.rstrip("\n")
                if not stripped.strip():
                    continue
                existing_lines.append(stripped)
                try:
                    obj = json.loads(stripped)
                except json.JSONDecodeError:
                    continue
                if (
                    isinstance(obj, dict)
                    and obj.get("kind") == "pr-record"
                    and obj.get("repo") == repo
                    and obj.get("pr") == pr
                ):
                    dup_index = len(existing_lines) - 1

    if dup_index is not None and not replace:
        die(
            f"{repo}#{pr} is already recorded in {ledger_path} -- pass "
            f"--replace to overwrite. Nothing written."
        )

    new_line = json.dumps(record, ensure_ascii=False)
    if dup_index is not None:
        existing_lines[dup_index] = new_line
        out_lines = existing_lines
    else:
        out_lines = existing_lines + [new_line]

    tmp = f"{ledger_path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            for ln in out_lines:
                f.write(ln + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, ledger_path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"could not write {ledger_path} ({e})")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="pr-record.py",
        description="One JSON-line record per merged PR: who did the work, at what tier, in how many rounds.",
    )
    p.add_argument("pr", type=int)
    p.add_argument("--repo", help="OWNER/NAME; defaults to `gh repo view`")
    p.add_argument("--session", help="session id; default $CLAUDE_CODE_SESSION_ID")
    p.add_argument(
        "--ledger",
        help=f"ledger path (default: $CLAUDE_PR_LEDGER, else {DEFAULT_LEDGER})",
    )
    p.add_argument("--replace", action="store_true", help="overwrite an existing (repo, pr) ledger entry")
    p.add_argument("--stdout", action="store_true", help="print the record; write nothing to the ledger")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    unknown = []

    repo = args.repo or current_repo()
    if not repo:
        die("no --repo given and `gh repo view` could not resolve one -- pass --repo OWNER/NAME")

    pr_data, err = fetch_pr(repo, args.pr)
    if pr_data is None:
        die(f"`gh pr view {args.pr} --repo {repo}` failed ({err}) -- no PR, no record")

    state = (pr_data.get("state") or "").upper()
    merged_at = pr_data.get("mergedAt")
    if state != "MERGED" or not merged_at:
        die(
            f"PR #{args.pr} in {repo} is not merged (state={state or 'UNKNOWN'}) "
            f"-- an unmerged PR REFUSES; nothing is written"
        )
    merged_dt = parse_iso(merged_at)

    head_ref = pr_data.get("headRefName")
    pr_meta = build_pr_meta(pr_data)
    commits = build_commits(pr_data)
    commit_oids = {c["oid"] for c in commits}
    ci_final = build_ci_final(pr_data)
    reviews_github = build_reviews_github(pr_data)

    filed_from_mod = load_filed_from()  # needed unconditionally: follow_ons is always attempted
    follow_ons = follow_ons_for(repo, args.pr, filed_from_mod, unknown)

    ci_runs, runs_failed = ci_runs_for(repo, head_ref, commit_oids, unknown)
    threads = review_threads_for(repo, args.pr, unknown)

    sid, source = resolve_session(args.session)
    session_block = None
    agents_public = None
    agents_unlinked = None
    review_rounds_agent = None
    rounds_missing = None
    findings = None

    if sid is not None:
        session_block, session_dir, rr_mod = build_session_block(sid, source, args.pr, repo, merged_dt)
        agents_raw, agents_unlinked = collect_agents(session_dir, args.pr, head_ref, rr_mod)
        review_rounds_agent, findings, rounds_missing = collect_rounds_and_findings(
            agents_raw, args.pr, rr_mod
        )
        agents_public = [public_agent(a) for a in agents_raw]

    record = {
        "kind": "pr-record",
        "schema_version": 1,
        "repo": repo,
        "pr": args.pr,
        "recorded_at": now_iso(),
        "pr_meta": pr_meta,
        "session": session_block,
        "commits": commits,
        "agents": agents_public,
        "agents_unlinked": agents_unlinked,
        "review_rounds": {
            "agent": review_rounds_agent,
            "rounds_missing": rounds_missing,
            "github": reviews_github,
            "threads": threads,
        },
        "findings": findings,
        "follow_ons": follow_ons,
        "ci": {
            "final": ci_final,
            "runs": ci_runs,
            "runs_failed": runs_failed,
        },
        "unknown": unknown,
    }

    exit_code = 2 if unknown else 0

    if args.stdout:
        print(json.dumps(record, indent=2, ensure_ascii=False))
        for u in unknown:
            print("warning: could not answer: " + u, file=sys.stderr)
        return exit_code

    ledger_path = ledger_path_for(args)
    write_ledger(ledger_path, repo, args.pr, record, args.replace)
    print(f"record: {os.path.abspath(ledger_path)} ({repo}#{args.pr})")
    for u in unknown:
        print("warning: could not answer: " + u, file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
