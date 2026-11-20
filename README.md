# Zander

A native Zig port of Stockfish, with neural network evaluation, parallel search,
and a differential test suite against a pinned C++ reference.

Zander connects to UCI chess GUIs and supports standard chess, Chess960,
MultiPV, configurable playing strength, and Syzygy endgame tablebases. The
production engine is written in Zig and does not link against Stockfish C++.

The port is in development. It does not claim Stockfish's playing strength,
performance, or complete parity across every platform and configuration.

## Quick start

Use **Zig 0.17.1**, Git, and Python. Python helpers target **3.14.7**, pinned in
[.python-version](.python-version).

```sh
git clone --recurse-submodules https://github.com/rafaelcl292/zander.git
cd zander
python3 scripts/fetch_network.py
zig build -Doptimize=ReleaseFast -Dnnue-backend=auto
./zig-out/bin/zander
```

Add `zig-out/bin/zander` as a UCI engine in your chess GUI. If the GUI starts the
engine from another directory, set `EvalFile` to the absolute path of
`networks/nn-bddd9d57eb87.nnue`.

Native builds and unit tests work without the Stockfish submodule or a C++
compiler. The quick start includes the submodule because the network fetch
helper reads it to identify the pinned weights. Weights are downloaded separately.

## Documentation

- [Usage](docs/usage.md): build options, network setup, UCI, and diagnostic commands.
- [Development](docs/development.md): prerequisites, tests, and engine comparisons.
- [Performance tools](docs/performance-tools.md): controlled benchmarks, profiling, revision experiments, and kernel replay.
- [Performance](docs/performance.md): validation scope and local experiment records.
- [Architecture](docs/architecture.md): source map and verification boundaries.

## Attribution and license

Zander derives from **Stockfish**, developed by the Stockfish team and
contributors. The reference in [vendor/stockfish](vendor/stockfish) is pinned to
commit [`1819b9ea37588be8adb044179fb54512f87c8249`](https://github.com/official-stockfish/Stockfish/tree/1819b9ea37588be8adb044179fb54512f87c8249).

Licensed under **GPL-3.0-or-later**. See [LICENSE](LICENSE) and
[AUTHORS.stockfish](AUTHORS.stockfish).
