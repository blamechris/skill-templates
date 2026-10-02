#!/usr/bin/env python3
"""Render and verify a repository against the Fleet Project Genesis Standard.

# Canonical copy (skill-templates). Bootstrap: cp assets/scripts/genesis-verify.py ~/.claude/scripts/

Usage:
  genesis-verify.py --plan --name NAME [--stack LIST] [--modules LIST] [--app-id ID|none]
                    [--visibility private] [--posture withheld|gated] [--description TEXT]
                    [--relay-token-in LIST|none] [--seed-issues PATH] [--date YYYY-MM-DD] [--json]
                    [--registry PATH] [--registry-ref REF] [--no-fetch]
  genesis-verify.py --repo PATH [--ref REF] [--gh-repo OWNER/NAME] [--json] [--pin auto|none|REF]
                    [--stack ... --modules ... --app-id ...]   (only when the profile has no intent)
                    [--registry PATH] [--registry-ref REF] [--no-fetch]
  genesis-verify.py --self-check [--registry PATH] [--registry-ref REF] [--no-fetch]
  genesis-verify.py --list-rules [--json] [--registry PATH] [--registry-ref REF] [--no-fetch]

This is the one piece of new logic `/project-genesis` adds; everything else it does is an
existing tool run in order. One renderer serves both halves of the job:

  --plan        renders every write genesis would make for a new repo -- the files with their
                full contents, the GitHub settings, labels, ruleset, skills, machine steps and
                issues -- from assets/genesis/standard-v1.json. The agent performs the writes;
                this script performs none. `--json` is what Phase 3 writes files from.
  verify        (--repo) probes a checkout AT A REF plus the live GitHub settings, and reports
                one row per rule: PASS / FAIL / WAIVED / N-A / LEGACY / PENDING-HUMAN / DRIFT.
                Probes are structural -- headings, keys, settings -- and the expected structure
                is read off the SAME rendered templates the plan wrote, so the two cannot drift
                apart.
  --self-check  the registry's own gate: every `probe`-class rule in the manifest has a probe
                here and every probe here has a rule (the rule<->probe parity), every template
                is referenced and exists, every placeholder is declared and resolves, and every
                `uses:` in a template is pinned to a full commit SHA.

Read-only by construction. The only commands it runs are `git fetch` (a hard precondition,
as in fleet-check.py), `git rev-parse` / `ls-tree` / `show`, and `gh api` GETs. It never
passes -X, -f or -F to gh, and the one secrets endpoint it reads returns names, never values.

The registry is read from `--registry-ref` (default origin/main) with `git show`, never from
the clone's working tree: ~/Projects/skill-templates is a shared working copy that may sit on
another session's branch.

Exit codes:
  0  no FAIL and no LEGACY. PENDING-HUMAN and DRIFT rows are allowed: a human step with an open
     `human-setup` issue, or a rule the registry has since changed underneath an already-conformant
     repo (see --pin below). For --plan: the plan was rendered.
  1  findings: at least one FAIL or LEGACY row (or, for --self-check, at least one registry
     defect).
  2  could not verify -- the registry or repo is unreadable, a ref does not resolve, a fetch
     failed, `gh` failed for any reason other than a meaningful 404 (an ERROR row), a probe hit
     its read bound before finding decisive evidence, --plan refused its input, or --repo names a
     non-git stub instead of a checkout (its own LEGACY finding, but no rule was probed: see
     LEGACY below). Never 0: a check that could not look must not report a pass.

--pin (verify only; default none). `none` judges every rule against --registry-ref alone. `auto`
also reads the one registry commit `docs/adr/0001-project-genesis.md` records under `## Evidence`
-- the commit this repo was built from -- and an explicit REF names such a commit instead. With a
pin, a row FAILs only when it fails at both commits; a row that fails only at --registry-ref is
DRIFT: the standard moved after this repo was built. DRIFT is reported, never filed, and never
changes the exit code; adopting the change is the owner's call. FAIL stays the default verdict: a
pin exempts a row only on positive evidence (a PASS there, or a rule its standard did not
require), and a probe that cannot run against the pin leaves the FAIL standing. An `auto` pin
that is not recorded or does not resolve falls back to --registry-ref alone; an explicit REF that
does not resolve is exit 2. Why (#314): a v1 change on the registry's default ref must not
retroactively FAIL a repo that conformed to the standard it was built from.

LEGACY (verify only; the back-port audit, standard §10.4) is a FAIL row that a known pre-standard
shape fully explains: the `ci-mirror` (a complementary pair of workflows, one skipping pull_request
on `paths-ignore` patterns the other runs on, posting the same check names so the stand-in reports
whenever the real one is skipped), `classic-protection` (classic branch protection instead of a
ruleset), or the repo-level `non-git-stub` (a stub directory in place of the checkout). Only a repo
with no committed genesis intent can read LEGACY; on a genesis repo the same shape is a regression
and stays FAIL. LEGACY is a finding, like FAIL, not an exemption like DRIFT: DRIFT is exit-neutral
because the repo conformed to the standard it was built from, and a LEGACY repo never did -- the
mirror is a confirmed merge-gate hole twice over (it can post a pass under a failing check's name,
and its `[skip-ci]` tag makes required jobs report Success, §4.4). What LEGACY adds is the fix it
names: a migration of the shape, filed once per shape. A failure wins: a detector reclassifies a
row only when its shape explains the row's WHOLE failure, and one that cannot look leaves the FAIL
standing with a could-not-run note, as classify_drift does. The stub is reported before any git
read, as one `machine.checkout` row, and exits 2: no rule was probed. Keeping a shape on purpose is
a waiver ADR (WAIVED), as for any rule.
"""
import argparse
import datetime
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import urllib.parse

EXIT_OK, EXIT_FINDINGS, EXIT_CANNOT_VERIFY = 0, 1, 2

MANIFEST = "assets/genesis/standard-v1.json"
GENESIS_DIR = "assets/genesis/"
TEMPLATES_DIR = "assets/genesis/templates/"
GLOBAL_CLAUDE = "assets/global-CLAUDE.md"

FLOOR_TOKEN = re.compile(r"^\s*<!--\s*floor\s*:\s*([a-z0-9][a-z0-9._-]*)\s*-->\s*$", re.M)
PLACEHOLDER = re.compile(r"@@([A-Z][A-Z0-9_]*)@@")
SLUG = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?$")
# Android's applicationId rule (>= 2 segments, each starting with a letter, [A-Za-z0-9_]);
# it is also a valid Apple bundle ID. It can never change once an app is published.
APP_ID = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*['\"]?([^\s'\"#]+)")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# skill-lint.sh's reading of a posture pin: the block's bold lead, alone or as a list item.
POSTURE_LEAD = re.compile(r"^[ \t]*(?:[-*+][ \t]+)?\*\*[ \t]*(Withheld|Gated)\b", re.M)
# A human-setup issue's `##` sections, in order (the ISSUE_TEMPLATE and human_setup_issue()'s
# render must both match this — self_check asserts both against the one constant).
HUMAN_SETUP_SECTIONS = ("What", "Why a human", "Exact steps", "Secret names", "Reuse or create", "Done when")

RESULTS = ("PASS", "FAIL", "WAIVED", "N-A", "LEGACY", "PENDING-HUMAN", "DRIFT")
ERROR = "ERROR"  # a row whose probe could not look; any ERROR row forces exit 2


class CannotVerify(Exception):
    """A probe could not look (gh failed, a git read failed, or its evidence lies past what it
    reads). Becomes an ERROR row."""


class RenderError(Exception):
    """A template could not be rendered honestly (undeclared or unresolved placeholder)."""


def die(msg):
    print(f"genesis-verify: cannot verify — {msg}", file=sys.stderr)
    print("genesis-verify: NO conformance verdict was produced (this is not a pass).", file=sys.stderr)
    sys.exit(EXIT_CANNOT_VERIFY)


def refuse(msg):
    print(f"REFUSE: {msg}", file=sys.stderr)
    print("genesis-verify: no plan was rendered.", file=sys.stderr)
    sys.exit(EXIT_CANNOT_VERIFY)


def git(path, *args):
    return subprocess.run(["git", "-C", path, *args], capture_output=True)


# ---------------------------------------------------------------- read-only git views

class GitTree:
    """A read-only view of one commit: the file list plus `git show` of any file in it."""

    def __init__(self, path, ref, fetch, what):
        if not os.path.isdir(path):
            die(f"{what} {path!r} does not exist")
        if git(path, "rev-parse", "--git-dir").returncode != 0:
            die(f"{what} {path!r} is not a git repository")
        if fetch and ref.startswith("origin/"):
            # HARD precondition, never `|| true`: a verdict about a stale clone is a wrong
            # answer delivered confidently, which is worse than no answer.
            try:
                fetched = subprocess.run(["git", "-C", path, "fetch", "origin", "--quiet"], capture_output=True,
                                         timeout=180, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
            except subprocess.TimeoutExpired:
                die(f"git fetch origin timed out in {path!r} — refusing to read a possibly stale {ref}")
            if fetched.returncode != 0:
                err = fetched.stderr.decode("utf-8", "replace").strip() or "no stderr"
                die(f"git fetch origin failed in {path!r} ({err}) — refusing to read a "
                    f"possibly stale {ref}")
        rev = git(path, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
        if rev.returncode != 0:
            die(f"{what} ref {ref!r} does not resolve to a commit in {path!r}")
        self.path, self.ref, self.what = path, ref, what
        self.commit = rev.stdout.decode().strip()
        # --full-tree: a --repo pointing at a subdirectory must still see the whole commit.
        listed = git(path, "ls-tree", "-r", "--full-tree", "--name-only", "-z", self.commit)
        if listed.returncode != 0:
            die(f"git ls-tree {self.commit} failed in {path!r}")
        self.files = {p for p in listed.stdout.decode("utf-8", "replace").split("\0") if p}
        self._text = {}

    def has(self, p):
        return p in self.files

    def read(self, p):
        """File text at the commit, or None when the path is absent."""
        if p not in self.files:
            return None
        if p not in self._text:
            shown = git(self.path, "show", f"{self.commit}:{p}")
            if shown.returncode != 0:
                raise CannotVerify(f"git show {self.commit[:7]}:{p} failed in {self.path!r}")
            self._text[p] = shown.stdout.decode("utf-8", "replace")
        return self._text[p]

    def under(self, prefix):
        return sorted(p for p in self.files if p.startswith(prefix))


class Registry(GitTree):
    def need(self, p):
        text = self.read(p)
        if text is None:
            die(f"the registry at {self.ref} ({self.commit[:7]}) has no {p}")
        return text

    def manifest(self):
        try:
            return json.loads(self.need(MANIFEST))
        except json.JSONDecodeError as e:
            die(f"{MANIFEST} at {self.ref} is not valid JSON ({e})")

    def genesis_json(self, rel):
        try:
            return json.loads(self.need(GENESIS_DIR + rel))
        except json.JSONDecodeError as e:
            die(f"{GENESIS_DIR}{rel} at {self.ref} is not valid JSON ({e})")

    def floor_ids(self):
        ids = FLOOR_TOKEN.findall(self.need(GLOBAL_CLAUDE))
        if not ids:
            die(f"{GLOBAL_CLAUDE} at {self.ref} declares no floor rules")
        return ids


class PinRegistry(Registry):
    """The registry at a --pin commit. It is only ever read to classify a FAIL, so a missing or
    malformed file raises CannotVerify -- the row keeps its FAIL -- instead of die(): a pin that
    cannot speak for one row must never abort the whole run (#314)."""

    def need(self, p):
        text = self.read(p)
        if text is None:
            raise CannotVerify(f"the registry pin {self.commit[:7]} has no {p}")
        return text

    def genesis_json(self, rel):
        try:
            return json.loads(self.need(GENESIS_DIR + rel))
        except json.JSONDecodeError as e:
            raise CannotVerify(f"{GENESIS_DIR}{rel} at the registry pin {self.commit[:7]} is not valid JSON ({e})")

    def floor_ids(self):
        ids = FLOOR_TOKEN.findall(self.need(GLOBAL_CLAUDE))
        if not ids:
            raise CannotVerify(f"{GLOBAL_CLAUDE} at the registry pin {self.commit[:7]} declares no floor rules")
        return ids


# ---------------------------------------------------------------- GitHub, GET only

class GH:
    """`gh api` GETs, memoized. A 404 is data only where the caller says it is."""

    def __init__(self, repo):
        self.repo, self.cache = repo, {}

    def get(self, endpoint, missing_ok=False):
        if endpoint in self.cache:
            return self.cache[endpoint]
        try:
            run = subprocess.run(
                ["gh", "api", "-H", "Accept: application/vnd.github+json", endpoint],
                capture_output=True, text=True, timeout=60,
            )
        except FileNotFoundError:
            raise CannotVerify("`gh` is not installed")
        except subprocess.TimeoutExpired:
            raise CannotVerify(f"gh api {endpoint} timed out")
        if run.returncode == 0:
            out = run.stdout.strip()
            try:
                value = json.loads(out) if out else {}  # a 204 has no body
            except json.JSONDecodeError:
                raise CannotVerify(f"gh api {endpoint} returned non-JSON output")
        elif missing_ok and "(HTTP 404)" in run.stderr:
            value = None
        else:
            err = (run.stderr.strip() or f"exit {run.returncode}").splitlines()[-1]
            raise CannotVerify(f"gh api {endpoint}: {err[:200]}")
        self.cache[endpoint] = value
        return value

    def paged(self, endpoint, key=None):
        """Every item of a list endpoint. `key` names the array inside an object response."""
        items, page, sep = [], 1, "&" if "?" in endpoint else "?"
        while True:
            data = self.get(f"{endpoint}{sep}per_page=100&page={page}")
            batch = data.get(key, []) if key else data
            if not isinstance(batch, list):
                raise CannotVerify(f"gh api {endpoint} did not return a list")
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1

    def repo_info(self):
        return self.get(f"repos/{self.repo}")


# ---------------------------------------------------------------- small parsers

def headings(text, level):
    """Heading texts of exactly `level`, outside code fences, in document order."""
    pat = re.compile(r"^" + "#" * level + r"[ \t]+(.+?)[ \t]*#*[ \t]*$")
    out, fenced = [], False
    for ln in text.splitlines():
        if ln.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            m = pat.match(ln)
            if m:
                out.append(m.group(1).strip())
    return out


def order_problems(required, actual):
    """Required headings that are missing from `actual`, or present out of order."""
    problems, pos = [], 0
    for h in required:
        if h not in actual:
            problems.append(f"missing `{h}`")
            continue
        try:
            pos = actual.index(h, pos) + 1
        except ValueError:
            problems.append(f"`{h}` is out of order")
    return problems


def defence(text):
    """Text with every fenced code block's lines blanked: a `# comment` in a bash example
    is not a heading, for any parser that walks headings."""
    out, fenced = [], False
    for ln in text.splitlines():
        if ln.lstrip().startswith("```"):
            fenced = not fenced
            out.append("")
        else:
            out.append("" if fenced else ln)
    return "\n".join(out)


def section(text, title, level=2):
    """Body of the `level` heading named `title`, up to the next heading of that level or
    higher, outside code fences; None when absent. Fenced lines come back blanked."""
    lines, out, inside = defence(text).splitlines(), [], False
    head = re.compile(r"^(#{1,%d})[ \t]+(.+?)[ \t]*#*[ \t]*$" % level)
    for ln in lines:
        m = head.match(ln)
        if m:
            if inside:
                break
            if len(m.group(1)) == level and m.group(2).strip() == title:
                inside = True
                continue
        elif inside:
            out.append(ln)
    return "\n".join(out) if inside else None


def ignore_lines(text):
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]


def split_list(value):
    v = (value or "").strip()
    if not v or v.lower() == "none":
        return []
    return [x.strip() for x in v.split(",") if x.strip()]


def workflow_jobs(text):
    """{job_key: {"needs": [...], "if": str|None, "name": str, "body": str}} from a workflow's
    `jobs:`. "name" is the job's display name -- its own `name:` property, falling back to the
    job key when absent (GitHub's jobs API reports the display name the same way).

    Indentation-aware rather than column-fixed: the job-key indent is whatever the first key
    under `jobs:` uses, and a job's properties are the lines indented one level deeper.
    """
    jobs, lines = {}, text.splitlines()
    try:
        start = next(i for i, ln in enumerate(lines) if re.match(r"^jobs:\s*(#.*)?$", ln))
    except StopIteration:
        return jobs
    key_indent, cur = None, None
    for ln in lines[start + 1:]:
        if not ln.strip() or ln.lstrip().startswith("#"):
            if cur:
                jobs[cur]["lines"].append(ln)
            continue
        indent = len(ln) - len(ln.lstrip(" "))
        if indent == 0:
            break
        if key_indent is None:
            key_indent = indent
        m = re.match(r"^\s*(['\"]?)([A-Za-z0-9_-]+)\1:\s*(#.*)?$", ln)
        if indent == key_indent:
            # A line at the job-key indent that is not a plain key is kept as its own
            # pseudo-job, so ci-gate's `needs` cannot cover it and the probe fails closed.
            cur = m.group(2) if m else f"<unparsed: {ln.strip()[:40]}>"
            jobs[cur] = {"lines": []}
        elif cur:
            jobs[cur]["lines"].append(ln)
    for key, j in jobs.items():
        body = j.pop("lines")
        props = [ln for ln in body if ln.strip() and not ln.lstrip().startswith("#")]
        pind = min((len(ln) - len(ln.lstrip(" ")) for ln in props), default=0)
        j["needs"], j["if"], j["name"] = [], None, key
        for i, ln in enumerate(body):
            if len(ln) - len(ln.lstrip(" ")) != pind:
                continue
            m = re.match(r"^\s*needs:\s*(.*?)\s*(#.*)?$", ln)
            if m:
                v = m.group(1)
                if v.startswith("["):
                    j["needs"] = [x.strip().strip("'\"") for x in v.strip("[]").split(",") if x.strip()]
                elif v:
                    j["needs"] = [v.strip("'\"")]
                else:
                    for nxt in body[i + 1:]:
                        m2 = re.match(r"^\s*-\s*['\"]?([A-Za-z0-9_-]+)", nxt)
                        if not m2:
                            break
                        j["needs"].append(m2.group(1))
            m = re.match(r"^\s*if:\s*(.+?)\s*$", ln)
            if m:
                j["if"] = m.group(1)
                ind = re.match(r"^([|>])[0-9+-]*\s*(?:#.*)?$", j["if"])
                if ind:
                    # A `|` / `>` block scalar (any chomping or indentation indicator): the
                    # condition is the lines indented deeper than `if:`, joined into one string.
                    # Either style yields a single evaluable line; a literal's newlines would only
                    # matter to a consumer comparing text, and none does.
                    parts = []
                    for nxt in body[i + 1:]:
                        if nxt.strip() and len(nxt) - len(nxt.lstrip(" ")) <= pind:
                            break
                        if nxt.strip():
                            parts.append(nxt.strip())
                    j["if"] = " ".join(parts) or None
            # A comment needs whitespace before its `#`: a display name like `C#-lint` keeps it.
            m = re.match(r"^\s*name:\s*(.*?)\s*(?:\s#.*)?$", ln)
            if m and m.group(1) and "${{" not in m.group(1):
                # An unresolved `${{ }}` expression can't be matched literally against the
                # jobs API's display name, so the job-key fallback stands instead.
                j["name"] = m.group(1).strip("'\"")
        j["body"] = "\n".join(body)
    return jobs


def on_block(text):
    """(inline_list_or_None, [lines of the `on:` block]) of a workflow."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r"^(?:on|\"on\"|'on'|true):\s*(.*?)\s*(#.*)?$", ln)
        if not m:
            continue
        if m.group(1):
            v = m.group(1)
            return [x.strip() for x in v.strip("[]").split(",") if x.strip()], []
        block = []
        for nxt in lines[i + 1:]:
            if nxt.strip() and not nxt.startswith((" ", "\t", "#")):
                break
            block.append(nxt)
        return None, block
    return None, None


ON_LINE = re.compile(r"^(?:on|\"on\"|'on'|true):\s*(.*?)\s*(#.*)?$")


def strip_comment(s):
    """`s` without a trailing YAML comment (` #` outside quotes), right-trimmed."""
    quote = None
    for i, c in enumerate(s):
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
    return s.rstrip()


def parse_flow(s):
    """A YAML flow node -- `{k: v, ...}`, `[a, b]` or a scalar -- as dict / list / str, quotes
    removed. A flow-mapping key with no value (`{pull_request, push}`) maps to None. Raises
    ValueError on anything it cannot read, so a caller can fall back to "unknown"."""
    pos = [0]

    def skip():
        while pos[0] < len(s) and s[pos[0]] in " \t\n":
            pos[0] += 1

    def scalar(stops):
        skip()
        if pos[0] < len(s) and s[pos[0]] in "'\"":
            q = s[pos[0]]
            pos[0] += 1
            out = []
            while pos[0] < len(s):
                c = s[pos[0]]
                if c == q:
                    if q == "'" and s[pos[0]:pos[0] + 2] == "''":
                        out.append("'")
                        pos[0] += 2
                        continue
                    pos[0] += 1
                    return "".join(out)
                if c == "\\" and q == '"' and pos[0] + 1 < len(s):
                    pos[0] += 1
                    c = s[pos[0]]
                out.append(c)
                pos[0] += 1
            raise ValueError("unterminated quote")
        start = pos[0]
        while pos[0] < len(s) and s[pos[0]] not in stops:
            if s[pos[0]] == ":" and (pos[0] + 1 >= len(s) or s[pos[0] + 1] in " \t\n,]}"):
                break
            pos[0] += 1
        return s[start:pos[0]].strip()

    def node():
        skip()
        if pos[0] >= len(s):
            raise ValueError("unexpected end")
        c = s[pos[0]]
        if c == "[":
            pos[0] += 1
            items = []
            while True:
                skip()
                if pos[0] < len(s) and s[pos[0]] == "]":
                    pos[0] += 1
                    return items
                items.append(node())
                skip()
                if pos[0] < len(s) and s[pos[0]] == ",":
                    pos[0] += 1
                elif pos[0] >= len(s) or s[pos[0]] != "]":
                    raise ValueError("bad flow sequence")
        if c == "{":
            pos[0] += 1
            out = {}
            while True:
                skip()
                if pos[0] < len(s) and s[pos[0]] == "}":
                    pos[0] += 1
                    return out
                key = scalar(",:}]")
                skip()
                val = None
                if pos[0] < len(s) and s[pos[0]] == ":":
                    pos[0] += 1
                    skip()
                    if pos[0] < len(s) and s[pos[0]] not in ",}":
                        val = node()
                out[key] = val
                skip()
                if pos[0] < len(s) and s[pos[0]] == ",":
                    pos[0] += 1
                elif pos[0] >= len(s) or s[pos[0]] != "}":
                    raise ValueError("bad flow mapping")
        return scalar(",]}")

    value = node()
    skip()
    if pos[0] != len(s):
        raise ValueError("trailing text")
    return value


def on_section(text):
    """(inline_value_or_None, [lines of the block]) of a workflow's `on:`, for wf_pull_request.
    Unlike on_block it keeps the raw inline text (a flow mapping is not a comma list), joins a
    flow collection that spans lines, and keeps an indentless block sequence (`on:` followed by
    `- pull_request` at column 0) in the block. (None, None) when there is no `on:`."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        m = ON_LINE.match(ln)
        if not m:
            continue
        val = m.group(1)
        if val:
            if val[0] in "[{":
                for nxt in lines[i + 1:]:
                    if not (val.count("[") + val.count("{") > val.count("]") + val.count("}")):
                        break
                    val += "\n" + strip_comment(nxt)
            return val, []
        block = []
        for nxt in lines[i + 1:]:
            if nxt.strip() and not nxt.startswith((" ", "\t", "#", "- ")):
                break
            block.append(nxt)
        return None, block
    return None, None


def push_branches(block):
    """The `push.branches` items of an `on:` block, inline or block list; None if absent."""
    push_i = next((i for i, ln in enumerate(block) if re.match(r"^\s+push:\s*(#.*)?$", ln)), None)
    if push_i is None:
        return None
    indent = len(block[push_i]) - len(block[push_i].lstrip())
    body = []
    for ln in block[push_i + 1:]:
        if ln.strip() and len(ln) - len(ln.lstrip()) <= indent:
            break
        body.append(ln)
    for i, ln in enumerate(body):
        m = re.match(r"^\s*branches:\s*(.*?)\s*(#.*)?$", ln)
        if not m:
            continue
        if m.group(1).startswith("["):
            return [x.strip().strip("'\"") for x in m.group(1).strip("[]").split(",") if x.strip()]
        items, bi = [], len(ln) - len(ln.lstrip())
        for nxt in body[i + 1:]:
            mm = re.match(r"^(\s*)-\s*['\"]?([^'\"#]+?)['\"]?\s*(#.*)?$", nxt)
            if not mm or len(mm.group(1)) < bi:
                break
            items.append(mm.group(2))
        return items
    return None


def dependabot_ecosystems(text):
    """{ecosystem: entry text} from dependabot.yml's `updates:` list. Items are split on the
    list marker at the item indent, and `package-ecosystem` may be any key of an item."""
    lines, items, item_indent, cur = text.splitlines(), [], None, None
    try:
        start = next(i for i, ln in enumerate(lines) if re.match(r"^updates:\s*(#.*)?$", ln))
    except StopIteration:
        return {}
    for ln in lines[start + 1:]:
        if ln.strip() and not ln.startswith((" ", "\t", "-", "#")):
            break
        m = re.match(r"^(\s*)-\s", ln)
        if m and (item_indent is None or len(m.group(1)) == item_indent):
            item_indent = len(m.group(1))
            cur = [ln[len(m.group(0)):]]
            items.append(cur)
        elif cur is not None:
            cur.append(ln)
    out = {}
    for it in items:
        body = "\n".join(it)
        m = re.search(r"(?:^|\n)\s*package-ecosystem:\s*['\"]?([A-Za-z0-9_-]+)", body)
        if m:
            out[m.group(1)] = body + "\n"
    return out


def remote_slug(path):
    got = git(path, "remote", "get-url", "origin")
    if got.returncode != 0:
        return None
    url = got.stdout.decode().strip()
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else None


# ---------------------------------------------------------------- intent

class Intent:
    """What the owner chose. From flags at plan time; from the committed profile at verify."""

    def __init__(self, **kw):
        self.name = kw["name"]
        self.owner = kw["owner"]
        self.visibility = kw.get("visibility", "private")
        self.overlays = kw.get("overlays", [])
        self.modules = kw.get("modules", [])
        self.app_id = kw.get("app_id", "none")
        self.posture = kw.get("posture", "withheld")
        self.description = kw.get("description") or ""
        self.credits_paths = kw.get("credits_paths", [])
        self.deferred = kw.get("deferred", None)
        self.waivers = kw.get("waivers", {})
        self.relay_token_in = kw.get("relay_token_in", None)
        self.date = kw.get("date") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        self.source = kw.get("source", "flags")
        self.problems = kw.get("problems", [])

    @property
    def repo(self):
        return f"{self.owner}/{self.name}"

    def layers(self):
        return {"core"} | {f"overlay:{o}" for o in self.overlays} | {f"module:{m}" for m in self.modules}


def norm_repo_path(p):
    p = posixpath.normpath(p.strip().strip("`"))
    return "" if p == "." else p.lstrip("/")


def derive_app_id(name):
    seg = re.sub(r"[^a-z0-9]", "", name.lower())
    return f"com.blamechris.{seg}"


def parse_profile_intent(profile_text, man):
    """(fields dict, problems) from `## project-genesis Customizations`; (None, [why]) if absent."""
    if profile_text is None:
        return None, [".claude/skill-profile.md is missing"]
    body = section(profile_text, man["profile_section"])
    if body is None:
        return None, [f"the profile has no `## {man['profile_section']}` section"]
    fields = {}
    for ln in body.splitlines():
        m = re.match(r"^\s*(?:[-*+]\s+)?([a-z][a-z-]*)\s*:\s*(.*?)\s*$", ln)
        if m and m.group(1) not in fields:
            fields[m.group(1)] = m.group(2)
    return fields, []


INTENT_KEYS = ("standard", "visibility", "overlays", "modules", "app-id", "credits-paths",
               "deferred-skills", "waivers")


def intent_from_profile(fields, man, name, owner, posture="withheld"):
    problems = [f"missing `{k}:`" for k in INTENT_KEYS if k not in fields]
    if fields.get("standard", "v1") != man["standard"]:
        problems.append(f"standard is {fields.get('standard')!r}, this registry renders {man['standard']!r}")
    overlays, modules = split_list(fields.get("overlays")), split_list(fields.get("modules"))
    for o in overlays:
        spec = man["overlays"].get(o)
        if spec is None:
            problems.append(f"unknown overlay `{o}`")
        elif spec.get("status") != "implemented":
            problems.append(f"overlay `{o}` is planned, not implemented, in {man['standard']}")
    for m in modules:
        spec = man["modules"].get(m)
        if spec is None:
            problems.append(f"unknown module `{m}`")
        elif spec.get("status") != "implemented":
            problems.append(f"module `{m}` is planned, not implemented, in {man['standard']}")
    vis = fields.get("visibility", "private")
    if vis not in man["visibility"]:
        problems.append(f"visibility `{vis}` is not one of {sorted(man['visibility'])}")
    elif man["visibility"][vis].get("status") != "implemented":
        problems.append(f"visibility `{vis}` is planned, not implemented, in {man['standard']} — "
                        f"nothing probes its bundle")
    for m, spec in man["modules"].items():
        if spec.get("required") and m not in modules:
            problems.append(f"module `{m}` is required: {spec['required']}")
    app_id = fields.get("app-id", "none") or "none"
    if app_id != "none" and not APP_ID.match(app_id):
        problems.append(f"app-id `{app_id}` is not a valid Android/Apple ID")
    deferred = split_list(fields.get("deferred-skills"))
    known_deferred = {d["name"] for d in man["skills"]["deferred"]}
    for d in deferred:
        if d not in known_deferred:
            problems.append(f"deferred skill `{d}` is not one the standard defers")
    waivers, probed = {}, {r["id"] for r in man["rules"] if r["class"] == "probe"}
    for w in split_list(fields.get("waivers")):
        m = re.match(r"^([a-z0-9._-]+)\s*\(([^)]+)\)$", w)
        if not m:
            problems.append(f"waiver `{w}` is not `<rule-id> (<adr path>)`")
        elif m.group(1) not in probed:
            problems.append(f"waiver names `{m.group(1)}`, which is not a probed rule")
        else:
            waivers[m.group(1)] = m.group(2).strip()
    return Intent(name=name, owner=owner, visibility=vis,
                  overlays=[o for o in overlays if man["overlays"].get(o, {}).get("status") == "implemented"],
                  modules=[m for m in modules if man["modules"].get(m, {}).get("status") == "implemented"],
                  app_id=app_id, credits_paths=[norm_repo_path(p) for p in split_list(fields.get("credits-paths"))],
                  posture=posture, deferred=deferred, waivers=waivers, source="profile", problems=problems)


# ---------------------------------------------------------------- rendering

def render_text(text, values, where):
    """Substitute @@KEY@@ tokens. A line made only of tokens that render empty is dropped,
    so an absent overlay leaves no blank scar. Undeclared or surviving tokens are errors:
    a rendered file never ships a placeholder (Principle 3, real values only)."""
    out = []
    for line in text.splitlines(keepends=True):
        names = PLACEHOLDER.findall(line)
        for n in names:
            if n not in values:
                raise RenderError(f"{where}: undeclared placeholder @@{n}@@")
        rendered = PLACEHOLDER.sub(lambda m: values[m.group(1)], line)
        if names and not PLACEHOLDER.sub("", line).strip() and not rendered.strip():
            continue
        out.append(rendered)
    result = "".join(out)
    if PLACEHOLDER.search(result):
        raise RenderError(f"{where}: a placeholder survived rendering")
    return result


def build_values(man, reg, intent):
    overlays = [(o, man["overlays"][o]) for o in intent.overlays]
    vis = man["visibility"].get(intent.visibility, {})

    def frag(kind):
        # A fragment block opens with a blank line and fragments are separated by one; the
        # placeholder's own line supplies the final newline.
        parts = [reg.need(GENESIS_DIR + spec["fragments"][kind]).strip("\n")
                 for _, spec in overlays if (spec.get("fragments") or {}).get(kind)]
        return "\n" + "\n\n".join(parts) if parts else ""

    groups = {o: {"ignore": spec["path_group"]["ignore"], "ready": spec["path_group"].get("ready")}
              for o, spec in overlays if spec.get("path_group")}
    commands = [f"- {c}" for c in man["core"]["commands"]]
    commands += [f"- {spec['build_note']}" for _, spec in overlays if spec.get("build_note")]
    desc = intent.description.strip() or f"{intent.name} has no description yet."
    values = {
        "NAME": intent.name,
        "OWNER": intent.owner,
        "REPO": intent.repo,
        "DESCRIPTION": desc,
        "DATE": intent.date,
        "VISIBILITY": intent.visibility,
        "OVERLAYS": ", ".join(intent.overlays) or "none",
        "MODULES": ", ".join(intent.modules) or "none",
        "APP_ID": intent.app_id,
        "POSTURE": "Gated" if intent.posture == "gated" else "Withheld",
        "FLOOR_IDS": "\n".join(f"- `{i}`" for i in reg.floor_ids()),
        "BUILD_COMMANDS": "\n".join(commands),
        "MCP_LINE": ("The `repo-memory` MCP server is configured in `.mcp.json`: prefer "
                     "`get_file_summary` over reading a whole file you will not edit."
                     if "repo-memory" in intent.modules else "No MCP servers are configured."),
        "LICENSE_LINE": vis.get("license_line", ""),
        "CREDITS_POSTURE": ("\n**Licence posture (credits module).** Bundled third-party media is "
                            "listed in `CREDITS.md`, one row per asset with its source, licence and "
                            "exact credit string. CC BY credits must be reachable in the app; CC BY-SA "
                            "and NC assets are a risk in a closed-source binary and need an ADR before "
                            "they are bundled." if "credits" in intent.modules else ""),
        "REGISTRY_COMMIT": reg.commit[:7],
        "GITIGNORE_OVERLAYS": frag("gitignore"),
        "GITATTRIBUTES_OVERLAYS": frag("gitattributes"),
        "DEPENDABOT_OVERLAYS": frag("dependabot"),
        "CI_OVERLAY_JOBS": frag("ci_job"),
        "CI_GATE_NEEDS": ", ".join(["route", "hygiene"] + (["changes"] if groups else [])
                                   + [spec["ci_job"] for _, spec in overlays if spec.get("ci_job")]),
        "CI_CHANGES_OUTPUTS": "\n".join(f"      {g}: ${{{{ steps.groups.outputs.{g} }}}}" for g in groups),
        "CI_CHANGES_GROUPS": json.dumps(groups, separators=(", ", ": ")),
        "CI_CHANGES_JOB": "",
    }
    if groups:
        tmpl = reg.need(GENESIS_DIR + man["core"]["fragments"]["ci_changes"])
        values["CI_CHANGES_JOB"] = "\n" + render_text(tmpl, values, "ci-changes fragment").strip("\n")
    # Fragments may themselves carry placeholders; render them against the same values.
    for k in ("GITIGNORE_OVERLAYS", "GITATTRIBUTES_OVERLAYS", "DEPENDABOT_OVERLAYS", "CI_OVERLAY_JOBS"):
        values[k] = render_text(values[k], values, f"{k} fragments").rstrip("\n") if values[k] else ""
    declared = set(man["placeholders"])
    if set(values) != declared:
        raise RenderError(f"renderer values {sorted(set(values) ^ declared)} disagree with the "
                          f"manifest's declared placeholders")
    return values


def file_specs(man, intent):
    specs = [dict(f, layer="core") for f in man["core"]["files"]]
    for m in intent.modules:
        specs += [dict(f, layer=f"module:{m}") for f in man["modules"][m].get("files", [])]
    return specs


def render_files(man, reg, intent):
    values = build_values(man, reg, intent)
    files = []
    for spec in file_specs(man, intent):
        content = render_text(reg.need(GENESIS_DIR + spec["template"]), values, spec["template"])
        files.append({"path": spec["path"], "template": spec["template"], "layer": spec["layer"],
                      "phase": 3, "content": content})
    return files, values


# ---------------------------------------------------------------- seed issues

TITLE_LINE = re.compile(r"^# (.+?)\s*$")
LABEL_LINE = re.compile(r"^Label:\s*(.*)$")
HEADER_LINE = re.compile(r"^(Labels|Parent|Acceptance):\s*(.*?)\s*$")


FENCE_LINE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")


def _fences(lines):
    """(mask, unclosed): per line, True on a fence delimiter or inside a fence; and the index
    of a fence that never closes, else None. As in CommonMark, a fence closes only on a bare
    run of its own character at least as long as the one that opened it, so a ```` fence can
    quote a ``` example and ``` can quote ~~~. headings()/defence() make no such distinction;
    the probes run them on templates that only ever fence with a bare ```. The delimiter line
    itself is masked, so it is never mistaken for a title, header or preamble line either."""
    mask, opener, opened_at = [], None, None
    for i, ln in enumerate(lines):
        m = FENCE_LINE.match(ln)
        # A backtick run whose info string holds a backtick is inline code, not a fence.
        if opener is None and m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            opener, opened_at = m.group(1), i
            mask.append(True)
        elif (opener is not None and m and m.group(1)[0] == opener[0]
              and len(m.group(1)) >= len(opener) and not m.group(2).strip()):
            opener = None
            mask.append(True)
        else:
            mask.append(opener is not None)
    return mask, (opened_at if opener is not None else None)


def _seed_h2(body):
    """A seed body's `##` heading texts outside ``` and ~~~ fences, in order."""
    pat = re.compile(r"^##[ \t]+(.+?)[ \t]*#*[ \t]*$")
    lines = body.split("\n")
    return [m.group(1).strip() for ln, fenced in zip(lines, _fences(lines)[0])
            if not fenced for m in [pat.match(ln)] if m]


def _add_owner_label(rest, line_no, standard_labels, remove_default_ci, owner_labels, owner_names_ci):
    """Parse one preamble `Label: name | colour | description` line (rule 11)."""
    parts = [p.strip() for p in rest.split("|", 2)]
    if len(parts) != 3 or not all(parts):
        refuse(f"seed issues line {line_no}: `Label:` needs `name | colour | description` "
               f"(three non-empty parts separated by `|`)")
    name, colour, desc = parts
    if len(name) > 50:
        refuse(f"seed issues line {line_no}: owner label `{name}` is longer than 50 characters")
    if "," in name:
        refuse(f"seed issues line {line_no}: owner label `{name}` cannot contain a comma")
    cm = re.match(r"^#?([0-9a-fA-F]{6})$", colour)
    if not cm:
        refuse(f"seed issues line {line_no}: owner label `{name}` has an invalid colour `{colour}` "
               f"(want 6 hex digits, an optional leading `#`)")
    if len(desc) > 100:
        refuse(f"seed issues line {line_no}: owner label `{name}` description is longer than 100 characters")
    if name.lower() in {s.lower() for s in standard_labels}:
        refuse(f"seed issues line {line_no}: owner label `{name}` redefines a standard label "
               f"(genesis never redefines a standard label)")
    if name.lower() in remove_default_ci:
        refuse(f"seed issues: owner label `{name}` is a GitHub default genesis deletes; pick another name")
    if name.lower() in owner_names_ci:
        refuse(f"seed issues line {line_no}: owner label `{name}` is declared more than once")
    owner_names_ci.add(name.lower())
    owner_labels.append({"name": name, "color": cm.group(1).lower(), "description": desc})


def parse_seed_issues(path, man, reg):
    """Parse a --seed-issues file (grammar v2) into owner labels + entries.

    An optional preamble of blank lines and `Label: name | colour | description` lines (owner
    labels), then zero or more entries:

        # <title>
        Labels: <comma list>
        Parent: <an earlier entry's title>       (optional)
        Acceptance: <criterion>                  (any number; required for a work entry)

        <body, up to the next `# <title>` or EOF>

    The header block (`Labels:`/`Parent:`/`Acceptance:` lines) sits directly under the title —
    no blank line before it — and ends at the first blank line; the body is everything after
    that blank line, leading/trailing blank lines stripped. Parsing is fence-aware throughout:
    a line whose lstrip starts with ``` or ~~~ toggles a fence, and a line inside a fence is
    never a title, preamble or header line (so a fenced `# not a title` stays body text).

    An entry is `human-setup` when `human-setup` is among its labels, else `work`:
      - work: at least one `Acceptance:` line; its body may not contain a `## Context`,
        `## Description` or `## Acceptance Criteria` heading — the plan renders those.
      - human-setup: no `Acceptance:` line; its body's `##` headings must include every one of
        HUMAN_SETUP_SECTIONS, in that order (other `##` headings may sit between them), and
        may not contain `## Context` (Phase 5 adds it).

    Every label must exactly equal a standard label (assets/genesis/labels.json) or an owner
    label declared by a preamble `Label:` line. `Parent:`, when present, must exactly equal an
    EARLIER entry's title in the same file — self, later or unknown REFUSEs. Titles must be
    unique and may not equal the epic title or any title genesis already plans to file; that
    last check needs the plan's own rendered issue titles, so it happens in build_plan, not
    here. A file with zero entries and zero owner labels is refused as empty.

    Every violation exits through refuse() (exit 2, "no plan was rendered"). Returns
    {"path": <abs path>, "sha256": <hex of the raw file bytes>, "owner_labels": [...],
     "entries": [{"kind", "title", "labels", "parent", "acceptance", "body"}, ...]} — all in
    file order.
    """
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        refuse(f"seed issues: cannot read `{path}` ({e.strerror or e})")
    abspath = os.path.realpath(path)
    digest = hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        refuse(f"seed issues: `{path}` is not valid UTF-8 ({e})")

    standard_labels = {l["name"] for l in reg.genesis_json(man["github"]["labels"])}
    remove_default_ci = {n.lower() for n in man["github"]["remove_default_labels"]}

    # Split on newlines only: splitlines() also breaks on U+2028, form feeds and the like,
    # which a paste from rich text can carry inside a title.
    lines = text.replace("\r\n", "\n").split("\n")
    n = len(lines)
    mask, unclosed = _fences(lines)
    if unclosed is not None:
        refuse(f"seed issues line {unclosed + 1}: a code fence opened here never closes, so every "
               f"entry after it would be read as its body")

    owner_labels, owner_names_ci = [], set()
    entries, titles_seen = [], set()

    i = 0
    # -------- preamble: blank and Label: lines only, up to the first entry title
    while i < n and not (TITLE_LINE.match(lines[i]) and not mask[i]):
        ln = lines[i]
        if ln.strip() == "":
            i += 1
            continue
        m = LABEL_LINE.match(ln)
        if not m:
            refuse(f"seed issues line {i + 1}: the preamble holds only `Label:` lines "
                   f"(an issue starts with `# <title>`)")
        _add_owner_label(m.group(1), i + 1, standard_labels, remove_default_ci, owner_labels, owner_names_ci)
        i += 1

    # -------- entries
    while i < n:
        m = TITLE_LINE.match(lines[i])
        title, title_line = m.group(1).strip(), i + 1
        if not title:
            refuse(f"seed issues line {title_line}: an issue title cannot be blank")
        if len(title) > 256:
            refuse(f"seed issues line {title_line}: `{title[:60]}…` is longer than 256 characters")
        i += 1

        header = []
        while i < n and lines[i].strip() != "":
            header.append((i, lines[i]))
            i += 1
        if i < n:
            i += 1  # skip the blank line terminating the header block

        body_start = i
        while i < n and not (TITLE_LINE.match(lines[i]) and not mask[i]):
            i += 1
        body_lines = lines[body_start:i]
        while body_lines and body_lines[0].strip() == "":
            body_lines.pop(0)
        # A header line below a blank (or whitespace-only) line would otherwise become body
        # prose, and a lost `Parent:` files the issue from the epic without a word.
        if body_lines and HEADER_LINE.match(body_lines[0]):
            refuse(f"seed issues: `{title}`: `{body_lines[0].strip()}` sits below a blank line; "
                   f"the `Labels:`, `Parent:` and `Acceptance:` lines follow the title with no "
                   f"blank line between them")
        while body_lines and body_lines[-1].strip() == "":
            body_lines.pop()
        body = "\n".join(body_lines)

        labels_val, parent_val, acceptance = None, None, []
        for ln_idx, ln_text in header:
            hm = HEADER_LINE.match(ln_text)
            if not hm:
                refuse(f"seed issues line {ln_idx + 1}: `{title}`'s header has an invalid line "
                       f"`{ln_text.strip()}` (want `Labels:`, `Parent:` or `Acceptance:`)")
            key, val = hm.group(1), hm.group(2)
            if key == "Labels":
                if labels_val is not None:
                    refuse(f"seed issues: `{title}` repeats `Labels:`")
                labels_val = val
            elif key == "Parent":
                if parent_val is not None:
                    refuse(f"seed issues: `{title}` has more than one `Parent:`")
                parent_val = val
            else:
                if not val:
                    refuse(f"seed issues: `{title}` has an empty `Acceptance:` line")
                acceptance.append(val)
        if labels_val is None:
            refuse(f"seed issues: `{title}` has no `Labels:` line")
        names = split_list(labels_val)
        if not names:
            refuse(f"seed issues: `{title}` has no `Labels:` line")
        if len(set(names)) != len(names):
            refuse(f"seed issues: `{title}` repeats a label")
        allowed = standard_labels | {ol["name"] for ol in owner_labels}
        unknown = [x for x in names if x not in allowed]
        if unknown:
            refuse(f"seed issues: `{title}` uses unknown label(s) {unknown} — owner labels must "
                   f"be declared with `Label:` lines")

        if not body.strip():
            refuse(f"seed issues: `{title}` has an empty body")

        kind = "human-setup" if "human-setup" in names else "work"
        if kind == "work":
            if not acceptance:
                refuse(f"seed issues: `{title}`: /create-issue requires acceptance criteria")
            forbidden = sorted({"Context", "Description", "Acceptance Criteria"} & set(_seed_h2(body)))
            if forbidden:
                refuse(f"seed issues: `{title}` body must not contain heading(s) {forbidden} — "
                       f"the plan renders those")
        else:
            if acceptance:
                refuse(f"seed issues: `{title}`: a human-setup entry states its criteria under "
                       f"`## Done when`")
            got = _seed_h2(body)
            probs = order_problems(list(HUMAN_SETUP_SECTIONS), got)
            if probs:
                refuse(f"seed issues: `{title}`: {'; '.join(probs)}")
            if "Context" in got:
                refuse(f"seed issues: `{title}` body must not contain `## Context` (Phase 5 adds it)")

        parent = None
        if parent_val:
            if parent_val not in titles_seen:
                refuse(f"seed issues: `{title}`'s `Parent:` names `{parent_val}`, which is not an "
                       f"earlier entry in this file")
            parent = parent_val

        entries.append({"kind": kind, "title": title, "labels": names, "parent": parent,
                        "acceptance": acceptance if kind == "work" else [], "body": body})
        titles_seen.add(title)

    if not entries and not owner_labels:
        refuse("seed issues: the file has no entries and no owner labels (empty)")

    return {"path": abspath, "sha256": digest, "owner_labels": owner_labels, "entries": entries}


# ---------------------------------------------------------------- plan

def human_setup_issue(man, intent, entry, values):
    title = render_text(entry["title"], values, "human_setup title")
    if entry["rule"] == "module.repo-relay.secrets":
        spec = man["modules"]["repo-relay"]
        req, opt = spec["secrets"], spec["optional_secrets"]
        if intent.relay_token_in is None:
            reuse = ("Unknown: Phase 0's sibling-secret probe was not passed to the plan "
                     "(`--relay-token-in`). Run it before creating a new bot.")
        elif intent.relay_token_in:
            reuse = ("Reuse the existing bot token. `DISCORD_BOT_TOKEN` is already set in: "
                     + ", ".join(f"`{intent.owner}/{r}`" for r in intent.relay_token_in) + ".")
        else:
            reuse = "No sibling repo holds `DISCORD_BOT_TOKEN`: create a bot."
        steps = [f"`gh secret set {s} -R {intent.repo}`" for s in req]
        body = "\n".join([
            "## What", "",
            f"Give `{intent.repo}`'s `repo-relay` workflow a Discord bot token and a channel, so "
            "pull request, issue and release events reach Discord.", "",
            "## Why a human", "",
            "Secret values are typed by the owner. Genesis lists secret names only and never "
            "reads, prints or writes a value.", "",
            "## Exact steps", "",
            *[f"{i}. {s}" for i, s in enumerate(steps, 1)],
            f"{len(steps) + 1}. Optional: " + ", ".join(f"`{s}`" for s in opt)
            + " (each falls back to the PRs channel).", "",
            "## Secret names", "",
            "Required: " + ", ".join(f"`{s}`" for s in req) + ". Optional: "
            + ", ".join(f"`{s}`" for s in opt) + ".", "",
            "## Reuse or create", "", reuse, "",
            "## Done when", "",
            f"The `genesis-verify` rule `{entry['rule']}` reports PASS.",
        ])
    elif entry["rule"] == "overlay.kotlin.android-sdk":
        runner_dir = f"~/github-runners/actions-runner-{intent.name}"
        body = "\n".join([
            "## What", "",
            f"Install the Android SDK on the host that runs `{intent.repo}`'s self-hosted "
            "runner, and give that runner `ANDROID_HOME`, so the `kotlin` CI job's "
            "`./gradlew check` finds the SDK.", "",
            "## Why a human", "",
            "The SDK's licences are accepted on the host, and the runner's `.env` lives on "
            "the host, outside the repo. The `kotlin` job has no SDK setup step: it relies on "
            "the runner's environment, and GitHub's hosted images already carry an SDK.", "",
            "## Exact steps", "",
            "1. On the runner host, install the Android SDK command-line tools and accept the "
            "licences: `sdkmanager --licenses`.",
            "2. Install `platform-tools`, and the `platforms;android-<N>` and "
            "`build-tools;<version>` packages the Gradle build pins.",
            f"3. Make sure `{runner_dir}/.env` has the line `ANDROID_HOME=<the SDK path>`. "
            "The runner's `config.sh` writes that line itself when the shell that ran "
            "`provision-runner.sh` exported `ANDROID_HOME`; otherwise add it.",
            f"4. Restart the runner so it rereads `.env`: `cd {runner_dir} && ./svc.sh stop "
            "&& ./svc.sh start`.", "",
            "## Secret names", "",
            "None. This is a local software install, not a secret.", "",
            "## Reuse or create", "",
            "Reuse an SDK already on the host if it carries the packages the build pins: one "
            "another runner already names (`grep -h '^ANDROID_HOME=' "
            "~/github-runners/actions-runner-*/.env`), or Android Studio's at "
            "`~/Library/Android/sdk`. Otherwise install the command-line tools.", "",
            "## Done when", "",
            f"The `genesis-verify` rule `{entry['rule']}` reports PASS: the newest `kotlin` "
            "job on the default branch that ran on a self-hosted runner succeeded. The job "
            "skips until `gradlew` exists, so this closes after the first Gradle PR merges.",
        ])
    else:
        raise RenderError(f"no human-setup body renderer for rule {entry['rule']}")
    return {"kind": "human-setup", "title": title, "labels": ["human-setup"], "rule": entry["rule"], "body": body}


def applies(when, intent):
    return when == "always" or when in intent.layers()


def trigger_met(when, intent):
    """A deferred skill whose `when` this intent meets installs in the same run instead of
    staying deferred. No `when` means genesis cannot create the condition itself (a build)."""
    if when is None:
        return False
    if when == "overlay:any":
        return bool(intent.overlays)
    if when.startswith("posture:"):
        return intent.posture == when.split(":", 1)[1]
    return applies(when, intent)


def skill_sets(man, intent):
    """(install_groups, deferred_entries): the manifest's install groups, plus one final group of
    every deferred skill whose `when` this intent meets (manifest order). deferred_entries holds
    the manifest's deferred entries that were not promoted. Single source for build_plan and the
    skills.installed probe, so a promoted skill can never appear in one but not the other."""
    install_groups = [list(g) for g in man["skills"]["install"]]
    promoted = [d for d in man["skills"]["deferred"] if trigger_met(d.get("when"), intent)]
    if promoted:
        install_groups = install_groups + [[d["name"] for d in promoted]]
    deferred_entries = [d for d in man["skills"]["deferred"] if not trigger_met(d.get("when"), intent)]
    return install_groups, deferred_entries


def seed_issue_body(entry):
    """The rendered body for one seed-issue plan entry — the part after Phase 5's `## Context` /
    `Filed from:` block, which build_plan does not know here and so does not add."""
    if entry["kind"] == "human-setup":
        return entry["body"]
    return ("## Description\n\n" + entry["body"] + "\n\n## Acceptance Criteria\n\n"
            + "\n".join("- [ ] " + a for a in entry["acceptance"]))


def check_seed_title_collisions(seed, issues, epic_title):
    """Rule 10: seed titles are the resume key — unique in the file, and never a title genesis
    already plans to file some other way (the epic, or a plan['issues'] entry)."""
    plan_titles = {i["title"] for i in issues}
    seen = set()
    for e in seed["entries"]:
        t = e["title"]
        if t == epic_title:
            refuse(f"seed issues: `{t}` equals the epic title")
        if t in plan_titles:
            refuse(f"seed issues: `{t}` equals a title genesis already plans to file")
        if t in seen:
            refuse(f"seed issues: `{t}` is used by more than one entry")
        seen.add(t)


def build_plan(man, reg, intent, explicit, seed=None):
    files, values = render_files(man, reg, intent)
    labels = reg.genesis_json(man["github"]["labels"])
    n_standard_labels = len(labels)
    owner_labels = seed["owner_labels"] if seed else []
    if owner_labels:
        labels = labels + owner_labels
    ruleset = reg.genesis_json(man["github"]["ruleset"])
    install_groups, deferred_entries = skill_sets(man, intent)
    deferred = [d["name"] for d in deferred_entries]
    issues = []
    for entry in man["issues"]:
        if applies(entry["when"], intent):
            issues.append({"kind": entry["kind"], "title": render_text(entry["title"], values, "issue title"),
                           "labels": entry["labels"],
                           "description": render_text(entry["description"], values, "issue description"),
                           "acceptance": entry["acceptance"]})
    for entry in man["human_setup"]:
        if applies(entry["when"], intent):
            issues.append(human_setup_issue(man, intent, entry, values))
    if seed is not None:
        check_seed_title_collisions(seed, issues, man["epic_title"])
    seed_issues = [{"kind": e["kind"], "title": e["title"], "labels": e["labels"], "parent": e["parent"],
                    "acceptance": e["acceptance"], "body": seed_issue_body(e)}
                   for e in (seed["entries"] if seed else [])]
    machine = []
    for m in intent.modules:
        for step in man["modules"][m].get("machine", []):
            machine.append({"module": m, "phase": step["phase"],
                            "command": render_text(step["command"], values, f"{m} machine step")})
    profile_section = "\n".join([
        f"## {man['profile_section']}", "",
        "Machine-read by `genesis-verify.py` and `/project-genesis --audit` / `--add`. Written from the",
        "approved genesis plan; change it through `/project-genesis --add`, never by hand-editing the layers.",
        "",
        f"- standard: {man['standard']}",
        f"- visibility: {intent.visibility}",
        f"- overlays: {', '.join(intent.overlays) or 'none'}",
        f"- modules: {', '.join(intent.modules) or 'none'}",
        f"- app-id: {intent.app_id}",
        f"- credits-paths: {', '.join(intent.credits_paths) or 'none'}",
        f"- deferred-skills: {', '.join(deferred) or 'none'}",
        "- waivers: none",
    ])
    decisions = decisions_table(man, intent, explicit)
    writes = [
        {"kind": "machine", "target": "~/.claude/scripts/genesis-verify.py",
         "action": "bootstrap copy, only if it differs from the registry copy"},
        {"kind": "github", "target": intent.repo, "action": f"create, {intent.visibility}, --add-readme"},
        {"kind": "github", "target": "repo settings",
         "action": "squash only (PR title + body), auto-merge off, delete branch on merge, update branch on; "
                   "wiki, projects, discussions off"},
        {"kind": "github", "target": "actions",
         "action": f"all actions allowed, SHA pinning required; token read-only and cannot approve; "
                   f"no workflows from fork PRs; retention {man['github']['retention_days']} days"},
        {"kind": "github", "target": "security", "action": "Dependabot alerts and security updates on"},
        {"kind": "github", "target": "labels",
         "action": f"create/update {len(labels)}"
                   + (f" ({n_standard_labels} standard; owner: " + ", ".join(l["name"] for l in owner_labels) + ")"
                      if owner_labels else "")
                   + "; delete unused defaults " + ", ".join(man["github"]["remove_default_labels"])},
        {"kind": "github", "target": f"ruleset `{ruleset['name']}`", "action": f"create from {man['github']['ruleset']}"},
        {"kind": "issue", "target": man["epic_title"], "action": "file the epic (label epic); its body freezes this plan"},
    ]
    writes += [{"kind": "file", "target": f["path"], "action": "add in the scaffold PR (Phase 3)"} for f in files]
    n_manifest_groups = len(man["skills"]["install"])
    writes += [{"kind": "skills", "target": f"group {i}",
                "action": "/skill add " + ", ".join(g)
                          + (" (Phase 4; deferred skills whose trigger this run meets)"
                             if i > n_manifest_groups else " (Phase 4)")}
               for i, g in enumerate(install_groups, 1)]
    writes += [{"kind": "machine", "target": s["module"], "action": f"{s['command']} (Phase {s['phase']})"}
               for s in machine]
    writes += [{"kind": "issue", "target": i["title"], "action": "file under the epic ("
                + ", ".join(i["labels"]) + ")"} for i in issues]
    for e in seed_issues:
        labels_str = ", ".join(e["labels"])
        action = (f"file as a sub-issue of “{e['parent']}” ({labels_str}) — seed issue" if e["parent"]
                  else f"file from the epic ({labels_str}) — seed issue")
        writes.append({"kind": "issue", "target": e["title"], "action": action})
    seed_intent = None if seed is None else {
        "path": seed["path"], "sha256": seed["sha256"], "issues": len(seed["entries"]),
        "owner_labels": [l["name"] for l in owner_labels],
    }
    return {
        "standard": man["standard"],
        "registry": {"path": reg.path, "ref": reg.ref, "commit": reg.commit},
        "intent": {"name": intent.name, "repo": intent.repo, "visibility": intent.visibility,
                   "overlays": intent.overlays, "modules": intent.modules, "app_id": intent.app_id,
                   "posture": intent.posture, "description": intent.description,
                   "credits_paths": intent.credits_paths, "deferred_skills": deferred,
                   "relay_token_in": intent.relay_token_in, "date": intent.date,
                   "seed_issues": seed_intent},
        "decisions": decisions,
        "github": {"repo": man["github"]["repo"], "features": man["github"]["features"],
                   "actions_permissions": man["github"]["actions_permissions"],
                   "workflow_permissions": man["github"]["workflow_permissions"],
                   "fork_pr_workflows_private": man["github"]["fork_pr_workflows_private"],
                   "retention_days": man["github"]["retention_days"],
                   "vulnerability_alerts": man["github"]["vulnerability_alerts"],
                   "automated_security_fixes": man["github"]["automated_security_fixes"],
                   "labels": labels, "remove_default_labels": man["github"]["remove_default_labels"],
                   "owner_labels": [l["name"] for l in owner_labels],
                   "ruleset": ruleset},
        "epic": {"title": man["epic_title"], "labels": ["epic"]},
        "files": files,
        "profile": {"section": profile_section,
                    "posture": values["POSTURE"],
                    "posture_sections": man["skills"]["posture_sections"],
                    "merge_strategy": man["skills"]["merge_strategy"],
                    "merge_sections": man["skills"]["merge_sections"],
                    "build_commands": values["BUILD_COMMANDS"].splitlines(),
                    "labels": [l["name"] for l in labels],
                    "targets": "claude"},
        "skills": {"install": install_groups, "deferred": deferred_entries},
        "machine": machine,
        "issues": issues,
        "seed_issues": seed_issues,
        "writes": writes,
    }


def decisions_table(man, intent, explicit):
    app_overlays = [o for o in intent.overlays if man["overlays"][o].get("app")]
    rec_modules = ", ".join(m for m, s in man["modules"].items()
                            if s.get("default") and s.get("status") == "implemented")
    rec_modules += " (+ credits when media is bundled)"

    def owner_or(key, value, rec, why, named_why):
        """A value passed as a flag is the owner's decision, so the Recommendation column shows it
        rather than a default that reads as second-guessing it (#332 for Stack, #333 for the rest).
        Self-merge posture is not routed here: `withheld` is the standard's own recommendation, and
        an explicit `gated` at genesis is exactly the disagreement that column exists to show."""
        if key in explicit:
            return value, f"Named by the owner with `--{key.replace('_', '-')}`; {named_why}"
        return rec, why

    visibility = owner_or("visibility", intent.visibility, "private", "Going public is an owner decision "
                          "recorded in an ADR; genesis never flips visibility.",
                          "going public is recorded in an ADR, and genesis never flips visibility.")
    stack_value = ", ".join(intent.overlays) or "none"
    stack = owner_or("stack", stack_value, "none until an owner decision names one",
                     "Genesis never chooses a stack (Principle 7).", "genesis never chooses a stack (Principle 7).")
    modules_value = ", ".join(intent.modules) or "none"
    modules = owner_or("modules", modules_value, rec_modules, "Module defaults ratified 2026-09-26 (decision 8).",
                       f"the ratified defaults (decision 8) are {rec_modules}.")
    app_id = owner_or("app_id", intent.app_id, derive_app_id(intent.name) if app_overlays else "none",
                      "Permanent once an app is published under it.", "permanent once an app is published under it.")
    rows = [
        ("Name / scope", intent.name, "—", "Final before anything exists: the seed scope, runner "
         "directory and app ID all key off it.", "name"),
        ("Visibility", intent.visibility, *visibility, "visibility"),
        ("Stack overlays", stack_value, *stack, "stack"),
        ("Modules", modules_value, *modules, "modules"),
        ("App ID", intent.app_id, *app_id, "app_id"),
        ("Self-merge posture", intent.posture, "withheld", "Flip to gated by a profile edit after the "
         "first reviewed PRs.", "posture"),
        ("Description", intent.description or "unset", "one line", "The GitHub description and the "
         "README lead; unset renders an honest \"no description yet\".", "description"),
    ]
    if "repo-relay" in intent.modules:
        v = ("unknown" if intent.relay_token_in is None else
             ("reuse (" + ", ".join(intent.relay_token_in) + ")") if intent.relay_token_in else "create")
        rows.append(("repo-relay bot token", v, "reuse when a sibling repo holds it",
                     "Names only are probed; the owner sets values.", "relay_token_in"))
    return [{"decision": d, "value": v, "recommendation": r, "why": w, "defaulted": k not in explicit}
            for d, v, r, w, k in rows]


def _cell(v):
    """A markdown table cell: owner-supplied text (a seed issue title, an owner label name) may
    itself contain `|`, which would otherwise be read as a column break."""
    return str(v).replace("|", "\\|")


def print_plan(plan):
    it = plan["intent"]
    print(f"## Genesis plan — {it['repo']} (Standard {plan['standard']})\n")
    print(f"Registry: `{plan['registry']['path']}` @ {plan['registry']['ref']} "
          f"({plan['registry']['commit'][:7]})\n")
    print("| # | Kind | Target | Action |\n|---|------|--------|--------|")
    for i, w in enumerate(plan["writes"], 1):
        print(f"| {i} | {_cell(w['kind'])} | {_cell(w['target'])} | {_cell(w['action'])} |")
    print("\n### Decisions\n\n| Decision | Value | Recommendation | Why |\n|---|---|---|---|")
    for d in plan["decisions"]:
        value = d["value"] + (" *(default)*" if d["defaulted"] else "")
        print(f"| {_cell(d['decision'])} | {_cell(value)} | {_cell(d['recommendation'])} | {_cell(d['why'])} |")
    si = it.get("seed_issues")
    if si:
        print(f"\nSeed issues: {si['path']} · sha256 {si['sha256'][:12]} · {si['issues']} issue(s), "
              f"{len(si['owner_labels'])} owner label(s).")


# ---------------------------------------------------------------- probes

PROBES = {}


def probe(rule_id):
    def deco(fn):
        PROBES[rule_id] = fn
        return fn
    return deco


class Ctx:
    def __init__(self, man, reg, tree, intent, gh):
        self.man, self.reg, self.tree, self.intent, self.gh = man, reg, tree, intent, gh
        self._expected = None
        self._ruleset = None

    def expected(self, path):
        if self._expected is None:
            files, _ = render_files(self.man, self.reg, self.intent)
            self._expected = {f["path"]: f["content"] for f in files}
        return self._expected[path]

    def ruleset(self):
        """(doc, live detail or None)."""
        if self._ruleset is None:
            doc = self.reg.genesis_json(self.man["github"]["ruleset"])
            live = None
            for rs in self.gh.paged(f"repos/{self.intent.repo}/rulesets"):
                if rs.get("name") == doc["name"]:
                    live = self.gh.get(f"repos/{self.intent.repo}/rulesets/{rs['id']}")
                    break
            self._ruleset = (doc, live)
        return self._ruleset


def fail(msg):
    return "FAIL", msg


def ok(msg):
    return "PASS", msg


def md_file(ctx, path):
    return ctx.tree.read(path)


def h2_probe(ctx, path, ordered=True):
    text = md_file(ctx, path)
    if text is None:
        return fail(f"{path} is missing")
    req = headings(ctx.expected(path), 2)
    act = headings(text, 2)
    problems = order_problems(req, act) if ordered else [f"missing `{h}`" for h in req if h not in act]
    if problems:
        return fail(f"{path}: " + "; ".join(problems))
    return ok(f"{path}: {len(req)} headings" + (" in order" if ordered else ""))


def h1_probe(ctx, path):
    text = md_file(ctx, path)
    if text is None:
        return fail(f"{path} is missing")
    if not headings(text, 1):
        return fail(f"{path} has no H1")
    return ok(f"{path} present")


@probe("core.claude-md")
def _(ctx):
    text = md_file(ctx, "CLAUDE.md")
    if text is None:
        return fail("CLAUDE.md is missing")
    n = len(text.splitlines())
    res, ev = h2_probe(ctx, "CLAUDE.md")
    if n > 150:
        return fail(f"CLAUDE.md is {n} lines (limit 150)" + ("" if res == "PASS" else f"; {ev}"))
    return (res, f"{ev}, {n} lines") if res == "PASS" else (res, ev)


@probe("core.claude-md.floor-ids")
def _(ctx):
    text = md_file(ctx, "CLAUDE.md")
    if text is None:
        return fail("CLAUDE.md is missing")
    body = section(text, "Floor rules")
    if body is None:
        return fail("CLAUDE.md has no `## Floor rules` section")
    listed = re.findall(r"^\s*[-*+]\s+`([^`]+)`\s*$", body, re.M)
    want = ctx.reg.floor_ids()
    dups = sorted({i for i in listed if listed.count(i) > 1})
    extra, missing = sorted(set(listed) - set(want)), sorted(set(want) - set(listed))
    if dups or extra or missing:
        return fail("Floor rules differ from the registry's: "
                    + "; ".join(x for x in (f"missing {missing}" if missing else "",
                                           f"not a floor rule {extra}" if extra else "",
                                           f"duplicated {dups}" if dups else "") if x))
    return ok(f"the {len(want)} registry floor IDs")


@probe("core.claude-reference")
def _(ctx):
    return h1_probe(ctx, "docs/CLAUDE_REFERENCE.md")


@probe("core.readme")
def _(ctx):
    text = md_file(ctx, "README.md")
    if text is None:
        return fail("README.md is missing")
    if not headings(text, 1):
        return fail("README.md has no H1")
    return h2_probe(ctx, "README.md", ordered=False)


@probe("core.mission")
def _(ctx):
    return h2_probe(ctx, "MISSION.md")


@probe("core.non-goals")
def _(ctx):
    return h1_probe(ctx, "NON-GOALS.md")


ADR0001 = "docs/adr/0001-project-genesis.md"


@probe("core.adr-0001")
def _(ctx):
    text = md_file(ctx, ADR0001)
    if text is None:
        return fail(f"{ADR0001} is missing")
    fields = [f for f in ("Status", "Date", "Deciders", "Supersedes")
              if not re.search(r"^\s*[-*+]?\s*\*\*" + f + r":\*\*", text, re.M)]
    res, ev = h2_probe(ctx, ADR0001)
    if fields:
        return fail(f"{ADR0001} lacks field(s) {fields}" + ("" if res == "PASS" else f"; {ev}"))
    return res, ev


@probe("core.app-id")
def _(ctx):
    want = ctx.intent.app_id
    if want != "none" and not APP_ID.match(want):
        return fail(f"intent app-id `{want}` is not a valid Android/Apple ID")
    text = md_file(ctx, ADR0001)
    if text is None:
        return fail(f"{ADR0001} is missing, so the app ID is not reserved anywhere")
    m = re.search(r"^\|\s*App ID\s*\|\s*`?([^|`]*?)`?\s*\|", text, re.M)
    if not m:
        return fail(f"{ADR0001} has no `| App ID |` row")
    if m.group(1) != want:
        return fail(f"ADR-0001 reserves `{m.group(1)}`, the intent says `{want}`")
    return ok(f"`{want}` reserved in ADR-0001")


@probe("core.docs-layout")
def _(ctx):
    missing = [d for d in ("docs/records/", "docs/design/") if not ctx.tree.under(d)]
    return fail(f"no files under {missing}") if missing else ok("docs/records/ and docs/design/ present")


def lines_probe(ctx, path):
    text = ctx.tree.read(path)
    if text is None:
        return fail(f"{path} is missing")
    have = set(ignore_lines(text))
    missing = [ln for ln in ignore_lines(ctx.expected(path)) if ln not in have]
    if missing:
        return fail(f"{path} lacks {len(missing)} line(s): " + ", ".join(f"`{m}`" for m in missing[:6])
                    + (" …" if len(missing) > 6 else ""))
    return ok(f"{path}: all {len(ignore_lines(ctx.expected(path)))} standard lines")


@probe("core.gitignore")
def _(ctx):
    return lines_probe(ctx, ".gitignore")


@probe("core.gitattributes")
def _(ctx):
    return lines_probe(ctx, ".gitattributes")


@probe("core.issue-templates")
def _(ctx):
    problems = []
    for name in ("bug_report.md", "feature_request.md", "human_setup.md"):
        path = f".github/ISSUE_TEMPLATE/{name}"
        text = ctx.tree.read(path)
        if text is None:
            problems.append(f"{name} missing")
            continue
        if not re.search(r"^Filed from:", text, re.M):
            problems.append(f"{name} has no `Filed from:` line")
        miss = [h for h in headings(ctx.expected(path), 2) if h not in headings(text, 2)]
        if miss:
            problems.append(f"{name} lacks {miss}")
    cfg = ctx.tree.read(".github/ISSUE_TEMPLATE/config.yml")
    if cfg is None:
        problems.append("config.yml missing")
    elif not re.search(r"^blank_issues_enabled:\s*true\s*$", cfg, re.M):
        problems.append("config.yml does not keep blank issues enabled")
    return fail("; ".join(problems)) if problems else ok("bug, feature, human-setup and config present")


@probe("core.pr-template")
def _(ctx):
    path = ".github/pull_request_template.md"
    text = ctx.tree.read(path)
    if text is None:
        return fail(f"{path} is missing")
    miss = [h for h in headings(ctx.expected(path), 2) if h not in headings(text, 2)]
    if "Fixes #" not in text:
        miss.append("`Fixes #`")
    return fail(f"{path} lacks {miss}") if miss else ok("Summary, Fixes #, Test Plan")


CI = ".github/workflows/ci.yml"


def ci_jobs(ctx):
    text = ctx.tree.read(CI)
    return (None, None) if text is None else (text, workflow_jobs(text))


def runs_gradlew(body):
    """True if a `run:` step in a job body (as returned by `workflow_jobs`) invokes
    `./gradlew`: the inline value, or -- for `run: |` / `run: >` -- the block scalar's lines
    (indented deeper than the `run:` key itself). YAML comment lines and shell comment lines
    (stripped text starting with `#`) are never scanned, and a step's `name:` is a different
    key: `- name: ./gradlew check` with an unrelated `run:` does not count."""
    lines = body.splitlines()
    for i, ln in enumerate(lines):
        # `- run:` opens a step on its own line; the key's column (past the dash) is what a
        # block scalar must out-indent, so a sibling key such as the step's `name:` ends it.
        m = re.match(r"^(\s*(?:-\s+)?)run:\s*(.*?)\s*(?:\s#.*)?$", ln)
        if not m:
            continue
        key, val = len(m.group(1)), m.group(2)
        if val and not re.match(r"^[|>][0-9+-]*$", val):
            if "./gradlew" in val:
                return True
            continue
        bind = None  # the block scalar's own indent, fixed by its first line
        for nxt in lines[i + 1:]:
            if not nxt.strip():
                continue
            ni = len(nxt) - len(nxt.lstrip(" "))
            if ni <= key or (bind is not None and ni < bind):
                break
            bind = bind if bind is not None else ni
            stripped = nxt.strip()
            if not stripped.startswith("#") and "./gradlew" in stripped:
                return True
    return False


def kotlin_job_set(jobs):
    """(job_set, ungated) from ci.yml's parsed `jobs` (workflow_jobs order == ci.yml order). A
    job belongs to the Kotlin job set when it is gated on `needs.changes.outputs.kotlin` AND
    runs `./gradlew`; `ungated` lists jobs that run `./gradlew` but are not gated, so a FAIL can
    name them."""
    job_set, ungated = [], []
    for k, j in jobs.items():
        if runs_gradlew(j["body"]):
            gated = bool(j["if"]) and "needs.changes.outputs.kotlin" in j["if"]
            (job_set if gated else ungated).append(k)
    return job_set, ungated


@probe("core.ci-gate")
def _(ctx):
    text, jobs = ci_jobs(ctx)
    if text is None:
        return fail(f"{CI} is missing")
    gate = jobs.get("ci-gate")
    if gate is None:
        return fail(f"{CI} has no `ci-gate` job")
    problems = []
    cond = re.sub(r"^\$\{\{\s*(.*?)\s*\}\}$", r"\1", (gate["if"] or "").strip().strip("'\""))
    if cond != "always()":
        # `always() && …` can skip the gate, and a skipped job reports Success.
        problems.append(f"ci-gate runs `if: {gate['if']}`, not exactly `if: always()`")
    uncovered = sorted(set(jobs) - {"ci-gate"} - set(gate["needs"]))
    if uncovered:
        problems.append(f"ci-gate does not need {uncovered}")
    code = "\n".join(ln for ln in gate["body"].splitlines() if not ln.strip().startswith(("#", "//")))
    if "failure" not in code or "cancelled" not in code:
        problems.append("ci-gate does not fail on both `failure` and `cancelled`")
    return fail("; ".join(problems)) if problems else ok(f"ci-gate needs all {len(jobs) - 1} jobs")


def ci_triggers_problems(text):
    """[(kind, message), ...] behind the core.ci-triggers probe -- kinds `missing`, `no-on`,
    `inline-on`, `no-event`, `path-filter`, `push-branches` -- so the ci-mirror legacy detector
    can ask "was the workflow-level path filter the ONLY problem?" without re-deriving the
    probe's own reading. The probe below joins the messages exactly as before; no evidence text
    changes."""
    if text is None:
        return [("missing", f"{CI} is missing")]
    inline, block = on_block(text)
    if block is None:
        return [("no-on", f"{CI} has no `on:`")]
    if inline is not None:
        return [("inline-on", f"`on: {inline}` — push must be restricted to main")]
    events = {m.group(1) for ln in block for m in [re.match(r"^\s{1,4}([a-z_]+):", ln)] if m}
    problems = [("no-event", f"no `{e}` trigger") for e in ("pull_request", "push", "workflow_dispatch")
                if e not in events]
    if any(re.match(r"^\s*paths(-ignore)?:", ln) for ln in block):
        problems.append(("path-filter", "a workflow-level path filter leaves ci-gate Pending on skipped runs"))
    if "push" in events and push_branches(block) != ["main"]:
        problems.append(("push-branches",
                         f"push is not restricted to exactly `main` (branches: {push_branches(block)})"))
    return problems


@probe("core.ci-triggers")
def _(ctx):
    problems = ci_triggers_problems(ctx.tree.read(CI))
    if problems:
        return fail("; ".join(m for _, m in problems))
    return ok("pull_request, push→main, workflow_dispatch; no path filter")


@probe("core.ci-hygiene")
def _(ctx):
    text, jobs = ci_jobs(ctx)
    if text is None:
        return fail(f"{CI} is missing")
    hits = [k for k, j in jobs.items() if re.search(r"\bgit\b[^\n]*\bls-files -ci --exclude-standard", j["body"])]
    return ok(f"job `{hits[0]}`") if hits else fail("no job runs `git ls-files -ci --exclude-standard`")


@probe("core.actions-pinned")
def _(ctx):
    wfs = [p for p in ctx.tree.under(".github/workflows/") if p.endswith((".yml", ".yaml"))]
    if not wfs:
        return fail("no workflows under .github/workflows/")
    loose = []
    for p in wfs:
        for ln in ctx.tree.read(p).splitlines():
            m = USES.match(ln)
            if not m or m.group(1).startswith(("./", "docker://")):
                continue
            ref = m.group(1).rsplit("@", 1)
            if len(ref) != 2 or not SHA40.match(ref[1]):
                loose.append(f"{os.path.basename(p)}: {m.group(1)}")
    if loose:
        return fail("not SHA-pinned: " + ", ".join(loose[:5]) + (" …" if len(loose) > 5 else ""))
    return ok(f"{len(wfs)} workflow(s), every action SHA-pinned")


DEPENDABOT = ".github/dependabot.yml"


@probe("core.dependabot")
def _(ctx):
    text = ctx.tree.read(DEPENDABOT)
    if text is None:
        return fail(f"{DEPENDABOT} is missing")
    eco = dependabot_ecosystems(text)
    gha = eco.get("github-actions")
    if gha is None:
        return fail("no github-actions update entry")
    problems = []
    if not re.search(r"interval:\s*['\"]?weekly", gha):
        problems.append("github-actions is not weekly")
    if "dependencies" not in gha:
        problems.append("github-actions is not labelled `dependencies`")
    return fail("; ".join(problems)) if problems else ok("github-actions weekly, labelled dependencies")


@probe("core.claude-settings")
def _(ctx):
    text = ctx.tree.read(".claude/settings.json")
    if text is None:
        return fail(".claude/settings.json is missing")
    try:
        s = json.loads(text)
    except json.JSONDecodeError:
        return fail(".claude/settings.json is not valid JSON")
    if not isinstance(s, dict):
        return fail(".claude/settings.json is not a JSON object")
    att = s.get("attribution")
    problems = []
    if not isinstance(att, dict) or att.get("commit") != "" or att.get("pr") != "":
        problems.append('`attribution` is not {"commit": "", "pr": ""}')
    if s.get("includeCoAuthoredBy") is not False:
        problems.append("`includeCoAuthoredBy` is not false")
    return fail("; ".join(problems)) if problems else ok("attribution off")


PROFILE = ".claude/skill-profile.md"


@probe("profile.genesis-intent")
def _(ctx):
    if ctx.intent.source != "profile":
        return fail(f"no committed intent ({ctx.intent.problems[0] if ctx.intent.problems else 'absent'})")
    problems = list(ctx.intent.problems)
    lock = skills_lock(ctx)
    installed = set(lock) if isinstance(lock, dict) else set()
    listed = set(ctx.intent.deferred or [])
    unaccounted = [d["name"] for d in ctx.man["skills"]["deferred"]
                   if d["name"] not in listed and d["name"] not in installed]
    if unaccounted:
        problems.append(f"deferred skills neither listed nor installed: {unaccounted}")
    if problems:
        return fail("; ".join(problems))
    return ok(f"standard {ctx.man['standard']}; overlays {ctx.intent.overlays or 'none'}; "
              f"modules {ctx.intent.modules or 'none'}")


@probe("profile.repo-wide")
def _(ctx):
    text = ctx.tree.read(PROFILE)
    if text is None:
        return fail(f"{PROFILE} is missing")
    have = headings(text, 2)
    miss = [h for h in ("Project Context", "Build / Test Commands", "Conventions") if h not in have]
    if not re.search(r"^\s*targets:\s*\S", text, re.M):
        miss.append("a `targets:` line")
    return fail(f"profile lacks {miss}") if miss else ok("repo-wide sections and targets present")


def posture_pins(text, man):
    """(got, problems): got maps posture section name -> "Withheld"/"Gated" pin, for every
    section the standard pins posture in. problems names each missing section, missing pin
    or disagreement — the same failures the profile.posture probe reports."""
    got, problems = {}, []
    for s in man["skills"]["posture_sections"]:
        body = section(text, f"{s} Customizations")
        if body is None:
            problems.append(f"no `## {s} Customizations`")
            continue
        blk = re.search(r"^#{3,4}[ \t]+Self-merge posture[ \t]*$(.*?)(?=^#{1,6}[ \t]|\Z)", body, re.M | re.S)
        lead = POSTURE_LEAD.search(blk.group(1)) if blk else None
        if not lead:
            problems.append(f"`{s}` has no `### Self-merge posture` bold lead")
        else:
            got[s] = lead.group(1)
    if not problems and len(set(got.values())) > 1:
        problems.append(f"the posture pins disagree: {got}")
    return got, problems


@probe("profile.posture")
def _(ctx):
    text = ctx.tree.read(PROFILE)
    if text is None:
        return fail(f"{PROFILE} is missing")
    got, problems = posture_pins(text, ctx.man)
    return fail("; ".join(problems)) if problems else ok(f"{next(iter(got.values()))} in "
                                                        + " and ".join(got))


@probe("profile.merge-strategy")
def _(ctx):
    text = ctx.tree.read(PROFILE)
    if text is None:
        return fail(f"{PROFILE} is missing")
    problems = []
    for s in ("merge", "batch-merge"):
        body = section(text, f"{s} Customizations")
        if body is None or "--squash" not in body:
            problems.append(f"`{s}` does not pin `--squash`")
    return fail("; ".join(problems)) if problems else ok("merge and batch-merge pin --squash")


def skills_lock(ctx):
    text = ctx.tree.read(".claude/skills.lock")
    if text is None:
        return None
    try:
        return json.loads(text).get("skills", {})
    except (json.JSONDecodeError, AttributeError):
        return "invalid"


@probe("skills.installed")
def _(ctx):
    lock = skills_lock(ctx)
    if lock is None:
        return fail(".claude/skills.lock is missing")
    if lock == "invalid":
        return fail(".claude/skills.lock is not valid JSON")
    want = [s for g in skill_sets(ctx.man, ctx.intent)[0] for s in g]
    missing = [s for s in want if s not in lock]
    no_cmd = [s for s in want if s in lock and not ctx.tree.has(f".claude/commands/{s}.md")]
    problems = ([f"not in skills.lock: {missing}"] if missing else []) + \
               ([f"no .claude/commands file: {no_cmd}"] if no_cmd else [])
    return fail("; ".join(problems)) if problems else ok(f"all {len(want)} install-set skills")


def settings_probe(ctx, want, got, what):
    if not isinstance(got, dict):
        raise CannotVerify(f"{what}: the API returned {type(got).__name__}, not an object")
    absent = [k for k in want if k not in got or got[k] is None]
    if absent:
        # GitHub omits these for a caller without admin rights; that is not a violation.
        raise CannotVerify(f"{what}: the API did not return {absent} (does this token have admin on the repo?)")
    diff = [f"{k}={got.get(k)!r} (want {v!r})" for k, v in want.items() if got.get(k) != v]
    return fail(f"{what}: " + ", ".join(diff)) if diff else ok(f"{what} as standard")


def live_visibility(info):
    """The visibility GitHub reports for the repo. One reading for both probes that ask: a public
    repo that github.fork-pr-workflows reads N-A is the one github.visibility judges (#353)."""
    return "private" if info.get("private") else info.get("visibility", "public")


@probe("github.visibility")
def _(ctx):
    live = live_visibility(ctx.gh.repo_info())
    if live != ctx.intent.visibility:
        return fail(f"the repo is {live}; the intent says {ctx.intent.visibility}")
    return ok(live)


@probe("github.merge-settings")
def _(ctx):
    return settings_probe(ctx, ctx.man["github"]["repo"], ctx.gh.repo_info(), "merge settings")


@probe("github.features")
def _(ctx):
    return settings_probe(ctx, ctx.man["github"]["features"], ctx.gh.repo_info(), "features")


@probe("github.actions")
def _(ctx):
    got = ctx.gh.get(f"repos/{ctx.intent.repo}/actions/permissions")
    return settings_probe(ctx, ctx.man["github"]["actions_permissions"], got, "actions permissions")


@probe("github.workflow-token")
def _(ctx):
    got = ctx.gh.get(f"repos/{ctx.intent.repo}/actions/permissions/workflow")
    return settings_probe(ctx, ctx.man["github"]["workflow_permissions"], got, "workflow token")


@probe("github.fork-pr-workflows")
def _(ctx):
    # The rule is the private-repo policy, and GitHub refuses its endpoint for a public repo
    # (HTTP 422). Only repo_info decides public: a 422 on a private repo stays an ERROR.
    if live_visibility(ctx.gh.repo_info()) == "public":
        return "N-A", ("the repo is public, so the private-repo fork-PR policy does not apply; fork-PR "
                       "approval for a public repo is the planned public bundle (blamechris/skill-templates#312)")
    got = ctx.gh.get(f"repos/{ctx.intent.repo}/actions/permissions/fork-pr-workflows-private-repos")
    return settings_probe(ctx, ctx.man["github"]["fork_pr_workflows_private"], got, "fork-PR workflows")


@probe("github.retention")
def _(ctx):
    got = ctx.gh.get(f"repos/{ctx.intent.repo}/actions/permissions/artifact-and-log-retention")
    want = ctx.man["github"]["retention_days"]
    return ok(f"{want} days") if got.get("days") == want else fail(f"retention is {got.get('days')} days (want {want})")


@probe("github.security")
def _(ctx):
    if not ((ctx.gh.repo_info().get("permissions") or {}).get("admin")):
        # Both endpoints 404 for a non-admin caller, which would read as "off".
        raise CannotVerify("reading Dependabot settings needs admin on the repo; this token lacks it")
    alerts = ctx.gh.get(f"repos/{ctx.intent.repo}/vulnerability-alerts", missing_ok=True)
    fixes = ctx.gh.get(f"repos/{ctx.intent.repo}/automated-security-fixes", missing_ok=True)
    # GET returns 200 {"enabled": bool, "paused": bool} (live, 2026-09-26). A body without
    # `enabled` (an empty 204, a changed API) says nothing either way: could not verify.
    if fixes is not None and not isinstance((fixes or {}).get("enabled"), bool):
        raise CannotVerify("automated-security-fixes returned no `enabled` field; cannot tell on from off")
    problems = []
    if alerts is None:
        problems.append("Dependabot alerts are off")
    if not (fixes or {}).get("enabled"):
        problems.append("Dependabot security updates are off")
    return fail("; ".join(problems)) if problems else ok("alerts and security updates on")


@probe("github.labels")
def _(ctx):
    want = ctx.reg.genesis_json(ctx.man["github"]["labels"])
    live = {l["name"]: l.get("color", "").lower() for l in ctx.gh.paged(f"repos/{ctx.intent.repo}/labels")}
    missing = [l["name"] for l in want if l["name"] not in live]
    recolored = [l["name"] for l in want if l["name"] in live and live[l["name"]] != l["color"].lower()]
    problems = ([f"missing {missing}"] if missing else []) + ([f"wrong colour {recolored}"] if recolored else [])
    # Extra labels never FAIL (owner labels are legitimate), but they are named: a GitHub
    # default the manifest does not know to delete is otherwise invisible (#323).
    other = sorted(n for n in live if n not in {l["name"] for l in want})
    note = (f"; also present: {', '.join(other[:8])}" + (f" (+{len(other) - 8} more)" if len(other) > 8 else "")
            if other else "")
    return fail("; ".join(problems) + note) if problems else ok(f"all {len(want)} seed labels{note}")


def rule_param_problems(doc_rule, live_rule):
    problems = []
    for k, v in (doc_rule.get("parameters") or {}).items():
        lv = (live_rule.get("parameters") or {}).get(k)
        if k == "required_status_checks":
            norm = lambda xs: sorted((str(c.get("context")), c.get("integration_id") or -1) for c in (xs or []))
            if norm(lv) != norm(v):
                problems.append(f"{doc_rule['type']}.{k}={norm(lv)} (want {norm(v)})")
        elif isinstance(v, list):
            if sorted(lv or []) != sorted(v):
                problems.append(f"{doc_rule['type']}.{k}={lv} (want {v})")
        elif lv != v:
            problems.append(f"{doc_rule['type']}.{k}={lv!r} (want {v!r})")
    return problems


@probe("github.ruleset")
def _(ctx):
    doc, live = ctx.ruleset()
    if live is None:
        return fail(f"no ruleset named `{doc['name']}`")
    problems = [f"{k}={live.get(k)!r} (want {doc[k]!r})" for k in ("target", "enforcement") if live.get(k) != doc[k]]
    ref_name = (live.get("conditions") or {}).get("ref_name") or {}
    inc, exc = ref_name.get("include") or [], ref_name.get("exclude") or []
    if not set(doc["conditions"]["ref_name"]["include"]) <= set(inc):
        problems.append(f"ref_name.include={inc} (want {doc['conditions']['ref_name']['include']})")
    if set(exc) != set(doc["conditions"]["ref_name"]["exclude"]):
        problems.append(f"ref_name.exclude={exc} (want {doc['conditions']['ref_name']['exclude']})")
    by_type = {r.get("type"): r for r in live.get("rules") or []}
    for r in doc["rules"]:
        if r["type"] not in by_type:
            problems.append(f"no `{r['type']}` rule")
        else:
            problems += rule_param_problems(r, by_type[r["type"]])
    if problems:
        return fail("; ".join(problems))
    return ok(f"ruleset `{doc['name']}` (id {live.get('id')}) carries all {len(doc['rules'])} rules")


@probe("github.ruleset.no-bypass")
def _(ctx):
    doc, live = ctx.ruleset()
    if live is None:
        return fail(f"no ruleset named `{doc['name']}`")
    bypass = live.get("bypass_actors") or []
    if bypass:
        return fail(f"{len(bypass)} bypass actor(s): " + ", ".join(
            f"{b.get('actor_type')}:{b.get('actor_id')}" for b in bypass))
    return ok("no bypass actors")


@probe("github.epic")
def _(ctx):
    title = ctx.man["epic_title"]
    hits = [i for i in ctx.gh.paged(f"repos/{ctx.intent.repo}/issues?labels=epic&state=all")
            if i.get("title") == title]
    return ok(f"#{hits[0]['number']} ({hits[0].get('state')})") if hits else fail(f"no `epic` issue titled `{title}`")


@probe("module.runner-mac")
def _(ctx):
    runners = ctx.gh.paged(f"repos/{ctx.intent.repo}/actions/runners", key="runners")
    if not runners:
        return fail("no self-hosted runner is registered on the repo")
    return ok(", ".join(f"{r.get('name')} ({r.get('status')})" for r in runners[:3]))


@probe("module.repo-memory")
def _(ctx):
    text = ctx.tree.read(".mcp.json")
    if text is None:
        return fail(".mcp.json is missing")
    try:
        srv = (json.loads(text).get("mcpServers") or {}).get("repo-memory")
    except (json.JSONDecodeError, AttributeError):
        return fail(".mcp.json is not valid JSON")
    if not isinstance(srv, dict) or srv.get("command") != "npx" or "@blamechris/repo-memory" not in (srv.get("args") or []):
        return fail(".mcp.json has no `repo-memory` stdio server running `npx … @blamechris/repo-memory`")
    return ok("repo-memory declared")


RELAY = ".github/workflows/repo-relay.yml"


@probe("module.repo-relay.workflow")
def _(ctx):
    text = ctx.tree.read(RELAY)
    if text is None:
        return fail(f"{RELAY} is missing")
    uses = [m.group(1) for ln in text.splitlines() for m in [USES.match(ln)] if m
            and m.group(1).startswith("blamechris/repo-relay@")]
    if not uses:
        return fail(f"{RELAY} does not use blamechris/repo-relay")
    if not all(SHA40.match(u.split("@", 1)[1]) for u in uses):
        return fail(f"{RELAY} does not pin blamechris/repo-relay to a SHA")
    return ok(uses[0])


@probe("module.repo-relay.secrets")
def _(ctx):
    names = {s.get("name") for s in ctx.gh.paged(f"repos/{ctx.intent.repo}/actions/secrets", key="secrets")}
    missing = [s for s in ctx.man["modules"]["repo-relay"]["secrets"] if s not in names]
    return fail(f"secret(s) not set: {missing}") if missing else ok("required secret names present")


@probe("module.credits.file")
def _(ctx):
    text = ctx.tree.read("CREDITS.md")
    if text is None:
        return fail("CREDITS.md is missing")
    head = re.search(r"^\|\s*Path\s*\|\s*Source\s*\|\s*Licen[cs]e\s*\|\s*Credit string\s*\|", text, re.M)
    return ok("CREDITS.md table present") if head else fail("CREDITS.md has no Path/Source/Licence/Credit string table")


@probe("module.credits.coverage")
def _(ctx):
    if not ctx.intent.credits_paths:
        return "N-A", "no `credits-paths:` declared yet"
    text = ctx.tree.read("CREDITS.md") or ""
    rows = {norm_repo_path(m.group(1)) for m in re.finditer(r"^\|\s*([^|]+?)\s*\|", text, re.M)}
    assets, empty = [], []
    for d in ctx.intent.credits_paths:
        hit = [d] if ctx.tree.has(d) else ctx.tree.under(d + "/") if d else []
        (assets.extend(hit) if hit else empty.append(d))
    if empty:
        return fail(f"credits-paths {empty} match no tracked file — a typo, or declared before any asset landed")
    missing = [p for p in assets if p not in rows]
    if missing:
        return fail(f"{len(missing)} asset(s) without a CREDITS.md row: " + ", ".join(missing[:5])
                    + (" …" if len(missing) > 5 else ""))
    return ok(f"{len(assets)} asset(s), every one credited")


@probe("overlay.kotlin.ci")
def _(ctx):
    text, jobs = ci_jobs(ctx)
    if text is None:
        return fail(f"{CI} is missing")
    changes = jobs.get("changes")
    job_set, ungated = kotlin_job_set(jobs)
    problems = []
    if not job_set:
        msg = "no job gated on `needs.changes.outputs.kotlin` runs `./gradlew`"
        if ungated:
            msg += " (ungated: [" + ", ".join(f"`{k}`" for k in ungated) + "])"
        problems.append(msg)
    if changes is None or not re.search(r"^\s*kotlin:\s*\$\{\{\s*steps\.", changes["body"], re.M):
        problems.append("no `changes` job output `kotlin`")
    if problems:
        return fail("; ".join(problems))
    names = ", ".join(f"`{jobs[k]['name']}`" for k in job_set)
    return ok(f"Gradle job(s) {names} gated on changes.kotlin")


@probe("overlay.kotlin.dependabot")
def _(ctx):
    text = ctx.tree.read(DEPENDABOT)
    if text is None:
        return fail(f"{DEPENDABOT} is missing")
    return ok("gradle ecosystem") if "gradle" in dependabot_ecosystems(text) else fail("no gradle update entry")


@probe("overlay.kotlin.app-id")
def _(ctx):
    found = {}
    for p in ctx.tree.files:
        if os.path.basename(p) in ("build.gradle", "build.gradle.kts"):
            for m in re.finditer(r"\bapplicationId\s*=?\s*[\"']([^\"']+)[\"']", ctx.tree.read(p) or ""):
                found.setdefault(m.group(1), []).append(p)
    if not found:
        return "N-A", "no applicationId in any Gradle build file yet"
    want = ctx.intent.app_id
    others = sorted(k for k in found if k != want)
    not_sub = [k for k in others if not k.startswith(want + ".")]
    problems = []
    if want not in found:
        problems.append(f"no applicationId equals the intent's `{want}` (found {sorted(found)})")
    if not_sub:
        problems.append(f"applicationId {not_sub} is not a sub-namespace of `{want}`")
    if problems:
        return fail("; ".join(problems))
    sub = [k for k in others if k.startswith(want + ".")]
    return ok(f"applicationId `{want}`" + (f"; sub-namespaces {sub}" if sub else ""))


# The SDK probe walks completed ci.yml runs on the default branch newest-first, a page at a
# time, to the first decisive self-hosted result from a candidate job; reading every run
# without one is a FAIL. Candidates are the Kotlin job set's display names in the audited
# ci.yml (a repo may have split the scaffold's single `kotlin` job into several, each gated on
# changes.kotlin and running `./gradlew`), plus the manifest's legacy `kotlin` name so runs
# from before such a split still count. A finished run with no candidate job never ends the
# walk (a bad merge can drop the job for one push), but at SDK_RUN_BOUND runs it decides: if
# the oldest finished run read has no candidate job, the job's history ends inside the window
# (FAIL, the `--add overlay:kotlin` shape). Otherwise the bound is an ERROR, not a FAIL: a
# quiet non-Kotlin stretch ages the evidence out without breaking anything, and a FAIL would
# have `--audit --file-issues` file a redo of a done human step. A closed human-setup issue is
# not read as proof instead: progress is probed, never stored (#331).
SDK_RUN_PAGE = 20    # completed runs requested per page
SDK_RUN_BOUND = 100  # the most runs the probe reads, across all pages


@probe("overlay.kotlin.android-sdk")
def _(ctx):
    _, wf_jobs = ci_jobs(ctx)
    job_set, _ = kotlin_job_set(wf_jobs or {})
    candidates = []
    for k in job_set:
        nm = wf_jobs[k]["name"]
        if nm not in candidates:
            candidates.append(nm)
    legacy = ctx.man["overlays"]["kotlin"]["ci_job"]
    if legacy not in candidates:
        candidates.append(legacy)
    name_set = "/".join(f"`{c}`" for c in candidates)
    branch = ctx.gh.repo_info().get("default_branch")
    if not branch:
        raise CannotVerify(f"repos/{ctx.intent.repo} returned no default_branch")
    wf_file = posixpath.basename(CI)
    endpoint = f"repos/{ctx.intent.repo}/actions/workflows/{wf_file}/runs"
    qbranch = urllib.parse.quote(branch, safe="")
    seen, page = 0, 1
    in_gap, gap_run_id = False, None  # did the oldest finished run read so far lack the job?
    while True:
        runs = ctx.gh.get(
            f"{endpoint}?branch={qbranch}&status=completed&per_page={SDK_RUN_PAGE}&page={page}",
            missing_ok=(page == 1),
        )
        if runs is None:
            return fail(f"GitHub has no {wf_file} workflow, so the {name_set} job has never run")
        wf = runs.get("workflow_runs")
        if not isinstance(wf, list):
            raise CannotVerify(f"{endpoint} did not return workflow_runs")
        page_len = len(wf)
        for run in wf[:SDK_RUN_BOUND - seen]:  # never read past the bound, even mid-page
            seen += 1
            run_jobs = ctx.gh.paged(f"repos/{ctx.intent.repo}/actions/runs/{run['id']}/jobs", key="jobs")
            found_job = False
            succeeded, failed = [], []
            for job in run_jobs:
                if job.get("name") not in candidates:
                    continue
                found_job = True
                labels = {str(l).lower() for l in (job.get("labels") or [])}
                if "self-hosted" not in labels:
                    continue
                conclusion = job.get("conclusion")
                if conclusion == "success":
                    succeeded.append(job)
                elif conclusion == "failure":
                    failed.append(job)
                # skipped, cancelled, None, ... — not decisive; keep walking
            if failed or succeeded:
                hit = failed[0] if failed else succeeded[0]
                runner = hit.get("runner_name") or "a self-hosted runner"
                sha = (run.get("head_sha") or "")[:7]
                where = f"{runner}, run {run['id']} ({sha})"
                listed = lambda js: ", ".join(f"`{j.get('name')}`" for j in js)
                if failed and succeeded:
                    # A failure wins even beside a success: ci.yml cannot say which candidate
                    # needs the SDK, and a JVM-only job's success standing in for it would be a
                    # false PASS. The sibling's success is named, so the finding (which
                    # `--file-issues` files verbatim) is not read as an SDK fault.
                    return fail(f"{listed(failed)} failed on {where}, while {listed(succeeded)} "
                                "succeeded in the same run — only `SDK location not found` in the "
                                "failed job's log means the runner's .env has no ANDROID_HOME")
                if failed:
                    return fail(f"{listed(failed)} failed on {where} — `SDK location not found` in "
                                "its log means the runner's .env has no ANDROID_HOME")
                return ok(f"{listed(succeeded)} succeeded on {where}")
            if run_jobs and run.get("conclusion") in ("success", "failure"):
                # only a finished run evaluated every job, so only it can show the job absent
                in_gap, gap_run_id = not found_job, run["id"]
        # History that happens to end exactly at the bound is not detected: it reads as an
        # ERROR (or the gap's FAIL) rather than the short-page FAIL below. That is the safe side.
        if seen >= SDK_RUN_BOUND:
            if in_gap:
                return fail(f"none of the newest {seen} completed {wf_file} runs on {branch} ran "
                            f"{name_set} to a result on a self-hosted runner, and the oldest of "
                            f"them predate the job (run {gap_run_id} has none)")
            raise CannotVerify(
                f"none of the newest {seen} completed {wf_file} runs on {branch} ran {name_set} "
                "to a result on a self-hosted runner, and the probe reads no further back: the SDK "
                f"is unverified, not failed — the next change that runs {name_set} re-probes it"
            )
        if page_len < SDK_RUN_PAGE:
            return fail(f"none of the {seen} completed {wf_file} run(s) on {branch} ran {name_set} "
                        "to a result on a self-hosted runner (it skips until `gradlew` exists)")
        page += 1


# ---------------------------------------------------------------- legacy shapes (#313)
#
# The back-port audit (standard §10.4): a FAIL row a known pre-standard shape fully explains, on
# a repo with no committed genesis intent, reclassifies to LEGACY -- a finding, not an exemption
# (see the module docstring). Each shape is registered with the manifest rule ids its detector
# can explain; `classify_legacy` is `run_verify`'s hook, symmetric with `classify_drift`.

LEGACY_SHAPES = {}


def legacy_shape(shape_id, title, ref, rules):
    """Registers a known pre-standard shape: `rules` are the manifest rule ids its detector can
    explain, each via `detect(ctx, rid) -> str | None` -- a string is the shape's evidence for
    that row ("explained"), None means "not this shape, not this row". `title` is used verbatim
    in filed issue titles (`legacy: <title>`), so it carries no `§`."""
    def deco(fn):
        LEGACY_SHAPES[shape_id] = {"id": shape_id, "title": title, "ref": ref, "rules": rules, "detect": fn}
        return fn
    return deco


def event_block(block, event):
    """The lines under `<event>:` in an `on:` block (on_block's second element) -- the same
    indentation-aware slice push_branches takes for `push:`. Anchored on `<event>:` at the end of
    the line, so a lookup for `pull_request` never matches a `pull_request_target:` sibling."""
    idx = next((i for i, ln in enumerate(block) if re.match(r"^\s+['\"]?" + re.escape(event) + r"['\"]?:\s*(#.*)?$", ln)), None)
    if idx is None:
        return None
    indent = len(block[idx]) - len(block[idx].lstrip())
    body = []
    for ln in block[idx + 1:]:
        if ln.strip() and len(ln) - len(ln.lstrip()) <= indent:
            break
        body.append(ln)
    return body


def path_filters(event_lines):
    """{"paths": [...], "paths-ignore": [...]} for whichever of the two keys an event block sets:
    block or inline flow lists, quotes and trailing comments stripped."""
    out = {}
    for i, ln in enumerate(event_lines):
        m = re.match(r"^(\s*)['\"]?(paths|paths-ignore)['\"]?:\s*(.*?)\s*(?:\s#.*)?$", ln)
        if not m:
            continue
        indent, key, val = len(m.group(1)), m.group(2), m.group(3)
        if val.startswith("["):
            out[key] = [x.strip().strip("'\"") for x in val.strip("[]").split(",") if x.strip()]
            continue
        items = []
        for nxt in event_lines[i + 1:]:
            if not nxt.strip() or nxt.strip().startswith("#"):
                continue
            item = re.match(r"^(\s*)-\s*(.+?)\s*(?:\s#.*)?$", nxt)
            # An item may sit at the key's own indent (YAML's indentless sequence); a key does not.
            if not item or len(item.group(1)) < indent:
                break
            items.append(item.group(2).strip("'\""))
        out[key] = items
    return out


def flow_filters(node):
    """{"paths": [...], "paths-ignore": [...]} from a parsed flow `pull_request` value."""
    out = {}
    if isinstance(node, dict):
        for k in ("paths", "paths-ignore"):
            v = node.get(k)
            if isinstance(v, list):
                out[k] = [x for x in v if isinstance(x, str)]
            elif isinstance(v, str):
                out[k] = [v]
    return out


def wf_pull_request(text):
    """(triggers_on_pull_request, path_filters) for one workflow's `on:`. All four YAML shapes
    count: a block mapping (the key may be quoted, its value a block or an inline flow mapping),
    a block sequence (`- pull_request`, also at column 0), an inline list or bare scalar (items
    may be quoted), and a flow mapping (`on: {pull_request: {paths: [...]}}`, possibly spread
    over lines). Only the mapping shapes can carry a path filter. Text that cannot be read reads
    as "does not trigger" -- the safe direction, the row stays FAIL."""
    inline, block = on_section(text)
    if inline is not None:
        try:
            node = parse_flow(inline)
        except ValueError:
            return False, {}
        if isinstance(node, dict):
            return "pull_request" in node, flow_filters(node.get("pull_request"))
        return "pull_request" in (node if isinstance(node, list) else [node]), {}
    if block is None:
        return False, {}
    body = [ln for ln in block if ln.strip() and not ln.lstrip().startswith("#")]
    if body and body[0].lstrip().startswith("- "):
        items = [strip_comment(ln.lstrip()[2:]).strip("'\"") for ln in body if ln.lstrip().startswith("- ")]
        return "pull_request" in items, {}
    pr = event_block(block, "pull_request")
    if pr is not None:
        return True, path_filters(pr)
    for ln in block:
        m = re.match(r"^\s+['\"]?pull_request['\"]?:\s*(\S.*?)\s*$", ln)
        if m:
            try:
                return True, flow_filters(parse_flow(strip_comment(m.group(1))))
            except ValueError:
                return True, {}
    return False, {}


SKIP_CI_TAG = re.compile(r"\b(skip-ci|ci-skip)\b")  # native `[skip ci]` (a space) never matches


def ci_mirror_evidence(ctx):
    """None, or evidence for the rejected shape (§4.4): a check a path-skipped workflow never
    reports is posted instead by a sibling that runs exactly when it is skipped. The pair must be
    COMPLEMENTARY -- one workflow skips pull_request on `paths-ignore` patterns the other runs on
    (`paths`), at least one pattern shared -- so independent per-area workflows that merely reuse
    a job name (a monorepo's `backend/**` and `frontend/**` each running `test`) are not a mirror.
    A name that is a `needs:` target of another job in EVERY pull_request workflow defining it is
    a shared helper (e.g. `decide_runner`), not a mirrored check. The `[skip-ci]`/`[ci-skip]`
    title tag, anywhere in the workflows, is supporting evidence, never a trigger on its own."""
    wfs = [p for p in ctx.tree.under(".github/workflows/") if p.endswith((".yml", ".yaml"))]
    texts = {p: ctx.tree.read(p) for p in wfs}
    prs = []  # (path, jobs, path_filters) for every workflow that triggers on pull_request
    for p, text in texts.items():
        if text is None:
            continue
        triggers, filters = wf_pull_request(text)
        if triggers:
            prs.append((p, workflow_jobs(text), filters))
    if len(prs) < 2:
        return None

    by_name = {}  # check name -> {workflow path: its pull_request path filters}
    for p, jobs, filters in prs:
        for j in jobs.values():
            by_name.setdefault(j["name"], {})[p] = filters

    def complementary(hits):
        """(skipping, standing-in) workflow pairs among one name's workflows."""
        return sorted((a, b) for a, fa in hits.items() for b, fb in hits.items()
                      if a != b and set(fa.get("paths-ignore") or ()) & set(fb.get("paths") or ()))

    def needed_everywhere(name):
        defining = [jobs for _, jobs, _ in prs if any(j["name"] == name for j in jobs.values())]
        for jobs in defining:
            keys = {k for k, j in jobs.items() if j["name"] == name}
            if not any(set(j2["needs"]) & keys for k2, j2 in jobs.items() if k2 not in keys):
                return False
        return True

    mirrored = {}
    for name, hits in by_name.items():
        pairs = complementary(hits)
        if pairs and not needed_everywhere(name):
            mirrored[name] = pairs
    if not mirrored:
        return None

    names = sorted(mirrored)
    shown, more = names[:6], names[6:]
    listed = [f"`{n}` (" + ", ".join(f"{posixpath.basename(a)} / {posixpath.basename(b)}"
                                     for a, b in mirrored[n]) + ")" for n in shown]
    ev = ("check name(s) posted by a complementary pair, the first workflow skipping pull_request "
          "on `paths-ignore` patterns the second runs on (`paths`), so one side always reports: "
          + ", ".join(listed) + (f" (+{len(more)} more)" if more else ""))

    tagged = sorted({posixpath.basename(p) for p, text in texts.items() if text is not None
                     for ln in text.splitlines()
                     if ln.strip() and not ln.strip().startswith("#") and SKIP_CI_TAG.search(ln)})
    if tagged:
        t_shown, t_more = tagged[:6], tagged[6:]
        ev += (f"; a [skip-ci]/[ci-skip] title tag in {len(tagged)} workflow(s) ("
               + ", ".join(t_shown) + (f" +{len(t_more)} more" if t_more else "")
               + "): a skipped required job reports Success")
    return ev


@legacy_shape("ci-mirror", "path-filtered auto-pass CI mirror", "§4.4", ["core.ci-gate", "core.ci-triggers"])
def _(ctx, rid):
    mirror = ci_mirror_evidence(ctx)
    if mirror is None:
        return None
    if rid == "core.ci-gate":
        text = ctx.tree.read(CI)
        if text is not None and "ci-gate" in workflow_jobs(text):
            return None  # ci-gate exists (even malformed); the mirror does not explain that
    else:  # core.ci-triggers: explained only when the sole problem is the path filter
        kinds = {k for k, _ in ci_triggers_problems(ctx.tree.read(CI))}
        if kinds not in ({"path-filter"}, {"missing"}):
            return None
    return mirror


@legacy_shape("classic-protection", "classic branch protection instead of a ruleset", "§4.3",
              ["github.ruleset", "github.ruleset.no-bypass"])
def _(ctx, rid):
    """The rejected shape (§4.3): no `main` ruleset, the default branch governed instead by
    GitHub's older classic branch protection. The migration adopts ruleset-main.json wholesale, so the classic
    protection's own content gaps (missing required checks, zero required approvals, ...) do not
    block LEGACY -- they are named in the evidence instead, for the owner to weigh."""
    _, live = ctx.ruleset()
    if live is not None:
        return None  # a ruleset named `main` exists: this is not the classic-protection shape
    branch = ctx.gh.repo_info().get("default_branch")
    if not branch:
        raise CannotVerify(f"repos/{ctx.intent.repo} returned no default_branch")
    prot = ctx.gh.get(f"repos/{ctx.intent.repo}/branches/{urllib.parse.quote(branch, safe='')}/protection",
                      missing_ok=True)
    if prot is None:
        return None  # no ruleset AND no classic protection either: an unexplained FAIL
    if not isinstance(prot, dict):
        raise CannotVerify(f"branch protection for {branch!r} returned {type(prot).__name__}, not an object")
    admins_on = bool((prot.get("enforce_admins") or {}).get("enabled"))
    if rid == "github.ruleset.no-bypass":
        return (f"classic protection on `{branch}`, enforce_admins "
                + ("on: admins cannot bypass it" if admins_on else "off: admins bypass it"))
    rspc = prot.get("required_status_checks") or {}
    contexts = rspc.get("contexts")
    if not contexts:
        checks = rspc.get("checks")
        contexts = [c.get("context") for c in checks] if isinstance(checks, list) else None
    approvals = (prot.get("required_pull_request_reviews") or {}).get("required_approving_review_count")
    force = bool((prot.get("allow_force_pushes") or {}).get("enabled"))
    deletions = bool((prot.get("allow_deletions") or {}).get("enabled"))
    conv = bool((prot.get("required_conversation_resolution") or {}).get("enabled"))
    return (f"classic protection on `{branch}`: required checks {contexts or 'none'}, "
            f"approvals {approvals if approvals is not None else 'none required'}, "
            f"enforce_admins {'on' if admins_on else 'off'}, "
            f"force pushes {'allowed' if force else 'blocked'}, "
            f"deletions {'allowed' if deletions else 'blocked'}, "
            f"conversation resolution {'on' if conv else 'off'}")


# The third shape is repo-level (standard §6: one checkout, no stub), reported by main()'s
# --repo preflight as its own row -- never by a rule's probe -- so it carries no rules here. Its
# metadata is still registered here, so a title lives in exactly one place.
LEGACY_SHAPES["non-git-stub"] = {"id": "non-git-stub", "title": "non-git stub instead of a checkout",
                                 "ref": "§6", "rules": [], "detect": None}


def classify_legacy(rid, evidence, ctx):
    """(result, evidence, shape_id) for a row that FAILed with no committed genesis intent
    (ctx.intent.source == "flags"). Tries every shape naming `rid`; the first whose detector
    explains this row's WHOLE failure reclassifies it LEGACY, keeping the probe's own evidence
    text alongside the shape's. A detector that raises (including CannotVerify from a `gh` call)
    degrades the row to FAIL with a could-not-run note -- the same shape as classify_drift's own
    crash handling -- rather than propagating, so one shape's outage never blocks another rule's
    verdict and never turns a row into ERROR."""
    for shape_id, spec in LEGACY_SHAPES.items():
        if rid not in spec["rules"]:
            continue
        try:
            found = spec["detect"](ctx, rid)
        except Exception as e:
            return "FAIL", f"{evidence} (legacy check `{shape_id}` could not run: {type(e).__name__}: {e})", None
        if found:
            return "LEGACY", f"{spec['title']} (standard {spec['ref']}): {found} — probe: {evidence}", shape_id
    return "FAIL", evidence, None


def legacy_shapes_present(rows):
    """{"<shape id>": "<title>", ...} for shapes actually present in `rows` -- the --json
    `legacy_shapes` key -- so the skill can title an issue per shape without parsing evidence."""
    ids = sorted({r["legacy"] for r in rows if r.get("legacy")})
    return {i: LEGACY_SHAPES[i]["title"] for i in ids}


# ---------------------------------------------------------------- verify

def open_human_setup(ctx):
    items = ctx.gh.paged(f"repos/{ctx.intent.repo}/issues?labels=human-setup&state=open")
    return [i for i in items if "pull_request" not in i]


class Pin:
    """A resolved --pin target: the manifest and registry view classify_drift re-runs a FAIL
    probe against. Never constructed for `--pin none`, an unresolved pin, or a pin equal to
    the current --registry-ref (see resolve_pin)."""

    def __init__(self, commit, man, reg):
        self.commit, self.man, self.reg = commit, man, reg


def resolve_pin(args, reg, tree):
    """(Pin or None, info). `info` is None only for `--pin none`; otherwise a dict
    {"commit": full sha or None, "source": "adr-0001"|"flag", "note": str or None} that the
    header/JSON report even when nothing resolved. The first element is None whenever there is
    nothing new to classify against: no pin requested, a pin that never resolved or whose
    manifest could not be read (auto only -- an explicit --pin dies instead, since the owner
    named it), or a pin equal to the current registry commit (a FAIL there is a FAIL here too,
    so no second Ctx is worth building)."""
    mode = args.pin
    if mode == "none":
        return None, None
    if mode == "auto":
        text = tree.read(ADR0001)
        body = section(text, "Evidence") if text else None
        hexes = re.findall(r"`([0-9a-f]{7,40})`", body or "")
        if len(hexes) != 1:
            note = ("no registry commit recorded in ADR-0001's Evidence" if not hexes else
                     f"ADR-0001's Evidence names {len(hexes)} commit hashes, not one")
            return None, {"commit": None, "source": "adr-0001", "note": note}
        cand, source = hexes[0], "adr-0001"
    else:
        cand, source = mode, "flag"

    rev = git(reg.path, "rev-parse", "--verify", "--quiet", f"{cand}^{{commit}}")
    if rev.returncode != 0:
        if source == "flag":
            die(f"--pin {cand!r} does not resolve to a commit in the registry at {reg.path!r}")
        return None, {"commit": None, "source": source,
                      "note": f"ADR-0001 records `{cand}`, which does not resolve in the registry"}
    sha = rev.stdout.decode().strip()

    if sha == reg.commit:
        return None, {"commit": sha, "source": source, "note": None}

    # Registry.need()/manifest() call die() on failure; route around them until the manifest
    # is known to be readable, so an auto pin can still degrade instead of aborting the run.
    shown = git(reg.path, "show", f"{sha}:{MANIFEST}")
    if shown.returncode != 0:
        if source == "flag":
            die(f"the registry pin {sha[:7]} has no {MANIFEST}")
        return None, {"commit": None, "source": source, "note": f"the registry pin {sha[:7]} has no {MANIFEST}"}
    try:
        pin_man = json.loads(shown.stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError as e:
        if source == "flag":
            die(f"{MANIFEST} at the registry pin {sha[:7]} is not valid JSON ({e})")
        return None, {"commit": None, "source": source,
                      "note": f"{MANIFEST} at the registry pin {sha[:7]} is not valid JSON ({e})"}

    pin_reg = PinRegistry(reg.path, sha, False, "registry pin")
    return Pin(sha, pin_man, pin_reg), {"commit": sha, "source": source, "note": None}


def classify_drift(rid, evidence, pin, pin_ctx, ctx):
    """(result, evidence) for a row that FAILed at the current registry commit. FAIL is the
    default verdict; DRIFT is an exemption that needs positive evidence from the pin, and a pin
    that cannot speak for this row -- absent, the wrong layer, or unreadable here -- never
    exempts it. Never raises (including CannotVerify/RenderError): a probe crash at the pin
    degrades to FAIL, the same as a rule the pin never had an opinion about."""
    p7, cur7 = pin.commit[:7], ctx.reg.commit[:7]
    try:
        pinned_rule = next((r for r in pin.man["rules"] if r["id"] == rid), None)
        if pinned_rule is None or pinned_rule["class"] != "probe":
            return "DRIFT", f"not in the standard at pin {p7}; at {cur7}: {evidence}"
        if pinned_rule["layer"] not in ctx.intent.layers():
            return "DRIFT", f"`{pinned_rule['layer']}` not required at pin {p7}; at {cur7}: {evidence}"
        try:
            pin_result, pin_evidence = PROBES[rid](pin_ctx)
        except Exception as e:
            return "FAIL", f"{evidence} (drift check at pin {p7} could not run: {type(e).__name__}: {e})"
        if pin_result == "PASS":
            return "DRIFT", f"PASS at pin {p7} ({pin_evidence}); at {cur7}: {evidence}"
        return "FAIL", evidence  # FAIL at both commits: a real finding, not drift
    except Exception as e:  # a pin manifest too malformed to even classify is not an exemption
        return "FAIL", f"{evidence} (drift check at pin {p7} could not run: {type(e).__name__}: {e})"


def run_verify(man, reg, tree, intent, gh, pin=None):
    ctx = Ctx(man, reg, tree, intent, gh)
    pin_ctx = Ctx(pin.man, pin.reg, tree, intent, gh) if pin is not None else None
    layers = intent.layers()
    rows = []
    human_issues = None
    for rule in man["rules"]:
        rid, layer = rule["id"], rule["layer"]
        if rule["class"] == "advisory":
            continue
        if layer not in layers:
            rows.append({"rule": rid, "layer": layer, "result": "N-A", "evidence": f"{layer} is not in the intent"})
            continue
        if rid in intent.waivers:
            adr = intent.waivers[rid]
            if rule.get("waivable") is False:
                rows.append({"rule": rid, "layer": layer, "result": "FAIL",
                             "evidence": f"waived by {adr}, but this rule is not waivable"})
            elif not norm_repo_path(adr).startswith("docs/adr/") or not tree.has(norm_repo_path(adr)):
                rows.append({"rule": rid, "layer": layer, "result": "FAIL",
                             "evidence": f"the waiver cites {adr}, which is not an ADR under docs/adr/ at {tree.ref}"})
            elif rid not in (tree.read(norm_repo_path(adr)) or ""):
                rows.append({"rule": rid, "layer": layer, "result": "FAIL",
                             "evidence": f"the waiver's ADR {adr} never names `{rid}`"})
            else:
                rows.append({"rule": rid, "layer": layer, "result": "WAIVED", "evidence": adr})
            continue
        legacy_id = None
        try:
            result, evidence = PROBES[rid](ctx)
            if result == "FAIL" and pin is not None:
                result, evidence = classify_drift(rid, evidence, pin, pin_ctx, ctx)
            if result == "FAIL" and intent.source == "flags":
                # Only a repo with no committed genesis intent can read LEGACY (the back-port
                # audit, #313). On a genesis repo the same shape is a regression: a plain FAIL.
                result, evidence, legacy_id = classify_legacy(rid, evidence, ctx)
            if result == "FAIL" and rule.get("human"):
                # PENDING-HUMAN only when an OPEN human-setup issue names this rule: an
                # unfiled human step is a FAIL, and an unreadable issue list is an ERROR.
                if human_issues is None:
                    human_issues = open_human_setup(ctx)
                tagged = [i for i in human_issues if f"`{rid}`" in (i.get("body") or "")]
                if tagged:
                    result, evidence = "PENDING-HUMAN", f"{evidence} — #{tagged[0]['number']} is open"
        except CannotVerify as e:
            result, evidence = ERROR, str(e)
        except RenderError as e:
            result, evidence = ERROR, f"cannot render the expected file: {e}"
        except Exception as e:  # a probe bug or an API shape it did not expect: it could not look
            result, evidence = ERROR, f"probe crashed ({type(e).__name__}: {e})"
        row = {"rule": rid, "layer": layer, "result": result, "evidence": evidence}
        if legacy_id is not None:  # only ever set for a LEGACY row; no other row carries this key
            row["legacy"] = legacy_id
        rows.append(row)
    return rows


def verify_exit(rows):
    if any(r["result"] == ERROR for r in rows):
        return EXIT_CANNOT_VERIFY
    if any(r["result"] in ("FAIL", "LEGACY") for r in rows):
        return EXIT_FINDINGS
    return EXIT_OK  # DRIFT (like PENDING-HUMAN) never reaches here as FAIL or LEGACY, so never flips this


def print_rows(head, rows, code, pin_info=None, not_a_checkout=False):
    print(head + "\n")
    print("| Rule | Result | Evidence |\n|---|---|---|")
    for r in rows:
        print(f"| `{r['rule']}` | {r['result']} | {r['evidence'].replace('|', '/')} |")
    counts = {}
    for r in rows:
        counts[r["result"]] = counts.get(r["result"], 0) + 1
    order = list(RESULTS) + [ERROR]
    print("\n" + " · ".join(f"{counts[k]} {k}" for k in order if k in counts) + f" · exit {code}")
    if any(r["result"] == "DRIFT" for r in rows) and pin_info and pin_info.get("commit"):
        print(f"DRIFT: the standard moved after this repo's pin ({pin_info['commit'][:7]}); these "
              "rows pass there and do not change the exit code.")
    if any(r["result"] == "LEGACY" for r in rows):
        ids = sorted({r["legacy"] for r in rows if r.get("legacy")})
        print(f"LEGACY: known pre-standard shape(s) {', '.join(ids)} (standard §10.4); each row is a "
              "finding, and its fix is a migration of the shape.")
    if code == EXIT_CANNOT_VERIFY:
        if not_a_checkout:
            print("Could not verify: no rule was probed, because --repo is not a checkout. This is not a pass.")
        else:
            print("Could not verify (ERROR rows): this is not a pass.")


def intent_for_verify(args, man, tree):
    slug = args.gh_repo or remote_slug(tree.path)
    if not slug or "/" not in slug:
        die("cannot tell which GitHub repo this is — pass --gh-repo OWNER/NAME")
    owner, name = slug.split("/", 1)
    text = tree.read(PROFILE)
    fields, why = parse_profile_intent(text, man)
    if fields is not None:
        # intent_from_profile never reads the posture pins; a profile with no pins, or
        # disagreeing ones, keeps the Intent default of "withheld" (profile.posture then FAILs).
        got, pin_problems = posture_pins(text, man)
        posture = (next(iter(got.values())).lower() if got and not pin_problems
                   and len(set(got.values())) == 1 else "withheld")
        return intent_from_profile(fields, man, name, owner, posture=posture)
    kw = intent_kwargs_from_flags(args, man, name, owner, verify=True)  # dies, never refuses
    return Intent(source="flags", problems=why, **kw)


# ---------------------------------------------------------------- self-check

def self_check(man, reg):
    problems = []
    ids = [r["id"] for r in man["rules"]]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        problems.append(f"rule id `{dup}` appears more than once")
    layers = {"core"} | {f"overlay:{o}" for o in man["overlays"]} | {f"module:{m}" for m in man["modules"]}
    for r in man["rules"]:
        if r.get("class") not in ("probe", "advisory"):
            problems.append(f"rule `{r['id']}` has class {r.get('class')!r} (want probe or advisory)")
        if r.get("layer") not in layers:
            problems.append(f"rule `{r['id']}` names unknown layer {r.get('layer')!r}")
    probed = {r["id"] for r in man["rules"] if r.get("class") == "probe"}
    advisory = {r["id"] for r in man["rules"] if r.get("class") == "advisory"}
    for rid in sorted(probed - set(PROBES)):
        problems.append(f"rule `{rid}` is classed probe but has no probe (Principle 2)")
    for rid in sorted(set(PROBES) - probed - advisory):
        problems.append(f"probe `{rid}` has no rule in the manifest")
    for rid in sorted(set(PROBES) & advisory):
        problems.append(f"rule `{rid}` is classed advisory but has a probe — class it probe")
    for shape_id, spec in sorted(LEGACY_SHAPES.items()):
        for rid in spec["rules"]:
            if rid not in probed:
                problems.append(f"legacy shape `{shape_id}` names `{rid}`, which is not a probed rule")
    for kind, table in (("overlay", man["overlays"]), ("module", man["modules"])):
        for name, spec in table.items():
            layer_rules = [r["id"] for r in man["rules"] if r["layer"] == f"{kind}:{name}"]
            if spec.get("status") == "implemented" and kind == "overlay" and not layer_rules:
                problems.append(f"implemented {kind} `{name}` has no rules")
            if spec.get("status") != "implemented" and (layer_rules or spec.get("files") or spec.get("fragments")):
                problems.append(f"planned {kind} `{name}` carries rules, files or fragments")
    for h in man["human_setup"]:
        if h["rule"] not in probed:
            problems.append(f"human_setup entry cites `{h['rule']}`, which is not a probed rule")
        elif not next(r for r in man["rules"] if r["id"] == h["rule"]).get("human"):
            problems.append(f"human_setup rule `{h['rule']}` is not marked human: true")

    known_when = {"overlay:any", "posture:withheld", "posture:gated"}
    for d in man["skills"]["deferred"]:
        when = d.get("when")
        if when is None or when in known_when:
            continue
        kind, _, rest = when.partition(":")
        table = man["overlays"] if kind == "overlay" else man["modules"] if kind == "module" else None
        if table is None or rest not in table:
            problems.append(f"deferred skill `{d['name']}` has unknown `when` {when!r}")

    hs_tmpl = next((f for f in man["core"]["files"] if f["path"] == ".github/ISSUE_TEMPLATE/human_setup.md"), None)
    if hs_tmpl is None:
        problems.append("no core file declares path `.github/ISSUE_TEMPLATE/human_setup.md`")
    else:
        hs_text = reg.read(GENESIS_DIR + hs_tmpl["template"])
        if hs_text is not None:
            got = headings(hs_text, 2)
            want = ["Context"] + list(HUMAN_SETUP_SECTIONS)
            if got != want:
                problems.append(f"the human-setup issue template's sections {got} differ from HUMAN_SETUP_SECTIONS")

    referenced = {f["template"] for f in man["core"]["files"]} | set(man["core"]["fragments"].values())
    for spec in man["overlays"].values():
        referenced |= set((spec.get("fragments") or {}).values())
    for spec in man["modules"].values():
        referenced |= {f["template"] for f in spec.get("files") or []}
    on_disk = {p[len(GENESIS_DIR):] for p in reg.under(TEMPLATES_DIR)}
    for t in sorted(referenced - on_disk):
        problems.append(f"the manifest references {t}, which does not exist")
    for t in sorted(on_disk - referenced):
        problems.append(f"{GENESIS_DIR}{t} is referenced by nothing in the manifest")
    for t in sorted(on_disk):
        if not t.endswith(".tmpl"):
            problems.append(f"{GENESIS_DIR}{t} lacks the .tmpl suffix (a live .gitignore or "
                            f"CLAUDE.md in the registry tree would act on the registry itself)")
    declared = set(man["placeholders"])
    for t in sorted(on_disk):
        text = reg.read(GENESIS_DIR + t) or ""
        for n in sorted(set(PLACEHOLDER.findall(text)) - declared):
            problems.append(f"{t} uses undeclared placeholder @@{n}@@")
        for i, ln in enumerate(text.splitlines(), 1):
            m = USES.match(ln)
            if m and not m.group(1).startswith(("./", "docker://")):
                parts = m.group(1).rsplit("@", 1)
                if len(parts) != 2 or not SHA40.match(parts[1]):
                    problems.append(f"{t}:{i} `uses: {m.group(1)}` is not pinned to a full SHA")

    labels = reg.genesis_json(man["github"]["labels"])
    names = [l.get("name") for l in labels]
    for dup in sorted({n for n in names if names.count(n) > 1}):
        problems.append(f"labels.json repeats `{dup}`")
    for l in labels:
        if not re.match(r"^[0-9a-fA-F]{6}$", l.get("color", "")):
            problems.append(f"label `{l.get('name')}` has colour {l.get('color')!r}")
        if not l.get("description") or len(l["description"]) > 100:
            problems.append(f"label `{l.get('name')}` needs a description of at most 100 characters")
    ruleset = reg.genesis_json(man["github"]["ruleset"])
    if ruleset.get("bypass_actors") != []:
        problems.append("ruleset-main.json has bypass actors (Critical Rule: no bypass)")
    checks = [c for r in ruleset.get("rules", []) if r.get("type") == "required_status_checks"
              for c in r.get("parameters", {}).get("required_status_checks", [])]
    if [c.get("context") for c in checks] != ["ci-gate"]:
        problems.append(f"ruleset-main.json requires {[c.get('context') for c in checks]}, want exactly ['ci-gate']")

    if referenced - on_disk:
        problems.append("rendering skipped: fix the missing template(s) first")
        return problems
    # Render every implemented layer at once: an unresolved or undeclared placeholder in any
    # combination the standard allows shows up here, before any repo is created with it.
    full = Intent(name="self-check", owner=man["owner"],
                  overlays=[o for o, s in man["overlays"].items() if s.get("status") == "implemented"],
                  modules=[m for m, s in man["modules"].items() if s.get("status") == "implemented"],
                  app_id="com.blamechris.selfcheck", relay_token_in=[])
    for intent in (full, Intent(name="self-check", owner=man["owner"], app_id="none")):
        try:
            plan = build_plan(man, reg, intent, explicit=set())
        except RenderError as e:
            problems.append(f"render ({'all layers' if intent is full else 'core only'}): {e}")
            continue
        jobs = workflow_jobs(next(f["content"] for f in plan["files"] if f["path"] == CI))
        gate = jobs.get("ci-gate", {"needs": []})
        if set(jobs) - {"ci-gate"} != set(gate["needs"]):
            problems.append(f"rendered ci.yml: ci-gate needs {gate['needs']}, jobs are {sorted(jobs)}")
        if intent is full:
            for i in plan["issues"]:
                if i["kind"] != "human-setup":
                    continue
                got = headings(i["body"], 2)
                if got != list(HUMAN_SETUP_SECTIONS):
                    problems.append(f"human_setup_issue()'s rendered sections {got} for "
                                    f"`{i['title']}` differ from HUMAN_SETUP_SECTIONS")
    return problems


# ---------------------------------------------------------------- non-git stub (--repo preflight)
#
# The third legacy shape (standard §6: "No stubs. One checkout, ~/Projects/<repo>") is repo-level:
# it never reaches a rule's probe, because there is no git tree to probe. main() checks for it
# before ever constructing a GitTree, so a stub is reported as its own LEGACY row instead of
# tripping GitTree's ordinary "is not a git repository" die().

STUB_ENTRIES = {".claude", ".mcp.json", ".repo-memory", ".repo-memory.json", ".DS_Store"}


def stub_repo(path):
    """True when `path` is a stub the standard forbids: a directory directly under ~/Projects/
    that is not a git repository and holds at most machine/tooling droppings -- never true for a
    git repository (however thin) or a directory outside ~/Projects/, so every other non-git
    --repo still falls through to GitTree's own die()."""
    if not os.path.isdir(path):
        return False
    if git(path, "rev-parse", "--git-dir").returncode == 0:
        return False
    real = os.path.realpath(path)
    if os.path.dirname(real) != os.path.realpath(os.path.expanduser("~/Projects")):
        return False
    try:
        entries = os.listdir(real)
    except OSError:
        return False
    return all(e in STUB_ENTRIES for e in entries)


def stub_row(path):
    real = os.path.realpath(path)
    entries = sorted(os.listdir(real))
    spec = LEGACY_SHAPES["non-git-stub"]
    holds = f"holds only {entries}" if entries else "is empty"
    evidence = (f"{spec['title']} (standard {spec['ref']}): {path} {holds} and no .git; the standard "
                "keeps one checkout at ~/Projects/<repo>, and a session started here resolves its "
                "seed scope to `fleet`. Audit a clone instead (--repo <clone> --gh-repo "
                "<owner>/<repo>); turning the stub into the checkout is the owner's call.")
    return {"rule": "machine.checkout", "layer": "machine", "result": "LEGACY",
            "legacy": "non-git-stub", "evidence": evidence}


# ---------------------------------------------------------------- CLI

def intent_kwargs_from_flags(args, man, name, owner, verify=False):
    """Plan-mode intent from flags. In verify mode (a repo whose profile records no intent)
    an absent flag means the layer was not chosen, never the plan default, and bad input is
    a could-not-verify rather than a refused plan."""
    stop = die if verify else refuse

    def listed(value, table, what, flag):
        out = split_list(value)
        for x in out:
            if x not in table:
                stop(f"unknown {what} `{x}` (the standard knows: {', '.join(sorted(table))})")
            if table[x].get("status") != "implemented":
                stop(f"{what} `{x}` is declared by Standard {man['standard']} but not implemented in "
                     f"its templates — nothing honest can be rendered for it yet")
        if len(set(out)) != len(out):
            stop(f"{flag} repeats an entry")
        return out

    overlays = listed(None if args.stack in (None, "none") else args.stack, man["overlays"], "overlay", "--stack")
    default_modules = "" if verify else ",".join(m for m, s in man["modules"].items() if s.get("default"))
    modules = listed(default_modules if args.modules is None else args.modules, man["modules"], "module",
                     "--modules")
    for m, spec in man["modules"].items():
        if spec.get("required") and m not in modules and not verify:
            stop(f"module `{m}` is required: {spec['required']}")
    vis = args.visibility or "private"
    if vis not in man["visibility"]:
        stop(f"unknown visibility `{vis}`")
    if man["visibility"][vis].get("status") != "implemented":
        stop(f"visibility `{vis}`: {man['visibility'][vis].get('note', 'planned in this standard')}")
    if args.app_id is None:
        app_id = derive_app_id(name) if any(man["overlays"][o].get("app") for o in overlays) else "none"
    else:
        app_id = args.app_id
    if app_id != "none" and not APP_ID.match(app_id):
        stop(f"invalid app id `{app_id}`: it needs two or more dot-separated segments, each "
               f"starting with a letter and using only [A-Za-z0-9_] (pass --app-id)")
    relay = None if args.relay_token_in is None else split_list(args.relay_token_in)
    # deferred is None here in both modes: nothing at plan time reads intent.deferred (build_plan
    # derives the plan's deferred list from skill_sets()), and only verify's profile.genesis-intent
    # reads it, where it comes from the committed profile instead.
    return dict(name=name, owner=owner, visibility=vis, overlays=overlays, modules=modules,
                app_id=app_id, posture=args.posture or "withheld", description=args.description,
                relay_token_in=relay, date=args.date, deferred=None)


def main():
    ap = argparse.ArgumentParser(description="Render and verify against the Fleet Genesis Standard.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true", help="render every write for a new repo")
    mode.add_argument("--repo", help="verify this checkout (at --ref) and its GitHub settings")
    mode.add_argument("--self-check", action="store_true", help="registry gate: rule<->probe parity etc.")
    mode.add_argument("--list-rules", action="store_true", help="print the manifest's rules")
    ap.add_argument("--registry", default=os.environ.get("SKILL_REGISTRY_DIR")
                    or os.path.expanduser("~/Projects/skill-templates"))
    ap.add_argument("--registry-ref", default="origin/main")
    ap.add_argument("--no-fetch", action="store_true", help="skip `git fetch` (tests, offline registry refs)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--name")
    ap.add_argument("--stack")
    ap.add_argument("--modules")
    ap.add_argument("--app-id")
    ap.add_argument("--visibility")
    ap.add_argument("--posture", choices=["withheld", "gated"])
    ap.add_argument("--description")
    ap.add_argument("--relay-token-in", help="sibling repos holding DISCORD_BOT_TOKEN (Phase 0), or none")
    ap.add_argument("--seed-issues", help="path to a v2 seed-issues file (plan mode only)")
    ap.add_argument("--date")
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--gh-repo", help="OWNER/NAME; default: the checkout's origin remote")
    ap.add_argument("--pin", default="none",
                    help="judge a FAIL against a second registry commit too: none (default), "
                         "auto (ADR-0001's recorded commit), or an explicit registry ref/sha (#314)")
    args = ap.parse_args()
    if args.seed_issues is not None and not args.plan:
        ap.error("--seed-issues is a --plan flag; verify reads no seed file")
    if args.pin != "none" and not args.repo:
        ap.error("--pin is a verify (--repo) flag")

    reg = Registry(args.registry, args.registry_ref, not args.no_fetch, "registry")
    man = reg.manifest()

    if args.list_rules:
        if args.json:
            print(json.dumps(man["rules"], indent=2))
        else:
            for r in man["rules"]:
                print(f"{r['id']:32} {r['class']:9} {r['layer']:20} {r['summary']}")
        return EXIT_OK

    if args.self_check:
        problems = self_check(man, reg)
        for p in problems:
            print(f"::error::genesis self-check: {p}")
        if not problems:
            n = sum(1 for r in man["rules"] if r["class"] == "probe")
            print(f"OK: {n} probed rules <-> {len(PROBES)} probes; templates, placeholders, pins, "
                  f"labels and ruleset consistent (registry {reg.commit[:7]}).")
        return EXIT_FINDINGS if problems else EXIT_OK

    if args.plan:
        if not args.name:
            refuse("--plan needs --name")
        if not SLUG.match(args.name):
            refuse(f"`{args.name}` is not a repo slug: lower-case letters, digits and inner hyphens")
        if args.date and not DATE.match(args.date):
            refuse("--date must be YYYY-MM-DD")
        explicit = {k for k in ("visibility", "stack", "modules", "app_id", "posture", "description",
                                "relay_token_in", "seed_issues") if getattr(args, k) is not None} | {"name"}
        # An empty path is refused as unreadable, never read as "no seed file".
        seed = None if args.seed_issues is None else parse_seed_issues(args.seed_issues, man, reg)
        intent = Intent(source="flags", **intent_kwargs_from_flags(args, man, args.name, man["owner"]))
        try:
            plan = build_plan(man, reg, intent, explicit, seed=seed)
        except RenderError as e:
            die(f"the registry's templates do not render: {e}")
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print_plan(plan)
        return EXIT_OK

    if stub_repo(args.repo):
        row = stub_row(args.repo)
        repo_label = args.gh_repo or f"{man['owner']}/{os.path.basename(os.path.realpath(args.repo))}"
        code = EXIT_CANNOT_VERIFY
        if args.json:
            print(json.dumps({"repo": repo_label, "ref": None, "commit": None,
                              "registry": {"ref": reg.ref, "commit": reg.commit},
                              "standard": man["standard"], "intent_source": None, "pin": None,
                              "results": [row], "legacy_shapes": legacy_shapes_present([row]),
                              "exit": code}, indent=2))
        else:
            head = (f"genesis-verify — {repo_label} @ not a checkout · Standard {man['standard']} "
                    f"(registry {reg.commit[:7]})")
            print_rows(head, [row], code, not_a_checkout=True)
        return code

    tree = GitTree(args.repo, args.ref, not args.no_fetch, "repo")
    pin, pin_info = resolve_pin(args, reg, tree)
    intent = intent_for_verify(args, man, tree)
    rows = run_verify(man, reg, tree, intent, GH(intent.repo), pin=pin)
    code = verify_exit(rows)
    if args.json:
        print(json.dumps({"repo": intent.repo, "ref": tree.ref, "commit": tree.commit,
                          "registry": {"ref": reg.ref, "commit": reg.commit},
                          "standard": man["standard"], "intent_source": intent.source,
                          "pin": pin_info, "results": rows, "legacy_shapes": legacy_shapes_present(rows),
                          "exit": code}, indent=2))
    else:
        head = (f"genesis-verify — {intent.repo} @ {tree.ref} ({tree.commit[:7]}) · Standard "
                f"{man['standard']} (registry {reg.commit[:7]}) · intent from {intent.source}")
        if pin_info is not None:
            head += (f" · pin {pin_info['commit'][:7]} ({pin_info['source']})" if pin_info["commit"]
                     else f" · no pin: {pin_info['note']}")
        print_rows(head, rows, code, pin_info)
    return code


def entry():
    try:
        return main()
    except CannotVerify as e:
        die(str(e))
    except RenderError as e:
        die(f"the registry's templates do not render: {e}")
    except Exception as e:  # exit 1 means findings; a crash is never a finding
        die(f"internal error {type(e).__name__}: {e}")


if __name__ == "__main__":
    sys.exit(entry())
