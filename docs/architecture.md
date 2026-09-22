# Architecture

[Documentation home](../README.md) · [Usage](usage.md) · [Development](development.md)

Zander ports Stockfish's board representation, evaluation, and search into Zig.
The vendored C++ implementation supplies reference results for tests; the
production executable does not link against it.

## Source map

| Area | Entry points |
| --- | --- |
| Board state, attacks, and legal moves | [position.zig](../src/position.zig), [attacks.zig](../src/attacks.zig), [movegen.zig](../src/movegen.zig) |
| Search and move ordering | [search.zig](../src/search.zig), [quiescence.zig](../src/quiescence.zig), [movepick.zig](../src/movepick.zig) |
| Transposition table and histories | [tt.zig](../src/tt.zig), [history.zig](../src/history.zig), [search_history.zig](../src/search_history.zig) |
| NNUE loading, incremental evaluation, and dispatch | [src/nnue/](../src/nnue) |
| Engine lifecycle and parallel workers | [engine.zig](../src/engine.zig), [search_thread.zig](../src/search_thread.zig), [worker_memory.zig](../src/worker_memory.zig) |
| Protocol and time management | [uci.zig](../src/uci.zig), [time_management.zig](../src/time_management.zig) |
| Memory allocation and NUMA | [memory.zig](../src/memory.zig), [numa.zig](../src/numa.zig) |
| Native endgame probing | [src/syzygy/](../src/syzygy) |
| CLI and library exports | [main.zig](../src/main.zig), [root.zig](../src/root.zig) |
| Test harnesses and C++ oracles | [tests/](../tests) |

## Implementation approach

Search combines iterative deepening, alpha-beta and quiescence search,
aspiration windows, move ordering, pruning, and a shared transposition table.
Persistent workers reuse caches and caller-owned recursive search storage,
without general-purpose allocation in the recursive search path.

NNUE evaluation uses incremental accumulators and quantized inference. Scalar
kernels remain selectable alongside portable vectors and runtime x86 dispatch.
See [build options](usage.md#build-the-engine) for selecting a backend.

## Verification boundaries

Differential tests compare board transitions, move generation, evaluation,
and covered single-worker search paths against the pinned reference. Separate
integration tests exercise resource replacement, UCI process behavior, and
Syzygy probing. See [Development](development.md) for commands and prerequisites.

Passing these tests does not imply full search parity, Stockfish's playing
strength, or equal behavior and performance on every platform. Exact search
comparisons use one worker; parallel search should be assessed separately.

The reference revision and upstream attribution are recorded in the
[README](../README.md#attribution-and-license).
