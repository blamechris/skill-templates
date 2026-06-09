# /rollback

Back out a bad change or a broken release safely — revert the offending merged PR, mark the bad published version so nobody new installs it, and ship a corrected version. The counterpart to `/release`: when something shipped that shouldn't have, this is the controlled path back to a good state without breaking people who already have the bad version.

Use this when a merged PR broke `main`, or a published version is broken in the wild. For shipping a normal new version, use `/release`.

## Arguments

- `$ARGUMENTS` — what to back out. Space-separated tokens:
  - `--revert=PR` — revert a merged pull request (by number) via a new revert PR.
  - `--deprecate=VERSION` — mark a published version as bad so new installs avoid it (does NOT delete it).
  - `--reason="..."` — short reason, used in the revert PR body and the deprecation message.
  - `--dry-run` — show what would be reverted/deprecated; change nothing.

Examples:
```
/rollback --revert=142 --reason="broke cache invalidation"
/rollback --deprecate=1.4.0 --reason="crashes on startup; use 1.4.1"
/rollback --revert=142 --deprecate=1.4.0 --reason="bad release"
```

## Instructions

### 1. Identify exactly what's bad

Pin down the offending change and its blast radius before touching anything:

- The merged PR / commit that introduced the problem (`gh pr view`, `git log`, `git bisect` if unclear).
- Whether a **published version** carries the bug (and which versions). A broken `main` that was never released only needs a revert; a broken *published* version also needs deprecation + a fixed release.
- What a *good* known state is (the last version/commit that worked) — that's the target to point users back to.

State the plan (revert? deprecate? both? corrected release?) before executing.

### 2. Revert the bad change (if `--revert`)

Reverting (not force-resetting) preserves history and goes through the normal review gate.

```bash
git revert --no-edit <merge-or-commit-sha>   # use -m 1 for a merge commit
```

- For a squash-merged PR, revert the single squash commit; for a merge-commit, `git revert -m 1 <merge sha>`.
- Put the revert on a branch and open a PR — a revert is a normal change and must pass the same gates and review.

{{CUSTOMIZE: how this repo lands changes — branch + PR vs direct push, the merge method, and the gate the revert PR must pass before merge. Reuse the project's standard flow.}}

If reverting conflicts (later changes built on the bad one), resolve forward — revert what you can cleanly and fix the rest in the same PR, rather than leaving a half-reverted tree.

### 3. Deprecate the bad published version (if `--deprecate`)

Mark the bad version so new installs steer away — **do not delete/unpublish it**. Unpublishing breaks everyone who pinned it and can be irreversible; deprecation is the safe, reversible signal.

{{CUSTOMIZE: the registry's deprecate command and policy, e.g. `npm deprecate <pkg>@<version> "<reason>; use <good version>"`. Note the project's stance: prefer deprecate over unpublish; only unpublish within the registry's safe window AND when the version has no dependents. If the project doesn't publish to a registry, REMOVE THIS MARKER LINE and treat rollback as revert-only.}}

The deprecation message should name the **good version** to use instead, so anyone hitting the warning knows where to go.

### 4. Ship the corrected version

A deprecation alone leaves users on an old-but-good version; ship a fixed release so the latest is healthy again.

- After the revert (and any forward fix) is merged, cut a new **patch** release via `/release` (or the project's release flow) so the newest published version is good.
- The corrected version should be the one the deprecation message points to.

### 5. Verify the good state is the default

Confirm a fresh consumer now gets a working version:

{{CUSTOMIZE: how to verify recovery, e.g. "a fresh install of the latest published version starts cleanly" / "the registry's latest tag resolves to the corrected version" / "main is green". Prefer a check that exercises the artifact a new user would actually get.}}

### 6. Report

```markdown
## Rollback complete

- **Reverted:** PR #<n> (<sha>) via revert PR #<m> (or "—")
- **Deprecated:** <pkg>@<version> → use <good version> (or "—")
- **Corrected release:** <new version> (or "pending /release")
- **Verified:** <recovery check result>
- **Reason:** <reason>
```

If `--dry-run`, make clear nothing was reverted, deprecated, or released.

## Notes

- **Deprecate, don't delete.** Removing a published version breaks pinned installs and CI elsewhere. Deprecation warns without breaking, and is reversible.
- **A revert is a normal change.** It goes through the same gates and review as any other PR — don't push reverts straight to a protected branch.
- **Forward-fix when revert is messy.** If too much was built on the bad change to revert cleanly, the safe path is often a corrective patch rather than an entangled revert; choose whichever leaves a coherent tree.
- **No attribution** in revert PRs, deprecation messages, or release notes.

## Customization Points

- **Change-landing flow** — branch + PR vs direct push, merge method, and the gate a revert PR must pass.
- **Deprecate command + policy** — the registry's deprecate command, and the deprecate-over-unpublish stance (or revert-only if the project doesn't publish).
- **Recovery verification** — the check that proves a fresh consumer now gets a working version.
