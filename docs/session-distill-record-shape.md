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

## The record (schema_version 2)

```json
{
  "kind": "session-distill-record",
  "schema_version": 2,
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
     "proof": "...or null when the report asserts without naming a check...",
     "quote": "...verbatim from the report..."}
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
  "distilled": {"at": "...Z", "model": "sonnet", "cost_usd": 0.0074, "passes": ["distill","chain"]}
}
```

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

- **`run.report_source`** — `"structured_output"` | `"harness_error"` |
  `"text"` | `"none"`, on EVERY run stub, both kinds. `structured_output`
  prefers the transcript's final `StructuredOutput` tool_use (report =
  its `input`, pretty-printed, with any final assistant text prepended).
  `harness_error` is a report matching a known harness cutoff/error prefix
  — kept, not discarded, but never silently treated as a real result. A
  main-turn's `report_source` is only ever `"text"`/`"none"` — main turns
  do not end in a `StructuredOutput` tool_use.
- **`verifications[]`** — DETERMINISTIC, never from the model. One entry per
  Bash tool_use whose command matches `test`/`lint`/`build`/`ci_read`
  (keyword/regex against the FULL command, not the digest). Each entry
  carries its own command (capped ~600 chars head+tail), the output of its
  OWN matching tool_result (matched by `tool_use_id`; `output_present: false`
  and `output: null` — never `""` — when no tool_result exists at all), and
  two independent flags: `exit_masked_by_pipe` (pipes through a truncating
  utility AND reads `$?` AND is unprotected by `pipefail`/PIPESTATUS) and
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
  `"verification"`, even when a later entry re-checked the same thing), and
  every `gates_named_not_run` category into a `"omitted-gate"` claim with
  `proof` null — but `verifications`/`gates_run`/`gates_named_not_run` are
  persisted on the record regardless of what the model actually returns.
- **`--resume` refuses a document written under a different
  `schema_version`** rather than mixing old-shape and new-shape records in
  one `records[]` list.

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

## Three passes, one model boundary

1. **`runs`** — deterministic inventory. No model. Walks the session dir, emits
   one run stub per run with provenance, the brief, the report, and a compact
   work trace (per tool call: tool name, a one-line argument digest, whether it
   errored). Fully offline, so this is what the fixture test exercises.
2. **`distill`** — one model call per run: stub -> `{asked, understood, delivered, claims[]}`.
3. **`chain`** — per run, deterministic retrieval first: pull the artifacts named
   in each claim (`#\d+`, paths, commands, symbols), scan every run that STARTED
   LATER for a mention of the same artifact within a correction cue window
   (`actually`, `in fact`, `wrong`, `retract`, `never ran`, `failed`, `turns
   out`, `correction`, `misread`, `regression`), then ONE model call per run over
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
                           [--model-cmd CMD] [--max-cost-usd N]
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
