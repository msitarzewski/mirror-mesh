# M10 — End-to-End Demo Integration + Bench Harness

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M3, M4, M5, M6, M7, M8, M9
**Blocks**: (release)

## Objective

Wire all the stages, produce a working SwiftUI demo and a headless benchmark CLI, and document the quickstart.

## Deliverables

- `Sources/MirrorMeshCore/Pipeline.swift` — top-level orchestrator wiring `Capture → Vision → Solver → Render → Watermark → Output`
- `Sources/mirrormesh-bench/main.swift` — CLI executable that runs a scenario file and emits JSONL
- `bench/scenarios/demo.json` — default scenario for the demo
- `bench/scenarios/capture_landmark.json` — capture-only latency scenario
- `bench/scripts/summarize.py` — reads JSONL, prints P50/P95/P99 per stage
- `README.md` (repo root) — quickstart for the demo
- `docs/demo.md` — what the demo shows, how to interpret it
- Smoke test: `swift test --filter EndToEndSmokeTest`

## Verification

1. `swift build` clean
2. `swift test` green
3. `swift run mirrormesh-bench --scenario bench/scenarios/demo.json` writes a JSONL file
4. Opening MirrorMesh.app (Xcode-built) launches, shows consent, runs pipeline, displays watermarked output
5. `bench/scripts/verify-output.swift` against a recorded session manifest returns valid
6. README quickstart works on a fresh clone

## Bench JSONL schema (frozen at v0.1.0)

Each line is one of:

```jsonc
{"t":"meta","session":"...","device":"Mac15,3","os":"14.5","commit":"abc123"}
{"t":"stage","frame":42,"stage":"capture","start_ns":1234,"end_ns":1300}
{"t":"frame","frame":42,"capture_ms":0.07,"vision_ms":4.2,"solver_ms":0.4,"render_ms":2.1,"watermark_ms":0.9,"e2e_ms":11.8}
{"t":"summary","frames":600,"p50_ms":11.2,"p95_ms":18.4,"p99_ms":27.6}
```

## Notes

- The demo does not need to be fast — it needs to be functioning and instrumented. Performance work follows in v0.2.0.
- If the Xcode app build is impractical in the harness environment, the CLI demo (capture -> bench JSONL -> watermarked output frames to disk) is sufficient evidence of demo state.
