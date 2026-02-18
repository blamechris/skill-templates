# Swarm Synthesis: /learn Skill Proposals

**Date:** 2026-02-18
**Panel:** 5 agents (Opus 4.6) — Skeptic, Builder, Guardian, Minimalist, Operator
**Objective:** Design a session-end learning/memory skill, distilled from the audited Reddit wrap-up skill's Phase 2

---

## Consensus (all 5 agents agreed)

| Design Decision | Rationale |
|-----------------|-----------|
| **Gate check / fast path** | Most sessions are routine. "Nothing to persist" should be 1 line, near-instant. |
| **Hard cap of 3 entries** | Quality over quantity. Prevents bloat after 50+ sessions. |
| **Mandatory deduplication** | Read all existing memory before proposing writes. Drop duplicates silently. |
| **10-line output ceiling** | Session-end output must be scannable in 2 seconds. |
| **No commit** | Separate "write file" from "commit file." User reviews via `git diff`. |
| **Direct argument shortcut** | `/learn React Native doesn't support ReadableStream` skips discovery entirely. |
| **Append-only writes** | Never edit existing CLAUDE.md lines. Prevents governance drift. |

## Key Disagreement: Confirmation Gates

| Agent | Position |
|-------|----------|
| **Operator** | Remove confirmation entirely. Memory writes are append-only, reversible, not committed. Friction kills daily adoption. |
| **Guardian** | Always confirm for CLAUDE.md and .claude/rules/. These are governance docs — unsupervised edits compound. |
| **Skeptic** | Confirm governance, auto-apply personal. The self-modification loop is a real risk. |
| **Builder** | Two-tier: governance needs approval, CLAUDE.local.md and auto memory apply immediately. |
| **Minimalist** | Confirm everything. Show the report, wait for "all" / "1 and 3" / "skip 2". |

**Resolution in final spec:** Two-tier model (Builder/Skeptic/Guardian consensus). CLAUDE.md and .claude/rules/ require approval. CLAUDE.local.md and auto memory apply immediately. This balances safety (governance docs protected) with speed (personal notes don't block).

## Best Ideas by Agent

| Agent | Contribution adopted |
|-------|---------------------|
| **Skeptic** | Behavioral Test as gate check. "Do X instead of Y" filter. Evidence quality metadata (VERIFIED/OBSERVED). Framing "nothing to persist" as the expected outcome, not failure. |
| **Builder** | Before/After behavioral delta requirement. Two-tier approval model. "$20 bet" quality bar heuristic. Conflict handling (present both, never resolve). |
| **Guardian** | Self-referential rule detection (never persist rules that modify /learn itself). No verbatim external content rule. "Even in solo repos" clause for approval. Missing CLAUDE.md edge case. |
| **Minimalist** | Stripped auto memory as a writable destination (noted Claude manages it — skill can't actually write to it). 3-criteria extraction filter (Novel, Reusable, Specific). No self-reflection phase. |
| **Operator** | Step 0 fast path design. Direct argument shortcut for mid-session capture. Output budget as a hard design constraint. "Will they actually read this" as the output test. |

## What Was Dropped (all agents agreed to cut)

1. **Auto-commit and push** — critically dangerous, unanimous
2. **Auto-deploy** — chains off unreviewed commit, unanimous
3. **File rename/move** — breaks imports, no relation to learning
4. **Phase 3 self-reflection** — navel-gazing with a template, 4/5 agents
5. **Phase 4 publishing** — scope creep, separate skill, 4/5 agents
6. **Multi-repo scanning** — Claude can't reliably track touched repos

## Final Spec

The synthesized skill at `generic/learn.md` incorporates the consensus and resolves the confirmation gate disagreement with the two-tier model. Key properties:

- **6 steps** (gate check, extract, dedup, route, report, apply)
- **12 safety rules** each mapped to a specific failure mode
- **6 edge cases** (contradictions, conflicts, missing CLAUDE.md, cross-repo, bypass requests, self-referential rules)
- **7 worked examples** covering the full range from "nothing learned" to conflict detection
- **Customization points** for per-repo adaptation

The Operator's full-auto-apply proposal was the outlier — defensible on UX grounds but rejected because governance file drift was the #1 long-term risk identified in the original audit. The two-tier model preserves the Operator's speed for low-risk targets while maintaining the Guardian's safety gates where they matter most.
