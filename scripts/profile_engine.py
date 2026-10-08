#!/usr/bin/env python3
"""Collect perf counters and symbol profiles in separate, warmed search passes."""
import argparse
import dataclasses
import os
import pathlib
import select
import signal
import subprocess

try:
    from .compare_engines import Engine
    from .perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                              metadata, pin_engine, prepare, save, signature, validate_cpus)
except ImportError:
    from compare_engines import Engine
    from perf_common import (DEFAULT_CORPUS, corpus, harness_affinity, identity, measurement_lock,
                             metadata, pin_engine, prepare, save, signature, validate_cpus)


class Perf:
    """Start disabled; acknowledge measurement boundaries before searching."""
    def __init__(self, command: list[str], log: pathlib.Path):
        control_read, self.control = os.pipe()
        self.ack, ack_write = os.pipe()
        self.log = log
        self.stream = log.open('w')
        self.process = None
        try:
            self.process = subprocess.Popen(command + ['-D', '-1', '--control', f'fd:{control_read},{ack_write}'],
                                            pass_fds=(control_read, ack_write), stdout=self.stream, stderr=self.stream)
        except BaseException:
            os.close(self.control)
            os.close(self.ack)
            self.stream.close()
            raise
        finally:
            os.close(control_read)
            os.close(ack_write)

    def command(self, command: str) -> None:
        try:
            os.write(self.control, (command + '\n').encode())
            ready, _, _ = select.select([self.ack], [], [], 15)
            response = os.read(self.ack, 64) if ready else b''
            if response.rstrip(b'\x00\n') != b'ack':
                raise RuntimeError(f'perf did not acknowledge measurement boundary: {response!r}')
        except (OSError, RuntimeError) as error:
            raise RuntimeError(f'{error}; inspect {self.log} for permissions or unsupported events') from error

    def close(self) -> None:
        assert self.process is not None
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGINT)
            try:
                code = self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise RuntimeError(f'perf shutdown timed out: {self.log}') from None
            if code not in (0, -signal.SIGINT):
                raise RuntimeError(f'perf failed ({code}); inspect {self.log}')
        finally:
            os.close(self.control)
            os.close(self.ack)
            self.stream.close()


def parse_stat(path: pathlib.Path) -> list[dict]:
    counters = []
    for line in path.read_text().splitlines():
        fields = line.split(';')
        if len(fields) < 5 or fields[0].startswith('#'):
            continue
        value, unit, event, runtime, running = [s.strip() for s in fields[:5]]
        try:
            count = float(value)
            fraction = float(running.rstrip('%')) / 100
        except ValueError:
            counters.append({'event': event, 'available': False, 'raw': line})
            continue
        counters.append({'event': event, 'available': True, 'count': count, 'unit': unit,
                         'runtime_ns': runtime, 'running_fraction': fraction,
                         'multiplexed': fraction < 1})
    return counters


def run(args):
    validate_cpus(args.cpu, args.harness_cpu)
    positions = corpus(args.positions)
    if args.position:
        positions = [p for p in positions if p.id in args.position]
        if {p.id for p in positions} != set(args.position):
            raise ValueError('Unknown position ID')
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'schema_version': 1, 'status': 'running', 'environment': metadata(),
              'configuration': {k: str(v) if isinstance(v, pathlib.Path) else v for k, v in vars(args).items()},
              'executable': identity(args.engine), 'network': identity(args.network), 'corpus': identity(args.positions),
              'positions': [dataclasses.asdict(p) for p in positions], 'passes': [],
              'note': 'Instrumented elapsed times are not benchmark evidence. Counters and sampling run separately; initialization, warmup, and hash clearing are outside enabled intervals.'}
    save(args.output / 'profile.json', report)
    expected = {}
    try:
        with measurement_lock(), harness_affinity(args.harness_cpu):
            for mode in ('stat', 'record'):
                for p in positions:
                    stem = f'{positions.index(p):02d}-{mode}'
                    engine = Engine(args.engine, args.network, 1, args.hash)
                    try:
                        pin_engine(engine, args.cpu)
                        prepare(engine, p)
                        engine.search(f'depth {args.warmup_depth}')
                        prepare(engine, p)
                        if mode == 'stat':
                            destination = args.output / f'{stem}.csv'
                            command = [args.perf, 'stat', '-x', ';', '--no-big-num', '-e',
                                       '{cycles:u,instructions:u,branches:u,branch-misses:u}', '-p', str(engine.process.pid), '-o', str(destination)]
                        else:
                            destination = args.output / f'{stem}.data'
                            command = [args.perf, 'record', '-e', 'cycles:u', '-F', str(args.frequency),
                                       '-p', str(engine.process.pid), '-o', str(destination)]
                            if args.call_graph:
                                command += ['--call-graph', 'dwarf,8192']
                        profiler = Perf(command, args.output / f'{stem}.log')
                        try:
                            profiler.command('enable')
                            limit = f'depth {args.depth}' if args.depth is not None else f'nodes {args.nodes}'
                            sample = engine.search(limit)
                            profiler.command('disable')
                        finally:
                            profiler.close()
                        entry = {'position': p.id, 'mode': mode, 'command': command, 'sample': sample}
                        report['passes'].append(entry)
                        if expected.setdefault(p.id, signature(sample)) != signature(sample):
                            raise RuntimeError(f'Search changed between profiling passes: {p.id}')
                        if mode == 'stat':
                            entry['counters'] = parse_stat(destination)
                            if not entry['counters'] or any(not c['available'] for c in entry['counters']):
                                raise RuntimeError(f'Counters unavailable; inspect {destination}')
                        else:
                            with (args.output / f'{stem}-symbols.txt').open('w') as output:
                                subprocess.run([args.perf, 'report', '--stdio', '--no-children', '--percent-limit', '0.5',
                                                '-i', str(destination)], stdout=output, stderr=subprocess.STDOUT, check=True)
                        save(args.output / 'profile.json', report)
                        print(f'{mode}: {p.id}', flush=True)
                    finally:
                        engine.close()
        report['status'] = 'complete'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        save(args.output / 'profile.json', report)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('engine', 'network', 'output'):
        p.add_argument('--' + name, type=pathlib.Path, required=True)
    p.add_argument('--positions', type=pathlib.Path, default=DEFAULT_CORPUS)
    p.add_argument('--position', action='append')
    p.add_argument('--perf', default='perf', help='perf executable, including a matching WSL tools binary')
    limits = p.add_mutually_exclusive_group()
    limits.add_argument('--nodes', type=int, help='Node budget (default: 5000000)')
    limits.add_argument('--depth', type=int, help='Fixed depth for equal-work cross-engine profiles')
    p.add_argument('--warmup-depth', type=int, default=12)
    p.add_argument('--hash', type=int, default=64)
    p.add_argument('--frequency', type=int, default=499)
    p.add_argument('--call-graph', action='store_true')
    p.add_argument('--cpu', type=int)
    p.add_argument('--harness-cpu', type=int)
    return p


def main():
    p = parser()
    args = p.parse_args()
    if args.nodes is None and args.depth is None:
        args.nodes = 5_000_000
    if min(value for value in (args.nodes, args.depth, args.warmup_depth, args.hash, args.frequency) if value is not None) < 1:
        p.error('Limits must be positive')
    run(args)


if __name__ == '__main__':
    main()
