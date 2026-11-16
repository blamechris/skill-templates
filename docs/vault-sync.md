# vault-sync

`assets/scripts/vault-sync.py` pushes the private, git-backed notes vault so the remote does not
fall behind local `main`. Without it nobody owns the push and other machines see stale state. It is
installed to `~/.claude/scripts/` with the other machine scripts (see `/session-lifecycle`) and is
step 5a of the session-end checklist.

This widens agent authority: agents push a private repository automatically. That is why the push is
fast-forward only and sits behind two gates.

## Contract

```
vault-sync.py [--vault PATH] status
vault-sync.py [--vault PATH] push [--dry-run] [--allow-path PATH]...
```

The vault is `--vault`, else `$CLAUDE_VAULT_DIR`, else `~/Obsidian/no-it-all`. `--vault` goes before
the subcommand.

| Exit | Meaning |
|---|---|
| 0 | pushed, or nothing to push |
| 1 | refused; nothing was pushed |
| 2 | usage or environment error (not a git repo, detached HEAD, no upstream, fetch failed) |

**`status`** is offline and read-only. It never fetches. From the last-fetched upstream it prints
`ahead N behind M`, the ahead commits, and `dirty: <modified> modified, <untracked> untracked`.

**`push`** fetches only the one remote branch (no tags, no prune), then:

1. refuses when the branch is behind or diverged, printing the counts. The script never pulls, merges,
   rebases or resets; reconciling is a decision for the owner.
2. runs the visibility gate;
3. runs the scope check over every commit in `<remote tip>..HEAD`;
4. runs `git push <remote> HEAD:refs/heads/<branch>`. Never `--force`, `--force-with-lease` or a `+`
   refspec. It prints `pushed: <old>..<new>`.

`--dry-run` does steps 1 to 3 and pushes nothing. Every git call runs with `GIT_DIR`, `GIT_WORK_TREE`,
`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`,
`GIT_NAMESPACE` and `GIT_CONFIG_*` removed, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, a timeout and
lossy output decoding, so an inherited environment cannot redirect the push.

A refusal means: report it in the status block and leave the commits local.

## Visibility gate

The push is refused unless `gh repo view <owner/name> --json visibility` reports `PRIVATE`. The
`owner/name` comes from the remote's fetch and push URLs (github.com, https, ssh or scp form). It is
refused, with a reason, when `gh` is missing or fails, when the URLs disagree, or when the remote is
not a GitHub URL, because privacy cannot be verified. `--skip-visibility-check` and the
`VAULT_SYNC_TEST_REPO` override exist for the test suite only and work only with `VAULT_SYNC_TEST=1`.

## Scope check

The vault is one checkout shared by every session, so a push also carries other sessions' local
commits. The check therefore covers the whole unpushed range, commit by commit, not just the current
session's work. It refuses when any commit:

- adds a line matching a credential heuristic: GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`,
  `github_pat_`), `sk-` keys, `sk_live_`/`sk_test_`, Slack `xox[abpr]-`, `AKIA` plus 16 characters,
  a PEM `BEGIN ... PRIVATE KEY` header, JWT-shaped strings, `password`/`secret`/`token`/`api_key`
  assignments whose value is 8 or more characters with a digit or mixed case, and `bearer` plus a long
  token;
- changes a path whose basename matches `.env*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`,
  `*credentials*`, `*.p12` or `*.keychain*`;
- adds a blob over 50 MB.

A refusal lists each commit, path and line number with the rule name. It never prints the matched
value. A summary line `scope: N commits, M paths, K files added` is printed on every run that reaches
the check.

`--allow-path <literal path>` (repeatable) exempts one repo-relative path, exactly as written, from the
scope check for an owner-reviewed false positive. Each use is echoed at the start and again for every
finding it suppressed. It is not a pattern and never relaxes the visibility gate.

### Limits

This is a heuristic backstop, not a guarantee. It reads added lines only, so it misses secrets without
a recognisable shape, secrets split across lines, encoded or encrypted blobs, secrets in binary files,
in commit messages or in path names, and personal data that has no token shape. It will also flag
benign text that resembles a key; that is the reason for `--allow-path`. Passing the check does not
make a commit safe to publish; the visibility gate and not putting secrets in notes remain the primary
controls.

## Tests

`assets/scripts/vault-sync.test.sh` is hermetic: a temp bare repo is the remote, a temp clone is the
vault, `HOME` and the git config are temporary, `gh` is a fake, and nothing touches the network.
Credential-shaped fixtures are assembled at run time. CI runs it as a named step in
`validate-registry.yml`.
