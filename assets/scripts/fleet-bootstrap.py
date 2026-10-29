#!/usr/bin/env python3
"""Install the Fleet root and provider adapters. Dry-run unless --apply is passed.

Python 3.11+. Existing differing files require --replace-existing after reviewing
machine-only defaults and re-supplying private blocks with --local-rules (or an
explicit --discard-local). --restore BACKUP restores the listed bytes and modes.
Claude activation additionally requires a recorded live
import check (--claude-import-verified). Backups are private and never committed.
"""
import argparse
import datetime
import importlib.util
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
try:
    import tomllib
except ImportError:
    print('fleet-bootstrap: Python 3.11+ is required (for example python3.12).', file=sys.stderr)
    sys.exit(2)


def fail(message):
    raise ValueError(message)


def config_text(text):
    data = tomllib.loads(text)
    old = data.get('project_doc_max_bytes', 32768)
    if type(old) is not int or old <= 0:
        fail('project_doc_max_bytes must be a positive integer')
    if old >= 65536:
        return text
    # Only a top-level assignment can set this option. Preserve all other settings.
    table = re.search(r'^\s*\[', text, re.M)
    split = table.start() if table else len(text)
    head, tail = text[:split], text[split:]
    pattern = r'^\s*project_doc_max_bytes\s*=.*$'
    if re.search(pattern, head, re.M):
        head = re.sub(pattern, 'project_doc_max_bytes = 65536', head, flags=re.M)
    else:
        head = 'project_doc_max_bytes = 65536\n' + head
    result = head + tail
    if tomllib.loads(result).get('project_doc_max_bytes') != 65536:
        fail('could not safely update instruction cap')
    return result


def atomic_write(path, content, source_mode=0o600, *, restore_mode=None):
    """Replace atomically, retaining an incumbent mode or the source mode."""
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = (restore_mode if restore_mode is not None else
            stat.S_IMODE(path.stat().st_mode) if path.exists() else source_mode)
    fd, temporary = tempfile.mkstemp(prefix='.fleet-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(content.encode('utf-8') if isinstance(content, str) else content)
            os.fchmod(out.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def reject_symlinks(path):
    for component in (path, *path.parents):
        if component.is_symlink():
            fail(f'{component} is a symlink; reconcile explicitly before replacing it')


def check_destination_shape(path):
    """Reject predictable layout errors before any member of a plan is written."""
    if path.exists() and not path.is_file():
        fail(f'{path} is not a regular-file destination')
    for parent in path.parents:
        if parent.exists() and not parent.is_dir():
            fail(f'{parent} is not a directory; cannot write {path}')


def raw_rules(text, check):
    """Retain block contents, including headings, for private-data preservation."""
    blocks, current, rule_class, body = {}, None, None, []
    for line in text.splitlines(keepends=True):
        token = check.TOKEN.match(line.rstrip('\r\n'))
        if token:
            if current is not None:
                blocks[current] = (rule_class, ''.join(body).strip('\r\n'))
            current = token.group(2)
            if current in blocks:
                fail(f'incumbent or local rules duplicate block ID {current}; reconcile explicitly')
            rule_class, body = token.group(1), []
        else:
            body.append(line)
    if current is not None:
        blocks[current] = (rule_class, ''.join(body).strip('\r\n'))
    return blocks


def restore_backup(args, home, codex_home):
    """Preflight the complete manifest before restoring any byte or mode."""
    backup = args.restore.expanduser()
    if backup.is_symlink():
        fail(f'{backup} is a symlink; reconcile explicitly before reading backups')
    # Canonicalize OS aliases such as macOS /tmp before checking backup members.
    backup = backup.resolve()
    reject_symlinks(backup)
    manifest = backup / 'paths.txt'
    reject_symlinks(manifest)
    targets = manifest.read_text(encoding='utf-8').splitlines()
    if not targets or len(set(targets)) != len(targets):
        fail('restore manifest must contain unique absolute target paths')
    allowed = {home / '.fleet/AGENTS.md', codex_home / 'AGENTS.md',
               codex_home / 'config.toml', home / '.gemini/GEMINI.md',
               home / '.claude/CLAUDE.md',
               *(home / '.claude/scripts' / name for name in ('fleet-check.py', 'session-seed.py', 'session-pulse.py'))}
    planned = []
    for index, target in enumerate(targets):
        path = Path(target)
        if not path.is_absolute() or path not in allowed:
            fail(f'restore target {target!r} is not a bootstrap destination for this home')
        reject_symlinks(path)
        check_destination_shape(path)
        source = backup / f'{index}-{path.name}'
        reject_symlinks(source)
        content = source.read_bytes()
        mode = stat.S_IMODE(source.stat().st_mode)
        planned.append((path, content, mode))
    for path, content, mode in planned:
        print(f'{"RESTORE" if args.apply else "PLAN RESTORE"}: {path} ({len(content)} bytes, mode {mode:o})')
    if not args.apply:
        print('Dry run; no files changed.')
        return 0
    for path, content, mode in planned:
        atomic_write(path, content, restore_mode=mode)
    print(f'Restored bytes and modes from {backup}')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--registry', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--home', type=Path, default=Path.home())
    ap.add_argument('--local-rules', type=Path, help='reviewed private additions to append to the root')
    ap.add_argument('--claude-extra', type=Path, help='reviewed Claude-only lines to append to its import')
    ap.add_argument('--replace-existing', action='store_true', help='acknowledge reconciliation of existing files; back them up before replacement')
    ap.add_argument('--discard-local', action='store_true', help='explicitly allow removal or modification of incumbent machine-only blocks')
    ap.add_argument('--restore', type=Path, help='restore files and modes listed in a backup directory paths.txt (dry-run unless --apply)')
    ap.add_argument('--claude-import-verified', action='store_true', help='acknowledge a successful fresh live import test; never use for static checks')
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    home = args.home.expanduser().resolve()
    codex_home = home / '.codex'
    if args.home == Path.home() and os.environ.get('CODEX_HOME'):
        codex_home = Path(os.environ['CODEX_HOME']).expanduser().absolute()
    if args.restore:
        if args.local_rules or args.claude_extra or args.replace_existing or args.discard_local or args.claude_import_verified:
            fail('--restore cannot be combined with install or reconciliation options')
        return restore_backup(args, home, codex_home)
    registry = args.registry.expanduser().resolve()
    root = (registry / 'assets/AGENTS.md').read_text(encoding='utf-8')
    spec = importlib.util.spec_from_file_location('fleet_check', registry / 'assets/scripts/fleet-check.py')
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    rules, duplicates, _ = check.parse(root, 'registry')
    if duplicates or {i for i, (c, _) in rules.items() if c == 'floor'} != set(check.FLOOR_IDS):
        fail('registry root must declare exactly five unique floor rules')
    public_ids = set(rules)
    supplied = {}
    if args.local_rules:
        local = args.local_rules.expanduser().read_text(encoding='utf-8')
        local_rules, local_duplicates, _ = check.parse(local, 'local additions')
        if local_duplicates or any(c == 'floor' for c, _ in local_rules.values()):
            fail('local additions must not redefine floor rules or duplicate IDs')
        if 'machine-local' in local_rules:
            for line in local.splitlines():
                if check.TOKEN.match(line):
                    break
                if line.strip():
                    fail('tagged local rules must start with a rule token; move preamble text inside machine-local')
        additions = ('\n' if 'machine-local' in local_rules else '\n<!--default:machine-local-->\n') + local.rstrip() + '\n'
        root += additions
        supplied = raw_rules(additions, check)
    combined, duplicates, _ = check.parse(root, 'combined root')
    if duplicates:
        fail('local additions duplicate root rule IDs')
    if len(root.encode()) > 32768:
        fail('root exceeds the 32 KiB bootstrap safety ceiling')
    claude = (registry / 'assets/global-CLAUDE.md').read_text(encoding='utf-8')
    if args.claude_extra:
        extra = args.claude_extra.expanduser().read_text(encoding='utf-8')
        extra_rules, extra_duplicates, _ = check.parse(extra, 'Claude additions')
        if extra_duplicates or any(c == 'floor' for c, _ in extra_rules.values()):
            fail('Claude additions must not redefine floor rules or duplicate IDs')
        claude += '\n' + extra.rstrip() + '\n'
    check.verify_gemini_settings(home / '.gemini/GEMINI.md')
    override = codex_home / 'AGENTS.override.md'
    if override.exists() and override.read_text(encoding='utf-8').strip():
        fail(f'{override} shadows the Codex adapter; reconcile it first')
    config = codex_home / 'config.toml'
    before = config.read_text(encoding='utf-8') if config.exists() else ''
    planned = {
        home / '.fleet/AGENTS.md': root,
        codex_home / 'AGENTS.md': root,
        home / '.gemini/GEMINI.md': root,
        config: config_text(before),
    }
    source_modes = {path: stat.S_IMODE((registry / 'assets/AGENTS.md').stat().st_mode)
                    for path in planned if path != config}
    source_modes[config] = 0o600
    # Stage the root/copies while preserving the old Claude file until live proof.
    if args.claude_import_verified:
        planned[home / '.claude/CLAUDE.md'] = claude
        source_modes[home / '.claude/CLAUDE.md'] = stat.S_IMODE((registry / 'assets/global-CLAUDE.md').stat().st_mode)
    else:
        print('HOLD: Claude adapter unchanged until a fresh live import is verified')
    for script in ('fleet-check.py', 'session-seed.py', 'session-pulse.py'):
        source = registry / 'assets/scripts' / script
        destination = home / '.claude/scripts' / script
        planned[destination] = source.read_text(encoding='utf-8')
        source_modes[destination] = stat.S_IMODE(source.stat().st_mode)
    backup_root = home / '.fleet/backups'
    for component in (backup_root, *backup_root.parents):
        if component.is_symlink():
            fail(f'{component} is a symlink; reconcile explicitly before writing backups')
    changes = {}
    for path, content in planned.items():
        reject_symlinks(path)
        old = path.read_text(encoding='utf-8') if path.exists() else None
        if old == content:
            continue
        if old is not None and not args.replace_existing:
            fail(f'{path} differs; review machine-only rules and pass --replace-existing')
        if old is not None and path in (home / '.fleet/AGENTS.md', codex_home / 'AGENTS.md', home / '.gemini/GEMINI.md') and not args.discard_local:
            incumbent = raw_rules(old, check)
            missing = [name for name, body in incumbent.items()
                       if (name == 'machine-local' or name not in public_ids)
                       and supplied.get(name) != body]
            if missing:
                fail(f'{path} has machine-only blocks not identically re-supplied by --local-rules: {", ".join(missing)}; supply them or explicitly pass --discard-local')
        changes[path] = content
    for path, content in changes.items():
        print(f'{"WRITE" if args.apply else "PLAN"}: {path} ({len(content.encode())} bytes)')
    if not args.apply:
        print('Dry run; no files changed.')
        return 0
    # All semantic checks precede writes. Preserve every incumbent before replacing any.
    backup = backup_root / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    existing = [p for p in changes if p.exists()]
    if existing:
        backup.mkdir(parents=True, mode=0o700)
        for index, path in enumerate(existing):
            shutil.copy2(path, backup / f'{index}-{path.name}')
        (backup / 'paths.txt').write_text('\n'.join(str(p) for p in existing) + '\n')
        print(f'Backups: {backup}')
    for path, content in changes.items():
        atomic_write(path, content, source_modes[path])
    print('Installed. Run fleet-check against the published registry and target project.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f'fleet-bootstrap: REFUSE: {exc}', file=sys.stderr)
        sys.exit(2)
