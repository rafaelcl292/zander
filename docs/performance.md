# Performance report

[Documentation home](../README.md) · [Benchmark procedure](development.md#compare-engines)

**Search outputs match in the measured single-thread suite. More threads increase
throughput but do not finish this shallow suite faster. Playing strength remains
unestablished.** These are measurements of the identified saved binaries, not a
benchmark of the current source checkout.

## Search equivalence — did the searches produce the same results?

| Evidence | Depth | Positions × repeats | Matching positions |
| --- | ---: | ---: | ---: |
| Fresh one-thread comparison | 12 | 27 × 3 | 27/27 |
| Historical extended comparison | 8 | 27 × 3 | 27/27 |
| Historical worker-memory comparison | 16 | 10 × 5 | 10/10 |

“Matching” means move, score, principal variation, and node count agree across
all samples and engines in that artifact. This is evidence for the tested inputs,
not proof that every internal search operation or all engine behavior is identical.
The fresh 2- and 4-thread runs each match on only 2/27 positions; parallel search
changes scheduling and work, so exact equality is not an acceptance criterion there.

## Execution speed, memory, and thread scaling

Fresh run: **2026-09-22 UTC (September 21 in São Paulo)**; Intel i7-10750H,
6 cores / 12 logical CPUs, Linux under WSL2. Same saved binaries and NNUE network
at every thread count; 27 positions, depth 12, three repeats, 64 MiB hash per
engine, NumaPolicy=none, no tablebases. No CPU affinity or explicit warmup.
Thread counts ran sequentially; engine order alternated within repeats.

| Engine | Threads | Time (s) ↓ | Nodes | Wall kN/s ↑ | Peak RSS (MiB) ↓ | Time speedup ↑ | NPS gain ↑ | NPS efficiency ↑ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Zander | 1 | 0.388 | 370,659 | 954 | 251.1 | 1.00× | 1.00× | 100% |
| Stockfish | 1 | 0.350 | 370,659 | 1,058 | 322.2 | 1.00× | 1.00× | 100% |
| Zander | 2 | 0.450 | 895,331 | 1,988 | 273.3 | 0.86× | 2.08× | 104% |
| Stockfish | 2 | 0.491 | 1,063,828 | 2,168 | 346.3 | 0.71× | 2.05× | 102% |
| Zander | 4 | 0.471 | 1,762,238 | 3,739 | 354.4 | 0.82× | 3.92× | 98% |
| Stockfish | 4 | 0.468 | 1,667,479 | 3,562 | 392.5 | 0.75× | 3.37× | 84% |

Time is the **sum of per-position median wall times**, measured from `go` through
`bestmove`, including UCI overhead but excluding initialization and hash clearing.
Nodes are the sum of per-position median node counts. Wall NPS = nodes / time;
it is an aggregate ratio, not the median sample NPS. Time speedup = T₁ / Tₙ;
NPS gain = NPSₙ / NPS₁; NPS efficiency = gain / threads. Baselines are per engine.

At four threads Zander processes 3.92× as many nodes per second, but searches
4.75× as many nodes and takes 21% longer than at one thread. Stockfish likewise
takes 34% longer. This short suite does **not** establish scaling on long searches;
small timings, scheduling, thermal state, and three repeats limit precision.
At one thread Zander takes 1.11× Stockfish's time for matching node counts.
Multi-thread timing ratios also reflect different amounts of search work.

Peak RSS is Linux `/proc/<pid>/status` VmHWM read after all benchmarks and before
games, separately for each process. It includes initialization, networks, hash,
workers, and other resident allocations; it is not incremental worker memory or
the sum of both engines. Both engines remain resident during the comparison.
Unavailable RSS is stored as JSON `null`, never zero.
The historical native worker budget is 4,734,656 bytes (4.52 MiB) per worker;
its 36.12 MiB for eight workers is planned payload, **not total process RSS**.

For a longer historical workload, `worker-memory/timing-repeat.json` records:

| Saved engine | Depth | Positions | Time (s) | Nodes | Wall kN/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Zander (`planned`) | 16 | 10 | 1.688 | 1,521,462 | 901 |
| Stockfish | 16 | 10 | 1.557 | 1,521,462 | 977 |

That run used five repeats, one warmup per position, one thread pinned to CPU 2,
and 64 MiB hash. Zander took 1.08× the reference time. The binary hashes match the
fresh scaling run, but corpus, depth, and measurement conditions differ: do not
combine these timings into a single trend. Historical scalar and automatic-backend
baselines also represent different builds and must not be pooled.

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

- Fresh: [1 thread](../artifacts/report/threads-1.json), [2 threads](../artifacts/report/threads-2.json), [4 threads](../artifacts/report/threads-4.json).
- Historical: [timing](../artifacts/worker-memory/timing-repeat.json), [worker budget](../artifacts/worker-memory/budget-native.json), [search and games](../artifacts/extended-comparison.json).

Fresh binary SHA-256 identifiers:

```text
Zander:    d3a9cacd3fb99a67202d6bd9b1f745df761aeee5725c9213231e726dcf8b62d7
Stockfish: fef4022ad38108fd34de2547d56175431bedbacc24ec2d04288143df709d4306
Network:   134a887f4c8ff7bf7284177a3b3fc6ff9cef95ba89eb8db3079a8e507f7126af
Positions: 778187a2ca732b8c1ba61554ea63c57b383752963ce4c6da19a9fe24d7ea44c6
```

Recollect with those saved executables (or substitute freshly built paths and
retain their new hashes as a separate experiment):

```sh
for threads in 1 2 4; do
  python3 scripts/compare_engines.py \
    artifacts/worker-memory/after/bin/zander \
    artifacts/baseline-build/stockfish/stockfish \
    --network networks/nn-134a887f4c8f.nnue \
    --positions tests/benchmark_positions.txt \
    --depth 12 --repeats 3 --hash 64 --threads "$threads" \
    --output "artifacts/report/threads-$threads.json"
done
```
