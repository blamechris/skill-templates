#!/usr/bin/env python3
"""Audit every registry guard for alternates satisfiable by NON-RULE content.

A guard exists to detect deletion of a load-bearing RULE. An alternate that also
matches a heading, a table row, a Customization Points bullet, or the skill's own
documentation of the rule can keep the guard green after the rule is gone. Five
such guards shipped before this existed.
"""
import json, re, sys, os

root = sys.argv[1] if len(sys.argv) > 1 else '.'
guards = json.load(open(os.path.join(root, 'skill-guards.json')))

def classify(line, in_custom, in_fence):
    s = line.strip()
    if in_custom: return 'customization-points'
    if in_fence: return 'code-fence'
    if s.startswith('#'): return 'heading'
    # A fully-bold line is a heading only if it reads like a LABEL. `**CRITICAL: every PR
    # MUST be reviewed.**` is a rule wearing bold, not a heading — treating it as scaffold
    # made the mutation harness skip the very line it meant to delete.
    m = re.match(r'^\*\*([^*]+)\*\*:?\s*$', s)
    if m and len(m.group(1)) <= 60 and not re.search(r'[.!?]|\bMUST\b|\bnever\b|\bNEVER\b', m.group(1)):
        return 'bold-heading'
    if s.startswith('|'): return 'table-row'
    return 'prose'

suspect = []
for skill, gs in guards.items():
    if skill.startswith('_'): continue
    path = os.path.join(root, 'generic', f'{skill}.md')
    if not os.path.exists(path): continue
    lines = open(path).read().split('\n')
    in_custom = False; in_fence = False; kinds = []
    for ln in lines:
        if ln.startswith('## '): in_custom = ln.strip().lower().startswith('## customization points')
        if ln.strip().startswith('```'): in_fence = not in_fence
        kinds.append(classify(ln, in_custom, in_fence))
    for g in gs:
        alt_ok = []; alt_detail = []
        for alt in g.get('anyOf', []):
            try: rx = re.compile(alt)
            except re.error: continue
            hits = [(i, kinds[i]) for i, ln in enumerate(lines) if rx.search(ln)]
            if not hits: continue
            prose = [h for h in hits if h[1] == 'prose']
            alt_ok.append(bool(prose))
            alt_detail.append((alt, sorted({k for _, k in hits}) or ['NO MATCH'], bool(prose)))
        if alt_ok and not any(alt_ok):
            suspect.append((skill, g['label'], alt_detail))
print(f"guards audited: {sum(len(v) for k, v in guards.items() if not k.startswith('_'))}")
print(f"GUARDS where NO alternate is anchored in prose (vacuity candidates): {len(suspect)}\n")
for sk, lbl, detail in suspect:
    print(f"  {sk} / {lbl}")
    for alt, kinds, ok in detail:
        print(f"      [{'prose' if ok else 'NON-RULE'}] {alt[:70]}  -> {', '.join(kinds)}")
