# Merge Gate Pattern

## Purpose

Short-circuit token-expensive diagnostic reasoning when `gh pr merge` fails due to branch protection. The most common blocker is unresolved review threads, which **only a human can resolve** via GitHub UI. This pattern turns a multi-step investigation into a 2-line handoff.

## The Problem

Without this pattern, when merge fails the agent:
1. Reads the error message
2. Reasons about possible causes
3. Runs `gh pr checks` to investigate
4. Composes a thoughtful diagnostic message
5. Asks the user what to do

All of that is wasted tokens — the answer is almost always "go resolve threads."

## CLAUDE.md Snippet

Add this to your repo's CLAUDE.md in the PR Workflow / merge section:

```markdown
**Merge Gate — MANDATORY short-circuit when merge is blocked:**

When `gh pr merge` fails with "base branch policy prohibits the merge":
1. **Do NOT investigate, reason about, or run diagnostic commands.** The cause is almost always unresolved review threads.
2. **Immediately respond with exactly this** (filling in the PR number):
   > Merge blocked — unresolved review threads. Please resolve them here:
   > https://github.com/{OWNER}/{REPO}/pull/{N}/files
   >
   > Say "done" when resolved.
3. **Wait for user confirmation**, then retry `gh pr merge --squash`.
4. If it fails a second time, THEN check `gh pr checks` for CI failures.
```

## Customization

- Replace `{OWNER}/{REPO}` with actual repo coordinates
- Adjust merge strategy (`--squash`, `--merge`, `--rebase`) per repo convention
- If a repo doesn't enforce comment resolution, this pattern is harmless but unnecessary

## Why This Works

- **Set once, forget forever** — lives in CLAUDE.md, loaded every session
- **Zero wasted tokens** — skips all diagnostic reasoning on first failure
- **Human intervention point** — only humans can resolve threads via GitHub UI
- **Graceful fallback** — second failure triggers real investigation

## Repos Using This Pattern

| Repo | Branch Protection | Comment Resolution Required |
|------|------------------|----------------------------|
| exodus-loop | Yes | Yes |
| chroxy | Yes | Yes |
| archery-apprentice | TBD | TBD |
| repo-relay | TBD | TBD |
| claude-code-notify | TBD | TBD |
