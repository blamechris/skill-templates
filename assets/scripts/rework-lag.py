#!/usr/bin/env python3
"""Measure the LAGGING signal for build item 5 of the session-evaluation plan
(#271, epic #266): did a merged PR get reworked later?

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/rework-lag.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/rework-lag.py --repo PATH --since ISO [--until ISO]
      [--windows 7,30] [--json] [--no-issues] [--attribute [LEDGER_PATH]] [--limit N]

THE PROBLEM: "a later PR touched the same file" overcounts rework by roughly
10x (measured 2026-09-20 on Aeolus: 10 of 16 PRs by that naive metric, 1 of 16
by the honest one — one line, #254 -> #264). Deliberate subsystem sequencing
looks exactly like churn under a file-level metric. This script asks the
honest, harder question instead: did a LATER merged PR remove or change LINES
this PR added, matched by content, per file, comments and trivial lines
excluded?

MATURITY — the rule that keeps this honest under repeated runs: a PR whose
merge is less than W days before `--until` has not had its W-day window
elapse yet. It is reported `immature` (unknown, not yet decidable), never
`clean` — "clean" is a claim about a window that has actually run out, and a
metric that cannot tell "no rework happened" from "not enough time has
passed to know" is not more honest than the file-touch metric it replaces.
`--until` exists so a result is reproducible after more PRs merge: run the
same `--since`/`--until` again later and the reported set does not move,
which is what makes an acceptance figure checkable. A FOURTH bucket,
`unreadable`, holds a PR whose diff `git show` could not produce at all (see
`unknown[]` for why) — it is disjoint from `clean` for the identical reason
`immature` is: a diff this script never saw cannot honestly be called "no
rework happened" either. `reworked` is checked before `unreadable`, which is
checked before the maturity split, in that priority order.

THE "all" WINDOW has no day cutoff, so by the same maturity logic its window
never elapses — there is always more future in which a PR could still be
reworked. Consequently `windows.all.clean` is always empty; every PR not
already reworked-as-of-`--until` sits in `windows.all.immature`. This is a
deliberate reading of the maturity rule, not an oversight: "all" trades a
concrete completion time for an unbounded one, and the honest price of an
unbounded window is that nothing under it is ever provably clean.

LINE MATCHING (from the prototype, unchanged, plus one extension): a line
counts only if, after stripping, it is longer than 12 characters and does not
start with `//`, `///`, `*`, or `#` (`#` is new here — a Python/shell comment
line was not excluded by the prototype, and shell/Python-heavy repos would
otherwise show comment churn as "rework"). Matching is per file: PR A's added
lines intersected with PR B's removed lines for the same path. CAVEAT: the
same two prefixes also drop lines that are not comments at all in some
languages — a Rust attribute (`#[derive(...)]`), a C/C++ preprocessor
directive (`#include`, `#ifdef`), and Swift's `#if`/`#endif` all start with
`#`, and are excluded from matching exactly like a real comment would be.
This is accepted, not fixed: language-aware parsing is out of scope for a
line-content heuristic, and treating these as "not content that churns"
errs toward under-counting rework, never toward the 10x overcount this
script exists to reject.

REVERTS are reported separately from `reworked` (in `reverts[]`, kind
`message` or `inversion`) but a revert pair, by construction, also removes
added lines and so is additionally present in the ordinary `reworked`/`pairs`
data — it is not double-counted (a Python set only ever holds a PR number
once), it is simply visible from both places, because both are true of it.

REOPENED ISSUES and FOLLOW-ON CLOSURE (both skippable with `--no-issues`) are
two more angles on the same lagging question — issues, not lines — and both
route the `Filed from:` grammar through `assets/scripts/filed-from.py`'s
`parse_filed_from` (imported by path from this script's own directory) rather
than re-implementing it; that grammar has already been hardened once (#274)
and a second copy would only drift from it. If the sibling module is not
found next to this script, running with issue measures requested is a REFUSE
(exit 2) — `--no-issues` sidesteps the whole question and works without it.

ATTRIBUTION (`--attribute [LEDGER]`, off by default) credits merged PRs back
to session ids using the same two-filter discipline
`usage-benchmark-row.py`'s `scan_work` uses (nomination from a transcript's
own raw text, adjudication from an authoritative source — here, this
script's own PR set and its own `[t0, t1]` derived from the transcript's
first/last `timestamp`, since the PR's merge fact is already established by
`gh pr list` and does not need re-adjudicating). The exact nomination
regexes are reused verbatim from `usage-benchmark-row.py` (bare `#N`,
`owner/repo#N`, and a `github.com/.../pull|issues/N` URL) — the transcript's
raw text is read only to search for these, never trusted for a number, a
state, or a timestamp, matching that script's own discipline. A qualified
nomination (`owner/repo#N` or the URL form) is only honored when its repo
equals the TARGET repo's own `nameWithOwner` (from `gh repo view`) — a
transcript naming `chroxy#264` must never nominate this repo's own #264. A
bare `#N` carries no repo and stays loose, exactly as `scan_work` treats it.

The rule for a ledger row is "never pick, never guess", applied without
exception: a session id whose 8-char prefix glob-matches more than one
transcript is never opened, a match with no `timestamp` fields at all yields
no window, and a row naming no transcript yields nothing either — none of
these can be tied to a PR by ANY means, including a proxy signal such as the
ledger row's own date column (an earlier version of this script did exactly
that, which is still a guess, just a quieter one). Every such row is instead
listed in the top-level `attribution_unresolved` array, by reason, so the
absence is visible rather than silently dropped. A PR credited by two
separate evaluable sessions keeps both in its `sessions` array — that is
real data, not an error.

WHAT `gh` FAILURE MEANS: identical discipline to `filed-from.py` and
`review-result.py` — a `gh`/`git` failure is reported and treated as
"unknown", never silently as "clean" or "zero". Failing to answer a specific
measure (a diff, a timeline call, an issue list) puts that measure's name in
`unknown[]`, prints a warning to stderr, and forces the overall exit code to
2 — but the JSON is still emitted with everything that COULD be answered.
Only a failure of the PR list itself is fatal (exit 2, no JSON at all): every
other measure is defined relative to that list, so a corrupted or partial
list cannot be silently built on.

JSON SHAPE (top-level; stable):
  {
    "since": ISO, "until": ISO, "repo": "owner/name" or null,
    "prs": N, "pr_numbers": [...],
    "windows": {
      "7":  {"reworked": [...], "clean": [...], "immature": [...],
             "unreadable": [...], "pairs": [...]},
      "30": {...}, "all": {...}
    },
    "reverts": [{"earlier": N, "later": N, "kind": "message"|"inversion"}, ...],
    "reopened_issues": [{"issue": N, "closed_by_pr": N, "reopened_at": ISO}, ...],
    "follow_ons": {"<pr>": {"open": [...], "closed": [...]}},
    "attribution": {"<pr>": {"sessions": [...]}},                      # only with --attribute
    "attribution_unresolved": [{"sid": ..., "reason": "multiple transcripts match"
                                 |"no transcript"|"no timestamps"}, ...],  # only with --attribute
    "unknown": ["<measure that gh/git could not answer>", ...]
  }
  A pair record is {"earlier": N, "later": N, "lines": N, "files": [...], "days": N}.

Exit codes: 0 every requested measure was answered; 2 the PR list failed (no
JSON emitted) OR at least one requested measure could not be answered (JSON
is still emitted, with that measure's name in `unknown[]`) OR a REFUSE (bad
`--repo`, missing `filed-from.py` sibling when an issue measure is needed).
"""
import argparse
import collections
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

GH_TIMEOUT = 30
GIT_TIMEOUT = 30
TRIVIAL_LEN = 12
COMMENT_PREFIXES = ("//", "///", "*", "#")
DEFAULT_LEDGER = "~/Obsidian/no-it-all/briefs/usage-benchmark.md"

REVERT_MSG_RE = re.compile(r"This reverts commit ([0-9a-fA-F]{7,40})")

# Reused verbatim from usage-benchmark-row.py's scan_work — the same
# nomination grammar, so a PR mentioned the same way in either script is
# recognized the same way. Not re-derived; copied on purpose, because these
# are data patterns (what a person types), not logic that can drift out of
# sync with a shared implementation the way filed-from's grammar can.
URL_RE = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+)")
REF_RE = re.compile(r"\b([\w.-]+/[\w.-]+)#(\d+)\b")
BARE_RE = re.compile(r"(?<![\w/#])#(\d+)\b")


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
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# gh / git plumbing
# ---------------------------------------------------------------------------

def _run(args, cwd, timeout):
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 1, "", f"{args[0]}: command not found"
    except subprocess.TimeoutExpired:
        return 1, "", f"{args[0]}: timed out after {timeout}s"
    except OSError as e:
        return 1, "", f"{args[0]}: {e}"


def gh_json(args, cwd):
    rc, out, err = _run(["gh"] + args, cwd, GH_TIMEOUT)
    if rc != 0:
        return None, err.strip() or f"gh exited {rc}"
    try:
        return json.loads(out), None
    except ValueError as e:
        return None, f"gh returned non-JSON output: {e}"


def current_repo(cwd):
    rc, out, _ = _run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                       cwd, GH_TIMEOUT)
    out = out.strip()
    return out if rc == 0 and out else None


def _git_show_diff(sha, cwd):
    """Run `git show` in a way that always produces a real diff, including for
    a TRUE (multi-parent) merge commit. Without `--diff-merges`, git's default
    for a merge is `--cc` (compact combined), which comes back EMPTY the
    instant a merge introduces no conflict against either parent — verified
    against skill-templates' own history (f91113c, 7d2c161, dc7be1d): 0 files,
    0 lines, exit 0, no error. Squash-merging (Aeolus, the acceptance repo)
    never hits this, which is the only reason it was not caught earlier; a
    repo using "Create a merge commit" would silently read every PR as clean.
    `--diff-merges=first-parent` asks for the diff against the merge's first
    parent instead — the same "what did this PR change" reading a squash
    merge gives for free. `-m --first-parent` is the fallback for a git old
    enough not to support the `first-parent` value (this script's own CI and
    author machine both support it; the fallback exists for whatever else
    bootstraps this copy). Neither flag affects an ordinary single-parent
    commit's diff at all — verified empirically, not assumed."""
    primary = ["git", "show", "--diff-merges=first-parent", "--format=",
               "--unified=0", "--no-color", sha]
    rc, out, err = _run(primary, cwd, GIT_TIMEOUT)
    if rc == 0:
        return rc, out, err
    fallback = ["git", "show", "-m", "--first-parent", "--format=",
                "--unified=0", "--no-color", sha]
    rc2, out2, err2 = _run(fallback, cwd, GIT_TIMEOUT)
    if rc2 == 0:
        return rc2, out2, err2
    return rc, out, err  # report the primary attempt's error, not the fallback's


_OCTAL_ESCAPE_RE = re.compile(r"\\([0-7]{1,3})")
_SIMPLE_ESCAPES = {"n": "\n", "t": "\t", "a": "\a", "b": "\b", "f": "\f",
                   "r": "\r", "v": "\v", "\\": "\\", '"': '"'}


def _unquote_diff_path(rest):
    """git quotes a `--- `/`+++ ` path in double quotes and C-escapes it
    (octal per byte, e.g. `\\303\\237`) the instant it contains a non-ASCII
    or otherwise "unsafe" byte -- the default (`core.quotePath=true`), not an
    opt-in. Unquoted, neither the `a/` nor `b/` prefix test below matches a
    quoted string at all, so the ENTIRE quoted text becomes the path, and an
    add/remove pair on the same non-ASCII file ends up keyed under two
    different (both wrong) strings. Strip the quotes and reverse the escaping
    (octal bytes re-assembled and decoded as UTF-8) before the prefix test
    ever sees the path."""
    if len(rest) < 2 or rest[0] != '"' or rest[-1] != '"':
        return rest
    inner = rest[1:-1]
    out = bytearray()
    i = 0
    while i < len(inner):
        c = inner[i]
        if c == "\\" and i + 1 < len(inner):
            m = _OCTAL_ESCAPE_RE.match(inner, i)
            if m:
                out.append(int(m.group(1), 8) & 0xFF)
                i = m.end()
                continue
            nxt = inner[i + 1]
            if nxt in _SIMPLE_ESCAPES:
                out.extend(_SIMPLE_ESCAPES[nxt].encode())
                i += 2
                continue
            out.extend(nxt.encode("utf-8", errors="replace"))
            i += 2
            continue
        out.extend(c.encode("utf-8"))
        i += 1
    return out.decode("utf-8", errors="replace")


def _diff_path(rest, prefix):
    rest = _unquote_diff_path(rest)
    if rest == "/dev/null":
        return None
    return rest[2:] if rest.startswith(prefix) else rest


def hunks_for(sha, cwd, cache):
    """Per-file (added, removed) non-trivial line sets for one PR's diff,
    cached by sha — one `git show` per PR no matter how many pairs it is
    compared against.

    The parser tracks the REMOVE path and the ADD path independently (from
    `--- ` and `+++ ` respectively), reset at each `diff --git` boundary,
    rather than a single "current file" updated only on `+++ b/...`. That
    single-variable version silently dropped a deleted file's removed lines
    entirely (`+++ /dev/null` never matched `+++ b/`, so the tracked file
    never changed) or — worse — kept crediting them to whatever file the
    PREVIOUS diff block in the same commit happened to be, which can
    manufacture a false rework pair against an unrelated file. Two independent
    paths also means a rename (`--- a/old` + `+++ b/new`) keys removed lines
    to the OLD path and added lines to the NEW path, so rework across a
    rename is visible instead of silently lost. `\\ No newline at end of
    file` and a binary-file notice are metadata, not content, and are
    ignored.

    `--- `/`+++ ` are recognized as HEADER lines only before the first `@@`
    seen since the last `diff --git` line — git emits the pair exactly once,
    in the block's preamble, never again once hunks start. A bare
    `line.startswith("--- ")` with no such gate cannot tell that header apart
    from a REMOVED content line whose own text happens to start with `-- `
    (a SQL/Lua/Haskell/Ada/Elm comment, or ordinary prose): once the diff's
    leading `-` is added, `-- a sql comment` reads as `--- a sql comment`,
    which matched the header test byte-for-byte and silently overwrote
    `cur_remove` with a bogus "path" built from the comment's own text —
    stealing every REAL removed line that followed it in the same hunk. The
    mirror case is an ADDED line starting with `++ ` reading as `+++ ` once
    diffed. Once `in_hunk` is true, neither `-` nor `+` is ever read as a
    header again until the next `diff --git` resets it."""
    if sha in cache:
        return cache[sha]
    rc, out, err = _git_show_diff(sha, cwd)
    if rc != 0:
        result = ({}, err.strip() or f"git exited {rc}")
        cache[sha] = result
        return result
    hunks = collections.defaultdict(lambda: (set(), set()))
    cur_add, cur_remove = None, None
    in_hunk = False
    for line in out.splitlines():
        if line.startswith("diff --git "):
            cur_add, cur_remove = None, None
            in_hunk = False
            continue
        if line.startswith("@@"):
            in_hunk = True
            continue
        if not in_hunk and line.startswith("--- "):
            cur_remove = _diff_path(line[4:], "a/")
            continue
        if not in_hunk and line.startswith("+++ "):
            cur_add = _diff_path(line[4:], "b/")
            continue
        if line.startswith("\\ No newline at end of file"):
            continue
        if line.startswith("Binary files "):
            continue
        if line.startswith("+"):
            if cur_add is None:
                continue
            s = line[1:].strip()
            if len(s) > TRIVIAL_LEN and not s.startswith(COMMENT_PREFIXES):
                hunks[cur_add][0].add(s)
        elif line.startswith("-"):
            if cur_remove is None:
                continue
            s = line[1:].strip()
            if len(s) > TRIVIAL_LEN and not s.startswith(COMMENT_PREFIXES):
                hunks[cur_remove][1].add(s)
    result = (dict(hunks), None)
    cache[sha] = result
    return result


def commit_message(sha, cwd, cache):
    if sha in cache:
        return cache[sha]
    rc, out, err = _run(["git", "log", "-1", "--format=%B", sha], cwd, GIT_TIMEOUT)
    result = (out, None) if rc == 0 else (None, err.strip() or f"git exited {rc}")
    cache[sha] = result
    return result


# ---------------------------------------------------------------------------
# filed-from.py reuse
# ---------------------------------------------------------------------------

def load_parse_filed_from():
    sib = Path(__file__).resolve().parent / "filed-from.py"
    if not sib.exists():
        die(
            "sibling assets/scripts/filed-from.py is missing. rework-lag.py "
            "reuses its parse_filed_from() for the `Filed from:` grammar "
            "rather than re-implementing it, and refuses to run an issue "
            f"measure without it (expected at {sib}). Pass --no-issues to "
            "skip both issue measures and run without the sibling."
        )
    # Importing a sibling script by path would otherwise leave a stray
    # assets/scripts/__pycache__/ in the checkout every time this runs --
    # disabled for this one load, restored immediately after.
    prev = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("rework_lag_filed_from", str(sib))
        if spec is None or spec.loader is None:
            die(f"sibling {sib} exists but importlib could not build a loader for it")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = prev
    return mod.parse_filed_from


# ---------------------------------------------------------------------------
# rework pairs + reverts
# ---------------------------------------------------------------------------

def compute_pairs_and_reverts(prs, repo_dir, hunk_cache, msg_cache, unknown):
    H = {}
    unreadable = set()
    for p in prs:
        hunks, err = hunks_for(p["sha"], repo_dir, hunk_cache)
        if err:
            unknown.append(f"diff for #{p['number']} ({err})")
            unreadable.add(p["number"])
        H[p["number"]] = hunks

    all_pairs = []
    reverts = []
    for i, a in enumerate(prs):
        for b in prs[i + 1:]:
            Ha = H.get(a["number"], {})
            Hb = H.get(b["number"], {})
            n = 0
            files = set()
            for f, (added, _removed) in Ha.items():
                if f in Hb:
                    hit = added & Hb[f][1]
                    if hit:
                        n += len(hit)
                        files.add(f)
            if n:
                delta = b["mergedAt_dt"] - a["mergedAt_dt"]
                all_pairs.append({
                    "earlier": a["number"], "later": b["number"],
                    "lines": n, "files": sorted(files),
                    "days": delta.days, "_delta": delta,
                })
            kind = _detect_revert(a, b, Ha, Hb, repo_dir, msg_cache)
            if kind:
                reverts.append({"earlier": a["number"], "later": b["number"], "kind": kind})
    return all_pairs, reverts, unreadable


def _detect_revert(a, b, Ha, Hb, repo_dir, msg_cache):
    # (a) message-based: a "This reverts commit <sha>" trailer prefix-matching
    # the earlier PR's merge commit, or a title starting "Revert" that names
    # the earlier PR's number somewhere in its title/body/commit message.
    msg_b, _err = commit_message(b["sha"], repo_dir, msg_cache)
    msg_b = msg_b or ""
    m = REVERT_MSG_RE.search(msg_b)
    if m:
        sha = m.group(1).lower()
        a_sha = a["sha"].lower()
        if a_sha.startswith(sha) or sha.startswith(a_sha):
            return "message"
    title_b = b.get("title") or ""
    if title_b.startswith("Revert"):
        # A word-boundary match, exactly like BARE_RE's own grammar for a
        # bare `#N` -- a plain `ref in haystack` substring test would let
        # "#12" match inside "#123", crediting PR #12 with a revert that
        # actually named a different PR entirely.
        ref_re = re.compile(rf"(?<![\w/#])#{a['number']}\b")
        haystack = title_b + "\n" + (b.get("body") or "") + "\n" + msg_b
        if ref_re.search(haystack):
            return "message"

    # (b) full inversion: EQUALITY, not subset. A revert is a diff that is the
    # inverse of the earlier one, no more — a large later PR that happens to
    # delete the earlier PR's whole addition among 500 other lines is not a
    # revert, it is the same overcount class this script exists to reject.
    # Over the union of files touched by EITHER PR (so an extra file the
    # later PR also touches, with no earlier-PR counterpart, breaks the
    # match instead of being silently ignored): removed_b must equal added_a
    # and added_b must equal removed_a, exactly, for every file. A partial
    # undo, or a revert plus one unrelated extra change anywhere, fails this
    # and is rework only, not a revert.
    if not Ha:
        return None
    total = 0
    for f in set(Ha) | set(Hb):
        added_a, removed_a = Ha.get(f, (set(), set()))
        added_b, removed_b = Hb.get(f, (set(), set()))
        if removed_b != added_a:
            return None
        if added_b != removed_a:
            return None
        total += len(added_a) + len(removed_a)
    if total == 0:
        return None
    return "inversion"


def window_result(prs, all_pairs, window_days, until_dt, unreadable):
    """The four buckets are disjoint by construction and MUST stay that way:
    `reworked` is checked first (a settled positive fact overrides everything
    else), then `unreadable` (a PR whose diff could not be read can never be
    honestly called `clean` — that is a claim about content this script never
    saw), and only then does the maturity check split the remainder into
    `clean`/`immature`. An unreadable PR can never actually land in
    `reworked` either: its own hunks are `{}` (nothing to match as `earlier`),
    and it can supply no removed lines to match anyone else's `added` set
    (nothing to match as `later`) — but the bucket is still checked in this
    order so that fact does not have to be re-proven here."""
    pairs = []
    reworked = set()
    for pr in all_pairs:
        if window_days is None or pr["_delta"] <= timedelta(days=window_days):
            reworked.add(pr["earlier"])
            pairs.append({k: v for k, v in pr.items() if not k.startswith("_")})
    clean, immature, unreadable_out = [], [], []
    for p in prs:
        num = p["number"]
        if num in reworked:
            continue
        if num in unreadable:
            unreadable_out.append(num)
            continue
        elapsed = window_days is not None and (until_dt - p["mergedAt_dt"]) >= timedelta(days=window_days)
        (clean if elapsed else immature).append(num)
    return {
        "reworked": sorted(reworked),
        "clean": sorted(clean),
        "immature": sorted(immature),
        "unreadable": sorted(unreadable_out),
        "pairs": pairs,
    }


# ---------------------------------------------------------------------------
# issue measures
# ---------------------------------------------------------------------------

def reopened_issues(prs, owner_repo, repo_dir, until_dt, unknown):
    out = []
    seen = set()  # (issue, closed_by_pr) -- report each pairing once, not once per reopen event
    for p in prs:
        data, err = gh_json(["pr", "view", str(p["number"]), "--json", "closingIssuesReferences"], repo_dir)
        if data is None:
            unknown.append(f"closingIssuesReferences for #{p['number']} ({err})")
            continue
        for ref in data.get("closingIssuesReferences") or []:
            n = ref.get("number")
            if n is None:
                continue
            tdata, terr = gh_json(["api", f"repos/{owner_repo}/issues/{n}/timeline", "--paginate"], repo_dir)
            if tdata is None:
                unknown.append(f"timeline for issue #{n} ({terr})")
                continue
            for ev in tdata:
                if ev.get("event") != "reopened":
                    continue
                created_at = ev.get("created_at")
                if not created_at:
                    continue
                key = (n, p["number"])
                if key in seen:
                    continue
                try:
                    reopened_dt = parse_iso(created_at)
                except ValueError:
                    continue
                # Bounded on both sides, same as the PR set itself: reopened
                # AFTER this PR's own merge (otherwise it is not this PR's
                # doing) and NOT AFTER --until (otherwise the answer changes
                # under the same --since/--until the next time this runs,
                # which is exactly what --until exists to prevent).
                if p["mergedAt_dt"] < reopened_dt <= until_dt:
                    seen.add(key)
                    out.append({"issue": n, "closed_by_pr": p["number"], "reopened_at": created_at})
    return out


FOLLOWON_LIST_LIMIT = 500


def follow_on_closure(pr_numbers, since_dt, until_dt, repo_dir, parse_filed_from, unknown):
    data, err = gh_json(
        ["issue", "list", "--state", "all", "--limit", str(FOLLOWON_LIST_LIMIT),
         "--json", "number,state,body,createdAt,closedAt"],
        repo_dir,
    )
    if data is None:
        unknown.append(f"issue list for follow-ons ({err})")
        return {}
    if len(data) >= FOLLOWON_LIST_LIMIT:
        unknown.append(
            f"follow-ons possibly truncated (gh issue list returned the full "
            f"--limit of {FOLLOWON_LIST_LIMIT})"
        )
    pr_set = set(pr_numbers)
    out = {}
    for issue in data:
        created = issue.get("createdAt")
        if not created:
            continue
        try:
            created_dt = parse_iso(created)
        except ValueError:
            continue
        # Bounded on both sides, like the PR set: an issue filed after
        # --until could not have been known about at that time, so excluding
        # it is what makes a --since/--until pair reproducible later.
        if not (since_dt < created_dt <= until_dt):
            continue
        parsed = parse_filed_from(issue.get("body") or "")
        if not parsed or parsed.get("form") != "ref":
            continue
        src = parsed["number"]
        if src not in pr_set:
            continue
        bucket = out.setdefault(str(src), {"open": [], "closed": []})
        state = (issue.get("state") or "").upper()
        # gh reports the issue's CURRENT state, not its state as of --until.
        # An issue closed after --until (or one gh reports CLOSED with no
        # closedAt at all, which should not happen but is not trusted blindly
        # either) is reported open — reproducibility means "as of --until",
        # and this script cannot honestly claim to know a closure it cannot
        # timestamp within the window.
        closed_at = issue.get("closedAt")
        closed_by_until = False
        if state == "CLOSED" and closed_at:
            try:
                closed_by_until = parse_iso(closed_at) <= until_dt
            except ValueError:
                closed_by_until = False
        bucket["closed" if closed_by_until else "open"].append(issue["number"])
    return out


# ---------------------------------------------------------------------------
# attribution
# ---------------------------------------------------------------------------

def parse_ledger_sessions(ledger_path):
    """['<8+ hex chars>', ...] -- the candidate session ids from the ledger's
    markdown table. The session-id column is whichever one sits immediately
    after the column whose header names 'date' — read from the table, never
    assumed to be a fixed index, since a ledger schema change should not
    silently misattribute a whole column."""
    text = Path(ledger_path).read_text(encoding="utf-8")
    rows = [ln for ln in text.splitlines() if ln.strip().startswith("|")]
    if not rows:
        return []
    header = [c.strip() for c in rows[0].strip().strip("|").split("|")]
    date_idx = next((i for i, c in enumerate(header) if "date" in c.lower()), None)
    if date_idx is None:
        return []
    sid_idx = date_idx + 1
    out = []
    for ln in rows[1:]:
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if len(cells) <= sid_idx:
            continue
        if cells[0] and set(cells[0]) <= set("-: "):
            continue  # the `|---|---|` separator row
        sid = cells[sid_idx]
        if not re.match(r"^[0-9a-fA-F][0-9a-fA-F-]{7,}$", sid):  # 8+ hex/dash chars, matching the docstring
            continue
        out.append(sid)
    return out


def _transcript_span_and_text(path):
    t0 = t1 = None
    chunks = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            chunks.append(line)
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue  # a bare JSON array/number/string line has no .get -- skip it, don't crash
            ts = rec.get("timestamp")
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
    return t0, t1, "".join(chunks)


def compute_attribution(prs, ledger_path, target_repo, unknown):
    """Returns (attribution, unresolved). `attribution` is {"<pr>": {"sessions":
    [...]}}. `unresolved` lists every ledger session id that could not be
    evaluated at all -- "never pick, never guess" means an ambiguous glob is
    never opened and therefore can never be tied to a PR by any means,
    including a proxy like the ledger's own date column; it is reported
    plainly instead."""
    home = os.environ.get("HOME") or os.path.expanduser("~")
    ledger_path = os.path.expanduser(ledger_path)
    try:
        rows = parse_ledger_sessions(ledger_path)
    except OSError as e:
        unknown.append(f"attribution ledger unreadable ({e})")
        return {}, []

    out = {}
    unresolved = []
    for sid in rows:
        pattern = os.path.join(home, ".claude", "projects", "*", sid + "*.jsonl")
        hits = glob.glob(pattern)
        if len(hits) > 1:
            # More than one transcript matches this session id's prefix.
            # Opening either would be a guess, so neither is opened, and this
            # sid cannot be tied to any PR by any means -- reported plainly
            # rather than associated by a proxy signal (the earlier ledger-date
            # heuristic was itself a guess, just a quieter one).
            unresolved.append({"sid": sid, "reason": "multiple transcripts match"})
            continue
        if not hits:
            unresolved.append({"sid": sid, "reason": "no transcript"})
            continue
        t0, t1, text = _transcript_span_and_text(hits[0])
        if t0 is None or t1 is None:
            unresolved.append({"sid": sid, "reason": "no timestamps"})
            continue
        # Qualified nominations (owner/repo#N, or a github.com/.../pull|issues/N
        # URL) are matched against the TARGET repo's own nameWithOwner -- a
        # transcript naming chroxy#264 must not nominate this repo's #264.
        # A bare `#N` carries no repo and stays loose, same as scan_work.
        qualified = set()
        bare = set()
        if target_repo:
            for rgx in (URL_RE, REF_RE):
                for mo in rgx.finditer(text):
                    if mo.group(1) == target_repo:
                        qualified.add(int(mo.group(2)))
        for mo in BARE_RE.finditer(text):
            bare.add(int(mo.group(1)))
        nominated = qualified | bare
        for p in prs:
            num = p["number"]
            if num not in nominated:
                continue
            if t0 <= p["mergedAt_dt"] <= t1:
                bucket = out.setdefault(str(num), {"sessions": []})
                if sid not in bucket["sessions"]:
                    bucket["sessions"].append(sid)
    return out, unresolved


# ---------------------------------------------------------------------------
# human output
# ---------------------------------------------------------------------------

def format_human(result, window_labels, issues_requested=True):
    lines = []
    for w in window_labels:
        wd = result["windows"][w]
        label = "all" if w == "all" else f"+{w}d"
        # `unreadable` is never folded into `clean` -- a PR whose diff could
        # not be read is not a claim of "no rework happened", it is a claim
        # this script never checked, and the two must never print the same.
        lines.append(f"{label}: {len(wd['reworked'])} reworked / {len(wd['clean'])} clean / "
                      f"{len(wd['immature'])} immature / {len(wd['unreadable'])} unreadable "
                      f"(of {result['prs']})")

    unk = result["unknown"]
    lines.append("")
    if result["reverts"]:
        lines.append("reverts:")
        for r in result["reverts"]:
            lines.append(f"  #{r['earlier']} -> #{r['later']} ({r['kind']})")
    else:
        lines.append("reverts: none")

    # A "repo resolution" failure also fires with --attribute alone (no issue
    # measure requested at all) -- `issues_requested` (false under
    # --no-issues) keeps that from printing "reopened issues: UNKNOWN" for a
    # measure that was never asked for; under --no-issues both sections
    # print "(skipped, --no-issues)" -- a measure never run must not read
    # like a measured zero -- and must not flip to a misleading "UNKNOWN"
    # just because some OTHER measure's repo lookup failed.
    reopened_unknown = issues_requested and any(
        u.startswith("closingIssuesReferences") or u.startswith("timeline for issue")
        or u.startswith("repo resolution")
        for u in unk
    )
    followon_unknown = issues_requested and any(
        u.startswith("issue list for follow-ons") or u.startswith("follow-ons possibly truncated")
        for u in unk
    )

    lines.append("")
    if reopened_unknown:
        lines.append("reopened issues: UNKNOWN (gh failure)")
    elif result["reopened_issues"]:
        lines.append("reopened issues:")
        for r in result["reopened_issues"]:
            lines.append(f"  #{r['issue']} reopened {r['reopened_at']} (closed by #{r['closed_by_pr']})")
    elif not issues_requested:
        lines.append("reopened issues: (skipped, --no-issues)")
    else:
        lines.append("reopened issues: none")

    lines.append("")
    if followon_unknown and not result["follow_ons"]:
        lines.append("follow-ons: UNKNOWN (gh failure)")
    elif result["follow_ons"]:
        lines.append("follow-ons:")
        for pr, buckets in result["follow_ons"].items():
            lines.append(f"  #{pr}: open={buckets['open']} closed={buckets['closed']}")
    elif not issues_requested:
        lines.append("follow-ons: (skipped, --no-issues)")
    else:
        lines.append("follow-ons: none")

    if "attribution" in result:
        lines.append("")
        attribution = result["attribution"]
        if attribution:
            lines.append("attribution:")
            for pr, bucket in attribution.items():
                lines.append(f"  #{pr}: sessions={bucket['sessions']}")
        else:
            lines.append("attribution: none")
        unresolved = result.get("attribution_unresolved") or []
        if unresolved:
            lines.append(
                "attribution unresolved: "
                + ", ".join(f"{u['sid']} ({u['reason']})" for u in unresolved)
            )
        else:
            lines.append("attribution unresolved: none")

    if unk:
        lines.append("")
        lines.append("UNKNOWN: " + "; ".join(unk))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="rework-lag.py",
        description="The lagging signal: did a merged PR get reworked later, honestly measured.",
    )
    p.add_argument("--repo", default=".", help="git checkout to run gh/git in (default: cwd)")
    p.add_argument("--since", required=True, help="ISO timestamp; PR set is since < mergedAt <= until")
    p.add_argument("--until", default=None, help="ISO timestamp (default: now, UTC)")
    p.add_argument("--windows", default="7,30", help="comma-separated day windows (default: 7,30)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-issues", dest="no_issues", action="store_true",
                    help="skip reopened-issue and follow-on-closure measures")
    p.add_argument("--attribute", nargs="?", const=DEFAULT_LEDGER, default=None,
                    metavar="LEDGER_PATH", help=f"credit PRs to sessions (default ledger: {DEFAULT_LEDGER})")
    p.add_argument("--limit", type=int, default=200, help="gh pr list limit (default: 200)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    repo_dir = os.path.abspath(os.path.expanduser(args.repo))
    if not os.path.isdir(repo_dir):
        die(f"--repo {repo_dir} does not exist")
    rc, _out, _err = _run(["git", "rev-parse", "--is-inside-work-tree"], repo_dir, GIT_TIMEOUT)
    if rc != 0:
        die(f"--repo {repo_dir} is not a git checkout")

    try:
        since_dt = parse_iso(args.since)
    except ValueError as e:
        die(f"--since {args.since!r} is not a valid ISO timestamp ({e})")
    if args.until:
        try:
            until_dt = parse_iso(args.until)
        except ValueError as e:
            die(f"--until {args.until!r} is not a valid ISO timestamp ({e})")
    else:
        until_dt = datetime.now(timezone.utc)

    try:
        window_days = [int(w.strip()) for w in args.windows.split(",") if w.strip()]
    except ValueError:
        die(f"--windows {args.windows!r} must be a comma-separated list of integers")

    unknown = []

    prs_raw, err = gh_json(
        ["pr", "list", "--state", "merged", "--limit", str(args.limit),
         "--json", "number,title,mergedAt,mergeCommit,body"],
        repo_dir,
    )
    if prs_raw is None:
        print(f"REFUSE: gh pr list failed -- {err}", file=sys.stderr)
        return 2
    if len(prs_raw) >= args.limit:
        # `gh pr list` truncates silently at --limit. A saturated list means
        # older merged PRs inside [since, until] may never have been
        # considered, which would read as clean/immature -- the silent-zero
        # shape this script rejects everywhere else (same rule as the
        # follow-on list). Recorded as unknown, so the exit code says so.
        unknown.append(
            f"PR list possibly truncated (gh pr list returned the full --limit "
            f"of {args.limit}; raise --limit)"
        )

    prs = []
    for p in prs_raw:
        if not p.get("mergeCommit") or not p["mergeCommit"].get("oid"):
            continue
        if not p.get("mergedAt"):  # a null/missing mergedAt is unparseable, not an error to crash on
            continue
        try:
            merged_dt = parse_iso(p["mergedAt"])
        except (ValueError, TypeError, KeyError):
            continue
        if not (since_dt < merged_dt <= until_dt):
            continue
        prs.append({
            "number": p["number"], "title": p.get("title") or "",
            "body": p.get("body") or "", "mergedAt": p["mergedAt"],
            "mergedAt_dt": merged_dt, "sha": p["mergeCommit"]["oid"],
        })
    prs.sort(key=lambda p: p["mergedAt_dt"])
    pr_numbers = [p["number"] for p in prs]

    hunk_cache, msg_cache = {}, {}
    all_pairs, reverts, unreadable_prs = compute_pairs_and_reverts(
        prs, repo_dir, hunk_cache, msg_cache, unknown
    )

    windows_out = {str(w): window_result(prs, all_pairs, w, until_dt, unreadable_prs) for w in window_days}
    windows_out["all"] = window_result(prs, all_pairs, None, until_dt, unreadable_prs)

    resolved_repo = current_repo(repo_dir)
    repo_needed = (not args.no_issues) or (args.attribute is not None)
    if resolved_repo is None and repo_needed:
        # A single, generically-worded entry: it is what drives exit 2 for
        # every caller that depended on the repo string, and it says up
        # front what that breaks, rather than requiring one bespoke message
        # per downstream measure (`reopened_unknown` in format_human matches
        # on this prefix too, for the same reason).
        unknown.append(
            "repo resolution (`gh repo view` failed) -- reopened-issue lookups and "
            "qualified attribution owner/repo#N and URL nominations cannot be "
            "evaluated (bare #N nominations are unaffected)"
        )

    reopened, follow_ons = [], {}
    if not args.no_issues:
        parse_filed_from = load_parse_filed_from()  # REFUSEs (exit 2) if the sibling is missing
        follow_ons = follow_on_closure(pr_numbers, since_dt, until_dt, repo_dir, parse_filed_from, unknown)
        if resolved_repo is not None:
            reopened = reopened_issues(prs, resolved_repo, repo_dir, until_dt, unknown)

    result = {
        "since": args.since,
        "until": args.until if args.until else fmt_iso(until_dt),
        "repo": resolved_repo,
        "prs": len(prs),
        "pr_numbers": pr_numbers,
        "windows": windows_out,
        "reverts": reverts,
        "reopened_issues": reopened,
        "follow_ons": follow_ons,
        "unknown": unknown,
    }

    if args.attribute is not None:
        attribution, attribution_unresolved = compute_attribution(
            prs, args.attribute, resolved_repo, unknown
        )
        result["attribution"] = attribution
        result["attribution_unresolved"] = attribution_unresolved

    exit_code = 2 if unknown else 0

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        window_labels = [str(w) for w in window_days] + ["all"]
        print(format_human(result, window_labels, issues_requested=not args.no_issues))

    for u in unknown:
        print(f"warning: could not answer: {u}", file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
