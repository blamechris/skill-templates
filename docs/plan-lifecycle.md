# Plan lifecycle

A plan is a note an agent writes to propose, scope or track a piece of work. Plans live in
a private vault, one Markdown file each, with a YAML frontmatter block. Until now the
`status:` field was free text and nothing kept it current: agents recorded progress by
appending update blockquotes to the body and left the header alone, so a plan whose work
had been approved, merged and was mid-delivery still read as an unreviewed proposal. This
contract fixes the vocabulary, the transitions and the one writer that changes them.

## Frontmatter

```yaml
---
type: plan
status: in-delivery
status_updated: 2026-11-15T09:30Z
# superseded_by: <plan>   (required only when status is superseded; put a value on the key line)
decisions: [DEC-0042]     # optional
---
```

| Key | Rule |
|-----|------|
| `type` | `plan`. |
| `status` | Exactly one of `proposal`, `accepted`, `in-delivery`, `delivered`, `superseded`, `abandoned`. |
| `status_updated` | UTC timestamp `YYYY-MM-DDTHH:MMZ`, set whenever `status` changes. |
| `superseded_by` | Required when `status` is `superseded`: the plan (path, title or id) that replaces this one. |
| `decisions` | Optional list of decision-record ids. The ids are references only: nothing here reads or validates the decision ledger, and nothing in code couples the two. |

## States and transitions

| State | Meaning | May move to |
|-------|---------|-------------|
| `proposal` | Written, awaiting the owner's go. | `accepted`, `abandoned` |
| `accepted` | Owner approved; no delivery PR yet. | `in-delivery`, `superseded`, `abandoned` |
| `in-delivery` | At least one PR for it has been opened. | `delivered`, `superseded`, `abandoned` |
| `delivered` | The work is merged and verified. Terminal. | `superseded` |
| `superseded` | Replaced by another plan. Terminal. | `superseded` (to re-point `superseded_by`) |
| `abandoned` | Dropped. Terminal. | `superseded` |

A terminal state changes only to `superseded`. Setting a plan to the status it already has
is allowed and only refreshes `status_updated` or adds decision ids.

Change the status when the state changes, not at the end: owner acceptance (`accepted`),
the first PR (`in-delivery`), verified merge (`delivered`).

## The frontmatter is authoritative

The header is the one place a reader looks. Body update blocks are allowed and useful as a
narrative, for example:

```markdown
> **Update 2026-11-15T09:30Z** first PR opened
```

Prefer timestamped stamps (`> **Update YYYY-MM-DDTHH:MMZ`); a date-only stamp is only
compared by date.

but they never replace the header: when the state changes, change `status` too. The linter
flags a `status_updated` older than the newest body update stamp it can find.

## The writer and the linter

`assets/scripts/plan-status.py` is the only supported way to change these keys:

```bash
python3 ~/.claude/scripts/plan-status.py set <plan.md> --status accepted
python3 ~/.claude/scripts/plan-status.py set <plan.md> --status superseded --superseded-by <other-plan>
python3 ~/.claude/scripts/plan-status.py set <plan.md> --status in-delivery --decision DEC-0042
python3 ~/.claude/scripts/plan-status.py check <plan.md>...
python3 ~/.claude/scripts/plan-status.py scan [--dir D] [--since YYYY-MM-DD]
```

- Closed frontmatter grammar. Before any edit, `set` validates the whole frontmatter
  against these line shapes and refuses (exit 1, file untouched, before any temp file is
  made) if one line falls outside them; `check` warns `unsupported frontmatter syntax at
  line N`. The shapes are: a comment line (`^\s*#`); a blank line outside any value span;
  a column-0 `key: value` with an unquoted key matching `[A-Za-z_][A-Za-z0-9_-]*`; and an
  indented `- item` line directly following a key with an empty value (or another item).
  A value starting with `"`, `'` or `[` must be complete on its own line: a closed
  quoted scalar, or a balanced one-line flow list with no nested brackets (so Obsidian
  `[[links]]` as a value are outside the subset). A value starting with `{`, `|`, `>`,
  `&`, `*` or `!` is never supported. This applies to every key, not only lifecycle keys.
  Quoted keys, `...`, column-0 `- x`, multi-line scalars and blank or comment lines inside
  a block list are therefore refused.
- Lifecycle scalars (`status`, `status_updated`, `superseded_by`) are plain or
  double-quoted; a double-quoted one supports only the `\\` and `\"` escapes, and any other
  backslash escape is refused. An unquoted `#` tail is a comment, kept byte for byte, never
  part of the value (`status: delivered # merged` is `delivered`). `superseded_by` is
  written plain only when it is id-style (below), otherwise double-quoted with those two
  escapes, which `check` decodes back to the same text.
- Decision ids, new and existing, match `[A-Za-z][A-Za-z0-9._-]*` and are not one of
  `null true false yes no on off y n ~` (any case); so no colon, no leading digit, no date or
  number. Decision-ledger ids of the form `dec-<12 hex>` pass. An existing quoted item that
  passes may be re-emitted plain; one that fails is refused, never retyped. `decisions` is
  validated whether or not it is being edited: absent, empty, a one-line `[a, b]` list (a
  trailing comment is kept) or a contiguous `- item` block.
- A frontmatter line containing a lone CR, VT, FF, U+0085, U+2028 or U+2029 (line breaks YAML honours but this script does not split on) is outside the grammar. A plain `null`/`~`/`Null` `superseded_by` is YAML null and counts as empty; `--superseded-by` values with control, line-break, non-character or surrogate characters are refused. `set` does not repair or validate YAML in keys it does not edit.
- `set` also refuses duplicate lifecycle keys, comment or blank lines inside an edited
  key's span, a read-only file, and a file with a UTF-8 BOM before the opening `---`
  (`check` reports it as having no frontmatter). After building the result it re-validates
  the grammar and re-parses it, and refuses unless every prior and new decision id is
  present, the decoded lifecycle values are as asked, every other key is unchanged and
  every byte outside the edited key lines is identical. A best-effort guard refuses if the
  file changed (mtime, size or content hash) between the read and the rename; it narrows,
  not closes, that race. CRLF line endings are preserved.
- `set` rewrites only `status`, `status_updated`, and when given `superseded_by` and
  `decisions`; every other byte of the file is preserved and the write is atomic (temp file
  in the same directory, then rename). It refuses an illegal transition, a missing file or a
  file with no frontmatter block (exit 1). A legacy free-text status, or none, may move to
  any status: that is the migration path when an old plan is touched. `set` never runs git;
  it prints the `git add` and `git commit` lines and the writer commits under the vault's
  existing rule.
- `check` is a report-only lint: `OK <file>` or `WARN <file> <reason>`. It warns on a missing
  or unknown status, a duplicated lifecycle key, a missing or malformed `status_updated`, a `superseded` plan with no
  `superseded_by`, and a `status_updated` earlier than a valid body update stamp (malformed stamps are ignored). The
  stamp heuristic is a line (outside code fences, matched by opener character and length) beginning `> **Update YYYY-MM-DD`,
  optionally followed by `THH:MM` or `THH:MMZ`; a date-only stamp counts as stale only when
  its date is after the date of `status_updated`.
- `scan` runs `check` over `*.md` in the plans directory (`--dir`, else `$CLAUDE_PLAN_DIR`,
  else `~/Obsidian/no-it-all/plans`) for plans whose modification date, or `date:`
  frontmatter if later, is on or after `--since` (strictly `YYYY-MM-DD`, a real date).
- Exit codes: `check` and `scan` exit 0 after a completed report whatever they found, and 2
  on a usage error or unreadable input. `set` exits 0 on success and 1 on a refusal.

## Scope and effective date

The rule applies to new plans and to plans touched on or after **2026-11-15**, which is the
default `--since` of `scan`. There is no bulk migration: an old plan keeps its free-text
status until someone touches it, and then `set` moves it onto the contract.
