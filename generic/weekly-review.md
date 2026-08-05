# /weekly-review

The **Monday TPM pass over everything on this machine**: scan every repo for the trailing week's git activity, fan out one read-only scan agent per active repo, sweep the quiet tail, aggregate local session usage from the transcripts, and write a dated Markdown note plus a self-contained HTML brief into the vault. The chat message it ends with is **a short list of decisions waiting on the owner and one pointer to the note** — never a recap of the week, which is what the note is for. Reach for it at the top of the week, or any time "what happened across all my projects, and what needs me?" is the actual question.

## What this is not

- **Not `/catchup`** — that re-orients one repo at the start of a session. This one crosses the whole fleet and is written for a human reading it once a week.
- **Not `/visual-brief`** — that briefs one topic or one session. This one is a fixed weekly cadence with a fixed shape, and its note is a series.
- **Not `/look-approve`** — that asks for one verdict on one visual. This one *lists* the decisions; it does not put any of them.
- **Not `/project-audit` or `/swarm-audit`** — those go deep on code quality in one repo. Nothing here reads a diff for correctness.

## Arguments

- `$ARGUMENTS` — optional flags:
  - `--since N` — lookback window in days (default: `7`).
  - `--week YYYY-Www` — label the note for a specific ISO week (default: the current one).
  - `--dir PATH` — output directory (overrides the default below).
  - `--no-open` — write both files but don't launch Obsidian.
  - `--repos a,b,c` — scan only these, skipping discovery. For a re-run after a failed scan.

## Report-only — the whole run touches nothing

The review reads; it never writes. **Nothing in this run merges a PR, pushes a branch, closes or reopens an issue, or edits a label** — not in the repos being scanned, not in the vault's history, not anywhere. A weekly review that changes the state it is reporting on cannot be trusted the following week, and the owner reads it precisely to decide what *should* change.

The only writes the run is allowed are the two output files, and they land outside every repo.

Nothing this skill writes — the note, the HTML, any commit that later carries them — carries AI or agent attribution of any kind. No `Co-Authored-By`, no "generated with", no agent bylines in the note's frontmatter.

## Output location (resolution order)

1. `--dir PATH` if given.
2. `$CLAUDE_BRIEF_DIR` if set — {{CUSTOMIZE: this machine's brief/vault directory and the Obsidian vault name that contains it, e.g. `~/Obsidian/no-it-all/briefs` inside vault `no-it-all`; the vault name is needed for the `obsidian://` URI in step 7}}
3. Default: `~/.claude/briefs/` (created if missing).

```
<dir>/weekly-review-<YYYY>-W<NN>.md          ← the note (the durable record)
<dir>/tpm-week-in-review-<YYYY-MM-DD>.html   ← the visual companion
```

Never overwrite — append `-2`, `-3` on collision.

## Instructions

### 1. Resolve the window, then find the week's active repos

```bash
SINCE_DAYS=${SINCE_DAYS:-7}
CUTOFF=$(date -v-"${SINCE_DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "${SINCE_DAYS} days ago" +%Y-%m-%d)
WEEK=$(date +%G-W%V)   # %G, not %Y — the ISO year diverges from the calendar year in
                       # the first and last week of January, and the note is named for it.
ROOT={{CUSTOMIZE: absolute path to the projects root that holds every working copy, e.g. ~/Projects}}
```

Count commits per repo across **all** refs, so work sitting on an unmerged branch still registers:

```bash
for d in "$ROOT"/*/; do
  [ -d "$d/.git" ] || continue
  n=$(git -C "$d" log --all --since="$CUTOFF" --oneline 2>/dev/null | wc -l | tr -d ' ')
  slug=$(git -C "$d" remote get-url origin 2>/dev/null \
         | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
  printf '%6s  %-28s %s\n' "$n" "$(basename "$d")" "${slug:-<no remote>}"
done | sort -rn
```

Two directories with the same `origin` remote are one repo — **count their PRs once**, scan them as a single target, and say in the note that N working copies map to one GitHub repo. A fleet accumulates these (a daemon checkout, a docs sibling, a stale clone) and double-counting a 40-PR series is the single most misleading error this report can make.

{{CUSTOMIZE: the known directory pairs/groups in this projects root that share one GitHub remote, e.g. `chroxy` + `chroxy-daemon` → `blamechris/chroxy`; and any directory suffix convention such as `*-docs` that is a separate repo despite the similar name}}

Split the list at the activity threshold:

{{CUSTOMIZE: the commit count at or above which a repo gets its own scan agent, e.g. 20 in the trailing 7 days; tune it so a normal week yields 4–6 dedicated agents and everything else falls to the sweep}}

Repos at or above it get a dedicated agent (step 2); everything else goes to one sweep agent (step 3). Repos with zero commits are named in a single line and not investigated.

### 2. Fan out one read-only scan agent per active repo

Per `/tiered-delegation`, this is breadth, not judgment: it runs **below the ceiling**, in parallel, one agent per repo, all dispatched in a single message.

{{CUSTOMIZE: the model tier for scan agents on this harness — name the role ("workhorse" or "mechanical"), and a concrete tier only if it is certainly at or below the session ceiling, e.g. `sonnet`}}

**Every scan agent is read-only.** No `fetch`, no `pull`, no `checkout`/`switch`/`stash`, no `worktree add`, no commits, and no `gh` subcommand that writes. The scan reports the machine as it stands on Monday morning; an agent that fetches has changed the thing it was sent to describe, and it does so inside a working copy other sessions share. `git log --all` already covers the remote-tracking refs a fetch would refresh, and `gh` reads GitHub directly.

Each agent returns **structured data, not prose**:

| Field | Content |
|---|---|
| `headline` | one sentence — the week in this repo, no hedging |
| `themes` | 2–5 bullets, each a shipped outcome with PR/issue numbers |
| `merged` | count + the numbers worth naming |
| `open_prs` | number, title, review state, whether anything is stuck |
| `needs_user` | **every** item awaiting an owner decision: a few words + the issue/PR link. This is the field the final message is built from |
| `blockers` | anything wedged, with what it is wedged on |
| `ci_status` | default-branch health, plus any workflow red for more than a day |

The queries each agent should run:

```bash
git -C "$REPO" log --all --since="$CUTOFF" --format='%ad %h %s' --date=short
gh pr list  --repo "$SLUG" --state merged --search "merged:>=$CUTOFF" --json number,title,mergedAt
gh pr list  --repo "$SLUG" --state open   --json number,title,reviewDecision,isDraft
gh issue list --repo "$SLUG" --state open --json number,title,labels,updatedAt
gh run list --repo "$SLUG" --limit 20 --json name,conclusion,createdAt
```

Every worker brief is self-contained — repo path, slug, cutoff, the return schema above, the read-only prohibition verbatim, the zero-attribution rule, and the instruction to end with the mechanical `**Status:**` line. Subagents do not inherit `CLAUDE.md`, so none of that can be assumed.

### 3. One sweep agent for the quiet tail

A single agent takes every remaining repo and answers one question per repo: *was this real work, or was it the fleet's own automation?*

An automated skill-registry sync wave is not a week of work, and a repo whose entire diff is one is reported as quiet. These waves land the same commits in fifteen repos within minutes of each other, and counting them as activity turns a two-product week into a "fifteen-repo week" — the exact inflation that makes a status report stop being read.

{{CUSTOMIZE: the commit-message signatures of this fleet's automated waves, e.g. `chore(skills): …` / `chore(registry): …` touching only `.claude/commands/*` and `.claude/skills.lock`, plus any bot author to filter on}}

The sweep returns one line per repo, and names — with numbers — any tail repo that had genuine feature work, because that is the one thing a tail sweep exists to catch.

### 4. Aggregate local session usage

Read the transcripts directly; never estimate. Stream them — one project's `.jsonl` runs to hundreds of megabytes and must never be read into memory whole.

{{CUSTOMIZE: the transcript root on this machine, e.g. `~/.claude/projects`, and how its per-project directory slug maps back to a working directory — non-alphanumerics are replaced with `-`, so worktrees appear as separate projects under the same repo prefix}}

```bash
python3 - "$TRANSCRIPT_ROOT" "$CUTOFF" <<'PY'
import json, os, sys, glob
from collections import defaultdict
from datetime import datetime, timezone

root, cutoff = sys.argv[1], sys.argv[2] + "T00:00:00+00:00"
cut = datetime.fromisoformat(cutoff)
agg = defaultdict(lambda: {"sessions": set(), "turns": 0, "out": 0, "inp": 0,
                           "models": defaultdict(int), "first": None, "last": None})

for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    proj = os.path.basename(os.path.dirname(path))
    with open(path, errors="replace") as fh:          # streaming: one line at a time
        for line in fh:
            try: o = json.loads(line)
            except Exception: continue
            ts = o.get("timestamp")
            if not ts: continue
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if t < cut: continue
            a = agg[proj]
            a["first"] = t if a["first"] is None else min(a["first"], t)
            a["last"]  = t if a["last"]  is None else max(a["last"], t)
            if o.get("sessionId"): a["sessions"].add(o["sessionId"])
            if o.get("type") != "assistant": continue
            msg = o.get("message") or {}
            u = msg.get("usage") or {}
            # The top-level usage IS the turn's total. `usage.iterations` restates the
            # same numbers per internal step — summing it double-counts every turn.
            a["turns"] += 1
            a["out"]   += u.get("output_tokens", 0)
            a["inp"]   += (u.get("input_tokens", 0)
                           + u.get("cache_read_input_tokens", 0)
                           + u.get("cache_creation_input_tokens", 0))
            a["models"][msg.get("model", "?")] += u.get("output_tokens", 0)

rows = sorted(agg.items(), key=lambda kv: -kv[1]["turns"])
for proj, a in rows:
    if not a["turns"]: continue
    span = int((a["last"] - a["first"]).total_seconds() // 60)
    print(f'{proj}\t{len(a["sessions"])}\t{a["turns"]}\t{a["out"]}\t{a["inp"]}\t{span//60}h{span%60:02d}m')
    for m, o in sorted(a["models"].items(), key=lambda kv: -kv[1]):
        print(f'    {m}\t{o}')
PY
```

Group the per-project rows into **working contexts** the owner recognises (a repo and its worktrees are one context; the home directory is the orchestrator/chat context) and report the model mix by output tokens, since that is the number that maps to the tiering doctrine.

Publish no usage number bare — every one carries its caveat in the same sentence. "Input" is overwhelmingly prompt-cache reads and writes billed at cache rates rather than fresh spend, so it is labelled *cache-inclusive* wherever it appears; and every span is a wall-clock transcript range covering idle gaps and resumed sessions, not focused time. Stated plainly, the input:output ratio is a useful finding about where cost actually goes. Stated bare, it is a number that reads like money and isn't.

Sidechain turns are subagent work and belong in the totals — they are real spend under the parent's `sessionId`.

### 5. Write the note

`<dir>/weekly-review-<YYYY>-W<NN>.md`, with frontmatter:

```yaml
---
tags: [weekly-review]
week: 2026-W32
period: 2026-07-28 → 2026-08-04
series: "Weekly Review #1"
---
```

The series number continues the previous note's — read it from the newest `weekly-review-*.md` already in the folder and add one; never restart at #1 because you did not look. The series is how the owner navigates a year of these, and a second "#1" silently breaks it.

Sections, in this order:

1. **`# Weekly Review — W<NN> (<dates>)`** then a one-line blockquote of scope: how many repos scanned, what the sources were.
2. **The two-minute version** — a bolded headline stat, then one line per active product. This is the only part most readings will get past.
3. **Shipped, by repo** — a table: repo · merged count · highlights · issues closed/filed.
4. **Decisions made this week** — numbered, each with its outcome and what it unblocked. Then a short **Still open** paragraph.
5. **Usage flow** — the step-4 table, the model mix, and the honesty caveats as their own paragraph.
6. **Process notes worth keeping** — only genuinely transferable lessons; omit the section rather than pad it.
7. **Companion artifacts** — Obsidian `[[wikilinks]]` to the HTML brief and to any session brief from the week.
8. **Seeds for next week** — one line per product, each an issue number.

Voice: past tense, specific, numbers over adjectives, every claim traceable to a PR or issue number. Name what went wrong as readily as what shipped — a review that only reports wins is a newsletter.

### 6. The HTML companion

Self-contained (inline `<style>`, no CDN, no framework), reusing `/visual-brief`'s skeleton and house palette — CSS variables for **both** `:root` dark and the `prefers-color-scheme: light` block, since a hardcoded hex renders correct for you and broken for the reader.

Layout, top to bottom: eyebrow + `<h1>` with the date range · a `.sub` paragraph that is the two-minute version · outcome `.chips` (PRs merged, active products, items needing the owner, anything red) · **one `.callout` listing what needs the owner**, numbered, the same items the chat message will lead with · then one `<section>` per active product · then the fleet sweep · then the per-PR record in `<details>` blocks, which is vault material rather than headline material.

Everything above the first `<section>` must answer "what happened and what needs me?" on its own.

### 7. Open it

```bash
# Obsidian first — the note is a vault object with working wikilinks there.
open "obsidian://open?vault=$VAULT&file=$(python3 -c \
  'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "briefs/$NOTE_BASENAME")"
# The HTML is a plain file; the browser is the right viewer for it.
open "$HTML_PATH"        # macOS; xdg-open on Linux
```

If the vault is not open or the URI scheme is unregistered, `open` silently succeeds and nothing appears — so fall back to opening the `.md` directly, and **print both absolute paths regardless**. Opening is a convenience, never a gate.

### 8. The final message is the product

The final chat message opens with the decision list: every open owner decision across every repo scanned, a few words and one link each. Pull it from the `needs_user` field of every agent's return — if an item appeared there, it appears here, even when it seems minor, because the owner's whole reason for reading is to find these.

```
**Needs you**
1. duskwright — ADR 0007's two owner calls · <link>
2. skill-templates — #158 codex emission home · <link>
3. Aeolus — visual-verify the new UI on device (#78) · <link>
```

Then one line pointing at the note, and stop. **The report is the note; the message is the ask.** A prose recap in chat is the failure mode this skill exists to prevent — the week has just been written up twice already, and a third telling in the one medium that cannot be searched next month is pure cost. If you are writing a second paragraph, you are writing the wrong artifact.

If nothing needs the owner, say exactly that in one line. An empty decision list is a real and welcome result; a fabricated one to fill the section is not.

End with the mechanical `**Status:**` line — the four fixed slots defined in the global `~/.claude/CLAUDE.md` ("End-of-message summary"); the pending decisions go in the `DECISION` slot.

## Failure modes, and what they actually mean

| Symptom | Cause | Fix |
|---|---|---|
| A 40-PR series counted twice | two working copies, one remote | dedup on `origin`, not on directory name |
| "Fifteen-repo week" | automated sync waves counted as work | filter them in the sweep; report those repos as quiet |
| Scan agent reports a repo as stale | it read a working copy nobody fetched | that IS the machine's state — report it, don't fetch |
| Usage numbers read as money | `input` published without its label | cache-inclusive, every time, in the same sentence |
| Note numbered "#1" again | previous note never read | derive the series from the folder before writing |
| Wrong ISO week in January | `%Y` instead of `%G` | `date +%G-W%V` |
| Owner misses a decision | it lived only in the note | every `needs_user` item goes in the chat message |
| The transcript aggregator OOMs | a `.jsonl` read whole | stream line by line, never `read()` the file |
| A scan agent left a repo dirty | it checked out or stashed | read-only prohibition belongs in the brief verbatim |

## Notes

- **Run it against a quiet week too.** The value is the cadence: a week where nothing needed the owner is a finding, and skipping the run in slow weeks is how the series dies.
- **The scan is a snapshot, not an investigation.** If a repo needs real analysis, the review's job is to say so and name the skill (`/catchup`, `/project-audit`) — not to grow a fourth agent tier inside a weekly report.
- **Agents return data; the orchestrator owns every sentence.** Nothing a scan agent wrote reaches the note or the message unread — per `/tiered-delegation`, delegation conserves tokens, not accountability.
- **The note outlives the session.** It is written for someone with no memory of the week, including the owner in three months.

## Customization Points

- **Projects root** — the directory holding every working copy that step 1 walks.
- **Output directory + vault** — `$CLAUDE_BRIEF_DIR` or `~/.claude/briefs/`, plus the Obsidian vault name the `obsidian://` URI needs.
- **Activity threshold** — the commit count that earns a repo its own scan agent.
- **Shared-remote groups** — the directory pairs in this root that are one GitHub repo, and any naming convention (`*-docs`) that looks shared but isn't.
- **Scan-agent tier** — the role and, where safe, the concrete model for the per-repo agents.
- **Sync-wave signatures** — the commit messages, paths, and bot authors that mark this fleet's automated waves.
- **Transcript root** — where session `.jsonl` files live and how their directory slugs map to working directories.
