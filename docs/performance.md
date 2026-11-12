# Performance

[Development](development.md) · [Measurement tools](performance-tools.md)

Zander is validated against its pinned Stockfish reference with matching network
weights and search settings. Search equivalence in the tested configurations does
not establish general execution-speed parity, playing strength, or scaling across
all machines and thread counts.

## Measuring changes

Use the [benchmark and profiling tools](performance-tools.md) to compare optimized
baseline, candidate, and reference builds. Fix the workload and acceptance criteria
before measuring; verify search signatures and noise controls, and validate on
independent positions and relevant hardware before making broader claims.

Keep execution speed, search equivalence, memory usage, and playing strength as
separate results. Measurements using different networks, references, or protocols
must not be pooled.

## Local records

Keep experiment protocols, binary hashes, raw results, profiles, detailed reports,
and rejected-candidate notes under `artifacts/`, which Git ignores. Preserve failed
and inconclusive results there. Versioned documentation describes the tools and
current contracts; it should not accumulate per-run reports or investigation logs.
