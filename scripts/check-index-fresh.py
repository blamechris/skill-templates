#!/usr/bin/env python3
"""check-index-fresh.py — is the committed registry.json still what
build-index.sh would produce?

Usage:
    scripts/check-index-fresh.py COMMITTED.json REBUILT.json

Exit 0 = fresh, 1 = stale (differences printed as GitHub error annotations),
2 = usage / unreadable input.

WHY THIS IS NOT `git diff --exit-code registry.json`
----------------------------------------------------
Two fields in registry.json are derived from git history, and both are
*necessarily* different on a PR branch than they will be on main:

  * `generatedFromCommit` — `git log -1 -- generic/ skill-guards.json`
  * `skills[].hash`       — `git log -1 -- generic/<name>.md`

On a branch that edits a template, those resolve to the branch's own commit.
main squash-merges, so the squash replaces that commit with a new one and the
values change through no fault of the author. A plain `git diff --exit-code`
would therefore fail every honest template PR. Post-merge staleness in those
two fields is real, but it can only be fixed *after* the squash exists — that
is what .github/workflows/reindex-after-merge.yml is for.

Everything else in the index is derived from file *content* or from the set of
files on disk, so it is squash-invariant and is compared here. See FIELDS
below: every key the generator emits is listed, with a reason.
"""

import json
import sys

# Every key build-index.sh emits, and whether this check compares it.
#
#   registry                — INCLUDED. Constant literal in build-index.sh; no
#                             git input. If it ever changes, that is real drift.
#   generatedFromCommit     — EXCLUDED. Git-derived (see module docstring).
#   skillCount              — INCLUDED. len(glob('generic/*.md')). File-set
#                             derived; squash cannot move it.
#   skills[].name           — INCLUDED. Basename of the template file.
#   skills[].hash           — EXCLUDED. Git-derived (see module docstring).
#   skills[].lines          — INCLUDED. Line count of the template's content.
#   skills[].description    — INCLUDED. Parsed out of the template's first
#                             paragraph. This is the field consumers read in
#                             `skill list`, and the one that silently rots when
#                             a template is edited without a reindex.
#   skills[].guards         — INCLUDED. Copied verbatim from skill-guards.json.
#                             Key presence matters too: a skill that gains or
#                             loses guards must show up as a difference.
#
# Ordering is compared as well: build-index.sh sorts skills by name, so a
# reordered committed file is stale even if the set matches.
IGNORED_TOP_LEVEL = ("generatedFromCommit",)
IGNORED_PER_SKILL = ("hash",)


def normalize(doc):
    """Strip the git-derived fields so what remains is squash-invariant."""
    out = {k: v for k, v in doc.items() if k not in IGNORED_TOP_LEVEL}
    out["skills"] = [
        {k: v for k, v in skill.items() if k not in IGNORED_PER_SKILL}
        for skill in doc.get("skills", [])
    ]
    return out


def _brief(value, limit=160):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _brief_pair(left, right, limit=110):
    """Render two values for a diff line, eliding what they have in common.

    Descriptions are long and usually differ in one clause; printing 160
    truncated characters of each shows a reader two identical-looking strings.
    Trim the shared prefix and suffix so the actual difference is on screen.
    """
    if not (isinstance(left, str) and isinstance(right, str)):
        return _brief(left), _brief(right)
    if max(len(left), len(right)) <= limit:
        return _brief(left), _brief(right)

    head = 0
    while head < min(len(left), len(right)) and left[head] == right[head]:
        head += 1
    tail = 0
    while (
        tail < min(len(left), len(right)) - head
        and left[len(left) - 1 - tail] == right[len(right) - 1 - tail]
    ):
        tail += 1

    # Keep a little shared text on each side as context, and mark the region
    # that actually differs with «guillemets» — a bare "……" tells nobody where.
    context = 28
    prefix = left[:head]
    suffix = left[len(left) - tail :] if tail else ""
    shown_prefix = ("…" + prefix[-context:]) if len(prefix) > context else prefix
    shown_suffix = (suffix[:context] + "…") if len(suffix) > context else suffix

    def cut(text):
        middle = text[head : len(text) - tail]
        if len(middle) > limit:
            middle = middle[: limit - 1] + "…"
        return f"{shown_prefix}«{middle}»{shown_suffix}"

    return f"'{cut(left)}'", f"'{cut(right)}'"


def differences(committed, rebuilt):
    """Return a list of human-readable differences; empty means fresh."""
    committed = normalize(committed)
    rebuilt = normalize(rebuilt)
    problems = []

    for key in sorted(set(committed) | set(rebuilt)):
        if key == "skills":
            continue
        if committed.get(key) != rebuilt.get(key):
            problems.append(
                f"top-level '{key}': committed {_brief(committed.get(key))} "
                f"!= rebuilt {_brief(rebuilt.get(key))}"
            )

    committed_skills = {s.get("name"): s for s in committed["skills"]}
    rebuilt_skills = {s.get("name"): s for s in rebuilt["skills"]}

    for name in sorted(set(rebuilt_skills) - set(committed_skills)):
        problems.append(f"'{name}': a template exists but registry.json has no entry")
    for name in sorted(set(committed_skills) - set(rebuilt_skills)):
        problems.append(f"'{name}': registry.json has an entry but no template exists")

    for name in sorted(set(committed_skills) & set(rebuilt_skills)):
        left, right = committed_skills[name], rebuilt_skills[name]
        for key in sorted(set(left) | set(right)):
            if left.get(key) != right.get(key):
                if key not in left:
                    problems.append(f"'{name}': gained '{key}' on rebuild ({_brief(right[key])})")
                elif key not in right:
                    problems.append(f"'{name}': lost '{key}' on rebuild (was {_brief(left[key])})")
                else:
                    was, now = _brief_pair(left[key], right[key])
                    problems.append(f"'{name}.{key}': committed {was} != rebuilt {now}")

    committed_order = [s.get("name") for s in committed["skills"]]
    rebuilt_order = [s.get("name") for s in rebuilt["skills"]]
    if committed_order != rebuilt_order and sorted(committed_order) == sorted(rebuilt_order):
        problems.append("skills[] order differs from build-index.sh output (sorted by name)")

    return problems


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} COMMITTED.json REBUILT.json\n")
        return 2
    docs = []
    for path in argv[1:]:
        try:
            with open(path, encoding="utf-8") as handle:
                docs.append(json.load(handle))
        except (OSError, ValueError) as exc:
            sys.stderr.write(f"ERROR: cannot read {path}: {exc}\n")
            return 2

    problems = differences(*docs)
    if not problems:
        print(
            f"OK: committed registry.json matches a fresh build-index.sh run "
            f"({docs[0].get('skillCount')} skills; "
            f"'generatedFromCommit' and per-skill 'hash' excluded — they are git-derived "
            f"and change on squash-merge)."
        )
        return 0

    print("::error::registry.json is stale — run ./scripts/build-index.sh and commit it")
    for problem in problems:
        print(f"  - {problem}")
    print(
        "  (the git-derived fields 'generatedFromCommit' and per-skill 'hash' are NOT "
        "compared, so none of the above is squash-merge noise)"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
