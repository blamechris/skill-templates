#!/usr/bin/env bash
# Offline pulse regressions and writer integration; no external services.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
python3 - "$HERE" <<'PY_PULSE_SUITE'
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(sys.argv[1])
PULSE = HERE / 'session-pulse.py'
SEED = HERE / 'session-seed.py'
NOW = '2026-10-28T13:00:00Z'
DATE = '2026-10-28T12:00:00Z'
BODY = '''## STATE

- **Branch / HEAD:** main
- **Tests:** unit PASS (cached)
- **CI:** green (cached)

## TL;DR — what shipped

The seed path and content checks passed; the offline pulse remains to verify.
'''


class PulseBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='session-pulse-test-')
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'demo'
        self.handoffs = self.root / 'handoffs'
        self.handoffs.mkdir()
        self.env = dict(os.environ, CLAUDE_HANDOFF_DIR=str(self.handoffs),
                        GIT_CEILING_DIRECTORIES=str(self.root),
                        GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                        GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t',
                        PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('CLAUDE_CODE_SESSION_ID', None)
        # Hermetic worktree-cache default: never read or write the real ~/.claude/state.
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env['HOME'] = str(self.home)
        self.env.pop('WORKTREE_AUDIT_CACHE', None)
        self.body = self.root / 'body.md'
        self.body.write_text(BODY)
        self.cmd(['git', '-c', 'init.defaultBranch=main', 'init', '-q', str(self.repo)], cwd=self.root)
        self.cmd(['git', 'commit', '-q', '--allow-empty', '-m', 'init'])
        self.seed = self.handoffs / 'NEXT-demo.md'
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def cmd(self, argv, cwd=None, env=None):
        return subprocess.run(argv, cwd=cwd or self.repo, env=env or self.env,
                              capture_output=True, text=True, timeout=8)

    def write(self, *extra, sid='pulse-test'):
        result = self.cmd([sys.executable, str(SEED), 'write', '--session', sid,
                           '--now', DATE, '--picks-up-at', 'Verify the offline pulse (agent Sol)',
                           '--boundary-reason', 'package complete', '--next',
                           'Verify the offline pulse. Acceptance: eight offline lines report cached state.',
                           '--body-file', str(self.body), *extra])
        self.assertEqual(result.returncode, 0, result.stderr)

    def pulse(self, *extra, env=None, cwd=None, script=PULSE):
        started = time.monotonic()
        result = self.cmd([sys.executable, str(script), '--source', 'codex', '--now', NOW, *extra],
                          cwd=cwd, env=env)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(len(result.stdout.splitlines()), 8, result.stdout)
        self.assertLess(elapsed, 1.0, 'pulse exceeded its one-second contract')
        return result.stdout

    def signals(self, **values):
        path = self.root / 'signals.json'
        path.write_text(json.dumps(dict(source='codex', observed_at=NOW, **values)))
        return ['--signals-file', str(path)]

    def refresh(self, snapshot, sid='pulse-test'):
        result = self.cmd([sys.executable, str(SEED), 'write', '--session', sid,
                           '--refresh-pulse', str(snapshot)])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result


class PulseTests(PulseBase):
    def test_eight_lines_cached_sources_and_real_timing(self):
        out = self.pulse()
        self.assertIn('scope: demo', out)
        self.assertIn('unit PASS (cached)', out)
        self.assertIn('CI green (cached)', out)
        self.assertIn('open items n/a | turns n/a', out)
        self.assertIn('ahead n/a / behind n/a', out)
        self.assertIn('0 open', out)  # writer explicitly declared decisions: []
        self.assertIn('usage: n/a | context n/a | compactions n/a', out)
        self.assertIn('no baseline', out)
        print('  smoke: eight-line real pulse completed below 1 second', flush=True)

    def test_missing_seed_never_invents_zeroes(self):
        self.seed.unlink()
        out = self.pulse()
        self.assertIn('seed missing/invalid', out)
        self.assertIn('commits since seed n/a | open items n/a | turns n/a', out)
        self.assertIn('decisions: n/a open', out)

    def test_invalid_seed_warns(self):
        self.seed.write_text('unfinished notes\n')
        self.assertIn('seed missing/invalid', self.pulse())

    def test_no_git_degrades_and_stays_fast(self):
        env = {**self.env, 'PATH': str(self.root / 'missing-bin')}
        out = self.pulse(env=env)
        self.assertIn('scope: n/a', out)
        self.assertIn('source unavailable/deadline', out)
        self.assertIn('HEAD n/a', out)

    def test_timeout_is_shared_not_per_command(self):
        stub = self.root / 'bin'
        stub.mkdir()
        git = stub / 'git'
        git.write_text('#!/bin/sh\nexec /bin/sleep 5\n')
        git.chmod(0o755)
        self.assertIn('source unavailable/deadline', self.pulse(env={**self.env, 'PATH': str(stub)}))

    def test_reader_runs_only_local_git_queries(self):
        stub = self.root / 'bin'
        stub.mkdir()
        marker = self.root / 'git-commands.jsonl'
        real_git = shutil.which('git')
        git = stub / 'git'
        git.write_text('#!' + sys.executable + '\nimport os,sys,json\n'
            'with open(%r,"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
            'os.execv(%r,[%r,*sys.argv[1:]])\n' % (str(marker), real_git, real_git))
        git.chmod(0o755)
        self.pulse(env={**self.env, 'PATH': str(stub) + os.pathsep + self.env['PATH']})
        commands = [json.loads(line) for line in marker.read_text().splitlines()]
        self.assertTrue(commands)
        for args in commands:
            self.assertEqual(args[:2], ['-c', 'core.fsmonitor=false'])
            args = args[2:]
            if args[0] == '-C':
                args = args[2:]
            self.assertIn(args[0], {'rev-parse', 'branch', 'status', 'rev-list'})

    def test_bad_flags_still_return_eight_lines_zero(self):
        self.assertIn('WARN:', self.pulse('--unsupported-option'))

    def test_linked_worktree_uses_shared_seed_resolver(self):
        linked = self.root / 'linked'
        self.assertEqual(self.cmd(['git', 'worktree', 'add', '-q', str(linked), '-b', 'linked']).returncode, 0)
        out = self.pulse(cwd=linked)
        self.assertIn('scope: demo', out)
        self.assertIn('branch linked', out)

    def test_signals_are_explicit_typed_and_host_matched(self):
        out = self.pulse(*self.signals(open_items=3, turns=12, compactions=1, context_pct=72.5))
        self.assertIn('open items 3 | turns 12', out)
        self.assertIn('context 72.5 | compactions 1', out)
        for bad in ({'source': 'claude', 'observed_at': NOW, 'turns': 2},
                    {'source': 'codex', 'observed_at': NOW, 'turns': True},
                    {'source': 'codex', 'observed_at': NOW, 'context_pct': 101},
                    {'source': 'codex', 'observed_at': NOW, 'compactions': -1},
                    {'source': 'codex', 'turns': 2}):
            path = self.root / 'bad.json'
            path.write_text(json.dumps(bad))
            out = self.pulse('--signals-file', str(path))
            self.assertIn('cached signals invalid/unavailable', out)
            self.assertIn('open items n/a | turns n/a', out)
        self.assertIn('cached signals invalid/unavailable', self.pulse('--signals-file', str(self.root / 'absent')))

    def test_thresholds_warn_without_failing(self):
        out = self.pulse(*self.signals(open_items=4, compactions=2, estimate=100, actual=126, unit='minutes'))
        for warning in ('open items >3', 'compactions >=2', 'stated estimate drift >25%'):
            self.assertIn(warning, out)
        out = self.pulse(*self.signals(open_items=3, compactions=1, estimate=100, actual=125, unit='minutes'))
        for warning in ('open items >3', 'compactions >=2', 'stated estimate drift >25%'):
            self.assertNotIn(warning, out)
        self.assertIn('cached signals invalid', self.pulse(*self.signals(estimate=100, actual=126)))

    def test_seed_age_and_dirty_boundary_thresholds(self):
        self.assertIn('seed >24h', self.pulse('--now', '2026-10-29T12:00:01Z'))
        self.assertNotIn('seed >24h', self.pulse('--now', '2026-10-29T12:00:00Z'))
        (self.repo / 'pending.txt').write_text('pending')
        self.assertIn('dirty at boundary', self.pulse('--boundary'))
        self.assertNotIn('dirty at boundary', self.pulse())

    def test_delta_unchanged_then_changed_and_snapshot_roundtrip(self):
        snapshot = self.root / 'snapshot.json'
        self.pulse('--snapshot-file', str(snapshot))
        original = self.seed.read_text()
        old_body = original.split('\n---\n', 1)[1]
        self.refresh(snapshot)
        self.assertEqual(self.seed.read_text().split('\n---\n', 1)[1], old_body)
        self.assertIn('date: ' + DATE[:16] + 'Z', self.seed.read_text())
        out = self.pulse('--now', '2026-10-28T13:01:00Z')
        self.assertIn('no material change since ' + NOW, out)
        self.assertEqual(self.cmd(['git', 'commit', '-q', '--allow-empty', '-m', 'second']).returncode, 0)
        self.assertIn('changed', self.pulse())
        self.assertIn('head', self.pulse())

    def test_structured_decisions_default_age_and_recurrence(self):
        decisions = self.root / 'decisions.json'
        decisions.write_text(json.dumps([{'text': 'Approve issue #123', 'opened_at': DATE,
                                         'default': 'Keep the recommendation pending an answer'}]))
        self.write('--decisions-file', str(decisions))
        first = self.root / 'first.json'
        out = self.pulse('--snapshot-file', str(first))
        self.assertIn('1 open; oldest 1.0h', out)
        self.assertIn('default Keep the recommendation', out)
        self.assertIn('text Approve issue #123', out)
        self.assertNotIn('same decision >=2', out)
        self.refresh(first)
        second = self.root / 'second.json'
        out = self.pulse('--snapshot-file', str(second))
        self.assertIn('same decision >=2 recorded pulses', out)
        self.assertIn('changed warn_decision_repeat', out)
        self.refresh(second, sid='next-session')
        self.assertEqual(len(list(self.handoffs.glob('NEXT-demo.*.md'))), 1)
        seed = self.seed.read_text()
        self.assertIn('Approve issue #123', seed)
        self.assertIn('session: next-session', seed)
        self.assertIn('date: ' + DATE[:16] + 'Z', seed)
        previous = json.loads(next(line.split(': ', 1)[1] for line in seed.splitlines() if line.startswith('last_pulse:')))
        self.assertEqual(previous['state']['decision_streaks']['Approve issue #123'], 2)
        self.assertIn('same decision >=2', self.pulse())
        self.assertIn('no material change since', self.pulse())

    def test_threshold_crossings_are_material_but_raw_age_is_not(self):
        snapshot = self.root / 'age.json'
        self.pulse('--now', '2026-10-29T12:00:00Z', '--snapshot-file', str(snapshot))
        self.refresh(snapshot)
        self.assertIn('changed warn_seed_age', self.pulse('--now', '2026-10-29T12:00:01Z'))
        self.pulse('--now', '2026-10-29T12:00:01Z', '--snapshot-file', str(snapshot))
        self.refresh(snapshot)
        self.assertIn('no material change since', self.pulse('--now', '2026-10-29T12:01:00Z'))
        (self.repo / 'dirty.txt').write_text('pending')
        snapshot = self.root / 'boundary.json'
        self.pulse('--snapshot-file', str(snapshot))
        self.refresh(snapshot)
        self.assertIn('changed warn_dirty_boundary', self.pulse('--boundary'))
        self.pulse('--boundary', '--snapshot-file', str(snapshot))
        self.refresh(snapshot)
        self.assertIn('no material change since', self.pulse('--boundary'))

    def test_refresh_preserves_crlf_body_bytes(self):
        snapshot = self.root / 'snapshot.json'
        self.pulse('--snapshot-file', str(snapshot))
        self.seed.write_bytes(self.seed.read_bytes().replace(b'\n', b'\r\n'))
        before = self.seed.read_bytes().split(b'# Handoff', 1)[1]
        self.refresh(snapshot)
        self.assertEqual(self.seed.read_bytes().split(b'# Handoff', 1)[1], before)

    def test_legacy_pending_decision_warns_with_unknown_count(self):
        with self.seed.open('a') as file:
            file.write('\nDECISION carried since 2026-10-28: still-open owner decision.\n')
        out = self.pulse()
        self.assertIn('legacy pending DECISION', out)
        self.assertIn('decisions: n/a open; oldest 13.0h', out)
        self.assertIn('text DECISION carried since', out)
        self.assertIn('still-open owner decision', out)

    def test_structured_decision_text_is_not_legacy_prose(self):
        decisions = self.root / 'decisions.json'
        decisions.write_text(json.dumps([{'text': 'DECISION: approve the plan', 'opened_at': DATE,
                                         'default': 'Hold pending answer'}]))
        self.write('--decisions-file', str(decisions))
        self.assertNotIn('legacy pending DECISION', self.pulse())

    def test_snapshot_failure_is_honest_and_never_writes_seed(self):
        before = self.seed.read_bytes()
        out = self.pulse('--snapshot-file', str(self.seed))
        self.assertIn('snapshot not saved', out)
        self.assertEqual(self.seed.read_bytes(), before)
        out = self.pulse('--snapshot-file', str(self.root / 'missing' / 'file'))
        self.assertIn('snapshot not saved', out)
        alias = self.root / 'alias'
        alias.symlink_to(self.seed)
        self.assertIn('snapshot not saved', self.pulse('--snapshot-file', str(alias)))
        hardlink = self.root / 'hardlink'
        os.link(self.seed, hardlink)
        self.assertIn('snapshot not saved', self.pulse('--snapshot-file', str(hardlink)))
        self.assertEqual(self.seed.read_bytes(), before)

    def test_invalid_snapshot_and_hollow_refresh_preserve_incumbent(self):
        original = self.seed.read_bytes()
        invalid = self.root / 'invalid.json'
        invalid.write_text('{"at":false}')
        result = self.cmd([sys.executable, str(SEED), 'write', '--session', 'other', '--refresh-pulse', str(invalid)])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.seed.read_bytes(), original)
        snapshot = self.root / 'valid.json'
        self.pulse('--snapshot-file', str(snapshot))
        self.seed.write_text(self.seed.read_text() + '\n<unfinished summary>\n')
        hollow = self.seed.read_bytes()
        result = self.cmd([sys.executable, str(SEED), 'write', '--session', 'other', '--refresh-pulse', str(snapshot)])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.seed.read_bytes(), hollow)
        self.assertEqual(list(self.handoffs.glob('NEXT-demo.*.md')), [])

    def test_usage_only_runs_for_actual_claude_source(self):
        tools = self.root / 'tools'
        tools.mkdir()
        shutil.copy(PULSE, tools / PULSE.name)
        shutil.copy(SEED, tools / SEED.name)
        marker = self.root / 'pace-called'
        (tools / 'usage-pace.py').write_text('from pathlib import Path\nimport sys\n'
            'assert sys.argv[1:] == ["--oneline"]\n'
            'Path(%r).write_text("called")\nprint("sd 12%% live")\n' % str(marker))
        self.pulse(script=tools / PULSE.name, env={**self.env, 'CLAUDE_CODE_SESSION_ID': 'test-id'})
        self.assertFalse(marker.exists())
        self.pulse('--source', 'claude', script=tools / PULSE.name)
        self.assertFalse(marker.exists())
        out = self.pulse('--source', 'claude', script=tools / PULSE.name,
                         env={**self.env, 'CLAUDE_CODE_SESSION_ID': 'test-id'})
        self.assertTrue(marker.exists())
        self.assertIn('usage: sd 12% live', out)

    def test_actual_usage_formatter_ages_are_not_material_measurements(self):
        # Generate source output with the real formatter, without invoking its
        # accounting scan or reading any live meter data.
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location('pace_formatter', HERE / 'usage-pace.py')
        formatter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(formatter)
        values = dict(source='live', sd=12, fh=3, pct_now=None,
                      sample_at=DATE, sample_age_min=1, spend=100, spend_hi=100,
                      anchor_label='period', fable=20, fable_hi=20, rate=None,
                      pts_left=88, hours_to_reset=10, burn_1h=5, burn_3h=4,
                      stale=True, fable_reading={'pct': 5, 'age_h': 1})
        tools = self.root / 'usage-tools'
        tools.mkdir()
        shutil.copy(PULSE, tools / PULSE.name)
        shutil.copy(SEED, tools / SEED.name)
        oneline = self.root / 'usage-line.txt'
        marker = self.root / 'usage-calls.txt'
        (tools / 'usage-pace.py').write_text('from pathlib import Path\nimport sys\n'
            'assert sys.argv[1:] == ["--oneline"]\n'
            'with Path(%r).open("a") as f: f.write("called\\n")\n'
            'print(Path(%r).read_text())\n' % (str(marker), str(oneline)))
        env = {**self.env, 'CLAUDE_CODE_SESSION_ID': 'test-id'}
        snapshot = self.root / 'usage-snapshot.json'
        oneline.write_text(formatter.fmt(values))
        out = self.pulse('--source', 'claude', '--snapshot-file', str(snapshot),
                         script=tools / PULSE.name, env=env)
        self.assertIn('1m old', out)
        self.refresh(snapshot)
        values.update(sample_age_min=2, hours_to_reset=9.9)
        values['fable_reading']['age_h'] = 2
        oneline.write_text(formatter.fmt(values))
        out = self.pulse('--source', 'claude', script=tools / PULSE.name, env=env)
        self.assertIn('2m old', out)
        self.assertIn('reset in 9.9h', out)
        self.assertIn('no material change since', out)
        values.update(sd=13, pts_left=87)
        oneline.write_text(formatter.fmt(values))
        self.assertIn('changed usage', self.pulse('--source', 'claude', script=tools / PULSE.name, env=env))
        values.update(sd=12, pts_left=88, spend=101, spend_hi=101)
        oneline.write_text(formatter.fmt(values))
        self.assertIn('changed usage', self.pulse('--source', 'claude', script=tools / PULSE.name, env=env))
        # Four observations made exactly four source calls, not separate human and
        # structured accounting queries.
        self.assertEqual(marker.read_text().splitlines(), ['called'] * 4)

        # A mutant restoring raw-string comparison reproduces the reported age
        # defect against the same actual formatter outputs and persisted baseline.
        mutant = tools / 'raw-usage-mutant.py'
        source = PULSE.read_text()
        needle = '"usage": usage_measurements'
        self.assertIn(needle, source)
        mutant.write_text(source.replace(needle, '"usage": usage'))
        self.write()
        values.update(sample_age_min=1, hours_to_reset=10, spend=100, spend_hi=100)
        values['fable_reading']['age_h'] = 1
        oneline.write_text(formatter.fmt(values))
        self.pulse('--source', 'claude', '--snapshot-file', str(snapshot), script=mutant, env=env)
        self.refresh(snapshot)
        values.update(sample_age_min=2, hours_to_reset=9.9)
        values['fable_reading']['age_h'] = 2
        oneline.write_text(formatter.fmt(values))
        self.assertIn('changed usage', self.pulse('--source', 'claude', script=mutant, env=env))
        print('  mutant: raw usage comparison invents a delta for actual formatter aging', flush=True)

    def test_no_baseline_mutant_is_detected(self):
        tools = self.root / 'mutant-tools'
        tools.mkdir()
        shutil.copy(SEED, tools / SEED.name)
        mutant = tools / PULSE.name
        source = PULSE.read_text()
        original = 'if previous is None:\n        return "no baseline"'
        self.assertIn(original, source)
        mutant.write_text(source.replace(original, 'if previous is None:\n        return "no material change since invented"'))
        good = self.pulse()
        broken = self.pulse(script=mutant)
        self.assertIn('no baseline', good)
        self.assertNotIn('no baseline', broken)
        print('  mutant: missing-baseline assertion rejects invented unchanged state', flush=True)


GENERATED = '2026-10-28T12:00:00Z'  # one hour before NOW
PATCHED = r"""
import collections, importlib.util, sys
spec = importlib.util.spec_from_file_location('session_pulse_under_test', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
free = sys.argv[2]
def usage(path):
    assert path == m.os.path.expanduser('~'), path
    if free == 'oserror':
        raise OSError('no statvfs')
    return collections.namedtuple('U', 'total used free')(1 << 40, 0, int(float(free) * 2 ** 30))
m.shutil.disk_usage = usage
sys.exit(m.main(sys.argv[3:]))
"""


class WorktreePulseTests(PulseBase):
    """Worktree hygiene from the worktree-audit cache (#435)."""

    def wt_cache(self, repos, generated=GENERATED, name='wt.json', pad=0):
        """repos: {basename: [(content_class, stale), ...]} -> path of a cache file."""
        doc = {'generated_at': generated, 'roots': [], 'leftovers': [], 'unverified': [], 'notes': [],
               'repos': [{'path': '/work/' + repo, 'default_base': 'origin/main',
                          'worktrees': [{'path': '/work/%s-%d' % (repo, i), 'branch': 'b%d' % i,
                                         'verdict': 'KEEP', 'content_class': cls, 'stale': stale,
                                         'creation_age_days': 20, 'head_age_days': 20,
                                         'reasons': ['x' * pad]}
                                        for i, (cls, stale) in enumerate(items)]}
                         for repo, items in repos.items()]}
        path = self.root / name
        path.write_text(json.dumps(doc))
        return path

    def patched(self, free, *extra, cache=None, env=None):
        started = time.monotonic()
        argv = [sys.executable, '-c', PATCHED, str(PULSE), str(free), '--source', 'codex', '--now', NOW, *extra]
        if cache is not None:
            argv += ['--worktree-cache', str(cache)]
        result = self.cmd(argv, env=env)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(len(result.stdout.splitlines()), 8, result.stdout)
        self.assertLess(elapsed, 1.5)
        return result.stdout

    def state(self, free, cache, *extra):
        snapshot = self.root / 'wt-snapshot.json'
        self.patched(free, '--snapshot-file', str(snapshot), *extra, cache=cache)
        return json.loads(snapshot.read_text())['state']

    WT_WARNS = ('worktrees >', 'stale class-B worktrees', 'free disk <')

    def test_below_thresholds_show_line_and_no_warning(self):
        cache = self.wt_cache({'alpha': [('A', True), ('B', False)], 'beta': [('B', False)] * 1})
        out = self.patched(500, cache=cache)
        self.assertIn('cached: tests unit PASS (cached) | CI green (cached) | '
                      'worktrees 3 (max 2 in alpha, stale B 0, audit 1.0h) | free 500.0 GiB', out)
        self.assertIn('WARN: none', out)
        state = self.state(500, cache)
        self.assertEqual((state['worktrees_total'], state['worktrees_max_repo'], state['worktrees_stale_b']), (3, 2, 0))
        self.assertEqual(state['worktree_audit_at'], GENERATED)
        for key in ('warn_worktrees_repo', 'warn_free_disk', 'warn_stale_b'):
            self.assertIs(state[key], False, key)
        self.assertNotIn('free_gib', state)

    def test_repo_worktree_count_threshold_is_strictly_above_15(self):
        out = self.patched(500, cache=self.wt_cache({'big': [('A', False)] * 16, 'small': [('A', False)]}))
        self.assertIn('worktrees >15 in big', out)
        self.assertIn('worktrees 17 (max 16 in big,', out)
        state = self.state(500, self.wt_cache({'big': [('A', False)] * 16}))
        self.assertIs(state['warn_worktrees_repo'], True)
        self.assertIs(state['warn_stale_b'], False)
        out = self.patched(500, cache=self.wt_cache({'big': [('A', False)] * 15, 'other': [('A', False)] * 15}))
        self.assertNotIn('worktrees >', out)  # 30 in total, but no ONE repo over 15

    def test_stale_class_b_threshold(self):
        out = self.patched(500, cache=self.wt_cache({'r': [('B', True), ('B', True), ('B', False), ('A', True)]}))
        self.assertIn('stale class-B worktrees 2', out)
        self.assertIn('stale B 2', out)
        self.assertIs(self.state(500, self.wt_cache({'r': [('B', True)]}))['warn_stale_b'], True)
        for items in ([('B', False)], [('A', True)], [('?', True)], [('B', 'true')], [('B', None)]):
            self.assertNotIn('stale class-B', self.patched(500, cache=self.wt_cache({'r': items})), items)

    def test_free_disk_threshold_and_unknown(self):
        cache = self.wt_cache({'r': [('A', False)]})
        out = self.patched(49.9, cache=cache)
        self.assertIn('free disk <50 GiB', out)
        self.assertIn('| free 49.9 GiB', out)
        self.assertIs(self.state(49.9, cache)['warn_free_disk'], True)
        self.assertNotIn('free disk', self.patched(50, cache=cache))
        out = self.patched('oserror', cache=cache)
        self.assertIn('| free n/a', out)
        self.assertNotIn('free disk', out)
        self.assertIs(self.state('oserror', cache)['warn_free_disk'], False)
        # Free disk needs no cache: a missing cache still warns on a nearly full disk.
        out = self.patched(10, cache=self.root / 'absent.json')
        self.assertIn('free disk <50 GiB', out)
        self.assertIn('worktrees n/a | free 10.0 GiB', out)

    def test_missing_or_invalid_cache_is_unknown_never_zero(self):
        good = json.loads(self.wt_cache({'r': [('A', False)]}).read_text())
        cases = {'missing': None, 'not json': '{nope', 'empty': '', 'list': '[]', 'null': 'null',
                 'repos not a list': json.dumps({**good, 'repos': {}}),
                 'no repos': json.dumps({'generated_at': GENERATED}),
                 'repo not a dict': json.dumps({**good, 'repos': ['x']}),
                 'repo without worktrees': json.dumps({**good, 'repos': [{'path': '/w/r'}]}),
                 'worktrees not a list': json.dumps({**good, 'repos': [{'path': '/w/r', 'worktrees': 3}]}),
                 'worktree not a dict': json.dumps({**good, 'repos': [{'path': '/w/r', 'worktrees': [1]}]}),
                 'no generated_at': json.dumps({k: v for k, v in good.items() if k != 'generated_at'}),
                 'non-UTC generated_at': json.dumps({**good, 'generated_at': '2026-10-28T12:00:00+02:00'}),
                 'naive generated_at': json.dumps({**good, 'generated_at': '2026-10-28T12:00:00'}),
                 'date only generated_at': json.dumps({**good, 'generated_at': '2026-10-28'}),
                 'numeric generated_at': json.dumps({**good, 'generated_at': 1761652800}),
                 'future generated_at': json.dumps({**good, 'generated_at': '2026-10-28T14:00:00Z'})}
        for name, text in cases.items():
            path = self.root / 'bad-cache.json'
            path.unlink(missing_ok=True)
            if text is not None:
                path.write_text(text)
            out = self.pulse('--worktree-cache', str(path))
            self.assertIn('worktrees n/a', out, name)
            self.assertNotIn('worktrees 0', out, name)
            for warning in ('worktrees >', 'stale class-B worktrees'):
                self.assertNotIn(warning, out, name)
            state = self.state(500, path)
            self.assertEqual((state['worktrees_total'], state['worktrees_max_repo'], state['worktrees_stale_b'],
                              state['worktree_audit_at']), (None,) * 4, name)
            self.assertEqual((state['warn_worktrees_repo'], state['warn_stale_b']), (False, False), name)
        directory = self.root / 'a-directory'
        directory.mkdir()
        self.assertIn('worktrees n/a', self.pulse('--worktree-cache', str(directory)))

    def test_old_cache_is_labelled_stale_without_a_warning(self):
        cache = lambda ts: self.wt_cache({'r': [('A', False)]}, generated=ts)
        out = self.patched(500, cache=cache('2026-10-20T13:00:00Z'))  # 8 days
        self.assertIn('worktrees 1 (max 1 in r, stale B 0, audit 8.0d stale)', out)
        self.assertIn('WARN: none', out)
        out = self.patched(500, cache=cache('2026-10-21T13:00:01Z'))  # just under 7 days
        self.assertIn('audit 7.0d)', out)
        self.assertNotIn('stale)', out)
        self.assertIn('audit 20m)', self.patched(500, cache=cache('2026-10-28T12:40:00Z')))

    def test_newly_crossed_worktree_warning_is_a_delta_but_free_gib_and_audit_time_are_not(self):
        snapshot = self.root / 'wt-baseline.json'
        low = self.wt_cache({'r': [('A', False)] * 3})
        self.patched(500, '--snapshot-file', str(snapshot), cache=low)
        self.refresh(snapshot)
        # Same counts, a fresher audit and different free space: not material.
        again = self.wt_cache({'r': [('A', False)] * 3}, generated='2026-10-28T12:30:00Z', name='again.json')
        out = self.patched(400, cache=again)
        self.assertIn('no material change since', out)
        self.assertNotIn('worktree_audit_at', out)
        # Crossing the per-repo threshold names the stable boolean.
        high = self.wt_cache({'r': [('A', False)] * 16}, name='high.json')
        out = self.patched(500, cache=high)
        self.assertIn('warn_worktrees_repo', out)
        self.assertIn('worktrees_total', out)  # the count itself is material
        # Crossing free disk names its boolean, and only that one.
        out = self.patched(10, cache=low)
        self.assertIn('changed warn_free_disk', out)
        self.assertNotIn('warn_worktrees_repo', out)
        # Staying crossed is quiet.
        self.patched(10, '--snapshot-file', str(snapshot), cache=low)
        self.refresh(snapshot)
        self.assertIn('no material change since', self.patched(11, cache=low))
        stale = self.wt_cache({'r': [('B', True)] * 3}, name='stale.json')
        self.assertIn('warn_stale_b', self.patched(10, cache=stale))

    def test_large_cache_finishes_within_the_contract(self):
        cache = self.wt_cache({'r%d' % i: [('B' if j % 3 == 0 else 'A', j % 2 == 0) for j in range(100)]
                               for i in range(20)}, pad=300)
        self.assertGreater(cache.stat().st_size, 512 * 1024)  # past the small-file bound
        started = time.monotonic()
        out = self.patched(500, cache=cache)
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertIn('worktrees 2000 (max 100 in r0, stale B ', out)
        self.assertIn('worktrees >15 in r0', out)

    def test_cache_read_spawns_no_subprocess(self):
        import unittest.mock as mock
        spec = importlib.util.spec_from_file_location('pulse_pymod', PULSE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cache = self.wt_cache({'r': [('B', True)] * 2})
        boom = AssertionError('subprocess spawned by the worktree-cache read')
        with mock.patch.object(subprocess, 'Popen', side_effect=boom), \
                mock.patch.object(subprocess, 'run', side_effect=boom), \
                mock.patch.object(os, 'system', side_effect=boom):
            summary = module.worktree_summary(str(cache), module.timestamp(NOW))
            self.assertEqual((summary['total'], summary['max'], summary['stale_b']), (2, 2, 2))
            self.assertIsNone(module.worktree_summary(str(self.root / 'absent.json'), module.timestamp(NOW)))
            module.free_gib()
            module.worktree_text(summary, 12.0)
        self.assertEqual(module.WT_REPO_MAX, 15)
        self.assertEqual(module.FREE_GIB_MIN, 50)

    def test_cache_path_resolution_flag_env_home(self):
        flag = self.wt_cache({'flagrepo': [('A', False)]}, name='flag.json')
        env_cache = self.wt_cache({'envrepo': [('A', False)] * 2}, name='env.json')
        env = {**self.env, 'WORKTREE_AUDIT_CACHE': str(env_cache)}
        self.assertIn('max 2 in envrepo', self.pulse(env=env))
        self.assertIn('max 1 in flagrepo', self.pulse('--worktree-cache', str(flag), env=env))
        self.assertIn('worktrees n/a', self.pulse())  # hermetic HOME has no cache
        state_dir = self.home / '.claude' / 'state'
        state_dir.mkdir(parents=True)
        (state_dir / 'worktree-audit.json').write_text(env_cache.read_text())
        self.assertIn('max 2 in envrepo', self.pulse())  # default under $HOME

    def test_fallback_line_keeps_eight_lines_and_the_new_shape(self):
        lines = self.pulse('--unsupported-option').splitlines()
        self.assertEqual(lines[4], 'cached: tests n/a | CI n/a | worktrees n/a | free n/a')

    def test_cache_and_signals_files_are_not_conflated(self):
        # A signals file passed as the worktree cache is invalid there, not accepted.
        self.assertIn('worktrees n/a', self.pulse('--worktree-cache', str(self.signals(turns=1)[1])))


unittest.main(argv=['session-pulse.test.sh'], verbosity=2)
PY_PULSE_SUITE
