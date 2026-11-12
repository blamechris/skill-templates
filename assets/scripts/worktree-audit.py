#!/usr/bin/env python3
"""Read-only inventory and classifier for stale git worktrees (#432).

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/worktree-audit.py ~/.claude/scripts/

Usage:
  python3 ~/.claude/scripts/worktree-audit.py [--root DIR]... [--repo PATH]...
      [--json] [--stale-days N] [--liveness auto|lsof|none] [--no-gh]
      [--seed-dir DIR] [--sizes]

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
so even `.git/index` is not refreshed, and the command set is restricted to
readers: no worktree add/remove/prune/lock/unlock, fetch, gc, checkout, reset,
stash or branch -d.

CLASSES per linked worktree (the main checkout is never classified):
  KEEP  in use or liveness unknown / locked by a live or unparseable pid / open
        PR, or PR state unknown for a branch whose head is not in the base /
        named in a session seed / created <24h ago and head not preserved.
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
root/repo, or any discovered repo's worktree list, could not be read (what was
read is still printed, with the unverified items listed).

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
    re.compile(r"\.pyc$"),
]

GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
KEEP_FRESH_DAYS = 1.0


class GitError(Exception):
    pass


def git(args, cwd, ok=(0,)):
    """Run a read-only git command; returns stdout bytes. Raises GitError."""
    try:
        p = subprocess.run(["git"] + args, cwd=cwd, env=GIT_ENV, capture_output=True, timeout=300)
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

def find_repos(root):
    """Main checkouts (.git is a DIRECTORY) under root, depth <= MAX_DEPTH."""
    found = []

    def walk(d, depth):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            if depth + 1 > MAX_DEPTH or e.name == "node_modules" or e.name == ".git":
                continue
            try:
                if not e.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            gp = os.path.join(e.path, ".git")
            if os.path.isdir(gp) and not os.path.islink(gp):
                found.append(e.path)
            elif not os.path.exists(gp):
                walk(e.path, depth + 1)

    walk(root, 0)
    return found


def common_dir(path):
    out, _ = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], path)
    return os.path.realpath(out.decode().strip())


def parse_porcelain(raw):
    entries, cur = [], None
    for line in raw.decode("utf-8", "surrogateescape").split("\n"):
        if not line:
            if cur:
                entries.append(cur)
            cur = None
            continue
        key, _, val = line.partition(" ")
        if key == "worktree":
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


def gh_slug(repo):
    out, rc = git(["config", "--get", "remote.origin.url"], repo, ok=(0, 1))
    url = out.decode().strip()
    # Raw config, not `remote get-url`: the latter applies url.*.insteadOf, and the
    # slug must name the GitHub repo even when the transport is rewritten.
    m = re.match(r"^(?:https?://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
                 r"([^/]+/[^/]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else None


def pr_facts(slug, branch, head, use_gh):
    """-> dict(known, open, merged_head, note)."""
    if branch is None:
        return {"known": True, "open": False, "merged_head": False, "state": "n/a"}
    unknown = {"known": False, "open": False, "merged_head": False, "state": "unknown"}
    if not use_gh or not slug or not shutil.which("gh"):
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
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def parse_pid(reason):
    m = re.search(r"\(pid (\d+)\)", reason) or re.search(r"pid[:= ]\s*(\d+)", reason, re.I)
    return int(m.group(1)) if m else None


def age_days(ts, now):
    return None if ts is None else max(0.0, (now - ts) / 86400.0)


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
        return f
    f["missing"] = False
    head = ent["head"]
    out, _ = git(["log", "-1", "--format=%ct", head], wt)
    f["head_age_days"] = age_days(int(out.strip() or 0), now)
    out, _ = git(["rev-parse", "--absolute-git-dir"], wt)
    gd = os.path.join(out.decode().strip(), "gitdir")
    try:
        f["creation_age_days"] = age_days(os.stat(gd).st_mtime, now)
    except OSError:
        f["creation_age_days"] = None
    out, _ = git(["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=no", "-z"], wt)
    f["tracked_dirty"] = sum(1 for x in out.split(b"\0") if x and x[:2] != b"??")
    # status -z renames add a second NUL field; that overcounts by at most the number of renames
    out, _ = git(["ls-files", "-z", "--others", "--exclude-standard"], wt)
    f["untracked"] = len(nul_list(out))
    out, _ = git(["ls-files", "-z", "--others", "--ignored", "--exclude-standard"], wt)
    ign = [p for p in nul_list(out) if not rebuildable(p)]
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
    pr = pr_facts(ctx["slugs"].get(repo), ent["branch"], head, ctx["use_gh"])
    f["pr"] = pr
    f["merged_pr_head"] = pr["merged_head"]
    cw = ctx["cwds"]
    if cw is None:
        f["in_use"] = None
    else:
        rp = os.path.realpath(wt)
        f["in_use"] = any(c == rp or c.startswith(rp + os.sep) for c in cw)
    f["seeds"] = seed_mentions(ctx["seeds"], wt, ent["branch"])
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
    bre = None
    if branch:
        bre = re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(branch) + r"(?![A-Za-z0-9_.-])")
    for name, text in seeds:
        if any(x in text for x in forms) or (bre and bre.search(text)):
            hits.append(name)
    return hits


def classify(f, stale_days):
    if f.get("missing"):
        f.update(verdict="PRUNABLE-REF", content_class="n/a", reasons=["directory missing; ref remains (git worktree prune)"], needs=[])
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
    elif f["branch"] and not pr["known"] and f["in_base"] is not True:
        reasons.append("PR state unknown")
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
            L.append("  REVIEW       %s  (mtime age %.1f days)" % (tilde(x["path"]), x["age_days"]))
    if rep["seed_dir_missing"]:
        L.append("note: seed dir %s does not exist; no seed mentions checked" % tilde(rep["seed_dir"]))
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
        repo_paths.extend(find_repos(r))

    repos, seen = [], set()
    for p in repo_paths:
        try:
            cd = common_dir(p)
        except GitError as e:
            unverified.append({"path": p, "reason": "not readable as a git repo: %s" % e})
            continue
        if cd in seen:
            continue
        seen.add(cd)
        main_path = os.path.dirname(cd) if os.path.basename(cd) == ".git" else p
        repos.append((main_path, cd))

    seed_dir = os.path.abspath(os.path.expanduser(
        a.seed_dir or os.environ.get("CLAUDE_HANDOFF_DIR") or "~/Obsidian/no-it-all/handoffs"))
    seeds, seed_missing = [], not os.path.isdir(seed_dir)
    if not seed_missing:
        for n in sorted(os.listdir(seed_dir)):
            fp = os.path.join(seed_dir, n)
            if n.startswith("NEXT-") and n.endswith(".md") and os.path.isfile(fp):
                try:
                    with open(fp, encoding="utf-8", errors="replace") as fh:
                        seeds.append((n, fh.read()))
                except OSError:
                    unverified.append({"path": fp, "reason": "seed file unreadable"})

    import time
    ctx = {"now": time.time(), "use_gh": not a.no_gh, "cwds": lsof_cwds(a.liveness) if a.liveness != "none" else None,
           "seeds": seeds, "sizes": a.sizes, "bases": {}, "slugs": {}}

    out_repos, counts = [], {}
    for main_path, cd in repos:
        try:
            raw, _ = git(["worktree", "list", "--porcelain"], main_path)
            ents = parse_porcelain(raw)
            ctx["bases"][main_path] = default_base(main_path)
            ctx["slugs"][main_path] = gh_slug(main_path)
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
                if e.is_dir(follow_symlinks=False) and not os.path.lexists(os.path.join(e.path, ".git")) \
                        and DATE_RE.search(e.name):
                    leftovers.append({"path": e.path, "verdict": "REVIEW",
                                      "age_days": age_days(e.stat().st_mtime, ctx["now"])})
        except OSError as e:
            unverified.append({"path": r, "reason": "root unreadable: %s" % e})

    free = {}
    for p in (roots or [m for m, _ in repos]):
        free[p] = free_gib(p)
    rep = {"generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "roots": roots, "repos": out_repos, "leftovers": leftovers, "unverified": unverified,
           "seed_dir": seed_dir, "seed_dir_missing": seed_missing,
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
