#!/usr/bin/env python3
"""Build two committed revisions in isolated worktrees, validate, then measure."""
import argparse
import pathlib
import re
import subprocess
import sys

try:
    from .perf_common import ROOT, DEFAULT_CORPUS, identity, metadata, save
except ImportError:
    from perf_common import ROOT, DEFAULT_CORPUS, identity, metadata, save


def resolve_revision(value: str) -> str:
    return subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', value + '^{commit}'],
                                   cwd=ROOT, text=True).strip()


def stage_network(tree: pathlib.Path, network: pathlib.Path) -> str:
    # UCI integration verifies default startup before setting EvalFile. Merely
    # passing -Dnetwork does not populate that runtime-relative default path.
    header = (tree / 'vendor/stockfish/src/evaluate.h').read_text()
    match = re.search(r'#define EvalFileDefaultName "(nn-[0-9a-f]{12}\.nnue)"', header)
    if match is None:
        raise ValueError('Cannot identify the revision default network')
    destination = tree / 'networks' / match.group(1)
    destination.parent.mkdir(exist_ok=True)
    if destination.exists():
        raise ValueError(f'Refusing to replace an existing network: {destination}')
    destination.symlink_to(network.resolve())
    return str(destination)


def run(args):
    revisions = {name: resolve_revision(getattr(args, name)) for name in ('baseline', 'candidate')}
    args.output = args.output.resolve()
    args.network = args.network.resolve()
    args.reference = args.reference.resolve()
    args.positions = args.positions.resolve()
    report: dict = {'schema_version': 1, 'status': 'building', 'environment': metadata(), 'revisions': revisions,
              'network': identity(args.network), 'reference': identity(args.reference),
              'commands': [], 'worktrees': {}, 'builds': {}, 'cleanup_errors': []}
    args.output.mkdir(parents=True, exist_ok=False)
    worktrees = []

    def execute(command, directory=ROOT, name='command'):
        if command[:2] == ['zig', 'build']:
            command = [*command, f'-j{getattr(args, "jobs", 2)}']
        log = args.output / f'{len(report["commands"]):02d}-{name}.log'
        entry: dict = {'command': [str(x) for x in command], 'cwd': str(directory), 'log': str(log)}
        report['commands'].append(entry)
        save(args.output / 'experiment.json', report)
        with log.open('w') as output:
            result = subprocess.run(command, cwd=directory, stdout=output, stderr=subprocess.STDOUT)
        entry['returncode'] = result.returncode
        if result.returncode:
            raise RuntimeError(f'{name} failed ({result.returncode}); inspect {log}')

    try:
        patch = subprocess.check_output(['git', 'diff', '--binary', revisions['baseline'], revisions['candidate']], cwd=ROOT)
        (args.output / 'change.patch').write_bytes(patch)
        for name, revision in revisions.items():
            tree = args.output / f'{name}-source'
            execute(['git', 'worktree', 'add', '--detach', str(tree), revision], name=f'{name}-checkout')
            worktrees.append(tree)
            report['worktrees'][name] = str(tree)
            execute(['git', 'submodule', 'update', '--init'], tree, f'{name}-submodule')
            report['builds'][name] = {'stockfish_revision': subprocess.check_output(
                ['git', '-C', str(tree / 'vendor/stockfish'), 'rev-parse', 'HEAD'], text=True).strip()}
            report['builds'][name]['test_network'] = stage_network(tree, args.network)
            execute(['zig', 'fmt', '--check', 'build.zig', 'src', 'tests'], tree, f'{name}-format')
            execute(['zig', 'build', 'test'], tree, f'{name}-debug-tests')
            options = ['-Doptimize=ReleaseFast', '-Dnnue-backend=auto', f'-Dnetwork={args.network}']
            execute(['zig', 'build', 'test', 'differential', 'network-test', 'search-test', 'engine-test', 'uci-test', *options],
                    tree, f'{name}-reference-tests')
            execute(['zig', 'build', 'python-check'], tree, f'{name}-python-check')
            execute([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py'], tree, f'{name}-python-tests')
            prefix = args.output / name
            execute(['zig', 'build', '-Doptimize=ReleaseFast', '-Dnnue-backend=auto', '--prefix', str(prefix)], tree, f'{name}-build')
            report['builds'][name]['executable'] = identity(prefix / 'bin/zander')
        report['status'] = 'benchmarking'
        command = [sys.executable, str(ROOT / 'scripts/bench.py'), '--baseline', str(args.output / 'baseline/bin/zander'),
                   '--candidate', str(args.output / 'candidate/bin/zander'), '--reference', str(args.reference),
                   '--network', str(args.network), '--positions', str(args.positions), '--output', str(args.output / 'benchmark'),
                   '--sessions', str(args.sessions), '--repeats', str(args.repeats), '--depth', str(args.depth),
                   '--warmup-depth', str(args.warmup_depth), '--hash', str(args.hash), '--seed', str(args.seed)]
        for name in ('cpu', 'harness_cpu'):
            if getattr(args, name) is not None:
                command += ['--' + name.replace('_', '-'), str(getattr(args, name))]
        execute(command, name='benchmark')
        if args.profile:
            report['status'] = 'profiling'
            for name in ('baseline', 'candidate', 'reference'):
                executable = args.reference if name == 'reference' else args.output / name / 'bin/zander'
                command = [sys.executable, str(ROOT / 'scripts/profile_engine.py'), '--engine', str(executable),
                           '--network', str(args.network), '--positions', str(args.positions), '--perf', args.perf,
                           '--output', str(args.output / f'profile-{name}'), '--hash', str(args.hash)]
                for option in ('cpu', 'harness_cpu'):
                    if getattr(args, option) is not None:
                        command += ['--' + option.replace('_', '-'), str(getattr(args, option))]
                execute(command, name=f'profile-{name}')
        report['status'] = 'complete'
        (args.output / 'report.txt').write_text((args.output / 'benchmark/report.txt').read_text() +
            '\nRevisions and validation: experiment.json\nExact committed diff: change.patch\n' +
            ('Profiles: profile-baseline/, profile-candidate/, profile-reference/\n' if args.profile else 'Profiling not requested.\n'))
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if not args.keep_worktrees:
            for tree in reversed(worktrees):
                # Only worktrees created by this invocation are removed. Builds
                # and evidence live outside them and remain available.
                result = subprocess.run(['git', 'worktree', 'remove', '--force', str(tree)], cwd=ROOT, capture_output=True, text=True)
                if result.returncode:
                    report['cleanup_errors'].append({'path': str(tree), 'error': result.stderr})
        save(args.output / 'experiment.json', report)
    print((args.output / 'report.txt').read_text())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline', required=True, help='Committed Git revision')
    p.add_argument('--candidate', required=True, help='Committed Git revision')
    for name in ('reference', 'network', 'output'):
        p.add_argument('--' + name, required=True, type=pathlib.Path)
    p.add_argument('--positions', type=pathlib.Path, default=DEFAULT_CORPUS)
    p.add_argument('--sessions', type=int, default=12)
    p.add_argument('--repeats', type=int, default=2)
    p.add_argument('--depth', type=int, default=20)
    p.add_argument('--warmup-depth', type=int, default=12)
    p.add_argument('--hash', type=int, default=64)
    p.add_argument('--seed', type=int, default=20261007)
    p.add_argument('--cpu', type=int)
    p.add_argument('--harness-cpu', type=int)
    p.add_argument('--jobs', type=int, default=2, help='Maximum parallel Zig build jobs')
    p.add_argument('--profile', action='store_true')
    p.add_argument('--perf', default='perf')
    p.add_argument('--keep-worktrees', action='store_true')
    args = p.parse_args()
    if args.sessions < 6 or args.sessions % 6 or min(args.repeats, args.depth, args.warmup_depth, args.hash, args.jobs) < 1:
        p.error('Use positive limits and a session count divisible by six')
    run(args)


if __name__ == '__main__':
    main()
