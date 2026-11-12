#!/usr/bin/env python3
"""Read-only inventory and classifier for stale git worktrees (#432).

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/worktree-audit.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/worktree-audit.py [--root DIR]... [--repo PATH]...
      [--json] [--stale-days N] [--liveness auto|lsof|none] [--no-gh]
      [--seed-dir DIR | --no-seeds] [--sizes]

THE PROBLEM: a machine that runs many agent sessions accumulates linked git
worktrees (`~/Projects/<repo>-<slug>-<date>`) and dated scratch folders, and
nothing reports which are safe to remove. A manual cleanup of 69 worktrees was
made safe only by a forensic pass, and that pass hit two gaps a naive check
repeats:

  * `git ls-files --others --exclude-standard` does NOT list ignored files, so
    gitignored evidence logs (`*.log`) looked like nothing to preserve. This
    script asks for ignored files explicitly (`--others --ignored`).
  * A "rebuildable output" filter that matched a folder NAME anywhere in the
    path skipped `coverage/` and `dist/` folders that lived inside evidence
    directories. REBUILDABLE below is ROOTED: it matches only at the named
    locations, never by bare folder name.

THIS SCRIPT NEVER WRITES. It reports; removal is somebody else's decision. Every
git call runs with GIT_OPTIONAL_LOCKS=0 (and `status` with --no-optional-locks)
so even `.git/index` is not refreshed. Every git call also carries
`-c core.fsmonitor=false -c core.untrackedCache=false`: GIT_OPTIONAL_LOCKS does not
stop `git status` from STARTING the fsmonitor daemon (writes `.git/fsmonitor--daemon*`,
leaves a process running) nor from running a repo-configured fsmonitor hook command.
The command set is restricted to readers: no worktree add/remove/prune/lock/unlock, fetch, gc, checkout, reset,
stash or branch -d.

CLASSES per linked worktree (the main checkout is never classified):
  KEEP  in use or liveness unknown / locked by a live or unparseable pid / open
        PR, or PR state unknown for ANY branch worktree (even if its head is in the
        base: the issue says unknown -> KEEP) / named in a session seed, or the seed
        check unavailable (seed dir absent or unreadable; `--no-seeds` is the
        explicit opt-out) / created <24h ago and head not preserved.
        A repo with an `upstream` remote (a fork) has PR state unknown: PRs target
        the upstream repo, which `gh pr list -R <origin>` cannot see.
  A     clean (no tracked edits, no untracked files, no ignored file outside the
        rooted rebuildable allowlist) and HEAD preserved: in the default branch,
        in some remote branch, or equal to a merged PR's head.
  B     everything else, with each thing that must be preserved first named.
An unknown fact is never "nothing to check": it becomes KEEP (or a named `needs`
entry) so the reason is visible. `content_class` (A/B) is computed even for KEEP
so the report says what the worktree would be if idle. A worktree whose directory
is gone but whose ref remains is `PRUNABLE-REF` (content class n/a).

Dated directories directly under a root with no `.git` entry are `leftovers`
(verdict REVIEW): no git facts exist, so they are listed with an mtime age.

EXIT: 0 when everything requested was read; 2 when an explicitly requested
root/repo/seed dir/`--liveness lsof`, any unreadable directory met while scanning,
or any discovered repo's worktree list, could not be read (what was read is still
printed, with the unverified items listed).

Python 3 stdlib only.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time

DEFAULT_ROOTS = ["~/Projects", "~/StudioProjects", "~/VSCodeProjects"]
MAX_DEPTH = 3
DATE_RE = re.compile(r"-(\d{8}|\d{4}-\d{2}-\d{2})")

# Ignored files that are safe to lose because a build recreates them. ROOTED: a
# pattern matches only at the location it names. A `coverage/`, `dist/`, `build/`
# or `node_modules/` anywhere else (e.g. `.evidence/run/dist/a.js`) is evidence,
# NOT rebuildable -- matching the bare folder name anywhere is exactly the gap
# that nearly lost evidence in the manual cleanup this script replaces (#432).
REBUILDABLE = [
    re.compile(r"^node_modules/"),
    re.compile(r"^packages/[^/]+/node_modules/"),
    re.compile(r"^packages/[^/]+/dist/"),
    re.compile(r"^packages/[^/]+/build/"),
    re.compile(r"^packages/desktop/src-tauri/target/"),
    re.compile(r"^packages/desktop/src-tauri/gen/"),
    re.compile(r"^\.repo-memory/"),
    re.compile(r"^packages/app/src/components/xterm-bundle\.generated\.ts$"),
    re.compile(r"(^|/)\.DS_Store$"),
    re.compile(r"(^|/)__pycache__/"),
    re.compile(r"(^|/)[^/]*\.pyc$"),
]

GIT_BASE = ["git", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
KEEP_FRESH_DAYS = 1.0


class GitError(Exception):
    pass


def git(args, cwd, ok=(0,)):
    """Run a read-only git command; returns stdout bytes. Raises GitError."""
    try:
        p = subprocess.run(GIT_BASE + args, cwd=cwd, env=GIT_ENV, capture_output=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GitError("git %s: %s" % (" ".join(args[:2]), e))
    if p.returncode not in ok:
        raise GitError("git %s exited %d: %s" % (" ".join(args[:2]), p.returncode,
                                                  p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout, p.returncode


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


# --------------------------------------------------------------- discovery

def find_repos(root, unverified):
    """Main checkouts (.git is a DIRECTORY) under root, depth <= MAX_DEPTH.
    An unreadable directory is recorded in `unverified`, never skipped silently."""
    found = []

    def walk(d, depth):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError as e:
            unverified.append({"path": d, "reason": "directory unreadable while scanning for repos: %s" % e})
            return
        for e in entries:
            if depth + 1 > MAX_DEPTH or e.name == "node_modules" or e.name == ".git":
                continue
            try:
                if not e.is_dir(follow_symlinks=False):
                    continue
            except OSError as ex:
                unverified.append({"path": e.path, "reason": "unreadable: %s" % ex})
                continue
            gp = os.path.join(e.path, ".git")
            if os.path.isdir(gp) and not os.path.islink(gp):
                found.append(e.path)
            elif not os.path.lexists(gp):
                walk(e.path, depth + 1)

    walk(root, 0)
    return found


def main_checkout(path):
    """The main checkout of the repo containing `path`: the FIRST entry of the
    worktree list, which git always reports first. Used as the dedupe key too."""
    raw, _ = git(["worktree", "list", "--porcelain", "-z"], path)
    ents = parse_porcelain(raw)
    if not ents:
        raise GitError("git worktree list returned nothing")
    return os.path.realpath(ents[0]["path"]), ents


def parse_porcelain(raw):
    """Parse `git worktree list --porcelain -z`: NUL-terminated fields, an empty
    field ends a record. -z keeps a path containing a newline in one piece."""
    entries, cur = [], None
    for line in raw.decode("utf-8", "surrogateescape").split("\0"):
        if not line:
            if cur:
                entries.append(cur)
            cur = None
            continue
        key, _, val = line.partition(" ")
        if key == "worktree":
            if cur:
                entries.append(cur)
            cur = {"path": val, "head": None, "branch": None, "detached": False,
                   "locked": False, "lock_reason": "", "prunable": False, "prunable_reason": ""}
        elif cur is None:
            continue
        elif key == "HEAD":
            cur["head"] = val
        elif key == "branch":
            cur["branch"] = val[len("refs/heads/"):] if val.startswith("refs/heads/") else val
        elif key == "detached":
            cur["detached"] = True
        elif key == "locked":
            cur["locked"], cur["lock_reason"] = True, val
        elif key == "prunable":
            cur["prunable"], cur["prunable_reason"] = True, val
    if cur:
        entries.append(cur)
    return entries


# ------------------------------------------------------------------- facts

def default_base(repo):
    out, rc = git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], repo, ok=(0, 1))
    if rc == 0 and out.strip():
        return out.decode().strip()
    for ref in ("refs/remotes/origin/main", "refs/remotes/origin/master"):
        _, rc = git(["rev-parse", "--verify", "-q", ref], repo, ok=(0, 1))
        if rc == 0:
            return ref
    return None


def slug_from_url(url):
    """owner/repo for a github.com remote URL (https, ssh, scp-style), else None."""
    m = re.match(r"^(?:https?://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
                 r"([^/]+/[^/]+?)(?:\.git)?/?$", url.strip())
    return m.group(1) if m else None


def gh_slug(repo):
    # Raw config, not `remote get-url`: the latter applies url.*.insteadOf, and the
    # slug must name the GitHub repo even when the transport is rewritten.
    out, _ = git(["config", "--get", "remote.origin.url"], repo, ok=(0, 1))
    return slug_from_url(out.decode())


def has_upstream_remote(repo):
    # A fork's PRs target the upstream repo; `gh pr list -R <origin>` would answer
    # "none" (known!) for them. Treat the PR state of such a repo as unknown.
    out, _ = git(["remote"], repo)
    return "upstream" in out.decode().split()


def pr_facts(slug, branch, head, use_gh, fork=False):
    """-> dict(known, open, merged_head, note)."""
    if branch is None:
        return {"known": True, "open": False, "merged_head": False, "state": "n/a"}
    unknown = {"known": False, "open": False, "merged_head": False, "state": "unknown"}
    if not use_gh or fork or not slug or not shutil.which("gh"):
        return unknown
    try:
        p = subprocess.run(["gh", "pr", "list", "-R", slug, "--head", branch, "--state", "all",
                            "--json", "number,state,headRefOid", "--limit", "20"],
                           capture_output=True, timeout=60, env=dict(os.environ, GH_PROMPT_DISABLED="1"))
        if p.returncode != 0:
            return unknown
        prs = json.loads(p.stdout.decode() or "null")
        if not isinstance(prs, list):
            return unknown
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return unknown
    is_open = any(x.get("state") == "OPEN" for x in prs)
    merged = any(x.get("state") == "MERGED" and x.get("headRefOid") == head for x in prs)
    return {"known": True, "open": is_open, "merged_head": merged,
            "state": "open" if is_open else ("merged" if merged else ("none" if not prs else "other"))}


def rebuildable(rel):
    return any(r.search(rel) for r in REBUILDABLE)


def nul_list(raw):
    return [x.decode("utf-8", "surrogateescape") for x in raw.split(b"\0") if x]


def lsof_cwds(mode):
    """-> set of realpath cwds, or None when liveness cannot be determined."""
    if mode == "none" or not shutil.which("lsof"):
        return None
    try:
        p = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0 and not out.strip():
        return None
    return {os.path.realpath(l[1:]) for l in out.splitlines() if l.startswith("n") and len(l) > 1}


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (OSError, OverflowError, ValueError):
        # PermissionError means it exists; an out-of-range pid (OverflowError) or
        # anything else we cannot interpret is NOT proof of death. Alive => KEEP.
        return True
    return True


def parse_pid(reason):
    m = re.search(r"\(pid (\d+)\)", reason) or re.search(r"pid[:= ]\s*(\d+)", reason, re.I)
    pid = int(m.group(1)) if m else None
    # pid 0 would make os.kill(0, 0) signal our own process GROUP (always "alive")
    # and says nothing about the lock holder; treat it as unparseable (also KEEP).
    return pid if pid and pid > 0 else None


def age_days(ts, now):
    return None if ts is None else max(0.0, (now - ts) / 86400.0)


def ignored_nonrebuildable(wt):
    """Ignored files that are not rooted-rebuildable. `--directory` keeps node_modules
    and target/ from being listed file by file; a collapsed dir that the rooted
    patterns do not cover is expanded again so nothing hides behind the collapse."""
    base = ["ls-files", "-z", "--others", "--ignored", "--exclude-standard"]
    out, _ = git(base + ["--directory"], wt)
    res = []
    for p in nul_list(out):
        if rebuildable(p):
            continue
        if p.endswith("/"):
            sub, _ = git(base + ["--", ":(literal)" + p], wt)
            res.extend(x for x in nul_list(sub) if not rebuildable(x))
        else:
            res.append(p)
    # git can list a directory AND files inside it; count each path once.
    res = list(dict.fromkeys(res))
    return res


def collect(repo, ent, ctx):
    """Gather facts for one linked worktree. Raises GitError on unreadable state."""
    now = ctx["now"]
    wt = ent["path"]
    f = {"path": wt, "branch": ent["branch"], "head": ent["head"], "detached": ent["detached"],
         "locked": ent["locked"], "lock_reason": ent["lock_reason"], "lock_pid": None}
    if ent["locked"]:
        f["lock_pid"] = parse_pid(ent["lock_reason"])
    if not os.path.isdir(wt):
        f["missing"] = True
        # A vanished PARENT suggests an unmounted volume, not a deleted worktree.
        f["parent_missing"] = not os.path.isdir(os.path.dirname(wt))
        return f
    f["missing"] = False
    head = ent["head"]
    out, _ = git(["log", "-1", "--format=%ct", head], wt)
    f["head_age_days"] = age_days(int(out.strip() or 0), now)
    out, _ = git(["rev-parse", "--absolute-git-dir"], wt)
    # Creation proxy: mtime of <admin>/gitdir, written when the worktree is added.
    # `git worktree repair/move` rewrites it, which only makes a worktree look younger
    # (safer: KEEP sooner).
    gd = os.path.join(out.decode().strip(), "gitdir")
    try:
        f["creation_age_days"] = age_days(os.stat(gd).st_mtime, now)
    except OSError:
        f["creation_age_days"] = None
    out, _ = git(["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=no", "-z"], wt)
    # status -z renames add a second NUL field; that overcounts by at most the
    # number of renames. Only zero vs non-zero and the printed count depend on it.
    f["tracked_dirty"] = sum(1 for x in out.split(b"\0") if x and x[:2] != b"??")
    out, _ = git(["ls-files", "-z", "--others", "--exclude-standard"], wt)
    f["untracked"] = len(nul_list(out))
    ign = ignored_nonrebuildable(wt)
    f["ignored_nonrebuildable"] = len(ign)
    f["ignored_nonrebuildable_sample"] = ign[:5]
    base = ctx["bases"].get(repo)
    if base is None:
        f["in_base"] = None
    else:
        _, rc = git(["merge-base", "--is-ancestor", head, base], wt, ok=(0, 1))
        f["in_base"] = (rc == 0)
    out, _ = git(["for-each-ref", "--contains", head, "refs/remotes"], wt)
    f["in_remote_branch"] = bool(out.strip())
    pr = pr_facts(ctx["slugs"].get(repo), ent["branch"], head, ctx["use_gh"], ctx["forks"].get(repo, False))
    f["pr"] = pr
    f["merged_pr_head"] = pr["merged_head"]
    cw = ctx["cwds"]
    if cw is None:
        f["in_use"] = None
    else:
        rp = os.path.realpath(wt)
        f["in_use"] = any(c == rp or c.startswith(rp + os.sep) for c in cw)
    f["seeds"] = seed_mentions(ctx["seeds"], wt, ent["branch"])
    f["seed_unavailable"] = ctx["seed_unavailable"]
    if ctx["sizes"]:
        try:
            p = subprocess.run(["du", "-sk", wt], capture_output=True, timeout=300)
            f["du_kb"] = int(p.stdout.split()[0]) if p.returncode == 0 and p.stdout.split() else None
        except (OSError, ValueError, subprocess.TimeoutExpired):
            f["du_kb"] = None
    return f


def seed_mentions(seeds, wt, branch):
    hits = []
    forms = {wt, tilde(wt), os.path.realpath(wt)}

    def word(x):  # whole-token match: not glued to other name characters
        return re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(x) + r"(?![A-Za-z0-9_.-])")

    words = [word(os.path.basename(wt.rstrip("/")))] + ([word(branch)] if branch else [])
    for name, text in seeds:
        if any(x in text for x in forms) or any(w.search(text) for w in words):
            hits.append(name)
    return hits


def classify(f, stale_days):
    if f.get("missing"):
        if f.get("parent_missing"):
            f.update(verdict="KEEP", content_class="n/a", needs=[],
                     reasons=["parent directory missing (unmounted volume?)"])
        else:
            f.update(verdict="PRUNABLE-REF", content_class="n/a", needs=[],
                     reasons=["directory missing; ref remains (git worktree prune)"])
        return
    pr = f["pr"]
    preserved = bool(f["in_base"] or f["in_remote_branch"] or f["merged_pr_head"])
    needs = []
    clean = f["tracked_dirty"] == 0 and f["untracked"] == 0 and f["ignored_nonrebuildable"] == 0
    if not preserved:
        unk = []
        if f["in_base"] is None:
            unk.append("default branch unknown")
        if not pr["known"]:
            unk.append("PR state unknown")
        needs.append("commits (head not on base, remote or merged PR)" + (" [%s]" % ", ".join(unk) if unk else ""))
    if f["tracked_dirty"]:
        needs.append("tracked edits (%d)" % f["tracked_dirty"])
    if f["untracked"]:
        needs.append("untracked files (%d)" % f["untracked"])
    if f["ignored_nonrebuildable"]:
        needs.append("ignored non-rebuildable files (%d)" % f["ignored_nonrebuildable"])
    content = "A" if (clean and preserved) else "B"
    reasons = []
    ca, ha = f["creation_age_days"], f["head_age_days"]
    f["stale"] = bool(ca is not None and ha is not None and ca > stale_days and ha > stale_days)
    if f["in_use"] is True:
        reasons.append("in use (a process has its cwd here)")
    if f["in_use"] is None:
        reasons.append("liveness unknown")
    if f["locked"] and (f["lock_pid"] is None or pid_alive(f["lock_pid"])):
        reasons.append("locked by %s" % ("unparseable pid" if f["lock_pid"] is None else "live pid %d" % f["lock_pid"]))
    if pr["open"]:
        reasons.append("open PR")
    elif f["branch"] and not pr["known"]:
        # Even when the head is in the base: the issue says unknown -> KEEP.
        reasons.append("PR state unknown")
    if f["seed_unavailable"]:
        reasons.append("seed check unavailable (%s)" % f["seed_unavailable"])
    for s in f["seeds"]:
        reasons.append("named in seed %s" % s)
    if (ca is None or ca < KEEP_FRESH_DAYS) and not preserved:
        reasons.append("created <24h ago and head not preserved" if ca is not None else "creation age unknown and head not preserved")
    f["content_class"] = content
    f["needs"] = needs
    if reasons:
        f["verdict"], f["reasons"] = "KEEP", reasons
    else:
        f["verdict"] = content
        f["reasons"] = ["clean and head preserved"] if content == "A" else ["needs preserving first"]


# ------------------------------------------------------------------ output

def orphan_note(gitfile):
    """A `.git` FILE whose gitdir target is gone: a stranded worktree, not a repo."""
    try:
        if os.path.isfile(gitfile):
            with open(gitfile, encoding="utf-8", errors="replace") as fh:
                m = re.match(r"gitdir:\s*(.+)", fh.read().strip())
            if m and not os.path.exists(m.group(1).strip()):
                return ".git file points at missing repo"
    except OSError:
        pass
    return None


def free_gib(path):
    try:
        return "%.1f GiB" % (shutil.disk_usage(path).free / 2**30)
    except OSError:
        return "unreadable"


def human(rep):
    L = []
    for r in rep["repos"]:
        L.append("== %s" % tilde(r["path"]))
        for w in r["worktrees"]:
            tag = w["branch"] or "(detached %s)" % (w["head"] or "?")[:8]
            size = ""
            if w.get("du_kb") is not None:
                size = "  du %d KiB (may overcount shared data)" % w["du_kb"]
            L.append("  %-12s class=%-3s %s  [%s]%s%s" % (w["verdict"], w["content_class"], tilde(w["path"]), tag,
                                                          "  STALE" if w.get("stale") else "", size))
            if w["reasons"]:
                L.append("      why:   " + "; ".join(w["reasons"]))
            if w["needs"]:
                L.append("      needs: " + "; ".join(w["needs"]))
            if w.get("ignored_nonrebuildable_sample"):
                L.append("      ignored sample: " + ", ".join(w["ignored_nonrebuildable_sample"]))
    if rep["leftovers"]:
        L.append("== leftovers (dated dirs with no .git; verdict REVIEW)")
        for x in rep["leftovers"]:
            L.append("  REVIEW       %s  (mtime age %.1f days)%s" % (tilde(x["path"]), x["age_days"],
                                                              "  " + x["note"] if x.get("note") else ""))
    if rep["seed_unavailable"]:
        L.append("note: seed check unavailable (%s); every worktree is KEEP" % rep["seed_unavailable"])
    if rep["unverified"]:
        L.append("== UNVERIFIED (could not be read; exit 2)")
        for u in rep["unverified"]:
            L.append("  %s: %s" % (tilde(u["path"]), u["reason"]))
    s = rep["summary"]
    counts = " ".join("%s=%d" % (k, v) for k, v in sorted(s["verdicts"].items())) or "none"
    L.append("Summary: %d repos, %d worktrees; %s; leftovers=%d; unverified=%d"
             % (s["repos"], s["worktrees"], counts, s["leftovers"], s["unverified"]))
    for p, fr in s["free_on_filesystem"].items():
        L.append("  free on filesystem of %s: %s" % (tilde(p), fr))
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Read-only worktree inventory and classifier.")
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--stale-days", type=float, default=14)
    ap.add_argument("--liveness", choices=["auto", "lsof", "none"], default="auto")
    ap.add_argument("--no-gh", action="store_true")
    ap.add_argument("--seed-dir", default=None)
    ap.add_argument("--no-seeds", action="store_true",
                    help="skip the session-seed check entirely (no KEEP reason, no unverified entry)")
    ap.add_argument("--sizes", action="store_true")
    a = ap.parse_args(argv)

    unverified = []
    roots, repo_paths = [], []
    explicit = bool(a.root or a.repo)
    for r in (a.root if explicit else DEFAULT_ROOTS):
        p = os.path.abspath(os.path.expanduser(r))
        if os.path.isdir(p):
            roots.append(p)
        elif r in a.root:
            unverified.append({"path": p, "reason": "root does not exist or is not a directory"})
    for r in a.repo:
        p = os.path.abspath(os.path.expanduser(r))
        if os.path.isdir(p):
            repo_paths.append(p)
        else:
            unverified.append({"path": p, "reason": "repo does not exist or is not a directory"})
    for r in roots:
        repo_paths.extend(find_repos(r, unverified))

    repos, seen = [], set()
    for p in repo_paths:
        try:
            main_path, ents = main_checkout(p)
        except GitError as e:
            unverified.append({"path": p, "reason": "not readable as a git repo: %s" % e})
            continue
        if main_path in seen:
            continue
        seen.add(main_path)
        repos.append((main_path, ents))

    seed_explicit = a.seed_dir is not None
    seed_dir = os.path.abspath(os.path.expanduser(
        a.seed_dir or os.environ.get("CLAUDE_HANDOFF_DIR") or "~/Obsidian/no-it-all/handoffs"))
    seeds, seed_missing, seed_unavailable = [], not os.path.isdir(seed_dir), None
    if a.no_seeds:
        seed_missing = False
    elif seed_missing:
        seed_unavailable = "seed dir %s absent: seed mentions not checked" % seed_dir
        if seed_explicit:
            unverified.append({"path": seed_dir, "reason": "--seed-dir does not exist or is not a directory"})
    else:
        try:
            names = sorted(os.listdir(seed_dir))
        except OSError as e:
            names = []
            seed_unavailable = "seed dir %s unreadable: %s" % (seed_dir, e)
            unverified.append({"path": seed_dir, "reason": "seed dir unreadable: %s" % e})
        for n in names:
            fp = os.path.join(seed_dir, n)
            if n.startswith("NEXT-") and n.endswith(".md") and os.path.isfile(fp):
                try:
                    with open(fp, encoding="utf-8", errors="replace") as fh:
                        seeds.append((n, fh.read()))
                except OSError as e:
                    seed_unavailable = "seed file %s unreadable: %s" % (n, e)
                    unverified.append({"path": fp, "reason": "seed file unreadable: %s" % e})

    cwds = lsof_cwds(a.liveness)
    if a.liveness == "lsof" and cwds is None:
        unverified.append({"path": "lsof", "reason": "--liveness lsof requested but lsof is missing or failed"})
    ctx = {"now": time.time(), "use_gh": not a.no_gh, "cwds": cwds, "seed_unavailable": seed_unavailable,
           "seeds": seeds, "sizes": a.sizes, "bases": {}, "slugs": {}, "forks": {}}

    out_repos, counts = [], {}
    for main_path, ents in repos:
        try:
            ctx["bases"][main_path] = default_base(main_path)
            ctx["slugs"][main_path] = gh_slug(main_path)
            ctx["forks"][main_path] = has_upstream_remote(main_path)
        except GitError as e:
            unverified.append({"path": main_path, "reason": "worktree list unreadable: %s" % e})
            continue
        wts = []
        for ent in ents[1:]:
            try:
                f = collect(main_path, ent, ctx)
                classify(f, a.stale_days)
            except (GitError, ValueError) as e:
                unverified.append({"path": ent["path"], "reason": "worktree facts unreadable: %s" % e})
                f = {"path": ent["path"], "branch": ent["branch"], "head": ent["head"], "detached": ent["detached"],
                     "verdict": "KEEP", "content_class": "?", "reasons": ["facts unreadable: %s" % e], "needs": []}
            counts[f["verdict"]] = counts.get(f["verdict"], 0) + 1
            wts.append(f)
        out_repos.append({"path": main_path, "default_base": ctx["bases"].get(main_path), "worktrees": wts})

    leftovers = []
    for r in roots:
        try:
            for e in sorted(os.scandir(r), key=lambda e: e.name):
                if not e.is_dir(follow_symlinks=False) or not DATE_RE.search(e.name):
                    continue
                gp = os.path.join(e.path, ".git")
                note = None
                if os.path.lexists(gp):
                    note = orphan_note(gp)
                    if note is None:
                        continue
                leftovers.append({"path": e.path, "verdict": "REVIEW", "note": note,
                                  "age_days": age_days(e.stat().st_mtime, ctx["now"])})
        except OSError as e:
            unverified.append({"path": r, "reason": "root unreadable: %s" % e})

    free = {}
    for p in (roots or [m for m, _ in repos]):
        free[p] = free_gib(p)
    rep = {"generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "roots": roots, "repos": out_repos, "leftovers": leftovers, "unverified": unverified,
           "seed_dir": seed_dir, "seed_dir_missing": seed_missing, "seed_unavailable": seed_unavailable,
           "summary": {"repos": len(out_repos), "worktrees": sum(counts.values()), "verdicts": counts,
                       "leftovers": len(leftovers), "unverified": len(unverified),
                       "free_on_filesystem": free}}
    print(json.dumps(rep, indent=2, default=str) if a.json else human(rep))
    if unverified:
        for u in unverified:
            print("worktree-audit: UNVERIFIED %s: %s" % (u["path"], u["reason"]), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
