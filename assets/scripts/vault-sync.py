#!/usr/bin/env python3
"""vault-sync.py - fail-closed, fast-forward push of the private notes vault.

  status        offline: ahead/behind of the last-fetched upstream (short OIDs only), dirty counts
  push [--dry-run]
                verify the destination, pin HEAD, copy the pinned history into an ISOLATED temporary
                bare repository, fetch the remote branch there, scan the unpushed range, and push from
                that repository to the canonical https://github.com/<owner>/<repo>.git

Exit codes: 0 ok (pushed, or nothing to push), 1 refused before anything was sent, 2 usage or
environment error, 3 transport failure or indeterminate result (a push may have partly succeeded).

The vault's own git configuration (remotes, insteadOf, credential helpers, ssh settings, hooks) is never
used for transport. The script never pulls, merges, rebases, resets or forces. The scope check is a
heuristic backstop, not a guarantee. Stdlib only. See docs/vault-sync.md.
"""
import argparse
import fnmatch
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

GIT_TIMEOUT = 60
NET_TIMEOUT = 120
MAX_BLOB = 50 * 1024 * 1024
ZERO = "0" * 40
HEX = re.compile(r"^[0-9a-f]{40}$")
NET_DROP = ("SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE")
GH_DROP = ("GH_HOST", "GH_REPO", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_CONFIG_DIR")


class Refused(Exception):
    """Preflight refusal: exit 1, nothing was sent."""


class EnvError(Exception):
    """Usage or environment problem: exit 2."""


class Indeterminate(Exception):
    """Transport failure or unverifiable outcome: exit 3."""


class Interrupted(Exception):
    """A termination signal arrived before anything was sent: exit 1."""


class State:
    sent = False
    signal = None
    cleaning = False


STATE = State()


# ---- output: one sanitizer, one printer --------------------------------------

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
    ("url-credentials", re.compile(r"://[^/\s:@]+:[^/\s@]{6,}@"), None),
    ("npm-token", re.compile(r"\bnpm_[A-Za-z0-9]{36}"), None),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}"), None),
    ("huggingface-token", re.compile(r"\bhf_[A-Za-z0-9]{30,}"), None),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}"), None),
    ("sendgrid-key", re.compile(r"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"), None),
    ("aws-secret-key", re.compile(r"(?i)aws_secret_access_key\s*[:=]"), None),
    ("basic-auth", re.compile(r"(?i)Authorization:\s*Basic\s+[A-Za-z0-9+/=]{8,}"), None),
]
PATH_GLOBS = [".env*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "*credentials*", "*.p12", "*.keychain*"]


def line_rule(text):
    for name, rx, check in LINE_RULES:
        for m in rx.finditer(text):
            if check is None or check(m):
                return name
    return None


_BIDI = set([0x200E, 0x200F, 0x2028, 0x2029] + list(range(0x202A, 0x202F)) + list(range(0x2066, 0x206A)))


def _esc(c):
    o = ord(c)
    if o < 0x20 or o == 0x7f or 0x80 <= o <= 0x9f:
        return "\\x%02x" % o
    if o in _BIDI:
        return "\\u%04x" % o
    return c


def safe(s):
    """The one sanitizer for every untrusted field: credential-shaped substrings become <redacted>;
    control characters, bidi controls and line/paragraph separators are escaped."""
    for _, rx, check in LINE_RULES:
        s = rx.sub(lambda m, c=check: "<redacted>" if c is None or c(m) else m.group(0), s)
    return "".join(_esc(c) for c in s)


def emit(msg, err=False):
    """The one printer. A closed, missing or broken stdout/stderr never changes the exit code."""
    try:
        f = sys.stderr if err else sys.stdout
        if f is None:
            return
        try:
            f.write(safe(msg) + "\n")
            f.flush()
        except (BrokenPipeError, OSError, ValueError, AttributeError):
            try:
                if err:
                    sys.stderr = open(os.devnull, "w")
                else:
                    sys.stdout = open(os.devnull, "w")
            except Exception:
                pass
    except Exception:
        pass


# ---- git plumbing --------------------------------------------------------------

def base_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    env["GIT_GRAFT_FILE"] = os.devnull
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


def _kill_group(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        p.communicate(timeout=5)
    except Exception:
        pass


def check_interrupt():
    if STATE.signal is not None and not STATE.sent and not STATE.cleaning:
        raise Interrupted()


def run(cmd, cwd, timeout=GIT_TIMEOUT, env=None, data=None):
    """(rc, stdout bytes). rc 124 on timeout, 127 when the program is missing. stderr is discarded:
    it can carry URLs or credentials and is never relayed. The child runs in its own process group; a
    termination signal that arrives before anything was sent kills that group and raises Interrupted."""
    check_interrupt()
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return 127, b""
    deadline, inp = time.monotonic() + timeout, data
    while True:
        try:
            out, _ = p.communicate(input=inp, timeout=0.2)
            return p.returncode, out
        except subprocess.TimeoutExpired:
            inp = None
            if STATE.signal is not None and not STATE.sent and not STATE.cleaning:
                _kill_group(p)
                raise Interrupted()
            if time.monotonic() > deadline:
                _kill_group(p)
                return 124, b""


def git_version_ok():
    rc, out = run(["git", "--version"], None, GIT_TIMEOUT, base_env())
    m = re.match(r"git version (\d+)\.(\d+)", out.decode("utf-8", errors="replace"))
    return rc == 0 and m is not None and (int(m.group(1)), int(m.group(2))) >= (2, 32)


class Repo:
    """A git working context: where to run, with which (sanitized) environment."""

    def __init__(self, cwd, env, gitdir=None):
        self.cwd, self.env = cwd, env
        self.prefix = BASE_GIT + (["--git-dir=%s" % gitdir] if gitdir else [])

    def raw(self, *args, timeout=GIT_TIMEOUT, data=None):
        return run(self.prefix + list(args), self.cwd, timeout, self.env, data)

    def text(self, *args, timeout=GIT_TIMEOUT):
        rc, out = self.raw(*args, timeout=timeout)
        return rc, out.decode("utf-8", errors="replace")


# ---- vault preflight (all local) ------------------------------------------------

class Ctx:
    pass


def resolve(args, need_remote):
    vault = args.vault or os.environ.get("CLAUDE_VAULT_DIR") or os.path.expanduser("~/Obsidian/no-it-all")
    vault = os.path.realpath(os.path.expanduser(vault))
    if not os.path.isdir(vault):
        raise EnvError("vault is not a directory")
    if not git_version_ok():
        raise EnvError("git 2.32 or newer is required (GIT_CONFIG_GLOBAL, --no-write-fetch-head)")
    c = Ctx()
    c.vault, c.repo = vault, Repo(vault, base_env())
    rc, top = c.repo.text("rev-parse", "--show-toplevel")
    if rc != 0 or os.path.realpath(top.strip()) != vault:
        raise EnvError("not the top of a git repository")
    rc, br = c.repo.text("symbolic-ref", "--short", "-q", "HEAD")
    if rc != 0 or not br.strip():
        raise EnvError("detached HEAD; check out the vault branch first")
    c.branch = br.strip()
    rc, up = c.repo.text("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    c.upstream = up.strip()
    if rc != 0 or not c.upstream:
        raise EnvError("branch %s has no upstream" % c.branch)
    if need_remote:
        rc, remote = c.repo.text("config", "--get", "branch.%s.remote" % c.branch)
        rc2, merge = c.repo.text("config", "--get", "branch.%s.merge" % c.branch)
        c.remote, merge = remote.strip(), merge.strip()
        if rc != 0 or rc2 != 0 or not c.remote or c.remote == "." or not merge.startswith("refs/heads/"):
            raise EnvError("branch %s has no upstream on a remote" % c.branch)
        c.rbranch = merge[len("refs/heads/"):]
    return c


def counts(repo, left, right):
    rc, out = repo.text("rev-list", "--left-right", "--count", "%s...%s" % (left, right))
    parts = out.split()
    if rc != 0 or len(parts) != 2 or not all(p.isdigit() for p in parts):
        raise EnvError("cannot compare with the upstream")
    return int(parts[0]), int(parts[1])


def cmd_status(args):
    c = resolve(args, need_remote=False)
    ahead, behind = counts(c.repo, "HEAD", "@{u}")
    emit("branch: %s -> %s" % (c.branch, c.upstream))
    emit("ahead %d behind %d" % (ahead, behind))
    if ahead:
        rc, out = c.repo.text("rev-list", "--abbrev-commit", "--abbrev=8", "@{u}..HEAD")
        if rc != 0:
            raise EnvError("cannot list ahead commits")
        for oid in out.split():
            emit("  " + oid)
    rc, out = c.repo.text("status", "--porcelain=v1", "--untracked-files=normal")
    if rc != 0:
        raise EnvError("git status failed (exit %d); the vault index or worktree may be damaged" % rc)
    mod = unt = 0
    for line in out.splitlines():
        if line.startswith("??"):
            unt += 1
        elif not line.startswith("!!") and line.strip():
            mod += 1
    emit("dirty: %d modified, %d untracked" % (mod, unt))
    return 0


# ---- destination identity ----------------------------------------------------------

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


def all_urls(c, push):
    args = ["remote", "get-url"] + (["--push"] if push else []) + ["--all", c.remote]
    rc, out = c.repo.text(*args)
    urls = [u for u in out.splitlines() if u.strip()]
    if rc != 0:
        raise Refused("cannot read the %s URLs of the upstream remote" % ("push" if push else "fetch"))
    return urls


def preflight(c):
    """Everything that can be decided locally, before any network call."""
    # The grafts and shallow files live in the common dir of a linked worktree.
    # `--git-path info/grafts` cannot locate them here: this script sets
    # GIT_GRAFT_FILE=/dev/null on purpose, and --git-path honours that remap.
    # `config` is never remapped and always lives in the common dir, so its
    # parent is the common dir. Both it and the per-worktree git dir are checked.
    rc, gd = c.repo.text("rev-parse", "--absolute-git-dir")
    rc2, cfg = c.repo.text("rev-parse", "--git-path", "config")
    if rc != 0 or rc2 != 0:
        raise EnvError("cannot locate the git directory")
    common = os.path.dirname(os.path.join(c.vault, cfg.strip()))
    for d in {gd.strip(), common}:
        for rel in ("info/grafts", "shallow"):
            if os.path.exists(os.path.join(d, rel)):
                raise Refused("the vault has %s; history rewrites that hide commits are not supported" % rel)
    rc, mirror = c.repo.text("config", "--get", "remote.%s.mirror" % c.remote)
    if rc == 0 and mirror.strip().lower() not in ("false", "no", "off", "0", ""):
        raise Refused("the upstream remote is a mirror remote")
    fetch, push = all_urls(c, False), all_urls(c, True)
    if len(fetch) != 1 or len(push) != 1:
        raise Refused("the upstream remote must have exactly one fetch URL and one push URL (found %d and %d)"
                      % (len(fetch), len(push)))
    sf, sp = parse_github(fetch[0]), parse_github(push[0])
    if sf is None or sp is None:
        raise Refused("the fetch and push URLs must be https or ssh github.com URLs, so privacy cannot be verified")
    if sf != sp:
        raise Refused("the fetch and push URLs name different repositories")
    c.owner, c.name = sf
    c.slug = "%s/%s" % sf
    c.canon = "https://github.com/%s/%s.git" % sf
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$", c.rbranch) or ".." in c.rbranch or \
            c.repo.raw("check-ref-format", "refs/heads/" + c.rbranch)[0] != 0:
        raise Refused("the upstream branch name is not acceptable")
    rc, head = c.repo.text("rev-parse", "--verify", "HEAD^{commit}")
    c.head_oid = head.strip()
    if rc != 0 or not HEX.match(c.head_oid):
        raise EnvError("cannot resolve HEAD")


def visibility_gate(c):
    c.gh = shutil.which("gh", path=os.environ.get("PATH", ""))
    if not c.gh:
        raise Refused("gh is not available, so repository visibility cannot be verified")
    rc, out = run(["gh", "api", "repos/%s" % c.slug, "--hostname", "github.com", "--jq", ".visibility"],
                  c.vault, NET_TIMEOUT, env=gh_env())
    vis = out.decode("utf-8", errors="replace").strip().strip('"').lower()
    if rc != 0 or not vis:
        raise Refused("gh failed (exit %d), so repository visibility cannot be verified" % rc)
    if vis != "private":
        raise Refused("%s is %s, not private" % (c.slug, vis))
    emit("visibility: %s is private" % c.slug)


# ---- isolated transport repository ---------------------------------------------------

def cfgval(v):
    return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')


def write_transport_config(path, gh):
    helper = "!%s auth git-credential" % shlex.quote(gh)
    lines = [
        "[core]", "\thooksPath = /dev/null",
        "[protocol]", "\tallow = never",
        '[protocol "https"]', "\tallow = always",
        '[protocol "file"]', "\tallow = always",
        "[credential]", "\thelper =",
        '[credential "https://github.com"]', "\thelper = %s" % cfgval(helper),
        "[push]", "\trecurseSubmodules = no",
        "[fetch]", "\trecurseSubmodules = no", "\tprune = false",
        "[submodule]", "\trecurse = false",
        "[transfer]", "\tfsckObjects = true",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def transport_env(cfg):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("GIT_") and k not in GH_DROP and k not in NET_DROP and not k.lower().endswith("_proxy")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": cfg, "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": os.devnull})
    return env


# ---- scope check over raw objects (inside the isolated repository) -----------------------

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


def commit_meta(T, oid):
    rc, out = T.raw("cat-file", "commit", oid)
    if rc != 0:
        raise Refused("scan could not complete: cannot read a commit (exit %d)" % rc)
    text = out.decode("latin-1")
    head = text.partition("\n\n")[0]
    parents = [l.split(" ", 1)[1].strip() for l in head.split("\n") if l.startswith("parent ")]
    return parents, text


def commit_entries(T, oid, parents):
    base = ["diff-tree", "-r", "-z", "--raw", "--no-renames", "--no-abbrev", "--no-ext-diff", "--no-commit-id"]
    runs = [base + [p, oid] for p in parents] if parents else [base + ["--root", oid]]
    res = []
    for a in runs:
        rc, out = T.raw(*a, timeout=120)
        if rc != 0:
            raise Refused("scan could not complete: diff-tree failed (exit %d)" % rc)
        res.extend(parse_raw(out.decode("utf-8", errors="replace")))
    return res


def blob_sizes(T, shas):
    shas = sorted(set(shas))
    if not shas:
        return {}
    rc, out = T.raw("cat-file", "--batch-check", timeout=120, data=("\n".join(shas) + "\n").encode())
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


def read_blobs(T, shas):
    shas = list(dict.fromkeys(shas))
    if not shas:
        return {}
    rc, out = T.raw("cat-file", "--batch", timeout=180, data=("\n".join(shas) + "\n").encode())
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


def scan_range(T, base_oid, head_oid):
    """Scan base..head inside the isolated repository; return (commits, findings)."""
    rc, out = T.text("rev-list", "--reverse", "%s..%s" % (base_oid, head_oid))
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
        parents, text = commit_meta(T, oid)
        # the whole raw commit object: author, committer, mergetag, encoding, gpgsig and message
        for n, l in enumerate(text.split("\n"), 1):
            r = line_rule(l)
            if r:
                add(oid, "(commit object)", n, r)
        entries = commit_entries(T, oid, parents)
        for e in entries:
            paths.add(e[5])
        live = [e for e in entries if e[4] != "D" and e[3] != ZERO]
        blobs = [e for e in live if e[1] != "160000"]
        sizes = blob_sizes(T, [e[3] for e in blobs] + [e[2] for e in blobs if e[2] != ZERO and e[0] != "160000"])
        for om, nm, osha, nsha, st, path in live:          # gitlinks included
            if st == "A":
                added += 1
            if any(fnmatch.fnmatchcase(path.rsplit("/", 1)[-1].lower(), g) for g in PATH_GLOBS):
                add(oid, path, None, "sensitive-path")
            if line_rule(path):
                add(oid, path, None, "credential-in-path")
        for om, nm, osha, nsha, st, path in blobs:
            if sizes[nsha] > MAX_BLOB:
                add(oid, path, None, "blob-too-large")      # refused outright, never partially scanned
                continue
            want = [nsha]
            use_old = osha != ZERO and om != "160000" and sizes.get(osha, 0) <= MAX_BLOB
            if use_old:
                want.append(osha)
            data = read_blobs(T, want)
            new_b, old_b = data[nsha], data[osha] if use_old else None
            if new_b.startswith(b"version https://git-lfs"):
                add(oid, path, None, "lfs-pointer")
            codecs = ["latin-1"] + (["utf-16-le", "utf-16-be"] if b"\0" in new_b else [])
            for cd in codecs:
                new = new_b.decode(cd, errors="replace").split("\n")
                old = set(old_b.decode(cd, errors="replace").split("\n")) if old_b is not None else set()
                for n, l in enumerate(new, 1):
                    if l not in old:
                        r = line_rule(l)
                        if r:
                            add(oid, path, n, r)
    emit("scope: %d commits, %d paths, %d files added" % (len(commits), len(paths), added))
    return commits, findings


# ---- push ----------------------------------------------------------------------------------

def cmd_push(args):
    c = resolve(args, need_remote=True)
    preflight(c)
    visibility_gate(c)                       # before ANY git network call
    tdir = tempfile.mkdtemp(prefix="vault-sync-")
    vref = "refs/vault-sync/%d/head" % os.getpid()
    made_ref = False
    try:
        cfg = os.path.join(tdir, "vs-config")
        write_transport_config(cfg, c.gh)
        tenv = transport_env(cfg)
        tgit = os.path.join(tdir, "repo.git")
        rc, _ = run(BASE_GIT + ["init", "--bare", "-q", tgit], tdir, GIT_TIMEOUT, tenv)
        if rc != 0:
            raise EnvError("cannot create the isolated transport repository")
        T = Repo(tdir, tenv, gitdir=tgit)
        # objects: the pinned head, copied from the vault through a private ref
        rc, _ = c.repo.text("update-ref", vref, c.head_oid)
        if rc != 0:
            raise EnvError("cannot pin HEAD in a private ref")
        made_ref = True
        rc, _ = T.text("fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                       c.vault, "%s:refs/vs/head" % vref, timeout=NET_TIMEOUT)
        if rc != 0:
            raise EnvError("could not copy the pinned history into the transport repository")
        # the remote branch, over the controlled https transport
        rc, _ = T.text("fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                       c.canon, "refs/heads/%s:refs/vs/base" % c.rbranch, timeout=NET_TIMEOUT)
        if rc != 0:
            raise Indeterminate("fetch failed (exit %d); nothing was pushed" % rc)
        rc, head_oid = T.text("rev-parse", "--verify", "refs/vs/head^{commit}")
        rc2, base_oid = T.text("rev-parse", "--verify", "refs/vs/base^{commit}")
        head_oid, base_oid = head_oid.strip(), base_oid.strip()
        if rc != 0 or rc2 != 0 or head_oid != c.head_oid or not HEX.match(base_oid):
            raise Indeterminate("fetch failed to produce the expected tips; nothing was pushed")
        ahead, behind = counts(T, "refs/vs/head", "refs/vs/base")
        emit("branch: %s -> %s  ahead %d behind %d" % (c.branch, c.slug, ahead, behind))
        if behind:
            raise Refused("%s the remote. Nothing was sent. This script never pulls, merges or rebases; "
                          "report it and reconcile by hand with the owner." % ("diverged from" if ahead else "behind"))
        if not ahead:
            emit("nothing to push")
            return 0
        commits, findings = scan_range(T, base_oid, head_oid)
        if findings:
            emit("REFUSED: scope check found %d suspected exposure(s); values are not printed:" % len(findings))
            for oid, path, line, rule in findings:
                emit("  %s %s%s [%s]" % (oid[:8], path, ":%d" % line if line else "", rule))
            emit("Nothing was sent. Leave the commits as they are and report this refusal; the owner reviews the "
                 "listed commits and, if they are false positives, pushes by hand.")
            return 1
        if args.dry_run:
            emit("dry-run: would push %s..%s (%d commits) to %s" % (base_oid[:8], head_oid[:8], ahead, c.slug))
            return 0
        check_interrupt()
        STATE.sent = True
        rc, _ = T.text("push", "--no-verify", "--no-follow-tags", "--recurse-submodules=no",
                       c.canon, "refs/vs/head:refs/heads/%s" % c.rbranch, timeout=NET_TIMEOUT)
        if rc != 0:
            raise Indeterminate("push failed (exit %d): push may have partially succeeded; "
                                "run vault-sync.py status after fetching" % rc)
        rc, out = T.text("ls-remote", c.canon, "refs/heads/%s" % c.rbranch, timeout=NET_TIMEOUT)
        tip = out.split()[0] if out.split() else ""
        if rc != 0 or tip != head_oid:
            raise Indeterminate("the remote tip could not be confirmed after the push: push may have partially "
                                "succeeded; run vault-sync.py status after fetching")
        emit("pushed: %s..%s" % (base_oid[:8], head_oid[:8]))
        return 0
    finally:
        STATE.cleaning = True
        if made_ref:
            c.repo.text("update-ref", "-d", vref)
        shutil.rmtree(tdir, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vault", help="vault path (default $CLAUDE_VAULT_DIR, else ~/Obsidian/no-it-all)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="offline ahead/behind and dirty counts")
    p = sub.add_parser("push", help="fast-forward push after the destination and scope checks")
    p.add_argument("--dry-run", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if args.cmd == "push":
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda signum, frame: setattr(STATE, "signal", signum))
    try:
        return cmd_status(args) if args.cmd == "status" else cmd_push(args)
    except Interrupted:
        emit("REFUSED: interrupted, nothing sent")
        return 1
    except Refused as e:
        emit("REFUSED: %s" % e)
        return 1
    except EnvError as e:
        emit("ERROR: %s" % e, err=True)
        return 2
    except Indeterminate as e:
        emit("FAILED: %s" % e)
        return 3
    except Exception as e:  # any unexpected failure: 3 once something may have been sent, else 2
        if STATE.sent:
            emit("FAILED: unexpected %s: push may have partially succeeded; run vault-sync.py status after fetching"
                 % type(e).__name__)
            return 3
        emit("ERROR: unexpected %s; nothing was pushed" % type(e).__name__, err=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
