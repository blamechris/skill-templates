# Usage accounting repair: staged rollout

This repository contains the candidate helpers and instructions. Merging this PR does
not install them. The existing `~/.claude` helpers, meter readings, benchmark ledger,
and paused cost breaker remain unchanged until a separately approved rollout.

## Before installation

1. Merge the small usage-pace reset-test PR (#356) first, then this PR after review.
2. Record the installed helper hashes and copy the installed files to a dated backup
   outside the transcript and ledger directories. Back up `~/.claude/CLAUDE.md` if
   installing the new global instructions later.
3. Run the repository suites and a read-only scan of a retained transcript sample.
   Compare the exact rate-card version, unpriced coverage, parent/child response
   counts, and lower/upper dollar totals. Do not infer meter percentages from dollars.
4. At a quiet session boundary, install `usage_accounting.py`, `usage-pace.py`,
   `usage-benchmark-row.py`, and `usage-checkpoint.py` together in
   `~/.claude/scripts/`. Copy `usage-trend.py` and `usage_accounting.py` together
   to `~/.claude/usage-history/`, the existing scheduled trend path; the sibling
   import then works without changing `PYTHONPATH`. Confirm that the schedule still
   uses that path before installation. Install the edited global
   and session-lifecycle instructions only at that same boundary.
5. First run of pace intentionally invalidates its old cache and anchors under
   `coherent-response-exact-rates-2026-09-30` and rebuilds from raw JSONL. Old
   meter readings and caps are retained, marked as incomparable until fresh
   calibration or readings are captured. Trend writes `daily-v2-*` and
   `weekly-v2-*` snapshots; do not overwrite old snapshots or benchmark rows.

## Checkpoint use and rollback

Capture a partial checkpoint before a continuation and a final one only when the
session ends. Pass the full session ID and stable run ID. `--aggregate-dir` selects
the latest capture per run/session and globally deduplicates the retained response
identities across sessions. Its output is cumulative for those sessions, with
source checkpoint identities and selected-response time bounds. Both lower and
upper API-equivalent totals, unknown cache-lifetime tokens, and unpriced-response
coverage remain visible. Ambiguous aliases excluded from global selection are
counted as coverage gaps, and `pricing_complete` is false for any uncertainty or
partial checkpoint. When observations are excluded, the dollar fields are priced
subtotals, not complete bounds. The legacy `*_usd` fields are lower-bound aliases, not
exact prices when the bounds differ or models are unpriced. Do not compare a
cumulative aggregate with a narrower meter interval without checking that its
run IDs and response time bounds belong to the work window. Checkpoint files
contain response usage metadata and source hashes, never prompt or tool text;
store them with the same
access controls as the transcript-derived ledgers.

The scheduled trend LaunchAgent uses `~/.claude/scripts/usage-trend.py`; on this
machine that is a symlink to `~/.claude/usage-history/usage-trend.py`. Verify the
actual LaunchAgent command and symlink target at installation, and keep the
shared `usage_accounting.py` beside the target script.

To roll back, restore the dated helper and instruction backups, and remove only
the new `pace-cache.json`/anchor state after preserving a copy for diagnosis. The
old `daily-*`, `weekly-*`, meter readings, and benchmark rows were never rewritten.
Keep `daily-v2-*`, `weekly-v2-*`, and checkpoint files for audit; do not add their
values to the old-rate series. The cost breaker remains paused throughout rollout
and rollback unless its owner independently changes that policy.
