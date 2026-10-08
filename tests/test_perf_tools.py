"""Test statistical decisions, experiment scheduling, and failure evidence."""
import argparse
import contextlib
import copy
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import bench, experiment, perf_common, profile_engine


class BenchmarkStatisticsTests(unittest.TestCase):
    def report(self, factor=1.0):
        config = {'sessions': 12, 'repeats': 2, 'bootstrap': 200, 'seed': 1,
                  'min_effect_pct': .5, 'control_tolerance_pct': 2, 'min_search_ms': 20}
        report = {'status': 'complete', 'configuration': config,
                  'positions': [{'id': 'one', 'category': 'test'}], 'samples': []}
        for session in range(config['sessions']):
            for repeat in range(config['repeats']):
                for label in bench.LABELS:
                    # Large shared session drift must cancel in paired comparisons.
                    elapsed = (session + 1) * 100_000_000 * (factor if label.startswith('candidate') else 1)
                    report['samples'].append(dict(session=session, repeat=repeat, position='one', label=label,
                                                  move='e2e4', score='cp 10', pv='e2e4', nodes=1000, depth=20, elapsed_ns=elapsed))
        return report

    def test_execution_ranks_balance_in_each_block(self):
        for block in (0, 6):
            for position in range(3):
                for repeat in range(2):
                    orders = [bench.balanced_order(42, s, position, repeat) for s in range(block, block + 6)]
                    for rank in range(6):
                        self.assertEqual({row[rank] for row in orders}, set(bench.LABELS))
                    self.assertEqual(orders[0], bench.balanced_order(42, block, position, repeat))

    def test_paired_sessions_detect_improvement_regression_and_no_change(self):
        for factor, verdict in ((.9, 'improvement'), (1.1, 'regression'), (1, 'inconclusive')):
            with self.subTest(factor=factor):
                summary = bench.analyze(self.report(factor))
                self.assertEqual(summary['verdict'], verdict)
                self.assertAlmostEqual(summary['candidate_vs_baseline']['change_pct'], (factor - 1) * 100)
                self.assertAlmostEqual(summary['candidate_vs_baseline']['ci95_pct'][0], (factor - 1) * 100)

    def test_noisy_control_suppresses_verdict(self):
        report = self.report(.9)
        for sample in report['samples']:
            if sample['label'] == 'baseline1':
                sample['elapsed_ns'] *= 1.1
        self.assertEqual(bench.analyze(report)['verdict'], 'inconclusive')

    def test_short_searches_suppress_verdict_without_dropping_samples(self):
        report = self.report(.9)
        report['configuration']['min_search_ms'] = 10000
        summary = bench.analyze(report)
        self.assertEqual(summary['verdict'], 'inconclusive')
        self.assertEqual(summary['short_positions'], ['one'])
        self.assertEqual(summary['searches'], len(report['samples']))

    def test_incomplete_duplicate_and_mismatched_samples_are_not_evidence(self):
        for kind in ('missing', 'duplicate', 'mismatch', 'failed'):
            report = self.report()
            if kind == 'missing':
                report['samples'].pop()
            elif kind == 'duplicate':
                report['samples'][-1] = copy.deepcopy(report['samples'][0])
            elif kind == 'mismatch':
                report['samples'][0]['nodes'] += 1
            else:
                report['status'] = 'failed'
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                bench.analyze(report)

    def test_six_sessions_are_smoke_only(self):
        effect = {'change_pct': -10, 'ci95_pct': [-11, -9]}
        control = {'change_pct': 0, 'ci95_pct': [-.1, .1]}
        self.assertEqual(bench.verdict(effect, [control], 6, .5, 2), 'inconclusive')

    def test_identical_binaries_cannot_claim_an_improvement(self):
        report = self.report(.9)
        report['executables'] = {name: {'sha256': 'same'} for name in ('baseline', 'candidate')}
        summary = bench.analyze(report)
        self.assertEqual(summary['verdict'], 'inconclusive')
        self.assertTrue(any('same binary' in reason for reason in summary['reasons']))


class FakeEngine:
    instances = []
    mismatch = False

    def __init__(self, executable, network, threads, hash_mb):
        self.path = str(executable)
        self.closed = False
        self.__class__.instances.append(self)

    def send(self, command):
        pass

    def new_game(self):
        pass

    def position(self, fen):
        pass

    def ready(self):
        pass

    def search(self, limit):
        return dict(move='e2e4', score='cp 10', pv='e2e4', nodes=101 if self.mismatch and 'candidate' in self.path else 100,
                    depth=int(limit.split()[1]), elapsed_ns=100_000_000)

    def close(self):
        self.closed = True


class BenchmarkLifecycleTests(unittest.TestCase):
    def run_fake(self, root, mismatch=False):
        root = pathlib.Path(root)
        corpus = root / 'positions.json'
        corpus.write_text(json.dumps([dict(id='one', category='opening', fen='8/8/8/8/8/8/8/8 w - - 0 1')]))
        args = bench.parser().parse_args(['--baseline', 'baseline', '--candidate', 'candidate', '--reference', 'reference',
                                         '--network', 'network', '--positions', str(corpus), '--output', str(root / 'run'),
                                         '--sessions', '6', '--repeats', '1', '--bootstrap', '100'])
        FakeEngine.instances = []
        FakeEngine.mismatch = mismatch
        with patch.object(bench, 'Engine', FakeEngine), patch.object(bench, 'identity', return_value={}), \
             patch.object(bench, 'metadata', return_value={}), patch.object(bench, 'peak_rss_bytes', return_value=None), \
             contextlib.redirect_stdout(io.StringIO()):
            if mismatch:
                with self.assertRaisesRegex(RuntimeError, 'Warmup search mismatch'):
                    bench.run(args)
            else:
                self.assertEqual(bench.run(args)['verdict'], 'inconclusive')
        self.assertTrue(all(e.closed for e in FakeEngine.instances))
        report = json.loads((root / 'run/results.json').read_text())
        self.assertEqual(report['status'], 'failed' if mismatch else 'complete')
        if mismatch:
            self.assertFalse((root / 'run/summary.json').exists())
            self.assertTrue(report['warmups'])
        else:
            self.assertEqual(len(FakeEngine.instances), 36)
            self.assertEqual(len(report['samples']), 36)

    def test_fresh_processes_and_complete_report(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_fake(root)

    def test_mismatch_preserves_partial_results_and_closes_engines(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_fake(root, mismatch=True)

    def test_measurement_lock_excludes_concurrent_tool(self):
        with perf_common.measurement_lock():
            with self.assertRaisesRegex(RuntimeError, 'Another benchmark'):
                with perf_common.measurement_lock():
                    self.fail('Second lock unexpectedly succeeded')


class ProfileTests(unittest.TestCase):
    def test_profile_limit_can_use_fixed_depth_instead_of_nodes(self):
        required = ['--engine', 'engine', '--network', 'network', '--output', 'report']
        args = profile_engine.parser().parse_args(required + ['--depth', '22'])
        self.assertEqual(args.depth, 22)
        self.assertIsNone(args.nodes)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            profile_engine.parser().parse_args(required + ['--depth', '22', '--nodes', '1000'])

    def test_counters_preserve_multiplexing_and_unavailable_events(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / 'stat.csv'
            path.write_text('100;;cycles:u;100000;100.00;;\n200;;instructions:u;100000;50.00;;\n<not supported>;;branch-misses:u;0;0.00;;\n')
            values = profile_engine.parse_stat(path)
            self.assertFalse(values[0]['multiplexed'])
            self.assertTrue(values[1]['multiplexed'])
            self.assertFalse(values[2]['available'])

    def test_perf_acknowledges_boundaries_and_exits(self):
        code = """import os, sys
ctl, ack = map(int, sys.argv[-1].removeprefix('fd:').split(','))
while os.read(ctl, 64):
    os.write(ack, b'ack\\n\\0')
"""
        with tempfile.TemporaryDirectory() as root:
            profiler = profile_engine.Perf([sys.executable, '-c', code], pathlib.Path(root) / 'perf.log')
            try:
                profiler.command('enable')
                profiler.command('disable')
            finally:
                profiler.close()
            assert profiler.process is not None
            self.assertIsNotNone(profiler.process.poll())


class ExperimentTests(unittest.TestCase):
    def test_validation_failure_never_starts_benchmark_and_cleans_own_worktree(self):
        with tempfile.TemporaryDirectory() as root:
            args = argparse.Namespace(baseline='old', candidate='new', output=pathlib.Path(root) / 'run',
                                      network=pathlib.Path('network'), reference=pathlib.Path('reference'),
                                      positions=pathlib.Path('positions'), keep_worktrees=False)
            calls = []
            def execute(command, **kwargs):
                calls.append(command)
                returncode = 1 if command[:3] == ['zig', 'build', 'test'] else 0
                return argparse.Namespace(returncode=returncode, stderr='')
            with patch.object(experiment, 'resolve_revision', side_effect=lambda x: x), \
                 patch.object(experiment, 'identity', return_value={}), patch.object(experiment, 'metadata', return_value={}), \
                 patch.object(experiment, 'stage_network', return_value='network'), \
                 patch.object(experiment.subprocess, 'check_output', side_effect=[b'patch', 'reference\n']), \
                 patch.object(experiment.subprocess, 'run', side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, 'debug-tests failed'):
                    experiment.run(args)
            self.assertFalse(any('bench.py' in str(c) for c in calls))
            removals = [c for c in calls if c[:3] == ['git', 'worktree', 'remove']]
            self.assertEqual(len(removals), 1)
            self.assertEqual(removals[0][-1], str(args.output / 'baseline-source'))
            self.assertEqual(json.loads((args.output / 'experiment.json').read_text())['status'], 'failed')

    def test_worktree_has_default_network_for_early_uci_ready(self):
        with tempfile.TemporaryDirectory() as root:
            tree = pathlib.Path(root) / 'tree'
            header = tree / 'vendor/stockfish/src/evaluate.h'
            header.parent.mkdir(parents=True)
            header.write_text('#define EvalFileDefaultName "nn-0123456789ab.nnue"\n')
            network = pathlib.Path(root) / 'custom-name.nnue'
            network.write_bytes(b'weights')
            staged = pathlib.Path(experiment.stage_network(tree, network))
            self.assertEqual(staged.name, 'nn-0123456789ab.nnue')
            self.assertEqual(staged.read_bytes(), b'weights')
            with self.assertRaises(ValueError):
                experiment.stage_network(tree, network)


if __name__ == '__main__':
    unittest.main()
