#!/usr/bin/env python3
"""Own the session handoff seed: resolve its scope, archive on collide, write it, prove it.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/session-seed.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/session-seed.py write  --picks-up-at TEXT [--body-file F]
  python3 ~/.claude/scripts/session-seed.py verify [--topic T] [--session ID]
  python3 ~/.claude/scripts/session-seed.py path   [--topic T]
  python3 ~/.claude/scripts/session-seed.py scope  [--topic T]
  python3 ~/.claude/scripts/session-seed.py list   [--archives]
  python3 ~/.claude/scripts/session-seed.py header PATH

The seed is the fleet's continuity mechanism: the one file the NEXT session opens.
It lives at an absolute path OUTSIDE every git workspace —
`$CLAUDE_HANDOFF_DIR/NEXT-<scope>.md`, default dir `~/Obsidian/no-it-all/handoffs/`
— because an absolute path there has no worktree to be torn down with, no branch to
be unreachable from, and no index to be confused with. Three earlier designs put it
inside a workspace and lost it to exactly those three surfaces.

This script exists because the fourth failure was different in kind: the logic was
PROSE CONTAINING BASH, transcribed and executed by an agent, and every fix added
more shell to a markdown file. Scope resolution, session-id resolution,
archive-on-collide, the write and the proof are one implementation here, so the two
places that used to hold near-copies of it cannot drift apart.

WHAT IT REFUSES TO GUESS
  * The scope key comes from git, never from an argument and never from a $PWD
    prefix test. Anything that is not "this is not a git repository" is a REFUSE,
    not a fallback to `fleet`.
  * The session id comes from --session or $CLAUDE_CODE_SESSION_ID, in that order,
    and from nothing else. There is no scan, no most-recent-mtime pick, no
    "probably this one". A session that cannot name itself writes no seed: an
    anonymous seed is one the next session cannot archive and this one cannot prove.

Exit codes:
  0  the operation succeeded (for `write` and `verify`: the canonical seed for this
     scope exists, carries this session's id, and sits outside every worktree).
  1  REFUSE — stated on stderr, and for `write` nothing was written and no incumbent
     seed was moved or destroyed.
  2  usage error.
"""
import argparse
import errno
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_HANDOFF_DIR = "~/Obsidian/no-it-all/handoffs"

# The name shape that tells an ARCHIVED seed from a canonical one, and the single
# definition of it. `/next` ranks canonical seeds and never archives, so both sides
# of that decision have to agree exactly — they used to be two hand-written regexes
# in two markdown files, which is how the dot defect below survived.
#
# `[^.]+` in the id position is load-bearing: the scope key itself may contain dots
# (`blamechris.github.io` is a legal directory basename, so it is a legal scope), so
# "the name contains a dot" cannot be the discriminator. The suffix must be exactly
# `.<UTC stamp>-<slug>.md` with no further dots — which is why SLUG_ALLOWED below
# does NOT keep `.`.
ARCHIVE_SUFFIX = re.compile(r"\.[0-9]{8}T[0-9]{6}Z-[^.]+\.md$")

# One filename component, and one WITHOUT dots. An earlier sanitiser kept `.`, so an
# incumbent whose `session:` held a dot (`a.b`) produced `NEXT-<scope>.<UTC>-a.b.md`
# — which ARCHIVE_SUFFIX cannot match, so `/next` read the archive as a canonical
# seed and hung a phantom scope `<scope>.<UTC>-a` off the fleet listing. Dots map to
# `-` like every other disallowed byte.
SLUG_ALLOWED = re.compile(r"[^A-Za-z0-9_-]")
SLUG_MAX = 40

TOPIC_OK = re.compile(r"\A[A-Za-z0-9_-]+\Z")
UUID = re.compile(r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                  r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")
# A session id that needs no YAML quoting. A leading `-` is excluded on purpose: it
# is a plain scalar to YAML, but it reads as a sequence item to a human skimming.
BARE_SCALAR = re.compile(r"\A[A-Za-z0-9_@+][A-Za-z0-9._/@+-]*\Z")
FM_LINE = re.compile(r"\A([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)\Z")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def die(msg):
    """REFUSE and stop. Nothing partial is left behind by any caller of this."""
    print("REFUSE: " + msg, file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------- scope

def _git(*args):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True)
    except FileNotFoundError:
        die("cannot resolve scope: `git` is not on PATH. The scope key is derived "
            "from git and from nothing else, so a missing git is 'I do not know "
            "which scope this is', not 'this must be the fleet'.")


def resolve_scope(topic=None):
    """The scope key: the MAIN worktree's directory basename, or `fleet`.

    `--git-common-dir` points at the shared `.git` — the repo's identity — from the
    main checkout, a nested subdirectory, a detached HEAD and every linked worktree
    alike. `--path-format=absolute` is an addition to that test, not a substitute:
    the bare form returns a relative `.git` from a main checkout, which cannot be
    dirname'd into a repo root.

    Not the origin slug: `chroxy` and `chroxy-daemon` share one origin URL and are
    separate projects with separate work, so keying on the remote would merge their
    seeds and let each overwrite the other's.

    Not a $PWD prefix match against ~/Projects: linked worktrees routinely live
    under /private/tmp, and a prefix test reports "fleet" from inside a repo.
    """
    r = _git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if r.returncode != 0:
        # ONLY "not a repository" means fleet. Dubious ownership, a corrupt index,
        # a git too old for --path-format — each of those is a question this cannot
        # answer, and answering `fleet` would file the seed under the wrong scope
        # while looking like a success.
        if "not a git repository" not in (r.stderr or "").lower():
            die("cannot resolve scope: git failed for a reason other than 'not a "
                "repository' — %s" % ((r.stderr or "").strip() or "no stderr"))
        if topic is not None and not TOPIC_OK.match(topic):
            die("--topic %r is not one filename component of [A-Za-z0-9_-]" % topic)
        return "fleet-" + topic if topic else "fleet"

    if topic is not None:
        die("--topic is only meaningful outside a repo. In repo scope the seed is "
            "keyed on the repo, so a topic would fork it into a second seed nobody "
            "reads. Drop --topic, or run from outside any git workspace.")

    bare = _git("rev-parse", "--is-bare-repository")
    if bare.returncode == 0 and bare.stdout.strip() == "true":
        die("cannot resolve scope: this is a bare repository, whose common dir is "
            "the repo itself — its basename is not a worktree name. A session does "
            "not run in a bare repo; run from a worktree.")

    common = (r.stdout or "").strip()
    if not common:
        die("cannot resolve scope: git reported no common dir")
    scope = os.path.basename(os.path.dirname(os.path.abspath(common)))
    if not scope or scope in (".", ".."):
        die("cannot resolve scope: the main worktree's parent has no usable "
            "basename (common dir %r)" % common)
    return scope


def _worktree_roots():
    """This worktree's root and the main worktree's root, for the location proof."""
    roots = []
    r = _git("rev-parse", "--show-toplevel")
    if r.returncode == 0 and r.stdout.strip():
        roots.append(os.path.realpath(r.stdout.strip()))
    c = _git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if c.returncode == 0 and c.stdout.strip():
        roots.append(os.path.realpath(os.path.dirname(c.stdout.strip())))
    return roots


def _is_under(child, parent):
    child, parent = os.path.realpath(child), os.path.realpath(parent)
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


# ---------------------------------------------------------------- paths / dir

def handoff_dir():
    d = os.environ.get("CLAUDE_HANDOFF_DIR") or DEFAULT_HANDOFF_DIR
    d = os.path.expanduser(d)
    if not os.path.isabs(d):
        # A relative seed dir resolves against whatever cwd the session happens to
        # have — which is usually a worktree, i.e. the one place the seed may not
        # live. Refuse rather than silently re-creating the failure this design
        # exists to remove.
        die("CLAUDE_HANDOFF_DIR=%r is relative. The seed's whole property is that "
            "it sits at an absolute path outside every git workspace." % d)
    return d


def seed_path(scope, directory=None):
    directory = directory or handoff_dir()
    name = "NEXT-%s.md" % scope
    # The canonical name must not be readable as an archive by `/next`, or the seed
    # this session writes is invisible to the dispatcher that ranks it. Only a repo
    # directory literally named like a timestamped archive can do this, which is
    # absurd and therefore exactly the kind of thing that is never noticed.
    if ARCHIVE_SUFFIX.search(name):
        die("scope %r makes the canonical seed name %r indistinguishable from an "
            "archived seed. Rename the checkout." % (scope, name))
    return os.path.join(directory, name)


# ------------------------------------------------------------------ frontmatter

def _unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    # Only an UNQUOTED scalar can carry a trailing `#` comment. Stripping it before
    # unquoting is what mangles `picks_up_at: "issue #205 — ..."`, which is the one
    # field `/next` quotes verbatim.
    return re.sub(r"\s+#.*\Z", "", v).strip()


def _quote(v):
    return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')


def read_frontmatter(path):
    """Parse the seed's YAML frontmatter. Missing file or no frontmatter -> {}.

    One parser, used by archive-on-collide, by the proof, by `list` and by `header`,
    so "what this file's `session:` says" cannot mean two different things in two
    places — which is the whole reason the incumbent's identity was ever in doubt.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}
    out = {}
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        m = FM_LINE.match(ln)
        if m and m.group(1) not in out:
            out[m.group(1)] = _unquote(m.group(2))
    return out


def incumbent_session(path):
    """The id an existing seed claims, or `unknown` when it claims none.

    Unidentifiable is a reason to KEEP a seed, not to clobber it: `unknown` never
    equals a resolved session id, so the collision arm always runs.
    """
    return read_frontmatter(path).get("session", "").strip() or "unknown"


# ------------------------------------------------------------------ session id

def resolve_session_id(explicit=None):
    """--session, then $CLAUDE_CODE_SESSION_ID, then REFUSE. Deterministic, in that order.

    THERE IS NO THIRD SOURCE, and in particular no "pick the most recently modified
    transcript under ~/.claude/projects". That pick is fleet-wide: on a machine
    running several sessions at once it returns whichever session most recently
    wrote a turn, which is neither stable across the two calls this checklist makes
    nor necessarily this session at all. A seed whose `session:` names a different
    session is worse than no seed: the next session archives on it and this one's
    proof passes on somebody else's authorship.

    $CLAUDE_CODE_SESSION_ID is the harness's own id for this session, so it is
    stable for the session's whole life and needs nothing on disk. A UUID is
    truncated to its first 8 characters, which is exactly what
    usage-benchmark-row.py prints in the id column of artifact ① — so the seed and
    the benchmark row name the session with the same string.
    """
    src, sid = "--session", explicit
    if sid is None:
        src, sid = "$CLAUDE_CODE_SESSION_ID", os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid is None or not sid.strip():
        die("this session has no id. Pass --session <id>, or run where the harness "
            "sets $CLAUDE_CODE_SESSION_ID. No seed is written: an anonymous seed "
            "cannot be archived by the next session or proved by this one, so an "
            "unresolvable id is a reason to halt, not a value to carry.")
    sid = sid.strip()
    if CONTROL.search(sid):
        die("the session id from %s contains a control character" % src)
    if "#" in sid:
        die("the session id from %s contains '#', which reads as a YAML comment in "
            "the seed's `session:` field and would not round-trip" % src)
    return sid[:8].lower() if UUID.match(sid) else sid


def slug(session_id):
    """The incumbent's id reduced to one dotless filename component.

    The incumbent's OWN BYTES must never steer the path that protects it. The id is
    documented as `[session-id-or-jsonl-path]` upstream, so a slash in one is a
    plausible agent choice rather than an attack — and interpolated raw it names a
    directory that does not exist, so the archive fails and (before the guard) the
    write went ahead anyway.

    Containment is separately structural: the slug is interpolated BEHIND the
    `NEXT-<scope>.<UTC>-` prefix, so it is never the leading component of a path
    element and a `..` inside it is just characters in a filename. Keep it there.
    """
    s = SLUG_ALLOWED.sub("-", session_id)[:SLUG_MAX]
    return s if s.strip("-") else "unknown"


# --------------------------------------------------------------------- archive

def archive(seed, scope, directory, stamp):
    """Move the incumbent aside, atomically, or REFUSE without touching it.

    THE ARCHIVE IS WHAT EARNS THE RIGHT TO WRITE, so every caller treats a failure
    here as fatal. Unguarded, this destroys the incumbent with no race and no
    hostile actor: creating the archive needs the write bit on the DIRECTORY, while
    overwriting a file inside it does not — so a read-only handoff dir silently
    turns "archive then write" into "write over it".

    `link()` then `unlink()`, not `rename()`: rename onto an existing name
    overwrites it, so the check-then-rename form destroys the archive it made a
    moment earlier whenever the same incumbent is archived twice inside one UTC
    second — which is precisely what a wave boundary does. `link()` fails with
    EEXIST instead, so stepping to the first free `-<n>` is atomic rather than a
    check with a window in it.
    """
    base = os.path.join(directory, "NEXT-%s.%s-%s" % (scope, stamp, slug(incumbent_session(seed))))
    for n in range(100):
        arch = "%s.md" % base if n == 0 else "%s-%d.md" % (base, n)
        try:
            os.link(seed, arch)
        except FileExistsError:
            continue                      # taken by an earlier archive; step past it
        except OSError as e:
            if e.errno in (errno.EPERM, errno.ENOSYS, errno.EOPNOTSUPP, errno.EMLINK, errno.EXDEV):
                # A filesystem without hardlinks. Fall back to the older
                # check-then-rename, which keeps the sequential guarantee and loses
                # only the atomicity against a concurrent writer.
                if os.path.exists(arch):
                    continue
                try:
                    os.rename(seed, arch)
                except OSError as e2:
                    die("could not archive %s (%s) — the incumbent stays, the seed "
                        "is not written" % (seed, e2))
                return arch
            die("could not archive %s (%s) — the incumbent stays, the seed is not "
                "written" % (seed, e))
        try:
            os.unlink(seed)
        except OSError as e:
            die("archived %s to %s but could not clear the canonical name (%s) — "
                "the seed is not written" % (seed, arch, e))
        return arch
    die("no free archive name for %s after 100 tries — the incumbent stays, the "
        "seed is not written" % seed)


# ----------------------------------------------------------------------- write

SKELETON = """## STATE

- **Branch / HEAD:** {branch}
- **Working tree:** <clean | the files another session left>
- **CI:** <last run and verdict>
- **Tests:** <suite and result>
- **Open PRs / issues:** <numbers>

Verify before building on any of this — re-derive, don't trust:

```bash
gh pr view <n> --json state -q .state      # expect: MERGED
git log --oneline -3                       # expect: <the commit this claims>
```

## TL;DR — what shipped

- <one line per landed change>

## Today's task

{picks_up_at}

Alternatives, if that is blocked: <the next two>

## Left undone, deliberately

- <item> — <why it is blocked or deferred>

Repeat the session-lifecycle protocol at this session's end: write the next seed
with `session-seed.py write`, and hand back the one line to paste.
"""


def render(scope, sid, date, picks_up_at, title, boundary, sensitivity, body):
    head = [
        "---",
        "type: handoff",
        "date: %s" % date,
        "scope: %s" % scope,
        "session: %s" % (sid if BARE_SCALAR.match(sid) else _quote(sid)),
        "picks_up_at: %s" % _quote(picks_up_at),
        "sensitivity: %s" % sensitivity,
        "---",
        "# Handoff — %s" % title,
        "",
        "- **Boundary reason:** %s" % boundary,
        "- **Picks up at:** %s" % picks_up_at,
        "",
        "",
    ]
    return "\n".join(head) + body.rstrip("\n") + "\n"


def atomic_write(path, text):
    """Write via a sibling temp file, so a failure never leaves a truncated seed.

    In a read-only handoff dir this fails at the temp file rather than truncating
    the canonical name in place, which is the other half of the `rename(2)` asymmetry
    that `archive()` documents.
    """
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die("could not write %s (%s)" % (path, e))


def cmd_write(a):
    scope = resolve_scope(a.topic)
    sid = resolve_session_id(a.session)
    now = parse_now(a.now)

    if not a.picks_up_at.strip():
        die("--picks-up-at is empty. It is the only line `/next` quotes, so a seed "
            "without it tells the next session nothing about where to start.")
    for name, val in (("--picks-up-at", a.picks_up_at), ("--title", a.title),
                      ("--boundary-reason", a.boundary_reason)):
        if "\n" in val or CONTROL.search(val):
            die("%s contains a newline or control character; it is a single "
                "frontmatter line" % name)

    directory = handoff_dir()
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as e:
        die("handoff dir %s does not exist and cannot be created (%s)" % (directory, e))
    if not os.path.isdir(directory):
        die("handoff dir %s is not a directory" % directory)

    seed = seed_path(scope, directory)
    for root in _worktree_roots():
        if _is_under(seed, root):
            die("%s is inside the worktree %s. The seed's whole property is that no "
                "teardown, branch switch or index can put it out of reach." % (seed, root))

    archived = None
    if os.path.exists(seed):
        prev = incumbent_session(seed)
        if prev != sid:
            archived = archive(seed, scope, directory, now.strftime("%Y%m%dT%H%M%SZ"))

    body = a.body if a.body is not None else SKELETON.format(
        branch=current_branch(), picks_up_at=a.picks_up_at)
    atomic_write(seed, render(
        scope, sid, now.strftime("%Y-%m-%dT%H:%MZ"), a.picks_up_at,
        a.title or a.picks_up_at, a.boundary_reason, a.sensitivity, body))

    if archived:
        print("archived: %s" % archived)
    if not a.no_verify:
        # The proof re-derives everything from scratch in a fresh process, with the
        # same cwd and the same explicit --topic this write used. It is not handed a
        # single value computed above: a check given the writer's own path can only
        # confirm the writer's own arithmetic, and the path is the half worth
        # doubting. Because both sides call ONE resolve_scope(), a topic-scoped
        # fleet seed is the same first-class case in the write and in the proof.
        argv = [sys.executable, os.path.abspath(__file__), "verify", "--session", sid]
        if a.topic is not None:
            argv += ["--topic", a.topic]
        r = subprocess.run(argv, capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        if r.returncode != 0:
            sys.exit(r.returncode)
    else:
        # A DIFFERENT string on purpose. `seed: <path>` is the proved form and only
        # the proof emits it, so "the write printed a path" can never be mistaken
        # for "the write proved the path".
        print("wrote (UNPROVED): %s" % seed)
    return 0


def current_branch():
    r = _git("branch", "--show-current")
    b = (r.stdout or "").strip() if r.returncode == 0 else ""
    return b or "(detached or not in a repo)"


def parse_now(s):
    if not s:
        return datetime.now(timezone.utc)
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        die("--now %r is not an ISO-8601 timestamp" % s)
    return d.astimezone(timezone.utc) if d.tzinfo else d.replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------------- verify

def cmd_verify(a):
    """Prove the seed the NEXT session will read is THIS session's.

    Existence is not the property worth proving — a file is at the canonical path in
    every failure mode this checklist has. Two modes matter and they fail in
    different halves, so the check re-derives AND reads back:

    * WRONG FILE — the scope was keyed on something other than the main worktree, so
      a perfectly well-formed seed sits at a path nobody opens while the previous
      session's stale seed still occupies the canonical name. Only re-deriving the
      scope catches this.
    * RIGHT FILE, WRONG AUTHOR — the archive was destroyed and overwritten, so the
      canonical path holds someone else's seed. Only reading `session:` back catches
      this; it is the same field the archive decides on, used a second time as proof.
    """
    scope = resolve_scope(a.topic)
    sid = resolve_session_id(a.session)
    seed = seed_path(scope)

    for root in _worktree_roots():
        if _is_under(seed, root):
            die("%s is inside the worktree %s" % (seed, root))

    if not os.path.exists(seed):
        extra = _elsewhere(sid, scope)
        die("no seed at %s%s" % (seed, extra))
    mine = read_frontmatter(seed).get("session", "").strip()
    if not mine:
        die("%s carries no `session:` — an unidentified seed is not a proof of "
            "authorship" % seed)
    if mine != sid:
        die("%s carries session %r, not this session's %r%s"
            % (seed, mine, sid, _elsewhere(sid, scope)))
    print("seed: %s" % seed)
    return 0


def _elsewhere(sid, scope):
    """Name this session's seed if it landed under a different scope key.

    A topic-scoped fleet session that runs the proof without its --topic would
    otherwise get a bare 'not yours' and no way to tell a misfiled seed from a
    forgotten flag. Reporting is all this does — it never widens what passes.
    """
    d = handoff_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return ""
    hits = [n for n in names
            if n.startswith("NEXT-") and n.endswith(".md")
            and not ARCHIVE_SUFFIX.search(n)
            and n != "NEXT-%s.md" % scope
            and read_frontmatter(os.path.join(d, n)).get("session", "").strip() == sid]
    if not hits:
        return ""
    return (". This session's seed is at %s — if that is a topic-scoped fleet seed, "
            "the proof needs the same --topic the write used"
            % ", ".join(os.path.join(d, n) for n in hits))


# ------------------------------------------------------------- read-only helpers

def cmd_scope(a):
    print(resolve_scope(a.topic))
    return 0


def cmd_path(a):
    print(seed_path(resolve_scope(a.topic)))
    return 0


def cmd_list(a):
    """One row per canonical seed: scope <TAB> date <TAB> path. `--archives` inverts it.

    `/next` ranks from this, so the archive discriminator lives here rather than in
    a second regex in a markdown file. A seed whose `date:` is missing or not
    shaped like a timestamp reports an EMPTY date and must be listed as UNDATED, not
    sorted as old: an empty field sorts before every digit, which silently buries
    exactly the seeds most likely to hold unconsumed work.
    """
    d = handoff_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError as e:
        die("cannot read the handoff dir %s (%s)" % (d, e))
    for n in names:
        if not (n.startswith("NEXT-") and n.endswith(".md")):
            continue
        if bool(ARCHIVE_SUFFIX.search(n)) != bool(a.archives):
            continue
        p = os.path.join(d, n)
        if not os.path.isfile(p):
            continue
        scope = n[len("NEXT-"):-len(".md")]
        if a.archives:
            scope = scope.split(".", 1)[0]
        ts = read_frontmatter(p).get("date", "").strip()
        if not re.match(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T", ts):
            ts = ""
        print("%s\t%s\t%s" % (scope, ts, p))
    return 0


def cmd_header(a):
    if not os.path.isfile(a.path):
        die("no such seed: %s" % a.path)
    print(json.dumps(read_frontmatter(a.path), indent=2, sort_keys=True, ensure_ascii=False))
    return 0


# ------------------------------------------------------------------------ main

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="session-seed.py", description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def scoped(sp):
        sp.add_argument("--topic", help="fleet sessions only: NEXT-fleet-<topic>.md")
        return sp

    w = scoped(sub.add_parser("write", help="archive on collide, write the seed, prove it"))
    w.add_argument("--picks-up-at", required=True,
                   help="the one thing the next session starts on; `/next` quotes it verbatim")
    w.add_argument("--session", help="this session's id (default: $CLAUDE_CODE_SESSION_ID)")
    w.add_argument("--title", default="", help="H1 text (default: --picks-up-at)")
    w.add_argument("--boundary-reason", default="unstated",
                   help="which global session-boundary rule fired")
    w.add_argument("--sensitivity", default="vault", choices=("public", "vault"))
    w.add_argument("--body-file", help="seed body after the header; `-` reads stdin")
    w.add_argument("--now", help="pin the clock (ISO-8601 UTC) for `date:` and the archive stamp")
    w.add_argument("--no-verify", action="store_true",
                   help="skip the built-in proof (it is the point; for tests only)")
    w.set_defaults(fn=cmd_write)

    v = scoped(sub.add_parser("verify", help="prove the canonical seed is this session's"))
    v.add_argument("--session", help="this session's id (default: $CLAUDE_CODE_SESSION_ID)")
    v.set_defaults(fn=cmd_verify)

    scoped(sub.add_parser("scope", help="print the resolved scope key")).set_defaults(fn=cmd_scope)
    scoped(sub.add_parser("path", help="print the canonical seed's absolute path")).set_defaults(fn=cmd_path)

    l = sub.add_parser("list", help="scope<TAB>date<TAB>path for every canonical seed")
    l.add_argument("--archives", action="store_true", help="list archived seeds instead")
    l.set_defaults(fn=cmd_list)

    h = sub.add_parser("header", help="print a seed's frontmatter as JSON")
    h.add_argument("path")
    h.set_defaults(fn=cmd_header)

    a = p.parse_args(argv)
    if getattr(a, "body_file", None):
        if a.body_file == "-":
            a.body = sys.stdin.read()
        else:
            try:
                with open(a.body_file, encoding="utf-8") as f:
                    a.body = f.read()
            except OSError as e:
                die("cannot read --body-file %s (%s)" % (a.body_file, e))
    elif a.cmd == "write":
        a.body = None
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
