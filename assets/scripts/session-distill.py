#!/usr/bin/env python3
"""Distill one session into a chain of asked -> understood/delivered ->
later-wrong records, one per RUN, classified against a closed vocabulary of
evidence-quality failure modes (#269, epic #266, design at
docs/session-distill-record-shape.md).

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/session-distill.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/session-distill.py schema
  python3 ~/.claude/scripts/session-distill.py runs    [--session SID] [--json]
  python3 ~/.claude/scripts/session-distill.py distill [--session SID] [--limit N] [--only RUNID]
      [--dry-run] [--resume] [--out PATH] [--force]
      [--model-cmd CMD] [--max-cost-usd N]
  python3 ~/.claude/scripts/session-distill.py report  [--session SID] [--in PATH] [--json]

THE UNIT OF ANALYSIS IS A RUN: a (brief -> final report) pair. Two kinds:
  * `subagent`  -- one `agent-<hex>.jsonl`, at EITHER sidecar level
    (`<session-dir>/subagents/` and `<session-dir>/subagents/workflows/
    <runId>/`). Brief = the FIRST `type:"user"` line's text. Report =
    review-result.py's `last_assistant_text` (the LAST `type:"assistant"`
    line's text blocks).
  * `main-turn` -- one user-prompt -> end-of-turn-assistant-text span of the
    MAIN transcript (`<session-dir>.jsonl`, the sibling of `<session-dir>/`).
    The main session is a run too, segmented by human turn, because a
    distiller that reads only `subagents/**` cannot see anything that
    happened on the main thread -- see MAIN-TURN SEGMENTATION below for why
    this is not scope creep.

REUSE, NOT RE-DERIVATION: session id resolution, the session-directory glob,
the two sidecar levels, and `last_assistant_text` are review-result.py's,
imported by path (the same pattern rework-lag.py uses for filed-from.py's
`parse_filed_from`) rather than re-implemented. If `assets/scripts/
review-result.py` is not next to this script, every command REFUSES (exit 2,
naming the missing sibling) rather than growing a second copy of session-
directory resolution -- the single thing most likely to make this drift from
review-result.py's own REFUSE discipline.

MAIN-TURN SEGMENTATION -- a clean discriminator, and the obvious one is
wrong. A main-transcript `type:"user"` line starts a turn iff
`origin.kind == "human"`. Filtering instead on "content is a string, not
`isMeta`, not `isSidechain`, and does not open with `<task-notification>`/
`<system-reminder>`/`<local-command`" (the obvious rule, used only as a
fallback -- see below) looks plausible but counts roughly 2x too many turns
on real data: measured on session 13cee7be, the `origin` rule found 27
turns; the shape rule found 61, of which 34 were harness traffic
(`<task-notification>` blocks, pasted terminal scrollback, a compaction
continuation message). A distiller that treats a task-notification as a
human brief invents a run nobody asked for.

`origin` is absent from OLDER-format transcripts entirely (tool-result
lines, and some full transcripts), so the rule actually applied is: use
`origin.kind` when the key is present ANYWHERE in the transcript; fall back
to the shape filter ONLY for a transcript that carries no `origin` key at
all. Which rule fired is recorded as `segmented_by: "origin" | "shape"` in
the session-level document and on every `main-turn` run stub -- silently
switching rules is how two sessions become incomparable.

A genuine human prompt commonly opens with an injected
`<system-reminder>...</system-reminder>` block (the harness's own
preamble). That block is STRIPPED, not dropped, from a main-turn's `asked`
text -- leading and trailing reminder blocks only; one embedded mid-prompt
(quoted back by the user) is left alone, and the turn itself is still real
even when every visible character was reminder boilerplate.

THE CLOSED VOCABULARY (exactly nine labels; see LABELS below) is enforced
TWICE, not once: the `--json-schema` handed to the model for the chain call
carries the label set as a JSON Schema `enum`, AND the document the model
returns is re-checked against the same frozen `LABELS` tuple before it is
written. An off-vocabulary label is replaced with `"unclassified"` and the
offending string is appended to that record's `unclassified_reason` --
never invented, never passed through as-is. Separately, a `classified_as`
entry whose `supports` list names neither an existing claim id nor a valid
`later_wrong` index is DROPPED entirely (not merely relabelled): a label
with no pointer to the evidence that earned it is exactly the unauditable
output this epic exists to remove.

THE MODEL BOUNDARY IS ONE FUNCTION AND ONE FLAG so the test suite never
calls a real model. `--model-cmd` defaults to the verified invocation

    claude -p --model sonnet --tools "" --safe-mode --strict-mcp-config
      --no-session-persistence --output-format json

(`--safe-mode` drops the ~26K-token CLAUDE.md + hook preamble; without it
the same call was $0.11/call in the flag-overhead comparison). The
$0.0075/call figure this docstring and DEFAULT_COST_PER_CALL_USD once
carried alongside it was measured on a ONE-TOKEN prompt and does not
survive a real run's payload -- measured on two REAL runs (#278 M2,
2026-09-20): $0.3349 and $0.3564 for one run's two calls, ~$0.167/call.
DEFAULT_COST_PER_CALL_USD is that corrected figure; see its own comment
for what it is and is not used for. This script
appends `--system-prompt <text>` and `--json-schema <json>` itself (the
system prompt and schema differ between the distill call and the chain
call, so they are not baked into the default string). The run's prompt goes
in on stdin; the command's stdout is parsed as the `claude -p
--output-format json` envelope, and the model's own JSON document is the
envelope's `result` field, itself a JSON *string* that must be parsed a
second time. `is_error: true` and a `result` that is not valid JSON are
each recorded as a per-run FAILURE (in the output document's `failures[]`)
and skipped -- never a crash, never a silently empty record.
`.test.sh` points `--model-cmd` at a fixture shell/python script that reads
the run id off stdin and echoes a canned envelope, so CI spends nothing.

TWO MODEL CALLS PER RUN: the `distill` command asks one call for
`{asked, understood, delivered, claims[]}`, then does deterministic
retrieval over the claims' artifacts (`#\\d+`, backtick-quoted spans, and
`path/like/this.ext` tokens) against every OTHER run that started later,
scanning for the same artifact near a correction-cue word ("actually",
"wrong", "retract", "never ran", "failed", "turns out", "correction",
"misread", "regression"), then makes ONE more call over the candidates for
`{later_wrong[], classified_as[]}`. Retrieval-before-model is what keeps
this O(n) calls instead of O(n^2) -- see docs/session-distill-record-shape.md's
"Three passes, one model boundary".

REPO-QUALIFIED `#N` RETRIEVAL (#287). A `#N` artifact is only a real
match when it names the SAME repo on both sides -- two repos sharing an
issue/PR number (measured on session 13cee7be: Aeolus and skill-templates
both had a #264) turned an unrelated later mention into a false
`later_wrong`. Retrieval computes, per run, a repo SET from four STRONG
qualified forms found in its own brief/report/tool inputs -- `owner/
repo#N`, the `github.com/owner/repo/(pull|issues)/N` URL, a `gh ...
-R|--repo owner/repo` flag, `git -C <path>`/`cd <path>` under `.../
Projects/<repo>` -- plus its own cwd(s) mapped to a repo, plus any bare
mention of a repo NAME already in the SESSION-WIDE vocabulary (built from
those same four strong forms across every run, before any per-run set is
computed) -- never the reverse: a bare mention resolves against the
vocabulary, it never seeds it, or "issue #250" would qualify "issue" as a
repo. Each `#N` OCCURRENCE then resolves to a repo: an explicit qualifier
attached to THAT occurrence wins; otherwise the run's own repo set if it
names exactly one; otherwise unresolved (ambiguous). `find_chain_
candidates` compares the claim side's resolution against each candidate
occurrence's: both resolved and DIFFERENT -> not a candidate; both
resolved and EQUAL -> an ordinary candidate, `repo_match: "same"`; either
side unresolved -> kept but tagged `repo_match: "ambiguous"` (a non-`#N`
artifact carries no repo concept and is tagged `"n/a"`). The chain prompt
prints every candidate's tag and is told an `"ambiguous"` one cannot
alone support a `later_wrong` or a label; `normalize_later_wrong` enforces
that DETERMINISTICALLY on the way out regardless of what the model does
with it -- a `later_wrong` entry whose `contradicted_by.run` is linked to
this run's claims ONLY through `"ambiguous"`-tagged candidates is dropped
(reason `"repo-ambiguous-only"`, surfaced the same way #278 C2's
unresolvable-claim drop is), which is exactly the reused evidence-chain
mechanism (#290) that also drops a `classified_as` entry whose sole
`supports` pointer named that now-gone index.

THE PROOF-LOCATABLE GUARD (#291). A schema-valid but content-free
response -- the model returns `{asked: "test", ..., claims: [{"proof":
"test proof", ...}]}` against a real report -- was recorded as a
successful distill with no trace of anything being wrong. Deterministic,
after the distill call and BEFORE the chain call (so a placeholder result
never reaches it): `build_tool_trace` keeps, alongside the truncated
`trace[]`, the FULL untruncated one-line form of every tool_use `input`
(`tool_digest(input, head=10**9, tail=0)`, in-memory only as `tool_inputs_
full` on the run stub -- never written into a record; `run_stub_public`
does not carry it). A claim's `proof` is "located" when EVERY piece of
it (proof_segments: `[N] `/`ToolName: ` prefixes stripped, output after
` -> ` dropped, split at each `...`/`…`) occurs in order inside ONE entry
of `tool_inputs_full`; pieces totalling under PROOF_MIN_FRAGMENT_CHARS
locate only as a whole input.
A result with >=1 non-null `proof` where EVERY one is unlocatable is a
FAILURE (`phase: "distill"`, `error` prefixed `"proof-not-in-trace:"`),
eligible for retry like any other distill-phase failure, and the chain
call is never made for it. Otherwise every claim with a non-null `proof`
gets `proof_located: true|false` (null for a null `proof`) on the written
record, and `report` prints the unlocatable-proof count/rate. Measured on
the 8 real re-run records at `~/Obsidian/no-it-all/records/session-
distill-13cee7be-rerun-2026-09-21/`: 4 of 211 real non-null proofs are
unlocatable, each a real misquote of the command that ran (a dropped
`| tail -4` twice, `tail -2` for `tail -3`, `=="` for `==="`); the
placeholder record's one proof is 1/1 unlocatable. A zero-claim or all-null-proof result is NOT a failure
by this guard -- there is no non-null proof for it to fail on, and this
script does not otherwise police that (left as-is; #269/#285's own model-
side labels are the mechanism for an empty or thin claims list).

THE RECORD (schema_version 3), one per run, appended to
`session-distill.json`'s `records[]`:

  kind                  const "session-distill-record".
  schema_version        int, currently 3 (bumped from 2 by #291 -- each
                         claim now carries `proof_located`, see THE
                         PROOF-LOCATABLE GUARD below. schema_version 2 was
                         bumped from 1 by #285 -- see REPORT EXTRACTION AND
                         DETERMINISTIC VERIFICATIONS below for what that
                         changed. `--resume` against an existing document
                         written under a different schema_version REFUSES
                         rather than mixing record shapes in one records[]
                         list).
  session               the session id.
  run                   provenance + shape, NOT the full brief/report text
                         (that stays in the transcript the `transcript`
                         field points at): id, kind ("subagent" |
                         "main-turn"), spawned_by ("session" | a workflow
                         runId | null for main-turn), agent_type, model,
                         description, workflow_phase, started_at, ended_at,
                         transcript (abs path), brief_chars, report_chars,
                         report_source, tool_calls, and (main-turn only)
                         segmented_by. `report_source` is one of
                         "structured_output" | "structured_output_rejected" |
                         "harness_error" | "text" |
                         "none" -- see below.
  asked / understood /
  delivered             free-text, from the distill call.
  claims[]              the join column: {id, text, kind, proof, quote,
                         proof_located}. `later_wrong` and `classified_as`
                         both point at a claim id, which is what makes a
                         `classified_as` label auditable rather than a
                         bare string. `kind` is free text; the distill
                         call is instructed to use "verification" for a
                         claim resting on a VERIFICATION COMMANDS entry.
                         It is told NOT to restate gates_run/
                         gates_named_not_run as claims (#286: 3 of 8
                         re-run records did, each drawing a spurious
                         absence label). `proof_located` (#291) is
                         True/False for a non-null `proof` (whether its
                         elided pieces all occur, in order, in one of
                         this run's own full tool inputs), or
                         null for a null `proof` -- see THE PROOF-
                         LOCATABLE GUARD below.
  verifications[]        DETERMINISTIC, never from the model -- one entry
                         per Bash tool_use, classified into zero or more of
                         test/lint/build/ci_read (see REPORT EXTRACTION AND
                         DETERMINISTIC VERIFICATIONS below). Persisted on
                         every record regardless of what the model returns.
  gates_run              {"test": n, "lint": n, "build": n, "ci_read": n} --
                         per-category counts from verifications[].
                         Deterministic.
  gates_named_not_run    [category, ...] -- categories the BRIEF names
                         (trigger words) that have zero verifications[]
                         entries. Deterministic.
  later_wrong[]          {claim, how, contradicted_by: {run, at, quote}}.
                         CONTRADICTIONS WITH THEIR TIMESTAMPS -- a later
                         entry can contradict an earlier one; this is a
                         chain, not a verdict, and no pass here adjudicates
                         a single final truth.
  classified_as[]        {label, supports[], why} -- label is always one of
                         LABELS after enforcement; supports[] names claim
                         ids and/or later_wrong indices (as digit strings).
  unclassified_reason    string or null -- set exactly when an off-
                         vocabulary label was corrected to "unclassified"
                         for this record; the offending label text.
  distilled              {at, model, cost_usd, passes: ["distill"] or
                         ["distill","chain"]}.

REPORT EXTRACTION AND DETERMINISTIC VERIFICATIONS (#285). Hand-reading a
real session's distilled payloads (issue #285's diagnosis comment) found
108 of 160 runs distilled with a silently EMPTY report: a workflow
subagent's real result lands in a final `StructuredOutput` tool_use's
`input`, not a text block, and review-result.py's `last_assistant_text`
(reused here for its own REUSE discipline, and NOT changed by this fix --
`review-result.py harvest` also depends on its exact semantics) reads only
text blocks of the last assistant line, so it returns None there and the
OLD stub silently stored "". Two things follow:

  * `extract_report(objs)` prefers the transcript's FINAL StructuredOutput
    tool_use (the last one anywhere in the file) when one exists: the
    report becomes that tool_use's `input`, pretty-printed JSON
    (`ensure_ascii=False`), with any final assistant TEXT prepended (text
    first) when the last assistant line also carries a text block.
    `report_source` is "structured_output". Absent a StructuredOutput, the
    ordinary last-assistant-text extraction applies; if that text matches a
    known harness cutoff/error prefix (a session-limit message, an API
    error) -- the run was cut off, and distilling claims from it would be a
    verdict from incomplete data -- `report_source` is "harness_error" and
    the text is KEPT, not discarded. Otherwise `report_source` is "text",
    or "none" when nothing was found at all. `report_source` is set on
    EVERY stub, both kinds -- a main-turn's is only ever "text" or "none"
    (a main turn's report is still the join of every assistant text block
    in its span; main turns do not end in a StructuredOutput tool_use).
  * `verifications[]` is built once per run, from the SAME parsed objs, by
    classifying every Bash tool_use's command into zero or more of `test`,
    `lint`, `build`, `ci_read` (keyword/regex match against known
    invocations -- swift test/npm test/pytest/go test/cargo test/xcodebuild
    test/node --test/*.test.sh for test; swift format lint/swiftlint/
    eslint/ruff/flake8/shellcheck/npm run lint for lint; swift build/npm
    run build/tsc/cargo build/xcodebuild build/make for build; `gh pr
    checks`, `gh run view|list|watch`, or a `gh pr view` whose --json names
    statusCheckRollup/mergeStateStatus for ci_read). Each entry carries its
    own full command (capped ~600 chars head+tail, never the digest), the
    OUTPUT of its OWN matching tool_result (matched by tool_use_id, capped
    ~400 chars head+tail; `output_present: false` and `output: null` --
    never "" -- when no tool_result exists at all, so a missing result is
    never confused with a genuinely empty one), and two independent flags:
    `exit_masked_by_pipe` (the command pipes through a truncating/
    filtering utility -- head/tail/grep/sed/awk/cut/sort/uniq/wc -- and
    then reads `$?` without `set -o pipefail`/PIPESTATUS protecting it) and
    `output_truncated` (the command pipes through one of those utilities at
    all, independent of whether `$?` is read or protected). These two
    flags are NOT the same condition and must not be conflated: `cmd; echo
    "exit=$?"` with no pipe is neither; `cmd | tail -3` with no `$?` read
    is `output_truncated` only; `set -o pipefail; cmd | tail; echo $?` is
    `output_truncated` but NOT `exit_masked_by_pipe`, because pipefail
    protects the exit code even though the OUTPUT is still truncated.
    `empty_ci_result` fires only for a `ci_read` entry whose OWN output
    text shows an empty `statusCheckRollup` (`"statusCheckRollup":[]`) or
    "no checks reported" -- never when the output is missing
    (`output_present: false`), which would itself be a verdict from data
    that was never read. `gates_run` is the per-category count from
    verifications[]; `gates_named_not_run` is every category whose trigger
    words appear in the BRIEF but has zero verifications[] entries. All
    three (verifications, gates_run, gates_named_not_run) are computed once
    in `build_all_run_stubs` (deterministic, no model call) and persisted
    on every record verbatim -- the distill model call is handed them as a
    `--- VERIFICATION COMMANDS ---` prompt section and instructed (in
    DISTILL_SYSTEM_PROMPT) to turn every verification whose result shaped
    the report or an intermediate decision into its own claim, and never
    to restate the gates fields as claims of its own -- the persisted verifications[]/gates_run/
    gates_named_not_run fields never depend on what the model returns.

WHAT `runs` REFUSES TO GUESS, and what it does not guess at all: session id
resolution and session-directory resolution are review-result.py's (see
REUSE above) -- an unset session id, an ambiguous session directory, or a
missing `review-result.py` sibling are all REFUSE, nothing is read.

AN UNREADABLE OR UNPARSEABLE MAIN TRANSCRIPT IS NEVER A SILENT ZERO
(#278 C1). A main transcript that cannot be opened (permissions, missing
mid-read) or that yields zero parsed lines (empty, or every line fails
JSON) previously produced the exact same output as a healthy session with
no main-thread turns at all -- `segmented_by` even asserted a rule
("shape") that never ran. Now: `segmented_by` is `null`, never a rule
name, whenever no line was ever successfully read; the failure (or the
count of unparseable lines dropped along the way, even from an otherwise
readable file) is appended to an `unreadable[]` list carried on BOTH the
`runs` and `distill` documents; a warning is printed to stderr per entry;
and the command's exit code is forced to 2 (the JSON is still emitted in
full, same discipline as rework-lag.py's `unknown[]`) -- see Exit codes
below. A main transcript that is simply ABSENT (no `.jsonl` sibling at
all -- a session with no main thread) is not an error: `segmented_by`
stays `null` and nothing is added to `unreadable[]`, because no rule was
supposed to run.

`--dry-run` prints the run inventory, the projected call count (2 per run
still to process), and a projected cost, and calls nothing -- with ~170
runs in a real validation session, a blind `distill` is a multi-dollar
surprise; `--dry-run` makes it an informed one. The projection's basis is
printed alongside the number (#278 M2) rather than left as a bare figure:
DEFAULT_COST_PER_CALL_USD until at least one real call has been made this
invocation, after which the projection recalibrates to this run's own
OBSERVED average cost per call -- a session's real payloads (long reports,
long tool traces) are not the one-token prompt that constant was
originally measured on, so a fixed guess converges toward truth only by
being replaced with a measurement.
`--resume` skips any run id already present in an existing output
document's `records[]` (a previously FAILED run is retried, not skipped --
resume is for cost, not for silently giving up on a transient failure).
`--max-cost-usd N` checks the running total against N before every model
call (using the OBSERVED running average once one exists, never a stale
fixed estimate alone) AND immediately after every model call (using the
OBSERVED total_cost_usd, not a projection) -- recording
`stopped: {reason, at_run, budget, spent}` in the document -- rather than
either truncating the JSON silently or spending past the budget on the
strength of an estimate that was never checked against what the calls
actually cost.

OUTPUT: one session-level document, `<session-dir>/session-distill.json`
(atomic write via review-result.py's `atomic_write`), `--force` required to
overwrite an existing file outside of `--resume`, `--out -` for stdout
(never touches disk, and the overwrite check does not apply).

Exit codes:
  schema   always 0.
  runs     0, or review-result.py's own REFUSE code (1) for session-id/
           session-dir resolution, or 2 naming a missing review-result.py,
           or 2 (JSON still printed in full) when the main transcript
           could not be read or yielded zero parsed lines -- named in the
           document's `unreadable[]`, same discipline as rework-lag.py's
           `unknown[]`.
  distill  0 on completion (an early `--max-cost-usd` stop is still 0: it is
           an intentional, recorded stop, not a failure); 2 for this
           script's own REFUSE cases (missing sibling, `--only` matching no
           run, an existing output file without `--force`/`--resume`,
           `--resume` against a document written under a different
           schema_version -- #285, see THE RECORD below), or
           review-result.py's own REFUSE code (1) for session-id/session-
           dir resolution, or 2 (JSON still written in full) when the main
           transcript could not be read or yielded zero parsed lines --
           named in the document's `unreadable[]`.
  report   0, or 2 if the input document cannot be read.
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 3

# The closed vocabulary -- exactly the checklist, 8 + "unclassified". Frozen
# here and nowhere else: both enforcement points (the --json-schema enum
# and the post-hoc recheck) read this same tuple, so there is exactly one
# place a tenth label could be added by mistake.
LABELS = (
    "absence-without-second-search",
    "plural-from-one-check",
    "proxy-as-thing",
    "green-as-done",
    "outcome-not-reason",
    "recalled-not-reopened",
    "consumers-unfound",
    "letter-not-goal",
    "unclassified",
)

# One line per label, rendered into the chain prompt (#286). Before this the
# prompt DEFINED only proxy-as-thing -- the other seven reached the model as
# bare enum strings -- and it defined it as any `| tail` before an exit
# read, so every truncated read got it: 127 of 160 runs (79%) on 13cee7be.
# A label the model is taught and seven it is not is a base-rate, not a
# finding. Keyed by LABELS; the test suite checks the two agree exactly.
LABEL_DEFINITIONS = {
    "absence-without-second-search":
        "stated that something is absent, not happening, or not there "
        "(no checks, no callers, frozen, nothing changed) from ONE look, "
        "without a second, differently-shaped search.",
    "plural-from-one-check":
        "wrote a plural (all, every, both, none) when one instance was checked.",
    "proxy-as-thing":
        "reported a STAND-IN signal as the thing itself: an exit status that "
        "belongs to a different program (a gate piped into head/tail/grep "
        "and then `$?` read -- the VERIFICATION FLAGS section marks these as "
        "exit_masked_by_pipe), or a status field read as the work's state "
        "(an empty statusCheckRollup read as 'CI is fine'). NOT this label: "
        "`cmd | tail -30` used only to READ output, with the conclusion "
        "drawn from the lines shown -- truncated reading is not a proxy.",
    "green-as-done":
        "treated a passing check as the task being done, or left what was "
        "not verified less prominent than what passed.",
    "outcome-not-reason":
        "checked the outcome, not the reason -- a right result for a wrong "
        "reason survives into the record.",
    "recalled-not-reopened":
        "asserted the state of an artefact (issue, PR, file, earlier fix) "
        "from memory or an earlier read instead of re-opening it.",
    "consumers-unfound":
        "changed a field, API, or behaviour without finding every consumer.",
    "letter-not-goal":
        "satisfied the literal wording of the ask while missing its goal.",
    "unclassified":
        "none of the above fits. Say why in `why`. Never invent a label.",
}

CORRECTION_CUES = (
    "actually", "in fact", "wrong", "retract", "never ran", "failed",
    "turns out", "correction", "misread", "regression",
)
CUE_WINDOW_CHARS = 400

ARTIFACT_RE = re.compile(r"#\d+|`[^`\n]{2,80}`|(?:[\w.-]+/)+[\w.-]+\.\w+")

REMINDER_OPEN = "<system-reminder>"
REMINDER_CLOSE = "</system-reminder>"

# #287: repo-qualification for `#N` artifacts in multi-repo sessions. Four
# STRONG forms SEED the session-wide repo vocabulary (build_repo_vocabulary):
# `owner/repo#N`, the `github.com/owner/repo/(pull|issues)/N` URL, a
# `gh ... -R|--repo owner/repo` flag, and `git -C <path>`/`cd <path>` under
# `.../Projects/<repo>`. A BARE name mention or a bare `repo#N`/`repo #N`
# never seeds the vocabulary -- only ever resolves against a name already in
# it (see compute_run_repo_set/resolve_hash_qualifier) -- or "issue #250"
# would qualify "issue" as a repo.
_REPO_QUALIFIED_HASH_RE = re.compile(r'\b([A-Za-z0-9][\w.-]*)/([A-Za-z0-9][\w.-]*)#(\d+)')
_REPO_URL_HASH_RE = re.compile(
    r'github\.com/([A-Za-z0-9][\w.-]*)/([A-Za-z0-9][\w.-]*)/(?:pull|issues)/(\d+)')
# `-R`/`--repo` is `gh`'s own flag -- `\bgh\b` must appear up to 60 chars
# before it, same line, or this also matches `grep -R <path>`, `cp -R`,
# `rsync -R`, none of which name a GitHub repo at all (measured on
# 13cee7be: `grep -R Sources/AeolusHelper` produced a false repo
# "AeolusHelper" without this guard).
_REPO_GH_FLAG_RE = re.compile(
    r'\bgh\b[^\n]{0,60}?(?:-R|--repo)[=\s]+([A-Za-z0-9][\w.-]*)/([A-Za-z0-9][\w.-]*)')
_REPO_GIT_C_CD_RE = re.compile(r'(?:git\s+-C\s+|cd\s+)\S*?/Projects/([A-Za-z0-9][\w.-]*)')
# A captured repo name never legitimately ends in sentence/bracket
# punctuation -- `--repo blamechris/skill-templates.` (end of a sentence)
# would otherwise mint the repo "skill-templates." (measured on 13cee7be).
_REPO_NAME_TRAILING_PUNCT = ".,;:)]}'\""


def _clean_repo_name(name):
    return name.rstrip(_REPO_NAME_TRAILING_PUNCT) if name else name

# A `#N` occurrence's own attached qualifier: `owner/repo#N` or a bare
# `repo#N`/`repo #N` immediately BEFORE it (`_TAIL_*`), or the markdown-link
# shape `[#N](https://github.com/owner/repo/(pull|issues)/N)` immediately
# AFTER it.
_TAIL_OWNER_REPO_RE = re.compile(r'([A-Za-z0-9][\w.-]*)/([A-Za-z0-9][\w.-]*)$')
_TAIL_BARE_NAME_RE = re.compile(r'([A-Za-z][\w.-]*)\s?$')

# cwd -> repo (#287): the slash form of a worktree path (`.../Projects/
# <repo>/...`) captures generically; the dash-joined form a session
# directory basename uses (`-Users-...-Projects-Aeolus--claude-worktrees-
# ...`) cannot be split unambiguously when a repo name itself contains a
# dash (`skill-templates`), so it is matched against already-KNOWN names
# instead of re-derived from the path alone.
_CWD_SLASH_PROJECTS_RE = re.compile(r'/Projects/([^/]+)')
_CWD_DASH_PROJECTS_RE = re.compile(r'-Projects-')

# #291: prefixes stripped from a `proof` before it is split into pieces
# (see proof_segments).
_PROOF_INDEX_PREFIX_RE = re.compile(r'^\[\d+\] ')
_PROOF_TOOL_PREFIX_RE = re.compile(r'^[A-Za-z_][\w-]*: ')
PROOF_MIN_FRAGMENT_CHARS = 8

# #285: known harness cutoff/error prefixes -- a report that opens with one
# of these was never a real result, it is the harness cutting the run off
# mid-flight (a session-limit message) or the model API itself erroring.
# Distilling claims from it would be a verdict from incomplete data, so
# `extract_report` records it as `report_source: "harness_error"` (the text
# is KEPT, never discarded -- the distill call is told what it is via
# REPORT_SOURCE in the prompt and can still note the cutoff itself).
# "You've hit your" rather than "...session limit": the same cutoff arrives
# worded "weekly limit" too, and on 13cee7be four of eight cutoffs used that
# wording -- a prefix list keyed on one meter's name silently passed them
# through as source "text".
HARNESS_ERROR_PREFIXES = (
    "You've hit your",
    "API Error",
)

# #285: deterministic verification-command classification -- no model call.
# Each category's pattern is matched against the FULL command text (never
# the truncated digest), case-insensitively. A command can match more than
# one category (e.g. `xcodebuild build test`).
_VERIFY_CATEGORY_PATTERNS = {
    "test": (
        r'\bswift\s+test\b', r'\bnpm\s+(?:run\s+)?test\b', r'\bpytest\b',
        r'\bgo\s+test\b', r'\bcargo\s+test\b', r'\bxcodebuild\b[^\n]*\btest\b',
        r'\bnode\s+--test\b', r'\S+\.test\.sh\b',
    ),
    "lint": (
        r'\bswift\s+format\s+lint\b', r'\bswiftlint\b', r'\beslint\b',
        r'\bruff\b', r'\bflake8\b', r'\bshellcheck\b', r'\bnpm\s+run\s+lint\b',
    ),
    "build": (
        r'\bswift\s+build\b', r'\bnpm\s+run\s+build\b', r'\btsc\b',
        r'\bcargo\s+build\b', r'\bxcodebuild\b[^\n]*\bbuild\b',
        r'(?:^|[;&|])\s*make\b',
    ),
}
_VERIFY_CATEGORY_RE = {
    cat: re.compile("|".join(pats), re.IGNORECASE)
    for cat, pats in _VERIFY_CATEGORY_PATTERNS.items()
}
_CI_READ_CHECKS_RE = re.compile(r'\bgh\s+pr\s+checks\b', re.IGNORECASE)
_CI_READ_RUN_RE = re.compile(r'\bgh\s+run\s+(?:view|list|watch)\b', re.IGNORECASE)
_CI_READ_PR_VIEW_RE = re.compile(r'\bgh\s+pr\s+view\b', re.IGNORECASE)
_CI_READ_JSON_FIELD_RE = re.compile(r'statuscheckrollup|mergestatestatus', re.IGNORECASE)

# `exit_masked_by_pipe`/`output_truncated`: a command that pipes a
# test/lint/build/ci_read invocation through one of these before reading
# `$?` masks the ORIGINAL command's exit status with the truncating
# utility's -- unless `pipefail`/PIPESTATUS protects it (#285, #278 M1's
# `swift format lint ... | head -50; echo "EXIT=$?"` is the canonical
# instance: EXIT=0 is head's exit code, not swift-format's).
_TRUNCATING_PIPE_RE = re.compile(
    r'\|\s*(?:head|tail|grep|sed|awk|cut|sort|uniq|wc)\b', re.IGNORECASE)
# Enabling pipefail (`set -o pipefail`, `set -euo pipefail`, `set -e -o
# pipefail`) or reading PIPESTATUS -- not the bare word, which `echo
# pipefail` or a grep pattern would carry without protecting anything.
_PIPEFAIL_PROTECTED_RE = re.compile(
    r'\bset\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*o\s+pipefail\b|\bPIPESTATUS\b')
# List separators, never a lone `|`: `$?` is the status of the pipeline that
# ran last, so the mask check needs pipelines, not the whole command. Quote-
# unaware, and that cuts both ways: a separator inside a quoted string can
# split a real pipeline away from its `$?` (a miss), and a quoted "| tail"
# right before an `echo $?` reads as a pipe (a false hit). Both need quoting
# shapes that did not occur on 13cee7be; a shell parser is not worth it yet.
_SEGMENT_SPLIT_RE = re.compile(r'&&|\|\||;|\n')
_EMPTY_CI_RESULT_RE = re.compile(
    r'"statusCheckRollup"\s*:\s*\[\]|no checks reported', re.IGNORECASE)

GATE_CATEGORIES = ("test", "lint", "build", "ci_read")

# `gates_named_not_run`: a category whose trigger words show up in the
# BRIEF but has zero verifications[] entries. Word-boundary patterns, not
# bare substrings, so "latest" does not name the "test" gate.
_GATE_BRIEF_PATTERNS = {
    "test": re.compile(
        r'\btest(s|ing)?\b|\bswift\s+test\b|\bpytest\b|\bgo\s+test\b|\bcargo\s+test\b',
        re.IGNORECASE),
    "lint": re.compile(
        r'\blint(ing|er)?\b|\bswiftlint\b|\beslint\b|\bswift\s+format\b', re.IGNORECASE),
    "build": re.compile(
        r'\bbuild(s|ing)?\b|\bcompile[sd]?\b|\bxcodebuild\b', re.IGNORECASE),
    "ci_read": re.compile(
        r'\bci\b|\bstatuscheckrollup\b|\bmergestatestatus\b|\bpr\s+checks\b', re.IGNORECASE),
}

DEFAULT_MODEL_CMD = (
    'claude -p --model sonnet --tools "" --safe-mode --strict-mcp-config '
    "--no-session-persistence --output-format json"
)
# #278 M2: the original $0.0075/call here was measured on a ONE-TOKEN
# prompt and does not survive a real run's payload (a real brief + report +
# full tool trace). Measured 2026-09-20 on two REAL runs instead:
# $0.3349 and $0.3564 total for one run's two calls each -- ~$0.167/call.
# This is still a fixed constant, and the docstring says so rather than
# implying otherwise: it is the INITIAL projection only, used before any
# call in THIS invocation has actually been made. The moment a real call
# returns a cost, `cmd_distill` recalibrates to THIS run's own observed
# average instead of trusting this constant further -- a fixed number can
# be corrected once, real payloads still vary, and the fix is to measure
# again, not to hand-pick a second guess.
DEFAULT_COST_PER_CALL_USD = 0.167
MODEL_TIMEOUT_SECS = 180


def die(msg, code=2):
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(code)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------- review-result.py reuse

def load_review_result():
    """The sibling module, imported by path -- the same importlib pattern
    rework-lag.py uses for filed-from.py's parse_filed_from(). Every command
    in this script needs resolve_session_id/resolve_session_dir at minimum,
    so this is called once at the top of each cmd_* function rather than
    conditionally."""
    sib = Path(__file__).resolve().parent / "review-result.py"
    if not sib.exists():
        die(
            "sibling assets/scripts/review-result.py is missing. "
            "session-distill.py reuses its resolve_session_id, "
            "resolve_session_dir, sidecar_dirs, iter_agent_jsonl, "
            "last_assistant_text and atomic_write rather than re-deriving "
            f"session-directory resolution a second time (expected at {sib})."
        )
    prev = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(
            "session_distill_review_result", str(sib))
        if spec is None or spec.loader is None:
            die(f"sibling {sib} exists but importlib could not build a loader for it")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = prev
    return mod


# --------------------------------------------------------------- transcript reading

def read_jsonl_objs(path):
    """Every line of PATH parsed as JSON, in order. Returns
    (objs, error, dropped):
      objs    the successfully parsed lines, in order. A blank line is
              skipped without counting against `dropped` (that is normal
              JSONL formatting, not a defect).
      error   None on a normal read (even one that yields zero objs
              because the file is genuinely empty), or a message string
              when the file could not be opened/read at all (#278 C1) --
              the OLD behaviour silently returned [] here, which made an
              unreadable transcript indistinguishable from an empty one.
              The caller records a non-None error in `unreadable[]`.
      dropped the count of non-blank lines that failed json.loads. The OLD
              behaviour discarded these with no counter at all -- a
              transcript that is nothing but garbage lines produced the
              same `objs == []` a chmod-000 file did, with no trace of
              which failure mode occurred. The caller folds a nonzero
              `dropped` into `unreadable[]` too, so unparseable content is
              reported rather than silently skipped."""
    objs = []
    dropped = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    dropped += 1
                    continue
                objs.append(obj)
    except OSError as e:
        return [], str(e), 0
    return objs, None, dropped


def get_user_text(obj):
    """A `type:"user"` line's text, whichever shape `message.content` is in
    -- a bare string (the common shape for a genuine typed prompt) or a
    list of content blocks (tool results, attachments, some harness
    versions of a plain prompt too). None if there is no text to extract."""
    if not isinstance(obj, dict):
        return None
    msg = obj.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(p for p in parts if p)
        return text or None
    return None


def assistant_text(obj):
    """Every text block of one `type:"assistant"` line, joined -- the same
    extraction review-result.py's last_assistant_text applies to the LAST
    such line; this is applied here to every assistant line in a span."""
    if not isinstance(obj, dict):
        return ""
    content = (obj.get("message") or {}).get("content") or []
    if not isinstance(content, list):
        return ""
    parts = [b.get("text", "") for b in content
             if isinstance(b, dict) and b.get("type") == "text"]
    return "\n".join(p for p in parts if p)


def strip_system_reminders(text):
    """Strip LEADING and TRAILING <system-reminder>...</system-reminder>
    blocks from a human prompt before it becomes `asked`. Stripped, not
    dropped -- the turn is still real even when every visible character was
    reminder boilerplate. A block embedded mid-prompt (the user quoting one
    back) is left exactly alone; only blocks anchored at either end are
    removed, and more than one stacked at the same end is handled by
    repeating the strip until none remain."""
    s = text
    while True:
        lead = s.lstrip()
        if not lead.startswith(REMINDER_OPEN):
            break
        close_idx = lead.find(REMINDER_CLOSE)
        if close_idx == -1:
            break
        s = lead[close_idx + len(REMINDER_CLOSE):]
    while True:
        trail = s.rstrip()
        if not trail.endswith(REMINDER_CLOSE):
            break
        open_idx = trail.rfind(REMINDER_OPEN)
        if open_idx == -1:
            break
        s = trail[:open_idx]
    return s.strip()


def tool_digest(input_obj, head=120, tail=60):
    """A one-line argument digest for a tool_use block -- the most
    recognizable string field if there is an obvious one, else a compact
    JSON dump, collapsed to one line and truncated.

    Truncation keeps the HEAD *and* the TAIL, not just the head (#278 M3):
    a long shell pipeline's exit-code read -- `... | head -50; echo
    "EXIT=$?"` -- lives at the END of the command, which is exactly where
    the proxy-as-thing pattern this tool exists to catch shows up. A
    head-only truncation silently drops that substring from every digest
    long enough to need truncating at all."""
    s = None
    if isinstance(input_obj, dict):
        for key in ("command", "file_path", "path", "pattern", "query", "prompt", "url"):
            v = input_obj.get(key)
            if isinstance(v, str):
                s = v
                break
        if s is None:
            s = json.dumps(input_obj, ensure_ascii=False, sort_keys=True)
    else:
        s = json.dumps(input_obj, ensure_ascii=False)
    s = " ".join(s.split())
    if len(s) > head + tail:
        s = s[:head] + "…" + (s[-tail:] if tail else "")
    return s


def proof_segments(proof):
    """The literal pieces of a claim's `proof` string, in order, used to
    test it against the run's FULL (untruncated) tool inputs (#291's
    proof-locatable guard). Strips an optional leading `[N] ` index tag,
    then an optional leading `ToolName: ` tag -- the shape the model
    copies straight out of the TOOL TRACE prompt section's numbered
    `[i] Tool: digest` lines -- drops everything from the first
    output-arrow (` -> `) on, unwraps a proof quoted whole (`"npm test"`),
    then splits at every elision (`...`, `…`) and whitespace-collapses
    each piece. Every piece is checked, not just the first: the model
    elides MID-command (`cd .../skill-templates-frozen && git show ...`),
    so the text before the first elision is often just `cd`, which
    matches nearly any trace. [] when PROOF is falsy or reduces to
    nothing -- the caller treats that as unlocatable."""
    if not proof:
        return []
    s = proof
    m = _PROOF_INDEX_PREFIX_RE.match(s)
    if m:
        s = s[m.end():]
    m = _PROOF_TOOL_PREFIX_RE.match(s)
    if m:
        s = s[m.end():]
    arrow = s.find(" -> ")
    if arrow != -1:
        s = s[:arrow]
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'`":
        s = s[1:-1]
    pieces = re.split(r"\.\.\.|…", s)
    return [p for p in (" ".join(x.split()) for x in pieces) if p]


def locate_proof_fragment(proof):
    """The leading piece of PROOF (see proof_segments), or ""."""
    segs = proof_segments(proof)
    return segs[0] if segs else ""


def _segments_in_order(segs, full):
    pos = 0
    for seg in segs:
        i = full.find(seg, pos)
        if i == -1:
            return False
        pos = i + len(seg)
    return True


def proof_located(proof, tool_inputs_full):
    """True iff every piece of PROOF (proof_segments) occurs, in order,
    within ONE entry of TOOL_INPUTS_FULL -- the run's own full, untruncated
    tool_use inputs (#291). Never "located" against no pieces or an empty
    TOOL_INPUTS_FULL (a run with no tool calls cannot locate anything).
    Pieces totalling fewer than PROOF_MIN_FRAGMENT_CHARS locate only as a
    WHOLE input: "git" is a substring of nearly any trace, so a fabricated
    proof that short would otherwise always pass."""
    segs = proof_segments(proof)
    if not segs or not tool_inputs_full:
        return False
    if sum(len(x) for x in segs) < PROOF_MIN_FRAGMENT_CHARS:
        return len(segs) == 1 and any(segs[0] == full for full in tool_inputs_full)
    return any(_segments_in_order(segs, full) for full in tool_inputs_full)


def compute_proof_located(claims, tool_inputs_full):
    """Mutates each claim dict in CLAIMS (already normalize_claims'd) in
    place, adding `proof_located`: True/False for a non-null `proof`, or
    None when `proof` is null -- never a silently absent key (#291).
    Returns (n_nonnull, n_unlocatable) so the caller can decide the
    placeholder-response FAILURE (every non-null proof unlocatable, #291)
    without re-deriving the same walk a second time."""
    n_nonnull = 0
    n_unlocatable = 0
    for c in claims:
        proof = c.get("proof")
        if not proof:
            c["proof_located"] = None
            continue
        n_nonnull += 1
        located = proof_located(proof, tool_inputs_full)
        c["proof_located"] = located
        if not located:
            n_unlocatable += 1
    return n_nonnull, n_unlocatable


def claims_all_proofs_unlocatable(distilled_doc, tool_inputs_full):
    """(is_failure, n_nonnull, n_unlocatable) for a fresh (not yet
    persisted) DISTILLED_DOC -- #291's placeholder-response guard. A
    result with >=1 non-null proof where EVERY one fails to locate in
    TOOL_INPUTS_FULL is a FAILURE (a schema-valid but content-free
    response, e.g. the literal placeholder doc {"claims": [{"proof": "test
    proof", ...}]} against a real trace); a result with ZERO claims or
    with every proof already null is NOT a failure by this guard -- there
    is no non-null proof to fail on, and this script does not otherwise
    police an empty claims list (#269/#285 already cover that ground:
    absence-without-second-search etc. are the model's own job to flag,
    not this deterministic guard's)."""
    claims = normalize_claims((distilled_doc or {}).get("claims"))
    n_nonnull, n_unlocatable = compute_proof_located(claims, tool_inputs_full)
    return (n_nonnull > 0 and n_unlocatable == n_nonnull), n_nonnull, n_unlocatable


def excerpt_head_tail(s, head, tail):
    """S truncated to its HEAD and TAIL (joined by an ellipsis) when longer
    than head+tail, otherwise S unchanged. Unlike `tool_digest`, this does
    NOT collapse whitespace -- a verification's full command/output is kept
    close to verbatim, not squeezed onto one line, since #285's
    verifications[] is meant to be read (by the model and by a human), not
    just fingerprinted."""
    if s is None:
        return None
    if len(s) <= head + tail:
        return s
    return s[:head] + "…" + (s[-tail:] if tail else "")


def extract_tool_result_text(raw_content):
    """The text of a tool_result block's `content`, handling both shapes
    seen in transcripts: a bare string, or a list of content blocks (each
    with a `text` field). Returns None only when RAW_CONTENT itself carries
    no extractable text (including a genuinely None `content` field) --
    the CALLER is responsible for distinguishing "no tool_result at all"
    (output_present=False) from "a tool_result whose content did not yield
    text" (output_present=True, output=None here) -- #285's `output_present`
    flag on each verification entry is what makes that distinction visible
    rather than collapsing both into the same "" a naive read would
    produce."""
    if raw_content is None:
        return None
    if isinstance(raw_content, str):
        return raw_content
    if isinstance(raw_content, list):
        parts = [b.get("text", "") for b in raw_content
                 if isinstance(b, dict) and b.get("type") == "text"]
        # No text block at all (an image-only result) is "yielded no text",
        # not "printed nothing" -- None, never "".
        return "\n".join(parts) if parts else None
    return None


def classify_verification_command(command):
    """The set of {"test","lint","build","ci_read"} categories COMMAND
    matches -- zero, one, or several (e.g. `xcodebuild build test`).
    Word-boundary regex against the FULL command text, not the truncated
    digest (#285)."""
    if not command:
        return set()
    cats = {cat for cat, rx in _VERIFY_CATEGORY_RE.items() if rx.search(command)}
    if is_ci_read(command):
        cats.add("ci_read")
    return cats


def is_ci_read(command):
    """True for a `gh pr checks`, `gh run view|list|watch`, or a
    `gh pr view` whose --json names statusCheckRollup/mergeStateStatus --
    the three shapes of "read CI state" #285's diagnosis names. A bare
    `gh pr view` with no such --json field is NOT a ci_read: it does not
    necessarily read check state at all."""
    if not command:
        return False
    if _CI_READ_CHECKS_RE.search(command) or _CI_READ_RUN_RE.search(command):
        return True
    if _CI_READ_PR_VIEW_RE.search(command) and _CI_READ_JSON_FIELD_RE.search(command):
        return True
    return False


# `(?<!<)`/`(?!<)`: a `<<<` here-string is not a heredoc and has no body.
_HEREDOC_OPEN_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def strip_heredoc_bodies(command):
    """COMMAND with every heredoc body removed -- the lines after a
    `<<WORD` / `<<'WORD'` / `<<-WORD` opener up to and including the line
    that is exactly WORD (leading tabs allowed, for `<<-`). The opener line
    itself is kept, so `python3 - <<'PY'` still reads as a python call.
    An unterminated heredoc drops everything after its opener: the body
    never ended, so nothing after it is shell."""
    if not command or "<<" not in command:
        return command or ""
    out = []
    lines = command.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        words = [m.group(2) for m in _HEREDOC_OPEN_RE.finditer(line)]
        i += 1
        for word in words:
            while i < len(lines) and lines[i].lstrip("\t") != word:
                i += 1
            i += 1  # the terminator line
    return "\n".join(out)


def classify_pipe_flags(command):
    """(exit_masked_by_pipe, output_truncated) for one Bash COMMAND (#285).

    These are two INDEPENDENT conditions, deliberately not conflated (the
    #286 saturation problem this docstring's issue calls out by name is
    exactly that conflation):
      output_truncated     the command pipes through a truncating/
                            filtering utility (head/tail/grep/sed/awk/cut/
                            sort/uniq/wc) ANYWHERE in it -- regardless of
                            whether an exit code is ever read.
      exit_masked_by_pipe  a `$?` read whose IMMEDIATELY PRECEDING
                            pipeline (the segment before it, splitting on
                            `;` `&&` `||` and newlines) pipes through such a
                            utility, with neither `pipefail` nor PIPESTATUS
                            appearing earlier in the command. Segment-aware
                            on purpose: `lint; echo "exit=$?"; swiftlint |
                            tail -3` reads lint's real status, and a
                            whole-command check flagged it anyway -- 3 of
                            4 hits on a real run were that false positive.
                            `cmd; echo "exit=$?"` with NO pipe is neither.
                            `cmd | tail -3` with no `$?` read is
                            output_truncated ONLY. `set -o pipefail; cmd |
                            tail; echo $?` is output_truncated but NOT
                            exit_masked_by_pipe -- pipefail makes `$?` the
                            real exit code even though the OUTPUT is still
                            truncated."""
    if not command:
        return False, False
    output_truncated = bool(_TRUNCATING_PIPE_RE.search(command))
    if not output_truncated:
        return False, False
    segments = _SEGMENT_SPLIT_RE.split(command)
    exit_masked = False
    for i, seg in enumerate(segments):
        if "$?" not in seg:
            continue
        before = segments[i - 1] if i > 0 else ""
        if not _TRUNCATING_PIPE_RE.search(before):
            continue
        # The masked status must be a GATE's: `git log | grep -c x; echo
        # rc=$?` reads grep's status on purpose and masks nothing.
        if not classify_verification_command(before):
            continue
        if _PIPEFAIL_PROTECTED_RE.search(" ".join(segments[:i + 1])):
            continue
        exit_masked = True
        break
    return exit_masked, output_truncated


def detect_empty_ci_result(output_text):
    """True when OUTPUT_TEXT shows an empty `statusCheckRollup` or "no
    checks reported" -- #285's A2 pattern (a `gh pr view` read 3-8s after a
    push, before CI had even started, misread as "CI has nothing to
    report"). Never fires on None/empty OUTPUT_TEXT -- the caller only
    calls this when a real tool_result was read; a missing result is a
    different, separately-flagged condition (`output_present`), never
    silently treated as an empty-and-therefore-clean result."""
    if not output_text:
        return False
    return bool(_EMPTY_CI_RESULT_RE.search(output_text))


def compute_gates(brief, verifications):
    """(gates_run, gates_named_not_run) -- deterministic, from VERIFICATIONS
    and the run's own BRIEF text, no model call. `gates_run` always carries
    all four GATE_CATEGORIES keys (0 for a category with no entries), so a
    consumer never has to guess whether an absent key means zero or means
    "not computed"."""
    gates_run = {cat: 0 for cat in GATE_CATEGORIES}
    for v in verifications:
        for cat in v["categories"]:
            if cat in gates_run:
                gates_run[cat] += 1
    text = brief or ""
    gates_named_not_run = [
        cat for cat in GATE_CATEGORIES
        if gates_run[cat] == 0 and _GATE_BRIEF_PATTERNS[cat].search(text)
    ]
    return gates_run, gates_named_not_run


def build_tool_trace(objs):
    """(tool_calls_count, trace[], verifications[], tool_inputs_full[])
    over a span of already- parsed transcript lines -- one `trace` entry
    per tool_use block on an assistant line, matched against a later
    tool_result (by tool_use_id) for `errored`; one `verifications` entry
    per Bash tool_use whose command matches at least one of test/lint/
    build/ci_read (#285); one `tool_inputs_full` entry per tool_use, in
    the SAME order/index as `trace`, holding the FULL, untruncated,
    whitespace-collapsed one-line form of its `input`
    (`tool_digest(input, head=10**9, tail=0)`) -- #291's proof-locatable
    guard needs the whole input, not `trace`'s head+tail-truncated
    `digest`, to tell a real cited command from a placeholder response.
    `tool_inputs_full` is kept on the in-memory run stub only, never
    written into a persisted record (`run_stub_public` does not carry it)
    -- it exists to be searched, not archived. Built in one pass over the
    same objs so a verification's `index` always lines up with its
    position in `trace`."""
    error_map = {}
    result_content = {}
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "user":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                tid = b.get("tool_use_id")
                if tid:
                    error_map[tid] = bool(b.get("is_error"))
                    result_content[tid] = b.get("content")

    trace = []
    verifications = []
    tool_inputs_full = []
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "assistant":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                continue
            name = b.get("name") or "unknown"
            tid = b.get("id")
            errored = error_map.get(tid, False)
            idx = len(trace)
            trace.append({
                "tool": name,
                "digest": tool_digest(b.get("input")),
                "errored": errored,
            })
            # #291: the FULL input, never truncated -- see the docstring.
            tool_inputs_full.append(tool_digest(b.get("input"), head=10**9, tail=0))
            if name != "Bash":
                continue
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            command = inp.get("command") if isinstance(inp.get("command"), str) else ""
            # Classified on the command with heredoc BODIES removed: a
            # heredoc is data handed to a program (a python script, a memory
            # note, a commit message), and on 13cee7be the only remaining
            # false exit-mask hits were heredoc text that merely DESCRIBED
            # `cmd | head; echo $?`. The stored `command` stays verbatim.
            shell_only = strip_heredoc_bodies(command)
            categories = classify_verification_command(shell_only)
            if not categories:
                continue
            output_present = tid in result_content
            output_text = (extract_tool_result_text(result_content.get(tid))
                            if output_present else None)
            exit_masked, output_truncated = classify_pipe_flags(shell_only)
            empty_ci = "ci_read" in categories and detect_empty_ci_result(output_text)
            verifications.append({
                "index": idx,
                "tool_use_id": tid,
                "categories": sorted(categories),
                "command": excerpt_head_tail(command, 300, 300),
                "errored": errored,
                "output": excerpt_head_tail(output_text, 200, 200),
                "output_present": output_present,
                "exit_masked_by_pipe": exit_masked,
                "output_truncated": output_truncated,
                "empty_ci_result": empty_ci,
            })
    return len(trace), trace, verifications, tool_inputs_full


def collect_cwds(objs):
    """The set of distinct `cwd` values carried by transcript lines in
    OBJS (#287) -- present on every line in current-format transcripts.
    More than one is legitimate (a run's cwd can change mid-span); an
    absent/falsy `cwd` on a line is simply not counted, never treated as
    a blank repo hint."""
    return {o.get("cwd") for o in objs if isinstance(o, dict) and o.get("cwd")}


# --------------------------------------------------------------- report extraction

def classify_harness_error(text):
    """True when TEXT opens with a known harness cutoff/error prefix (#285)
    -- a session-limit message, an API error -- rather than a real report.
    Checked against the STRIPPED text's start, not a bare substring search
    anywhere in it (a report that merely quotes one of these mid-text is
    not itself a cutoff)."""
    if not text:
        return False
    stripped = text.strip()
    return any(stripped.startswith(p) for p in HARNESS_ERROR_PREFIXES)


def last_structured_output(objs):
    """The LAST `StructuredOutput` tool_use block across every assistant
    line in OBJS (already-parsed transcript lines), or None. Workflow
    subagents end their run with a `StructuredOutput` tool_use whose
    `input` IS their report (#285's diagnosis) -- review-result.py's
    `last_assistant_text` only reads TEXT blocks of the last assistant
    line and returns None for a line that is tool_use only, which is why
    108 of 160 runs in the diagnosing session were distilled with a
    silently empty report. "Last" is over the WHOLE file, not just the
    last assistant line -- a later assistant line with only trailing text
    (a sign-off) after the StructuredOutput call is common and must not
    hide the structured result.

    Returns (block, rejected). A StructuredOutput whose own tool_result is
    `is_error` was REJECTED by the harness (schema validation) and is not
    the run's report; the last ACCEPTED one wins. Only when every
    submission was rejected is the last rejected one returned, with
    rejected=True, so the caller can say so instead of trusting it."""
    errored = set()
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "user":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if (isinstance(b, dict) and b.get("type") == "tool_result"
                    and b.get("is_error") and b.get("tool_use_id")):
                errored.add(b["tool_use_id"])
    accepted = rejected = None
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "assistant":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if (isinstance(b, dict) and b.get("type") == "tool_use"
                    and b.get("name") == "StructuredOutput"):
                if b.get("id") in errored:
                    rejected = b
                else:
                    accepted = b
    if accepted is not None:
        return accepted, False
    if rejected is not None:
        return rejected, True
    return None, False


def last_assistant_text_from_objs(objs):
    """The same extraction review-result.py's `last_assistant_text` applies
    to a freshly-opened file, applied instead to already-parsed OBJS -- the
    subagent/main-turn stub builders here already hold objs in hand from
    `read_jsonl_objs`, so this avoids re-reading and re-parsing the
    transcript a second time. Semantics are identical on purpose: this is
    NOT a second derivation of a different rule, it is the same rule
    applied to data already in memory."""
    last = None
    for o in objs:
        if isinstance(o, dict) and o.get("type") == "assistant":
            last = o
    if last is None:
        return None
    content = (last.get("message") or {}).get("content") or []
    if not isinstance(content, list):
        return None
    parts = [b.get("text", "") for b in content
             if isinstance(b, dict) and b.get("type") == "text"]
    text = "\n".join(p for p in parts if p)
    return text or None


def extract_report(objs):
    """(report, report_source) -- REPORT EXTRACTION (#285; see the module
    docstring's REPORT EXTRACTION AND DETERMINISTIC VERIFICATIONS section
    for the full rationale). Sources, in the order they are tried:
      structured_output  the transcript's final StructuredOutput tool_use
                          exists -- report is its `input`, pretty-printed
                          JSON, with any final assistant TEXT prepended
                          (text first) when there also is some.
      structured_output_rejected  every StructuredOutput submission's
                          tool_result was `is_error` -- the report is the
                          last rejected input, labelled so it is never
                          counted as a healthy result.
      harness_error       no StructuredOutput, and the last assistant text
                          matches a known harness cutoff/error prefix --
                          kept, not discarded, but flagged so it is never
                          silently distilled as if it were a real result.
      text                 the ordinary case: the last assistant line's
                          text blocks, same extraction review-result.py's
                          `last_assistant_text` applies.
      none                 neither exists -- report is "".
    Never "" pretending to be a real (if terse) report: "" only occurs
    together with report_source "none"."""
    last_text = last_assistant_text_from_objs(objs)
    so, so_rejected = last_structured_output(objs)
    if so is not None:
        input_json = json.dumps(so.get("input"), indent=2, ensure_ascii=False)
        report = (last_text + "\n\n" + input_json) if last_text else input_json
        return report, ("structured_output_rejected" if so_rejected else "structured_output")
    if last_text:
        if classify_harness_error(last_text):
            return last_text, "harness_error"
        return last_text, "text"
    return "", "none"


# ------------------------------------------------------------ main-turn segmentation

def segment_main_turns(objs):
    """(segmented_by, [(start_idx, end_idx), ...]) over OBJS (the parsed
    main transcript). See the module docstring's MAIN-TURN SEGMENTATION for
    why `origin.kind == "human"` is used whenever any line in the
    transcript carries an `origin` key at all, and the shape filter is a
    fallback used only when no line does."""
    has_origin = any(isinstance(o, dict) and "origin" in o for o in objs)
    segmented_by = "origin" if has_origin else "shape"

    def is_turn_start(o):
        if not isinstance(o, dict) or o.get("type") != "user":
            return False
        if segmented_by == "origin":
            # `origin` is a dict on every shape seen so far, but this file
            # tolerates lines it has not seen yet the same way every other
            # shape check here does (#278 N1) -- a line carrying a bare
            # `"origin": "human"` string used to raise AttributeError on
            # `.get("kind")` instead of simply not matching.
            origin = o.get("origin")
            origin = origin if isinstance(origin, dict) else {}
            return origin.get("kind") == "human"
        # shape fallback -- the "obvious" rule, deliberately used only when
        # `origin` is unavailable anywhere: string content, not isMeta, not
        # isSidechain, and not opening with harness-injected boilerplate.
        if o.get("isMeta") or o.get("isSidechain"):
            return False
        msg = o.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, str):
            return False
        stripped = content.lstrip()
        for bad in ("<task-notification>", "<system-reminder>", "<local-command"):
            if stripped.startswith(bad):
                return False
        return True

    starts = [i for i, o in enumerate(objs) if is_turn_start(o)]
    spans = []
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(objs)
        spans.append((start, end))
    return segmented_by, spans


def build_main_turn_stub(main_path, objs, start, end, idx, segmented_by):
    user_obj = objs[start]
    raw_brief = get_user_text(user_obj) or ""
    brief = strip_system_reminders(raw_brief)
    span = objs[start + 1:end]
    report = "\n\n".join(
        t for t in (assistant_text(o) for o in span
                    if isinstance(o, dict) and o.get("type") == "assistant") if t)
    # #285: a main turn's report_source is only ever "text" or "none" -- a
    # main turn does not end in a StructuredOutput tool_use (that is a
    # workflow-subagent shape), and its report is the join of every
    # assistant text block in the span, not just the last one, so the
    # harness-cutoff check (which reads only the LAST assistant text) does
    # not apply here either.
    report_source = "text" if report else "none"
    tool_calls, tool_trace, verifications, tool_inputs_full = build_tool_trace(span)
    gates_run, gates_named_not_run = compute_gates(brief, verifications)
    cwds = collect_cwds(objs[start:end])

    started_at = user_obj.get("timestamp") if isinstance(user_obj, dict) else None
    ended_at = None
    for o in reversed(objs[start:end]):
        if isinstance(o, dict) and o.get("timestamp"):
            ended_at = o["timestamp"]
            break

    return {
        "id": "main-turn-%03d" % idx,
        "kind": "main-turn",
        "spawned_by": None,
        "agent_type": None,
        "model": None,
        "description": None,
        "workflow_phase": None,
        "started_at": started_at,
        "ended_at": ended_at,
        "transcript": os.path.abspath(main_path),
        "brief": brief,
        "brief_chars": len(brief),
        "report": report,
        "report_chars": len(report),
        "report_source": report_source,
        "tool_calls": tool_calls,
        "tool_trace": tool_trace,
        "tool_inputs_full": tool_inputs_full,
        "verifications": verifications,
        "gates_run": gates_run,
        "gates_named_not_run": gates_named_not_run,
        "segmented_by": segmented_by,
        "cwds": sorted(cwds),
    }


def build_subagent_stub(rr, jsonl_path, unreadable):
    base = jsonl_path[:-len(".jsonl")]
    agent_name = os.path.basename(base)
    meta_path = base + ".meta.json"
    meta = {}
    if os.path.exists(meta_path):
        # A missing .meta.json is a run with null provenance, not a skipped
        # run (see the module docstring) -- and so, deliberately, is one
        # that exists but fails to parse: the sidecar transcript itself is
        # still real and still a run.
        try:
            with open(meta_path, encoding="utf-8") as f:
                meta = json.load(f) or {}
        except (OSError, json.JSONDecodeError):
            meta = {}

    d = os.path.dirname(jsonl_path)
    if os.path.basename(os.path.dirname(d)) == "workflows":
        spawned_by = os.path.basename(d)
    else:
        spawned_by = "session"

    objs, err, dropped = read_jsonl_objs(jsonl_path)
    if err:
        unreadable.append("subagent transcript %s (%s)" % (jsonl_path, err))
    elif dropped:
        unreadable.append(
            "subagent transcript %s: %d unparseable line(s) skipped" % (jsonl_path, dropped))
    first_user = next((o for o in objs if isinstance(o, dict) and o.get("type") == "user"), None)
    brief = (get_user_text(first_user) or "") if first_user is not None else ""
    # #285: prefer the transcript's final StructuredOutput tool_use over
    # review-result.py's last_assistant_text (rr.last_assistant_text is
    # deliberately left untouched -- review-result.py's own `harvest`
    # command depends on its exact text-blocks-only semantics; see
    # extract_report's docstring and the module docstring's REPORT
    # EXTRACTION section for why the OLD `rr.last_assistant_text(jsonl_path)
    # or ""` call here silently returned "" for 108 of 160 runs in the
    # diagnosing session).
    report, report_source = extract_report(objs)
    tool_calls, tool_trace, verifications, tool_inputs_full = build_tool_trace(objs)
    gates_run, gates_named_not_run = compute_gates(brief, verifications)
    cwds = collect_cwds(objs)

    started_at = None
    for o in objs:
        if isinstance(o, dict) and o.get("timestamp"):
            started_at = o["timestamp"]
            break
    ended_at = None
    for o in reversed(objs):
        if isinstance(o, dict) and o.get("timestamp"):
            ended_at = o["timestamp"]
            break

    return {
        "id": agent_name,
        "kind": "subagent",
        "spawned_by": spawned_by,
        "agent_type": meta.get("agentType"),
        "model": meta.get("model"),
        "description": meta.get("description"),
        "workflow_phase": meta.get("workflowPhase"),
        "started_at": started_at,
        "ended_at": ended_at,
        "transcript": os.path.abspath(jsonl_path),
        "brief": brief,
        "brief_chars": len(brief),
        "report": report,
        "report_chars": len(report),
        "report_source": report_source,
        "tool_calls": tool_calls,
        "tool_trace": tool_trace,
        "tool_inputs_full": tool_inputs_full,
        "verifications": verifications,
        "gates_run": gates_run,
        "gates_named_not_run": gates_named_not_run,
        "cwds": sorted(cwds),
    }


def build_all_run_stubs(rr, session_dir):
    """(segmented_by, [run_stub, ...], unreadable[], repo_vocabulary) --
    every main-turn and every subagent run in the session, sorted by
    started_at (runs with no timestamp sort first, deterministically, by
    id).

    `segmented_by` is `None` unless `segment_main_turns` actually ran --
    never a rule name asserted on zero evidence (#278 C1). That happens in
    exactly two cases, both legitimate and neither an error: the main
    transcript is absent entirely (no main thread for this session), or it
    is present but empty. Anything else that prevents a read --
    unreadable, or present-but-entirely-unparseable -- is instead recorded
    in `unreadable[]`, one entry per main or subagent transcript that could
    not be fully read; the caller (`cmd_runs`/`cmd_distill`) turns a
    non-empty `unreadable[]` into a stderr warning per entry and a forced
    exit code, same discipline as rework-lag.py's `unknown[]`.

    `repo_vocabulary` (#287) is computed ONCE, session-wide, over every
    stub's brief/report/tool_inputs_full, from the four STRONG qualified
    forms only (see the module-level regex block) -- never from a bare
    mention, which is what lets a bare mention resolve against it without
    circularity. Each stub then gets its own `repos` set (`compute_run_
    repo_set`), stored on the stub (never written into a persisted
    record's `run` sub-object -- `run_stub_public` does not carry it)."""
    stubs = []
    segmented_by = None
    unreadable = []

    main_path = session_dir + ".jsonl"
    if os.path.exists(main_path):
        objs, err, dropped = read_jsonl_objs(main_path)
        if err:
            unreadable.append("main transcript %s (%s)" % (main_path, err))
        else:
            if dropped and objs:
                unreadable.append(
                    "main transcript %s: %d unparseable line(s) skipped" % (main_path, dropped))
            elif dropped and not objs:
                unreadable.append(
                    "main transcript %s: 0 of %d line(s) parsed" % (main_path, dropped))
            if objs:
                segmented_by, spans = segment_main_turns(objs)
                for k, (start, end) in enumerate(spans):
                    stubs.append(build_main_turn_stub(main_path, objs, start, end, k + 1, segmented_by))
            # objs == [] and dropped == 0: a genuinely empty file. Not an
            # error -- segmented_by stays None because no rule ran.

    for jsonl_path in rr.iter_agent_jsonl(session_dir):
        stubs.append(build_subagent_stub(rr, jsonl_path, unreadable))

    stubs.sort(key=lambda r: (r.get("started_at") or "", r["id"]))

    repo_vocabulary = build_repo_vocabulary(stubs)
    for stub in stubs:
        stub["repos"] = sorted(compute_run_repo_set(stub, repo_vocabulary))

    return segmented_by, stubs, unreadable, repo_vocabulary


# --------------------------------------------------------------- claim/label handling

def normalize_claims(raw):
    out = []
    for i, c in enumerate(raw or []):
        if not isinstance(c, dict):
            continue
        cid = c.get("id")
        if not isinstance(cid, str) or not cid:
            cid = "c%d" % (i + 1)
        elif cid.isdigit():
            # A digit-only id would share one namespace with the digit-string
            # later_wrong index pointers in `supports` (#290 review): claim
            # "0" and later_wrong[0] would be the same pointer. Claims are
            # normalized before the chain call, so the model only ever sees
            # the prefixed id and never references the bare one.
            cid = "c" + cid
        out.append({
            "id": cid,
            "text": c.get("text") or "",
            "kind": c.get("kind") or "unspecified",
            "proof": c.get("proof") if isinstance(c.get("proof"), str) else None,
            "quote": c.get("quote") if isinstance(c.get("quote"), str) else None,
        })
    return out


def normalize_later_wrong(raw, claim_ids, candidates=None):
    """(later_wrong[], dropped[], index_map{}) -- a `later_wrong` entry whose `claim`
    does not name a real claim id is dropped, not silently kept as a
    dangling pointer (#278 C2): `enforce_classified_as` below treats a
    `later_wrong` INDEX as valid supporting evidence for a `classified_as`
    label, so an unvalidated `later_wrong[i]` naming a nonexistent claim
    would let a label ride in on evidence that itself points nowhere.
    `dropped` carries the offending claim references (bare, as before) so
    the caller can record/warn about them -- unresolvable is reported,
    never silently kept.

    #287: an entry whose `contradicted_by.run` is linked to this run's
    claims ONLY through ambiguous-repo `#N` CANDIDATES -- every candidate
    CANDIDATES carries for that run is a `#N` artifact tagged
    `repo_match=="ambiguous"`, none `"same"`/`"n/a"` -- is likewise
    dropped, deterministically, regardless of what the chain prompt told
    the model: a shared issue/PR number across two repos is retrieval
    noise, not evidence a contradiction exists. Reuses the SAME
    drop/index_map mechanism as the unresolvable-claim case above (#290:
    index pointers must survive a drop) -- `dropped` gets a dict entry
    `{"claim", "run", "reason": "repo-ambiguous-only"}` for this case
    (distinguishable from the bare claim-ref strings the older case
    appends) so the caller's warning names the reason. A run with NO
    candidates at all is left alone by this check -- it has nothing to do
    with repo ambiguity, and is out of this guard's scope. CANDIDATES
    defaults to None/empty, in which case this check simply never fires
    (existing callers that have no candidates -- e.g. a budget-stop record
    with only a distill pass -- see no change in behaviour).

    `index_map` maps each KEPT entry's position in the model's RAW array to
    its position in the returned list. The model writes `classified_as`
    index pointers against the array it emitted; dropping raw[0] shifts
    every later entry down one, and reading the pointers against the
    shrunk list put a label and its `why` on the wrong contradiction and
    marked a classified one "not classified by the model" (#290 review).
    `enforce_classified_as` resolves index pointers through this map --
    which is exactly how a `classified_as` entry whose SOLE support was a
    now-dropped index is handled too: it has no pointer left that resolves
    to anything, so `enforce_classified_as` drops IT entirely (see that
    function's docstring) -- the same treatment an unresolvable-claim drop
    already got, unchanged by this addition."""
    candidates_by_run = {}
    for cand in candidates or []:
        candidates_by_run.setdefault(cand.get("run"), []).append(cand)

    out = []
    dropped = []
    index_map = {}
    for raw_i, lw in enumerate(raw or []):
        if not isinstance(lw, dict):
            continue
        claim = lw.get("claim")
        if not isinstance(claim, str) or claim not in claim_ids:
            dropped.append(claim)
            continue
        cb = lw.get("contradicted_by")
        cb = cb if isinstance(cb, dict) else {}
        run = cb.get("run")
        run_candidates = candidates_by_run.get(run) or []
        # Keyed by CLAIM, not run: a run's "same" candidate for some other
        # claim is no evidence for this one. Kept when a non-ambiguous
        # candidate in RUN names this claim; withdrawn when RUN was reached
        # through an ambiguous #N and nothing better ties it to this claim
        # (13cee7be's c61 never mentions #264 at all).
        backed = any(claim in (c.get("claims") or []) and c.get("repo_match") != "ambiguous"
                     for c in run_candidates)
        if not backed and any(c.get("repo_match") == "ambiguous" for c in run_candidates):
            dropped.append({"claim": claim, "run": run, "index": raw_i,
                            "reason": "repo-ambiguous-only"})
            continue
        index_map[raw_i] = len(out)
        out.append({
            "claim": claim,
            "how": lw.get("how") or "",
            "contradicted_by": {
                "run": run,
                "at": cb.get("at"),
                "quote": cb.get("quote"),
            },
        })
    return out, dropped, index_map


def enforce_classified_as(raw, claims, later_wrong, index_map=None, withdrawn=None):
    """(classified_as[], unclassified_reason) -- the CLOSED VOCABULARY's
    second enforcement point.

    `supports` is filtered ELEMENT-WISE (#278 C2), not all-or-nothing: the
    OLD behaviour dropped an entry only when EVERY pointer in `supports`
    was bad, then wrote the RAW list back -- so `["0", "c99-bogus"]` with
    a valid `"0"` kept `"c99-bogus"` in the persisted record as a dangling
    pointer nobody had checked. Now only the pointers that actually
    resolve (to an existing claim id, or to a valid `later_wrong` index)
    survive into the written `supports`; the entry itself is DROPPED only
    when NONE of its pointers resolve -- it then has no evidence pointer
    at all, so there is nothing honest to keep. An entry that survives
    with at least one valid pointer but carries an off-vocabulary label is
    kept with its label replaced by "unclassified", and the offending
    label text is folded into `unclassified_reason` -- never invented,
    never passed through unexamined.

    Every surviving `supports` element is NORMALIZED TO A STRING on the
    way out (#278 round 2 T1): a `later_wrong` index resolves whether it
    arrives as the int `0` or the digit-string `"0"`, but the OLD code
    wrote back whichever type the model sent, so `supports: [0]` and
    `supports: ["0"]` both shipped and a consumer of the schema-documented
    digit-string had to handle two types for the same value. The claim-id
    case is already a string (`normalize_claims` only ever mints string
    ids), so this only ever changes an int index into its digit-string."""
    claim_ids = {c["id"] for c in claims}
    n_later_wrong = len(later_wrong)
    # WITHDRAWN (#287): raw later_wrong indices dropped as repo-ambiguous.
    # A label that cited one rested on a contradiction that was never
    # there; its surviving claim pointer does not make it evidenced, so
    # the whole entry goes (on 13cee7be, an outcome-not-reason on c61
    # outlived the false later_wrong it was built on).
    withdrawn = {str(i) for i in (withdrawn or ())}
    # INDEX_MAP (from normalize_later_wrong) translates the model's raw
    # later_wrong positions to kept ones; None means the pointers already
    # address LATER_WRONG as given.
    if index_map is None:
        index_map = {i: i for i in range(n_later_wrong)}

    def resolve(s):
        """The written pointer for S, or None when it resolves to nothing."""
        if isinstance(s, str) and s in claim_ids:
            return s
        if isinstance(s, str) and s.isdigit():
            s = int(s)
        if isinstance(s, int) and not isinstance(s, bool) and s in index_map:
            return str(index_map[s])
        return None

    out = []
    reasons = []
    for entry in raw or []:
        if not isinstance(entry, dict):
            continue
        supports = entry.get("supports")
        if not isinstance(supports, list):
            continue
        if any(str(s) in withdrawn for s in supports if not isinstance(s, bool)):
            continue  # DROPPED -- it cited a withdrawn later_wrong
        resolved = [p for p in (resolve(s) for s in supports) if p is not None]
        if not resolved:
            continue  # DROPPED -- no pointer in `supports` resolves to anything
        label = entry.get("label")
        if label not in LABELS:
            reasons.append(str(label))
            label = "unclassified"
        out.append({
            "label": label,
            "supports": resolved,
            "why": entry.get("why") or "",
        })
    # #286: every later_wrong entry is covered by some label, or says in the
    # record that it is not. On 13cee7be main-turn-005's later_wrong[2]/[3]
    # found the real cause of a misattributed bug and carried no label at
    # all -- a contradiction found and never classified, in silence.
    covered = {s for e in out for s in e["supports"]}
    for i in range(n_later_wrong):
        if str(i) not in covered:
            out.append({
                "label": "unclassified",
                "supports": [str(i)],
                "why": "later_wrong[%d] was not classified by the model" % i,
            })
            reasons.append("later_wrong[%d] unlabelled by the model" % i)
    unclassified_reason = "; ".join(reasons) if reasons else None
    return out, unclassified_reason


# ----------------------------------------------------------------- chain retrieval

def extract_repo_qualifiers(text):
    """The set of repo names TEXT explicitly qualifies (#287) via the four
    STRONG forms only -- `owner/repo#N`, the `github.com/owner/repo/
    (pull|issues)/N` URL, a `gh ... -R|--repo owner/repo` flag, and
    `git -C <path>`/`cd <path>` under `.../Projects/<repo>`. This is the
    ONLY function that SEEDS the session-wide repo vocabulary
    (build_repo_vocabulary) -- a bare mention is resolved against that
    vocabulary elsewhere, never added to it here."""
    repos = set()
    if not text:
        return repos
    for rx in (_REPO_QUALIFIED_HASH_RE, _REPO_URL_HASH_RE, _REPO_GH_FLAG_RE):
        for m in rx.finditer(text):
            repos.add(_clean_repo_name(m.group(2)))
    for m in _REPO_GIT_C_CD_RE.finditer(text):
        repos.add(_clean_repo_name(m.group(1)))
    return repos


def repo_from_cwd(cwd, known_names):
    """The repo CWD names (#287), or None. The slash form of a worktree
    path (`.../Projects/<repo>/...`) is captured generically. The
    dash-joined form a session directory basename uses (`-Users-...-
    Projects-Aeolus--claude-worktrees-...`) cannot be split unambiguously
    when a repo name itself contains a dash (`skill-templates`), so it is
    matched against KNOWN_NAMES (this run's own qualifiers union the
    session vocabulary) instead of re-derived from the dashes alone --
    longest name first, so `skill-templates` is not shadowed by a shorter
    name that happens to be a prefix of it."""
    if not cwd:
        return None
    m = _CWD_SLASH_PROJECTS_RE.search(cwd)
    if m:
        return m.group(1)
    m2 = _CWD_DASH_PROJECTS_RE.search(cwd)
    if m2:
        tail = cwd[m2.end():]
        for name in sorted(known_names, key=len, reverse=True):
            if tail.startswith(name) and (len(tail) == len(name) or tail[len(name)] in "-/"):
                return name
    return None


def _run_repo_text(stub):
    return "\n".join([
        stub.get("brief") or "", stub.get("report") or "",
        "\n".join(stub.get("tool_inputs_full") or []),
    ])


def build_repo_vocabulary(stubs):
    """The session-wide repo vocabulary (#287): the union, over every run
    STUB's brief/report/tool_inputs_full, of every repo name the four
    STRONG qualified forms establish (extract_repo_qualifiers). Computed
    once, before any per-run repo set, so a bare mention in run A can
    resolve against a name a DIFFERENT run B qualified explicitly."""
    vocab = set()
    for stub in stubs:
        vocab |= extract_repo_qualifiers(_run_repo_text(stub))
        # A cwd under Projects/<repo> names a repo as surely as a -R flag;
        # without it a two-repo session that names only one repo in text
        # looks single-repo and loses its ambiguity tagging.
        for cwd in stub.get("cwds") or []:
            m = _CWD_SLASH_PROJECTS_RE.search(cwd)
            if m:
                vocab.add(m.group(1))
    return vocab


def compute_run_repo_set(stub, vocabulary):
    """The set of repo names this run's own text and tool inputs
    establish (#287): the four STRONG qualified forms found in ITS OWN
    brief/report/tool_inputs_full; its own cwd(s) mapped to a repo
    (repo_from_cwd); and any bare mention of a repo NAME already in the
    session-wide VOCABULARY, case-sensitive and word-bounded -- never the
    reverse (a bare mention here never adds to VOCABULARY, only consumes
    it), or "issue #250" would qualify "issue" as a repo."""
    text = _run_repo_text(stub)
    repos = extract_repo_qualifiers(text)
    for cwd in stub.get("cwds") or []:
        r = repo_from_cwd(cwd, repos | vocabulary)
        if r:
            repos.add(r)
    for name in vocabulary:
        if re.search(r'\b%s\b' % re.escape(name), text):
            repos.add(name)
    return repos


def resolve_hash_qualifier(text, start, end, number, vocabulary):
    """The explicit repo name attached to the `#<number>` occurrence at
    text[start:end] (#287 design point 2) -- `owner/repo#N` or a bare
    `repo#N`/`repo #N` immediately BEFORE it (the bare form counts only
    when `repo`, case-sensitive, is already in VOCABULARY -- never a raw
    word, or "issue #250" would qualify "issue"), or the markdown-link
    shape `[#N](https://github.com/owner/repo/(pull|issues)/N)`
    immediately AFTER it -- or None when this specific occurrence carries
    no such qualifier."""
    before = text[max(0, start - 100):start]
    m = _TAIL_OWNER_REPO_RE.search(before)
    if m:
        return _clean_repo_name(m.group(2))
    m = _TAIL_BARE_NAME_RE.search(before)
    if m and m.group(1) in vocabulary:
        return m.group(1)
    after = text[end:end + 150]
    m = re.search(
        r'github\.com/([A-Za-z0-9][\w.-]*)/([A-Za-z0-9][\w.-]*)/(?:pull|issues)/%s\b'
        % re.escape(number), after)
    if m:
        return _clean_repo_name(m.group(2))
    return None


def resolve_claim_hash_repo(claims, artifact, vocabulary, current_repos):
    """The repo ARTIFACT (a `#N` string) resolves to for THIS run's claims
    (#287 design point 2): the first explicit qualifier found at any
    occurrence of ARTIFACT in a claim's `text`/`quote` wins; absent one,
    CURRENT_REPOS (this run's own repo set) if it names EXACTLY one repo;
    otherwise None (ambiguous)."""
    number = artifact[1:]
    for c in claims:
        for field in ("text", "quote"):
            s = c.get(field) or ""
            if artifact not in s:
                continue
            for m in re.finditer(re.escape(artifact), s):
                repo = resolve_hash_qualifier(s, m.start(), m.end(), number, vocabulary)
                if repo:
                    return repo
    if len(current_repos) == 1:
        return next(iter(current_repos))
    return None


def extract_artifacts(text):
    if not text:
        return set()
    hits = set()
    for m in ARTIFACT_RE.finditer(text):
        s = m.group(0).strip("`")
        if len(s) >= 2:
            hits.add(s)
    return hits


def find_chain_candidates(claims, current_started_at, current_repos, other_runs, vocabulary):
    """Deterministic retrieval, done before any model call: pull the
    artifacts named in each claim, then scan every OTHER run that started
    LATER for a mention of the same artifact within CUE_WINDOW_CHARS of a
    correction-cue word. Retrieval-before-model is what keeps `distill`
    O(n) model calls instead of O(n^2).

    #287: for a `#N`-shaped artifact, each SIDE of a candidate match is
    independently resolved to a repo -- the claim side via
    resolve_claim_hash_repo (this run's claims + CURRENT_REPOS), the
    occurrence side via resolve_hash_qualifier at that exact position,
    falling back to the other run's OWN repo set when it names exactly
    one. Both resolved and DIFFERENT -> this occurrence is skipped (not a
    candidate; the scan continues to the artifact's next occurrence in
    the same run, since a later occurrence may carry a different, matching
    qualifier). Both resolved and EQUAL -> an ordinary candidate, tagged
    `repo_match: "same"`. Either side unresolved -> kept, but tagged
    `repo_match: "ambiguous"` -- retrieval noise the model is told (in
    CHAIN_SYSTEM_PROMPT) cannot alone support a later_wrong or a label,
    and `normalize_later_wrong` enforces that deterministically on the
    way out regardless of what the model does with it. A non-`#N`
    artifact (backtick span, path) carries no repo concept at all and is
    tagged `repo_match: "n/a"` -- never silently absent, matching this
    script's existing "never an absent key" discipline (`report_source`
    etc.)."""
    artifacts = set()
    for c in claims:
        artifacts |= extract_artifacts(c.get("text", ""))
        artifacts |= extract_artifacts(c.get("quote") or "")
    if not artifacts or not current_started_at:
        return []

    current_repos = current_repos or set()
    vocabulary = vocabulary or set()
    hash_re = re.compile(r'^#\d+$')

    candidates = []
    for r in other_runs:
        started_at = r.get("started_at")
        if not started_at or started_at <= current_started_at:
            continue
        haystack = (r.get("brief") or "") + "\n" + (r.get("report") or "")
        if not haystack.strip():
            continue
        low = haystack.lower()
        other_repos = set(r.get("repos") or [])
        for art in artifacts:
            is_hash = bool(hash_re.match(art))
            claim_repo = (resolve_claim_hash_repo(claims, art, vocabulary, current_repos)
                          if is_hash else None)
            idx = haystack.find(art)
            while idx != -1:
                lo = max(0, idx - CUE_WINDOW_CHARS)
                hi = idx + len(art) + CUE_WINDOW_CHARS
                window = low[lo:hi]
                if any(cue in window for cue in CORRECTION_CUES):
                    if is_hash:
                        occ_repo = resolve_hash_qualifier(
                            haystack, idx, idx + len(art), art[1:], vocabulary)
                        if occ_repo is None and len(other_repos) == 1:
                            occ_repo = next(iter(other_repos))
                        if (claim_repo is not None and occ_repo is not None
                                and claim_repo.lower() != occ_repo.lower()):
                            # Different, resolved repos -- not a candidate
                            # AT THIS OCCURRENCE. Keep scanning: a later
                            # occurrence of the same artifact string may
                            # carry a qualifier that does match.
                            idx = haystack.find(art, idx + 1)
                            continue
                        # Ambiguity needs a second repo to be ambiguous
                        # WITH: in a session whose vocabulary names at most
                        # one repo, a bare #N cannot collide, and weakening
                        # it would drop real later_wrong entries from any
                        # run whose cwd lies outside ~/Projects.
                        if (claim_repo is not None and occ_repo is not None) or len(vocabulary) <= 1:
                            repo_match = "same"
                        else:
                            repo_match = "ambiguous"
                    else:
                        repo_match = "n/a"
                    candidates.append({
                        "run": r["id"],
                        "started_at": started_at,
                        "artifact": art,
                        "excerpt": haystack[max(0, idx - 120): idx + len(art) + 120].replace("\n", " "),
                        "repo_match": repo_match,
                        "claims": sorted(
                            c["id"] for c in claims
                            if art in (c.get("text") or "") or art in (c.get("quote") or "")),
                    })
                    break
                idx = haystack.find(art, idx + 1)
    return candidates


# ---------------------------------------------------------------------- model boundary

# #278 M1: on a real run, `proof` came back non-null for only 4 of 14
# claims on one 89-tool-call run, and 10 of 11 on a 35-tool-call run -- the
# defect is VARIANCE, not absence (a first read that generalized "null on
# 14/14" to "the model nulls everything" was itself one run's worth of
# evidence, corrected before shipping this fix). The tool trace this
# prompt is handed already carries the command that would justify most of
# these -- on the 89-call run, the actual defect (`swift format lint ...
# 2>&1 | head -50; echo "EXIT=$?"`) sat untruncated in the trace and
# unused while the model cited an unrelated symbol instead. `proof` is
# stated below as a FLOOR the model must clear, not a suggestion, and the
# instruction is to search the WHOLE trace regardless of its length --
# nothing in this prompt truncates the trace itself (`tool_digest` on the
# per-line digests is head+tail, #278 M3), so a large trace degrading
# compliance is a model-following problem this wording narrows, not a
# missing-data problem this script has.
DISTILL_SYSTEM_PROMPT = (
    "You are distilling one run of an agent session for skill-templates "
    "issue #269. `asked` is what was actually requested of this run, "
    "`understood` is what the run itself interpreted that as, `delivered` "
    "is what it actually did, and `claims` is every checkable assertion "
    "the report makes -- each with a stable id (c1, c2, ...), a short "
    "`kind`, a verbatim `quote` from the report, and a `proof`. "
    "PROOF IS A FLOOR: read the TOOL TRACE section below the brief/report "
    "in full, command by command, however many entries it has -- the last "
    "entries matter as much as the first, and a longer trace is not an "
    "excuse for a shorter search. If any trace entry's command or output "
    "supports a claim, `proof` MUST be that trace entry's command, "
    "verbatim, even when the report itself never restates it -- the trace "
    "is evidence the report did not have to repeat for it to count. "
    "`proof` is null ONLY after checking the whole trace and finding "
    "nothing in it that supports the claim -- never null merely because "
    "the report did not name a check. "
    "REPORT_SOURCE (#285) tells you what kind of report this is: "
    "`harness_error` means the run was cut off by the harness (e.g. a "
    "session-limit message) -- the REPORT text is not a real result, do "
    "not treat it as evidence for any claim beyond the cutoff itself. "
    "`structured_output_rejected` means the harness rejected every result "
    "the run submitted -- treat the REPORT as an unaccepted draft, not the "
    "run's result. "
    "`none` means there is no report at all -- base claims only on the "
    "brief and the trace/VERIFICATION COMMANDS. "
    "VERIFICATION COMMANDS is a deterministic list (not your judgment) of "
    "every Bash command that ran a test/lint/build or read CI state, with "
    "its own output and flags already computed. Every entry whose result "
    "shaped the report or an intermediate decision becomes its own claim "
    "(kind \"verification\"), even when the report never restates it and "
    "even when a LATER entry re-checked the same thing -- a defective "
    "earlier check that a later one superseded is still a claim, not "
    "discarded in favor of the one best proof. Claims are about the RUN, "
    "never about this prompt: do not claim that a gate was or was not run, "
    "or that a section is empty, on the strength of VERIFICATION COMMANDS "
    "or gates_named_not_run -- those are recorded deterministically "
    "already, and a claim restating them has no proof in the run. "
    "Return only the JSON object the schema describes."
)

CHAIN_SYSTEM_PROMPT = (
    "You are checking one run's claims against candidate later mentions "
    "from the same session for contradictions, and classifying each "
    "claim's evidence quality against a CLOSED vocabulary of failure "
    "modes, defined in the LABELS section of the prompt. Judge primarily "
    "from each claim's `proof` text, not only its `quote`, and quote the "
    "exact command or text a label rests on in `why`. Choose the label "
    "that names the specific defect; a claim with no evidence-quality "
    "defect gets NO label -- labelling is not required per claim. "
    "Classify EVERY later_wrong entry you emit: a contradiction exists "
    "because some claim's evidence failed, and naming how is the point. "
    "Use ONLY a label from the schema's enum -- never "
    "invent one; unclear cases still get the closest listed label, and "
    "enforcement happens in code on the way out, not in this prompt. "
    "Every classified_as entry's `supports` array MUST name at least one "
    "existing claim id or later_wrong index (as a digit string) -- an "
    "entry with no such pointer is discarded downstream. A later_wrong "
    "entry names the claim id it contradicts, a one-sentence `how`, and "
    "`contradicted_by: {run, at, quote}` pointing at the run/timestamp/"
    "quote that contradicts it. "
    "Each CANDIDATE LATER MENTION is tagged repo_match: \"same\" (both "
    "sides resolved to the same repo), \"ambiguous\" (a #N candidate "
    "whose repo could not be resolved on at least one side), or \"n/a\" "
    "(not a #N artifact -- no repo concept applies). An "
    "repo_match=\"ambiguous\" candidate is retrieval NOISE, not evidence: "
    "it CANNOT on its own support a later_wrong entry or a classified_as "
    "label -- a shared issue/PR number across two different repos is not "
    "a contradiction. Only cite one when something else about it (a "
    "repo_match=\"same\" candidate, or a repo_match=\"n/a\" candidate "
    "naming the same artifact/claim) also ties the same run to the same "
    "claim. Return only the JSON object the schema describes."
)

DISTILL_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "required": ["asked", "understood", "delivered", "claims"],
    "properties": {
        "asked": {"type": "string"},
        "understood": {"type": "string"},
        "delivered": {"type": "string"},
        "claims": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["id", "text", "kind"],
                "properties": {
                    "id": {"type": "string"},
                    "text": {"type": "string"},
                    "kind": {"type": "string"},
                    "proof": {"type": ["string", "null"]},
                    "quote": {"type": ["string", "null"]},
                },
            },
        },
    },
}

CHAIN_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "required": ["later_wrong", "classified_as"],
    "properties": {
        "later_wrong": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["claim", "how", "contradicted_by"],
                "properties": {
                    "claim": {"type": "string"},
                    "how": {"type": "string"},
                    "contradicted_by": {
                        "type": "object",
                        "properties": {
                            "run": {"type": ["string", "null"]},
                            "at": {"type": ["string", "null"]},
                            "quote": {"type": ["string", "null"]},
                        },
                    },
                },
            },
        },
        "classified_as": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["label", "supports", "why"],
                "properties": {
                    # Enforcement point 1 of 2 -- see enforce_classified_as
                    # for point 2, the post-hoc recheck against LABELS.
                    "label": {"type": "string", "enum": list(LABELS)},
                    "supports": {"type": "array", "items": {"type": "string"}},
                    "why": {"type": "string"},
                },
            },
        },
    },
}


def run_model(model_cmd_argv, system_prompt, schema, prompt_text, timeout_secs=None):
    """Invoke the model boundary once. Returns (doc, cost_usd, error):
    exactly one of doc/error is not None. cost_usd is the envelope's
    total_cost_usd (0.0 when absent or when the call never produced an
    envelope) -- summed by the caller regardless of success, since a
    failed call can still have spent money."""
    argv = list(model_cmd_argv) + [
        "--system-prompt", system_prompt,
        "--json-schema", json.dumps(schema),
    ]
    try:
        proc = subprocess.run(
            argv, input=prompt_text, capture_output=True,
            encoding="utf-8", errors="replace",
            timeout=timeout_secs or MODEL_TIMEOUT_SECS)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, 0.0, "model invocation failed: %s" % e

    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return None, 0.0, "model stdout is not a valid JSON envelope: %s" % e

    cost = envelope.get("total_cost_usd") if isinstance(envelope, dict) else None
    cost = cost if isinstance(cost, (int, float)) else 0.0

    if not isinstance(envelope, dict):
        return None, cost, "model envelope is not a JSON object"
    if envelope.get("is_error"):
        return None, cost, "model reported is_error: true (%r)" % (envelope.get("result"),)

    raw_result = envelope.get("result")
    if not isinstance(raw_result, str):
        return None, cost, "envelope 'result' is not a string"
    try:
        doc = json.loads(raw_result)
    except json.JSONDecodeError as e:
        return None, cost, "envelope 'result' is not valid JSON: %s" % e
    if not isinstance(doc, dict):
        return None, cost, "envelope 'result' did not parse to a JSON object"
    return doc, cost, None


def model_name_from_cmd(argv):
    for i, tok in enumerate(argv):
        if tok == "--model" and i + 1 < len(argv):
            return argv[i + 1]
    return "unknown"


def build_distill_prompt(r):
    lines = [
        "SESSION_DISTILL_PASS: distill",
        "RUN_ID: %s" % r["id"],
        "RUN_KIND: %s" % r["kind"],
        "DESCRIPTION: %s" % (r.get("description") or ""),
        "REPORT_SOURCE: %s" % (r.get("report_source") or "none"),
        "",
        "--- BRIEF ---",
        r.get("brief") or "",
        "",
        "--- REPORT ---",
        r.get("report") or "",
        "",
        "--- TOOL TRACE (%d calls) ---" % r.get("tool_calls", 0),
    ]
    # Numbered with the same 0-based index VERIFICATION COMMANDS' `[N]`
    # tags carry, so the model can tie an entry back to its trace position.
    for i, t in enumerate(r.get("tool_trace") or []):
        lines.append("[%d] %s: %s%s" % (i, t["tool"], t["digest"], " [ERRORED]" if t["errored"] else ""))

    # #285: a deterministic, model-free section -- every category/flag/
    # output below was computed in build_tool_trace/compute_gates, not by
    # this call. DISTILL_SYSTEM_PROMPT tells the model to turn each entry
    # into its own claim rather than picking one best proof.
    verifications = r.get("verifications") or []
    lines.append("")
    lines.append("--- VERIFICATION COMMANDS (%d) ---" % len(verifications))
    for v in verifications:
        flags = [name for name in ("exit_masked_by_pipe", "output_truncated", "empty_ci_result")
                 if v.get(name)]
        lines.append("[%d] categories=%s errored=%s flags=%s" % (
            v.get("index"), ",".join(v.get("categories") or []), v.get("errored"),
            ",".join(flags) or "-"))
        lines.append("  command: %s" % v.get("command"))
        if v.get("output_present"):
            lines.append("  output: %s" % (v.get("output") if v.get("output") else "(empty)"))
        else:
            lines.append("  output: (no tool_result found)")
    gates_run = r.get("gates_run") or {cat: 0 for cat in GATE_CATEGORIES}
    gates_named_not_run = r.get("gates_named_not_run") or []
    lines.append("")
    lines.append("gates_run: %s" % json.dumps(gates_run, sort_keys=True))
    lines.append("gates_named_not_run: %s" % json.dumps(gates_named_not_run))
    return "\n".join(lines)


def build_chain_prompt(r, claims, candidates):
    lines = ["SESSION_DISTILL_PASS: chain", "RUN_ID: %s" % r["id"], "", "--- LABELS ---"]
    for label in LABELS:
        lines.append("%s: %s" % (label, LABEL_DEFINITIONS[label]))
    # #286: the deterministic flags, so proxy-as-thing on an exit read rests
    # on the per-pipeline check rather than on the model spotting a pipe.
    flagged = [v for v in (r.get("verifications") or [])
               if v.get("exit_masked_by_pipe") or v.get("empty_ci_result")]
    lines.append("")
    lines.append("--- VERIFICATION FLAGS (deterministic, %d) ---" % len(flagged))
    if not flagged:
        lines.append("(none: no gate's exit status was read through a pipe, "
                     "and no CI read returned an empty rollup)")
    for v in flagged:
        flags = [n for n in ("exit_masked_by_pipe", "empty_ci_result") if v.get(n)]
        lines.append("[%d] %s: %s" % (v.get("index"), ",".join(flags), v.get("command")))
    lines.append("")
    lines.append("--- CLAIMS ---")
    for c in claims:
        lines.append(json.dumps(c, ensure_ascii=False))
    lines.append("")
    lines.append("--- CANDIDATE LATER MENTIONS ---")
    if not candidates:
        lines.append("(none found)")
    for cand in candidates:
        lines.append("run=%s at=%s artifact=%r repo_match=%s" % (
            cand["run"], cand.get("started_at"), cand["artifact"], cand.get("repo_match", "n/a")))
        lines.append("  %s" % cand["excerpt"])
    return "\n".join(lines)


def run_stub_public(r):
    """The `run` sub-object as it appears in a written RECORD -- provenance
    and counts only, never the full brief/report text or the tool trace
    (that stays out-of-band in the transcript `transcript` already
    points at, and in the `runs` command's own richer stub)."""
    out = {
        "id": r["id"],
        "kind": r["kind"],
        "spawned_by": r.get("spawned_by"),
        "agent_type": r.get("agent_type"),
        "model": r.get("model"),
        "description": r.get("description"),
        "workflow_phase": r.get("workflow_phase"),
        "started_at": r.get("started_at"),
        "ended_at": r.get("ended_at"),
        "transcript": r.get("transcript"),
        "brief_chars": r.get("brief_chars", 0),
        "report_chars": r.get("report_chars", 0),
        # #285: on every stub, both kinds -- "structured_output" |
        # "harness_error" | "text" | "none" for a subagent, only "text" |
        # "none" for a main-turn. Never absent: a silent empty report is
        # exactly the defect this field exists to make visible.
        "report_source": r.get("report_source"),
        "tool_calls": r.get("tool_calls", 0),
    }
    if r["kind"] == "main-turn":
        out["segmented_by"] = r.get("segmented_by")
    return out


def warn_dropped_later_wrong(run_id, dropped_lw):
    """Print one stderr warning per entry `build_record` dropped from
    `later_wrong` -- a bare claim reference (#278 C2's unresolvable-claim
    case) or a dict `{"claim","run","reason":"repo-ambiguous-only"}`
    (#287's repo-ambiguity case) -- never silent either way. The single
    place both drop reasons get surfaced, so cmd_distill's three call
    sites (the two budget-stop paths and the normal completion path)
    cannot drift out of sync on wording."""
    for dc in dropped_lw:
        if isinstance(dc, dict) and dc.get("reason") == "repo-ambiguous-only":
            print(
                "warning: run %s: later_wrong entry for claim %r contradicted_by.run=%r "
                "was linked ONLY through ambiguous-repo #N candidate(s) -- dropped "
                "(repo-ambiguous-only)" % (run_id, dc.get("claim"), dc.get("run")),
                file=sys.stderr)
        else:
            print("warning: run %s: later_wrong entry names an unresolvable claim %r -- dropped"
                  % (run_id, dc), file=sys.stderr)


def build_record(sid, run_stub, distilled_doc, chain_doc, distilled_at, model_name, cost_usd,
                  passes, candidates=None):
    """(record, dropped_later_wrong[]) -- dropped_later_wrong carries the
    claim references any `later_wrong` entry named that did not resolve to
    a real claim id (#278 C2), or (#287) a dict `{"claim","run","reason":
    "repo-ambiguous-only"}` for an entry whose only link to its
    contradicted_by.run was an ambiguous-repo #N candidate -- so the
    caller can warn about either rather than the drop happening with no
    trace anywhere. CANDIDATES is the list `find_chain_candidates`
    produced for this run (#287); omitted (None) when the caller has none
    (e.g. a budget-stop record with only a distill pass), in which case
    the repo-ambiguity check simply never fires.

    #291: every claim gets a `proof_located` flag (True/False for a
    non-null `proof`, None for a null one) against RUN_STUB's own
    `tool_inputs_full` -- computed here, once, on the SAME `claims` list
    this record persists, so the written record and the live guard in
    `cmd_distill` (which checks the SAME thing before this function is
    even called, to decide the placeholder-response FAILURE) never see
    two different derivations of the same fact."""
    claims = normalize_claims((distilled_doc or {}).get("claims"))
    compute_proof_located(claims, run_stub.get("tool_inputs_full") or [])
    claim_ids = {c["id"] for c in claims}
    later_wrong, dropped_later_wrong, lw_index_map = normalize_later_wrong(
        (chain_doc or {}).get("later_wrong") if chain_doc else None, claim_ids, candidates)
    classified_as, unclassified_reason = enforce_classified_as(
        (chain_doc or {}).get("classified_as") if chain_doc else None, claims, later_wrong,
        lw_index_map,
        withdrawn=[d["index"] for d in dropped_later_wrong if isinstance(d, dict)])
    record = {
        "kind": "session-distill-record",
        "schema_version": SCHEMA_VERSION,
        "session": sid,
        "run": run_stub_public(run_stub),
        "asked": (distilled_doc or {}).get("asked") or "",
        "understood": (distilled_doc or {}).get("understood") or "",
        "delivered": (distilled_doc or {}).get("delivered") or "",
        "claims": claims,
        # #285: DETERMINISTIC, computed once in build_all_run_stubs (no
        # model call) -- persisted verbatim regardless of what the distill/
        # chain calls returned, so a model that ignores VERIFICATION
        # COMMANDS in the prompt still leaves an auditable trail on the
        # record itself.
        "verifications": run_stub.get("verifications") or [],
        "gates_run": run_stub.get("gates_run") or {cat: 0 for cat in GATE_CATEGORIES},
        "gates_named_not_run": run_stub.get("gates_named_not_run") or [],
        "later_wrong": later_wrong,
        "classified_as": classified_as,
        "unclassified_reason": unclassified_reason,
        # #287: repo-ambiguous drops persist on the record, not only on
        # stderr, so a reader of the record can see what the chain pass
        # proposed and why it was withdrawn.
        "later_wrong_withdrawn": [d for d in dropped_later_wrong if isinstance(d, dict)],
        "distilled": {
            "at": distilled_at,
            "model": model_name,
            "cost_usd": round(cost_usd, 6),
            "passes": passes,
        },
    }
    return record, dropped_later_wrong


# -------------------------------------------------------------------------- commands

def cmd_schema(a):
    print(json.dumps({
        "record_schema_version": SCHEMA_VERSION,
        "labels": list(LABELS),
        "distill_call_schema": DISTILL_SCHEMA,
        "chain_call_schema": CHAIN_SCHEMA,
    }, indent=2, sort_keys=False))
    return 0


def cmd_runs(a):
    rr = load_review_result()
    sid = rr.resolve_session_id(a.session)
    session_dir = rr.resolve_session_dir(sid)
    segmented_by, runs, unreadable, repo_vocabulary = build_all_run_stubs(rr, session_dir)
    main_turns = sum(1 for r in runs if r["kind"] == "main-turn")
    subagent_runs = sum(1 for r in runs if r["kind"] == "subagent")

    doc = {
        "kind": "session-distill-runs",
        "schema_version": SCHEMA_VERSION,
        "session": sid,
        "session_dir": session_dir,
        "segmented_by": segmented_by,
        "main_turns": main_turns,
        "subagent_runs": subagent_runs,
        "runs": runs,
        "unreadable": unreadable,
        # #287: the session-wide repo vocabulary every run's own `repos`
        # set (also on each run stub above) was resolved against.
        "repo_vocabulary": sorted(repo_vocabulary),
    }

    if a.json:
        print(json.dumps(doc, indent=2, ensure_ascii=False))
    else:
        print("session: %s" % sid)
        print("segmented_by: %s" % segmented_by)
        print("main_turns: %d   subagent_runs: %d   total: %d" % (main_turns, subagent_runs, len(runs)))
        for r in runs:
            print("  %-18s %-10s %-10s brief=%-6d report=%-6d src=%-17s tools=%d  %s" % (
                r["id"], r["kind"], r.get("spawned_by") or "-",
                r["brief_chars"], r["report_chars"], r.get("report_source") or "-",
                r["tool_calls"], (r.get("description") or "")[:40]))
        if unreadable:
            print("unreadable:")
            for u in unreadable:
                print("  %s" % u)

    # #278 C1: an unreadable/unparseable transcript is never a silent
    # zero -- same discipline as rework-lag.py's `unknown[]`. The JSON is
    # still emitted in full; the exit code is what tells an automated
    # caller the inventory may be incomplete.
    for u in unreadable:
        print("warning: could not fully read: %s" % u, file=sys.stderr)
    return 2 if unreadable else 0


def cmd_distill(a):
    rr = load_review_result()
    sid = rr.resolve_session_id(a.session)
    session_dir = rr.resolve_session_dir(sid)

    try:
        model_cmd = shlex.split(a.model_cmd)
    except ValueError as e:
        die("--model-cmd %r could not be parsed as a shell command (%s)" % (a.model_cmd, e))
    if not model_cmd:
        die("--model-cmd is empty")

    segmented_by, all_runs, unreadable, repo_vocabulary = build_all_run_stubs(rr, session_dir)

    if a.only:
        all_runs_for_run = [r for r in all_runs if r["id"] == a.only]
        if not all_runs_for_run:
            die("--only %r matches no run in this session" % a.only)
    else:
        all_runs_for_run = all_runs

    out_path = a.out if a.out else os.path.join(session_dir, "session-distill.json")

    existing_doc = None
    if a.resume and out_path != "-" and os.path.exists(out_path):
        try:
            with open(out_path, encoding="utf-8") as f:
                existing_doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            die("--resume could not read existing %s (%s)" % (out_path, e))
        # #285: a document written under a different schema_version has a
        # different record shape (this version added report_source/
        # verifications/gates_run/gates_named_not_run) -- resuming into it
        # would silently mix old-shape and new-shape records in the same
        # records[] list, which is exactly the kind of drift this script's
        # own REUSE discipline exists to refuse rather than paper over.
        existing_schema = existing_doc.get("schema_version") if isinstance(existing_doc, dict) else None
        if existing_schema != SCHEMA_VERSION:
            die(
                "--resume: %s was written with schema_version %r, this "
                "script now writes schema_version %d -- mixing schema "
                "versions in one records[] list is not supported. Move "
                "the old file aside and redistill from scratch (with "
                "--force, without --resume), or resume a document that "
                "was written with the current schema."
                % (out_path, existing_schema, SCHEMA_VERSION))
    elif not a.resume and out_path != "-" and os.path.exists(out_path) and not a.force and not a.dry_run:
        die("%s already exists -- pass --force to overwrite, or --resume to continue it" % out_path)
    elif (a.force and not a.resume and out_path != "-" and os.path.exists(out_path)
          and not a.dry_run and (a.only or a.limit is not None)):
        # #278 N3: --force alone (no --resume) always overwrites the WHOLE
        # document -- `records` is only ever seeded from disk under
        # --resume. Combined with --only/--limit that silently rewrites an
        # existing multi-run document down to just the newly-processed
        # run(s), discarding every other run's record with no trace. This
        # cannot un-guess what the caller meant, so at minimum it warns
        # loudly with the count of records about to be discarded, rather
        # than truncating in silence.
        try:
            with open(out_path, encoding="utf-8") as f:
                prior = json.load(f)
            prior_n = len(prior.get("records") or [])
        except (OSError, json.JSONDecodeError):
            prior_n = None
        if prior_n:
            print(
                "warning: --force without --resume replaces %s entirely -- "
                "%d existing record(s) will be discarded because --only/--limit "
                "narrows this run to a subset (pass --resume to keep them)"
                % (out_path, prior_n), file=sys.stderr)

    records = []
    failures = []
    total_cost = 0.0
    done_ids = set()
    if existing_doc:
        records = existing_doc.get("records") or []
        failures = existing_doc.get("failures") or []
        total_cost = existing_doc.get("total_cost_usd") or 0.0
        done_ids = {
            rec["run"]["id"] for rec in records
            if isinstance(rec, dict) and isinstance(rec.get("run"), dict) and rec["run"].get("id")
        }

    todo = [r for r in all_runs_for_run if r["id"] not in done_ids]
    if a.limit is not None:
        todo = todo[:a.limit]

    if a.dry_run:
        calls = len(todo) * 2
        projected = calls * DEFAULT_COST_PER_CALL_USD
        print("session: %s" % sid)
        print("session_dir: %s" % session_dir)
        print("segmented_by: %s" % segmented_by)
        print("runs in session: %d   selected (after --only): %d   already done (resume): %d   to process: %d" % (
            len(all_runs), len(all_runs_for_run), len(done_ids), len(todo)))
        for r in todo:
            print("  %-18s %-10s %s" % (r["id"], r["kind"], (r.get("description") or "")[:50]))
        # #278 M2: the projection states its basis instead of a bare
        # number -- DEFAULT_COST_PER_CALL_USD is a fixed constant measured
        # 2026-09-20 on real payloads (see its own comment), not a formula;
        # --dry-run makes zero calls, so it is the only basis available.
        print("calls (projected): %d   cost (projected): $%.4f  "
              "(basis: $%.4f/call, DEFAULT_COST_PER_CALL_USD measured 2026-09-20 "
              "on real payloads -- no live calls made yet to calibrate against)"
              % (calls, projected, DEFAULT_COST_PER_CALL_USD))
        if unreadable:
            print("unreadable:")
            for u in unreadable:
                print("  %s" % u)
        for u in unreadable:
            print("warning: could not fully read: %s" % u, file=sys.stderr)
        return 2 if unreadable else 0

    # #278 M2: the running budget check uses the CALIBRATED average of
    # this invocation's own observed call costs once at least one call has
    # returned a cost, rather than trusting the fixed
    # DEFAULT_COST_PER_CALL_USD estimate for the whole run -- a session's
    # real payloads vary, and the old code compared every check against
    # the same one-token-prompt-derived constant regardless of what the
    # calls actually cost.
    observed_costs = []

    def calibrated_cost_per_call():
        if observed_costs:
            return sum(observed_costs) / len(observed_costs)
        return DEFAULT_COST_PER_CALL_USD

    def over_budget():
        return a.max_cost_usd is not None and total_cost > a.max_cost_usd

    def projected_over_budget():
        return (a.max_cost_usd is not None
                and (total_cost + calibrated_cost_per_call()) > a.max_cost_usd)

    stopped = None
    for r in todo:
        if over_budget():
            stopped = {
                "reason": "max-cost-usd already exceeded by observed spend",
                "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
            }
            break
        if projected_over_budget():
            stopped = {
                "reason": "max-cost-usd projected to be exceeded before this run's distill call",
                "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
            }
            break

        distilled_doc, cost1, err1 = run_model(
            model_cmd, DISTILL_SYSTEM_PROMPT, DISTILL_SCHEMA, build_distill_prompt(r),
            a.timeout_secs)
        total_cost += cost1
        observed_costs.append(cost1)
        if err1:
            failures.append({"run": r["id"], "phase": "distill", "error": err1})
            # #278 M2: checked AFTER the call too, using OBSERVED spend --
            # a call that errors can still have spent money (run_model's
            # own contract), and a budget that only ever checks BEFORE a
            # call never notices that until the next run's pre-check.
            if over_budget():
                stopped = {
                    "reason": "max-cost-usd exceeded by observed spend after this run's (failed) distill call",
                    "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
                }
                break
            continue

        # #291: the placeholder-response guard -- a schema-valid distill
        # response whose every non-null proof fails to locate in this
        # run's own (untruncated) tool inputs is a FAILURE, never a
        # record, and the chain call is NEVER made for it (nothing to
        # spend on top of a result this hollow). cost1 -- already spent --
        # is still folded into total_cost/observed_costs above, same
        # discipline as the err1 path just above.
        is_placeholder, n_nonnull, n_unlocatable = claims_all_proofs_unlocatable(
            distilled_doc, r.get("tool_inputs_full") or [])
        if is_placeholder:
            failures.append({
                "run": r["id"], "phase": "distill",
                "error": (
                    "proof-not-in-trace: every non-null proof (%d of %d claim(s)) failed "
                    "to locate in this run's own tool inputs -- a schema-valid but "
                    "content-free (placeholder) response" % (n_unlocatable, n_nonnull)),
            })
            if over_budget():
                stopped = {
                    "reason": "max-cost-usd exceeded by observed spend after this run's (failed) distill call",
                    "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
                }
                break
            continue

        if over_budget():
            record, dropped_lw = build_record(
                sid, r, distilled_doc, None, now_iso(),
                model_name_from_cmd(model_cmd), cost1, ["distill"])
            records.append(record)
            warn_dropped_later_wrong(r["id"], dropped_lw)
            stopped = {
                "reason": "max-cost-usd exceeded by observed spend after this run's distill call",
                "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
            }
            break
        if projected_over_budget():
            record, dropped_lw = build_record(
                sid, r, distilled_doc, None, now_iso(),
                model_name_from_cmd(model_cmd), cost1, ["distill"])
            records.append(record)
            warn_dropped_later_wrong(r["id"], dropped_lw)
            stopped = {
                "reason": "max-cost-usd projected to be exceeded before this run's chain call",
                "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
            }
            break

        claims = normalize_claims(distilled_doc.get("claims"))
        other_runs = [x for x in all_runs if x["id"] != r["id"]]
        current_repos = set(r.get("repos") or [])
        candidates = find_chain_candidates(
            claims, r.get("started_at"), current_repos, other_runs, repo_vocabulary)

        chain_doc, cost2, err2 = run_model(
            model_cmd, CHAIN_SYSTEM_PROMPT, CHAIN_SCHEMA, build_chain_prompt(r, claims, candidates),
            a.timeout_secs)
        total_cost += cost2
        observed_costs.append(cost2)
        passes = ["distill"]
        if err2:
            failures.append({"run": r["id"], "phase": "chain", "error": err2})
            chain_doc = None
        else:
            passes.append("chain")

        # #278 N2: the record's own cost_usd now always includes cost2,
        # matching what was just added to total_cost unconditionally --
        # the OLD code added cost2 to total_cost regardless of err2 (a
        # failed call can still have spent money) but recorded only cost1
        # on the record when err2, so sum(record costs) != total_cost_usd.
        record, dropped_lw = build_record(
            sid, r, distilled_doc, chain_doc, now_iso(),
            model_name_from_cmd(model_cmd), cost1 + cost2, passes, candidates)
        records.append(record)
        warn_dropped_later_wrong(r["id"], dropped_lw)

        if over_budget():
            stopped = {
                "reason": "max-cost-usd exceeded by observed spend after this run's chain call",
                "at_run": r["id"], "budget": a.max_cost_usd, "spent": round(total_cost, 6),
            }
            break

    doc = {
        "kind": "session-distill-document",
        "schema_version": SCHEMA_VERSION,
        "session": sid,
        "session_dir": session_dir,
        "generated_at": now_iso(),
        "segmented_by": segmented_by,
        "model_cmd": a.model_cmd,
        "total_cost_usd": round(total_cost, 6),
        # #278 N3: the session's real total is distinct from how many runs
        # THIS invocation selected (--only narrows to one; --limit narrows
        # `todo` further but does not change selection) -- a document
        # calling itself the session's own record should not report "1"
        # for a session that has 160 runs just because this call used
        # --only.
        "runs_total": len(all_runs),
        "runs_selected": len(all_runs_for_run),
        "records": records,
        "failures": failures,
        "unreadable": unreadable,
        "stopped": stopped,
    }
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"

    if out_path == "-":
        sys.stdout.write(text)
    else:
        rr.atomic_write(out_path, text)
        print("session-distill: %s" % os.path.abspath(out_path))
        print("runs_total: %d  runs_selected: %d  records: %d  failures: %d  cost_usd: $%.4f" % (
            len(all_runs), len(all_runs_for_run), len(records), len(failures), total_cost))
        if stopped:
            print("stopped: %s" % stopped["reason"])
        if unreadable:
            print("unreadable:")
            for u in unreadable:
                print("  %s" % u)

    for u in unreadable:
        print("warning: could not fully read: %s" % u, file=sys.stderr)
    return 2 if unreadable else 0


def cmd_report(a):
    if a.in_path:
        path = a.in_path
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            die("cannot read %s (%s)" % (path, e))
    else:
        rr = load_review_result()
        sid = rr.resolve_session_id(a.session)
        session_dir = rr.resolve_session_dir(sid)
        path = os.path.join(session_dir, "session-distill.json")
        if not os.path.exists(path):
            die("no %s -- run `distill` first, or pass --in" % path)
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            die("cannot read %s (%s)" % (path, e))

    if a.json:
        print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0

    records = doc.get("records") or []
    label_counts = {}
    label_runs = {}
    later_wrong_total = 0
    unclassified = []
    # #285: report_source and verification-flag counts -- a silent empty
    # report (report_source != "text") or a masked/omitted gate must be
    # VISIBLE in every plain `report` run, never only discoverable by
    # reading the raw JSON.
    report_source_counts = {"text": 0, "structured_output": 0, "structured_output_rejected": 0,
                            "harness_error": 0, "none": 0}
    exit_masked_runs = 0
    empty_ci_runs = 0
    gates_named_not_run_runs = 0
    # #291: the placeholder-response guard's own visibility -- how often a
    # SURVIVING record (the all-unlocatable case is never a record at all;
    # see `failures` above) still carries at least one unlocatable proof.
    proofs_nonnull = 0
    proofs_unlocatable = 0
    for rec in records:
        for ca in rec.get("classified_as") or []:
            label = ca.get("label")
            label_counts[label] = label_counts.get(label, 0) + 1
        for label in {ca.get("label") for ca in rec.get("classified_as") or []}:
            label_runs[label] = label_runs.get(label, 0) + 1
        later_wrong_total += len(rec.get("later_wrong") or [])
        if rec.get("unclassified_reason"):
            run = rec.get("run") or {}
            unclassified.append((run.get("id"), rec["unclassified_reason"]))

        src = (rec.get("run") or {}).get("report_source")
        report_source_counts[src] = report_source_counts.get(src, 0) + 1
        verifications = rec.get("verifications") or []
        if any(v.get("exit_masked_by_pipe") for v in verifications):
            exit_masked_runs += 1
        if any(v.get("empty_ci_result") for v in verifications):
            empty_ci_runs += 1
        if rec.get("gates_named_not_run"):
            gates_named_not_run_runs += 1
        for c in rec.get("claims") or []:
            pl = c.get("proof_located")
            if pl is not None:
                proofs_nonnull += 1
                if pl is False:
                    proofs_unlocatable += 1

    print("session: %s" % doc.get("session"))
    print("records: %d   failures: %d   cost_usd: $%.4f" % (
        len(records), len(doc.get("failures") or []), doc.get("total_cost_usd") or 0.0))
    if doc.get("stopped"):
        print("stopped: %s" % doc["stopped"].get("reason"))
    if doc.get("unreadable"):
        print("unreadable: %d (see doc's unreadable[] for detail)" % len(doc["unreadable"]))
    print()
    # #285: printed unconditionally, even at 0 -- "text" and
    # "structured_output" are the healthy sources, "harness_error" and
    # "none" must never be silent regardless of how many runs hit them.
    print("report_source distribution:")
    for src in ("text", "structured_output", "structured_output_rejected", "harness_error", "none"):
        print("  %-28s %d" % (src, report_source_counts.get(src, 0)))
    # A record with no report_source was written before schema 2 (or by
    # something else); it is counted in `records:` above, so it must be
    # counted here too rather than vanish from the distribution.
    unrecorded = sum(n for k, n in report_source_counts.items()
                     if k not in ("text", "structured_output", "structured_output_rejected",
                                  "harness_error", "none"))
    if unrecorded:
        print("  %-28s %d" % ("(no report_source: pre-v2)", unrecorded))
    print()
    print("verification flags: exit_masked_by_pipe=%d run(s)   empty_ci_result=%d run(s)   "
          "gates_named_not_run=%d run(s)" % (exit_masked_runs, empty_ci_runs, gates_named_not_run_runs))
    # #291: printed unconditionally (0/0 included) -- proof_located is a
    # per-claim FLOOR, and a silent absence of unlocatable proofs must be
    # readable as "checked, none found" rather than "never printed".
    proof_rate = (100.0 * proofs_unlocatable / proofs_nonnull) if proofs_nonnull else 0.0
    print("proof_located: %d/%d non-null claim proof(s) unlocatable (%.1f%%)" % (
        proofs_unlocatable, proofs_nonnull, proof_rate))
    print()
    # #286: a class hit reads against its BASE RATE -- the share of runs
    # carrying the label at all. On 13cee7be proxy-as-thing sat on 79% of
    # runs, so "the right run carries it" was near-certain by chance.
    print("classified_as label distribution (entries, runs carrying it, share of %d runs):"
          % len(records))
    for label in LABELS:
        if label_counts.get(label):
            runs = label_runs.get(label, 0)
            share = (100.0 * runs / len(records)) if records else 0.0
            print("  %-32s %4d  %4d  %5.1f%%" % (label, label_counts[label], runs, share))
    print()
    print("later_wrong entries: %d" % later_wrong_total)
    if unclassified:
        print()
        print("unclassified_reason recorded:")
        for run_id, reason in unclassified:
            print("  %s: %s" % (run_id, reason))
    return 0


# ------------------------------------------------------------------------------ main

def build_parser():
    p = argparse.ArgumentParser(
        prog="session-distill.py", description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser(
        "schema", help="print the record schema plus the two model-call schemas"
    ).set_defaults(fn=cmd_schema)

    r = sub.add_parser("runs", help="deterministic run inventory -- no model call")
    r.add_argument("--session", help="session id (default: $CLAUDE_CODE_SESSION_ID)")
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_runs)

    d = sub.add_parser("distill", help="asked/understood/delivered/claims + chain, one model boundary")
    d.add_argument("--session", help="session id (default: $CLAUDE_CODE_SESSION_ID)")
    d.add_argument("--limit", type=int, default=None, help="process at most N NEW runs")
    d.add_argument("--only", default=None, metavar="RUNID", help="process exactly one run")
    d.add_argument("--dry-run", action="store_true", help="print the inventory/cost projection; call nothing")
    d.add_argument("--resume", action="store_true", help="skip runs already in an existing output document")
    d.add_argument("--out", default=None,
                    help="output path, or - for stdout (default: <session-dir>/session-distill.json)")
    d.add_argument("--force", action="store_true", help="overwrite an existing output file")
    d.add_argument("--model-cmd", default=DEFAULT_MODEL_CMD,
                    help="the model invocation, as a shell command line (see module docstring)")
    d.add_argument("--max-cost-usd", type=float, default=None,
                    help="stop before exceeding this cumulative spend")
    d.add_argument("--timeout-secs", type=int, default=MODEL_TIMEOUT_SECS,
                    help="per model call timeout (default %d; a long trace on a "
                         "busy CLI exceeds it)" % MODEL_TIMEOUT_SECS)
    d.set_defaults(fn=cmd_distill)

    rp = sub.add_parser("report", help="summarize a session-distill.json document")
    rp.add_argument("--session", help="session id (default: $CLAUDE_CODE_SESSION_ID)")
    rp.add_argument("--in", dest="in_path", default=None,
                     help="path to a session-distill.json (default: resolved via --session)")
    rp.add_argument("--json", action="store_true")
    rp.set_defaults(fn=cmd_report)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
