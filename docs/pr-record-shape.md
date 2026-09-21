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
    "nominates_pr": true,
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
  "review_rounds": {
    "agent": [{"agent": "agent-a6ad05c88f18a514e", "skill": "agent-review", "round": 1,
               "verdict": "request_changes", "source": "harvest",
               "critical": 2, "suggestion": 3, "nitpick": 3, "mutation_ran": 3,
               "result_path": "<abs path to .result.json>"}],
    "rounds_missing": [],
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
| `ci.runs` | `gh run list --branch <head_ref>`, **filtered to the PR's commit SHAs** | `null` + `unknown[]` |
| `follow_ons` | `filed-from.py`'s `descendants(pr, repo, depth=1)` | `null` + `unknown[]` on a `?` node |
| `session.*` | `--session` → `$CLAUDE_CODE_SESSION_ID` → `null` | the whole agent half is `null` |
| `agents`, `review_rounds.agent`, `findings` | the session dir, via `review-result.py`'s walkers | `null` when there is no session |

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

**2. An agent belongs to the PR only with evidence, and the evidence is recorded.**
Sidecars carry no PR and transcripts carry `gitBranch: HEAD` and `cwd: ~` for every
line (measured on both validation sessions), so neither is usable. Two links are:

- `result` — a `.result.json` whose `pr` equals this PR (authoritative).
- `brief` — the agent's first user message names the PR (`#N`, `PR N`, `pull/N`) or
  the PR's head branch name.

Measured on #278's session: 5 agents, 4 linked (implementer and both fixers by brief,
reviewer by result and brief), 1 correctly unlinked (the Explore recon agent, which was
session-level work). On #276's session: 2 agents, both linked — and the reviewer
**only** by `result`, its brief naming neither the PR nor the branch. Either link alone
would miss an agent; the pair missed none on the validation set. `agents_unlinked`
keeps the rest visible without attributing them.

**3. Review rounds report the gap, not just the rows.** #276's only recorded result says
`round: 3`, and there is no round 1 or 2 anywhere in the session dir (#267's
one-result-per-agent limitation). A record that listed one round would read as "one
round of review". So `rounds_missing` lists every integer below the highest recorded
round that has no row: `[1, 2]` for #276, `[]` for #278.

## What is deliberately not here

- **Rework.** `rework-lag.py` measures +7d/+30d windows that do not exist at merge time.
  The record carries the key and the lagging data joins on it later; copying a
  not-yet-decidable measure into a merge-time record would store `immature` forever.
- **Dollars.** `usage` is raw tokens per agent, deduplicated by `requestId` keeping the
  *last* record (the #259 lesson: the first is a partial). Pricing belongs to
  `usage-pace.py`; a second price table here would drift from it.
- **Distilled claims.** `session-distill.py` output joins on session + agent id. The
  record does not re-run a model.
- **Multiple sessions per PR.** v1 takes one `--session`. A PR split across sessions
  gets one record per `--replace` run today; if the ledger shows it happening, that is
  the evidence for making `session` a list.

## Idempotency

One record per `(repo, pr)`. Writing a PR that is already in the ledger REFUSES unless
`--replace`, which rewrites the ledger atomically with the old line swapped out. The
ledger defaults to `~/Obsidian/no-it-all/ledgers/pr-records.jsonl`
(`--ledger` / `$CLAUDE_PR_LEDGER` override). `--stdout` prints the record and writes
nothing. An unmerged PR REFUSES.
