# /release

Ship a new version of this project end to end: run the release gates, bump the version, build the artifacts, publish, tag, and verify. One command that encodes the project's release checklist so a release never skips a step or ships a broken build.

Use this **after** changes are merged and the working tree is clean. For diagnosing a *failed* publish or a broken local setup, use `/doctor`. For dependency upkeep before a release, use `/deps`.

## Arguments

- `$ARGUMENTS` — release configuration. Space-separated tokens:
  - First positional: version bump — `patch` | `minor` | `major` | an explicit version like `1.4.0` (default: `patch`).
  - `--dry-run` — run every gate and show what *would* happen, but do not bump, publish, tag, or push.
  - `--no-publish` — bump, build, tag locally, but skip the publish step (for a build-only or manual-publish release).
  - `--from=REF` — base ref for changelog/notes (default: the previous release tag).

Examples:
```
/release                  # patch release, full pipeline
/release minor
/release 2.0.0 --dry-run  # rehearse a major release
/release patch --no-publish
```

## Instructions

### 1. Preflight (stop on any failure)

Confirm the release can safely proceed. Abort with a clear message if any check fails:

- **Clean working tree** — no uncommitted or staged changes (`git status --porcelain` is empty). A release must build from committed state.
- **Correct branch** — on the release branch {{CUSTOMIZE: name the release branch, e.g. "main" — the branch releases are cut from}} and up to date with the remote (`git fetch` then compare).
- **Authenticated** — the publish credentials/registry login are present {{CUSTOMIZE: how this project authenticates to its publish target, e.g. "npm whoami succeeds" or "logged in to the container registry"; remove if the project does not publish anywhere}}.

State the resolved bump type and the current → next version before doing anything mutating.

### 2. Run the release gates

Run the project's full verification suite. **Every gate must pass** before the version is touched — a release must never ship red.

{{CUSTOMIZE: the exact gate commands this project requires before release, one per line, e.g. "npm run typecheck", "npm run lint", "npm test", "npm run build". List them in the order they should run, fastest/cheapest first. If a gate is known to be flaky or slow, note it.}}

If any gate fails, stop and report which one — do not continue to the bump.

### 3. Bump the version

Bump per the resolved type from step 1.

{{CUSTOMIZE: the version-bump mechanism, e.g. "npm version <type> --no-git-tag-version" or editing a VERSION file / Cargo.toml. Note whether the tool also creates a git tag/commit so step 6 doesn't double-tag.}}

### 4. Update release notes / changelog

Generate the release notes for the changes since `--from` (default: previous release tag). **Prefer the `/changelog` skill** — invoke it for the range (`/changelog --from=<prev tag> --version=<new version>`) and use its rendered section as the release notes. If `/changelog` is not installed, fall back to generating notes directly from merged PR titles / commit subjects in range.

{{CUSTOMIZE: where release notes live and the format, e.g. "prepend a section to CHANGELOG.md" or "draft a GitHub release body"; remove if this project keeps no changelog.}}

### 5. Build the release artifacts

Produce the exact artifacts that will be published — never publish from a stale build.

{{CUSTOMIZE: the build/packaging command(s) that produce the publishable artifact, e.g. "npm run build" or "npm pack" to inspect the tarball contents first. Note any files that must be present in the artifact.}}

### 6. Publish

If `--dry-run` or `--no-publish`, skip this step and say so.

Publish to the project's distribution target.

{{CUSTOMIZE: the publish command and target registry, e.g. "npm publish --access public". CALL OUT any publish footguns specific to this project here — interactive auth/OTP prompts, "do not retry on a prompt that may have already succeeded", whether to show full output so an auth URL is visible, and any pre-publish check (e.g. run the linter independently first) that has bitten past releases. These hard-won details are the whole point of having a release skill.}}

Show the publish output in full — do not truncate it, so any auth URL, OTP prompt, or warning is visible to the user.

### 7. Tag and push

If `--dry-run`, skip. Otherwise:

- Commit the version bump (and changelog) if the bump tool did not.
- Create an annotated tag for the new version (skip if step 3's tool already tagged).
- Push the commit and the tag to the remote {{CUSTOMIZE: remote/branch, e.g. "origin <release branch>"; note if the project forbids direct pushes to the release branch and requires a PR instead}}.

Do not force-push.

### 8. Post-publish verification

Confirm the release is actually live and usable — a publish that "succeeded" can still be unconsumable.

{{CUSTOMIZE: how to verify the published release, e.g. "the registry shows the new version" / "a fresh install of the published package starts cleanly" / "the new version's entrypoint runs". Prefer a check that exercises the published artifact, not just metadata.}}

### 9. Report

Summarize concisely:

```markdown
## Released: <name> <new version>

- **Gates:** <pass/fail per gate>
- **Published:** <target> (or "skipped — --no-publish/--dry-run")
- **Tag:** <tag> pushed to <remote>
- **Verified:** <post-publish check result>
- **Notes:** <link or summary of changes shipped>
```

If `--dry-run`, make clear that nothing was bumped, published, tagged, or pushed.

## Customization Points

- **Release branch & remote** — which branch releases are cut from and pushed to; whether direct push is allowed or a PR is required.
- **Authentication** — how the project authenticates to its publish target (npm login, registry token, none).
- **Gate commands** — the exact typecheck/lint/test/build commands that must pass pre-release, in order.
- **Version-bump mechanism** — the command or file edit that bumps the version, and whether it auto-tags.
- **Changelog** — where release notes live and their format; or remove if none.
- **Build/packaging** — the command that produces the publishable artifact.
- **Publish command + footguns** — the publish command, target registry, and any hard-won publish gotchas (OTP/interactive auth, don't-retry semantics, pre-publish lint). This is the highest-value spot to tailor.
- **Post-publish verification** — the check that proves the release is live and consumable.
