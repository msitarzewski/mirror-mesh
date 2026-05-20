# MirrorMesh v0.1.0 — Demo

## What the demo proves

- Capture → landmarks → blendshapes → Metal render → cryptographically watermarked output, end-to-end, on Apple Silicon
- JSONL telemetry trace produced and summarized
- Tamper-evident session manifest signed with per-session Ed25519 key, verifiable with the included CLI

## Running the headless demo

```bash
swift build
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
```

This runs 120 synthetic frames through the full pipeline. Output goes to `bench/out/`:

- `demo_<timestamp>.jsonl` — frame-level telemetry
- `demo_<timestamp>.manifest.json` — signed session manifest

## Summarizing the trace

```bash
python3 bench/scripts/summarize.py bench/out/demo_<timestamp>.jsonl
```

Output:

```
stage            p50_ms     p95_ms     p99_ms      n
capture          18.710     20.007     23.920    120  ← includes inter-frame wait at 30 FPS
render            0.729      0.968      1.038    120
solver            0.061      0.071      0.103    120
vision            0.017      0.019      0.030    120  ← synthetic landmarks; real Vision is ~5-10ms
watermark         0.562      0.625      0.753    120
e2e               1.408      1.643      4.587    120  ← excluding inter-frame wait
```

Numbers above were captured on a Mac17,6 (Apple M5 Max, 128 GB, macOS 26.5).

## Verifying the manifest

```bash
swift run mirrormesh-verify --manifest bench/out/demo_<timestamp>.manifest.json
```

Output on success:

```
OK
session_id: <UUID>
frame_count: 120
started_at: 2026-05-19 18:02:31 +0000
ended_at: 2026-05-19 18:02:38 +0000
```

Mutate any byte of the manifest (e.g. flip `frame_count`) → verifier exits non-zero with a clear error.

## What the demo does NOT do (deferred to v0.2.0)

- Real camera capture (requires camera permission grant; works in the SwiftUI app, not in this CLI)
- Vision framework face landmarks on real video (the CLI uses a synthetic landmark generator since the procedural test pattern has no real face)
- SwiftUI app window (requires Xcode build, not Command Line Tools)
- Virtual camera output (`CMIOExtension`)
- WebRTC streaming

## Pipeline modes

- `synthetic` — procedural frames + synthetic landmarks. Used by CI and headless bench. No camera permission needed.
- `live` — `AVCaptureSession` + Apple Vision landmarks. Used by the SwiftUI app. Camera permission required at runtime.

Pipeline orchestrator is `Sources/MirrorMeshOutput/Pipeline.swift`.

## Trust layer summary

Every output frame carries:

1. A **visible** "MIRRORMESH • SYNTHETIC" badge composited into the bottom-right
2. A 64-byte **Ed25519 signature** binding the frame to the session, over `(frameID || hostTimeNs || SHA-256(BGRA pixels))`
3. A reference in the **signed session manifest**, which itself is signed over its canonical JSON form

Per-session keys are ephemeral; the public key is published in the manifest.

## Files of interest

| Path | What it does |
|------|--------------|
| `Sources/MirrorMeshOutput/Pipeline.swift` | End-to-end orchestrator |
| `Sources/mirrormesh-bench/BenchCLI.swift` | Scenario runner (ADR-0013: `@main` struct, not `main.swift`) |
| `Sources/mirrormesh-verify/VerifyCLI.swift` | Manifest verifier (ADR-0013: `@main` struct, not `main.swift`) |
| `Sources/MirrorMeshWatermark/FrameSigner.swift` | Ed25519 signing |
| `Sources/MirrorMeshWatermark/SessionManifest.swift` | Tamper-evident session manifest |
| `Sources/MirrorMeshCore/Telemetry.swift` | Per-stage telemetry bus |
| `bench/scripts/summarize.py` | Latency aggregator |
