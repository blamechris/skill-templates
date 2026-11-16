# vault-sync

`assets/scripts/vault-sync.py` pushes the private, git-backed notes vault so the remote does not
fall behind local `main`. Without it nobody owns the push and other machines see stale state. It is
installed to `~/.claude/scripts/` with the other machine scripts (see `/session-lifecycle`) and is
step 5a of the session-end checklist.

This widens agent authority: agents push a private repository automatically. The design is
fail-closed: anything the script cannot verify is a refusal, and there is no override.

## Contract

```
vault-sync.py [--vault PATH] status
vault-sync.py [--vault PATH] push [--dry-run]
```

The vault is `--vault`, else `$CLAUDE_VAULT_DIR`, else `~/Obsidian/no-it-all`. `--vault` goes before
the subcommand.

| Exit | Meaning |
|---|---|
| 0 | pushed, or nothing to push |
| 1 | refused; nothing was sent |
| 2 | usage or environment error (not a git repo, detached HEAD, no upstream, damaged index, git older than 2.32, unexpected failure before anything was sent) |
| 3 | transport failure or an outcome that could not be confirmed; a push may have partially succeeded. Run `vault-sync.py status` after fetching. A failed remote fetch also exits 3, with a message saying nothing was pushed (so exit 3 does not always mean a push began). Any unexpected exception after the push began is also 3 |

**`status`** is offline and read-only (`--no-optional-locks`, no fetch). It resolves the upstream with
`rev-parse --abbrev-ref --symbolic-full-name @{u}`, checks every return code, and prints
`ahead N behind M`, the ahead commits as short OIDs (never subjects), and
`dirty: <modified> modified, <untracked> untracked`. A damaged index makes it fail with exit 2.

## How `push` works

The vault's own git configuration (remotes, `insteadOf`, `pushurl`, credential helpers, `core.sshCommand`,
ssh config, hooks) is **never used for transport**. Transport happens from a fresh temporary bare
repository that the script creates and deletes.

1. **Vault preflight, all local.** No inherited `GIT_*`, `--no-replace-objects`, `GIT_GRAFT_FILE=/dev/null`,
   no hooks. Refuse if `.git/info/grafts` or `.git/shallow` exists (they can hide commits from history
   walks). Refuse a mirror remote. `git remote get-url --all` and `--push --all` must each return exactly
   one URL, both naming the same repository on `github.com` in https or ssh/scp form with no embedded
   credentials. Pin `head_oid = HEAD`.
2. **Destination.** Design premise: the push is pinned to the repository the vault's own URLs name, and the check is that this repository is private. Any private github.com repository reachable with the user's `gh` token therefore passes; the script does not know which repository the vault *should* be. The script builds the canonical URL itself: `https://github.com/<owner>/<repo>.git`.
   It is https only, even when the vault remote is ssh/scp. The vault's own URL string is never passed to
   transport git. `gh api repos/<owner>/<repo> --hostname github.com --jq .visibility` must print
   `private`, checked before any network git call. `gh` runs with a rebuilt environment: `GH_HOST`,
   `GH_REPO`, enterprise tokens and `GH_CONFIG_DIR` are dropped; only `PATH`, `HOME`, `GH_TOKEN` and
   `GITHUB_TOKEN` pass through.
3. **Isolated transport repository.** Every git call against it runs with `GIT_CONFIG_NOSYSTEM=1`,
   `GIT_CONFIG_GLOBAL` pointing at a generated file, no other inherited `GIT_*`, `GIT_TERMINAL_PROMPT=0`,
   `GIT_NO_REPLACE_OBJECTS=1` and `--no-replace-objects`. That file contains only: `core.hooksPath=/dev/null`;
   `protocol.allow=never` with https and file allowed; an empty `credential.helper` (reset) followed by
   `credential.https://github.com.helper=!<gh> auth git-credential`; no submodule recursion;
   `transfer.fsckObjects=true`. It has no remotes and no `insteadOf`. Authentication is therefore
   **only** through `gh` (`gh auth login`); ambient credential helpers are replaced, not consulted.
4. **Objects.** A private vault ref `refs/vault-sync/<pid>/head` pins `head_oid`; the transport repository
   fetches it from the vault path, then fetches `refs/heads/<branch>` from the canonical URL. The vault ref
   is deleted afterwards.
5. **Scan** of `base..head` inside the transport repository (below). Behind or diverged is a refusal; the
   script never pulls, merges, rebases or resets.
6. **Push** from the transport repository: `git push --no-verify --no-follow-tags --recurse-submodules=no
   <canonical URL> refs/vs/head:refs/heads/<branch>`. Never `--force`, `--force-with-lease` or a `+` refspec.
   A commit that lands in the vault after the pin is neither scanned nor pushed. The result is checked
   with `ls-remote` against the same canonical URL; a mismatch is exit 3.

`--dry-run` runs everything up to and including the scan and pushes nothing.

Proxy and CA environment variables (`*_proxy`, `NO_PROXY`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`) are dropped for transport git, as for `gh`. Git 2.32 or newer is required.

**Signals.** SIGTERM, SIGINT and SIGHUP are only recorded. A signal that arrives before the push begins kills the current child's process group, cleans up (private ref and temporary repository), prints `REFUSED: interrupted, nothing sent` and exits 1; the default signal disposition is not re-raised, so the exit-code contract holds. Once the push has begun, the push and the `ls-remote` verification are allowed to finish (each has a timeout) and the exit is 0 if verified, otherwise 3. Cleanup always runs.

A configured `gh auth git-credential` helper runs during the fetch and push to github.com; that is the one
helper that can run. If the process is killed with SIGKILL the temporary repository and the private vault
ref may be left behind; they are harmless and the next run uses a new pid. The script trusts the
executables found on `PATH` (`git`, `gh`); that is a documented assumption, not something it verifies.

## Scope check

The vault is one checkout shared by every session, so a push also carries other sessions' local
commits. The check covers the whole unpushed range. It reads raw objects, not diff text: the full raw
commit object (author, committer, mergetag, encoding, gpgsig and message), every tree-entry path
(gitlinks included), and for every added or modified blob its raw bytes. Lines of the new blob that are
absent from the parent blob are the added lines. Diff attributes, textconv, `bigFileThreshold`, binary
classification and `+++` content cannot hide a line. Bytes are decoded as latin-1; a blob containing NUL
bytes is also decoded as UTF-16 little and big endian. Any finding is a refusal:

- an added line or commit-object line matching a credential heuristic: GitHub tokens (`ghp_`, `gho_`,
  `ghu_`, `ghs_`, `ghr_`, `github_pat_`), `sk-` keys, `sk_live_`/`sk_test_`, Slack `xox[abpr]-`, `AKIA`
  plus 16 characters, a PEM `BEGIN ... PRIVATE KEY` header, JWT-shaped strings, `password`/`secret`/
  `token`/`api_key` assignments whose value is 8 or more characters with a digit or mixed case, and
  `bearer` plus a long token; URL userinfo (`://user:password@`), npm, GitLab (`glpat-`), Hugging Face
  (`hf_`), Google API (`AIza`) and SendGrid (`SG.`) tokens, an `aws_secret_access_key` assignment and an
  `Authorization: Basic` header. The generic keyword rule deliberately requires a value of 8 or more
  characters with a digit or mixed case, so low-entropy values such as `password: changeme-please` pass;
- a credential-shaped path, or an added or modified path whose basename matches `.env*`, `*.pem`,
  `*.key`, `id_rsa*`, `id_ed25519*`, `*credentials*`, `*.p12` or `*.keychain*`;
- a blob over 50 MB (refused outright, never partially scanned) or a Git LFS pointer (its payload is not
  validated, but the pointer text is still scanned);
- anything that cannot be fully read: a failing, short or malformed `cat-file --batch-check` or `--batch`,
  or unparseable `diff-tree` output.

A refusal prints the short commit OID, the path, the line number and the rule name, and never a matched
value. Every printed field passes through one sanitizer that replaces credential-shaped substrings with
`<redacted>` and escapes control characters, bidirectional controls (U+200E/F, U+202A-E, U+2066-9) and the
line and paragraph separators U+2028/9; this covers paths, branch names and error text. Subprocess stderr is
discarded. All output goes through one printer that tolerates a missing, closed or broken stdout and stderr
(including `None`): a write failure is swallowed and never changes the exit code. With both closed, a push
still runs and exits 0 or 3, but its refusal text cannot be seen, so check the exit code.

**There is no override.** A refusal tells the agent to leave the commits as they are and report it; the owner
reviews the listed commits and, if they are false positives, pushes by hand.

### Limits

This is a heuristic backstop, not a guarantee, and it does not replace skimming `git log --stat @{u}..HEAD`
before pushing. It misses secrets without a recognisable shape, secrets split across lines, encoded or
encrypted content, other text encodings, and secrets inside archives, and it flags benign text that
resembles a key. Passing the scan does not make a commit safe to publish.

## Tests

`assets/scripts/vault-sync.test.sh` is hermetic: a temp bare repo is the remote, a temp clone is the vault
with a github.com URL, and a git wrapper outside the script maps the canonical URL to the local bare repo,
logs every invocation, its `GIT_*` environment and the transport config it was given, and injects faults
(a failing `batch-check`, a failing push, a lying `ls-remote`, a commit landing after the pin). `gh` is a
fake on `PATH`. `HOME` is temporary and nothing touches the network. Credential-shaped fixtures are
assembled at run time. CI runs it as a named step in `validate-registry.yml`.
