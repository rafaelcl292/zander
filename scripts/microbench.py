#!/usr/bin/env python3
"""Capture search PVs, then replay them through native kernel microbenchmarks."""
import argparse
import dataclasses
import json
import pathlib
import random
import statistics
import subprocess

try:
    from .compare_engines import Engine
    from .perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                              metadata, pin_engine, prepare, save, validate_cpus)
except ImportError:
    from compare_engines import Engine
    from perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                             metadata, pin_engine, prepare, save, validate_cpus)

MODES = ('nnue', 'movegen', 'move_ordering', 'tt')


def run(args):
    validate_cpus(args.cpu, None)
    positions = corpus(args.positions)
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'schema_version': 1, 'status': 'running', 'environment': metadata(),
              'configuration': {k: str(v) if isinstance(v, pathlib.Path) else v for k, v in vars(args).items()},
              'executables': {name: identity(getattr(args, name)) for name in ('engine', 'baseline', 'candidate')},
              'network': identity(args.network), 'corpus': identity(args.positions), 'traces': [], 'samples': [],
              'note': 'Warm PV-path replay, including make/unmake and checksum work. Histories use initial values; TT is a small warm key set. This is not the full search access distribution; confirm every gain with bench.py.'}
    try:
        with measurement_lock():
            engine = Engine(args.engine, args.network, 1, 64)
            try:
                pin_engine(engine, args.cpu)
                for p in positions:
                    prepare(engine, p)
                    sample = engine.search(f'depth {args.depth}')
                    if not sample['pv']:
                        raise ValueError(f'Cannot capture a nonterminal PV: {p.id}')
                    report['traces'].append({'position': dataclasses.asdict(p), 'search': sample, 'moves': sample['pv'].split()})
            finally:
                engine.close()
            save(args.output / 'microbench.json', report)
            rng = random.Random(args.seed)
            jobs = [(trace, mode) for trace in report['traces'] for mode in args.mode]
            rng.shuffle(jobs)
            for trace, mode in jobs:
                expected = None
                times = {'baseline': [], 'candidate': []}
                for repeat in range(args.repeats):
                    for label in (('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')):
                        command = [str(getattr(args, label).resolve()), str(args.network.resolve()), mode, str(args.iterations),
                                   str(int(trace['position']['chess960'])), trace['position']['fen'], *trace['moves']]
                        with harness_affinity(args.cpu):
                            output = subprocess.check_output(command, text=True, timeout=args.timeout)
                        result = json.loads(output)
                        if result['mode'] != mode or result['iterations'] != args.iterations or result['elapsed_ns'] <= 0:
                            raise ValueError('Invalid microbenchmark result')
                        sig = (result['checksum'], result['positions_per_iteration'])
                        if expected is not None and sig != expected:
                            raise ValueError(f'Kernel checksum mismatch: {trace["position"]["id"]}/{mode}')
                        expected = sig
                        times[label].append(result['elapsed_ns'])
                        report['samples'].append({'position': trace['position']['id'], 'label': label, 'repeat': repeat, **result})
                ratio = statistics.median(times['candidate']) / statistics.median(times['baseline'])
                print(f'{trace["position"]["id"]}/{mode}: candidate time {ratio:.4f}x baseline (diagnostic only)', flush=True)
                save(args.output / 'microbench.json', report)
        report['status'] = 'complete'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        save(args.output / 'microbench.json', report)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('engine', 'baseline', 'candidate', 'network', 'output'):
        p.add_argument('--' + name, type=pathlib.Path, required=True,
                       help='UCI engine for PV capture' if name == 'engine' else None)
    p.add_argument('--positions', type=pathlib.Path, default=DEFAULT_CORPUS)
    p.add_argument('--mode', choices=MODES, action='append', help='Repeat to select modes; default all')
    p.add_argument('--iterations', type=int, default=10000)
    p.add_argument('--repeats', type=int, default=6)
    p.add_argument('--depth', type=int, default=16)
    p.add_argument('--cpu', type=int)
    p.add_argument('--seed', type=int, default=20261007)
    p.add_argument('--timeout', type=int, default=120)
    args = p.parse_args()
    args.mode = args.mode or list(MODES)
    if min(args.iterations, args.repeats, args.depth, args.timeout) < 1 or args.repeats % 2:
        p.error('Use positive limits and an even repeat count')
    run(args)


if __name__ == '__main__':
    main()
