# vault-sync

`assets/scripts/vault-sync.py` pushes the private, git-backed notes vault so the remote does not
fall behind local `main`. Without it nobody owns the push and other machines see stale state. It is
installed to `~/.claude/scripts/` with the other machine scripts (see `/session-lifecycle`) and is
step 5a of the session-end checklist.

This widens agent authority: agents push a private repository automatically. The design is
fail-closed: anything the script cannot verify is a refusal.

## Contract

```
vault-sync.py [--vault PATH] status
vault-sync.py [--vault PATH] push [--dry-run] [--allow-path OID:PATH:RULE]...
```

The vault is `--vault`, else `$CLAUDE_VAULT_DIR`, else `~/Obsidian/no-it-all`. `--vault` goes before
the subcommand.

| Exit | Meaning |
|---|---|
| 0 | pushed, or nothing to push |
| 1 | refused in preflight; nothing was sent |
| 2 | usage or environment error (not a git repo, detached HEAD, no upstream, damaged index, bad option) |
| 3 | transport failure or an outcome that could not be confirmed; a push may have partially succeeded. Run `vault-sync.py status` after fetching. A failed fetch also exits 3 and says nothing was pushed |

**`status`** is offline and read-only (`--no-optional-locks`, no fetch). It resolves the upstream with
`rev-parse --abbrev-ref --symbolic-full-name @{u}`, checks every return code, and prints
`ahead N behind M`, the ahead commits as short OIDs (never subjects), and
`dirty: <modified> modified, <untracked> untracked`. A damaged index makes it fail with exit 2 rather
than report a clean tree.

**`push`**, in order:

1. Resolve the branch and its configured remote and remote branch (the local branch name need not
   match). Refuse a mirror remote.
2. Freeze the destination. `git remote get-url --all` and `--push --all` must each return exactly one
   URL, both must name the same repository, on host `github.com`, in https or ssh/scp form with no
   embedded credentials. Fetch, push and the final check all use those literal URLs, so a config
   change after validation cannot redirect them.
3. Pin `head_oid = HEAD`.
4. Visibility gate, before any git network call (below).
5. Fetch the remote branch into a private ref (`refs/vault-sync/<pid>/base`, deleted afterwards), with
   no tags and no submodule recursion. `FETCH_HEAD` is not used.
6. Compute ahead/behind from the two OIDs. Behind or diverged is a refusal; the script never pulls,
   merges, rebases or resets.
7. Scan exactly `base..head_oid` (below).
8. `git push --no-verify --no-follow-tags --recurse-submodules=no <url> <head_oid>:refs/heads/<branch>`.
   Never `--force`, `--force-with-lease` or a `+` refspec. A commit that lands in the vault after step 3
   is neither scanned nor pushed.
9. `git ls-remote <url> refs/heads/<branch>` must equal `head_oid`, else exit 3.

`--dry-run` runs steps 1 to 7 and pushes nothing.

### Environment and hooks

Every inherited `GIT_*` variable is removed, then only `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C` and
`GIT_NO_REPLACE_OBJECTS=1` are set. Every git call also passes `--no-replace-objects`,
`--no-optional-locks` and `-c core.hooksPath=/dev/null`, so no vault hook runs (including
`reference-transaction`), and submodule recursion and tag following are disabled. A credential helper
that is configured **does** run during fetch and push, because authentication needs it; that is why the
destination is verified before the first network call. Each git call has a timeout and output is
decoded with replacement. Subprocess stderr is never relayed: failures print a fixed category (`fetch
failed`, `push failed`, `gh failed`) and an exit code.

## Visibility gate

`gh api repos/<owner>/<repo> --hostname github.com --jq .visibility` must print `private`. `gh` runs
with a rebuilt environment: `GH_HOST`, `GH_REPO`, enterprise tokens and `GH_CONFIG_DIR` are dropped;
only `PATH`, `HOME`, `GH_TOKEN` and `GITHUB_TOKEN` pass through. A missing or failing `gh` is a refusal.
There is no bypass flag or test switch in the script.

## Scope check

The vault is one checkout shared by every session, so a push also carries other sessions' local
commits. The check therefore covers the whole unpushed range. It reads raw objects, not diff text:
for each commit it lists changes against each parent with NUL-delimited `diff-tree --raw`, reads each
added or modified blob with `cat-file --batch`, and treats the lines of the new blob that are absent
from the parent blob as added lines. Diff attributes, textconv, `bigFileThreshold`, binary
classification and `+++` content cannot hide a line. Bytes are decoded as latin-1, so nothing is
skipped. Commit messages are scanned too. It refuses when a commit:

- adds a line (or has a message line) matching a credential heuristic: GitHub tokens (`ghp_`, `gho_`,
  `ghu_`, `ghs_`, `ghr_`, `github_pat_`), `sk-` keys, `sk_live_`/`sk_test_`, Slack `xox[abpr]-`, `AKIA`
  plus 16 characters, a PEM `BEGIN ... PRIVATE KEY` header, JWT-shaped strings, `password`/`secret`/
  `token`/`api_key` assignments whose value is 8 or more characters with a digit or mixed case, and
  `bearer` plus a long token;
- has a credential-shaped path, or changes a path whose basename matches `.env*`, `*.pem`, `*.key`,
  `id_rsa*`, `id_ed25519*`, `*credentials*`, `*.p12` or `*.keychain*`;
- adds a blob over 50 MB, or a Git LFS pointer (the payload is not validated);
- cannot be fully read: a failing, short or malformed `cat-file --batch-check` or `--batch`, or
  unparseable `diff-tree` output, refuses rather than skips.

A refusal prints the short commit OID, a path with credential-shaped substrings replaced by
`<redacted>` and control characters escaped, the line number and the rule name. It never prints a
matched value. `scope: N commits, M paths, K files added` is printed on every run that reaches the scan.

`--allow-path <commit-oid>:<path>:<rule>` (repeatable) exempts exactly that finding: the commit OID
(at least 8 hex characters), the literal path and the rule name as printed. Each use is echoed at the
start and again for the finding it suppressed; an allow that matched nothing is reported as unused. It
never relaxes the destination or visibility checks.

### Limits

This is a heuristic backstop, not a guarantee. It misses secrets without a recognisable shape, secrets
split across lines, encoded or encrypted content, UTF-16 text, secrets inside archives, and personal
data with no token shape. It also flags benign text that resembles a key, which is what `--allow-path`
is for. A configured credential helper runs during fetch and push. Passing the scan does not make a
commit safe to publish.

## Tests

`assets/scripts/vault-sync.test.sh` is hermetic: a temp bare repo is the remote, a temp clone is the
vault with a github.com URL, and a git wrapper outside the script maps that URL to the local bare repo,
logs every invocation and its `GIT_*` environment, and injects faults (a failing `batch-check`, a lying
`ls-remote`, a commit landing after the fetch). `gh` is a fake on `PATH`. `HOME` is temporary and
nothing touches the network. Credential-shaped fixtures are assembled at run time. CI runs it as a named
step in `validate-registry.yml`.
