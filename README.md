# Zander

**The craft of a chess engine, expressed in Zig.**

Zander is a native Zig port of Stockfish: a UCI chess engine that brings together
neural network evaluation, parallel game-tree search, and explicit memory
management. It connects to chess GUIs, plays standard chess and Chess960, and
includes a differential test suite against a pinned Stockfish reference.

The project explores systems programming through one of its most demanding
applications: searching millions of possible moves while keeping board state,
neural accumulators, and concurrent workers in sync.

## Highlights

- **A playable engine.** UCI support with time controls, pondering, MultiPV,
  configurable playing strength, and Syzygy endgame tablebases.
- **Neural evaluation.** Incremental NNUE accumulators, quantized inference,
  portable vector kernels, and runtime x86 CPU dispatch.
- **Deep search.** Iterative deepening, alpha-beta and quiescence search,
  aspiration windows, move ordering, pruning, and a shared transposition table.
- **Explicit resource ownership.** Persistent search workers, reusable caches,
  and caller-owned recursive search storage without general-purpose allocation
  in the recursive search path.
- **Reference-driven verification.** Tests compare move generation, board
  transitions, evaluation, and covered single-worker search paths with the
  original C++ implementation.

Zander is a port in development. It does not claim Stockfish's playing strength,
performance, or complete parity across every platform and configuration.

## Build and play

You need **Zig 0.16.0**, Git, and Python to fetch the neural network. Python
helpers target **3.14.7**, pinned in `.python-version`.

```sh
git clone --recurse-submodules https://github.com/rafaelcl292/zander.git
cd zander
python3 scripts/fetch_network.py
zig build -Doptimize=ReleaseFast -Dnnue-backend=auto
./zig-out/bin/zander
```

Add `zig-out/bin/zander` as a UCI engine in your chess GUI. Set its `EvalFile`
option to the absolute path of `networks/nn-134a887f4c8f.nnue` if the GUI starts
the engine from another directory. Network weights are downloaded separately;
the fetch script verifies the SHA-256 prefix specified by the pinned reference.

Without arguments, Zander starts in UCI mode. To try it in a terminal, send:

```text
uci
isready
ucinewgame
position startpos moves e2e4 e7e5
go movetime 3000
```

Wait for `bestmove`, then send another position or `quit`. The command loop
remains responsive during search; `stop` interrupts the active search.
Use `uci` to list the supported options, including `Threads`, `Hash`, `MultiPV`,
`UCI_Chess960`, `UCI_LimitStrength`, and `SyzygyPath`.

The default build uses scalar NNUE kernels. `-Dnnue-backend=auto` enables runtime
x86 dispatch and portable vectors on other architectures. For a portable x86-64
Linux executable, also pass `-Dtarget=x86_64-linux -Dcpu=baseline`; native builds
can use instructions specific to the build machine.

## Explore the engine

```sh
# List diagnostic commands.
zig build run -- help

# Count legal move sequences: the starting position has 197281 at depth 4.
zig build run -- perft 4

# Inspect evaluation or run a fixed-depth search.
./zig-out/bin/zander eval networks/nn-134a887f4c8f.nnue
./zig-out/bin/zander search networks/nn-134a887f4c8f.nnue 8 --multipv=3
```

Diagnostics use the starting position unless you supply a quoted FEN. Their
evaluation scores use internal units; UCI output provides centipawn or mate scores.

## Under the hood

| Area | Source |
| --- | --- |
| Board representation, attacks, and legal moves | [`position.zig`](src/position.zig), [`attacks.zig`](src/attacks.zig), [`movegen.zig`](src/movegen.zig) |
| Search, move ordering, and transposition storage | [`search.zig`](src/search.zig), [`quiescence.zig`](src/quiescence.zig), [`movepick.zig`](src/movepick.zig), [`tt.zig`](src/tt.zig) |
| Neural network loading and incremental evaluation | [`src/nnue/`](src/nnue) |
| Engine lifecycle and parallel workers | [`engine.zig`](src/engine.zig), [`search_thread.zig`](src/search_thread.zig), [`worker_memory.zig`](src/worker_memory.zig) |
| Protocol and time management | [`uci.zig`](src/uci.zig), [`time_management.zig`](src/time_management.zig) |
| Native endgame tablebase probing | [`src/syzygy/`](src/syzygy) |
| Zig tests, C++ reference oracles, and UCI integration | [`tests/`](tests) |

The production engine is written in Zig and does not link against Stockfish C++.
The vendored reference is used by the test harness. Scalar reference behavior
and optional optimized backends remain separately selectable.

## Verify

The differential harness targets **Linux x86-64** and requires a host **C++17
compiler** with GNU-compatible flags. Initialize the submodule first if you
cloned without `--recurse-submodules`:

```sh
git submodule update --init
zig build test differential
zig build test differential -Doptimize=ReleaseFast
```

With the downloaded network, check real NNUE evaluation, search equivalence,
engine resource handling, and UCI behavior through actual process pipes:

```sh
zig build network-test search-test engine-test uci-test \
  -Dnetwork=networks/nn-134a887f4c8f.nnue -Doptimize=ReleaseFast
```

Python scripts and tests are type-checked with pinned `ty==0.0.32`. With `uvx`
available, run `zig build python-check`.

## Attribution and license

Zander derives from **Stockfish**, developed by the Stockfish team and
contributors. The reference is pinned to commit
[`17a6c8f1eb0da45c2ca405321919519bf4e211ba`](https://github.com/official-stockfish/Stockfish/tree/17a6c8f1eb0da45c2ca405321919519bf4e211ba)
in [`vendor/stockfish`](vendor/stockfish).

Licensed under **GPL-3.0-or-later**. See [LICENSE](LICENSE) and
[AUTHORS.stockfish](AUTHORS.stockfish) for the license and upstream credits.
