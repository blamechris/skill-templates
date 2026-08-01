# /fetch-docs

Sync a companion documentation repo (e.g., Obsidian vault) so agents can reference design docs, architecture notes, and project knowledge during development.

## Arguments

- `$ARGUMENTS` - Optional: specific doc path or search term. If empty, syncs the full repo and lists key docs.

## Instructions

### 1. Sync Docs Repo

**Sync first, always.** An existing clone is stale until it is refreshed, and reading
it unrefreshed serves last month's design as if it were current — a failure nobody
notices, because the docs still read as plausible.

```bash
# {{CUSTOMIZE: Companion docs repo URL and local clone path}}
DOCS_REPO="owner/project-docs"
DOCS_PATH="$HOME/path/to/project-docs"

# A failed sync must ABORT. The whole point of this step is that an unrefreshed
# clone silently serves stale docs — and a `pull` that fails (no network, a
# conflicted rebase, auth expiry) leaves exactly that, only now you have also
# printed "Pulling latest docs..." and look current.
if [ -d "$DOCS_PATH/.git" ]; then
  echo "Pulling latest docs..."
  git -C "$DOCS_PATH" pull --rebase 2>&1 || {
    echo "STOP: docs pull failed — the clone at $DOCS_PATH is stale. Fix it before citing docs." >&2
    exit 1
  }
else
  echo "Cloning docs repo..."
  git clone "https://github.com/${DOCS_REPO}.git" "$DOCS_PATH" 2>&1 || {
    echo "STOP: docs clone failed — there is nothing to read." >&2
    exit 1
  }
fi
```

### 2. List Key Docs

After syncing, list the most important reference docs:

```bash
# {{CUSTOMIZE: Key doc files and their descriptions — the files agents reference most often}}
echo "Key docs available at ${DOCS_PATH}:"
# e.g., GDD, architecture overview, API specs, glossary
```

Output a table of key docs with brief descriptions so the agent knows what's available:

```markdown
## Docs Synced

| Doc | Path | Description |
|-----|------|-------------|
| ... | ... | ... |
```

### 3. Search or Read (if arguments provided)

**Classify `$ARGUMENTS` before using it — resolve it against the filesystem, then assign `DOC_PATH` on the path branch or `SEARCH_TERM` on the search branch.**

Neither variable may be referenced unassigned. An empty search pattern makes
`grep -ril` succeed against every file in the repo, so the skill reports the whole
vault as a hit rather than failing where you would see it.

```bash
# DOCS_PATH is set in step 1. Re-set it here if you run this block on its own.
DOCS_PATH="${DOCS_PATH:-$HOME/path/to/project-docs}"  # {{CUSTOMIZE: same clone path as step 1}}
[ -d "$DOCS_PATH" ] || { echo "Docs not synced yet — run step 1 first."; exit 1; }

# A real file or directory under $DOCS_PATH is a doc path; anything else is a term.
ARG="$(printf '%s' "$ARGUMENTS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [ -z "$ARG" ]; then
  echo "No argument — sync and key-doc listing only; nothing to read or search."
elif [ -e "$DOCS_PATH/$ARG" ]; then
  DOC_PATH="$ARG"
  echo "Reading ${DOC_PATH}:"
  if [ -d "$DOCS_PATH/$DOC_PATH" ]; then
    find "$DOCS_PATH/$DOC_PATH" -type f -name '*.md' | sort | head -20
  else
    cat "$DOCS_PATH/$DOC_PATH"
  fi
else
  SEARCH_TERM="$ARG"
  echo "Searching for '${SEARCH_TERM}':"
  # {{CUSTOMIZE: file globs to search — `*.md` for Obsidian, `*.adoc` for AsciiDoc}}
  { grep -ril --include='*.md' -e "$SEARCH_TERM" "$DOCS_PATH" 2>/dev/null || true
    find "$DOCS_PATH" -type f -iname "*${SEARCH_TERM}*.md" 2>/dev/null || true
  } | sort -u | head -20
fi
```

Output matching docs or the requested doc content.

## Customization Points

Lines and sections marked with `{{CUSTOMIZE}}` need repo-specific adaptation:

- **Docs repo URL** — GitHub `owner/repo` for the companion docs repo
- **Local clone path** — where to clone the docs locally (e.g., `~/Projects/exodus-loop-docs`)
- **Key doc files** — table of important reference docs with descriptions
- **Search patterns** — file extensions to search (`.md` for Obsidian, `.adoc` for AsciiDoc, etc.)
