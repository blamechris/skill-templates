# pr-record.py — record shape (designed before coding, per #270)

## The unit: one merged PR

`pr-record.py` writes **one JSON line per merged PR** to a ledger in the vault. It is the
join table of epic #266: the leading signals (`review-result.py`, `session-distill.py`)
and the lagging one (`rework-lag.py`) all key on `(repo, pr)`, and until now nothing
wrote that key down together with who did the work, at what tier, in how many rounds.

It runs **at merge time, in the session that merged**, which is the only moment every
source is still cheap to read: the session directory is on disk, the branch still
exists for `gh run list`, and `$CLAUDE_CODE_SESSION_ID` names the right session. It
also runs later for backfill, with `--session` given explicitly.

## The record (schema_version 1)

```json
{
  "kind": "pr-record",
  "schema_version": 1,
  "repo": "blamechris/skill-templates",
  "pr": 278,
  "recorded_at": "2026-09-21T02:10:00Z",
  "pr_meta": {
    "title": "...", "author": "blamechris", "merged_by": "blamechris",
    "head_ref": "feat/session-distill", "created_at": "...Z", "merged_at": "...Z",
    "merge_commit": "776dbca...", "additions": 2962, "deletions": 5, "changed_files": 6,
    "closes": [269]
  },
  "session": {
    "id": "7613cec0-38a1-41fb-84a7-f3bc43823911",
    "source": "flag" | "env",
    "transcript": "<abs path>",
    "merged_within_span": true,
    "main_models": {"claude-opus-5": 212}
  },
  "commits": [{"oid": "...", "headline": "...", "authored_at": "...Z"}],
  "agents": [
    {"id": "agent-a6ad05c88f18a514e", "linked_by": ["result"],
     "description": "Adversarial review of PR 278", "agent_type": "general-purpose",
     "model_requested": "opus", "models_observed": {"claude-opus-5": 41},
     "tier": "opus", "started_at": "...Z", "ended_at": "...Z",
     "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}}
  ],
  "agents_unlinked": 1,
  "agents_after_merge": 0,
  "review_rounds": {
    "agent": [{"agent": "agent-a6ad05c88f18a514e", "skill": "agent-review", "round": 1,
               "verdict": "request_changes", "source": "harvest",
               "critical": 2, "suggestion": 3, "nitpick": 3, "mutation_ran": 3,
               "result_path": "<abs path to .result.json>"}],
    "rounds_missing": {"agent-review": []},
    "github": [{"author": "copilot-pull-request-reviewer", "state": "COMMENTED",
                "submitted_at": "...Z"}],
    "threads": {"total": 4, "resolved": 4, "by_author": {"copilot-pull-request-reviewer": 4}}
  },
  "findings": [
    {"agent": "agent-a6ad05c88f18a514e", "round": 1, "severity": "critical",
     "title": "...", "file": "...", "line": 123, "mutation_ran": false, "red_line": false}
  ],
  "follow_ons": [{"number": 280, "state": "OPEN", "title": "..."}],
  "ci": {
    "final": [{"name": "validate", "workflow": "validate-registry", "conclusion": "SUCCESS"}],
    "runs": [{"id": 1, "workflow": "validate-registry", "conclusion": "success",
              "head_sha": "...", "event": "pull_request", "created_at": "...Z"}],
    "runs_failed": 0
  },
  "unknown": []
}
```

## Where every field comes from

| Field | Source | Absent means |
|---|---|---|
| `pr_meta`, `commits`, `ci.final` | `gh pr view --json …` (one call) | REFUSE — no PR, no record |
| `review_rounds.github` | same call, `reviews` | `[]` is a real zero |
| `review_rounds.threads` | `gh api graphql` `reviewThreads` | `null` + `unknown[]` entry |
| `ci.runs` | `gh run list --branch <head_ref>`, **filtered to the PR's commit SHAs** | `null` + `unknown[]` — a run list truncated at its own `--limit` is treated exactly like a failed call, never a confidently partial list |
| `follow_ons` | `filed-from.py`'s `descendants(pr, repo, depth=1)` | `null` + `unknown[]` on a `?` node |
| `session.*` | `--session` → `$CLAUDE_CODE_SESSION_ID` → `null` | the whole agent half is `null` |
| `agents`, `review_rounds.agent`, `findings` | the session's own main transcript (`~/.claude/projects/*/<sid>.jsonl`), via `review-result.py`'s sidecar walkers | `null` when there is no session; `agents: []` (not a REFUSE) when the transcript resolves but its sidecar directory doesn't exist at all — see design call 1 |
| `agents_after_merge` | agents with real linking evidence whose `started_at` is after the PR's own `merged_at` | `null` when there is no session |

`ci.final` maps BOTH of GitHub's own `statusCheckRollup` shapes into one
`{name, workflow, conclusion}` form (round 2, S5): the modern Checks API
(`__typename: "CheckRun"`, fields `name`/`workflowName`/`conclusion`) and the legacy
commit-status API (`__typename: "StatusContext"`, fields `context`/`state`, no workflow
at all — mapped to `workflow: null`). A StatusContext entry carries a real result and a
real name, just under different field names, so it is mapped rather than silently
dropped.

`null` and `[]` are different facts everywhere in this record: `[]` is "the source
answered and there were none", `null` is "the source was not asked or could not answer",
and every `null` caused by a failure also puts a sentence in `unknown[]`. The exit code
is nonzero whenever `unknown[]` is non-empty — `rework-lag.py`'s contract, reused.

## Three design calls, each with its reason

**1. The session is given, never searched for.** An earlier idea was to find the
session by scanning every transcript for a mention of the PR — that is a nomination, and
`rework-lag.py --attribute` already shows the price: multiple matching transcripts,
none openable without guessing. At merge time the harness already knows the answer.
What the script *does* check is that the named session is plausible: its transcript
must nominate the PR (the same `URL_RE` / `REF_RE` / `BARE_RE` grammar `rework-lag.py`
uses, imported, not copied), or the run REFUSES — a record filed under the wrong session
is worse than one filed under none.

Nomination alone is too weak, and the validation data shows why: the session that
*designed this script* mentions #276 dozens of times and did none of #276's work. So
the check depends on where the id came from:

- `source: env` (the merge-time path) additionally requires `merged_within_span` — the
  PR's `mergedAt` falls inside the transcript's first/last timestamp. The env var only
  proves which session is *running*; the span proves it was running when the merge
  happened. Backfilling #276 from this session with the env var alone REFUSES.
- `source: flag` records `merged_within_span` but does not enforce it: a person naming
  a session is making the claim deliberately, and a PR authored in one session and
  merged from the web UI later is still that session's work.

There is deliberately no `nominates_pr` field in the record: a session that fails to
nominate the PR always REFUSES before a record is ever built, so a present `session`
block has, by construction, always nominated — the field would be a hard-coded `true`
on every record that exists to read.

**Session resolution is by main TRANSCRIPT, not by session directory** (round 2 of
#270's review, S2): exactly one `~/.claude/projects/*/<sid>.jsonl` must exist, but the
sidecar directory `~/.claude/projects/*/<sid>/` is allowed to be entirely absent — a
session that spawned no subagents never creates one at all (measured on the author's
machine: 404 of 590 transcripts have no such directory). When the directory doesn't
exist, `agents` reads `[]`, a real and confidently-known zero, never a REFUSE. A REFUSE
is reserved for the transcript itself failing to resolve to exactly one match.

**2. An agent belongs to the PR only with evidence, and the evidence is recorded.**
Sidecars carry no PR and transcripts carry `gitBranch: HEAD` and `cwd: ~` for every
line (measured on both validation sessions), so neither is usable. Two links are:

- `result` — a `.result.json` whose `pr` equals this PR **and** whose `repo`, when
  non-null, equals this repo (round 2, C3a: a result recorded for the right PR number
  in a different repo is not evidence for this one).
- `brief` — the agent's first user message names the PR (`#N`, `PR N`, `pull/N`) or
  the PR's head branch name, the branch match bounded on BOTH sides against
  `[A-Za-z0-9_./-]` (round 2, C3b: an unbounded substring test let a branch called
  `fix` match inside "prefix" and "fixture").

**Round 2 added a third, independent gate: TIMING.** An agent with real linking
evidence additionally needs a `started_at` at or before the PR's own `merged_at` — work
that started after the merge cannot be work on the PR, however its brief reads.
Reproduced on real data: backfilling PR #276 from a *later* session (one reviewing this
very finding) linked an agent that started at 02:42Z against a merge at 00:10Z. Such an
agent is excluded from `agents[]` and counted in `agents_after_merge` instead of
`agents_unlinked` — the evidence exists, it is just temporally impossible. An agent
with evidence but no `started_at` at all (an empty or entirely unparseable transcript)
cannot be placed in time either direction, so it does not link either — counted in
`agents_unlinked`, with its own `unknown[]` entry so the exclusion is visible rather
than looking like "no evidence was ever found".

**A `.result.json`, a transcript, or a meta.json that cannot be trusted is never
silently folded into "no evidence" either (C1/C2).** A result file that fails to parse
as JSON, that parses but fails `review-result.py`'s own `validate_document`, or that
validates but carries a null `pr`, can never supply a `result` link — but when its raw
text (or, for a parseable-but-invalid document, its own `pr` field) still points at
this PR, an `unknown[]` entry names the file and best-effort recovers whatever round
number it can, because a malformed file that visibly claims to be about this PR is
evidence an agent TRIED to record a review round that is now unreadable — and letting
`rounds_missing` read as if that round never existed would be exactly the silent
completeness bug this record exists to reject. A transcript or meta.json that raises an
OSError while being read (as opposed to one that is simply absent) always gets its own
`unknown[]` entry for the same reason. A transcript line that parses as JSON but is not
an object is skipped (the same fix rework-lag.py's `_transcript_span_and_text` got in
this round) but also named in `unknown[]` once per agent, as a data-quality signal.

Measured on #278's session: 5 agents, 4 linked (implementer and both fixers by brief,
reviewer by result and brief), 1 correctly unlinked (the Explore recon agent, which was
session-level work). On #276's session: 2 agents, both linked — and the reviewer
**only** by `result`, its brief naming neither the PR nor the branch. Either link alone
would miss an agent; the pair missed none on the validation set. `agents_unlinked`
keeps the rest visible without attributing them.

**3. Review rounds report the gap, not just the rows — computed PER SKILL.** #276's
only recorded result says `round: 3`, and there is no round 1 or 2 anywhere in the
session dir (#267's one-result-per-agent limitation). A record that listed one round
would read as "one round of review". So `rounds_missing` lists, for each skill that has
at least one valid recorded round, every integer below that skill's own highest
recorded round with no row of its own: `{"agent-review": [1, 2]}` for #276,
`{"agent-review": []}` for #278. It is an object keyed by skill, not one flat list
(round 2, nitpick), because two different skills reviewing the same PR keep independent
round sequences — folding them into one list would let one skill's complete history
mask a gap in another's.

**`tier` can read `"other"`, not only the four known families.** `tier()` is reused
from `usage-pace.py` by path (round 2, S4) rather than a second, hand-maintained
substring table, and it returns `"other"` for a model string it doesn't recognize as
fable/opus/sonnet/haiku. That value is recorded as-is — `null` is reserved for "no
model information at all" (neither an observed model nor `meta.json`'s own `model`),
a different fact from "a model was named but isn't one of the four known families".

## What is deliberately not here

- **Rework.** `rework-lag.py` measures +7d/+30d windows that do not exist at merge time.
  The record carries the key and the lagging data joins on it later; copying a
  not-yet-decidable measure into a merge-time record would store `immature` forever.
- **Dollars.** `usage` is raw tokens per agent, deduplicated by `(message.id, requestId)`
  keeping the *last* record for that pair — the same key `usage-pace.py` builds (round
  2, S4), not a second hand-rolled one — since the first is always a partial (the #259
  lesson). Pricing belongs to `usage-pace.py`; a second price table here would drift
  from it.
- **Distilled claims.** `session-distill.py` output joins on session + agent id. The
  record does not re-run a model.
- **Multiple sessions per PR.** v1 takes one `--session`. A PR split across sessions
  gets one record per `--replace` run today; if the ledger shows it happening, that is
  the evidence for making `session` a list.

## Idempotency

One record per `(repo, pr)`. Writing a PR that is already in the ledger REFUSES unless
`--replace`, which rewrites the ledger with the old line swapped out. The ledger
defaults to `~/Obsidian/no-it-all/ledgers/pr-records.jsonl` (`--ledger` /
`$CLAUDE_PR_LEDGER` override). `--stdout` prints the record and writes nothing — no
duplicate check runs at all in that mode, since nothing is written. An unmerged PR
REFUSES.

**Concurrency and structure preservation (round 2, C4/S3).** The whole read-check-write
is guarded by an exclusive `fcntl.flock` on a sidecar `<ledger>.lock` file, so two
`pr-record.py` invocations racing against the same ledger serialize instead of one
clobbering the other's write. A brand new `(repo, pr)` is **appended** as a single line
under that lock — the file is never read in full or rewritten just to add one record.
`--replace` is the only path that ever rewrites the file (still under the lock): every
other line survives as found, including a blank one; the file's own permission bits are
restored on the replacement; and a ledger path that is itself a symlink is written
through to the file it resolves to, rather than being overwritten with a plain file
(which would sever the link). There is no claim of exact byte-for-byte preservation of
every untouched line's original whitespace/newline convention — only that its content
is not touched, lost, or reordered.

A line that fails to parse as JSON but whose raw text still contains both this PR
number and this repo is treated as a **possible duplicate** — most likely a previous
write that was truncated or corrupted mid-write — and REFUSEs exactly like a confirmed
one; only `--replace` may swap it out. The duplicate key is always `(repo, pr)`, never
`pr` alone: the same PR number recorded in a different repo is a different record.
