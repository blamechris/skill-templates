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

- `set` handles a strict subset of YAML and refuses everything else (exit 1, file
  untouched): top-level `key: value` lines; scalar lifecycle values on one line with an
  optional trailing `# comment` (kept byte for byte; an unquoted `#` tail is never part of
  the value, so `status: delivered # merged` is `delivered`); `decisions` absent, empty,
  a one-line `[a, b]` list with no nested brackets (a trailing comment stays after the
  list) or a contiguous `- item` block. It also refuses duplicate lifecycle keys, comment
  or blank lines inside an edited key's span, multi-line values, a read-only file, and a
  file with a UTF-8 BOM before the opening `---` (reported by `check` as having no
  frontmatter). Before writing it re-parses the result and refuses unless every prior and
  new decision id is present, every other key is unchanged and every byte outside the
  edited key lines is identical. A best-effort guard refuses if the file changed (mtime,
  size or content hash) between the read and the rename; it narrows, not closes, that
  race. CRLF line endings are preserved.
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
  frontmatter if later, is on or after `--since`.
- Exit codes: `check` and `scan` exit 0 after a completed report whatever they found, and 2
  on a usage error or unreadable input. `set` exits 0 on success and 1 on a refusal.

## Scope and effective date

The rule applies to new plans and to plans touched on or after **2026-11-15**, which is the
default `--since` of `scan`. There is no bulk migration: an old plan keeps its free-text
status until someone touches it, and then `set` moves it onto the contract.
