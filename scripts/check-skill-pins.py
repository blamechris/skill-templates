#!/usr/bin/env python3
"""check-skill-pins.py — installed-skill pins must be real template history (#375).

For every skill in .claude/skills.lock:
  1. the lock `hash` is a prefix of a commit reachable from --base that touched
     generic/<name>.md (history membership, not equality with registry.json: an
     older pin is valid; a pre-squash hash that is no longer reachable is not);
  2. .claude/commands/<name>.md carries exactly one stamp line
     `<!-- skill-templates: <name> <hash> <date> -->` agreeing with the lock.
Run from the repo root. Never reads registry.json.
Exit: 0 verified - 1 mismatch - 2 cannot verify (fail closed).
"""
import argparse, json, re, subprocess, sys

STAMP = re.compile(r'^<!-- skill-templates: (\S+) (\S+) (\S+) -->\s*$')
HEX = re.compile(r'^[0-9a-f]{7,40}$')
SAFE = re.compile(r'^[A-Za-z0-9._-]+$')


def unverifiable(msg):
    print(f"::error::cannot verify skill pins: {msg}")
    sys.exit(2)


def git(*args):
    try:
        p = subprocess.run(['git', *args], capture_output=True, text=True)
    except OSError as e:
        unverifiable(f"git is not runnable ({e})")
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    base_arg = ap.parse_args().base

    p = git('rev-parse', '--is-shallow-repository')
    if p.returncode != 0 or p.stdout.strip() != 'false':
        unverifiable("repository is shallow or its depth is unknown; fetch full history (fetch-depth: 0)")
    p = git('rev-parse', '--verify', f'{base_arg}^{{commit}}')
    if p.returncode != 0:
        unverifiable(f"base '{base_arg}' does not resolve to a commit")
    base = p.stdout.strip()

    try:
        skills = json.load(open('.claude/skills.lock'))['skills']
        assert isinstance(skills, dict)
    except (OSError, ValueError, KeyError, TypeError, AssertionError) as e:
        unverifiable(f".claude/skills.lock missing or malformed ({e})")

    bad = 0
    for name, ent in sorted(skills.items()):
        h = ent.get('hash') if isinstance(ent, dict) else None
        if not SAFE.match(name) or not isinstance(h, str):
            print(f"::error::{name}: lock entry is malformed (needs a string hash); run /skill update {name}")
            bad += 1
            continue
        if not HEX.match(h):
            print(f"::error::{name}: lock hash '{h}' is not 7+ lowercase hex; run /skill update {name}")
            bad += 1
        else:
            p = git('log', '--format=%H', base, '--', f'generic/{name}.md')
            if p.returncode != 0:
                unverifiable(f"git log failed for generic/{name}.md: {p.stderr.strip()}")
            commits = p.stdout.split()
            if not any(c.startswith(h) for c in commits):
                newest = ', '.join(c[:7] for c in commits[:3]) or 'none: no template commit is reachable from the base'
                print(f"::error::{name}: lock hash {h} is not a commit reachable from {base[:7]} that touched "
                      f"generic/{name}.md; run /skill update {name} or pin to a reachable template commit "
                      f"(newest: {newest})")
                bad += 1
        try:
            lines = open(f'.claude/commands/{name}.md', encoding='utf-8').read().splitlines()
        except OSError:
            print(f"::error::{name}: .claude/commands/{name}.md is missing; run /skill update {name}")
            bad += 1
            continue
        stamps = [m.groups() for m in map(STAMP.match, lines) if m]
        if len(stamps) != 1:
            print(f"::error::{name}: expected exactly one skill-templates stamp, found {len(stamps)}; run /skill update {name}")
            bad += 1
        elif stamps[0][0] != name or stamps[0][1] != h:
            print(f"::error::{name}: stamp says '{stamps[0][0]} {stamps[0][1]}' but lock pins {name} {h}; run /skill update {name}")
            bad += 1

    if bad:
        sys.exit(1)
    print(f"skill pins: {len(skills)} skills verified against {base[:7]}")


if __name__ == '__main__':
    main()
