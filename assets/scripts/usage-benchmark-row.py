#!/usr/bin/env python3
"""Emit a markdown row for the vault usage benchmark.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/usage-benchmark-row.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/usage-benchmark-row.py [session-id-or-jsonl-path]

With no argument, targets the most recently modified session transcript under
~/.claude/projects/*/ (i.e., the session you are ending).

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
import json, glob, os, sys
from datetime import datetime

W_IN, W_CR, W_CW, W_OUT = 1.0, 0.1, 2.0, 5.0

def pick_transcript():
    if len(sys.argv) > 1:
        a = sys.argv[1]
        if a.endswith(".jsonl") and os.path.exists(a):
            return a
        hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{a}*.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime)
        sys.exit(f"no transcript matching {a!r}")
    files = [f for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
             if os.path.getsize(f) > 50_000]
    if not files:
        sys.exit("no transcripts found")
    return max(files, key=os.path.getmtime)

path = pick_transcript()
n = 0; eff = 0.0; out = 0; t0 = t1 = None
seen = set()
with open(path) as f:
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
    sys.exit(f"no usage records in {path}")

dur = (datetime.fromisoformat(t1.replace("Z", "+00:00"))
       - datetime.fromisoformat(t0.replace("Z", "+00:00"))).total_seconds() / 3600
sid = os.path.basename(path)[:8]
date = t0[5:10]
print(f"| {date} | {sid} | {dur:.1f} | {n} | {eff/1e6:.1f} | {out/1e3:.0f} | {eff/n/1e3:.1f} | <workload note> |")
print(f"\n(append to ~/Obsidian/no-it-all/briefs/usage-benchmark.md and replace the note)", file=sys.stderr)
