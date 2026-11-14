#!/usr/bin/env python3
"""check-html-dark.py — every generic/*.md template that renders an HTML page
must carry the fleet's dark-by-default rule (assets/AGENTS.md,
`html-dark-by-default`): `color-scheme: dark` on :root, no `prefers-color-scheme`
switch, no `light dark` declaration. An opt-in single-value `color-scheme:light`
(a per-document light request) is allowed.

Detection is structural, not a name list, so a NEW HTML-emitting skill is held to
the rule the day it lands: a template renders HTML if it contains an HTML
document skeleton (`<!DOCTYPE html` / `<html`) or names a `.html` output file.

Limits, stated so nobody reads more into a green run than it proves: every
check is a text-presence test over the whole template. Rule 1 is satisfied by
the declaration appearing anywhere, prose or comment included, so a skeleton
that says `color-scheme: light` next to prose saying `color-scheme: dark`
passes, and so does a sentence that negates the rule (the inversion-blindness
of #226). What it does catch is the rule being DROPPED from a template, or a
new HTML-rendering template that never had it, which is #381's gap.

Usage: check-html-dark.py [--root DIR]
Exit:  0 all detected templates comply
       1 at least one violation (every violation is reported)
       2 cannot check: generic/ missing or empty, unreadable file, or the
         detector found zero HTML-rendering templates (a check over zero cases
         must not report success)
"""
import argparse
import re
import sys
from pathlib import Path

SKELETON = re.compile(r"<!doctype\s+html|<html\b", re.I)
HTML_OUTPUT = re.compile(r"[\w>\]\-`]\.html\b", re.I)

DARK_ALONE = re.compile(r"(?<!prefers-)color-scheme\s*:\s*dark\b(?!\s*light)", re.I)
COMBINED_DECL = re.compile(r"color-scheme\s*:\s*(?:light\s+dark|dark\s+light)\b", re.I)
# A meta `content` value naming both schemes, in either order and with any
# separator, in either attribute order.
_BOTH = r"[^\"']*\b(?:light\b[^\"']*\bdark|dark\b[^\"']*\blight)\b"
COMBINED_META = [
    re.compile(
        r"name\s*=\s*[\"']color-scheme[\"'][^>]*content\s*=\s*[\"']" + _BOTH, re.I),
    re.compile(
        r"content\s*=\s*[\"']" + _BOTH + r"[^>]*name\s*=\s*[\"']color-scheme[\"']", re.I),
]
# A light/dark switch: an `@media` or `@import` query, or a `media="..."`
# attribute (e.g. `<link media="(prefers-color-scheme: light)">`), that tests
# prefers-color-scheme. Prose that names prefers-color-scheme to forbid it is
# none of these.
MEDIA_QUERY = re.compile(
    r"@(?:media|import)\b[^{;]*prefers-color-scheme"
    r"|\bmedia\s*=\s*[\"'][^\"']*prefers-color-scheme", re.I)


def renders_html(text):
    return bool(SKELETON.search(text) or HTML_OUTPUT.search(text))


def violations(text):
    out = []
    if not DARK_ALONE.search(text):
        out.append("renders HTML but has no `color-scheme: dark` declaration "
                   "(html-dark-by-default)")
    if COMBINED_DECL.search(text) or any(p.search(text) for p in COMBINED_META):
        out.append("declares a combined `color-scheme: light dark` value "
                   "(CSS or meta tag); dark must stand alone")
    if MEDIA_QUERY.search(text):
        out.append("contains a prefers-color-scheme switch (`@media`, `@import` "
                   "or a `media=` attribute); no light/dark switch is allowed")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    gdir = Path(args.root) / "generic"
    files = sorted(gdir.glob("*.md")) if gdir.is_dir() else []
    if not files:
        print(f"::error::html-dark: cannot check — no generic/*.md under {gdir}")
        return 2

    detected, bad = [], 0
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"::error file=generic/{f.name}::html-dark: cannot read: {e}")
            return 2
        if not renders_html(text):
            continue
        detected.append(f.stem)
        for msg in violations(text):
            bad += 1
            print(f"::error file=generic/{f.name}::{msg}")

    if not detected:
        print("::error::html-dark: detector found zero HTML-rendering templates "
              "— refusing to report success over zero cases")
        return 2
    if bad:
        return 1
    print(f"html-dark: {len(detected)} HTML-rendering templates carry the dark rule "
          f"({', '.join(detected)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
