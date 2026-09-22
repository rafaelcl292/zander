# Performance report

[Documentation home](../README.md) · [Benchmark procedure](development.md#compare-engines)

**Search outputs match in the measured single-thread suites. Thread throughput
increases, but this shallow suite does not establish long-search scaling.
Playing strength remains unestablished.** The current measurements use Zander
built from clean commit `ddaa58c88e5c5e4f22cbe3889a34746a844cc35f` with Zig
0.16.0, ReleaseFast, and the automatic NNUE backend. The reference is the retained
GCC/BMI2/LTO Stockfish binary for pinned commit
`17a6c8f1eb0da45c2ca405321919519bf4e211ba`. Neither engine uses PGO.

## Search equivalence — did the searches produce the same results?

| Evidence | Depth | Positions × repeats | Matching positions |
| --- | ---: | ---: | ---: |
| Fresh one-thread comparison | 12 | 27 × 3 | 27/27 |
| Fresh pinned one-thread comparison | 16 | 27 × 7 | 27/27 |
| Fresh pinned comparison, reversed engine order | 16 | 27 × 7 | 27/27 |
| Historical extended comparison | 8 | 27 × 3 | 27/27 |
| Historical worker-memory comparison | 16 | 10 × 5 | 10/10 |

“Matching” means move, score, principal variation, and node count agree across
all samples and engines in that artifact. This is evidence for the tested inputs,
not proof that every internal search operation or all engine behavior is identical.
The fresh 2- and 4-thread runs each match on only 2/27 positions; parallel search
changes scheduling and work, so exact equality is not an acceptance criterion there.

## Execution speed, memory, and thread scaling

Fresh run: **2026-09-22 UTC and São Paulo**; Intel i7-10750H,
6 cores / 12 logical CPUs, Linux under WSL2. Same identified binaries and NNUE network
at every thread count; 27 positions, depth 12, three repeats, 64 MiB hash per
engine, NumaPolicy=none, no tablebases. No CPU affinity or explicit warmup.
Thread counts ran sequentially; engine order alternated within repeats.

| Engine | Threads | Time (s) ↓ | Nodes | Wall kN/s ↑ | Peak RSS (MiB) ↓ | Time speedup ↑ | NPS gain ↑ | NPS efficiency ↑ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Zander | 1 | 0.362 | 370,659 | 1,023 | 251.2 | 1.00× | 1.00× | 100% |
| Stockfish | 1 | 0.334 | 370,659 | 1,110 | 322.3 | 1.00× | 1.00× | 100% |
| Zander | 2 | 0.348 | 709,063 | 2,035 | 273.4 | 1.04× | 1.99× | 99% |
| Stockfish | 2 | 0.407 | 849,907 | 2,089 | 346.3 | 0.82× | 1.88× | 94% |
| Zander | 4 | 0.373 | 1,384,690 | 3,712 | 354.5 | 0.97× | 3.63× | 91% |
| Stockfish | 4 | 0.377 | 1,672,328 | 4,433 | 392.4 | 0.89× | 3.99× | 100% |

Time is the **sum of per-position median wall times**, measured from `go` through
`bestmove`, including UCI overhead but excluding initialization and hash clearing.
Nodes are the sum of per-position median node counts. Wall NPS = nodes / time;
it is an aggregate ratio, not the median sample NPS. Time speedup = T₁ / Tₙ;
NPS gain = NPSₙ / NPS₁; NPS efficiency = gain / threads. Baselines are per engine.

At four threads Zander processes 3.63× as many nodes per second, but searches
3.74× as many nodes and takes 3% longer than at one thread. Stockfish takes
13% longer. Zander's two-thread run finishes about 4% sooner than its one-thread
run. This short suite does **not** establish scaling on long searches;
small timings, scheduling, thermal state, and three repeats limit precision.
At one thread Zander takes 1.084× Stockfish's time for matching node counts.
Multi-thread timing ratios also reflect different amounts of search work.

Peak RSS is Linux `/proc/<pid>/status` VmHWM read after all benchmarks and before
games, separately for each process. It includes initialization, networks, hash,
workers, and other resident allocations; it is not incremental worker memory or
the sum of both engines. Both engines remain resident during the comparison.
Unavailable RSS is stored as JSON `null`, never zero.
The historical native worker budget is 4,734,656 bytes (4.52 MiB) per worker;
its 36.12 MiB for eight workers is planned payload, **not total process RSS**.

### Deeper single-thread baseline

The current binaries also ran all 27 positions at depth 16, seven repeats,
one thread, and 64 MiB hash, pinned to CPU 2 with `taskset`. Engine order
alternated within repeats; there was no explicit warmup. Initialization and
hash clearing are excluded, as in the shallow suite.

| Run | Engine | Time (s) | Nodes | Wall kN/s |
| --- | --- | ---: | ---: | ---: |
| Zander first on even repeats | Zander | 2.221 | 2,567,651 | 1,156 |
| Zander first on even repeats | Stockfish | 2.111 | 2,567,651 | 1,216 |
| Stockfish first on even repeats | Zander | 2.391 | 2,567,651 | 1,074 |
| Stockfish first on even repeats | Stockfish | 2.260 | 2,567,651 | 1,136 |

Zander takes **1.052×** the reference time in the first run and **1.058×** in
the separate confirmation with executable arguments reversed. Both runs alternate
engine order on successive repeats, indexed from zero. Absolute times increased
in the confirmation for both engines; the observed ratios are not a confidence
interval. Depth, corpus, affinity, and machine conditions matter: these ratios
are not a universal performance gap.
Some corpus entries are terminal or finish below the requested depth.

### Historical context

The earlier `worker-memory/timing-repeat.json` records:

| Saved engine | Depth | Positions | Time (s) | Nodes | Wall kN/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Zander (`planned`) | 16 | 10 | 1.688 | 1,521,462 | 901 |
| Stockfish | 16 | 10 | 1.557 | 1,521,462 | 977 |

That run used five repeats, one warmup per position, one thread pinned to CPU 2,
and 64 MiB hash. Zander took 1.08× the reference time. It uses an older Zander
binary, and corpus and measurement conditions differ: do not interpret the new
ratios as a measured improvement over that run or combine them into a single
trend. The previous depth-12 report remains in `artifacts/report/` and also uses
that older binary. Historical scalar and automatic-backend
baselines also represent different builds and must not be pooled.

## Current cycle profile

A separate profile of the same current Zander binary used the initial position,
one worker pinned to CPU 2, 64 MiB hash, and a 5,000,000-node budget (actual
5,000,190 nodes). A 1,000,000-node warmup preceded `ucinewgame`; `perf record`
attached after initialization and sampled user cycles at 499 Hz. It collected
3,781 samples with zero reported lost samples.

| Symbol | Share of sampled user cycles |
| --- | ---: |
| `FeatureTransformer.applyCombined` | 31.66% |
| `Stack.evaluate` | 10.71% |
| `zander_sparse_avx2` | 10.23% |
| `MovePicker.next` | 9.74% |
| Main search | 8.12% |

These are leaf-symbol samples: inlined work is attributed to the containing
symbol. They identify investigation targets for this position, not recoverable
speedup percentages or universal workload shares. They do not establish whether
the NNUE bottleneck is memory traffic, arithmetic, dependencies, or bookkeeping.
The profiled elapsed time is excluded from the timing tables above.

The [profile report](../artifacts/report-current/profile/report.txt),
[metadata](../artifacts/report-current/profile/metadata.json), and
[collection script](../artifacts/report-current/profile.py) retain the details.
Recollect with `python3 artifacts/report-current/profile.py` using the local perf
binary named in that script; do not run it concurrently with timing benchmarks.

## Playing strength — does it win games?

The historical `extended-comparison.json` has **2 wins, 5 draws, 1 loss** from
Zander's perspective (8 finished, 0 unfinished), at 10,000 nodes per move with
colors swapped in opening pairs. This is a game/regression smoke test, not a
strength estimate. It uses different binary hashes from the timing runs.
Ply-capped `*` results must remain unfinished and must never count as draws.

Neither equal search outputs nor higher NPS establishes Elo. A strength claim
needs a substantially larger controlled match with paired openings, specified
time controls/hardware, and uncertainty accounting for paired games. Fixed-node
games in particular do not measure the benefit of faster execution at equal time.

## Sources and reproduction

Raw artifacts are local and Git-ignored; the tables above preserve the snapshot:

- Fresh: [build metadata](../artifacts/report-current/metadata.json), [1 thread](../artifacts/report-current/threads-1.json), [2 threads](../artifacts/report-current/threads-2.json), [4 threads](../artifacts/report-current/threads-4.json), [depth 16](../artifacts/report-current/depth-16.json), [reversed order](../artifacts/report-current/depth-16-reverse.json).
- Historical: [timing](../artifacts/worker-memory/timing-repeat.json), [worker budget](../artifacts/worker-memory/budget-native.json), [search and games](../artifacts/extended-comparison.json).

Fresh binary SHA-256 identifiers:

```text
Zander:    9f5da26d5a7a9cc084ef691d1671640d93df4a199ea4281eeaf6d03bf1c066bf
Stockfish: fef4022ad38108fd34de2547d56175431bedbacc24ec2d04288143df709d4306
Network:   134a887f4c8ff7bf7284177a3b3fc6ff9cef95ba89eb8db3079a8e507f7126af
Positions: 778187a2ca732b8c1ba61554ea63c57b383752963ce4c6da19a9fe24d7ea44c6
```

Build the identified checkout and recollect (retain new hashes when changing
source, toolchain, or build configuration):

```sh
zig build -Doptimize=ReleaseFast -Dnnue-backend=auto \
  --prefix artifacts/report-current/build
for threads in 1 2 4; do
  python3 scripts/compare_engines.py \
    artifacts/report-current/build/bin/zander \
    artifacts/baseline-build/stockfish/stockfish \
    --network networks/nn-134a887f4c8f.nnue \
    --positions tests/benchmark_positions.txt \
    --depth 12 --repeats 3 --hash 64 --threads "$threads" \
    --output "artifacts/report-current/threads-$threads.json"
done

taskset -c 2 python3 scripts/compare_engines.py \
  artifacts/report-current/build/bin/zander \
  artifacts/baseline-build/stockfish/stockfish \
  --network networks/nn-134a887f4c8f.nnue \
  --positions tests/benchmark_positions.txt \
  --depth 16 --repeats 7 --hash 64 --threads 1 --require-identical \
  --output artifacts/report-current/depth-16.json
```

For the depth-16 confirmation, swap the two executable arguments and write to
`artifacts/report-current/depth-16-reverse.json`. In that JSON, `candidate` is
Stockfish and `reference` is Zander; the table above maps engines by identity.
