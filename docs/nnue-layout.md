# NNUE activation layout

Automatic sparse builds targeting x86-64 with AVX2 keep transformer activations
in native `vpackuswb` order and reorder the existing packed i8 weights at load
time. Processing 32 neurons at once also allows writing sparsity masks directly
by byte. This removes lane rearrangements and partial mask updates without
expanding threat weights or fusing layers. Other targets retain the canonical path.

Measured on 2026-09-22: Zig 0.16.0, ReleaseFast, `-Dnnue-backend=auto`,
i7-10750H/WSL2, baseline `601fdca463d89816c92892f0217f20769cd270c3`.
The 27 benchmark positions ran at depth 16, one thread, 64 MiB hash, pinned to
CPU 2, with nine repeats, alternating engine order and no explicit warmup.
Time is the sum of per-position median UCI wall times, excluding initialization.
No compilation or tests ran concurrently.

| Run | Candidate (s) | Baseline (s) | Time change |
| --- | ---: | ---: | ---: |
| Initial | 2.179601 | 2.239520 | -2.68% |
| Executable order reversed | 2.135289 | 2.178901 | -2.00% |

Both runs matched move, score, PV and node count on 27/27 positions. The observed
2.0–2.7% time reduction is specific to this workload, not a confidence interval
or an Elo result. Scalar, native and generic x86 tests, real-network/search
reference tests, formatting and Python checks passed. Transform tests cover all
65,536 clipped operand pairs, saturation, perspective order and sparsity masks.

Binaries, timing JSON, source snapshots, disassemblies and the full report are
retained locally under `artifacts/nnue-layout/` (Git-ignored). Reproduce with:

```sh
taskset -c 2 python3 scripts/compare_engines.py \
  artifacts/nnue-layout/byte-mask/bin/zander \
  artifacts/nnue-layout/baseline/bin/zander \
  --network networks/nn-134a887f4c8f.nnue \
  --positions tests/benchmark_positions.txt \
  --depth 16 --repeats 9 --threads 1 --hash 64 --require-identical \
  --output artifacts/nnue-layout/recheck.json
```
