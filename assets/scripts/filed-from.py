#!/usr/bin/env python3
"""Check and walk the `Filed from:` linkage every skill-filed issue carries.

#268: session 13cee7be filed ~8 follow-on issues; 3 cited their source PR. Without
a machine-readable source on EVERY issue a skill files, the lagging metric "did
this PR spawn work" is uncomputable, and a rework chain (issue -> PR -> issue
filed from it -> PR ...) cannot be walked without a human re-reading every body.

The grammar (one line, first line of the issue body's `## Context` section,
always present):

    Filed from: #NNN                     -- a PR or issue number (one space;
                                             GitHub numbers share a namespace,
                                             so there is no PR/issue prefix)
    Filed from: #NNN (<url>)             -- same, with the specific review
                                             comment that prompted the issue
    Filed from: session <id>             -- found during a session with no PR
                                             yet (id: 8+ hex/dash chars)
    Filed from: none                     -- a genuinely standalone issue; the
                                             literal word is required so
                                             absence is distinguishable from
                                             forgetting

Two commands:

    check   -- list issues (default: open, label `from-review`) whose body has
               no valid `Filed from:` line, distinguishing a line that is
               simply ABSENT from one that is PRESENT but malformed.
    chain   -- given a number, walk the chain both ways: parents by following
               each node's own `Filed from:` line, children by searching for
               issues that name this number and confirming the match (search
               is fuzzy -- a hit is not proof).

stdlib + the `gh` CLI as a subprocess. Nothing here is trusted blindly: a `gh`
failure is reported and treated as "unknown", never silently as "clean" --
the same discipline `usage-benchmark-row.py`'s `_gh_json` follows, for the
same reason (a corrupted "0" is worse than a visible "could not check").
"""
import argparse
import json
import re
import subprocess
import sys

GH_TIMEOUT = 30

# ---------------------------------------------------------------------------
# Grammar
# ---------------------------------------------------------------------------
# FILED_FROM_PREFIX_RE is deliberately looser than FILED_FROM_RE: it exists so
# `check` can tell "no line at all" (MISSING) apart from "a line that says
# `Filed from:` but doesn't parse" (MALFORMED) -- e.g. a stray "PR " prefix,
# or a missing space after the colon. Both regexes require the EXACT
# case-sensitive text "Filed from:" anchored at the start of a line (`^` in
# MULTILINE mode). A line that doesn't start with that exact casing --
# "filed from: #12", or "Filed from:" appearing mid-sentence rather than at
# the start of its own line -- matches NEITHER regex and is therefore
# reported as MISSING, not malformed. There is no partial credit for close
# casing or wrong placement: a check that accepted "close enough" would stop
# catching the actual typo class it exists to catch.
FILED_FROM_PREFIX_RE = re.compile(r'^Filed from:.*$', re.MULTILINE)

FILED_FROM_RE = re.compile(
    r'^Filed from: (?:'
    r'#(?P<number>\d+)(?: \((?P<url>[^\s()]+)\))?'
    r'|session (?P<session_id>[0-9a-fA-F][0-9a-fA-F-]{7,})'
    r'|(?P<none>none)'
    r')$',
    re.MULTILINE,
)


def parse_filed_from(body):
    """Parse the first valid `Filed from:` line in an issue/PR body.

    Returns a dict -- {'form': 'ref', 'number': int, 'url': str|None, 'raw': str}
    for the `#NNN` / `#NNN (<url>)` forms, {'form': 'session', 'session_id': str,
    'raw': str} for `session <id>`, or {'form': 'none', 'raw': str} for the
    literal `none` -- or None if no line in `body` matches the grammar.

    None is deliberately ambiguous between "no Filed from: line at all" and "a
    Filed from: line is present but malformed" -- callers that need to tell
    those apart (namely `check`, for its reason column) re-check with
    FILED_FROM_PREFIX_RE themselves rather than this function growing a second
    return channel for a distinction only one caller needs.
    """
    if not body:
        return None
    m = FILED_FROM_RE.search(body)
    if not m:
        return None
    raw = m.group(0)
    if m.group('number') is not None:
        return {
            'form': 'ref',
            'number': int(m.group('number')),
            'url': m.group('url'),
            'raw': raw,
        }
    if m.group('session_id') is not None:
        return {'form': 'session', 'session_id': m.group('session_id'), 'raw': raw}
    return {'form': 'none', 'raw': raw}


# ---------------------------------------------------------------------------
# gh plumbing
# ---------------------------------------------------------------------------

def _gh(args):
    """Run gh, returning (returncode, stdout, stderr). Never raises: a missing
    binary or a timeout is reported the same way a non-zero exit is, so every
    caller has exactly one failure path to handle."""
    try:
        r = subprocess.run(['gh'] + args, capture_output=True, text=True, timeout=GH_TIMEOUT)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 1, '', 'gh: command not found'
    except subprocess.TimeoutExpired:
        return 1, '', f'gh: timed out after {GH_TIMEOUT}s'
    except OSError as e:
        return 1, '', f'gh: {e}'


def _gh_json(args):
    """Run gh and parse its stdout as JSON. Returns (data, error) -- exactly
    one of the pair is non-None. A non-zero exit or non-JSON stdout is a
    failure, reported with gh's own stderr so the caller can show it verbatim
    rather than inventing a vaguer message."""
    rc, out, err = _gh(args)
    if rc != 0:
        return None, err.strip() or f'gh exited {rc}'
    try:
        return json.loads(out), None
    except ValueError as e:
        return None, f'gh returned non-JSON output: {e}'


def current_repo():
    """`gh repo view`'s nameWithOwner, or None if gh cannot answer (not inside
    a repo checkout, gh unauthenticated, no network)."""
    rc, out, _ = _gh(['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'])
    out = out.strip()
    return out if rc == 0 and out else None


def _resolve_repo(explicit):
    if explicit:
        return explicit, None
    repo = current_repo()
    if repo:
        return repo, None
    return None, (
        'REFUSE: no --repo given and `gh repo view` could not resolve one '
        '(not inside a repo checkout, or gh is unauthenticated) -- pass '
        '--repo OWNER/NAME'
    )


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

def _flag(issue):
    """Classify one issue as clean, missing, or malformed."""
    body = issue.get('body') or ''
    if parse_filed_from(body) is not None:
        return None
    m = FILED_FROM_PREFIX_RE.search(body)
    if m:
        return {
            'number': issue.get('number'),
            'title': issue.get('title', ''),
            'url': issue.get('url', ''),
            'status': 'malformed',
            'detail': m.group(0),
        }
    return {
        'number': issue.get('number'),
        'title': issue.get('title', ''),
        'url': issue.get('url', ''),
        'status': 'missing',
        'detail': None,
    }


def cmd_check(args):
    repo, refuse = _resolve_repo(args.repo)
    if refuse:
        print(refuse, file=sys.stderr)
        return 2

    list_args = ['issue', 'list', '--repo', repo]
    if not args.all:
        list_args += ['--label', 'from-review']
    list_args += ['--state', args.state, '--limit', '500',
                   '--json', 'number,title,body,labels,url']

    issues, err = _gh_json(list_args)
    if issues is None:
        # A failed listing is never treated as a clean result -- an empty
        # `flagged` list here would print "0 flagged" and look identical to
        # an honest all-clean run.
        print(f'REFUSE: gh issue list failed -- {err}', file=sys.stderr)
        return 2

    flagged = [f for f in (_flag(i) for i in issues) if f is not None]

    if args.json:
        print(json.dumps({'repo': repo, 'total': len(issues), 'flagged': flagged}, indent=2))
    else:
        scope = 'all' if args.all else 'from-review'
        print(f'{repo}: {len(issues)} issue(s) checked ({args.state}, label={scope}), '
              f'{len(flagged)} flagged')
        for f in flagged:
            if f['status'] == 'malformed':
                reason = f'malformed: {f["detail"]}'
            else:
                reason = 'missing'
            print(f'  #{f["number"]:<6} {reason:<48} {f["title"]}')

    return 1 if flagged else 0


# ---------------------------------------------------------------------------
# chain
# ---------------------------------------------------------------------------

def _fetch_node(number, repo):
    """Fetch #number as an issue, falling back to a PR -- #N may be either,
    and gh's issue/PR endpoints are separate. Returns a dict with an added
    'kind' key ('issue' or 'pr'), or None if neither view succeeds."""
    fields = 'number,title,state,body'
    data, _ = _gh_json(['issue', 'view', str(number), '--repo', repo, '--json', fields])
    if data is not None:
        data['kind'] = 'issue'
        return data
    data, _ = _gh_json(['pr', 'view', str(number), '--repo', repo, '--json', fields])
    if data is not None:
        data['kind'] = 'pr'
        return data
    return None


def ancestors(root_node, repo, depth):
    """Walk PARENTS: follow root_node's own `Filed from:` line, then each
    ancestor's in turn, up to `depth` hops. Cycle-safe via a visited set seeded
    with the root -- a chain that loops back on itself stops the instant it
    would revisit a number, rather than recursing forever."""
    visited = {root_node['number']}
    chain = []
    node = root_node
    for _ in range(depth):
        parsed = parse_filed_from(node.get('body') or '')
        if not parsed or parsed['form'] != 'ref':
            break
        parent_num = parsed['number']
        if parent_num in visited:
            break  # cycle
        visited.add(parent_num)
        parent_node = _fetch_node(parent_num, repo)
        if parent_node is None:
            break
        chain.append(parent_node)
        node = parent_node
    return chain


def _search_children(number, repo):
    """Candidates whose body MENTIONS `Filed from: #number` -- gh's search is
    fuzzy (it can match the string anywhere, including inside a different
    grammar form or a quote), so every candidate is re-confirmed with
    parse_filed_from before being trusted."""
    query = f'"Filed from: #{number}" in:body'
    data, _ = _gh_json(['issue', 'list', '--repo', repo, '--state', 'all',
                         '--search', query, '--json', 'number,title,state,body'])
    return data or []


def descendants(root_number, repo, depth, visited, current_depth=0):
    """Walk CHILDREN recursively into a tree, bounded by `depth` and made
    cycle-safe by the same shared `visited` set ancestors() seeded -- a loop
    that runs parent-then-child (or purely through children) still terminates."""
    if current_depth >= depth:
        return []
    children = []
    for cand in _search_children(root_number, repo):
        num = cand.get('number')
        if num is None or num in visited:
            continue
        parsed = parse_filed_from(cand.get('body') or '')
        if not parsed or parsed['form'] != 'ref' or parsed['number'] != root_number:
            continue  # search hit did not survive confirmation
        visited.add(num)
        node = dict(cand)
        node['children'] = descendants(num, repo, depth, visited, current_depth + 1)
        children.append(node)
    return children


def _strip(node):
    d = {'number': node.get('number'), 'title': node.get('title'),
         'state': node.get('state'), 'kind': node.get('kind')}
    if 'children' in node:
        d['children'] = [_strip(c) for c in node['children']]
    return d


def _line(node):
    kind = ' (PR)' if node.get('kind') == 'pr' else ''
    return f'#{node.get("number")} [{node.get("state", "?")}]{kind} {node.get("title", "")}'


def cmd_chain(args):
    repo, refuse = _resolve_repo(args.repo)
    if refuse:
        print(refuse, file=sys.stderr)
        return 2

    root = _fetch_node(args.number, repo)
    if root is None:
        print(f'REFUSE: #{args.number} is not an issue or PR gh can read in {repo}',
              file=sys.stderr)
        return 2

    parents = ancestors(root, repo, args.depth)
    visited = {root['number']} | {p['number'] for p in parents}
    children = descendants(root['number'], repo, args.depth, visited)

    if args.json:
        print(json.dumps({
            'root': _strip(root),
            'parents': [_strip(p) for p in parents],
            'children': [_strip(c) for c in children],
        }, indent=2))
        return 0

    indent = 0
    for p in reversed(parents):
        print('  ' * indent + '^ ' + _line(p))
        indent += 1
    print('  ' * indent + '* ' + _line(root))

    def print_children(nodes, level):
        for c in nodes:
            print('  ' * (indent + level) + 'v ' + _line(c))
            print_children(c.get('children', []), level + 1)
    print_children(children, 1)

    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog='filed-from.py',
        description='Check and walk `Filed from:` linkage on skill-filed issues.',
    )
    sub = p.add_subparsers(dest='command', required=True)

    c = sub.add_parser('check', help='Flag issues missing a valid Filed from: line')
    c.add_argument('--repo', help='OWNER/NAME; defaults to `gh repo view`')
    c.add_argument('--all', action='store_true',
                    help='check every issue in scope, not just label:from-review')
    c.add_argument('--state', choices=['open', 'all'], default='open')
    c.add_argument('--json', action='store_true')
    c.set_defaults(func=cmd_check)

    w = sub.add_parser('chain', help='Walk the Filed from: chain both ways')
    w.add_argument('number', type=int)
    w.add_argument('--repo', help='OWNER/NAME; defaults to `gh repo view`')
    w.add_argument('--depth', type=int, default=10, help='max hops each direction')
    w.add_argument('--json', action='store_true')
    w.set_defaults(func=cmd_chain)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
