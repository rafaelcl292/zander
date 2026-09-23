# Performance report

[Documentation home](../README.md) · [Benchmark procedure](development.md#compare-engines)

**Search outputs match in the measured single-thread suites. Thread throughput
increases, but this shallow suite does not establish long-search scaling.
Playing strength remains unestablished.** The historical measurements below use Zander
built from clean commit `ddaa58c88e5c5e4f22cbe3889a34746a844cc35f` with Zig
0.16.0, ReleaseFast, and the automatic NNUE backend. The reference is the retained
GCC/BMI2/LTO Stockfish binary for pinned commit
`17a6c8f1eb0da45c2ca405321919519bf4e211ba`. Neither engine uses PGO.

The [three-version comparison](#controlled-comparison-of-three-zander-versions)
tests the historical, pre-huge-page and huge-page versions together. The
[latest NNUE tile comparison](#contiguous-nnue-accumulator-tiles--2026-09-22)
measures the retained optimization against that same Stockfish binary.

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

## Primary NNUE allocation — 2026-09-22

A separate experiment against `9b1b51a347c8e338682bf793d474008d2bdea1e7`
changed the UCI engine's primary network allocation to the dedicated, aligned
`memory.Region` already used for NUMA replicas. It requests transparent huge
pages before loading the weights and retains normal-page/platform fallback.
Previously the primary network used the general allocator, including in the
usual single-thread configuration without NUMA replicas.

Same i7-10750H/WSL2 host, Zig 0.16.0 ReleaseFast, automatic NNUE backend,
one thread, 16 MiB hash, NumaPolicy=none, depth 18. Engines were pinned to CPU 2
and the harness to CPU 0. Each run had one excluded warmup round; position and
engine order were randomized within rounds. A second process running the
identical baseline binary served as an A/A control. Times below sum all measured
searches, excluding loading and hash clearing.

| Run | Positions × repeats | Baseline A (s) | Baseline B (s) | Candidate (s) | Less time vs mean baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial comparison | 7 × 6 | 17.526 | 17.672 | 17.164 | 2.47% |
| Full-corpus confirmation | 27 × 4 | 15.872 | 15.829 | 15.476 | 2.36% |

Move, score, PV and node count matched in every measured search. Retired
instructions were effectively identical. The full-corpus A/A difference was
0.27%; this remains a local timing result, not a guarantee for other CPUs,
page configurations, thread counts, or playing strength.

Linux `/proc/<pid>/smaps` confirmed that the candidate network occupied
112 MiB of transparent huge pages; the baseline network had none. Mapping
rounding cost approximately 2 MiB of additional resident memory on this host.
NUMA replicas already requested huge pages, so this result does not establish
an additional gain when searching those replicas.

Unit tests in Debug and ReleaseFast, ReleaseFast differential tests, engine
lifecycle tests in both modes, UCI integration, formatting and Python checks
passed. A failure-injection regression also verifies that an unsuccessful
network replacement leaves the previous network usable for search.

Local artifacts: [initial comparison](../artifacts/nnue-incremental/controlled-huge-network-6.json),
[full-corpus confirmation](../artifacts/nnue-incremental/validation-huge-network-4-d18-all.json),
[actual page mappings](../artifacts/nnue-incremental/network-pages.json), and
[investigation notes](../artifacts/nnue-incremental/REPORT.md).

## Controlled comparison of three Zander versions

Measured on 2026-09-22 with all three Zander commits rebuilt using the same
Zig 0.16.0 ReleaseFast/auto configuration. The pinned Stockfish executable is
the same GCC/BMI2/LTO reference identified above. This comparison replaces
estimates obtained by combining results from different workloads.

All engines searched the same 27 positions at depth 20, one thread, 64 MiB hash,
NumaPolicy=none. Two sessions used fresh processes, each with one discarded
full-corpus warmup and five measured rounds. Engine order was randomized and
balanced: each engine occupied every execution rank once per position/session.
Engines ran on CPU 2 and the harness on CPU 0, with no concurrent builds. A
second process using the identical pre-huge-page binary provided an A/A control.
The ten measured rounds were fixed before timing began.

| Zander version | Commit | More search time than Stockfish | Within-run 95% bootstrap interval |
| --- | --- | ---: | ---: |
| Historical report version | `ddaa58c` | 7.20% | 5.31–8.89% |
| Immediately before huge pages | `9b1b51a` | 3.92% | 2.74–5.06% |
| Including huge pages | `d2ff957` | 2.30% | 1.15–3.42% |

Ratios use total search wall time, excluding initialization, warmup and hash
clearing. The immediate-before result averages both identical baseline
processes. Intervals resample whole paired rounds 20,000 times, retaining all
positions and engines together; they describe this fixed corpus and execution,
not other machines or workloads. WSL2 host scheduling and frequency remain
uncontrolled, and rounds within a session may be correlated.

The isolated huge-page change reduced time by **1.55%** (within-run interval
1.11–2.06%), with improvements of 1.29% and 1.82% in the two sessions. It was
also 1.08% faster than the faster of the two baseline processes overall. The
A/A difference was 0.97% (interval −0.09–2.05%). This supports a modest local
gain, with more uncertainty than the point estimate alone suggests. The earlier
depth-18 estimate of about 2.4% should not be treated as universal.

All **1,350 measured searches**, as well as warmups, matched move, score, PV and
nodes. Every engine searched 144,861,910 measured nodes. The current Zander used
184.642 seconds versus Stockfish's 180.490 seconds; peak RSS was approximately
253.2 MiB versus 322.5–322.6 MiB. The current version reduced time by 4.57%
relative to the historical Zander in this same experiment. No Elo or updated
multi-thread scaling claim follows from these results.

Local reproducible evidence: [report](../artifacts/reliable-comparison/REPORT.md),
[raw samples and hashes](../artifacts/reliable-comparison/results.json),
[summary and intervals](../artifacts/reliable-comparison/summary.json),
[predeclared protocol](../artifacts/reliable-comparison/protocol.json),
[host and toolchain](../artifacts/reliable-comparison/environment.json),
[runner](../artifacts/reliable-comparison/run.py) and
[analysis](../artifacts/reliable-comparison/analyze.py).

## Cache, layout and compiler experiments — 2026-09-22

Seven candidates were explored after `d2ff957`: history padding, huge-page history
allocation, outlined MovePicker scoring, packed move returns, a split MovePicker
fast path, earlier hot metadata, and frame-pointer omission. None was retained.

Frame-pointer omission looked best in the depth-18 pilot (1.94% less time), but
an independent depth-20 confirmation reduced that estimate to **0.25% less time**,
with a within-run 95% paired-round bootstrap interval from **1.35% less to 0.89%
more**. Session one was 0.42% slower and session two 0.92% faster. The identical
baseline control differed by 0.71%. About 0.94% fewer retired instructions did
not translate into a reliable elapsed-time improvement.

The confirmation used 27 positions, two fresh-process sessions, four measured
rounds per session after warmup, one thread and 64 MiB hash, with balanced engine
order and CPU affinity. All **864 measured searches** matched move, score, PV and
nodes. The unchanged baseline took 2.55% more time than Stockfish; the rejected
candidate took 2.29% more. These are local execution-speed results, not evidence
of parity or playing strength. The fixed-corpus and WSL2 limitations above apply.

The candidate passed Debug unit tests, ReleaseFast unit/differential/network/
search/engine/UCI tests, formatting and Python checks before being reverted.
Local evidence: [investigation report](../artifacts/cache-investigation/REPORT.md),
[confirmation protocol](../artifacts/cache-investigation/confirmation/protocol.json),
[raw measurements](../artifacts/cache-investigation/confirmation/results.json),
[summary](../artifacts/cache-investigation/confirmation/summary.json), and
[rejected patch](../artifacts/cache-investigation/confirmation/candidate.patch).

## Contiguous NNUE accumulator tiles — 2026-09-22

The retained candidate changes accumulator tile loads/stores to contiguous vector
array views and rebases each weight row before indexing its vectors. Integer
arithmetic, feature lists and search behavior are unchanged. The array views
retain the existing i16 alignment requirement. This extends the earlier
weight-row-only experiment: the generated accumulator stores now also avoid
seven separate offset calculations, reducing general-register pressure.

A separate confirmation compared `d2ff957`, an identical control, the candidate,
and the pinned Stockfish executable. It used 27 positions at depth 20, one
thread, 64 MiB hash, two fresh-process sessions, one warmup and four measured
rounds per session. Execution ranks were balanced per position/session; engines
ran on CPU 2 and the harness on CPU 0, with no concurrent builds.

| Comparison | Extra search time | Within-run 95% paired-round bootstrap interval |
| --- | ---: | ---: |
| Candidate versus mean baseline | **−1.77%** | −2.67% to −0.91% |
| Identical baseline control | +0.46% | −1.34% to +2.10% |
| Baseline versus Stockfish | +2.60% | +1.83% to +3.34% |
| Candidate versus Stockfish | **+0.79%** | −0.27% to +1.87% |

The candidate improved by 0.84% and 2.69% in the two sessions, and by 1.55%
relative to the faster baseline process overall. Retired instructions fell
2.86%. All **864 measured searches**, plus warmups, matched move, score, PV and
nodes; each engine searched 115,889,528 measured nodes. Candidate search time
was 145.942 seconds versus Stockfish's 144.802 seconds. Peak RSS was about
253.2 MiB versus 322.5 MiB.

The more optimistic depth-18 pilot showed 3.55% less time; use the independent
confirmation above as the final estimate. Larger accumulator tiles and fusion
of activation generation with the first sparse layer were rejected. The fused
version passed correctness checks but took 8.49% more search time in its pilot.

Intervals resample whole paired rounds 20,000 times. These results are specific
to this corpus, i7-10750H and WSL2; session rounds can be correlated and physical
frequency/scheduling are uncontrolled. The interval versus Stockfish crossing
zero does not prove performance equivalence. No new multi-thread or playing-
strength claim follows. Debug and ReleaseFast tests, differential/network/search/
engine/UCI checks, formatting and Python checks passed. ReleaseFast unit and
real-network reference tests also passed for `-Dcpu=baseline`.

Local evidence: [investigation report](../artifacts/nnue-tiles/REPORT.md),
[raw samples and hashes](../artifacts/nnue-tiles/confirmation/results.json),
[summary](../artifacts/nnue-tiles/confirmation/summary.json),
[protocol](../artifacts/nnue-tiles/confirmation/protocol.json),
[runner](../artifacts/nnue-tiles/confirmation/run.py),
[analysis](../artifacts/nnue-tiles/confirmation/analyze.py), and
[patch](../artifacts/nnue-tiles/final.patch).

## Follow-up on block access and initialization — 2026-09-22

Two candidates were tested against `1b37302`: contiguous tile views in the NNUE
refresh/hybrid paths, and resetting only the metadata of `Dirties`. The latter
removed two 432-byte constant-object copies in the normal move path: one from
NNUE stack push and another from position update. Threat storage outside the
logical list length is unspecified; appended entries are written before use.

The pilots favored both candidates, but an independent depth-20 confirmation
remained inconclusive. It used 27 positions, one thread, 64 MiB hash, two fresh-
process sessions, one warmup and four measured rounds per session. Two identical
baseline processes controlled for timing variation; execution ranks were balanced
and no builds ran concurrently.

| Candidate | Less search time than mean baseline | Within-run 95% interval for time change | Retired-instruction change |
| --- | ---: | ---: | ---: |
| Metadata-only reset | 0.83% | -2.42% to +0.69% | -1.79% |
| Contiguous refresh/hybrid tiles | 0.70% | -2.30% to +0.79% | -0.17% |

Negative interval endpoints mean faster execution. Metadata reset improved by
1.14% and 0.52% in the two sessions; refresh/hybrid by 0.70% and 0.71%. The
identical baseline control differed by 0.57%. Both intervals still include a
small regression, so neither candidate was retained at this stage. This does not establish
that they have no benefit; it does not establish a reliable speed gain either.

All **864 measured searches**, plus warmups, matched move, score, PV and nodes;
each engine searched 115,889,528 measured nodes. Metadata reset passed Debug
unit tests and ReleaseFast unit/differential/network/search/engine/UCI tests,
formatting and Python checks. The refresh/hybrid candidate passed the real-
network reference test. Both candidates were initially reverted; the metadata
reset was subsequently accepted as described below.

The intervals resample paired whole rounds 20,000 times and apply only to this
fixed corpus and i7-10750H/WSL2 execution. Session rounds can be correlated;
physical CPU frequency and scheduling remain uncontrolled. Stockfish was not
part of this run, so the ratios must not be combined with earlier experiments
to claim an updated Stockfish gap.

Local evidence: [report](../artifacts/contiguous-followup/REPORT.md),
[raw measurements](../artifacts/contiguous-followup/confirmation/results.json),
[summary](../artifacts/contiguous-followup/confirmation/summary.json),
[protocol](../artifacts/contiguous-followup/confirmation/protocol.json),
[metadata reset patch](../artifacts/contiguous-followup/dirty-reset.patch), and
[refresh/hybrid patch](../artifacts/contiguous-followup/refresh.patch).

## Metadata reset: precision follow-up — 2026-09-22

A more controlled test revisited only the metadata-reset candidate against
`1b37302`. Ten fresh-process sessions used two copies of each binary, eight
FEN-only positions from the pinned Stockfish benchmark and one million requested
nodes per search. ABBA/BAAB blocks were balanced per position and session, with
randomized position and process order. Engines ran on guest CPU 2, harness on
CPU 0, with no concurrent builds. The primary metric and decision rule were
fixed before timing; all samples were retained.

| Metric, candidate versus baseline | Change | Within-run 95% session-bootstrap interval |
| --- | ---: | ---: |
| Search wall time (primary) | -0.74% | -1.60% to +0.24% |
| Scheduled task CPU time | -0.74% | -1.60% to +0.24% |
| CPU cycles (secondary) | -0.88% | -1.30% to -0.45% |
| Retired instructions | -1.77% | Essentially invariant across sessions |

The candidate improved wall time in 7 of 10 sessions. The identical baseline
copies differed by +0.07% (interval -0.87% to +0.98%); the identical candidate
copies differed by -0.71% (interval -1.93% to +0.57%). All **320 measured searches**
and 40 warmups matched move, score, PV, nodes and depth. The measured total was
320,131,200 nodes; slight node-limit overshoots were identical across binaries.

The narrower wall-time interval is still **inconclusive** under the predeclared
rule. Lower measured cycle cost strengthens the evidence of CPU efficiency,
but this secondary result does not replace the wall-time criterion. The corpus
and bootstrap unit differ from the preceding fixed-depth test, so the results
should not be naively pooled.

The metadata-only reset is retained because it removes unnecessary copies,
explicitly resets all logical state, and preserves the validated behavior. The
instruction and cycle reductions support the implementation choice; the measured
0.74% wall-time reduction is not claimed as a proven speedup. The separate
refresh/hybrid tile experiment remains excluded. This acceptance does not change
the statistical test's inconclusive result.

Intervals resample ten complete sessions 50,000 times. WSL2 host scheduling and
physical frequency remain uncontrolled; cpufreq is unavailable. Kernel-inclusive
perf counters were denied, and filtered software context-switch counts were
omitted after an instrumentation check. That interrupted diagnostic and the
zero-sample denied attempt are archived separately and excluded from inference.
Available counters ran without multiplexing. Guest task-clock and CPU activity
do not establish host physical-core isolation or identify all interference.

Local evidence: [report](../artifacts/dirty-precision/REPORT.md),
[protocol](../artifacts/dirty-precision/protocol.json),
[raw samples](../artifacts/dirty-precision/results.json),
[summary](../artifacts/dirty-precision/summary.json),
[runner](../artifacts/dirty-precision/run.py), and
[analysis](../artifacts/dirty-precision/analyze.py).

## ARM64 sparse NNUE kernels — 2026-09-22

The ARM64 auto backend now uses packed four-input weights, skips zero activation
blocks in the first affine layer, and computes all three layers with specialized
vector kernels. Targets with `dotprod` use signed byte dot-product instructions;
baseline ARM64 retains a widened vector fallback. Activations are limited to
0..127, and signed weights, wrapping sums, network serialization and search
behavior are preserved. ARM CPU feature selection is compile-time; see
[ARM build options](usage.md#build-the-engine).

A confirmation on the shared Oracle Neoverse-N1 VM compared `65a7508`, two copies
of the candidate, and pinned Stockfish. Both Zander binaries targeted
`aarch64-linux-musl` and `neoverse_n1` with Zig 0.16.0, ReleaseFast and auto NNUE.
Stockfish used Zig's Clang C++ driver, musl, NEON/dotprod, O3 and full LTO without
PGO. All builds were local. The harness used portable Python 3.14.7 on the server.

| Comparison | Search-time change | Within-run 95% session-bootstrap interval |
| --- | ---: | ---: |
| New versus previous Zander | **−52.20%** | −52.31% to −52.09% |
| New Zander versus Stockfish | **+14.42%** | +14.02% to +14.80% |
| Identical candidate control | +0.20% | −0.04% to +0.52% |

The previous Zander took 191.869 seconds, the candidate averaged 91.712 seconds
across its two copies, and Stockfish took 80.157 seconds for the same 31,863,660
nodes per process. Thus the candidate processed the same work about **2.09x** as
fast as the previous Zander. In this same run, the previous Zander took 139.37%
more time than Stockfish. Mean peak RSS was 250.9 MiB before, 252.9 MiB after,
and 318.9 MiB for Stockfish.

Twelve fresh-process sessions used eight positions at depth 18, one thread,
64 MiB hash and NUMA policy none. Engine threads ran on guest CPU 1 and the
harness on CPU 0. Latin-square execution ranks were balanced per position over
each four-session group, with randomized base orders, positions and process
creation. All **384 measured searches** and 48 warmups matched move, score, PV,
nodes and depth. Every sample was retained. Intervals resample twelve complete
sessions 50,000 times. Improvement held in every session; the identical-copy
control was compatible with zero.

Both ARM variants passed ReleaseFast unit tests under QEMU, including sparse
and small-layer comparisons against scalar arithmetic. Both also matched the
reference on eight depth-18 positions on real ARM. The dot-product candidate
matched Stockfish on 27 additional depth-12 positions. Native Debug unit tests,
ReleaseFast unit/differential/network/search/engine/UCI tests, formatting and
Python checks passed. The generated x86 `.text` section was byte-identical to
the previous binary.

The portable ARM build also improved in the excluded pilot (16.153 to 10.139
seconds), but it did not receive the replicated confirmation above. The formal
speed estimate applies to the Neoverse-N1 dot-product build. It does not establish
performance on other ARM CPUs, multi-thread performance, playing strength or
parity with Stockfish. Physical-host interference in the shared VM remains
uncontrolled, and the Stockfish build is not claimed to be the fastest possible.

Production services stayed active with unchanged PIDs and zero restarts. After
retrieving and verifying the results, the benchmark's temporary files, portable
Python, binaries and processes were removed. Production executable/network
hashes and application health matched the initial snapshot; no deployment or
system configuration change was made.

Local evidence: [report](../artifacts/arm-improvements/REPORT.md),
[protocol](../artifacts/arm-improvements/protocol.json),
[raw samples](../artifacts/arm-improvements/results.json),
[summary](../artifacts/arm-improvements/summary.json),
[runner](../artifacts/arm-improvements/run.py),
[analysis](../artifacts/arm-improvements/analyze.py), and
[cleanup confirmation](../artifacts/arm-improvements/cleanup.json).

## ARM64 accumulator tiles and activation narrowing — 2026-09-22

The retained follow-up uses 16-vector accumulator tiles on ARM64 and saturates
signed accumulator lanes directly to bytes with `SQXTUN` before multiplying
activation pairs. Incremental, refresh and hybrid updates traverse feature indices
half as often. The other architectures retain their eight-vector tiles and
portable activation expression. The arithmetic and search remain unchanged;
these changes also support baseline ARM64 without requiring dot product.

A user-cycle profile placed 41.39% of Zander's samples in `applyCombined`, 14.75%
in accumulator evaluation, 9.61% in affine propagation and 6.56% in activation
transformation. Inlined work is attributed to containing symbols. Profiling used
`perf` with administrative privileges without changing system settings, and was
separate from timing. No samples were lost.

An initial pilot favored both larger tiles and three independent sparse
accumulator chains. A separate combination pilot favored tiles plus activation
narrowing; adding the triple-chain kernel made that combination about 1.82%
slower. The triple-chain experiment was rejected. Neither pilot is used as the
final performance estimate.

| Confirmation comparison | Search-time change | Within-run 95% session-bootstrap interval |
| --- | ---: | ---: |
| Candidate versus `8332755` | **−3.77%** | −4.11% to −3.40% |
| Candidate versus Stockfish | **+9.60%** | +9.41% to +9.81% |
| Identical candidate control | +0.07% | −0.16% to +0.33% |

For 31,863,660 nodes per process, the previous Zander took 92.067 seconds,
the candidate averaged 88.596 seconds across its two copies, and Stockfish took
80.838 seconds. In this same run, the previous Zander took 13.89% more time than
Stockfish. Improvement held in all twelve sessions. Mean peak RSS remained
about 252.9 MiB for Zander versus 318.9 MiB for Stockfish.

The independent confirmation used twelve fresh-process sessions, eight positions
at depth 18, one thread, 64 MiB hash, NUMA policy none and the same network.
Latin-square execution ranks were balanced per position over each four-session
group. Engines ran on guest CPU 1 and the Python 3.14.7 harness on CPU 0. All
**384 measured searches** and 48 warmups matched move, score, PV, nodes and depth.
All samples were retained; intervals use 50,000 resamples of complete sessions.
Build settings and shared Neoverse-N1 VM limitations are as in the preceding
ARM comparison. No profiler ran during timing. These results do not establish
playing strength, multi-thread performance or gains on other ARM processors.

ARM unit tests passed under QEMU for Neoverse-N1 and baseline targets, including
exhaustive clipped-product and saturation-boundary checks against scalar results.
Native Debug unit tests, ReleaseFast unit/differential/network/search/engine/UCI
checks, formatting and Python checks passed. The final candidate matched
Stockfish on 27 additional depth-12 positions on real ARM. The generated x86
`.text` section remained byte-identical to the parent binary.

The server was cleaned after verified retrieval of the results: temporary
binaries, Python, profiles, benchmark files and processes/cgroups were removed.
Production services retained their PIDs and zero restarts; executable/network
hashes and application health matched the initial snapshot. No deployment or
system configuration change was made.

Local evidence: [report](../artifacts/arm-tuning/REPORT.md),
[profile](../artifacts/arm-tuning/baseline-profile.txt),
[protocol](../artifacts/arm-tuning/protocol.json),
[raw results](../artifacts/arm-tuning/results.json),
[summary](../artifacts/arm-tuning/summary.json),
[runner](../artifacts/arm-tuning/run.py),
[analysis](../artifacts/arm-tuning/analyze.py), and
[cleanup confirmation](../artifacts/arm-tuning/cleanup.json).

## Precomputed NNUE threat geometry — 2026-09-23

Threat-feature indexing now folds each square's offset into the geometry lookup
at compile time. Non-pawn geometry is shared between colors, while the two pawn
attack directions remain separate. The geometry table remains 64 KiB, the
separate 4 KiB offsets table disappears, and each index uses two table lookups
instead of three. Feature indices and network serialization remain unchanged;
the implementation uses no architecture-specific instructions.

An independent confirmation on the shared Oracle Neoverse-N1 VM compared
`08e80e2` with the change, using two identical copies of each executable. Both
were built locally with Zig 0.16.0, ReleaseFast, auto NNUE, aarch64-linux-musl
and neoverse_n1. The harness used portable Python 3.14.7.

| Comparison | Search-time change | Within-run 95% session-bootstrap interval |
| --- | ---: | ---: |
| Candidate versus baseline | **−1.20%** | −1.29% to −1.12% |
| Identical baseline control | −0.14% | −0.40% to +0.09% |
| Identical candidate control | +0.11% | −0.16% to +0.34% |

The candidate improved in all sixteen fresh-process sessions. Mean total search
time per copy fell from 776.780 to 767.454 seconds for identical work. Eight
positions used two million requested nodes per measured search, one worker,
64 MiB hash and NUMA policy none. Each process warmed up with 200,000 nodes.
Engine threads ran on guest CPU 1 and the harness on CPU 0. Cyclic Latin ranks
balanced execution order over each four-session group; process creation and
position order were randomized. All 512 measured searches and 64 warmups matched
move, score, PV, nodes and depth. All samples were retained, and intervals use
50,000 resamples of complete sessions. Both identical-copy controls include zero,
meeting the predeclared acceptance criterion alongside the improvement interval.
A separate 27-position depth-12 comparison also matched; its timings are excluded.

Native Debug and ReleaseFast unit tests, exhaustive C++ feature-index comparison,
and network/search/engine/UCI checks passed for the candidate. ARM Neoverse-N1
unit tests passed under QEMU, and real ARM search equivalence is covered above.
The earlier independent Intel i7-10750H/WSL2 confirmation averaged 0.82% less
search time, but its interval crossed zero and an identical-copy control failed.
That x86 result remains inconclusive; it is not pooled with the ARM measurement.

The gain is established for this single-worker ARM configuration. Shared physical
host interference remains uncontrolled, and the fixed corpus does not establish
performance on every workload, other CPUs, multiple workers or playing strength.
Temporary server files, Python, binaries and the benchmark cgroup were removed
after verified retrieval. CheSSH, Cinema, rqbit and nginx retained their PIDs
with zero restarts; deployed binary/network hashes and health checks matched the
initial snapshot. The deployed engine was not changed.

Local evidence: [ARM report](../artifacts/geometry-arm/REPORT.md),
[protocol](../artifacts/geometry-arm/protocol.json),
[raw results](../artifacts/geometry-arm/results.json),
[summary](../artifacts/geometry-arm/summary.json),
[runner](../artifacts/geometry-arm/run.py),
[analysis](../artifacts/geometry-arm/analyze.py),
[cleanup confirmation](../artifacts/geometry-arm/cleanup.json), and
[x86 investigation](../artifacts/move-processing/REPORT.md).
