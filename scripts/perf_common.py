"""Shared reproducibility and workload helpers for performance tools."""
import contextlib
import dataclasses
import datetime
import json
import os
import pathlib
import platform
import subprocess

try:
    from .compare_engines import Engine, digest
except ImportError:
    from compare_engines import Engine, digest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / 'tests/performance_positions.json'


@dataclasses.dataclass(frozen=True)
class Position:
    id: str
    category: str
    fen: str
    chess960: bool = False


def corpus(path: pathlib.Path) -> list[Position]:
    entries = json.loads(path.read_text())
    if not isinstance(entries, list) or not entries:
        raise ValueError('Performance corpus must be a nonempty JSON list')
    positions = [Position(**entry) for entry in entries]
    if len({p.id for p in positions}) != len(positions):
        raise ValueError('Position IDs must be unique')
    for p in positions:
        if not all(isinstance(v, str) and v.strip() for v in (p.id, p.category, p.fen)) or type(p.chess960) is not bool:
            raise ValueError('Invalid position fields')
        if len(p.fen.split()) != 6 or '\n' in p.fen or '\r' in p.fen:
            raise ValueError(f'Expected a six-field FEN: {p.id}')
    return positions


def save(path: pathlib.Path, data) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def command_output(command: list[str], cwd: pathlib.Path = ROOT) -> str | None:
    try:
        return subprocess.check_output(command, cwd=cwd, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def metadata() -> dict:
    return {'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'platform': platform.platform(), 'python': platform.python_version(),
            'cpu': command_output(['lscpu']), 'revision': command_output(['git', 'rev-parse', 'HEAD']),
            'working_tree': command_output(['git', 'status', '--porcelain']),
            'zig': command_output(['zig', 'version']), 'cxx': command_output(['c++', '--version']),
            'affinity': sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None,
            'tool_sha256': {path.name: digest(path) for path in sorted((ROOT / 'scripts').glob('*.py'))}}


def identity(path: pathlib.Path) -> dict:
    return {'path': str(path.resolve()), 'sha256': digest(path)}


def signature(sample: dict) -> tuple:
    return tuple(sample[key] for key in ('move', 'score', 'pv', 'nodes', 'depth'))


def prepare(engine: Engine, position: Position) -> None:
    engine.send(f'setoption name UCI_Chess960 value {str(position.chess960).lower()}')
    engine.new_game()
    engine.position(position.fen)
    engine.ready()


def pin_engine(engine: Engine, cpu: int | None) -> None:
    if cpu is not None:
        for task in pathlib.Path(f'/proc/{engine.process.pid}/task').iterdir():
            os.sched_setaffinity(int(task.name), {cpu})


def validate_cpus(engine_cpu: int | None, harness_cpu: int | None) -> None:
    if engine_cpu is None and harness_cpu is None:
        return
    if not hasattr(os, 'sched_getaffinity'):
        raise ValueError('CPU pinning requires Linux sched affinity support')
    allowed = os.sched_getaffinity(0)
    if any(cpu is not None and cpu not in allowed for cpu in (engine_cpu, harness_cpu)):
        raise ValueError(f'CPU must be in the current allowed set: {sorted(allowed)}')
    if engine_cpu is not None and engine_cpu == harness_cpu:
        raise ValueError('Use different CPUs for the engine and harness')


@contextlib.contextmanager
def harness_affinity(cpu: int | None):
    previous = os.sched_getaffinity(0) if cpu is not None else None
    try:
        if cpu is not None:
            os.sched_setaffinity(0, {cpu})
        yield
    finally:
        if previous is not None:
            os.sched_setaffinity(0, previous)


@contextlib.contextmanager
def measurement_lock():
    """Prevent these tools from measuring concurrently within one checkout."""
    import fcntl
    directory = ROOT / 'artifacts'
    directory.mkdir(exist_ok=True)
    with (directory / '.performance.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another benchmark/profile is running in this checkout') from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
