# decision-record.py and seed-freshness.py — record shape

## The problem

An owner decision arrives in chat mid-package, sometimes relayed by another agent.
Nothing writes it down, so the plan, the seed and the pending-decision fields lag
what was approved. A seed can ask the owner to decide something minutes after the
owner already answered it, and go on asking for hours. The PR ledger
(`pr-record.py`) stays accurate because a merge triggers it; a decision has no
equivalent trigger. The fix is a ledger the deciding session writes **before
acting on the answer**, plus a read-only check that compares seeds against it.

## The unit: one decision

`decision-record.py add` appends **one JSON line per decision** to
`~/Obsidian/no-it-all/ledgers/decisions.jsonl` (`$CLAUDE_DECISION_LEDGER`, then
`--ledger`, each overriding the one before).

```json
{
  "kind": "decision-record",
  "schema_version": 1,
  "id": "dec-3f9a1c0b27de",
  "scope": "skill-templates",
  "received_at": "2026-11-01T10:00:00Z",
  "decided_by": "Chris",
  "channel": "direct" | "relay",
  "relay_via": null | "dot",
  "question": "Merge PR 9115 and start the follow-on?",
  "answer_verbatim": "yes, merge it, then start",
  "authorizes": ["merge PR 9115", "start the follow-on"],
  "limits": ["no force push"],
  "pins": {"pr": "9115", "head": "abc123"},
  "refs": ["https://github.com/OWNER/REPO/pull/9115"],
  "supersedes": null,
  "session": "7613cec0-38a1-41fb-84a7-f3bc43823911",
  "recorded_at": "2026-11-01T10:00:20Z"
}
```

## Design calls

1. **Verbatim, not paraphrased.** `answer_verbatim` is the owner's exact words. A
   relayed answer is recorded as relayed (`channel: "relay"`, `relay_via` required),
   so a later reader can tell what the owner said from what an agent said they said.
2. **`id` is a hash of the content** (scope, received_at, decided_by, question,
   answer), so recording the same decision twice is a refusal, not a duplicate line.
   `supersedes` names an earlier id that must already be in the ledger.
3. **`received_at` is when the answer arrived**, not when it was written down, and may
   be passed explicitly for a late record. `recorded_at` is the write time. The
   freshness check compares `received_at`.
4. **No session, no record.** The session comes from `--session`, then
   `$CLAUDE_CODE_SESSION_ID`; there is no third source, the same discipline as
   `session-seed.py`. `scope` defaults to `session-seed.py scope`.
5. **Single-line fields only, and nothing credential-shaped.** A newline or control
   character in any field, or a value shaped like a token (`ghp_`, `github_pat_`,
   `sk-`, `xox*-`, `AKIA…`, a PEM private-key header, a long `Bearer` value), is a
   refusal. This is a heuristic backstop, not a license to paste secrets.
6. **One locked O_APPEND write.** The same `fcntl.flock` on a sidecar `.lock` file as
   `pr-record.py`, so racing writers serialize and lines never interleave.
7. **No git in the script.** Committing stays the writer's job under the
   vault-writer-commits rule; `add` prints the exact `git -C <vault> add -- <p>` and
   `commit -m <m> -- <p>` lines to run.

`list [--scope S] [--since UTC] [--json]` is read-only.

## seed-freshness.py: the check

Report-only. For each canonical seed `NEXT-<scope>.md` in the handoff dir (or one
`--scope`) it prints `FRESH <scope>` or `STALE <scope> <reason>`. The seed's
frontmatter and the handoff-dir rule are loaded from `session-seed.py` itself, so a
seed is parsed exactly one way. Archived seeds are ignored. A seed is STALE when,
after its `date`:

| Code | Condition |
|---|---|
| `decision` | a decision record for the scope has a later `received_at` |
| `pr-record` | a pr-record whose repo basename equals the scope, or whose `session.id` starts with the seed's `session`, has a later `recorded_at` or `pr_meta.merged_at` |
| `owner-ask` | `picks_up_at` contains `OWNER:` and a later decision exists: the seed asks the owner for something a later decision may have answered |

`--json` prints a list of `{scope, status, reasons[{code, detail}]}`. Exit 0 on a
completed check whatever it found; exit 2 on a usage error or an unreadable input
(a seed, a malformed ledger line, a missing seed date), with the verdicts that could
be computed still printed. It never writes, renames or commits anything.

## What it does not do

It does not decide whether a stale seed is wrong, only that something happened after
it was written. The remedy is the existing one: record the decision, then re-write the
seed through `session-seed.py write` if its `picks_up_at` or pending decisions changed.
