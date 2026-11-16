#!/usr/bin/env python3
"""vault-sync.py - fail-closed, fast-forward push of the private notes vault.

  status                 offline: ahead/behind of the last-fetched upstream (short OIDs only), dirty counts
  push [--dry-run] [--allow-path OID:PATH:RULE]...
                         verify the destination, pin HEAD, fetch the one remote branch into a private
                         ref, refuse unless behind=0, scan every unpushed commit's raw content, then
                         push exactly the pinned commit to the verified URL and check the remote tip

Exit codes: 0 ok (pushed, or nothing to push), 1 refused before anything was sent, 2 usage or
environment error, 3 transport failure or indeterminate result (a push may have partly succeeded).

The script never pulls, merges, rebases, resets or forces. The scope check is a heuristic backstop,
not a guarantee. Stdlib only. See docs/vault-sync.md.
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
ZERO = "0" * 40
HEX = re.compile(r"^[0-9a-f]{40}$")


class Refused(Exception):
    """Preflight refusal: exit 1, nothing was sent."""


class EnvError(Exception):
    """Usage or environment problem: exit 2."""


class Indeterminate(Exception):
    """Transport failure or unverifiable outcome: exit 3."""


def git_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    return env


def gh_env():
    """Controlled env for gh: no host, repo, enterprise-token or config-dir overrides."""
    env = {"GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"}
    for k in ("PATH", "HOME", "GH_TOKEN", "GITHUB_TOKEN"):
        if k in os.environ:
            env[k] = os.environ[k]
    return env


BASE_GIT = ["git", "--no-replace-objects", "--no-optional-locks",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "-c", "fetch.prune=false", "-c", "fetch.pruneTags=false",
            "-c", "push.recurseSubmodules=no", "-c", "submodule.recurse=false",
            "-c", "push.followTags=false"]


def run(cmd, cwd, timeout=GIT_TIMEOUT, env=None, data=None):
    """(rc, stdout bytes). rc 124 on timeout, 127 when the program is missing. stderr is discarded:
    it can carry URLs or credentials and is never relayed."""
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env if env is not None else git_env(),
                           input=data, stdin=None if data is not None else subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, b""
    except OSError:
        return 127, b""
    return p.returncode, p.stdout


def git_raw(vault, *args, timeout=GIT_TIMEOUT, data=None):
    return run(BASE_GIT + list(args), vault, timeout, data=data)


def git(vault, *args, timeout=GIT_TIMEOUT):
    rc, out = git_raw(vault, *args, timeout=timeout)
    return rc, out.decode("utf-8", errors="replace")


# ---- output hygiene ----------------------------------------------------------

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


def line_rule(text):
    for name, rx, check in LINE_RULES:
        for m in rx.finditer(text):
            if check is None or check(m):
                return name
    return None


def redact(s):
    for _, rx, check in LINE_RULES:
        s = rx.sub(lambda m, c=check: "<redacted>" if c is None or c(m) else m.group(0), s)
    return s


def safe(s):
    """Printable form of an untrusted string: credential-shaped substrings redacted, control chars escaped."""
    return "".join(c if 0x20 <= ord(c) < 0x7f or ord(c) > 0x9f else "\\x%02x" % ord(c) for c in redact(s))


def sensitive_path(path):
    base = path.rsplit("/", 1)[-1].lower()
    return any(fnmatch.fnmatchcase(base, g) for g in PATH_GLOBS)


# ---- repository resolution ---------------------------------------------------

class Ctx:
    pass


def resolve(args, need_remote):
    vault = args.vault or os.environ.get("CLAUDE_VAULT_DIR") or os.path.expanduser("~/Obsidian/no-it-all")
    vault = os.path.realpath(os.path.expanduser(vault))
    if not os.path.isdir(vault):
        raise EnvError("vault is not a directory")
    rc, top = git(vault, "rev-parse", "--show-toplevel")
    if rc != 0 or os.path.realpath(top.strip()) != vault:
        raise EnvError("not the top of a git repository")
    rc, br = git(vault, "symbolic-ref", "--short", "-q", "HEAD")
    if rc != 0 or not br.strip():
        raise EnvError("detached HEAD; check out the vault branch first")
    c = Ctx()
    c.vault, c.branch = vault, br.strip()
    rc, up = git(vault, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    c.upstream = up.strip()
    if rc != 0 or not c.upstream:
        raise EnvError("branch %s has no upstream" % c.branch)
    if need_remote:
        rc, remote = git(vault, "config", "--get", "branch.%s.remote" % c.branch)
        rc2, merge = git(vault, "config", "--get", "branch.%s.merge" % c.branch)
        c.remote, merge = remote.strip(), merge.strip()
        if rc != 0 or rc2 != 0 or not c.remote or c.remote == "." or not merge.startswith("refs/heads/"):
            raise EnvError("branch %s has no upstream on a remote" % c.branch)
        c.rbranch = merge[len("refs/heads/"):]
    return c


def counts(vault, left, right):
    rc, out = git(vault, "rev-list", "--left-right", "--count", "%s...%s" % (left, right))
    parts = out.split()
    if rc != 0 or len(parts) != 2 or not all(p.isdigit() for p in parts):
        raise EnvError("cannot compare with the upstream")
    return int(parts[0]), int(parts[1])


def cmd_status(args):
    c = resolve(args, need_remote=False)
    ahead, behind = counts(c.vault, "HEAD", "@{u}")
    print("branch: %s -> %s" % (c.branch, c.upstream))
    print("ahead %d behind %d" % (ahead, behind))
    if ahead:
        rc, out = git(c.vault, "rev-list", "--abbrev-commit", "--abbrev=8", "@{u}..HEAD")
        if rc != 0:
            raise EnvError("cannot list ahead commits")
        for oid in out.split():
            print("  " + oid)
    rc, out = git(c.vault, "status", "--porcelain=v1", "--untracked-files=normal")
    if rc != 0:
        raise EnvError("git status failed (exit %d); the vault index or worktree may be damaged" % rc)
    mod = unt = 0
    for line in out.splitlines():
        if line.startswith("??"):
            unt += 1
        elif not line.startswith("!!") and line.strip():
            mod += 1
    print("dirty: %d modified, %d untracked" % (mod, unt))
    return 0


# ---- destination identity ----------------------------------------------------

NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*"
URL_FORMS = (
    re.compile(r"^https://github\.com/(%s)/(%s?)(?:\.git)?/?$" % (NAME, NAME)),
    re.compile(r"^ssh://git@github\.com/(%s)/(%s?)(?:\.git)?/?$" % (NAME, NAME)),
    re.compile(r"^git@github\.com:(%s)/(%s?)(?:\.git)?/?$" % (NAME, NAME)),
)


def parse_github(url):
    """(owner, name) lower-cased for an https or ssh/scp github.com URL, else None."""
    for rx in URL_FORMS:
        m = rx.match(url.strip())
        if m:
            return (m.group(1).lower(), m.group(2).lower())
    return None


def all_urls(vault, remote, push):
    args = ["remote", "get-url"] + (["--push"] if push else []) + ["--all", remote]
    rc, out = git(vault, *args)
    urls = [u for u in out.splitlines() if u.strip()]
    if rc != 0:
        raise Refused("cannot read the %s URLs of remote '%s'" % ("push" if push else "fetch", remote))
    return urls


def freeze_destination(c):
    rc, mirror = git(c.vault, "config", "--get", "remote.%s.mirror" % c.remote)
    if rc == 0 and mirror.strip().lower() not in ("false", "no", "off", "0", ""):
        raise Refused("remote '%s' is a mirror remote" % c.remote)
    fetch, push = all_urls(c.vault, c.remote, False), all_urls(c.vault, c.remote, True)
    if len(fetch) != 1 or len(push) != 1:
        raise Refused("remote '%s' must have exactly one fetch URL and one push URL (found %d and %d)"
                      % (c.remote, len(fetch), len(push)))
    sf, sp = parse_github(fetch[0]), parse_github(push[0])
    if sf is None or sp is None:
        raise Refused("the fetch and push URLs must be https or ssh github.com URLs, so privacy cannot be verified")
    if sf != sp:
        raise Refused("the fetch and push URLs name different repositories")
    c.fetch_url, c.push_url, c.slug = fetch[0].strip(), push[0].strip(), "%s/%s" % sf


def visibility_gate(c):
    rc, out = run(["gh", "api", "repos/%s" % c.slug, "--hostname", "github.com", "--jq", ".visibility"],
                  c.vault, NET_TIMEOUT, env=gh_env())
    if rc == 127:
        raise Refused("gh is not available, so repository visibility cannot be verified")
    vis = out.decode("utf-8", errors="replace").strip().strip('"').lower()
    if rc != 0 or not vis:
        raise Refused("gh failed (exit %d), so repository visibility cannot be verified" % rc)
    if vis != "private":
        raise Refused("%s is %s, not private" % (c.slug, vis))
    print("visibility: %s is private" % c.slug)


# ---- scope check over raw objects -------------------------------------------

def parse_raw(out):
    toks = out.split("\0")
    entries, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t == "":
            i += 1
        elif t.startswith(":"):
            f = t[1:].split(" ")
            if len(f) != 5 or i + 1 >= len(toks):
                raise Refused("scan could not complete: malformed diff-tree output")
            entries.append((f[0], f[1], f[2], f[3], f[4][:1], toks[i + 1]))
            i += 2
        else:
            raise Refused("scan could not complete: unexpected diff-tree output")
    return entries


def commit_meta(vault, oid):
    rc, out = git_raw(vault, "cat-file", "commit", oid)
    if rc != 0:
        raise Refused("scan could not complete: cannot read a commit (exit %d)" % rc)
    text = out.decode("latin-1")
    head, _, msg = text.partition("\n\n")
    parents = [l.split(" ", 1)[1].strip() for l in head.split("\n") if l.startswith("parent ")]
    return parents, text


def commit_entries(vault, oid, parents):
    base = ["diff-tree", "-r", "-z", "--raw", "--no-renames", "--no-abbrev", "--no-ext-diff", "--no-commit-id"]
    runs = [base + [p, oid] for p in parents] if parents else [base + ["--root", oid]]
    res = []
    for a in runs:
        rc, out = git_raw(vault, *a, timeout=120)
        if rc != 0:
            raise Refused("scan could not complete: diff-tree failed (exit %d)" % rc)
        res.extend(parse_raw(out.decode("utf-8", errors="replace")))
    return res


def blob_sizes(vault, shas):
    shas = sorted(set(shas))
    if not shas:
        return {}
    rc, out = git_raw(vault, "cat-file", "--batch-check", timeout=120, data=("\n".join(shas) + "\n").encode())
    lines = out.decode("utf-8", errors="replace").splitlines()
    if rc != 0 or len(lines) != len(shas):
        raise Refused("scan could not complete: object sizes could not be read")
    sizes = {}
    for sha, line in zip(shas, lines):
        m = re.match(r"^([0-9a-f]{40}) blob (\d+)$", line)
        if not m or m.group(1) != sha:
            raise Refused("scan could not complete: unexpected object size output")
        sizes[sha] = int(m.group(2))
    return sizes


def read_blobs(vault, shas):
    """{sha: bytes} via one cat-file --batch call (raw content: no textconv, filters or attributes)."""
    shas = [s for s in dict.fromkeys(shas)]
    if not shas:
        return {}
    rc, out = git_raw(vault, "cat-file", "--batch", timeout=180, data=("\n".join(shas) + "\n").encode())
    if rc != 0:
        raise Refused("scan could not complete: object contents could not be read")
    res, pos = {}, 0
    for sha in shas:
        nl = out.find(b"\n", pos)
        m = re.match(rb"^([0-9a-f]{40}) blob (\d+)$", out[pos:nl]) if nl >= 0 else None
        if not m or m.group(1).decode() != sha:
            raise Refused("scan could not complete: unexpected object content output")
        size = int(m.group(2))
        res[sha] = out[nl + 1:nl + 1 + size]
        if len(res[sha]) != size or out[nl + 1 + size:nl + 2 + size] != b"\n":
            raise Refused("scan could not complete: truncated object content")
        pos = nl + 2 + size
    return res


def parse_allow(items):
    allow = []
    for a in items:
        try:
            oid, rest = a.split(":", 1)
            path, rule = rest.rsplit(":", 1)
        except ValueError:
            raise EnvError("--allow-path takes <commit-oid>:<path>:<rule>")
        if not re.match(r"^[0-9a-f]{8,40}$", oid) or not path or not rule:
            raise EnvError("--allow-path takes <commit-oid>:<path>:<rule>")
        allow.append((oid, path, rule))
    return allow


def scan_range(c, base_oid, head_oid, allow):
    rc, out = git(c.vault, "rev-list", "--reverse", "%s..%s" % (base_oid, head_oid))
    commits = out.split()
    if rc != 0 or not all(HEX.match(x) for x in commits):
        raise Refused("scan could not complete: cannot list the unpushed commits")
    findings, seen, paths, added = [], set(), set(), 0

    def add(oid, path, line, rule):
        key = (oid, path, line, rule)
        if key not in seen:
            seen.add(key)
            findings.append(key)

    for oid in commits:
        parents, text = commit_meta(c.vault, oid)
        msg = text.partition("\n\n")[2]
        for n, l in enumerate(msg.split("\n"), 1):
            r = line_rule(l)
            if r:
                add(oid, "(commit message)", n, r)
        entries = commit_entries(c.vault, oid, parents)
        live = [e for e in entries if e[4] != "D" and e[3] != ZERO and e[1] != "160000"]
        sizes = blob_sizes(c.vault, [e[3] for e in live] +
                           [e[2] for e in live if e[2] != ZERO and e[0] != "160000"])
        for om, nm, osha, nsha, st, path in entries:
            paths.add(path)
        for om, nm, osha, nsha, st, path in live:
            if st == "A":
                added += 1
            if sensitive_path(path):
                add(oid, path, None, "sensitive-path")
            if line_rule(path):
                add(oid, path, None, "credential-in-path")
            if sizes[nsha] > MAX_BLOB:
                add(oid, path, None, "blob-too-large")
                continue
            want = [nsha]
            use_old = osha != ZERO and om != "160000" and sizes.get(osha, 0) <= MAX_BLOB
            if use_old:
                want.append(osha)
            data = read_blobs(c.vault, want)
            new = data[nsha].decode("latin-1").split("\n")
            if new and new[0].startswith("version https://git-lfs"):
                add(oid, path, None, "lfs-pointer")
                continue
            old = set(data[osha].decode("latin-1").split("\n")) if use_old else set()
            for n, l in enumerate(new, 1):
                if l not in old:
                    r = line_rule(l)
                    if r:
                        add(oid, path, n, r)
    print("scope: %d commits, %d paths, %d files added" % (len(commits), len(paths), added))
    used, blocked = set(), []
    for oid, path, line, rule in findings:
        hit = next((a for a in allow if oid.startswith(a[0]) and path == a[1] and rule == a[2]), None)
        if hit:
            used.add(hit)
            print("allowed (--allow-path): %s %s%s [%s]" % (oid[:8], safe(path), ":%d" % line if line else "", rule))
        else:
            blocked.append((oid, path, line, rule))
    for a in allow:
        if a not in used:
            print("allow-path unused: %s:%s:%s" % (a[0], safe(a[1]), a[2]))
    if blocked:
        print("REFUSED: scope check found %d suspected exposure(s); values are not printed:" % len(blocked))
        for oid, path, line, rule in blocked:
            print("  %s %s%s [%s]" % (oid[:8], safe(path), ":%d" % line if line else "", rule))
        print("Leave the commits local and report this refusal to the owner. For a reviewed false positive "
              "the owner may re-run with --allow-path <commit-oid>:<path>:<rule>.")
        raise SystemExit(1)
    return len(commits)


# ---- push ------------------------------------------------------------------

def cmd_push(args):
    allow = parse_allow(args.allow_path)
    c = resolve(args, need_remote=True)
    for a in args.allow_path:
        print("allow-path in effect: %s" % safe(a))
    freeze_destination(c)
    rc, head_oid = git(c.vault, "rev-parse", "--verify", "HEAD^{commit}")
    head_oid = head_oid.strip()
    if rc != 0 or not HEX.match(head_oid):
        raise EnvError("cannot resolve HEAD")
    visibility_gate(c)
    ref = "refs/vault-sync/%d/base" % os.getpid()
    try:
        rc, _ = git(c.vault, "fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                    c.fetch_url, "+refs/heads/%s:%s" % (c.rbranch, ref), timeout=NET_TIMEOUT)
        if rc != 0:
            raise Indeterminate("fetch failed (exit %d); nothing was pushed" % rc)
        rc, base_oid = git(c.vault, "rev-parse", "--verify", ref + "^{commit}")
        base_oid = base_oid.strip()
        if rc != 0 or not HEX.match(base_oid):
            raise Indeterminate("fetch failed to produce a remote tip; nothing was pushed")
        ahead, behind = counts(c.vault, head_oid, base_oid)
        print("branch: %s -> %s  ahead %d behind %d" % (c.branch, c.slug, ahead, behind))
        if behind:
            raise Refused("%s the remote. Nothing was pushed. This script never pulls, merges or rebases; "
                          "report it and reconcile by hand with the owner." % ("diverged from" if ahead else "behind"))
        if not ahead:
            print("nothing to push")
            return 0
        scan_range(c, base_oid, head_oid, allow)
        if args.dry_run:
            print("dry-run: would push %s..%s (%d commits) to %s" % (base_oid[:8], head_oid[:8], ahead, c.slug))
            return 0
        rc, _ = git(c.vault, "push", "--no-verify", "--no-follow-tags", "--recurse-submodules=no",
                    c.push_url, "%s:refs/heads/%s" % (head_oid, c.rbranch), timeout=NET_TIMEOUT)
        if rc != 0:
            raise Indeterminate("push failed (exit %d): push may have partially succeeded; "
                                "run vault-sync.py status after fetching" % rc)
        rc, out = git(c.vault, "ls-remote", c.fetch_url, "refs/heads/%s" % c.rbranch, timeout=NET_TIMEOUT)
        tip = out.split()[0] if out.split() else ""
        if rc != 0 or tip != head_oid:
            raise Indeterminate("the remote tip could not be confirmed after the push: push may have partially "
                                "succeeded; run vault-sync.py status after fetching")
        print("pushed: %s..%s" % (base_oid[:8], head_oid[:8]))
        return 0
    finally:
        git(c.vault, "update-ref", "-d", ref)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vault", help="vault path (default $CLAUDE_VAULT_DIR, else ~/Obsidian/no-it-all)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="offline ahead/behind and dirty counts")
    p = sub.add_parser("push", help="fast-forward push after the destination and scope checks")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--allow-path", action="append", default=[], metavar="OID:PATH:RULE",
                   help="exempt exactly one reviewed finding (commit oid prefix, literal path, rule name)")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    try:
        return cmd_status(args) if args.cmd == "status" else cmd_push(args)
    except Refused as e:
        print("REFUSED: %s" % e)
        return 1
    except EnvError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 2
    except Indeterminate as e:
        print("FAILED: %s" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
