# /fetch-docs

Sync a companion documentation repo (e.g., Obsidian vault) so agents can reference design docs, architecture notes, and project knowledge during development.

## Arguments

- `$ARGUMENTS` - Optional: specific doc path or search term. If empty, syncs the full repo and lists key docs.

## Instructions

### 1. Sync Docs Repo

```bash
# {{CUSTOMIZE: Companion docs repo URL and local clone path}}
DOCS_REPO="owner/project-docs"
DOCS_PATH="$HOME/path/to/project-docs"

if [ -d "$DOCS_PATH/.git" ]; then
  echo "Pulling latest docs..."
  git -C "$DOCS_PATH" pull --rebase 2>&1
else
  echo "Cloning docs repo..."
  git clone "https://github.com/${DOCS_REPO}.git" "$DOCS_PATH" 2>&1
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

If `$ARGUMENTS` contains a search term or path:

```bash
# Search doc titles and content
grep -ril "${SEARCH_TERM}" "${DOCS_PATH}" --include="*.md" | head -20

# Or read a specific doc
cat "${DOCS_PATH}/${DOC_PATH}"
```

Output matching docs or the requested doc content.

## Customization Points

Lines and sections marked with `{{CUSTOMIZE}}` need repo-specific adaptation:

- **Docs repo URL** — GitHub `owner/repo` for the companion docs repo
- **Local clone path** — where to clone the docs locally (e.g., `~/Projects/exodus-loop-docs`)
- **Key doc files** — table of important reference docs with descriptions
- **Search patterns** — file extensions to search (`.md` for Obsidian, `.adoc` for AsciiDoc, etc.)
