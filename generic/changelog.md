# /changelog

Generate release notes from what actually merged: collect the merged PRs and commits since the last release, group them into meaningful sections, and write them to the project's changelog (or a draft release body). Turns "what changed since the last version?" into a formatted, linked summary instead of a hand-scrolled git log.

Use this standalone to draft notes, or let `/release` invoke it as its notes step. For shipping the version itself, use `/release`.

## Arguments

- `$ARGUMENTS` — configuration. Space-separated tokens:
  - `--from=REF` — start of the range (default: the previous release tag, e.g. `git describe --tags --abbrev=0`).
  - `--to=REF` — end of the range (default: `HEAD`).
  - `--version=X` — the version label to head the new section with (default: `Unreleased`).
  - `--output=DEST` — where to write: the changelog file (default), `release` to draft a GitHub release body, or `-` for stdout only.

Examples:
```
/changelog                          # notes since the last tag, into the changelog file
/changelog --version=1.4.0
/changelog --from=v1.2.0 --to=v1.3.0 --output=-
/changelog --output=release         # draft a GitHub release body
```

## Instructions

### 1. Resolve the range

Determine `FROM..TO`:

```bash
FROM=${from:-$(git describe --tags --abbrev=0 2>/dev/null)}
TO=${to:-HEAD}
```

If there is no prior tag (first release), use the repository's root commit as the start and say so in the output. State the resolved range before collecting.

### 2. Collect what changed in the range

Prefer **merged PRs** (richer titles, labels, author, and a link) and fall back to commit subjects where a change landed without a PR.

```bash
# Merged PRs whose merge commit is in range (gh + git):
git log --merges --first-parent ${FROM}..${TO} --pretty='%s'   # "Merge pull request #N ..."
# Or, for squash-merge repos, PRs by merge date:
gh pr list --state merged --base <release branch> --json number,title,labels,mergedAt,url \
  --search "merged:>=$(git log -1 --format=%cs ${FROM})"
# Direct commits not from a PR:
git log ${FROM}..${TO} --no-merges --pretty='%s (%h)'
```

{{CUSTOMIZE: how this project merges (squash vs merge-commit) and therefore how to enumerate what shipped — e.g. "squash-merge: use `gh pr list --state merged` filtered by date" or "merge commits: use `git log --merges --first-parent`". Name the release branch. If the project tags every release, the previous-tag default is reliable; note if it doesn't.}}

### 3. Categorize into sections

Group entries into the changelog's sections. Derive the category from each change's conventional-commit type or PR label.

{{CUSTOMIZE: the categorization scheme and section headings this project uses, e.g. Keep a Changelog (Added / Changed / Fixed / Removed / Security) mapped from conventional-commit types (feat→Added, fix→Fixed, refactor/perf→Changed, …) or from PR labels. Name the type/label → section mapping. If the project has no convention, default to grouping by conventional-commit type.}}

- Omit purely internal noise (merge commits themselves, version-bump commits, `chore` that ships nothing user-facing) unless the project's convention says otherwise.
- Each entry: a one-line description in past tense, the PR/issue link (`(#123)`), and scope where it sharpens meaning.
- Note **breaking changes** prominently (a `!` in the type or a `BREAKING CHANGE:` footer) — call them out at the top of the section.

### 4. Render the new section

```markdown
## [<version>] - <date>

### Added
- Short description (#123)

### Fixed
- Short description (#130)
```

Use `--version` for the heading (default `Unreleased`). Use today's date (`YYYY-MM-DD`) — take it from the environment, do not invent one.

### 5. Write to the destination

- **Changelog file (default):** prepend the new section directly under the top header / `Unreleased` marker, preserving the rest of the file. Create the file with a standard header if it does not exist.
- **`--output=release`:** emit the section as a GitHub release body (e.g. for `gh release create`/`gh release edit`) rather than editing a file.
- **`--output=-`:** print to stdout only; write nothing.

{{CUSTOMIZE: the changelog file path and format for this project (e.g. `CHANGELOG.md` in Keep a Changelog format with an `## [Unreleased]` section). If the project keeps no changelog file and publishes notes only as GitHub releases, say so and default `--output` to `release`.}}

### 6. Report

State the resolved range, the version/section written, the destination, and counts per category. If invoked by `/release`, return the rendered section so the release step can use it.

## Notes

- **Don't invent history.** Every entry must trace to a real merged PR or commit in range. If a change has no PR and an unclear commit subject, list it under its best-guess category and flag it rather than fabricating a description.
- **Idempotent on the file.** Re-running for the same version should replace that version's section, not append a duplicate.
- **No attribution.** No AI/agent mentions in the changelog, commits, or release body — the entries describe the work, not who wrote them.

## Customization Points

- **Merge style & enumeration** — squash vs merge-commit, the release branch, and the command that reliably lists what shipped in a range.
- **Categorization scheme** — the section headings and the conventional-commit-type / PR-label → section mapping.
- **Changelog location & format** — the changelog file path and format, or whether the project uses GitHub releases instead of a file.
