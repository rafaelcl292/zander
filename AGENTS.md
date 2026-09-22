# Project basics

- Zander is a native Zig port of Stockfish and a UCI chess engine.
- Use Zig 0.16.0 and Python 3.14.7 (see `.python-version`).
- Engine code lives in `src/`, tests in `tests/`, Python helpers in `scripts/`,
  and guides in `docs/`. Start with `docs/development.md` for test prerequisites.
- `vendor/stockfish` is the pinned reference submodule; production code does not
  link against its C++. Generated benchmarks and binaries belong in `artifacts/`.
- Build: `zig build -Doptimize=ReleaseFast -Dnnue-backend=auto`.
- Run checks relevant to changes: `zig build test`,
  `zig fmt --check build.zig src tests`, and `zig build python-check`.
- Follow existing commit subjects: `docs: ...`, `feat: ...`, `perf: ...`,
  or scoped fixes such as `fix(build): ...`. Keep descriptions concise.
- Add a commit body when useful to explain motivation, non-obvious decisions,
  or validation beyond what the subject conveys.
- Keep search equivalence, execution speed, and playing-strength claims separate.
