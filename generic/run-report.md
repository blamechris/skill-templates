# /run-report

Write the run-level report and record for a long prime-directive or tackle-issues run: what the owner asked for, how each issue was chosen, which were hard and why, what that says about the codebase, and the one decision the owner must make. Every number comes from a command or file; anything not recorded at the time is labelled reconstructed.

Use it when such a run itself has stopped or reached package close, or on `/run-report`. A mid-run WARN brief or wave boundary is a bare `/visual-brief` and does not stop the run. It renders through `/visual-brief` and changes neither that skill's contract nor `/session-lifecycle`'s end order. It records. It adds no gate and no authority, and it never changes a review or a merge posture.

## Arguments

- `$ARGUMENTS` — optional run id, `--dir PATH` (passed to `/visual-brief`) and `--no-open`.
- With no id, take the run id, run-record path and ledger path from the seed. If the seed names none, read `ledger:` from the newest `$CLAUDE_RECORDS_DIR/<scope>-[0-9]*/README.md` that has no `stopped:` field, or the newest if all are stopped. If there is no record, take the newest `$CLAUDE_LEDGER_DIR/<scope>-[0-9]*.md`, then the repo's older session-log path, such as `autonomous-session-*.md` at the repo root.

## Run record

The run record is `$CLAUDE_RECORDS_DIR/<run-id>/README.md` (default dir `~/Obsidian/no-it-all/records/`), written outside every worktree like the seed.

- The run id is the stable run id passed to `usage-checkpoint.py --run-id` and written in the ledger STATE header. A new run uses `<scope>-<UTC start date, YYYYMMDD>`, with `-2`, `-3` on collision, where `<scope>` comes from `session-seed.py scope`. A run already in flight keeps the identity it has. The record directory allows only `[A-Za-z0-9._-]`: if the identity has other characters, make only the directory name safe and keep the original in `run:`.
- Create the run record when the run starts, before the first pick, with the owner's words verbatim, the charter, the start snapshot and the selection policy.
- The run id is stable across sessions. Each new session appends itself to `sessions` at its start with its host (the harness or app that ran the coordinator) and `started`. At its end it adds `hours`: `captured_at` of its final checkpoint minus its `started`, in hours to one decimal. The final checkpoint is the newest file for its `session_id` in `~/.claude/usage-history/checkpoints`; with none, write `not recorded`.
- Every seed the run writes, and every reload instruction in a compaction summary, names the run id, the run-record path and the ledger path.
- A run whose ledger already sits at an older path keeps it, recorded in `ledger:`, and is not migrated mid-run.
- A run with no record gets one at resume: `started` is the earliest known time, `direction` comes from the first seed or owner message, and every reconstructed field says `reconstructed`.
- At stop, add `stopped`, `stop_reason` and `report` (the brief path). A mid-run report on demand writes `report` only.
- The run record, the ledger and the report hold the owner's words and private pick reasons. They stay in their private directories and never go into a repository, issue or PR.
- Install `run-report` once, at run start, in the run's own worktree, or not at all. Never run `skill add` mid-pick. Without it, the fallback in the runner skill applies.

```yaml
---
type: run-record
run: RUN_ID
repo: OWNER/NAME
ledger: ABSOLUTE_PATH
sessions: ["SESSION_ID host=HARNESS started=UTC hours=N"]
started: UTC timestamp
direction: "the owner's mission words, verbatim"
charter:
  outcome: "the owner's outcome in the owner's words, or: not stated (inherited: PATH)"
  pool: "a saved COMMAND that returns a number and can reach zero, or: not stated"
  done: "the observable that ends the run, or: not stated"
  check_in: "cadence, or: not stated"
start_snapshot: "UTC; open=N bug_label=NAME-or-none bugs=N-or-n/a bands=<30:N,30-59:N,60-119:N,120+:N pool=N"
selection_policy: "lane order, the repo's pain labels and the old-debt rule text, with its source"
eligible_query: "COMMAND listing the open issues the policy lets the run pick, or: not stated"
limits: "budget, retry and wave limits, each with its scope"
channels: ["NAME | tags: GLOB or none | paths: GLOB | live: COMMAND | released: COMMAND"]
deployed: "COMMAND that prints the running instance's commit or version, or: none"
---
```

The charter only records. A field the owner did not give is written `not stated` and never invented.

Take the start snapshot with one command, `gh issue list --repo "$REPO" --state open --limit 10000 --json number,createdAt,labels`. `$REPO` is the record's `repo`. Compute `open` (rows), `bugs` (rows carrying `bug_label`) and the four age bands from that JSON at the one UTC time written in `start_snapshot`. `pool` is the output of the saved pool command at that time. `bug_label` is taken at run start from `selection_policy`, else from `gh label list --repo "$REPO"`. If the repo has no bug label, write `none` and `bugs=n/a`. The stop report reuses the recorded value and never re-guesses it.

`channels` come from the repo's release docs, or `channels: not recorded`. `tags` is the glob of the channel's release tags, or `none` for a channel with no git tag, such as a store or OTA channel. `paths` is the glob of the repo files that ship in the channel. `live` prints the version users can install now. `released` prints the latest published release on those tags.

## Pick record

Pick lines are append-only History lines in the private ledger, `$CLAUDE_LEDGER_DIR/<run-id>.md` (default dir `~/Obsidian/no-it-all/ledgers/`), written outside every worktree. The STATE header is unchanged.

```text
PICK <UTC> w<wave> #<issue> lane=<lane> age=<days>d because: <one clause, 140 characters max, naming the observable thing this closes> [passed-over=#a:reason;#b:reason]
DONE #<issue> pr=#<pr> sha=<7> rounds=<n> attempts=<n> pkgs=<n> files=<n> hard=<codes|none> [ev=<code>:<ref>,...] [rounds-src=comments|github]
DONE #<issue> pr=- closed=<duplicate|already-fixed|invalid|decomposed>
STOP #<issue> reason=<blocked|abandoned|deferred|decomposed> because: <one clause> [pr=#<pr>]
REVIEW #<pr> r<n> head=<7> <verdict>
WAVE w<wave> <UTC> eligible=<n> taken=<ids>
```

- Recording never stops, defers or reorders a pick, a review or a merge. Append the PICK line before investigating. A missed pick, or an attempt already in flight when this skill was adopted, is back-filled before the next pick as `PICK ... reconstructed`, and the report prints it so. A failed write goes in Status and the work continues.
- Append one `REVIEW` line for each `/full-review` round as it returns, and at the latest before the DONE line. `r<n>` counts from 1 per PR, `head` is the first 7 characters of the reviewed head commit and `<verdict>` is the round's reported verdict.
- A `passed-over` reason must not contain `;`. Replace any with a comma.
- Append the DONE line at merge and a STOP line before moving on from any pick that will not merge, from GitHub facts and the ledger, before selecting more work. An issue the run closes without a PR gets the `pr=- closed=` form of DONE.
- Take the merge facts at that moment with `gh pr view <pr> --json mergeCommit,reviews,comments,files,changedFiles`. `sha` is the first 7 characters of `mergeCommit.oid`. `files` is `changedFiles`. `pkgs` counts the distinct top-level directories in `files`, written `pkgs>=N` when `changedFiles` is above 100, the cap on `files`.
- Append `WAVE` at each wave end, or `WAVE w0` once at stop for a run with no waves.
- Issue-less work (a security upgrade, a release, an infra fix) is keyed `#-1`, `#-2` and so on in PICK, DONE and STOP, and DONE or STOP carries `pr=`.
- Lane is exactly one of these, so counts aggregate. If none fits use `other` and say why in `because`.
  - `owner-directed` — the owner named the issue or chose it from options offered; give a date or a short quote.
  - `pain` — a user-visible failure or an owner-named daily-use path; the repo's pain labels are in `selection_policy`.
  - `old-debt` — chosen under the run's old-debt rule.
  - `priority` — chosen by the selection policy on value, with no other reason.
  - `security-private` — a vault pointer only, no detail.
  - `prerequisite-of:#N`, `follow-up-of:#PR` (including a defect this run introduced and found later), `release`, `infra-unblock`, `other`.
- Field meanings: `age` is whole days from the issue's `createdAt` to the pick time; `attempts` comes from the ledger STATE table; `rounds` is the count of the PR's `REVIEW` lines in the ledger. If it has none, use the count of its `## Code Review` comments in `comments`, labelled `rounds-src=comments`. Only if it has neither, use the distinct head commits in `reviews[].commit.oid`, labelled `rounds-src=github`. The report prints the labels as `comments-only` and `github-reviews-only`; `w0` is the wave of a run with no waves. `eligible` is the count of `eligible_query` at the wave end, and `n/a` when it is `not stated`.
- `hard` is a comma list. `review-churn`, `cross-cutting` and `blocked-then-resolved` are measured from the DONE fields. Every other code needs `ev=<code>:<ref>`, where `ref` is a PR comment URL, a run id or a ledger line, and without it print `not recorded`.

  | code | trigger |
  |---|---|
  | `review-churn` | `rounds` is 3 or more |
  | `cross-cutting` | `pkgs` is 3 or more |
  | `blocked-then-resolved` | `attempts` is above 1 |
  | `fix-defect` | a review comment, PR body or ledger line says the defect was in the change's own fix |
  | `ci-environment` | a non-test CI job failed, then passed on rerun or after an infra-only change |
  | `reversed-design`, `scope-grew` | set at the time, naming the comment or ledger line that records it |

- PICK, DONE and STOP lines stay in the private ledger. Never post a "selected because" comment on the public issue for a `security-private` pick, since the reason can reveal motive.

## Report

Answer these sections in this order, each ending with its source. Render through `/visual-brief --type recap` into `$CLAUDE_BRIEF_DIR`, dark by the root rule, with a "Needs you" callout under the hero. Leave out its session-metrics chips.

1. **Takeaway** — the hero carries outcome chips (verified merges, closures, gates passed) and a two- or three-sentence result. Under it, one paragraph and the one decision the owner must make, with `recommend:` and `default:`. The default records the recommended plan and grants no reserved authority. Other owner checks go under Steward handoff. Section 5 holds the per-PR table the root rule asks for.
2. **Direction** — the charter printed field by field, with the fields marked `not stated` named plainly; the owner's words verbatim; the standing policy text the run inherited, with its source; the limits; the stop reason.
3. **Result** — start against stop: open count, open bugs, pool, using the start snapshot. Then issues retired (the run's issues, open at run start and closed in the window), issues filed and fixed inside the run, net open change, and work by others.
4. **Reach** — for each channel and for the deployed instance, the live version against the released version, and whether each fix is on it, per Inputs, step 4. A fix that is not on a channel is not delivered to that channel.
5. **How issues were chosen** — a lane-by-count table, eligible, taken and `eligible - taken` per wave, the full per-PR table (PR, issue, lane, reason, hard), `passed-over` entries, STOP lines, and picks with no DONE or STOP as `open at stop`.
6. **What was hard and why** — each `hard` code and each STOP, with the measured facts behind it.
7. **What it says about the codebase** — hotspots and, where a recorded reason names the cause, tech debt.
8. **Backlog age** — bands `<30`, `30-59`, `60-119`, `120+` for open at start, open now and closed in the window. A closed issue's age is `closedAt - createdAt`.
9. **Process and cost** — review rounds, reruns and incidents; a `ran in` line giving each session's host and hours, each printed `wall-clock <n>h (includes idle)` or `not recorded`; cost per the rules below.
10. **Steward handoff** — the state of the project, what is usable, what is not verified, owner checks and next work.

### Inputs, read in order

1. The run record, then the ledger PICK, DONE, STOP and WAVE lines. `rounds`, `pkgs`, `files` and `hard` come from the DONE lines and are not recomputed from GitHub.
2. GitHub, with `$REPO` and `$RUN_START` from the run record:

   ```bash
   gh pr list --repo "$REPO" --state merged --search "merged:>=$RUN_START" --limit 500 \
     --json number,mergedAt,closingIssuesReferences,files,changedFiles
   gh issue list --repo "$REPO" --state open --limit 10000 --json number,createdAt,labels
   gh issue list --repo "$REPO" --state closed --search "closed:>=$RUN_START" --limit 10000 \
     --json number,createdAt,closedAt,labels
   ```

   Open at run start is the open issues created before `$RUN_START` plus the closed-in-window issues created before it. `files` lists stop at 100 per PR, so say so for any PR whose `changedFiles` is above 100.
3. Cost, with `$RUN` the run record's `run:` value. Copy this run's checkpoints to a scratch directory and aggregate them, since the aggregate sums everything in its directory:

   ```bash
   T=$(mktemp -d); grep -l "\"run_id\": \"$RUN\"" ~/.claude/usage-history/checkpoints/*.json | while read -r f; do cp "$f" "$T"; done
   python3 ~/.claude/scripts/usage-checkpoint.py --aggregate-dir "$T"
   ```

4. Reach, after `git fetch --tags`. A fix applies to a channel only if one of its PR's `files` matches the channel's `paths`; otherwise print `n/a` for that channel. A channel's release for a merged SHA is the first tag matching its `tags` glob that contains the SHA (`git tag --list 'GLOB' --contains <sha> --sort=creatordate`), or `no release yet` if there is none. Compare `live` with a tag by removing the literal prefix of the `tags` glob (the text before its first `*`) from the tag. The fix is on the channel when `live` is that release's version or a later one in `git tag --list 'GLOB' --sort=v:refname` order. Print `released` beside `live`. A tag newer than `released` is `tagged, not published`. A channel with `tags: none` is `not verifiable`. For `deployed`, a commit read-back is compared with `git merge-base --is-ancestor <sha> <deployed>`, where exit 0 means on it and exit 1 means not, and a version read-back goes through the tag rule of the channel it comes from. A claim that auto-deploy happened is not a read-back: read the running commit or version.

### Rules

- Every number comes from a command or file; a number with no source is left out. Print the row count beside each count.
- If a list returns exactly its `--limit` rows, rerun with a higher limit or slice it by date; otherwise report that section as not run.
- A field with no pick record prints as `reconstructed from PR text` or `not recorded`, never filled silently.
- A PR or issue belongs to the run if and only if it has a DONE or STOP line. Anything else merged or closed in the window is `other sessions or owner`, counted apart.
- State what the owner never stated about selection, such as a priority order or an age rule; do not infer one.
- Hotspots are files touched by at least max(4, 5% of the run's PRs) merged PRs, and top-level packages by PR count, printed with the threshold. Leave out lockfiles, generated files (including those marked in `.gitattributes`), and version and changelog files. They are hotspots and not defects. Call something tech debt only where a recorded `hard` code or reviewer finding names the cause.
- Compute age in whole days from `createdAt` to one stated UTC snapshot time, print that time beside every count, and use the count at or above the run's old-debt threshold from `selection_policy`, else 60 days, as the headline band.
- Cost is quoted only for a complete count. After the aggregate, compare its `sessions` count N with the number M of entries in the run record's `sessions`. If N is 0 or lower than M, print `cost: not recorded (N of M sessions checkpointed)` and never quote a dollar figure. Only when N equals M, quote the printed figures; any other count quotes none and names the mismatch.
- When N equals M, quote cost from the aggregate's `all_in_lower_usd` and `unpriced_responses` as printed, as "lower bound, Claude only, N unpriced", and report `partial_sessions` if it is above 0. Link the row that `usage-benchmark-row.py` appended to the usage benchmark table, whose default path that script prints, under the brief directory. Find it by this session's id prefix, or say `none appended`. Add none, and give no tier to a multi-package run.
- Never copy private-finding detail into the report; a withheld finding appears only as a count (`1 finding withheld`). Its vault path stays in the ledger, the seed and the chat status.
- Before publishing, a fresh subagent at the workhorse tier or cheaper, never Fable, rechecks the headline numbers: the Result counts, the headline-band count, the Reach comparison, and the cost session count. It answers one line per number, `match` or the differing value, reusing the fetched JSON only where the snapshot time is the same. The report footer records the answers.
- Recording steps are not skipped on the agent's own judgement; one that cannot run is reported as not run, with the reason, and the work continues.

### Hand-off

Reach supplies the facts for the root `In effect:` line. End the chat with the Status block and `Next`, linking the brief.
