#!/usr/bin/env python3
"""Screen engines by user-mode cycles on equal-work, fixed-depth searches.

A fast first filter before a controlled bench.py run. Every engine must produce
identical search signatures, so cycle and instruction ratios compare the same
work. Counts exclude initialization, warmup, hash clearing and kernel time.
Ratios are screening signals, not timing evidence or confidence intervals.
"""
import argparse
import dataclasses
import pathlib
import statistics

try:
    from .compare_engines import Engine
    from .perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                              metadata, pin_engine, prepare, save, signature, validate_cpus)
    from .profile_engine import Perf, parse_stat
except ImportError:
    from compare_engines import Engine
    from perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                             metadata, pin_engine, prepare, save, signature, validate_cpus)
    from profile_engine import Perf, parse_stat

EVENTS = ('cycles:u', 'instructions:u')


def labelled(value: str) -> tuple[str, pathlib.Path]:
    label, separator, path = value.partition('=')
    if not separator or not label or not path:
        raise argparse.ArgumentTypeError('Expected LABEL=PATH')
    return label, pathlib.Path(path)


def summarize(samples: list[dict], labels: list[str], positions: list[str]) -> dict:
    """Median counts per position and label; ratios against the first label.

    The aggregate ratio divides summed medians, so longer searches weigh more,
    matching bench.py's session-total statistic.
    """
    medians: dict[str, dict[str, dict[str, float]]] = {}
    for position in positions:
        medians[position] = {}
        for label in labels:
            rows = [s for s in samples if s['position'] == position and s['label'] == label]
            if not rows:
                raise ValueError(f'No samples for {label} on {position}')
            medians[position][label] = {e: statistics.median(r['counters'][e] for r in rows) for e in EVENTS}
    base = labels[0]
    result = {'base': base, 'positions': {}, 'total': {}}
    for position in positions:
        result['positions'][position] = {
            label: {e: medians[position][label][e] / medians[position][base][e] for e in EVENTS}
            for label in labels[1:]}
    for label in labels[1:]:
        result['total'][label] = {
            e: sum(medians[p][label][e] for p in positions) / sum(medians[p][base][e] for p in positions)
            for e in EVENTS}
    return result


def report(summary: dict, labels: list[str], positions: list[str]) -> str:
    lines = [f"Ratios versus {summary['base']} (above 1 means more user-mode work)"]
    for label in labels[1:]:
        total = summary['total'][label]
        lines.append(f"{label}: cycles {total['cycles:u']:.4f}, instructions {total['instructions:u']:.4f}")
    lines.append('Per position (cycles):')
    for position in positions:
        ratios = ', '.join(f"{label} {summary['positions'][position][label]['cycles:u']:.4f}" for label in labels[1:])
        lines.append(f'  {position}: {ratios}')
    lines.append('Equal-work screening only: confirm retained changes with bench.py. No strength claim.')
    return '\n'.join(lines) + '\n'


def run(args) -> dict:
    validate_cpus(args.cpu, args.harness_cpu)
    labels = [label for label, _ in args.engine]
    if len(set(labels)) != len(labels) or len(labels) < 2:
        raise ValueError('Use at least two engines with unique labels')
    positions = corpus(args.positions)
    args.output.mkdir(parents=True, exist_ok=False)
    data = {'schema_version': 1, 'status': 'running', 'environment': metadata(),
            'configuration': {'depth': args.depth, 'warmup_depth': args.warmup_depth, 'hash': args.hash,
                              'repeats': args.repeats, 'cpu': args.cpu, 'harness_cpu': args.harness_cpu},
            'engines': {label: identity(path) for label, path in args.engine},
            'network': identity(args.network), 'corpus': identity(args.positions),
            'positions': [dataclasses.asdict(p) for p in positions], 'samples': []}
    save(args.output / 'screen.json', data)
    expected: dict[str, tuple] = {}
    try:
        with measurement_lock(), harness_affinity(args.harness_cpu):
            for repeat in range(args.repeats):
                # Rotate engine order each repeat so no engine always runs first.
                order = args.engine[repeat % len(args.engine):] + args.engine[:repeat % len(args.engine)]
                for label, path in order:
                    engine = Engine(path, args.network, 1, args.hash)
                    try:
                        pin_engine(engine, args.cpu)
                        for index, p in enumerate(positions):
                            prepare(engine, p)
                            engine.search(f'depth {args.warmup_depth}')
                            prepare(engine, p)
                            stem = f'{repeat:02d}-{label}-{index:02d}'
                            destination = args.output / f'{stem}.csv'
                            command = [args.perf, 'stat', '-x', ';', '--no-big-num', '-e', '{' + ','.join(EVENTS) + '}',
                                       '-p', str(engine.process.pid), '-o', str(destination)]
                            profiler = Perf(command, args.output / f'{stem}.log')
                            try:
                                profiler.command('enable')
                                sample = engine.search(f'depth {args.depth}')
                                profiler.command('disable')
                            finally:
                                profiler.close()
                            if expected.setdefault(p.id, signature(sample)) != signature(sample):
                                raise RuntimeError(f'Search signature differs for {label} on {p.id}')
                            counters = {c['event']: c for c in parse_stat(destination)}
                            if any(not counters.get(e, {}).get('available') for e in EVENTS):
                                raise RuntimeError(f'Counters unavailable; inspect {destination}')
                            data['samples'].append({'repeat': repeat, 'label': label, 'position': p.id,
                                                    'counters': {e: counters[e]['count'] for e in EVENTS},
                                                    'sample': sample})
                            save(args.output / 'screen.json', data)
                    finally:
                        engine.close()
                print(f'Repeat {repeat + 1}/{args.repeats}: all search signatures match', flush=True)
        ids = [p.id for p in positions]
        data['summary'] = summarize(data['samples'], labels, ids)
        data['status'] = 'complete'
        (args.output / 'report.txt').write_text(report(data['summary'], labels, ids))
    except BaseException as error:
        data['status'] = 'failed'
        data['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        save(args.output / 'screen.json', data)
    return data


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--engine', type=labelled, action='append', required=True,
                   help='LABEL=PATH; repeat for each engine. The first is the ratio base.')
    for name in ('network', 'output'):
        p.add_argument('--' + name, type=pathlib.Path, required=True)
    p.add_argument('--positions', type=pathlib.Path, default=DEFAULT_CORPUS)
    p.add_argument('--perf', default='perf', help='perf executable, including a matching WSL tools binary')
    p.add_argument('--depth', type=int, default=20)
    p.add_argument('--warmup-depth', type=int, default=12)
    p.add_argument('--hash', type=int, default=64)
    p.add_argument('--repeats', type=int, default=3)
    p.add_argument('--cpu', type=int)
    p.add_argument('--harness-cpu', type=int)
    return p


def main():
    p = parser()
    args = p.parse_args()
    if min(args.depth, args.warmup_depth, args.hash, args.repeats) < 1:
        p.error('Limits must be positive')
    print(report(run(args)['summary'], [label for label, _ in args.engine],
                 [p.id for p in corpus(args.positions)]), end='')


if __name__ == '__main__':
    main()
