# MirrorMesh — Testing Patterns

**Status**: Initial guidance; expand as test surface grows.

---

## Test Categories

| Category | Lives in | Runs in CI | Purpose |
|----------|----------|------------|---------|
| Unit | `Tests/<Module>Tests/` | Yes | Logic correctness, stage I/O contracts |
| Integration | `Tests/IntegrationTests/` | Yes | Multi-stage pipelines on fixture media |
| Benchmark | `bench/` | Self-hosted runner only | Reproducible latency / power numbers |
| Snapshot | `Tests/<Module>Tests/__Snapshots__/` | Yes | Frame-level rendering regression |
| Provenance | `Tests/ProvenanceTests/` | Yes | Every model has signed provenance |
| Watermark roundtrip | `Tests/WatermarkTests/` | Yes | Verifier round-trips on every code change |

## Principles

- **Deterministic**. No timer-dependent assertions; no flaky retries-to-pass.
- **Independent**. Tests do not share global state. Each test sets up and tears down its own pipeline.
- **Fast on the unit tier**. Sub-second per test on unit; integration may take longer but stays under a minute per test.
- **Hermetic media**. Fixture clips are license-cleared, tiny (≤ 1 MB), and stored alongside the test that uses them.
- **Real data at boundaries**. Tests of capture/landmark/etc. use small real video fixtures, not synthetic noise.

## Fixtures

- Synthetic test signals where appropriate (e.g., known landmark positions on a generated face mesh render)
- Small license-cleared video clips for end-to-end paths
- No personally identifying media of real third parties in the repo

## Benchmark Discipline

- Every benchmark scenario lives in `bench/scenarios/<name>.json`
- Output is JSONL with a stable schema (see `systemPatterns.md` "Benchmarkable Everything")
- Each run records: machine model, OS, build commit, power mode (plugged/battery), thermal state at start
- Comparisons are tag-stable: numbers cited in the paper must be reproducible from a tagged commit + scenario

## What We Don't Test (yet)

- Long-running thermal characterization beyond 10 minutes — handled in a separate manual harness
- Cross-device handoff (Continuity Camera failover) — manual until M2
- Multi-user / network call ergonomics — out of scope until M4

## Anti-Patterns

- **Snapshot tests as a substitute for assertion**: snapshots catch unexpected regressions, not specifications. Pair snapshot tests with explicit assertions about what's being tested.
- **Mocking the Apple frameworks under test**: prefer fixture inputs over `AVCaptureSession` mocks. We are testing that this pipeline runs on this platform — abstracting the platform defeats the purpose.
- **Latency assertions in unit tests**: unit tests assert correctness, not performance. Performance belongs in `bench/`.

## Coverage Targets

- Unit: ≥ 80% on `MirrorMeshCore` and pipeline stages
- Integration: every shipping pipeline configuration has at least one happy-path test
- Watermark: 100% — verifier must pass on every output the app can produce
