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
   The duplicate refusal only catches an identical `received_at`: the same answer
   recorded with a different arrival time is a new record, so record once, at the
   moment the answer arrives. `supersedes` names an earlier id that must already be
   in the ledger.
3. **`received_at` is when the answer arrived**, not when it was written down, and may
   be passed explicitly for a late record. `recorded_at` is the write time. The
   freshness check compares `received_at`, which may not be more than 5 minutes in
   the future. Every accepted timestamp, offsets (at most 14:59) and unpadded fields
   included, is normalized to canonical `YYYY-MM-DDTHH:MM:SSZ`, or with `.ffffffZ`
   when the fraction is non-zero, before it is stored and hashed; comparisons keep
   full precision, so equal instants get one id and `--since`
   compares parsed values.
4. **No session, no record.** The session comes from `--session`, then
   `$CLAUDE_CODE_SESSION_ID`; there is no third source, the same discipline as
   `session-seed.py`. `scope` defaults to `session-seed.py scope`.
5. **Single-line fields, except the owner's words, and nothing credential-shaped.**
   `answer_verbatim` and `question` may span lines (`\n`; `\r\n` is normalized to
   `\n`; JSON escapes it safely), and `--answer-file PATH|-` reads a multi-line answer
   from a file or stdin. Every other field is single-line. Any other control
   character, U+2028, U+2029 or U+0085 anywhere is refused (checked on the raw value,
   before trimming), as is an empty or whitespace-only required field, or a value shaped like a
   credential (`ghp_`, `github_pat_`, `sk-`, `sk_live_`, `pk_live_`, `xox*-`, `AKIA…`,
   a JWT, a PEM private-key header, a `Bearer` value in any case, or
   `password|secret|token|api_key` followed by `:` or `=` and a value of at least 8
   characters that contains a digit or mixed case, so prose like "token: rotation
   weekly" passes) is a refusal. The message tells the agent to paraphrase the
   credential part, keep the rest verbatim and note that it did so.
   This is a heuristic backstop, not a guarantee and not a license to paste secrets.
6. **One locked, repaired O_APPEND write.** The same `fcntl.flock` on a sidecar `.lock`
   file as `pr-record.py`, so racing writers serialize. Under the lock, a last record
   missing its newline is preserved by prepending one, a short write is continued
   until the whole line is down, and any write error truncates the ledger back to its
   pre-append size and exits 2. The ledger path is resolved with `realpath` first, so
   an alias and its target share one lock; if the rollback itself fails the message
   says restoring FAILED and partial bytes may remain. Locks are keyed by realpath, so hardlinked aliases are not serialized for the
   duplicate check or rollback: use one path per ledger. A refusal creates no directory
   and no `.lock`.
7. **The ledger is private and vault-only.** `add` refuses a ledger path inside one of
   the current session's repo worktrees (using `session-seed.py`'s worktree-roots
   logic, loaded by path). Never quote a record or `answer_verbatim` into a repo, PR
   or issue; cite the `dec-…` id instead.
8. **No git in the script.** Committing stays the writer's job under the
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
| `decision` | a decision record for the scope has a later `received_at` or `recorded_at` (a late relay recorded after the seed was written is not in the seed) |
| `pr-record` | a pr-record whose repo basename equals the scope, or whose `session.id` starts with the seed's `session`, has a later `recorded_at` or `pr_meta.merged_at` |
| `owner-ask` | `picks_up_at` contains `OWNER:` and a later decision exists: the seed asks the owner for something a later decision may have answered |

`--json` prints a list of `{scope, status, reasons[{code, detail}]}`. Exit 0 on a
completed check whatever it found; exit 2 on a usage error or an unreadable input
(a seed, a malformed ledger line, a missing seed date), with the verdicts that could
be computed still printed. It never writes, renames or commits anything.

**Corruption policy, shared by `list`, `add` and `seed-freshness.py`.** A malformed
line, invalid UTF-8, a non-object row, a `pr_meta` or `session` that is not an object,
or an event that cannot be dated is skipped and reported with its line number on
stderr; every computable result is still produced; `list` and `seed-freshness.py`
then exit 2. An event that cannot be dated is an error, never "nothing happened".
`add` repairs the newline, appends, warns about the bad lines and exits 0, so one bad
line never bricks the ledger.

**Seed date resolution.** `session-seed.py` writes the seed `date` at minute
resolution. When the seed file's mtime falls inside that same UTC minute it is the
exact write instant. Otherwise a date without seconds is treated as ending at the end
of that minute, so a decision recorded earlier in the same minute (the normal flow) is
not STALE; the tradeoff is that an event in that minute *after* the write is missed, a
false-FRESH window under 60 seconds. A date carrying seconds is used exactly. Session ids are
matched the way `session-seed.py` normalizes them: only UUID-shaped ids are lowercased, any
other id is compared case-sensitively, and a seed session shorter than 8 characters
must match exactly, never as a prefix.

## What it does not do

`owner-ask` is a heuristic: it does not match the later decision to the ask, only
notes that an `OWNER:` seed predates some decision for its scope. It does not decide
whether a stale seed is wrong, only that something happened after
it was written. The remedy is the existing one: record the decision, then re-write the
seed through `session-seed.py write` if its `picks_up_at` or pending decisions changed.
