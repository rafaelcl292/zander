# Performance tools

[Development](development.md) · [Historical measurements](performance.md)

Use these tools to evaluate execution changes with matching search behavior.
They do not estimate Elo. Python 3.14.7, Zig 0.17.0 and Linux are the supported
measurement environment. Python uses only the standard library; profiling also
requires `perf` and permission to access the requested hardware events.

## Build and validate before measuring

Build baseline and candidate with the same compiler and options. For optimized
comparisons use ReleaseFast and automatic NNUE dispatch. Use an optimized
Stockfish reference too: `scripts/build_reference.py` intentionally produces a
scalar reference, so it is inappropriate as the optimized speed baseline.

Every invocation requires a **new output directory** under `artifacts/`; existing
results are never overwritten. These tools use a shared advisory lock to prevent
concurrent measurements in this checkout. Other applications and builds can still
interfere: keep the host idle and finish compilation before measuring. On SMT
machines, choose engine and harness CPUs on different physical cores and leave
the engine's sibling idle. WSL host activity is outside this lock's control.

## Controlled benchmark

```sh
python3 scripts/bench.py \
  --baseline artifacts/baseline/bin/zander \
  --candidate artifacts/candidate/bin/zander \
  --reference artifacts/stockfish-optimized \
  --network networks/nn-252f33942263.nnue \
  --cpu 2 --harness-cpu 0 \
  --output artifacts/experiment-001
```

The default experiment uses one worker, 64 MiB hash, NUMA policy none, no
tablebases, depth 20, two repeats and twelve fresh-process sessions. Every
session starts two copies of **each** binary: baseline, candidate and reference.
All six processes remain resident, so budget memory for six engines. Every
process warms up on every position at depth 12. Before every measured search,
`ucinewgame` clears histories/hash and a readiness barrier completes preparation.
Timing includes UCI round-trip overhead and excludes loading, warmups and clearing.

The seeded schedule randomizes position and process creation order. Every label
occupies every execution rank once per six-session block, for each position and
repeat. Session counts must be multiples of six. A six-session run is a smoke
test only; it cannot produce an improvement/regression verdict. Do not extend a
run opportunistically until a desired result appears; choose a new confirmation
protocol and output directory before collecting more samples.

The corpus in `tests/performance_positions.json` separates seven nonterminal
opening, middlegame, tactical and endgame workloads from the larger correctness
corpus. It is a starting workload set, not a representative playing-strength
suite. Change corpus or depth **before** an experiment, and retain the protocol.
Each entry has a unique `id`, `category`, six-field `fen`, and optional `chess960`.

### What the verdict means

All warmup and measured search signatures must match across copies, sessions and
engines: move, score, PV, node count and completed depth. Mismatch or incomplete
telemetry stops the run and preserves partial evidence; there is no speed verdict.
Terminal positions are rejected from the timed performance corpus.

For each session, the primary statistic sums each position's mean search time,
then averages the two copies of each engine. Candidate versus baseline is the
ratio of mean session totals minus one; negative percentages mean less time.
Longer workloads contribute more to this aggregate. Per-position times remain
available; no outliers or short positions are silently discarded.

The 95% percentile bootstrap resamples **whole paired sessions**, preserving
within-session correlations between positions, repeats, and process copies. It
uses 10,000 seeded draws. The interval describes variation in this experiment;
it cannot account for every source of host interference or selection bias.

An improvement/regression verdict requires all of:

- At least twelve complete sessions with equivalent searches.
- Each A/A control's entire interval inside ±2% (`--control-tolerance-pct`).
- Every workload's mean time for every label at least 20 ms (`--min-search-ms`).
- Candidate/baseline interval entirely below −0.5% or above +0.5%
  (`--min-effect-pct`). Otherwise the verdict is `inconclusive`.

Identical baseline/candidate executable hashes also force an inconclusive A/A
result. The report lists every reason a verdict was withheld.

Thresholds and seed are recorded before measurements. Candidate/reference results
are contextual; the acceptance verdict is specifically candidate versus baseline.
A small A/A estimate alone does not prove that machine noise is absent.

Outputs:

- `protocol.json`: predeclared settings, corpus, hashes and environment.
- `results.json`: every warmup/sample, execution rank, session RSS and run status.
- `summary.json`: paired intervals, controls, session totals and per-position times.
- `report.txt`: concise verdict and its supporting estimates.

## Profiling, separately from timing

```sh
python3 scripts/profile_engine.py \
  --engine artifacts/candidate/bin/zander \
  --network networks/nn-252f33942263.nnue \
  --position kiwipete --nodes 5000000 \
  --cpu 2 --harness-cpu 0 \
  --output artifacts/profile-001
```

Omit `--position` to profile every corpus position, or repeat it to select a
subset. Use `--perf /path/to/perf` for a locally installed WSL-compatible binary.
No elevated privileges or machine settings are changed automatically.
For cross-engine comparisons, use `--depth 22` instead of `--nodes` and verify
search signatures across the two reports. Node budgets can stop at different
polling boundaries even when fixed-depth searches match; equal budgets do not
guarantee identical search work.

Each position has two independent passes: grouped user-space cycles,
instructions, branches and branch misses; then cycle sampling at 499 Hz.
Initialization and warmup finish before attachment. `perf` starts disabled and
acknowledges enable/disable commands around the search. Preparation and hash
clearing occur outside those boundaries. The wrapper waits for readiness rather
than sleeping for an assumed attachment delay. Search signatures must match
between the two passes. Instrumented elapsed times are **not** benchmark evidence.

`profile.json` retains counters and running fractions. Multiplexed events are
flagged; unsupported/unavailable counters fail explicitly rather than becoming
zeros. Raw CSV, perf logs, `.data` and symbol reports remain available. Symbol
shares are diagnostic, not recoverable speedup percentages. Add `--call-graph`
for DWARF call stacks at additional profiling cost. For small workloads, increase
the node budget until enough samples exist to interpret the symbol report.

## Isolated revision experiments

```sh
python3 scripts/experiment.py \
  --baseline main --candidate my-optimization \
  --reference artifacts/stockfish-optimized \
  --network networks/nn-252f33942263.nnue \
  --cpu 2 --harness-cpu 0 \
  --output artifacts/revision-experiment-001
```

Refs resolve to immutable commits before work begins. Uncommitted changes are
not included. The manager creates detached worktrees and initializes each
revision's pinned Stockfish submodule. It links the supplied weights at that
revision's default runtime network path for the startup integration checks.
It runs formatting, Debug unit tests,
ReleaseFast/auto unit and differential tests, NNUE/search/engine/UCI integration,
Python type checking and Python regression tests for **both** revisions. A failed
check prevents benchmarking. Syzygy regression tables are not required by this
workflow; run that suite separately for tablebase changes.

Both optimized binaries are retained outside their temporary source trees.
The manager then runs the controlled benchmark. Add `--profile` to profile
baseline, candidate and reference **after** timing completes; `--perf` selects
the profiler binary. There are no overlapping builds and measurements within one
experiment. Do not launch another build or experiment concurrently.

`experiment.json` records resolved commits, tool versions, build/reference hashes,
commands, return codes, logs and cleanup errors. `change.patch` contains the
exact committed diff. The aggregate `report.txt` links the result locations.
Worktrees created by the invocation are removed on success or failure; use
`--keep-worktrees` to retain them for debugging. Existing worktrees are untouched.
Killed processes cannot guarantee cleanup; recorded paths identify any leftovers.

## Targeted kernel experiments

Build the same harness at baseline and candidate revisions:

```sh
zig build microbench-build -Doptimize=ReleaseFast -Dnnue-backend=auto \
  --prefix artifacts/candidate
python3 scripts/microbench.py \
  --engine artifacts/candidate/bin/zander \
  --baseline artifacts/baseline/bin/zander-microbench \
  --candidate artifacts/candidate/bin/zander-microbench \
  --network networks/nn-252f33942263.nnue \
  --cpu 2 --output artifacts/kernels-001
```

`microbench-build` is opt-in and does not change the production engine. The Python
runner captures legal PV traces from the specified UCI engine and feeds the exact
same FENs and moves to both native executables. It alternates engine order over an
even number of repeats; each process warms up before native timing. Setup,
allocation and network loading are excluded. Modes are `nnue`, `movegen`,
`move_ordering`, and `tt`; repeat `--mode` to select a subset. Checksums and replay
position counts must agree. Raw traces, executable/network hashes and samples
are retained in `microbench.json`.

These measure a **warm PV-path workload**, including make/unmake, loop and
checksum overhead. NNUE includes incremental updates and inference. Move ordering
uses initialized histories, not histories captured from a mature search. TT
replays a small warm key set; it does not model a full search's miss rate or cache
footprint. They help investigate a profiler-identified hotspot, but cannot justify
an end-to-end speed claim. Confirm retained changes with `bench.py`.

## Tests

```sh
zig build test
zig build python-test python-check
zig fmt --check build.zig src tests
```

The Python tests cover balanced schedules, paired session drift, verdict/noise
thresholds, short workloads, invalid evidence, fresh process sessions, cleanup,
measurement locking, profiler acknowledgements and counter availability. Real
engine smoke runs should exercise all four workflows before changing their
measurement protocol.
