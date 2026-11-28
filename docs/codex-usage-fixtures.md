# Codex counter fixtures

`assets/scripts/codex_usage.py` is an experimental, read-only counter reporter.
Its only validation evidence is invented local JSONL fixtures. It does not scan
the user's Codex home, discover children, read accounts, price usage, write a
checkpoint, or change the existing Claude accounting commands.

Supply explicit fixture paths:

```sh
python3 -B assets/scripts/codex_usage.py /tmp/invented-root.jsonl /tmp/invented-child.jsonl
```

The command writes JSON to stdout. Exit 0 means the supplied records satisfied
the supported counter contract, not that usage coverage or pricing is complete.
Exit 1 includes diagnostics for unreadable, malformed, unmeasured or ambiguous
inputs. Missing CLI paths are an argparse usage error (exit 2). Diagnostics
contain source locations and codes, never record contents.

The supported fixture shape is a `session_meta` record with `payload.id`, followed
by timestamped `event_msg` records whose `payload.type` is `token_count` and whose
`payload.info.total_token_usage` contains nonnegative integer `input_tokens`,
`output_tokens` and `total_tokens`. Timestamps require an explicit UTC offset.
`total_tokens` must equal input plus output. Optional `cached_input_tokens` is a
subset of input; optional `reasoning_output_tokens` is a subset of output.
Neither subset is added again. An absent subset stays unknown, not zero.

Repeated cumulative snapshots and copied/resumed files sharing a session ID are
not added together. The report selects one coherent dominating observation per
session. Counter regressions, conflicting observations at one timestamp, or
incomparable snapshots make that session's observation unavailable rather than
guessing a reset or adding epochs. `last_token_usage` is never added to a total.

Different session IDs are reported separately. There is deliberately no grand
total: these files cannot prove whether parent/fork/child counters overlap or
whether all sessions were supplied. Coverage, hierarchy and prices remain
explicitly incomplete or unknown; dollar values are null. This does not establish
support for every live Codex rollout version, metering units, subscription cost,
or complete parent/child attribution. Adding any of those requires its own
observable contract and validation.

The invented regression cases run inside the existing accounting suite:

```sh
python3 -B -m unittest assets/scripts/usage_accounting_test.py
```
