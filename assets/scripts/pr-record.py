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
  session          {id, source ("flag"|"env"), transcript,
                    merged_within_span, main_models} or null when no
                   session id was given and none was found in
                   $CLAUDE_CODE_SESSION_ID -- the whole agent half of the
                   record is null in that case (see SESSION VALIDATION).
                   There is deliberately no `nominates_pr` field: a session
                   that does not nominate this PR always REFUSES (see
                   below), so a present `session` block has always
                   nominated -- the field would be a hard-coded `true` on
                   every record that exists to read, i.e. a tautology.
  agents[]         {id, linked_by[], description, agent_type,
                    model_requested, models_observed, tier, started_at,
                    ended_at, usage} -- one per subagent LINKED to this PR
                   (see AGENT LINKAGE); null when session is null.
  agents_unlinked  count of subagents seen in the session but not linked to
                   this PR, INCLUDING one with a started_at that could not
                   be determined at all (see AGENT LINKAGE); null when
                   session is null.
  agents_after_merge  count of subagents that carried real linking evidence
                   (a matching result or brief) but started strictly AFTER
                   this PR's own merged_at, and are therefore excluded from
                   `agents[]` on the grounds that work starting after the
                   merge cannot be work ON the merge; null when session is
                   null. Disjoint from `agents_unlinked`: a given agent is
                   counted in exactly one of the three buckets (linked,
                   unlinked, after-merge).
  review_rounds    {agent[], rounds_missing, github[], threads} --
                   agent[] and rounds_missing are null when session is
                   null; github[] (from the PR view call's own `reviews`)
                   and threads (from a GraphQL reviewThreads call) do not
                   depend on session and are always attempted.
                   `rounds_missing` is an OBJECT keyed by skill name
                   (`{"agent-review": [1, 2]}`), not a flat list -- two
                   different skills reviewing the same PR keep independent
                   round sequences, and folding them into one list would
                   let one skill's complete history mask another's gaps.
  findings[]       every finding from every linked agent's review-result
                   document, tagged with its agent id and round; null when
                   session is null.
  follow_ons[]     filed-from.py's descendants(pr, repo, depth=1) -- null +
                   an unknown[] entry on a `?` (gh failure) node anywhere
                   in the walk.
  ci               {final[], runs[], runs_failed} -- final[] is read
                   straight off the PR view call's own statusCheckRollup
                   (both `CheckRun` and legacy `StatusContext` shapes, see
                   below); runs[] comes from `gh run list --branch
                   <head_ref>`, filtered down to runs whose headSha is one
                   of this PR's own commit oids; either half is null (with
                   an unknown[] entry) on a gh failure OR a run list
                   truncated at its own --limit -- a truncated list is
                   exactly as untrustworthy as a failed one (it may be
                   missing runs that would have changed `runs_failed`), so
                   it gets the same null treatment, never a confidently
                   partial list.
  unknown[]        every source above that could not be answered, in
                   prose -- never a silent null with no explanation.

SESSION VALIDATION (design call 1 of docs/pr-record-shape.md): a session id
is never searched for, only validated once given, by --session or
$CLAUDE_CODE_SESSION_ID (in that order; neither may contain `/` or `..` --
same discipline review-result.py's resolve_session_id applies, since a
session id is a directory NAME under ~/.claude/projects/*/, not a path).
Resolution is by MAIN TRANSCRIPT, not by session directory: exactly one
`~/.claude/projects/*/<sid>.jsonl` must exist (a REFUSE on zero or more
than one match) -- the sidecar DIRECTORY `~/.claude/projects/*/<sid>/` is
allowed to not exist at all, because a session that spawned no subagents
never creates one (measured on this machine: 404 of 590 transcripts have
no such directory). When the directory is absent, `agents` reads `[]` (a
real, confidently-known zero), never a REFUSE -- a REFUSE is reserved for
the transcript itself being unresolvable. That transcript must NOMINATE
this PR -- the same URL_RE/REF_RE/BARE_RE grammar usage-benchmark-row.py's
scan_work and rework-lag.py's --attribute use, imported from rework-lag.py
rather than re-implemented -- or the run REFUSES entirely (exit 2, nothing
written): a record filed under the wrong session is worse than one filed
under none. A session id sourced from $CLAUDE_CODE_SESSION_ID (source:
"env") additionally REFUSES unless the PR's own mergedAt falls inside the
transcript's own [first, last] timestamp span (merged_within_span) -- the
env var only proves which session is running, not that it was running when
the merge happened. A session id given with --session (source: "flag")
records merged_within_span but does not enforce it -- naming a session by
hand is a deliberate claim the caller is making. merged_within_span at the
SESSION level says nothing about any one AGENT's own timing, which is why
AGENT LINKAGE (below) checks it again, per agent.

AGENT LINKAGE (design call 2, hardened in round 2 of #270's review): an
agent belongs to this PR only with evidence, recorded in linked_by --
"result" and/or "brief":

  - "result": a sidecar `.result.json` whose own `pr` field equals this PR
    AND whose own `repo` field, if it is non-null, equals this repo -- a
    result recorded for the right PR number in a DIFFERENT repo is not
    evidence for this one. A `.result.json` that fails to parse as JSON,
    that parses but fails review-result.py's own validate_document, or
    that parses and validates but carries a null `pr`, can NEVER supply a
    "result" link (obviously -- there is no trustworthy `pr` to compare)
    -- but it is not silently ignored either: whenever the file's own raw
    text still contains this PR's number (or the file could not be parsed
    at all, so there is no number to rule it out with), an unknown[] entry
    names the file and the exit code goes to 2. The reasoning: a malformed
    result file that visibly claims to be about this PR is evidence an
    agent TRIED to record a review round that is now unreadable, and
    letting `rounds_missing` read as if that round never existed -- rather
    than as an unknown gap -- would be the exact silent-completeness bug
    this record exists to prevent.
  - "brief": the agent's first user-turn message names this PR by `#N`,
    `PR N`, or `pull/N` (each word-boundaried so `#2780` never matches
    `#278`), OR names the PR's own head branch -- also boundaried, on
    BOTH sides, against `[A-Za-z0-9_./-]`, so a branch called `fix` does
    not match inside "prefix" or "fixture".

  Neither the sidecar meta.json nor the transcript carries a PR number
  directly (gitBranch/cwd read HEAD/~ for every line), which is why both
  signals exist.

  TIMING gates linkage a third way, independent of either signal above: an
  agent with real evidence (linked_by non-empty) additionally needs a
  started_at that is <= this PR's own merged_at -- work that started after
  the PR merged cannot be work ON the PR, however its brief reads (a
  session's own transcript can go on mentioning an old PR number for
  unrelated reasons long after that PR shipped; reproduced on real data:
  backfilling PR #276 from the session that later reviewed THIS finding
  linked an agent that started at 02:42Z against a merge at 00:10Z). Such
  an agent is excluded from `agents[]` and counted in `agents_after_merge`
  instead of `agents_unlinked` -- it is not that no evidence was found, it
  is that the evidence is temporally impossible. An agent that has
  linking evidence but NO started_at at all (its transcript is empty, or
  entirely unparseable) cannot be placed in time either direction, so it
  does NOT link -- counted in `agents_unlinked`, with an unknown[] entry
  naming it, so this exclusion is visible rather than indistinguishable
  from an agent that simply had no evidence.

  A `.result.json` or transcript/meta.json that raises an OSError while
  being read (as opposed to one that is simply absent, which is normal and
  silent) always adds an unknown[] entry naming the file -- an unreadable
  file must never be indistinguishable from "this agent has no evidence",
  which is exactly what silently treating a read failure as "no data"
  would produce. A transcript line that parses as JSON but is not an
  object (a bare array, string, or number) is skipped for parsing purposes
  the same way rework-lag.py's `_transcript_span_and_text` skips one (that
  exact fix rides along in this round), but is ALSO named in an unknown[]
  entry once per agent, because a transcript containing lines shaped like
  that is a data-quality anomaly worth surfacing even though it did not
  prevent an answer this time.

REVIEW ROUNDS (design call 3): review-result.py's `record` command REFUSES
to overwrite an existing `.result.json` without --force, so only the
LATEST round an agent's result was recorded at ever survives on disk -- a
PR reviewed three times by the same agent shows one row with `round: 3`.
`rounds_missing` is computed PER SKILL (see THE RECORD, above): for each
skill that has at least one valid recorded round, every integer below its
own highest recorded round that has no row of its own is listed, so the
record never silently reads as "one round of review" when there were more,
and one skill's complete round history can never mask a gap in another's.

REUSE -- nothing here is re-implemented that a sibling already owns:
review-result.py's sidecar_dirs, find_sidecar_dir, validate_document
(sidecar walking, and the review-result schema check); filed-from.py's
descendants/_has_error (the `Filed from:` follow-on walk); rework-lag.py's
URL_RE/REF_RE/BARE_RE and _transcript_span_and_text (session nomination
AND, since round 2, every per-agent transcript span/text read too -- one
shared implementation of "read this JSONL transcript's timestamp span and
raw text, skipping any line that isn't a JSON object", not two); and
usage-pace.py's own `tier()` (and its "mythos prices as fable" alias) for
mapping an observed or requested model string to a family. `tier()` can
return `"other"` for a model string it does not recognize as any known
family -- that value is recorded as-is, not silently mapped to null: null
is reserved for "no model information at all" (neither an observed model
nor meta.json's own `model` field), which is a different fact from "a
model was named but it's not one of the four known families". Each
sibling is imported BY PATH -- the same importlib.util.spec_from_file_location
pattern rework-lag.py uses for filed-from.py -- with sys.dont_write_bytecode
toggled around the import so no stray __pycache__/ appears in the
checkout. Importing any of them this way only runs its module top level
(constants, regexes, function/class definitions); each one's own
`if __name__ == "__main__"` guard means its own `main()` -- and, for
rework-lag.py, its own internal filed-from.py dependency -- never runs. A
missing sibling REFUSES (exit 2, naming it): filed-from.py is needed
unconditionally (follow_ons is always attempted); review-result.py,
rework-lag.py and usage-pace.py are only needed, and only loaded, once a
session id is actually being validated.

LEDGER: one record per (repo, pr), one JSON object per line, default path
~/Obsidian/no-it-all/ledgers/pr-records.jsonl ($CLAUDE_PR_LEDGER, then
--ledger, each overriding the one before). The parent directory is created
if missing. The whole read-check-write is guarded by an exclusive
fcntl.flock on a sidecar `<ledger>.lock` file, so two invocations racing
against the same ledger serialize rather than one clobbering the other's
write. A brand new (repo, pr) is APPENDED as a single line under that
lock -- the file is never fully read into memory or rewritten just to add
one record. Writing a PR already present REFUSES (exit 2, nothing
written) unless --replace, which is the ONLY path that rewrites the file
at all (temp file + os.replace, still under the lock): every other line
survives exactly as found, including a blank one, the file's own
permission bits are restored on the replacement, and a ledger path that is
itself a symlink is written through to the file it resolves to rather than
being overwritten with a plain file (breaking the link). A line that fails
to parse as JSON but whose raw text still contains both this PR number and
this repo is treated as a POSSIBLE duplicate -- most likely a previous
write that was truncated or corrupted mid-write -- and REFUSEs exactly
like a confirmed one; only --replace may swap it out. (There is no claim
of exact byte-for-byte preservation of every untouched line's original
whitespace/newline convention -- only that its content is not touched,
lost, or reordered.) --stdout prints the record to stdout and does not
touch the ledger at all -- no duplicate check runs, because nothing is
written.

Exit codes:
  0   every requested source answered (unknown[] is empty) and the record
      was emitted (to stdout or the ledger).
  2   REFUSE -- no such PR, gh could not answer, the PR is not merged, a
      named session whose transcript does not resolve to exactly one
      match, one that does not nominate this PR, or (env-sourced only)
      falls outside merged_within_span, a session id containing `/` or
      `..`, a duplicate (confirmed or possible) ledger entry without
      --replace, or a missing required sibling script. Nothing is written
      in any REFUSE case.
      OR unknown[] is non-empty -- the record IS still emitted/written in
      this case, matching rework-lag.py's own contract: an incomplete
      answer is not a failure to produce output, only a reason the exit
      code says so.
"""
import argparse
import fcntl
import glob
import importlib.util
import json
import os
import re
import stat
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

# Best-effort recovery of `"pr": N` / `"round": N` out of a .result.json that
# failed to parse as JSON at all -- see AGENT LINKAGE. Never trusted for
# anything but deciding whether an unparseable file is worth naming in
# unknown[] (i.e. whether it MIGHT be about the PR this run is for).
_PR_TEXT_RE = re.compile(r'"pr"\s*:\s*(-?\d+)')
_ROUND_TEXT_RE = re.compile(r'"round"\s*:\s*(-?\d+)')


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


def _coerce_int(v):
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


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


def load_usage_pace():
    return _load_sibling("usage-pace.py", "pr_record_usage_pace")


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
    """statusCheckRollup entries come in two GitHub-native shapes: the
    modern Checks API (`__typename: "CheckRun"`, fields name/workflowName/
    conclusion) and the legacy commit-status API (`__typename:
    "StatusContext"`, fields context/state, no workflow at all). Both are
    mapped to the same {name, workflow, conclusion} shape here rather than
    silently dropping every StatusContext entry (which carried a real
    result and a real name, just under different field names)."""
    out = []
    for c in pr_data.get("statusCheckRollup") or []:
        if not isinstance(c, dict):
            continue
        typename = c.get("__typename")
        if typename == "StatusContext":
            out.append({
                "name": c.get("context"),
                "workflow": None,
                "conclusion": c.get("state"),
            })
        else:
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
        # A truncated list is exactly as untrustworthy as a failed one -- it
        # may be missing the very run that would have flipped runs_failed --
        # so it gets the SAME null treatment as a gh failure, never a
        # confidently partial list (S1 of #270's round-2 review).
        unknown.append(
            f"ci.runs possibly truncated (gh run list returned the full "
            f"--limit of {CI_RUN_LIMIT})"
        )
        return None, None
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
    "   reviewThreads(first: %d) {"
    "    totalCount"
    "    nodes { isResolved comments(first: 1) { nodes { author { login } } } }"
    "   }"
    "  }"
    " }"
    "}"
) % THREADS_PAGE


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


def tally_models_from_text(text):
    """{model: count} over every `assistant` line's message.model, reading
    from an already-loaded transcript TEXT blob (as returned by
    rework-lag.py's _transcript_span_and_text) rather than re-opening the
    file a second time."""
    counts = {}
    for line in text.splitlines():
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
    return counts


# ---------------------------------------------------------------------------
# agent brief / head_ref matching
# ---------------------------------------------------------------------------

_BOUNDARY_CHARS = r"A-Za-z0-9_./\-"


def brief_names_pr(text, pr, head_ref):
    """True if TEXT names PR number PR as `#N`, `PR N`, or `pull/N` (each
    word-boundaried so `#2780` never matches `#278`), or contains HEAD_REF
    bounded on BOTH sides against [A-Za-z0-9_./-] -- so a branch called
    `fix` never matches inside "prefix" or "fixture" (C3b of #270's round-2
    review: an unbounded substring test let exactly that happen)."""
    if not text:
        return False
    if re.search(r"(?<![\w/#])#%d\b" % pr, text):
        return True
    if re.search(r"\bPR\s+%d\b" % pr, text, re.IGNORECASE):
        return True
    if re.search(r"pull/%d\b" % pr, text):
        return True
    if head_ref:
        pattern = r"(?<![%s])%s(?![%s])" % (
            _BOUNDARY_CHARS, re.escape(head_ref), _BOUNDARY_CHARS
        )
        if re.search(pattern, text):
            return True
    return False


# ---------------------------------------------------------------------------
# agent transcript -- span/text via rework-lag.py's own reader (reused, not
# a second implementation), brief/models/usage parsed from that same text
# ---------------------------------------------------------------------------

def read_agent_transcript(jsonl_path, rl_mod):
    """One read of JSONL_PATH via rework-lag.py's own
    _transcript_span_and_text (reused for the span, per S4 of #270's round-2
    review, instead of a second hand-rolled span reader), with brief/
    models/usage all parsed from the SAME text blob it returns -- one file
    read, not four.

    Returns a dict:
      exists           False if the file is simply absent (normal, silent).
      ok                False if opening/reading it raised OSError.
      error             the OSError's message, when ok is False.
      started_at/ended_at   ISO strings, or None.
      brief             the first user-turn message's text, or None.
      models            {model: count} over assistant lines.
      usage             {input, output, cache_read, cache_creation} summed
                        over assistant lines, deduplicated by
                        (message.id, requestId) keeping the LAST record for
                        that pair (usage-pace.py's own key construction --
                        the first is always a partial, per #259).
      non_dict_lines    count of lines that parsed as JSON but were not a
                        JSON object (a bare array/string/number) -- these
                        are skipped for every purpose above, exactly as
                        rework-lag.py's own reader now skips them, but are
                        also counted here so the caller can flag the
                        anomaly (C2 of #270's round-2 review).
    """
    result = {
        "exists": False, "ok": True, "error": None,
        "started_at": None, "ended_at": None, "brief": None,
        "models": {}, "usage": None, "non_dict_lines": 0,
    }
    if not os.path.isfile(jsonl_path):
        return result
    result["exists"] = True

    try:
        t0, t1, text = rl_mod._transcript_span_and_text(jsonl_path)
    except OSError as e:
        result["ok"] = False
        result["error"] = str(e)
        return result

    result["started_at"] = fmt_iso(t0)
    result["ended_at"] = fmt_iso(t1)

    brief = None
    models = {}
    by_key = {}
    no_key = []
    non_dict_lines = 0

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue  # not valid JSON at all -- silently skipped, existing convention
        if not isinstance(obj, dict):
            non_dict_lines += 1
            continue

        if brief is None and obj.get("type") == "user":
            content = (obj.get("message") or {}).get("content")
            if isinstance(content, str):
                brief = content
            elif isinstance(content, list):
                parts = [
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                ]
                brief = "\n".join(p for p in parts if p) or None

        if obj.get("type") == "assistant":
            msg = obj.get("message") or {}
            model = msg.get("model")
            if model:
                models[model] = models.get(model, 0) + 1
            usage = msg.get("usage")
            if isinstance(usage, dict):
                key = (msg.get("id"), obj.get("requestId"))
                if key[0] or key[1]:
                    by_key[key] = usage  # last write wins
                else:
                    no_key.append(usage)

    totals = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}

    def add(u):
        totals["input"] += u.get("input_tokens") or 0
        totals["output"] += u.get("output_tokens") or 0
        totals["cache_read"] += u.get("cache_read_input_tokens") or 0
        totals["cache_creation"] += u.get("cache_creation_input_tokens") or 0

    for u in by_key.values():
        add(u)
    for u in no_key:
        add(u)

    result["brief"] = brief
    result["models"] = models
    result["usage"] = totals
    result["non_dict_lines"] = non_dict_lines
    return result


# ---------------------------------------------------------------------------
# agent meta.json
# ---------------------------------------------------------------------------

def read_agent_meta(meta_path):
    """(meta, error) -- meta is None and error is None when the file is
    simply absent (normal); meta is None and error is a message when it
    exists but could not be read/parsed (C2: this must never look the same
    as "absent")."""
    if not os.path.isfile(meta_path):
        return None, None
    try:
        with open(meta_path, encoding="utf-8") as f:
            return json.load(f), None
    except (OSError, json.JSONDecodeError) as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# agent result.json -- validated, with best-effort recovery for the
# unknown[]-worthiness check on a file that fails to parse or validate
# ---------------------------------------------------------------------------

def read_agent_result(result_path, rr_mod):
    """(doc, wrapper, problem, recovered_pr, recovered_round).

    doc/wrapper are non-None ONLY when the file parses as JSON, carries a
    `result` object, that object validates against review-result.py's own
    schema, AND its `pr` is non-null -- i.e. only when it is safe to use
    for linkage or for a review round. `problem` is None in that case and
    a short human-readable reason otherwise (unparseable JSON, no `result`
    object, fails validate_document, or `pr` is null).

    recovered_pr/recovered_round are BEST-EFFORT numbers pulled from the
    raw text with a regex when the file could not be parsed as JSON at
    all, or read directly from the (parsed but invalid) document
    otherwise -- used only to decide whether an unparseable/invalid file
    is worth naming in unknown[] (see AGENT LINKAGE): a malformed file
    whose recovered pr is unambiguously a DIFFERENT PR's is not this PR's
    problem to report, but one whose recovered pr matches (or could not be
    determined at all, so it cannot be ruled out) is.
    """
    if not os.path.isfile(result_path):
        return None, None, None, None, None

    try:
        with open(result_path, encoding="utf-8") as f:
            raw = f.read()
    except OSError as e:
        return None, None, f"unreadable ({e})", None, None

    try:
        wrapper = json.loads(raw)
    except json.JSONDecodeError as e:
        m_pr = _PR_TEXT_RE.search(raw)
        m_round = _ROUND_TEXT_RE.search(raw)
        return (
            None, None, f"is not valid JSON ({e})",
            int(m_pr.group(1)) if m_pr else None,
            int(m_round.group(1)) if m_round else None,
        )

    doc = wrapper.get("result") if isinstance(wrapper, dict) else None
    if not isinstance(doc, dict):
        return None, wrapper, "carries no `result` object", None, None

    errors = rr_mod.validate_document(doc)
    if errors:
        rnd = doc.get("round") if isinstance(doc.get("round"), int) and not isinstance(doc.get("round"), bool) else None
        return None, wrapper, f"fails review-result schema validation ({errors[0]})", _coerce_int(doc.get("pr")), rnd

    if doc.get("pr") is None:
        rnd = doc.get("round") if isinstance(doc.get("round"), int) and not isinstance(doc.get("round"), bool) else None
        return None, wrapper, "has a null `pr`", None, rnd

    rnd = doc.get("round") if isinstance(doc.get("round"), int) and not isinstance(doc.get("round"), bool) else None
    return doc, wrapper, None, doc.get("pr"), rnd


# ---------------------------------------------------------------------------
# agents[] / review_rounds.agent[] / findings[] / rounds_missing / counters
# ---------------------------------------------------------------------------

def enumerate_agent_names(session_dir, rr_mod):
    names = set()
    for d in rr_mod.sidecar_dirs(session_dir):
        for p in glob.glob(os.path.join(d, "agent-*.meta.json")):
            names.add(os.path.basename(p)[: -len(".meta.json")])
        for p in glob.glob(os.path.join(d, "agent-*.jsonl")):
            names.add(os.path.basename(p)[: -len(".jsonl")])
    return sorted(names)


def _tier_of(tier_fn, *models):
    for m in models:
        if m:
            return tier_fn(m)
    return None


def build_round_row(agent_id, doc, wrapper, result_path):
    counts = {"critical": 0, "suggestion": 0, "nitpick": 0}
    mutated = 0
    findings = []
    for f in doc.get("findings") or []:
        if not isinstance(f, dict):
            continue
        sev = f.get("severity")
        if sev in counts:
            counts[sev] += 1
        if f.get("mutation_ran") is True:
            mutated += 1
        findings.append({
            "agent": agent_id,
            "round": doc.get("round"),
            "severity": sev,
            "title": f.get("title"),
            "file": f.get("file"),
            "line": f.get("line"),
            "mutation_ran": f.get("mutation_ran"),
            "red_line": f.get("red_line"),
        })
    row = {
        "agent": agent_id,
        "skill": doc.get("skill"),
        "round": doc.get("round"),
        "verdict": doc.get("verdict"),
        "source": wrapper.get("source") if isinstance(wrapper, dict) else None,
        "critical": counts["critical"],
        "suggestion": counts["suggestion"],
        "nitpick": counts["nitpick"],
        "mutation_ran": mutated,
        "result_path": os.path.abspath(result_path) if result_path else None,
    }
    return row, findings


def collect_agents(session_dir, pr, repo, head_ref, merged_dt, rr_mod, rl_mod, tier_fn, unknown):
    """(agents, agents_unlinked, agents_after_merge, rounds, findings).

    agents carries the PUBLIC fields only (no result document attached) --
    see AGENT LINKAGE and REVIEW ROUNDS in the module docstring for the
    full rules. Every file-read failure and every malformed-but-plausibly-
    relevant result.json adds its own unknown[] entry rather than being
    folded silently into "no evidence found".
    """
    agents = []
    rounds = []
    findings = []
    unlinked = 0
    after_merge = 0

    for name in enumerate_agent_names(session_dir, rr_mod):
        sidecar_dir = rr_mod.find_sidecar_dir(session_dir, name)
        if sidecar_dir is None:
            continue
        meta_path = os.path.join(sidecar_dir, name + ".meta.json")
        jsonl_path = os.path.join(sidecar_dir, name + ".jsonl")
        result_path = os.path.join(sidecar_dir, name + ".result.json")

        meta, meta_err = read_agent_meta(meta_path)
        if meta_err is not None:
            unknown.append(f"agent {name} meta.json ({meta_path}) unreadable: {meta_err}")

        tinfo = read_agent_transcript(jsonl_path, rl_mod)
        if tinfo["exists"] and not tinfo["ok"]:
            unknown.append(f"agent {name} transcript ({jsonl_path}) unreadable: {tinfo['error']}")
        if tinfo["non_dict_lines"]:
            unknown.append(
                f"agent {name} transcript ({jsonl_path}) contains "
                f"{tinfo['non_dict_lines']} non-object JSON line(s), skipped"
            )

        doc, wrapper, problem, recovered_pr, recovered_round = read_agent_result(result_path, rr_mod)
        if problem is not None and (recovered_pr is None or recovered_pr == pr):
            round_note = f", round {recovered_round}" if recovered_round is not None else ""
            unknown.append(
                f"agent {name} result.json ({result_path}) {problem}{round_note} -- "
                f"a review round may be missing from this record"
            )

        result_link = (
            isinstance(doc, dict) and doc.get("pr") == pr
            and (doc.get("repo") is None or doc.get("repo") == repo)
        )
        brief_link = brief_names_pr(tinfo.get("brief"), pr, head_ref)

        linked_by = []
        if result_link:
            linked_by.append("result")
        if brief_link:
            linked_by.append("brief")

        if not linked_by:
            unlinked += 1
            continue

        started_at = tinfo.get("started_at")
        if started_at is None:
            unknown.append(
                f"agent {name} has linking evidence ({', '.join(linked_by)}) but no "
                f"started_at timestamp -- cannot verify it precedes the PR's merge, excluded"
            )
            unlinked += 1
            continue

        if parse_iso(started_at) > merged_dt:
            after_merge += 1
            continue

        models_observed = tinfo["models"]
        observed_model = max(models_observed, key=models_observed.get) if models_observed else None
        model_requested = (meta or {}).get("model")

        agents.append({
            "id": name,
            "linked_by": linked_by,
            "description": (meta or {}).get("description"),
            "agent_type": (meta or {}).get("agentType"),
            "model_requested": model_requested,
            "models_observed": models_observed,
            "tier": _tier_of(tier_fn, observed_model, model_requested),
            "started_at": started_at,
            "ended_at": tinfo.get("ended_at"),
            "usage": tinfo.get("usage"),
        })

        if result_link:
            row, doc_findings = build_round_row(name, doc, wrapper, result_path)
            rounds.append(row)
            findings.extend(doc_findings)

    rounds.sort(key=lambda r: (r["skill"] or "", r["round"] if r["round"] is not None else -1, r["agent"]))
    return agents, unlinked, after_merge, rounds, findings


def compute_rounds_missing(rounds):
    """{skill: [missing round ints]} -- computed independently per skill
    (see REVIEW ROUNDS in the module docstring), never as one flat list
    across every skill that reviewed this PR."""
    by_skill = {}
    for r in rounds:
        rnd = r.get("round")
        if isinstance(rnd, int) and not isinstance(rnd, bool):
            by_skill.setdefault(r.get("skill") or "unknown", []).append(rnd)
    out = {}
    for skill, nums in by_skill.items():
        mx = max(nums)
        out[skill] = sorted(set(range(1, mx)) - set(nums)) if mx > 0 else []
    return out


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


def resolve_session_transcript(sid):
    """The absolute path to ~/.claude/projects/*/<sid>.jsonl -- REFUSEs on
    zero or more than one match. Deliberately does NOT require the sidecar
    DIRECTORY ~/.claude/projects/*/<sid>/ to exist: a session that spawned
    no subagents never creates one at all (measured on this machine: 404 of
    590 transcripts have no such directory), and that must read as
    `agents: []`, not a REFUSE (S2 of #270's round-2 review)."""
    pattern = os.path.join(os.path.expanduser("~/.claude/projects"), "*", glob.escape(sid) + ".jsonl")
    matches = sorted(p for p in glob.glob(pattern) if os.path.isfile(p))
    if len(matches) != 1:
        die(
            f"main transcript for session {sid!r} is not exactly one match "
            f"under ~/.claude/projects/*/{sid}.jsonl (found {len(matches)}) "
            f"-- cannot resolve this session"
        )
    return matches[0]


def build_session_block(sid, source, pr, repo, merged_dt, rl_mod):
    """Returns (session_block, session_dir) or REFUSEs per the SESSION
    VALIDATION rules in this module's docstring. SESSION_DIR is derived
    from the transcript path and may not exist as an actual directory --
    every caller (sidecar_dirs et al.) already tolerates that."""
    main_transcript = resolve_session_transcript(sid)
    session_dir = main_transcript[: -len(".jsonl")]

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
        "merged_within_span": merged_within_span,
        "main_models": tally_models_from_text(text),
    }
    return session_block, session_dir


# ---------------------------------------------------------------------------
# ledger
# ---------------------------------------------------------------------------

def ledger_path_for(args):
    return os.path.expanduser(
        args.ledger or os.environ.get("CLAUDE_PR_LEDGER") or DEFAULT_LEDGER
    )


def _classify_ledger_line(line, repo, pr):
    """None (no match), "exact" (parses as a pr-record for this exact
    (repo, pr)), or "possible" (failed to parse as JSON at all, but its raw
    text still contains both this PR number and this repo -- most likely a
    previous write truncated or corrupted mid-write, per S3 of #270's
    round-2 review: never silently appended past without a human decision)."""
    stripped = line.strip()
    if not stripped:
        return None
    try:
        obj = json.loads(stripped)
    except json.JSONDecodeError:
        if (f'"pr": {pr}' in line or f'"pr":{pr}' in line) and repo in line:
            return "possible"
        return None
    if (
        isinstance(obj, dict)
        and obj.get("kind") == "pr-record"
        and obj.get("repo") == repo
        and obj.get("pr") == pr
    ):
        return "exact"
    return None


def _acquire_lock(lock_path):
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _release_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def write_ledger(ledger_path, repo, pr, record, replace):
    """See LEDGER in the module docstring for the full contract: locked
    read-check-write, append-only for a brand new (repo, pr), --replace as
    the only path that rewrites the file (preserving every other line,
    the file's mode, and following a symlink through to its target)."""
    real_path = os.path.realpath(ledger_path)
    parent = os.path.dirname(real_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    lock_path = real_path + ".lock"

    lock_fd = _acquire_lock(lock_path)
    try:
        # Every matching line, not just the first: a ledger that already
        # holds two lines for one (repo, pr) -- from a hand edit or a pre-lock
        # race -- must come out of --replace with exactly one, never with the
        # earlier duplicate silently left behind.
        dups = []
        if os.path.exists(real_path):
            with open(real_path, encoding="utf-8") as f:
                for i, raw in enumerate(f):
                    kind = _classify_ledger_line(raw.rstrip("\n"), repo, pr)
                    if kind is not None:
                        dups.append((i, kind))
        dup_index, dup_kind = dups[0] if dups else (None, None)

        if dup_index is not None and not replace:
            where = f"line {dup_index + 1}"
            if dup_kind == "possible":
                die(
                    f"{ledger_path} has an unparseable {where} that looks like it "
                    f"may already be a record for {repo}#{pr} -- pass --replace to "
                    f"overwrite it, or clean up the ledger by hand. Nothing written."
                )
            die(
                f"{repo}#{pr} is already recorded in {ledger_path} ({where}) -- "
                f"pass --replace to overwrite. Nothing written."
            )

        new_line = json.dumps(record, ensure_ascii=False)

        if dup_index is None:
            # APPEND ONLY: the common case never reads the rest of the file
            # into memory or rewrites anything it doesn't have to (C4 of
            # #270's round-2 review).
            try:
                with open(real_path, "a", encoding="utf-8") as f:
                    f.write(new_line + "\n")
                    f.flush()
                    os.fsync(f.fileno())
            except OSError as e:
                die(f"could not append to {real_path} ({e})")
            return

        # --replace on a confirmed or possible duplicate: the only path
        # that ever rewrites the file, and the only one that needs every
        # other line held in memory to preserve them (blank lines
        # included).
        with open(real_path, encoding="utf-8") as f:
            content = f.read()
        lines = content.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        lines[dup_index] = new_line
        extra = {i for i, _ in dups[1:]}
        if extra:
            print(f"warning: {ledger_path} held {len(dups)} lines for {repo}#{pr}; "
                  f"--replace kept one and removed lines "
                  f"{', '.join(str(i + 1) for i in sorted(extra))}", file=sys.stderr)
            lines = [ln for i, ln in enumerate(lines) if i not in extra]

        original_mode = None
        if os.path.exists(real_path):
            original_mode = os.stat(real_path).st_mode

        tmp = f"{real_path}.tmp.{os.getpid()}"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
                f.flush()
                os.fsync(f.fileno())
            if original_mode is not None:
                os.chmod(tmp, stat.S_IMODE(original_mode))
            os.replace(tmp, real_path)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            die(f"could not write {real_path} ({e})")
    finally:
        _release_lock(lock_fd)


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
    agents_after_merge = None
    review_rounds_agent = None
    rounds_missing = None
    findings = None

    if sid is not None:
        rl_mod = load_rework_lag()
        session_block, session_dir = build_session_block(sid, source, args.pr, repo, merged_dt, rl_mod)
        rr_mod = load_review_result()
        tier_fn = load_usage_pace().tier
        agents_public, agents_unlinked, agents_after_merge, review_rounds_agent, findings = collect_agents(
            session_dir, args.pr, repo, head_ref, merged_dt, rr_mod, rl_mod, tier_fn, unknown
        )
        rounds_missing = compute_rounds_missing(review_rounds_agent)

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
        "agents_after_merge": agents_after_merge,
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
