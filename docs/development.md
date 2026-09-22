# Development

[Documentation home](../README.md) · [Usage](usage.md) · [Architecture](architecture.md)

Run these commands from the repository root. Build steps are defined in
[build.zig](../build.zig).

## Prerequisites

| Task | Requirements beyond the checkout |
| --- | --- |
| Native build and unit tests | Zig 0.16.0 |
| Differential and reference tests | Stockfish submodule and a host C++17 compiler with GNU-compatible flags; the harness targets Linux x86-64 |
| Network-dependent tests | Downloaded NNUE weights; fetching them requires Python and the submodule |
| UCI integration tests | Python and NNUE weights |
| Syzygy reference tests | Python, reference-test prerequisites, and regression tablebases |
| Python type checking | `uvx`; the build pins `ty==0.0.32` |

Python helpers target 3.14.7, pinned in [.python-version](../.python-version).
Type-checker configuration is in [ty.toml](../ty.toml).

## Unit and differential tests

Unit tests run without the submodule or a C++ compiler:

```sh
zig build test
```

To compare against the pinned Stockfish reference:

```sh
git submodule update --init
zig build test differential
zig build test differential -Doptimize=ReleaseFast
```

The C++ oracles are test dependencies, not part of the production engine.
Reference tests report an initialization instruction when the submodule is missing.

## Network and process integration

Fetch the network, then test real NNUE evaluation, covered single-worker search
paths, engine resource handling, and UCI through actual process pipes:

```sh
python3 scripts/fetch_network.py
zig build network-test search-test engine-test uci-test \
  -Dnetwork=networks/nn-134a887f4c8f.nnue -Doptimize=ReleaseFast
```

`network-test` and `search-test` require the C++ reference.
`engine-test` and `uci-test` do not. These four steps are available only when
`-Dnetwork` is supplied. `quiescence-test` is an alias for `search-test`.

Builds default to scalar NNUE. To exercise automatic backend selection, append
`-Dnnue-backend=auto` to the test command.

## Syzygy regression tests

Download the small regression corpus and compare native probing with Stockfish:

```sh
python3 scripts/fetch_tablebases.py
zig build syzygy-test -Dtablebases=artifacts/syzygy -Doptimize=ReleaseFast
```

The fetch helper verifies sizes and SHA-256 hashes against
[the pinned manifest](../tests/syzygy_manifest.json). This is a regression corpus,
not a complete collection of endgame tablebases. The `syzygy-test` step is
available only when `-Dtablebases` is supplied.

To include tablebase coverage in network and UCI tests, also pass
`-Dtablebases=artifacts/syzygy` to their build command.

## Formatting and Python checks

```sh
zig fmt --check build.zig src tests
zig build python-check
```

## Compare engines

See the [performance report](performance.md) for measured time, nodes, memory,
and thread scaling, with search equivalence and playing strength kept separate.

The [comparison harness](../scripts/compare_engines.py) runs repeated fixed-depth
UCI searches and can run paired games. Prepare the submodule and network first,
then build a scalar reference and candidate:

```sh
python3 scripts/build_reference.py
zig build -Doptimize=ReleaseFast -Dnnue-backend=scalar
python3 scripts/compare_engines.py \
  zig-out/bin/zander artifacts/stockfish-reference \
  --network networks/nn-134a887f4c8f.nnue \
  --depth 6 --repeats 3 --threads 1 --require-identical \
  --output artifacts/comparison.json
```

`--require-identical` checks move, score, principal variation, and node count
across samples and requires one worker. Omit it when comparing configurations
where exact search equivalence is not expected. Use `--help` for all options.

The JSON report includes executable and network hashes, configuration, search
samples, median elapsed times, and optional game results. A
`reference_over_candidate` ratio above 1 means the candidate took less time.
The reference build helper produces a scalar executable; account for backend
and compiler differences when interpreting timing comparisons.

It also records the positions file hash and `benchmark_peak_rss_bytes` for each
engine: Linux process high-water RSS through the benchmarks, including
initialization and excluding subsequent games. On unsupported platforms this
value is `null`. Hash size and worker payload budgets are not total process RSS.

Add `--games 20 --game-nodes 10000` to run 20 games with colors swapped in pairs.
Games reaching the ply limit remain unfinished. These checks do not establish
playing strength or an Elo rating.

Generated binaries, reports, and regression tablebases belong under `artifacts/`,
which is ignored by Git.
