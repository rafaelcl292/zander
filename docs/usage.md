# Usage

[Documentation home](../README.md) · [Development](development.md) · [Architecture](architecture.md)

Run the commands below from the repository root. For a fresh checkout, follow
the [quick start](../README.md#quick-start).

## Build the engine

Zig 0.16.0 is required. A native build needs neither the Stockfish submodule nor
a C++ compiler:

```sh
zig build -Doptimize=ReleaseFast -Dnnue-backend=auto
```

The executable is written to `zig-out/bin/zander` (`zander.exe` on Windows).
The default NNUE backend is `scalar`; `auto` enables runtime x86 dispatch and
portable vectors on other architectures. Explicit backends are `scalar`,
`vector`, `sse2`, and `avx2`. List build options with `zig build --help`.

Native builds can use instructions specific to the build machine. To build a
portable x86-64 Linux executable with runtime NNUE dispatch:

```sh
zig build -Doptimize=ReleaseFast -Dnnue-backend=auto \
  -Dtarget=x86_64-linux -Dcpu=baseline
```

## Prepare the network

Evaluation and search require NNUE weights. The fetch helper reads the default
network name from the pinned Stockfish source and verifies the SHA-256 prefix:

```sh
git submodule update --init
python3 scripts/fetch_network.py
```

The default path is `networks/nn-134a887f4c8f.nnue`, relative to the engine's
working directory. In a GUI, set the `EvalFile` option to an absolute path if
necessary. You can also supply a network when starting UCI mode:

```sh
./zig-out/bin/zander uci /absolute/path/to/nn-134a887f4c8f.nnue
```

If reference tests report missing Stockfish sources, run
`git submodule update --init`. Building the native executable alone does not
fetch or require these sources.

## Play through UCI

Starting the executable without arguments enters UCI mode:

```sh
./zig-out/bin/zander
```

Send the following commands in the running process:

```text
uci
isready
ucinewgame
position startpos moves e2e4 e7e5
go movetime 3000
```

Wait for `bestmove` before sending the next position. Use `stop` to interrupt a
search and `quit` to exit. The command loop remains responsive during search.

The `uci` response lists available options and their limits. Common options are:

| Option | Purpose |
| --- | --- |
| `EvalFile` | Path to the NNUE weights |
| `Threads` | Search worker count |
| `Hash` | Transposition table size in MiB |
| `MultiPV` | Number of principal variations to report |
| `UCI_Chess960` | Enable Chess960 mode |
| `Skill Level` | Set playing strength through the skill setting |
| `UCI_LimitStrength`, `UCI_Elo` | Enable and configure the target strength setting |
| `SyzygyPath` | Directory containing Syzygy tablebases |
| `Ponder` | Enable pondering support |

For example, before starting a search:

```text
setoption name Threads value 4
setoption name Hash value 128
setoption name MultiPV value 3
```

The strength settings do not establish a measured Elo rating for this port.

## Diagnostic commands

```sh
# List commands and accepted arguments.
./zig-out/bin/zander help

# Count legal move sequences: the initial position has 197281 at depth 4.
./zig-out/bin/zander perft 4

# Evaluate the initial position or search it with one worker.
./zig-out/bin/zander eval networks/nn-134a887f4c8f.nnue
./zig-out/bin/zander search networks/nn-134a887f4c8f.nnue 8 --multipv=3

# Inspect data layout and memory requirements for four workers.
./zig-out/bin/zander layout
./zig-out/bin/zander memory 4
```

`perft`, `eval`, and `search` use the initial position unless you supply a quoted
FEN. They accept `--chess960`; diagnostic search also accepts `--multipv=N`.
Perft depths range from 0 to 8, and search depths from 1 to 245.

Diagnostic evaluation scores use internal units from the side-to-move
perspective. UCI output provides centipawn or mate scores.

To build and run a diagnostic in one step, use `zig build run -- perft 4`.
