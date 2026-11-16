#!/usr/bin/env python3
"""vault-sync.py - fast-forward push of the private notes vault, with a scope check.

  status                 offline: ahead/behind of the last-fetched upstream, ahead commits, dirty counts
  push [--dry-run]       fetch the one remote branch, refuse unless behind=0 and the remote repo is
                         private, scan every unpushed commit for credential-shaped lines, sensitive
                         paths and huge blobs, then `git push <remote> HEAD:refs/heads/<branch>`

Exit codes: 0 ok (pushed, or nothing to push), 1 refused (nothing pushed), 2 usage/environment error.

The script never pulls, merges, rebases, resets or forces; a refusal tells the agent to leave the
commits local and report it. The scope check is a heuristic backstop, not a guarantee.
Stdlib only. See docs/vault-sync.md.
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys

GIT_TIMEOUT = 60
NET_TIMEOUT = 120
MAX_BLOB = 50 * 1024 * 1024
DROP_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE")


def test_mode():
    return os.environ.get("VAULT_SYNC_TEST") == "1"


def git_env():
    env = {k: v for k, v in os.environ.items()
           if k not in DROP_ENV and not k.startswith("GIT_CONFIG")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    return env


def run(cmd, cwd, timeout=GIT_TIMEOUT, env=None):
    """Return (rc, stdout, stderr) as text; rc 124 on timeout, 127 when the program is missing."""
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env if env is not None else git_env(), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss: %s" % (timeout, " ".join(cmd[:3]))
    except OSError as e:
        return 127, "", str(e)
    return (p.returncode, p.stdout.decode("utf-8", errors="replace"),
            p.stderr.decode("utf-8", errors="replace"))


def git(vault, *args, timeout=GIT_TIMEOUT):
    return run(["git"] + list(args), vault, timeout)


def die(code, msg):
    print(msg, file=sys.stderr if code == 2 else sys.stdout)
    sys.exit(code)


class Ctx:
    pass


def resolve(args):
    vault = args.vault or os.environ.get("CLAUDE_VAULT_DIR") or os.path.expanduser("~/Obsidian/no-it-all")
    vault = os.path.realpath(os.path.expanduser(vault))
    if not os.path.isdir(vault):
        die(2, "ERROR: vault is not a directory: %s" % vault)
    rc, top, _ = git(vault, "rev-parse", "--show-toplevel")
    if rc != 0 or os.path.realpath(top.strip()) != vault:
        die(2, "ERROR: not the top of a git repository: %s" % vault)
    rc, br, _ = git(vault, "symbolic-ref", "--short", "-q", "HEAD")
    if rc != 0 or not br.strip():
        die(2, "ERROR: detached HEAD; check out the vault branch first")
    c = Ctx()
    c.vault, c.branch = vault, br.strip()
    rc, remote, _ = git(vault, "config", "--get", "branch.%s.remote" % c.branch)
    rc2, merge, _ = git(vault, "config", "--get", "branch.%s.merge" % c.branch)
    c.remote, merge = remote.strip(), merge.strip()
    if rc != 0 or rc2 != 0 or not c.remote or c.remote == "." or not merge.startswith("refs/heads/"):
        die(2, "ERROR: branch %s has no upstream on a remote" % c.branch)
    c.rbranch = merge[len("refs/heads/"):]
    return c


def ahead_behind(vault, other):
    rc, out, err = git(vault, "rev-list", "--left-right", "--count", "HEAD...%s" % other)
    if rc != 0:
        die(2, "ERROR: cannot compare with %s: %s" % (other, err.strip()))
    a, b = out.split()
    return int(a), int(b)


def cmd_status(args):
    c = resolve(args)
    up = "refs/remotes/%s/%s" % (c.remote, c.rbranch)
    rc, _, _ = git(c.vault, "rev-parse", "--verify", "-q", up)
    if rc != 0:
        die(2, "ERROR: no last-fetched %s/%s (run push, or fetch it by hand)" % (c.remote, c.rbranch))
    ahead, behind = ahead_behind(c.vault, up)
    print("branch: %s -> %s/%s" % (c.branch, c.remote, c.rbranch))
    print("ahead %d behind %d" % (ahead, behind))
    if ahead:
        rc, out, _ = git(c.vault, "log", "--format=%h %s", "%s..HEAD" % up)
        for line in out.splitlines():
            print("  " + line)
    rc, out, _ = git(c.vault, "status", "--porcelain=v1", "--untracked-files=normal")
    mod = unt = 0
    for line in out.splitlines():
        if line.startswith("??"):
            unt += 1
        elif not line.startswith("!!") and line.strip():
            mod += 1
    print("dirty: %d modified, %d untracked" % (mod, unt))
    return 0


# ---- visibility gate -------------------------------------------------------

def parse_slug(url):
    """owner/name from a github.com remote URL, else None."""
    url = url.strip()
    pats = (r"^(?:https?|ssh|git)://(?:[^@/]+@)?github\.com(?::\d+)?/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$",
            r"^[^@/\s]+@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")
    for p in pats:
        m = re.match(p, url)
        if m:
            return "%s/%s" % (m.group(1), m.group(2))
    return None


def visibility_gate(c, skip):
    if skip:
        if not test_mode():
            die(2, "ERROR: --skip-visibility-check is only honoured when VAULT_SYNC_TEST=1")
        print("visibility: SKIPPED (test mode)")
        return None
    slug = os.environ.get("VAULT_SYNC_TEST_REPO") if test_mode() else None
    if not slug:
        urls = []
        for extra in ((), ("--push",)):
            rc, out, _ = git(c.vault, "remote", "get-url", *(extra + (c.remote,)))
            if rc == 0 and out.strip():
                urls.append(out.strip())
        slugs = set(parse_slug(u) for u in urls)
        if not urls or len(slugs) != 1 or None in slugs:
            print("REFUSED: cannot tell which GitHub repository remote '%s' is, so privacy cannot be verified" % c.remote)
            sys.exit(1)
        slug = slugs.pop()
    rc, out, err = run(["gh", "repo", "view", slug, "--json", "visibility", "-q", ".visibility"],
                       c.vault, NET_TIMEOUT, env=dict(os.environ, GH_PROMPT_DISABLED="1"))
    if rc == 127:
        print("REFUSED: gh is not available, so repository visibility cannot be verified")
        sys.exit(1)
    vis = out.strip().strip('"').upper()
    if rc != 0 or not vis:
        print("REFUSED: gh could not report the visibility of %s (exit %d)" % (slug, rc))
        sys.exit(1)
    if vis != "PRIVATE":
        print("REFUSED: %s is %s, not PRIVATE" % (slug, vis))
        sys.exit(1)
    print("visibility: %s is PRIVATE" % slug)
    return slug


# ---- scope check -----------------------------------------------------------

def has_mixed(v):
    return bool(re.search(r"\d", v)) or (bool(re.search(r"[a-z]", v)) and bool(re.search(r"[A-Z]", v)))


def _assign(m):
    v = m.group(2)
    return len(v) >= 8 and not v.startswith(("${", "$(", "{{", "<")) and has_mixed(v)


def _bearer(m):
    return has_mixed(m.group(1))


LINE_RULES = [
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), None),
    ("sk-key", re.compile(r"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{19,}"), None),
    ("stripe-key", re.compile(r"\b[sr]k_(?:live|test)_[A-Za-z0-9]{8,}"), None),
    ("slack-token", re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{8,}"), None),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), None),
    ("private-key-block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"), None),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"), None),
    ("secret-assignment", re.compile(r"(?i)(password|passwd|secret|token|api[_-]?key)[\"']?\s*[:=]\s*[\"']?([^\s\"']{8,})"), _assign),
    ("bearer-token", re.compile(r"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{20,})"), _bearer),
]
PATH_GLOBS = [".env*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "*credentials*", "*.p12", "*.keychain*"]


def sensitive_path(path):
    base = path.rsplit("/", 1)[-1].lower()
    for g in PATH_GLOBS:
        if fnmatch.fnmatchcase(base, g):
            return g
    return None


def line_rule(text):
    for name, rx, check in LINE_RULES:
        for m in rx.finditer(text):
            if check is None or check(m):
                return name
    return None


def commit_changes(vault, sha):
    """[(status, path, new_blob_sha, mode)] for one commit (each parent, for a merge)."""
    rc, out, err = git(vault, "-c", "core.quotepath=false", "diff-tree", "-r", "-m", "--root", "--no-commit-id",
                       "--no-renames", "--no-ext-diff", "--raw", "-z", sha, timeout=120)
    if rc != 0:
        die(2, "ERROR: cannot list changes of %s: %s" % (sha[:8], err.strip()))
    toks = out.split("\0")
    res, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t.startswith(":") and i + 1 < len(toks):
            f = t[1:].split()
            res.append((f[4][:1], toks[i + 1], f[3], f[1]))
            i += 2
        else:
            i += 1
    return res


def commit_added_lines(vault, sha):
    """[(path, lineno, text)] added lines of one commit."""
    rc, out, err = git(vault, "-c", "core.quotepath=false", "diff-tree", "-p", "-U0", "-m", "--root", "--no-commit-id",
                       "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color",
                       "--src-prefix=a/", "--dst-prefix=b/", sha, timeout=180)
    if rc != 0:
        die(2, "ERROR: cannot diff %s: %s" % (sha[:8], err.strip()))
    res, path, ln = [], None, 0
    for line in out.split("\n"):
        if line.startswith("diff --git "):
            path, ln = None, 0
        elif line.startswith("+++ "):
            p = line[4:].split("\t")[0]
            path = p[2:] if p.startswith("b/") else None
        elif line.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)", line)
            ln = int(m.group(1)) if m else 0
        elif line.startswith("+") and path is not None:
            res.append((path, ln, line[1:]))
            ln += 1
    return res


def blob_sizes(vault, shas):
    if not shas:
        return {}
    try:
        p = subprocess.run(["git", "cat-file", "--batch-check"], cwd=vault, env=git_env(),
                           input=("\n".join(shas) + "\n").encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=GIT_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError) as e:
        die(2, "ERROR: cat-file failed: %s" % e)
    out = {}
    for line in p.stdout.decode("utf-8", errors="replace").splitlines():
        f = line.split()
        if len(f) == 3 and f[1] == "blob":
            out[f[0]] = int(f[2])
    return out


def scope_check(c, base, allow):
    rc, out, err = git(c.vault, "rev-list", "--reverse", "%s..HEAD" % base)
    if rc != 0:
        die(2, "ERROR: cannot list commits: %s" % err.strip())
    commits = out.split()
    findings, allowed, paths, added = [], [], set(), 0
    limit = MAX_BLOB
    for sha in commits:
        short = sha[:8]
        changes = commit_changes(c.vault, sha)
        live = [x for x in changes if set(x[2]) != {"0"} and x[3] != "160000"]
        sizes = blob_sizes(c.vault, [x[2] for x in live])
        for status, path, blob, mode in changes:
            paths.add(path)
        for status, path, blob, mode in live:
            if status == "A":
                added += 1
            rules = []
            g = sensitive_path(path)
            if g:
                rules.append("sensitive-path (%s)" % g)
            if sizes.get(blob, 0) > limit:
                rules.append("blob over %d MB (%d bytes)" % (limit // (1024 * 1024), sizes[blob]))
            for r in rules:
                (allowed if path in allow else findings).append((short, path, None, r))
        for path, ln, text in commit_added_lines(c.vault, sha):
            r = line_rule(text)
            if r:
                (allowed if path in allow else findings).append((short, path, ln, r))
    print("scope: %d commits, %d paths, %d files added" % (len(commits), len(paths), added))
    for short, path, ln, r in allowed:
        print("allowed (--allow-path): %s %s%s [%s]" % (short, path, ":%d" % ln if ln else "", r))
    if findings:
        print("REFUSED: scope check found %d suspected exposure(s); values are not printed:" % len(findings))
        for short, path, ln, r in findings:
            print("  %s %s%s [%s]" % (short, path, ":%d" % ln if ln else "", r))
        print("Leave the commits local and report this refusal to the owner. If a finding is a reviewed "
              "false positive the owner may re-run with --allow-path <path>.")
        sys.exit(1)
    return commits


# ---- push ------------------------------------------------------------------

def cmd_push(args):
    c = resolve(args)
    for p in args.allow_path:
        print("allow-path in effect: %s" % p)
    rc, out, err = git(c.vault, "-c", "fetch.prune=false", "-c", "fetch.pruneTags=false", "fetch", "--no-tags",
                       "--no-recurse-submodules", c.remote, c.rbranch, timeout=NET_TIMEOUT)
    if rc != 0:
        die(2, "ERROR: fetch of %s %s failed: %s" % (c.remote, c.rbranch, err.strip()))
    rc, tip, _ = git(c.vault, "rev-parse", "--verify", "FETCH_HEAD^{commit}")
    tip = tip.strip()
    if rc != 0 or not tip:
        die(2, "ERROR: cannot resolve the fetched remote tip")
    ahead, behind = ahead_behind(c.vault, tip)
    print("branch: %s -> %s/%s  ahead %d behind %d" % (c.branch, c.remote, c.rbranch, ahead, behind))
    if behind:
        print("REFUSED: %s the remote. Nothing was pushed. This script never pulls, merges or rebases; "
              "report it and reconcile by hand with the owner." % ("diverged from" if ahead else "behind"))
        sys.exit(1)
    if not ahead:
        print("nothing to push")
        return 0
    visibility_gate(c, args.skip_visibility_check)
    scope_check(c, tip, set(args.allow_path))
    rc, head, _ = git(c.vault, "rev-parse", "HEAD")
    head = head.strip()
    if args.dry_run:
        print("dry-run: would push %s..%s (%d commits) to %s %s" % (tip[:8], head[:8], ahead, c.remote, c.rbranch))
        return 0
    rc, out, err = git(c.vault, "push", c.remote, "HEAD:refs/heads/%s" % c.rbranch, timeout=NET_TIMEOUT)
    if rc != 0:
        print("REFUSED: git push failed (exit %d): %s" % (rc, (err or out).strip()))
        sys.exit(1)
    print("pushed: %s..%s" % (tip[:8], head[:8]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vault", help="vault path (default $CLAUDE_VAULT_DIR, else ~/Obsidian/no-it-all)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="offline ahead/behind and dirty counts")
    p = sub.add_parser("push", help="fast-forward push after the visibility and scope checks")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--allow-path", action="append", default=[], metavar="PATH",
                   help="literal repo-relative path to exempt from the scope check (owner-reviewed false positive)")
    p.add_argument("--skip-visibility-check", action="store_true", help=argparse.SUPPRESS)
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    return cmd_status(args) if args.cmd == "status" else cmd_push(args)


if __name__ == "__main__":
    sys.exit(main())
