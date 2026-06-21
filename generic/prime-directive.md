# prime-directive — overnight autonomous backlog run

Run the repo's open-issue backlog to completion while the user is away. Triggered when the user says
something like "work autonomously / use the prime directive / keep working til I'm back or there's
literally nothing left." Do NOT wait for the user and do NOT wrap up early — the only stop is a clean
backlog. This is the north-star wrapper around the companion autonomous skills (tackle-issues,
autonomous-dev-flow, agent-review, unattended-merge, swarm-audit).

## STOP CONDITION
The ONLY stop is a clean backlog: every open issue is either RESOLVED (its PR merged, `Closes #N`) or
genuinely BLOCKED (needs the user's machine / infra / a design decision / external data) and documented
as such on the issue. Keep going across context compactions until then. The user returns to a converged
backlog + a decisions report, or interrupts to review.

## SETUP (once, at the start of a run)
1. Create/update a project NORTH-STAR file (a persistent memory file, or a tracked repo note) holding: the
   MISSION, this RELOAD PROTOCOL, a DECISION LOG, and a PROGRESS LOG. After any compaction it is your
   re-entry point. Keep its backlog section honest — re-derive, don't trust a stale snapshot.
2. Derive live state from the issue tracker (`gh issue list --state open`) — the tracker is the source of
   truth for what's LEFT; the north-star file is the source of truth for the PLAN + decisions.
3. Triage every open issue into AUTONOMOUSLY-COMPLETABLE vs BLOCKED (user / infra / visual-or-Electron /
   external-data / owner-decision). Work the completable ones in value order; for each blocked one, comment
   WHY it's blocked + what's needed, and skip it (never fake-merge a blocked issue as done).

## THE LOOP (one issue at a time — companion skills are authoritative)
Re-read the relevant companion skill before each phase:
- `tackle-issues.md` — the marathon multi-wave driver.
- `autonomous-dev-flow.md` — per-issue cycle: sync main → understand → TDD (RED→GREEN→REFACTOR) → commit → PR → review → gate → assess.
- `agent-review.md` — the MANDATORY adversarial sub-agent review on EVERY code PR. Post it as a PR comment; address blocker/major findings in-PR; file + link follow-up issues for deferred items.
- `unattended-merge.md` — the merge gate. Match it to the repo's CI reality (see Customization Points).
- `swarm-audit.md` — for ANY decision with multiple valid options, run the swarm, take its recommendation, record it in the DECISION LOG, proceed.

### Per-issue procedure (condensed)
1. `git checkout main && git pull`. Fresh branch `feat|fix|docs/<num>-<slug>` from main — never stack.
2. TDD where testable: write the failing test(s) for the acceptance criteria → implement → refactor.
   UI / Electron / visual-only changes that genuinely can't be unit-tested: validate by parse-check +
   extracting the pure logic into a tested helper + a real-data sanity probe, and FLAG for the user's
   live verification. Never claim a visual change is verified when it isn't.
3. Conventional commit; link the issue (`Refs #N`, flip to `Closes #N` at merge). NO AI attribution, ever.
4. Mandatory adversarial agent-review. Fix blocker/major in-PR; file + link follow-ups for the rest.
5. Gate passes → merge → verify the PR reads MERGED → record in the PROGRESS LOG. Two fix attempts max per
   PR; if still failing, leave it open + flag it, and move on.
6. Next issue.

## HARD CONSTRAINTS
- ZERO AI attribution anywhere (no Co-Authored-By, no "Generated with Claude") in commits / PRs / issues / comments.
- Conventional commits; stage specific files (never `git add -A`); never commit secrets / local db files.
- Branch from main every time; never loosen a gate to merge; don't fake completion. Infra/credential/
  external blockers get a documented follow-up issue, not a fake merge.
- Every fixed issue links its PR (`Closes #N`); every deferred item → a tracked, linked follow-up issue.

## RELOAD PROTOCOL (after every compaction)
Re-read the north-star file → `git checkout main && git pull` → `gh issue list --state open` → resume at
the next completable issue. Do NOT idle or wrap up — the user said keep working.

## DECISION LOG / PROGRESS LOG
Append every non-trivial decision (with the WHY) and every merge/close to the north-star file. These are
the basis for the morning summary you present when the user returns.

## Customization Points
{{CUSTOMIZE: the repo's MERGE GATE — does CI run? If CI is blocked (billing/quota), substitute a verified
local run of the CI commands and record that decision; note whether main protection forces `--admin` or a
plain protected merge. The repo's TEST commands. The branch + merge convention (squash/delete-branch). Any
owner-gated or infra-blocked issue categories that must be built-and-flagged, never fake-merged.}}
