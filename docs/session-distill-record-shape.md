# session-distill.py — record shape (designed before coding, per #269)

## The unit of analysis: a RUN

A run is a (brief -> final report) pair. Two kinds, one shape:

- `subagent` — one `agent-<hex>.jsonl`, at EITHER sidecar level
  (`<session-dir>/subagents/` and `<session-dir>/subagents/workflows/<runId>/`,
  the two levels review-result.py already walks). Brief = the FIRST `type:"user"`
  line's text. Report = the transcript's FINAL `StructuredOutput` tool_use's
  `input` when one exists (a workflow subagent's real result), else the LAST
  `type:"assistant"` line's text blocks (the same extraction review-result.py's
  `last_assistant_text` applies) — see `run.report_source` (#285) below for why
  the plain text-blocks-only read is not enough on its own.
- `main-turn` — one user-prompt -> end-of-turn-assistant-text span of the MAIN
  transcript.

**Why main turns are runs, and this is not scope creep.** The issue says "one
record per agent run"; the plan's item 7 acceptance says the method must find the
false-freeze on its own. The false-freeze happened on the MAIN thread — a
distiller that reads only `subagents/**` cannot see it and fails its own
acceptance. The main session is a run; it is segmented by user turn because that
is where its brief lives.

## The record (schema_version 6)

```json
{
  "kind": "session-distill-record",
  "schema_version": 6,
  "session": "13cee7be-edd8-4dfc-afe3-093e899db85b",
  "run": {
    "id": "agent-a1794d4c28be50f83",
    "kind": "subagent",
    "spawned_by": "session",
    "agent_type": "general-purpose",
    "model": "opus",
    "description": "Fix restoreAllToAutomatic doc mismatch",
    "workflow_phase": null,
    "started_at": "2026-09-16T22:24:11Z",
    "ended_at": "2026-09-16T22:51:03Z",
    "transcript": "<abs path>",
    "brief_chars": 2851,
    "report_chars": 1904,
    "report_source": "structured_output",
    "tool_calls": 37
  },
  "asked":      "...",
  "understood": "...",
  "delivered":  "...",
  "claims": [
    {"id": "c1", "text": "...", "kind": "verification",
     "proof_index": 12,
     "proof_snippet": "swift format lint --recursive",
     "proof": "...DERIVED from trace entry [proof_index]; null when uncited or out of range...",
     "quote": "...verbatim from the report...",
     "proof_located": true}
  ],
  "brief_claims": [
    {"id": "b1.c10", "text": "...a repo-state assertion THIS run made in a brief...",
     "kind": "defect-location", "quote": "...verbatim from the brief...",
     "source": "brief", "from_run": "agent-a125a8c132b05b56c", "via_tool": "Agent"}
  ],
  "verifications": [
    {"index": 12, "tool_use_id": "toolu_...", "categories": ["lint"],
     "command": "swift format lint --recursive --strict Sources Tests Tools 2>&1 | head -50; echo \"EXIT=$?\"",
     "errored": false, "output": "EXIT=0", "output_present": true,
     "exit_masked_by_pipe": true, "output_truncated": true, "empty_ci_result": false}
  ],
  "gates_run": {"test": 1, "lint": 1, "build": 0, "ci_read": 1},
  "gates_named_not_run": ["build"],
  "later_wrong": [
    {"claim": "c1", "how": "...one sentence...",
     "contradicted_by": {"run": "agent-a353ff...", "at": "...Z", "quote": "..."}}
  ],
  "classified_as": [
    {"label": "proxy-as-thing", "supports": ["c1"], "why": "..."}
  ],
  "unclassified_reason": null,
  "later_wrong_withdrawn": [],
  "distilled": {"at": "...Z", "model": "sonnet", "cost_usd": 0.6124, "passes": ["distill","chain"],
                "calls": {"distill": {"cost_usd": 0.4011, "num_turns": 2},
                          "chain":   {"cost_usd": 0.2113, "num_turns": 2}}}
}
```

### #288 — per-pass cost accounting (schema_version 5)

A run's spend was one number, `distilled.cost_usd`. #299's two post-change
samples ran above the prior range, and nothing could say which pass the extra
spend sat in. Now:

- `distilled.calls` holds one entry per call **made** for the record: its own
  `cost_usd` and the envelope's `num_turns`. A failed chain call is in `calls`
  but not in `passes`, because it spent money without producing a result.
  `distilled.cost_usd` is the sum of `calls`, so the split and the total cannot
  disagree.
- The document's `failed_cost_usd` sums the calls that produced **no** record:
  distill-phase failures, including #291's placeholder. `--resume` carries it
  forward even after #294 prunes the failure entry, so
  `total_cost_usd == Σ record cost_usd + failed_cost_usd` holds across retries.
- Every `failures[]` entry carries its `cost_usd` and the envelope's `subtype`,
  `api_error_status` and `num_turns` verbatim, or null when the envelope lacks
  them or never parsed. #273's 11 `is_error` failures printed only `result`,
  which was `None`, and dropped the one field that would have named the cause.
- `report` prints the per-pass totals, the mean cost per call and the mean
  `num_turns`, plus `failed_cost_usd`.
- The default `--timeout-secs` goes from 180 to 540. 180 was exceeded by a
  real main turn in #273, and every live validation since has passed 540 by
  hand.
- `--jobs N` runs up to N runs at once. #273 took about 7.5 hours serially, and
  the proof had to be sharded by hand into 6 `--only` processes and merged.
  Records and failures are merged back in run order, so `--jobs 4` writes the
  `--jobs 1` document and only the timestamps differ. Every call passes one
  budget gate. The projection reserves the calibrated per-call average for
  each call still in flight. Under a budget, the pool runs a single call until
  one real cost has been observed. A stop refuses every later call: queued runs
  never start, and a run between its passes keeps a distill-only record. Calls
  already in flight finish and are billed. The overshoot bound is therefore N
  times the serial loop's: each in-flight call can exceed the average it
  reserved.

### #285 — report extraction and deterministic verifications (schema_version 2)

Hand-reading a real session's distilled payloads (issue #285's diagnosis comment)
found 108 of 160 runs distilled with a silently EMPTY report: a workflow
subagent's real result lands in a final `StructuredOutput` tool_use's `input`,
not a text block, and review-result.py's `last_assistant_text` (unchanged by
this fix — `review-result.py harvest` also depends on its exact
text-blocks-only semantics) reads only text blocks of the last assistant
line, so it silently returned `""`. Two more runs' "report" was the harness's
own session-limit cutoff message — a verdict from incomplete data if
distilled as if it were real.

- **`run.report_source`** — `"structured_output"` | `"structured_output_rejected"` | `"harness_error"` |
  `"text"` | `"none"`, on EVERY run stub, both kinds. `structured_output`
  prefers the transcript's final `StructuredOutput` tool_use (report =
  its `input`, pretty-printed, with any final assistant text prepended).
  A submission whose own tool_result is `is_error` was rejected by the
  harness; the last ACCEPTED one is the report, and a run whose every
  submission was rejected is `structured_output_rejected`.
  `harness_error` is a report matching a known harness cutoff/error prefix
  — kept, not discarded, but never silently treated as a real result. A
  main-turn's `report_source` is only ever `"text"`/`"none"` — main turns
  do not end in a `StructuredOutput` tool_use.
- **`verifications[]`** — DETERMINISTIC, never from the model. One entry per
  Bash tool_use whose command matches `test`/`lint`/`build`/`ci_read`
  (keyword/regex against the full command with heredoc BODIES removed —
  a heredoc is data, and a script whose text merely describes `cmd | head;
  echo $?` is not that defect; the stored command stays verbatim). Each entry
  carries its own command (capped ~600 chars head+tail), the output of its
  OWN matching tool_result (matched by `tool_use_id`; `output_present: false`
  and `output: null` — never `""` — when no tool_result exists at all), and
  two independent flags: `exit_masked_by_pipe` (a `$?` read whose
  IMMEDIATELY PRECEDING pipeline — splitting on `;` `&&` `||` newline —
  invokes a gate and pipes it through a truncating utility, with no
  `pipefail`/PIPESTATUS earlier in the command; per pipeline, because a
  whole-command check flagged `lint; echo "exit=$?"; swiftlint | tail -3`,
  which reads lint's real status) and
  `output_truncated` (pipes through a truncating utility at all, regardless
  of whether `$?` is read). These are NOT the same condition: `cmd; echo
  "exit=$?"` (no pipe) is neither; `cmd | tail -3` (no `$?` read) is
  `output_truncated` only; `set -o pipefail; cmd | tail; echo $?` is
  `output_truncated` but not `exit_masked_by_pipe`. `empty_ci_result` fires
  only for a `ci_read` entry whose OWN output shows an empty
  `statusCheckRollup` or "no checks reported" — never on missing output.
- **`gates_run`** / **`gates_named_not_run`** — per-category counts from
  `verifications[]`, and the categories the BRIEF names (trigger words) that
  have zero entries. Both deterministic.
- The distill call is handed all of this as a `--- VERIFICATION COMMANDS
  ---` prompt section and instructed to turn every entry whose result
  shaped the report or an intermediate decision into its own claim (kind
  `"verification"`, even when a later entry re-checked the same thing). It is
  told **not** to restate the gates fields as claims (#286): the #285 wording
  asked for an `"omitted-gate"` claim per named-not-run gate, and on the 8-run
  re-run 3 records made claims about the prompt's own sections ("no gates were
  named as not run", "no build commands were executed") with null proof, each
  then labelled `absence-without-second-search`. `verifications`/`gates_run`/`gates_named_not_run` are
  persisted on the record regardless of what the model actually returns.
- **`--resume` refuses a document written under a different
  `schema_version`** rather than mixing old-shape and new-shape records in
  one `records[]` list.

### #291 — the proof-locatable guard (schema_version 3)

A schema-valid but content-free response (`{asked: "test", ..., claims:
[{"proof": "test proof", ...}]}` against a real report) was recorded as a
successful distill with no trace anything was wrong. `build_tool_trace` now
also keeps, in memory only, `tool_inputs_full[]` — the FULL, untruncated,
whitespace-collapsed form of every tool_use `input`
(`tool_digest(input, head=10**9, tail=0)`) — never written into a record
(`run_stub_public` does not carry it). A claim's `proof` is **located**
when **every** piece of it occurs, in order, inside **one**
`tool_inputs_full` entry. Pieces: strip an optional `[N] ` index tag, then
an optional `ToolName: ` tag (the shape the model copies out of the TOOL
TRACE prompt's numbered `[i] Tool: digest` lines), drop everything from
the first ` -> ` on, unwrap a proof quoted whole, split at every
`...`/`…`, whitespace-collapse. Every piece counts because the model
elides mid-command (`cd .../skill-templates-frozen && ...`): the text
before the first elision is often just `cd`, which is in nearly every
trace. Pieces totalling under 8 characters locate only as a whole input,
so a fabricated `git` never passes. A result with `>=1` non-null
`proof` where **every** one is unlocatable is a FAILURE (`phase:
"distill"`, `error` prefixed `"proof-not-in-trace:"`), retryable like any
other distill-phase failure — **the chain call is never made for it**.
Otherwise every claim with a non-null `proof` gets `proof_located:
true|false` (`null` for a null `proof`) and `report` prints the
unlocatable-proof count/rate. A zero-claim or all-null-proof result is
**not** a failure by this guard — left as-is, since there is no non-null
proof for it to fail on.

Measured on the 8 real re-run records
(`~/Obsidian/no-it-all/records/session-distill-13cee7be-rerun-2026-09-21/`):
**4 of 211** real non-null proofs are unlocatable, and each differs
from the command that actually ran: two dropped a `| tail -4` (c29/c30
on main-turn-005), one wrote `tail -2` for `tail -3` (a963d9f8 c18), one
wrote `=="` for `==="` (main-turn-005 c2). None of the 8 records fails
the all-unlocatable test; the placeholder record's one proof is 1/1
unlocatable. A first-piece-only matcher reported 2 of 211, but only
because a piece like `cd` matched vacuously.

### #295 — the trace-index proof contract (schema_version 4)

#291's locator matched a model-WRITTEN `proof` string, and the model writes
it in whatever style a sample settles on: ` → output`, ` ... output: …`,
a `[N]` prefix, stripped double quotes. On session `13cee7be` the same
run's unlocatable rate swung 0–89% between samples, mostly from separator
styles the locator did not strip rather than from real paraphrase.

The model no longer writes `proof`. Each claim returns **`proof_index`**
(the `[N]` of the TOOL TRACE entry) and **`proof_snippet`** (a short
fragment copied verbatim from that entry's command). Then:

- `proof` is **derived**: `tool_inputs_full[proof_index]`, head+tail
  excerpted at 300+300 characters like a verification's `command`, or
  `null` when the index is null or out of range. Anything the model put in
  a `proof` field is discarded, so a record's `proof` cannot be a paraphrase.
- `proof_located` is true iff the index is in range **and** the snippet
  occurs in **that** entry, using #291's piece matcher and 8-character
  floor. A real snippet cited against the wrong index is unlocatable, as is
  an index with no snippet.
- A claim **cites** a proof when it has a `proof_index`, a
  `proof_snippet`, or a legacy free-text `proof`. `proof_located` is `null`
  only for a claim that cites nothing. A legacy `proof` with no index
  counts as cited and never locates, so a placeholder that ignores the
  index contract still trips #291's all-unlocatable FAILURE.

This adds no model calls. The distill input is unchanged, and the output
is a short fragment instead of a full command string.

### #287 — repo-qualified `#N` retrieval

Two repos sharing an issue/PR number turned an unrelated later mention
into a false `later_wrong` (measured on session `13cee7be`: Aeolus and
skill-templates both had a `#264`). Retrieval now computes, per run, a
repo **set** from four STRONG qualified forms in its own brief/report/
tool inputs — `owner/repo#N`, the `github.com/owner/repo/(pull|issues)/N`
URL, a `gh ... -R|--repo owner/repo` flag, `git -C <path>`/`cd <path>`
under `.../Projects/<repo>` — plus its own cwd(s) mapped to a repo, plus
any bare mention of a repo NAME already in the **session-wide vocabulary**
(built from those same four strong forms across every run, before any
per-run set is computed). A bare mention never seeds the vocabulary,
only ever resolves against it — otherwise "issue #250" would qualify
"issue" as a repo. Each `#N` occurrence then resolves to a repo: an
explicit qualifier attached to *that* occurrence wins (`owner/repo#N`,
a bare `repo#N`/`repo #N` when `repo` is already in vocabulary, or the
markdown-link `[#N](.../pull/N)` form); otherwise the run's own repo set
if it names exactly one; otherwise unresolved (ambiguous).

`find_chain_candidates` compares the claim side's resolution against each
candidate occurrence's: both resolved and **different** → not a
candidate; both resolved and **equal** → an ordinary candidate tagged
`repo_match: "same"`; **either side unresolved** → kept but tagged
`repo_match: "ambiguous"` (a non-`#N` artifact carries no repo concept
and is tagged `"n/a"`). The chain prompt prints every candidate's tag and
tells the model an `"ambiguous"` one cannot alone support a `later_wrong`
or a label — enforced deterministically in code regardless: a
`later_wrong` entry whose `contradicted_by.run` is linked to this run's
claims **only** through `"ambiguous"`-tagged candidates is dropped
and persisted on the record as `later_wrong_withdrawn[]`
(`{"claim", "run", "index", "reason": "repo-ambiguous-only"}`, `index`
being the model's raw `later_wrong` position), as well as warned on
stderr. Any `classified_as` entry whose `supports` named a withdrawn
index is dropped **whole**, even when it also names a claim: on
`13cee7be` an `outcome-not-reason` on c61 cited both c61 and the false
LW1, and its surviving claim pointer would otherwise have kept a label
whose only reasoning was the withdrawn contradiction.

Ambiguity needs a second repo: when the session-wide vocabulary names at
most one repo, an unresolved `#N` is tagged `"same"`, not `"ambiguous"`,
so a single-repo session loses no `later_wrong` to a run whose cwd lies
outside `~/Projects`.

Verified against session `13cee7be`'s real data: `agent-a125a8c132b05b56c`
(the Aeolus run whose false `later_wrong` LW1 filed this issue) resolves
to repo set `{Aeolus}`; `main-turn-024` resolves to `{Aeolus,
skill-templates}` (ambiguous — it discusses both repos); `main-turn-020`'s
set includes `skill-templates` (named only in an Agent tool_use prompt,
never in its own brief/report text); `main-turn-023` resolves cleanly to
`{Aeolus}`. Running real retrieval, `main-turn-024` still appears as a
candidate for `agent-a125a8c132b05b56c`'s claims (its own `#264`/`#262`
mentions are genuinely near a correction cue), but every one of its
candidates is tagged `"ambiguous"` — so a `later_wrong` citing it alone,
like the original LW1, is now dropped rather than recorded.

### #292 — round pairs (fix → delta)

Some defects live in the hand-off between runs, not inside one. Row 6 of the
#273 ground truth, "every fix round left a can't-fail assertion", is visible
only across two rounds: a fix round adds a test, and the delta review of that
round finds that the test cannot fail. A per-run distill of either run alone
has nothing to contradict, and cue-word retrieval rarely links them, so the
row appeared in zero of 160 records.

The pairing key is `description`, not `workflow_phase`. The phase is a
free-text label (`Fix`, `Fix 2`, `Fix2`), while the description carries
`fix<N>:<target>` / `delta<N>:<target>`, where a bare `fix` is round 1 and
targets compare exactly (`259a` ≠ `#259`, `Aeolus#260` ≠ `#260`).
`pair_rounds` pairs each delta with the **latest-started** same-key fix that
meets all of these:

- It **finished before the delta started**, so a fix still in flight cannot
  outrank the finished one.
- Its repo set is **not disjoint** from the delta's (the #287 hazard, checked
  here because a round-pair candidate is never withdrawn as ambiguous).
- It is in the **delta's own workflow** when any fix there qualifies.
  Pairing crosses workflows only as a fallback.

"Latest" matters because `13cee7be`'s `wf_30faad6a` holds two `fix:#259` and
two `delta:#259` interleaved. A delta that cannot be paired is reported with a
reason (`no-started-at`, `no-earlier-fix`, `no-finished-fix`,
`repo-mismatch`, `ambiguous-latest-fix`) and is never guessed.

The fix run's chain call then gets the paired delta's whole report as a
guaranteed candidate (`source: "round-pair"`, naming every claim). Its
`repo_match` is `"same"` only when both runs' repo sets resolved and intersect,
and `"n/a"` otherwise, because the link is the pairing, not an `#N` match.
Neither value triggers the #287 withdrawal. The report is capped at one head+tail budget per fix, split
across its deltas. It supersedes any cue-word hit from the same delta run and
adds no model call. `runs` and `distill` both write the result under
`round_pairs: {pairs[], unpaired_deltas[]}`.

**Measured on `13cee7be`.** All 20 deltas pair. The first live run, on
`fix:#253`, surfaced row 6 directly: claim c13b ("the NDJSONTests suite
passed") is contradicted from `delta:#253`, whose report says the new test
"cannot fail for any mutation of the behaviour it was added for". The same run
found three more vacuous-test contradictions.

### #298 — brief-as-claims (schema_version 6)

The other between-runs defect runs the other way, and row 5 of the #273 ground
truth is its shape: three of four client-test issues were **partly already
fixed** by #237/#254 when the brief for `a125a8c1` was written. The worker got
it right — its report says #256 was "largely already landed in #254" and #239's
first site "was already fixed by #237" — so a per-run distill of the worker has
no claim of its own to label. The defect belongs to the main-thread turn that
wrote the brief **from memory**, and nothing in the record pointed there.

**A spawned run's brief is not written by the run that receives it.** Its
factual assertions about repo state ("#250 is open", "two tests release the
harness at `HelperClientTests.swift:172-173`") are the spawning run's claims.
`--brief-claims` extracts them, one model call per spawned run, and attributes
them to the owner.

**The owner mapping is an exact join, not a time window.** Two routes, each
citing a real id, both measured on `13cee7be`:

| route | key | resolved |
|---|---|---|
| direct subagent | its own `.meta.json`'s `toolUseId` → the `Agent` tool_use line | 15 of 15 |
| workflow subagent | `spawned_by` runId → the `Workflow` tool_result announcing `.../workflows/<runId>` | 118 of 118, via 11 announcements |

The owner is the main turn whose span contains that line. **133 of 133 subagent
runs resolve; 0 unowned.** A time window was the obvious rule and is wrong for
the same reason the round-pair key is `description`: a background Agent can
outlive the turn that launched it, and two turns can have agents in flight at
once. The announcement scan is restricted to **spawning** tool_results, which
is load-bearing rather than defensive — on `13cee7be` a later `Bash` call cats
two workflows' journals by path, and an unfiltered scan offered those two a
second, spawn-less candidate each. A runId announced by two different spawning
calls is reported `ambiguous-workflow-announcement`, never resolved by picking
one. `runs` and `distill` both write `spawn_links: {links[], unowned[]}`
whether or not the pass is run: the mapping is deterministic and free, so it
can be audited without paying for the extraction.

Each brief's claims are namespaced `b<k>.<id>` (k being the spawned run's
position in its owner's spawn list) and land on the owner's record as
`brief_claims[]` — **never folded into `claims[]`**, which stays what this run's
own report asserted. The spawned run's whole report reaches the owner's chain
call as a guaranteed candidate (`source: "brief-as-claims"`, `repo_match:
"n/a"` — the link is the spawn, not an `#N` match), on one head+tail budget
split across the owner's spawned runs.

**Cost, measured rather than estimated.** The issue's basis was "one extra
distill-style call per spawned run"; a brief call is handed the **brief only**
— no report, no tool trace — so it is far cheaper than a distill call. On
`13cee7be` `main-turn-023` (2026-09-22): 9 brief calls, **$0.459 total,
$0.051 each**, against $0.688 for that run's own distill call and $0.400 for
its chain call. The call COUNT is still real — 133 extra calls session-wide,
320 → 453 — which is why the pass is opt-in and `--dry-run` counts brief calls
from the owner map (one per *spawned* run, not one per selected run) and prints
them apart.

**Measured on `13cee7be`, live.** `main-turn-023` came back with three
`recalled-not-reopened` labels, each on a brief claim and each cited from the
run that received the brief: `b1.c10` from `a125a8c1` ("#239's line numbers and
half its scope were stale"), and `b2.c3`/`b2.c8` from `a1794d4c` ("three was an
undercount; it is seven"). The worker records stay clean, which is the point —
the workers were right.

**Row 1a is NOT handled here, and the reason is measured.** `a55f340b`'s brief
never names lint, so `gates_named_not_run` cannot fire. The obvious extension —
inherit the gate names from the OWNER's brief or workflow script — was tested
against the data and does not work: that run's owner is the `Workflow` call at
main transcript line 1969, whose 16,797-character script mentions lint **zero**
times. The gate is absent from the whole spawn chain, so no reading of it can
recover the gate. It needs the CI config (`.github/workflows` job names), which
is a filesystem dependency at distill time over a repo whose state has since
moved, and is split out as its own issue.

### The five fields the issue names, and the two it does not

`asked` / `understood` / `delivered` / `later_wrong[]` / `classified_as[]` are the
issue's. Two more earn their place:

- **`claims[]`** is the join column. `later_wrong` has to point at SOMETHING in
  `delivered`, and a free-text "delivered" paragraph has no addressable parts. It
  is also what makes the chain pass cheap: claim text yields the artifacts
  (PR/issue numbers, paths, commands) that the retrieval filter searches for.
- **`classified_as[]` holds objects, not bare strings.** A label with no pointer
  to the claim or contradiction that justifies it is exactly the unauditable
  output this epic exists to remove — and #272's gate ledger wants the evidence
  chain, not the label. `[c["label"] for c in classified_as]` is still the label
  list. **Code-enforced:** a label whose `supports` names no claim id and no
  `later_wrong` index is dropped, not emitted.

## The closed vocabulary (exactly the checklist; 8 + 1)

| label | the checklist line |
|---|---|
| `absence-without-second-search` | stated an absence without a second, differently-shaped search |
| `plural-from-one-check` | wrote a plural ("all", "every", "both") when one thing was checked |
| `proxy-as-thing` | reported a proxy as the thing (an exit code for the work being good; a grep for the repo) |
| `green-as-done` | treated green as done; left the unverified less prominent than the passing |
| `outcome-not-reason` | checked the outcome, not the reason — a right action for a wrong reason survives into the record |
| `recalled-not-reopened` | recalled the artefact instead of re-opening it |
| `consumers-unfound` | changed a field without finding every consumer |
| `letter-not-goal` | read the letter of the goal instead of restating it |
| `unclassified` | anything else. Never an invented label. |

**Enforced in code, not in the prompt.** The `--json-schema` handed to the model
carries the enum, AND the returned document is re-checked against the same
frozen tuple before it is written; an off-vocabulary label is replaced by
`unclassified` with the offending string recorded in `unclassified_reason`. A
prompt that asks for a closed set and a script that trusts the answer is the
proxy-as-thing failure, written into the tool that detects it.

**Defined in the prompt, every label, from one table** (#286). The table above
is the checklist; the model reads `LABEL_DEFINITIONS` in `session-distill.py`,
one line per label, rendered into the chain prompt's `LABELS` section. The
first proof run taught the model only `proxy-as-thing`, and taught it as any
`| tail` before an exit read, so the label landed on 127 of 160 runs (79%) and
a class hit carried no information. `proxy-as-thing` is now a stand-in *signal*
— an exit status that belongs to another program, which the deterministic
`exit_masked_by_pipe` flag marks and the chain prompt lists, or a status field
read as the work's state. `cmd | tail -30` used only to read output is named
as *not* the label. A claim with no evidence defect gets no label at all.

**Every `later_wrong` entry is classified, or says it is not.** A contradiction
the chain found and never labelled was silent (row 4, `main-turn-005`
`later_wrong[2]`/`[3]`). Enforcement now appends an `unclassified` entry for
each uncovered index, with `why: "later_wrong[N] was not classified by the
model"`, and names it in `unclassified_reason`. A label entry dropped for an
unresolvable pointer covers nothing.

**Read a class hit against its base rate.** `report` prints, per label, the
entry count, the number of runs carrying it, and that share of all runs.
"The right run carries the label" means little when 79% of runs do.

## Three passes, one model boundary (four with `--brief-claims`)

1. **`runs`** — deterministic inventory. No model. Walks the session dir, emits
   one run stub per run with provenance, the brief, the report, and a compact
   work trace (per tool call: tool name, a one-line argument digest, whether it
   errored). Fully offline, so this is what the fixture test exercises.
2. **`distill`** — one model call per run: stub -> `{asked, understood, delivered, claims[]}`,
   guarded by #291's proof-locatable check before any chain call is made (see
   above).
3. **`brief`** (#298, `--brief-claims` only) — one model call per run THIS run
   spawned, over that run's BRIEF alone: `{claims[]}`, the repo-state assertions
   the owner made. Charged to the owner, because the owner wrote them.
4. **`chain`** — per run, deterministic retrieval first: pull the artifacts named
   in each claim (`#\d+`, paths, commands, symbols), scan every run that STARTED
   LATER for a mention of the same artifact within a correction cue window
   (`actually`, `in fact`, `wrong`, `retract`, `never ran`, `failed`, `turns
   out`, `correction`, `misread`, `regression`), repo-qualifying every `#N`
   match along the way (#287, see above), plus, for a fix round, its paired
   delta review's whole report (#292, see above), plus, for a run that spawned
   others, each spawned run's whole report against that run's brief claims
   (#298, see above), then ONE model call per run over
   the candidates -> `later_wrong[]` + `classified_as[]`. Retrieval-before-model
   is what keeps this O(n) calls instead of O(n^2).

## The model boundary is a command, so the tests never call a model

`--model-cmd` defaults to the verified invocation

```
claude -p --model sonnet --tools "" --safe-mode --strict-mcp-config
  --no-session-persistence --system-prompt <prompt> --json-schema <schema>
  --output-format json
```

Measured 2026-09-20: $0.0075/call with these flags, $0.11 without
(`--safe-mode` drops the ~26K-token CLAUDE.md + hook preamble). The prompt goes
in on stdin; `result` in the JSON envelope is the model's JSON as a string.
`.test.sh` points `--model-cmd` at a fixture script that echoes a canned
envelope — so the tests are hermetic and CI never spends a cent.

## Commands

```
session-distill.py schema
session-distill.py runs    [--session SID] [--json]
session-distill.py distill [--session SID] [--limit N] [--only RUNID]
                           [--dry-run] [--resume] [--out PATH] [--force]
                           [--brief-claims]
                           [--model-cmd CMD] [--max-cost-usd N] [--timeout-secs N] [--jobs N]
session-distill.py report  [--session SID] [--in PATH] [--json]
```

- Output: ONE session-level document, `<session-dir>/session-distill.json`
  (atomic write, `--force` to overwrite, `--out -` to stdout). Session-level
  rather than review-result.py's per-agent sidecar because main-turn runs have no
  sidecar to sit beside, and #270 wants one file per session, not 144.
- `--dry-run` prints the inventory, the call count and the projected cost and
  calls nothing. With 144 runs in the validation session, a blind `distill` is a
  ~$2 surprise; it should be an informed one.
- Session id resolution, the `/` and `..` refusal, the exactly-one-match session
  directory rule and the two sidecar levels are review-result.py's, imported
  rather than restated (the second-derivation rule).

## Acceptance (the issue's, plus the plan's item 7)

- [ ] one record per run, both kinds
- [ ] labels exactly the nine above; an off-vocabulary label becomes
      `unclassified` and is recorded, never invented, never passed through
- [ ] a label with no `supports` is dropped
- [ ] `.test.sh` with a fixture transcript and a stub model; CI step by name
- [ ] run over `13cee7be`: EVENT A (pipe exit code -> "gate clean") comes back
      `proxy-as-thing`, EVENT B (the false freeze) comes back
      `absence-without-second-search` — found by the tool, not by the operator

## Measured on the validation session (13cee7be), not assumed

- 133 subagent runs: 15 directly under `subagents/`, 118 under
  `subagents/workflows/<runId>/` across 11 workflow runs. **Corrected**: this
  first read 144/129, from a `find -name '*.jsonl'` that also matched the 11
  `journal.jsonl` workflow journals — a glob counted as if it were the
  population, which is `proxy-as-thing` in the document that defines it. 133
  also reconciles with the "118 of 133 agents" #267 measured independently.
  The tool's own inventory caught this, not its author.
- **Main-turn segmentation has a clean discriminator, and the obvious one is
  wrong.** A main-transcript `type:"user"` line is a HUMAN prompt iff
  `origin.kind == "human"` — 27 of them in this session. Filtering instead on
  "content is a string, not `isMeta`, not `isSidechain`" (the obvious rule)
  returns 61, of which 34 are harness traffic: `<task-notification>` blocks
  (28 of them, carrying `origin.kind == "task-notification"`), pasted terminal
  scrollback, and the compaction continuation message. A distiller that treats
  a task-notification as a user brief invents a run that nobody asked for.
- `origin` is absent on the other 468 user lines (tool results, older-format
  lines), so the rule is: **use `origin.kind` when the key is present anywhere
  in the transcript; fall back to the content-shape filter only for a
  transcript that carries no `origin` at all**, and say which rule was used in
  the run stub (`segmented_by: "origin" | "shape"`). Silently switching rules
  is how two sessions become incomparable.
- The harness prepends `<system-reminder>…</system-reminder>` to a genuine
  human prompt (the first turn here is one), so those blocks are stripped from
  `asked` — stripped, not dropped: the turn is real.
- Run total for this session: 133 + 27 = **160 runs, ~320 model calls, ~$2.40**
  at the measured per-call cost. That is why `--dry-run` prints the projection
  before anything is spent.

## Hand-filled examples, from verified transcript text

Three targets, not two. The plan's ground-truth table compresses Event A into
one row that does not survive reading the transcript (see "Ground truth
corrected" below), so the acceptance names the runs and quotes outright.

### A1 — the proxy pattern, real but NOT causal
run `agent-a353ff10516b7b760` (general-purpose, sonnet, "Fix Aeolus 259 CI lint
failure"), transcript line 67-69, 2026-09-20T01:26:30Z:

```json
{
  "run": {"id": "agent-a353ff10516b7b760", "kind": "subagent", "spawned_by": "session",
          "agent_type": "general-purpose", "model": "sonnet"},
  "delivered": "Re-ran the swift-format lint gate and reported it passing, then moved on to swiftlint.",
  "claims": [
    {"id": "c1", "text": "the swift-format lint gate passes", "kind": "verification",
     "proof": "swift format lint --recursive --strict Sources Tests Tools 2>&1 | head -50; echo \"EXIT=$?\"  ->  EXIT=0",
     "quote": "Lint passes now. Let's also run swiftlint per CI."}
  ],
  "later_wrong": [],
  "classified_as": [
    {"label": "proxy-as-thing", "supports": ["c1"],
     "why": "EXIT=0 is head's exit status, not swift-format's; the pipeline's last command is the pager. The claim is read off a proxy even though the proxy happened to agree here."}
  ]
}
```

**`later_wrong` is empty and that is the point.** swift-format's output really
was empty at that moment, and the same run re-verified later with the unpiped
form. The label is earned by the METHOD, in-run, with no later contradiction —
which is why `classified_as` may not require a `later_wrong` entry.

### A2 — the causal misreport, which the table misses entirely
run `agent-a55f340b7fa566416` (workflow-subagent, sonnet, "fix2:259a", phase
`Fix2`, under `wf_8da22100-610`). It ran `swift build` + `swift test` and never
invoked swift-format or swiftlint at all, pushed 66f3196, then read
`gh pr view` 3-8 s after the push and reported:

> `pr=259 rebased=False suite=swift build clean; swift test full suite 1526/1526 passed … merge_state=BLOCKED (per gh pr view; state OPEN, reviewDecision empty — no CI checks reported yet on statusCheckRollup …)`

`classified_as`: `green-as-done` (a passing local suite delivered as done while
the lint gate was never run and is reported as merely "not yet reported") and
`proxy-as-thing` (an empty `statusCheckRollup` read as the state of CI, when it
only means CI had not started 3 seconds after a push).
`later_wrong[0].contradicted_by` is the delta reviewer `agent-a6c4dca678a782bf2`
(reviewer, opus, "delta:259a"): *"[critical] The delta commit fails CI's lint
gate on a line it added — the fix round reported CI as \"no checks reported
yet\""*, with `gh run view --job 105081509708 --log-failed` showing
`HelperClientConnectionTests.swift:212:109: error: [AddLines] add 1 line break`.

**A2 is the acceptance that matters**, because it is the one that can only be
found by CHAINING two different runs — the claim is in one subagent's report and
the contradiction is in another's, four minutes later. A1 is in-run and needs no
chain.

### B — the false freeze (main thread)
main turn at 2026-09-20T02:28:43Z asserts *"An 8.2x drop, as a clean step"* from
one table derived from one source (the weekly meter-readings file), and only
THEN says *"Let me corroborate against the 5-hour meter"* — which at
02:29:37Z reports *"The 5-hour meter confirms it independently … an 8.07x drop"*
while reading the SAME underlying sample file.

`classified_as`: `absence-without-second-search` — supported by the ordering
(assertion at 02:28:43, "corroboration" at 02:29:37) and by the retraction's own
verdict at 02:35:14Z: *"the 'two independent meters agreeing at 8.07x and 8.19x'
… was worthless corroboration, because both numbers came out of the same frozen
file."* `later_wrong[0].contradicted_by` is the 02:33:45Z main turn: *"That
settles it, and it means I was wrong — I need to retract the 8x finding
immediately."*

**Do not encode the un-retraction as the tool's target.** The chain has three
phases, not two: retraction at 02:33, then at 03:31 *"I was wrong to retract"*,
with the settled explanation being zero-spend flat periods PLUS a genuine plan
reset either side of the 40→4 step — not the "idle account" summary. A distiller
that must land on a single final truth would have to adjudicate that; it does
not. `later_wrong` records CONTRADICTIONS WITH THEIR TIMESTAMPS, and a later
entry can contradict an earlier one. The record is a chain, not a verdict.

## Ground truth corrected (do this before #273 can mean anything)

The plan brief's first table row reads: *"Lint verified through `cmd | head;
echo $?` → 124-char line into CI | proxy-as-thing"*. Read against the
transcripts, three parts of that are wrong:

- The run that broke CI (`a55f340b7fa566416`) **never ran a lint command at
  all** — the failure was an omitted gate plus a premature `statusCheckRollup`
  read, not an exit-code proxy.
- The `| head …; echo $?` instance is in a **different run**, three days later,
  and did not flip a real failure to a false pass.
- **"124-char line" is not in the evidence.** Every CI excerpt cites
  `HelperClientConnectionTests.swift:212:109` with `[AddLines]`, and the local
  reproduction shows 109 characters.

Two different runs, two different failure modes, merged into one row — which is
`recalled-not-reopened` in the table that exists to catalogue it. #273 diffs the
tool's output against this table, so an uncorrected row makes the proof
unfalsifiable: the tool would be marked wrong for being right.
