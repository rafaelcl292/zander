#!/usr/bin/env python3
"""Controlled single-worker baseline/candidate/reference benchmark."""
import argparse
import dataclasses
import math
import pathlib
import random
import statistics

try:
    from .compare_engines import Engine, peak_rss_bytes
    from .perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity,
                              measurement_lock, metadata, pin_engine, prepare, save, signature, validate_cpus)
except ImportError:
    from compare_engines import Engine, peak_rss_bytes
    from perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity,
                             measurement_lock, metadata, pin_engine, prepare, save, signature, validate_cpus)

LABELS = ('baseline0', 'baseline1', 'candidate0', 'candidate1', 'reference0', 'reference1')


def balanced_order(seed: int, session: int, position: int, repetition: int) -> list[str]:
    # One shuffled base per six-session block and position. Every label occupies
    # every execution rank exactly once in each complete block, for every repeat.
    rng = random.Random(f'{seed}:{session // len(LABELS)}:{position}:{repetition}')
    order = list(LABELS)
    rng.shuffle(order)
    shift = session % len(order)
    return order[shift:] + order[:shift]


def interval(pairs: list[tuple[float, float]], draws: int, seed: int) -> dict:
    """Ratio of mean session totals; resample whole paired sessions, not searches."""
    if not pairs or any(a <= 0 or b <= 0 or not math.isfinite(a + b) for a, b in pairs):
        raise ValueError('Expected positive finite paired session totals')
    rng = random.Random(seed)
    def change(values):
        return 100 * (sum(a for a, _ in values) / sum(b for _, b in values) - 1)
    samples = sorted(change(rng.choices(pairs, k=len(pairs))) for _ in range(draws))
    return {'change_pct': change(pairs), 'ci95_pct': [samples[int(draws * .025)], samples[min(draws - 1, int(draws * .975))]]}


def verdict(effect: dict, controls: list[dict], sessions: int, minimum: float, tolerance: float) -> str:
    if sessions < 12 or any(c['ci95_pct'][0] < -tolerance or c['ci95_pct'][1] > tolerance for c in controls):
        return 'inconclusive'
    low, high = effect['ci95_pct']
    if high < -minimum:
        return 'improvement'
    if low > minimum:
        return 'regression'
    return 'inconclusive'


def analyze(report: dict) -> dict:
    config = report['configuration']
    positions = report['positions']
    sessions = config['sessions']
    expected_count = sessions * config['repeats'] * len(positions) * len(LABELS)
    if report['status'] != 'complete' or len(report['samples']) != expected_count:
        raise ValueError('Cannot analyze an incomplete benchmark')
    groups = {}
    expected = {}
    for sample in report['samples']:
        if sample['elapsed_ns'] <= 0 or not math.isfinite(sample['elapsed_ns']):
            raise ValueError('Invalid sample duration')
        key = (sample['session'], sample['position'], sample['label'], sample['repeat'])
        if key in groups:
            raise ValueError('Duplicate sample')
        groups[key] = sample
        sig = signature(sample)
        if expected.setdefault(sample['position'], sig) != sig:
            raise ValueError('Search mismatch: speed verdict is invalid')
    totals = []
    per_position = []
    for session in range(sessions):
        totals.append({label: sum(statistics.mean(groups[session, p['id'], label, repeat]['elapsed_ns']
                                                  for repeat in range(config['repeats']))
                                  for p in positions) for label in LABELS})
    for p in positions:
        times = {label: statistics.mean(groups[s, p['id'], label, r]['elapsed_ns']
                                         for s in range(sessions) for r in range(config['repeats'])) / 1e6 for label in LABELS}
        per_position.append({'id': p['id'], 'category': p['category'], 'mean_ms': times,
                             'short_search': min(times.values()) < config['min_search_ms']})
    def compare(numerator, denominator):
        pairs = [(statistics.mean(row[k] for k in numerator), statistics.mean(row[k] for k in denominator)) for row in totals]
        return interval(pairs, config['bootstrap'], config['seed'])
    controls = {name: compare([name + '1'], [name + '0']) for name in ('baseline', 'candidate', 'reference')}
    effect = compare(['candidate0', 'candidate1'], ['baseline0', 'baseline1'])
    decision = verdict(effect, list(controls.values()), sessions, config['min_effect_pct'], config['control_tolerance_pct'])
    short = [p['id'] for p in per_position if p['short_search']]
    reasons = []
    if sessions < 12:
        reasons.append('Fewer than twelve independent sessions')
    for name, control in controls.items():
        low, high = control['ci95_pct']
        if low < -config['control_tolerance_pct'] or high > config['control_tolerance_pct']:
            reasons.append(f'{name} A/A interval exceeds noise tolerance')
    if short:
        reasons.append('Some workloads are shorter than the declared timing floor')
    binaries = report.get('executables', {})
    if binaries.get('baseline', {}).get('sha256') is not None and binaries['baseline']['sha256'] == binaries.get('candidate', {}).get('sha256'):
        reasons.append('Baseline and candidate are the same binary (A/A experiment)')
    if reasons:
        decision = 'inconclusive'
    elif decision == 'inconclusive':
        reasons.append('Interval does not establish a change beyond the practical threshold')
    return {'verdict': decision, 'reasons': reasons, 'candidate_vs_baseline': effect,
            'candidate_vs_reference': compare(['candidate0', 'candidate1'], ['reference0', 'reference1']),
            'aa_controls': controls, 'session_totals_ns': totals, 'positions': per_position,
            'short_positions': short, 'searches': expected_count, 'search_equivalent': True,
            'note': 'Negative change means less time. Paired session bootstrap covers within-run variation, not all host interference. No strength claim.'}


def render_text(summary: dict) -> str:
    lines = [f"Verdict: {summary['verdict']}", *summary['reasons']]
    for key in ('candidate_vs_baseline', 'candidate_vs_reference'):
        item = summary[key]
        lo, hi = item['ci95_pct']
        lines.append(f"{key}: {item['change_pct']:+.2f}% time; 95% session interval [{lo:+.2f}%, {hi:+.2f}%]")
    for name, item in summary['aa_controls'].items():
        lines.append(f"A/A {name}: {item['change_pct']:+.2f}%; interval {item['ci95_pct']}")
    lines.extend([f"Short workloads: {', '.join(summary['short_positions']) or 'none'}",
                  f"Matching searches: {summary['searches']}", summary['note']])
    return '\n'.join(lines) + '\n'


def run(args) -> dict:
    validate_cpus(args.cpu, args.harness_cpu)
    positions = corpus(args.positions)
    paths = {name: getattr(args, name).resolve() for name in ('baseline', 'candidate', 'reference')}
    report = {'schema_version': 1, 'status': 'running', 'environment': metadata(),
              'configuration': {key: str(value) if isinstance(value, pathlib.Path) else value for key, value in vars(args).items()},
              'executables': {name: identity(path) for name, path in paths.items()}, 'network': identity(args.network),
              'corpus': identity(args.positions), 'positions': [dataclasses.asdict(p) for p in positions],
              'method': 'Sum of position mean times per session, averaged over identical process copies; fresh processes per session. Bootstrap complete paired sessions. No outlier removal.',
              'samples': [], 'warmups': [], 'rss': []}
    args.output.mkdir(parents=True, exist_ok=False)
    save(args.output / 'protocol.json', report)
    expected = {}
    warm_expected = {}
    try:
        with measurement_lock(), harness_affinity(args.harness_cpu):
            for session in range(args.sessions):
                engines = {}
                rng = random.Random(args.seed + session)
                labels = list(LABELS)
                rng.shuffle(labels)
                try:
                    for label in labels:
                        engine = Engine(paths[label[:-1]], args.network, 1, args.hash)
                        engines[label] = engine
                        pin_engine(engine, args.cpu)
                    for label in labels:
                        for p in positions:
                            prepare(engines[label], p)
                            sample = engines[label].search(f'depth {args.warmup_depth}')
                            report['warmups'].append({'session': session, 'label': label, 'position': p.id, **sample})
                            if warm_expected.setdefault(p.id, signature(sample)) != signature(sample):
                                raise RuntimeError(f'Warmup search mismatch: {p.id}, {label}')
                    order = list(enumerate(positions))
                    rng.shuffle(order)
                    for index, p in order:
                        for repeat in range(args.repeats):
                            for rank, label in enumerate(balanced_order(args.seed, session, index, repeat)):
                                prepare(engines[label], p)
                                sample = engines[label].search(f'depth {args.depth}')
                                report['samples'].append({'session': session, 'repeat': repeat, 'position': p.id, 'label': label, 'rank': rank, **sample})
                                if sample['move'] == '0000':
                                    raise RuntimeError(f'Terminal position belongs in correctness corpus: {p.id}')
                                if expected.setdefault(p.id, signature(sample)) != signature(sample):
                                    raise RuntimeError(f'Search mismatch: {p.id}, {label}; timing verdict suppressed')
                    report['rss'].append({'session': session, **{name: peak_rss_bytes(e) for name, e in engines.items()}})
                finally:
                    for engine in engines.values():
                        engine.close()
                save(args.output / 'results.json', report)
                print(f'Session {session + 1}/{args.sessions}: all search signatures match', flush=True)
        report['status'] = 'complete'
        summary = analyze(report)
        save(args.output / 'summary.json', summary)
        (args.output / 'report.txt').write_text(render_text(summary))
        print(render_text(summary), end='')
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        save(args.output / 'results.json', report)
    return summary


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'reference', 'network', 'output'):
        p.add_argument('--' + name, type=pathlib.Path, required=True)
    p.add_argument('--positions', type=pathlib.Path, default=DEFAULT_CORPUS)
    p.add_argument('--sessions', type=int, default=12)
    p.add_argument('--repeats', type=int, default=2)
    p.add_argument('--depth', type=int, default=20)
    p.add_argument('--warmup-depth', type=int, default=12)
    p.add_argument('--hash', type=int, default=64)
    p.add_argument('--cpu', type=int)
    p.add_argument('--harness-cpu', type=int)
    p.add_argument('--seed', type=int, default=20261007)
    p.add_argument('--bootstrap', type=int, default=10000)
    p.add_argument('--min-effect-pct', type=float, default=.5)
    p.add_argument('--control-tolerance-pct', type=float, default=2)
    p.add_argument('--min-search-ms', type=float, default=20)
    return p


def main():
    p = parser()
    args = p.parse_args()
    if args.sessions < 6 or args.sessions % 6 or min(args.repeats, args.depth, args.warmup_depth, args.hash) < 1 or args.bootstrap < 100:
        p.error('Use sessions in multiples of six, positive limits, and at least 100 bootstrap draws')
    if any(not math.isfinite(x) or x < 0 for x in (args.min_effect_pct, args.control_tolerance_pct, args.min_search_ms)):
        p.error('Thresholds must be finite and nonnegative')
    run(args)


if __name__ == '__main__':
    main()
