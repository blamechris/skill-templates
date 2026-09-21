# gate-ledger.py — record shape (designed before coding, per #272)

## The question it answers

Plan item 6 of epic #266: *debug the interaction trace before adding a gate* —
otherwise the hook compensates for the wrong failure mode. #263/#264 is the case
it exists for. A guard was built for a frozen sample file, and the freeze was
never real. The trace showed an idle account plus a genuine plan reset; the
actual failure was the orchestrator's, `absence-without-second-search`. The
guard targeted a sensor defect and the trace named a reasoning defect. Nothing
recorded either fact, so nothing could compare them.

The ledger records, for every gate, **the failure mode it targets** (a label from
`session-distill.py`'s closed vocabulary) and **the evidence chain that justified
it**. `gate-ledger.py report` then joins that to `session-distill.json` output by
label and to `pr-records.jsonl` by `(repo, pr)`, and says per gate whether:

- the trace was ever debugged (`untraced`);
- the trace names the mode the gate targets (`mislabelled`);
- the mode recurs after the gate (`recurring`);
- the mode was never observed at all (`suspect`).

## The unit: one gate

A gate is anything added to stop an agent doing a thing: a `skill-guards.json`
guard, a Claude Code hook, a CI step, a refusal inside a script, a doctrine rule.
There is one record per gate. It lives **next to the gate it describes**, so a
rename or deletion of the gate carries its record with it:

| kind | where the record lives | id |
|---|---|---|
| `skill-guard` | a `gate` field on the guard object in `skill-guards.json` | `<skill>/<label>`, derived |
| `hook`, `ci-step`, `script-check`, `doctrine` | one line in `gates.jsonl` at the registry root | given, `^[a-z0-9][a-z0-9./-]*$` |

The registry is **public**, so a record holds only pointers: PR and issue numbers,
session ids, run ids and claim ids. It holds no transcript quotes. The quotes
stay in the private session-distill output, and the pointer resolves to them.

A guard with no `gate` field is **legacy**, not invalid. Most of the ~270
existing guards predate this ledger. `check` counts them and does not fail on
them. Requiring a record on *new* guards is a follow-on, and it needs a diff
against the base, which `check` does not have.

## The record (schema_version 1)

Illustrative values; a `gates.jsonl` line carries all of these. A `gate` field in `skill-guards.json`
carries `targets`, `added`, `evidence` and an optional `note`. Its `id` and `kind`
are derived from the guard, `where` is the guard's own location, and
`schema_version` defaults to 1, so all four are optional there.

```json
{
  "schema_version": 1,
  "id": "example/illustrative-hook",
  "kind": "hook",
  "where": "~/.claude/settings.json UserPromptSubmit -> some-script.py --hook",
  "targets": [
    {"label": "green-as-done",
     "mode": "one sentence: the concrete failure this gate stops"}
  ],
  "added": {"repo": "blamechris/skill-templates", "pr": 275, "at": "2026-09-20T19:31:10Z"},
  "evidence": [
    {"kind": "distill", "session": "13cee7be-...", "run": "agent-a55f...", "claim": "c1"},
    {"kind": "trace",   "session": "13cee7be-...", "run": "agent-a353...", "at": "2026-09-20T01:26:30Z"},
    {"kind": "issue",   "repo": "blamechris/skill-templates", "number": 267},
    {"kind": "pr",      "repo": "blamechris/skill-templates", "number": 275}
  ],
  "note": "optional free text"
}
```

- **`targets[].label`** must be in the vocabulary that `session-distill.py`
  defines. The script imports that tuple rather than restating it, which is the
  second-derivation rule. `unclassified` is allowed. A gate against a sensor, a
  race or a git filter is not an agent misreport, and forcing a checklist label
  onto it would be the invented-label failure. An `unclassified` target requires
  a non-empty `mode`. A gate whose targets are all `unclassified` cannot be
  joined by label, and the report says so rather than scoring it.
- **`added`** is the PR that landed the gate. `at` is its merge time as a full
  UTC timestamp, the instant the recurrence clock starts. `(repo, pr)` is
  `pr-record.py`'s key, used as-is. The ledger adds no second key.
- **`evidence[]`** must be non-empty. The four kinds split into two classes:
  - **Traced:** `distill` and `trace`. `distill` points at a session-distill
    record, which has a machine-checkable label. `trace` points at a run and a
    timestamp that a person read by hand. The ground-truth corrections of
    2026-09-20 are this kind.
  - **Asserted:** `issue` and `pr`. They point at where the gate was *argued
    for*. Neither shows that anyone read the trace.

  A gate with only asserted evidence is `untraced`, whatever else the report
  finds. That is the #263 shape, and it is visible the day the gate is recorded.
  The report does not need recurrence data to see it.

## Verdicts (`report`, first match wins)

| verdict | condition |
|---|---|
| `invalid` | the record itself fails the same checks `check` runs. `report` never crashes on a malformed record and never silently scores one as clean; it names the reasons and moves on to the next gate. |
| `untraced` | no `distill` or `trace` evidence |
| `evidence-unverified` | has `distill` evidence, but a given `--distill` file set does not resolve every one of it to a **loaded** classification. A distill record whose chain pass never ran (`"chain"` not in `distilled.passes`) or that is named in its document's own `failures[]` does not count as loaded, even when it was found — its `classified_as` was never really produced, and reading it as a real "no matching label" would be `mislabelled` on an untested run. This is never a silent pass, and it never degrades to `mislabelled` just because *some* of several `distill` evidence entries resolved. |
| `mislabelled` | every `distill` evidence record resolved to a loaded classification, and **none** of them carries a `classified_as` label in the gate's `targets`. When a claim is named, the label must `supports` that claim. The trace names a different mode from the one the gate targets. |
| `not-joinable` | the gate is traced, and all of its targets are `unclassified` |
| `incomplete` | the distilled data available cannot certify an absence — see INCOMPLETE below. Checked **after** a possible `recurring` match, since recurrence is positive evidence that survives incompleteness elsewhere in the corpus. |
| `unobserved` | fewer than `--min-sessions` (default 5) distinct distilled **sessions** — never runs — have any run that started strictly after `added.at` |
| `recurring` | at least one distilled run, with a resolvable session, a real `run.id` and a parseable timestamp, started strictly **after** `added.at` (not at or before it) and carries a target label. The report lists the run ids. |
| `suspect` | there are enough sessions after the gate and no recurrence, **and** the target label appears in no distilled run anywhere, before the gate or after it. The mode was never observed by the instrument, which is the issue's wording. |
| `quiet` | there are enough sessions after the gate and no recurrence, and the mode was observed before the gate |

`trace` evidence counts as traced, but no machine can check its label. The report
prints `trace-unverified` beside the verdict so that it does not read as confirmed.

### INCOMPLETE

A run that carries a target label but whose `started_at` is missing or
unparseable, whose `run.id` is missing, or whose session identity is
unresolvable, cannot safely support an absence claim — it might be the very
recurrence `unobserved`/`suspect`/`quiet` would otherwise assert never
happened. A run's session identity is its own `session` field (every
session-distill record carries one) falling back to its document's
`session` only when the record's own is absent — neither present is the
same unresolvable case. The same is true of the corpus as a whole: any loaded
`--distill` document with `stopped` set, a non-empty `unreadable[]`, a
non-empty `failures[]`, or `runs_selected` less than `runs_total` means the
distill run that produced it did not see everything, so nothing computed
from it can certify a clean absence either. `report` prints every
contributing reason.

The one exception is `recurring`: a properly-dated, fully-identified
recurrence is positive evidence, unaffected by incompleteness elsewhere, and
fires even when other documents or runs in the same invocation are
incomplete — which is why `recurring` is evaluated **before** `incomplete`
is issued, despite sitting after it in the table above. `suspect`, `quiet`
and `unobserved` are absence claims and are **never** issued from incomplete
data.

### Timestamps

Every timestamp gate-ledger.py compares (`added.at`, a `trace` evidence
entry's `at`, a distilled run's `started_at`) is parsed with pr-record.py's
own `parse_iso` (imported, not re-implemented), with one policy added on
top that pr-record.py does not need: a **naive** timestamp — no trailing
`Z` and no explicit `+HH:MM`/`-HH:MM` offset — is treated as unparseable,
never silently assumed to be UTC. `check` applies the same rule to
`added.at` and a `trace` evidence entry's `at`.

## Inputs, and how they fail

- **Registry:** `--registry DIR` defaults to the git toplevel of the cwd. Under
  it are `skill-guards.json`, which is required, and `gates.jsonl`. An **absent**
  `gates.jsonl` means zero records. An **unreadable or unparseable** one is an
  error with exit 2, naming the file and line. Absent and broken are different
  states and never print the same output.
- **`--distill PATH` (repeatable, optional):** each must be a readable, UTF-8
  `session-distill.json` document of the right `kind`, whose `records` field,
  when present, is a list. Anything else is exit 2 naming the path. A missing
  or garbage input never becomes an empty record set, because that is the
  silent-zero failure fixed twice in this epic. Zero files is legal — a gate
  with `distill` evidence then reads `evidence-unverified`, never a silent
  pass. The same `(session, run)` pair loaded from two different `--distill`
  files is exit 2, naming both paths, rather than letting whichever file
  loads last silently win.
- **`--pr-records PATH`:** the default is `pr-record.py`'s own ledger-path
  constant, imported. If the default is absent, every gate reports
  `pr_record: no-ledger`. If an explicitly given path is absent, that is exit 2.
  A present ledger reports `found` or `missing` per gate. The report never
  guesses at a PR from a title or branch. The key is `(repo, pr)` or nothing.
  Every line of a resolved ledger is validated as JSON up front — a garbage
  line is exit 2 naming the path and line, never silently read as "missing"
  for whatever gate happens to ask — and each gate's own lookup reuses
  pr-record.py's own `_classify_ledger_line` rather than a second copy of its
  kind/repo/pr checks.

## Commands

```
gate-ledger.py schema                 # this shape as JSON Schema
gate-ledger.py check  [--registry D]  # validate every record; exit 1 on any invalid
gate-ledger.py list   [--registry D] [--json]
gate-ledger.py report [--registry D] [--distill P ...]
                      [--pr-records P] [--min-sessions N] [--json]
```

`--min-sessions` must be `>= 1` (an argparse usage error otherwise).

`check` runs in CI against the registry itself. It rejects:
- a label outside the vocabulary;
- an `unclassified` target with no `mode`;
- empty `evidence`;
- an evidence entry missing the fields its kind requires;
- an `added.at`, or a `trace` evidence entry's `at`, that is not a full UTC
  timestamp — an explicit `Z` or `+HH:MM`/`-HH:MM` offset is required; a naive
  timestamp is invalid (see Timestamps above);
- a non-integer `pr` or `number`;
- a missing or malformed `added.repo` (must be an `OWNER/NAME` string);
- a `schema_version` that is present but not `1`;
- a duplicate id across both sources;
- a `gates.jsonl` kind of `skill-guard`, because that record belongs on the guard;
- an unknown top-level key, because a typo in `evidence` must not become a record
  with no evidence — this also catches `"gate": null` on a guard, which is a
  present-but-invalid key, not the same as the key being absent (legacy).

## The worked example (acceptance item 1)

The worked example is `agent-review/structured-review-result`, added by #275
(fixing #267). The gate targets `green-as-done`: without the structured result,
asserted and mutation-proven findings read the same. Its evidence is issue #267
and PR #275. **Its verdict is `untraced`**, which is the truthful answer. The
plan's ground-truth row, *"every fix round left a can't-fail assertion"*, was
observed in session `13cee7be` and never pinned to a run. When #273 distills that
session, the record gains a `distill` pointer, or it turns out `mislabelled`.
Either result is information the ledger did not have before.

The #263/#264 guard is the test fixture for `mislabelled`, not a ledger line. It
never merged, and the ledger records gates that exist.

## Acceptance

- [ ] ledger format decided (this document), with one entry written for an
      existing gate
- [ ] `session-distill.py` output joins to it by label: `report` over a fixture
      distill document yields each verdict above
- [ ] `.test.sh` is hermetic, and every verdict and every exit-2 path is pinned
      by a test that fails when its branch is deleted. CI step by name; bootstrap
      line.
