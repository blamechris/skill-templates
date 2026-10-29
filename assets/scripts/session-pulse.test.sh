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


class PulseTests(unittest.TestCase):
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


unittest.main(argv=['session-pulse.test.sh'], verbosity=2)
PY_PULSE_SUITE
