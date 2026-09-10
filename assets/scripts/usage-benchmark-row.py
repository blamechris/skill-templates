#!/usr/bin/env python3
"""Emit a markdown row for the vault usage benchmark.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/usage-benchmark-row.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/usage-benchmark-row.py [session-id-or-jsonl-path]

With no argument, targets $CLAUDE_CODE_SESSION_ID's transcript — the session
actually running this. There is no other resolution path.

WHAT IT REFUSES TO GUESS (a REFUSE prints `REFUSE: ...` on stderr and exits 1;
nothing is emitted, so nothing wrong can be appended):
  - no argument and $CLAUDE_CODE_SESSION_ID unset — there used to be a
    newest-mtime fallback here, and it is wrong whenever two sessions overlap,
    which is the normal case on this machine: it globbed EVERY project and took
    the newest mtime, so a session ending at the moment another wrote a tool
    result got the OTHER session's transcript. It mispicked three times in the
    week of 2026-08-17 alone (measured 2026-08-20: an Aeolus session resolved a
    concurrent chroxy session and would have written a row wrong in the id AND
    every number — unrepairable, because End step 2 is "neither append nor
    overwrite" once a row exists). Same shape as skill-templates#207.
  - $CLAUDE_CODE_SESSION_ID set but matching no transcript — set-but-stale is
    not a licence to fall through to the same heuristic.
  - an explicit argument matching no transcript.

The row's workload-note cell is emitted with TWO measured suffixes already
filled in — `· subagents: <eff>M/<count>` (from the session's subagents/
transcripts, same dedup and weights) and `· work: <n>pr/<n>iss` (merged PRs and
closed issues this session is credited with, see scan_work). Replace only the
`<workload note>` text and KEEP both suffixes — hand-typed subagent figures
produced 12+ unparseable formats in one week, and the work figures exist
precisely so the numerator stops living in unparseable prose: a scan of the
ledger's own workload notes returned 7,587 PRs for a single week.

`work:` may read `n/a`, which is NOT the same as `0pr/0iss` — see scan_work.

Which transcript was chosen, and how, is printed to stderr so a wrong pick is
visible instead of silent.

Method (must match briefs/usage-benchmark.md): effective units =
input*1 + cache_read*0.1 + cache_write*2 + output*5 over assistant turns,
deduplicated by message.id (fallback: requestId) — transcripts write one JSONL
line per content block, each repeating the same usage object, so without dedup
multi-block turns are counted 2-3x (~2.2x measured). Transcript text is treated
as opaque data; only usage numbers and timestamps are read.

DEDUP IS NOT A REFINEMENT — it is what makes a row comparable to the rows above
it. The benchmark file is a single table read across sessions, and nothing in a
row records which version produced it, so one inflated row is not a bad row but a
corrupted column. This copy shipped without the dedup for long enough that a
machine bootstrapped from it (`cp assets/scripts/usage-benchmark-row.py
~/.claude/scripts/`) wrote ~2.2x rows into a table it could not then repair —
session-lifecycle's End step 2 is "neither append nor overwrite" once a row
exists. skill-templates#207.
"""
import json, glob, os, re, subprocess, sys
from datetime import datetime

W_IN, W_CR, W_CW, W_OUT = 1.0, 0.1, 2.0, 5.0

def die(msg):
    """REFUSE and stop. Nothing was printed to stdout, so nothing can be appended."""
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(1)

def pick_transcript():
    if len(sys.argv) > 1:
        a = sys.argv[1]
        # An empty or glob-metachar argument would wildcard the id glob below into
        # "every transcript, newest wins" — the removed fallback through a side door.
        if not a.strip() or any(c in a for c in "*?["):
            die(f"invalid session-id argument {a!r} — pass a real id or a .jsonl path.")
        if a.endswith(".jsonl") and os.path.exists(a):
            return a, "argv path"
        hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{a}*.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime), f"argv {a!r}"
        die(f"no transcript matching {a!r}. Pass a session id or a .jsonl path.")
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if sid:
        hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}*.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime), f"$CLAUDE_CODE_SESSION_ID={sid[:8]}"
        # Set but unresolvable is NOT a licence to guess: falling through to a
        # mtime heuristic here is exactly how a row gets another session's id.
        die(f"CLAUDE_CODE_SESSION_ID={sid!r} is set but no transcript matches it. "
            "Pass a session id or a .jsonl path explicitly.")
    # No argument, no session id: REFUSE. The newest-mtime fallback that lived
    # here resolved the WRONG session three times in one week (see docstring).
    die("no session id: pass one explicitly, or run from inside a Claude session "
        "(where $CLAUDE_CODE_SESSION_ID is set).")

def scan_subagents(transcript_path):
    """Sum the session's subagent transcripts (<session-dir>/subagents/**/*.jsonl)
    with the same dedup and weights as the main loop. Returns (eff, file_count)."""
    base = transcript_path[:-len(".jsonl")] if transcript_path.endswith(".jsonl") else transcript_path
    eff = 0.0
    count = 0
    seen = set()
    subdir = os.path.join(base, "subagents")
    if not os.path.isdir(subdir):
        return 0.0, 0  # no subagents dir is the normal case, not an error
    # Below here, an unreadable file or directory means the number cannot be
    # trusted, and a confident-but-wrong suffix is the failure this script exists
    # to prevent — so unreadable is a REFUSE, never a silent undercount.
    def walk_err(e):
        die(f"cannot measure subagents: {e}")
    for root, _dirs, names in os.walk(subdir, onerror=walk_err):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            try:
                fh = open(os.path.join(root, name), errors="replace")
            except OSError as e:
                die(f"cannot measure subagents: {e}")
            count += 1
            with fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    msg = rec.get("message") or {}
                    k = msg.get("id") or rec.get("requestId")
                    if k:
                        if k in seen:
                            continue
                        seen.add(k)
                    u = msg.get("usage") or {}
                    eff += (u.get("input_tokens", 0) * W_IN
                            + u.get("cache_read_input_tokens", 0) * W_CR
                            + u.get("cache_creation_input_tokens", 0) * W_CW
                            + u.get("output_tokens", 0) * W_OUT)
    return eff, count

# --- work numerator -------------------------------------------------------
# The ledger could state spend to four significant figures and could not state
# WORK at all, so "are we getting more efficient?" was unanswerable for five
# weeks while $/merged-PR quietly doubled ($17 -> $34, weeks closing 2026-08-12
# and 2026-09-09). The denominator was measured to death; this is the numerator.
#
# Attribution is the whole difficulty, and it is done with TWO independent
# filters that must BOTH pass:
#
#   1. NOMINATED by the transcript — the number appears somewhere in this
#      session's own JSONL.
#   2. ADJUDICATED by GitHub — it actually merged/closed inside this session's
#      [t0, t1] window, per `gh search`.
#
# Neither alone works. A pure time window credits every concurrently-running
# session with the same PR (three sessions overlap on this machine as a matter
# of routine, which is the same collision class as the mtime fallback removed
# from pick_transcript above). A pure transcript scan credits a session for
# merely READING a ledger full of old PR numbers.
#
# This keeps the docstring's "transcript text is opaque data" promise intact:
# the text can only ever NARROW a set that GitHub produced. No number, state, or
# timestamp is ever taken from transcript text — GitHub is the sole authority on
# all three, and the transcript is not trusted, only consulted.
GH_TIMEOUT = 30

def _gh_json(args):
    """Run a gh command, return parsed JSON, or None if gh cannot answer."""
    try:
        r = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None  # gh absent, or the network hung: not measurable
    if r.returncode != 0:
        return None  # unauthenticated, rate-limited, offline
    try:
        return json.loads(r.stdout)
    except Exception:
        return None

def _window(t0, t1):
    """ISO stamps -> a gh search range. Fractional seconds are stripped; gh
    rejects them, and a rejected query returns rc!=0, i.e. a silent n/a."""
    def clean(t):
        t = t.split(".")[0]
        return t if t.endswith("Z") else t + "Z"
    return f"{clean(t0)}..{clean(t1)}"

def scan_work(transcript_path, t0, t1):
    """Return the `work: ` note for the row: merged PRs and closed issues this
    session can be credited with, or 'n/a' when GitHub could not be asked.

    'n/a' and '0pr/0iss' are DELIBERATELY different strings. Measured-zero and
    could-not-measure are different facts, and collapsing them is exactly the
    error the meter ledger forbids for a missing reading ("print MISSING
    prominently ... NEVER infer or invent"). A row that says 0 because the
    laptop was offline would corrupt the $/PR series the same way an inflated
    eff column corrupted the one above it (skill-templates#207)."""
    # `gh api user --jq .login` emits a bare string, not JSON, so it is read
    # raw rather than through _gh_json. Deriving the owner instead of hardcoding
    # one keeps this copy portable to any machine that bootstraps from it.
    try:
        r = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                           capture_output=True, text=True, timeout=GH_TIMEOUT)
        owner = r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        owner = None
    if not owner:
        return "n/a"

    # --- 1. nominate, from the transcript's raw bytes ---------------------
    qualified, bare = set(), set()
    url_re = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+)")
    ref_re = re.compile(r"\b([\w.-]+/[\w.-]+)#(\d+)\b")
    bare_re = re.compile(r"(?<![\w/#])#(\d+)\b")
    try:
        with open(transcript_path, errors="replace") as f:
            for line in f:
                for m in url_re.finditer(line):
                    qualified.add((m.group(1), int(m.group(2))))
                for m in ref_re.finditer(line):
                    qualified.add((m.group(1), int(m.group(2))))
                for m in bare_re.finditer(line):
                    bare.add(int(m.group(1)))
    except OSError:
        return "n/a"
    if not qualified and not bare:
        return "0pr/0iss"

    def credited(rows):
        """Keep only what this session nominated. A bare '#245' carries no repo,
        so it matches on number alone — deliberately loose, because the window
        filter is the one doing the real work and a session that never mentioned
        a number at all is the case worth excluding."""
        n = 0
        for row in rows or []:
            num = row.get("number")
            repo = (row.get("repository") or {}).get("nameWithOwner")
            if (repo, num) in qualified or num in bare:
                n += 1
        return n

    win = _window(t0, t1)
    prs = _gh_json(["search", "prs", "--owner", owner, "--merged",
                    "--merged-at", win, "--limit", "200",
                    "--json", "number,repository"])
    iss = _gh_json(["search", "issues", "--owner", owner, "--state", "closed",
                    "--closed", win, "--limit", "200",
                    "--json", "number,repository"])
    if prs is None or iss is None:
        return "n/a"
    return f"{credited(prs)}pr/{credited(iss)}iss"


path, how = pick_transcript()
n = 0; eff = 0.0; out = 0; t0 = t1 = None
seen = set()
with open(path, errors="replace") as f:
    for line in f:
        try:
            rec = json.loads(line)
        except Exception:
            continue
        ts = rec.get("timestamp")
        if ts:
            t0 = t0 or ts
            t1 = ts
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        # One turn, one count. `message.id` is the API's id for the assistant turn
        # and repeats on every content block of it; `requestId` is the harness's
        # and is the fallback for lines that carry no message id. A line with
        # NEITHER is counted (no key, no way to tell it from a distinct turn) —
        # undercounting a turn is the failure the other direction.
        key = msg.get("id") or rec.get("requestId")
        if key:
            if key in seen:
                continue
            seen.add(key)
        u = msg.get("usage") or {}
        i, cr, cw, o = (u.get("input_tokens", 0), u.get("cache_read_input_tokens", 0),
                        u.get("cache_creation_input_tokens", 0), u.get("output_tokens", 0))
        if i + cr + cw + o == 0:
            continue
        n += 1
        out += o
        eff += i * W_IN + cr * W_CR + cw * W_CW + o * W_OUT

if not (n and t0 and t1):
    die(f"no usage records in {path}")

sub_eff, sub_count = scan_subagents(path)
# One format for every row, zero included ("0.0M/0") — two shapes in one column
# is the hand-typed drift this suffix replaces, in miniature.
sub_note = f"{sub_eff/1e6:.1f}M/{sub_count}"
work_note = scan_work(path, t0, t1)
dur = (datetime.fromisoformat(t1.replace("Z", "+00:00"))
       - datetime.fromisoformat(t0.replace("Z", "+00:00"))).total_seconds() / 3600
sid = os.path.basename(path)[:8]
date = t0[5:10]
print(f"| {date} | {sid} | {dur:.1f} | {n} | {eff/1e6:.1f} | {out/1e3:.0f} | {eff/n/1e3:.1f} "
      f"| <workload note> · subagents: {sub_note} · work: {work_note} |")
print(f"\nresolved {sid} via {how}", file=sys.stderr)
print(f"  transcript: {path}", file=sys.stderr)
print(f"  If that is not the session you are ending, STOP — pass the id explicitly.", file=sys.stderr)
print(f"\n(append to ~/Obsidian/no-it-all/briefs/usage-benchmark.md; replace only the "
      f"<workload note> text — the measured subagents and work suffixes stay)", file=sys.stderr)
if work_note == "n/a":
    print("  work: n/a — GitHub could not be asked (gh missing, unauthenticated, or "
          "offline). This is NOT a measured zero; do not replace it with one.", file=sys.stderr)
