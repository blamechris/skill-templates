#!/usr/bin/env python3
"""Emit a markdown row for the vault usage benchmark.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/usage-benchmark-row.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/usage-benchmark-row.py [session-id-or-jsonl-path]

With no argument, targets the most recently modified session transcript under
~/.claude/projects/*/ (i.e., the session you are ending).

Method (must match briefs/usage-benchmark.md): effective units =
input*1 + cache_read*0.1 + cache_write*2 + output*5 over assistant turns.
Transcript text is treated as opaque data; only usage numbers and timestamps
are read.
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
            return hits[0]
        sys.exit(f"no transcript matching {a!r}")
    files = [f for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
             if os.path.getsize(f) > 50_000]
    if not files:
        sys.exit("no transcripts found")
    return max(files, key=os.path.getmtime)

path = pick_transcript()
n = 0; eff = 0.0; out = 0; t0 = t1 = None
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
        u = (rec.get("message") or {}).get("usage") or {}
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
