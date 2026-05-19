# Changelog

## v0.4.0 — "Sustainable" — 2026-05-19 (in progress)

### Changed
- **License pivot**: Apache-2.0 → AGPL-3.0 + Commercial dual-license (ADR-0014). Apache-2.0 commits remain Apache; new contributions land under AGPL + commercial. See [`COMMERCIAL.md`](./COMMERCIAL.md) and [`CONTRIBUTING.md`](./CONTRIBUTING.md).
- DCO sign-off required on every commit (Linux-kernel-style, no CLA).
- README and ADR-0005 retained for history; ADR-0014 supersedes the license decision.

---

## v0.2.0 — "Living Window" — 2026-05-19

**Theme**: Real camera, real window, real tests, recordable output, real CI.

### Added

- `mirrormesh-app` executable target — `swift run mirrormesh-app` opens an `NSWindow` hosting the SwiftUI pipeline UI; `--smoke-test` exits after 2s for CI (M12)
- `MTKView`-backed live preview that zero-copies `RenderedFrame` pixel buffers via `CVMetalTextureCache` (M13)
- Permission-denied UX with "Open System Settings" deep link (M13)
- `MirrorMeshRecorder` module — `VideoRecorder` actor wraps `AVAssetWriter` and writes H.264 (default) or HEVC `.mov` files; pipeline optionally records every watermarked frame, sidecar manifest auto-generated (M14)
- `FileFrameSource` — `AVAssetReader`-backed implementation of `FrameSource` for playback of pre-recorded clips through the pipeline (M15)
- Procedural 26 KB / 3 s face-animation fixture at `Tests/Fixtures/face_synthetic_3s.mp4` plus a `mirrormesh-fixture-gen` regeneration tool (M15)
- `bench/scenarios/fixture.json` — exercises the file-source + real-Vision path
- Instruments `os_signpost` intervals on every stage, plus `bench/scripts/trace.sh` to record a `.trace` (M16)
- `bench/scripts/power.sh` + `power_parse.py` + `summarize_power.py` — `powermetrics`-backed power benchmark with JSONL output (M17)
- `ExpressionSolver` protocol — `GeometricSolver` and `CoreMLSolver` both conform; `Pipeline.options.solverKind` selects (M18)
- `models/training/blendshape_solver.py` — illustrative trainer for a tiny MLP blendshape solver; provenance manifest at `models/blendshape_solver_v1.provenance.json` per Rule R5 (M18)
- `bench/scripts/diff_coefficients.py` — side-by-side P50/P95 diff between two JSONL runs (M18)
- GitHub Actions CI (`.github/workflows/ci.yml`, `release.yml`, `dependabot.yml`); runs `swift test`, selftest, and a bench round-trip on macOS arm64; status badge in README (M19)
- Real Swift Testing test targets (`Tests/Mirror*/...`) per module + `MirrorMeshIntegrationTests` (M11)
- `bench/scripts/figures.py` — matplotlib-based generator for `latency_by_stage.pdf`, `e2e_distribution.pdf`, `per_session.pdf` (M20)
- `docs/m13-checklist.md`, `docs/instruments.md`, `docs/power-methodology.md`, `docs/ci.md`, `docs/figures.md` (M13/M16/M17/M19/M20)
- `Tests/Fixtures/PROVENANCE.md` documenting the synthetic fixture's origin and limits

### Changed

- Build toolchain now requires Xcode (ADR-0012). The CLT-only `mirrormesh-selftest` remains as a smoke binary for restricted environments.
- `PipelineMode` extended with `.file(URL)` case (M15)
- `Pipeline` exposes `setOnRender(_:)` for the SwiftUI preview wiring (M13)
- Renamed manifest `CaptureConfig` → `ManifestCaptureConfig` to avoid namespace collision with the runtime `MirrorMeshCapture.CaptureConfig`
- Synthetic landmark extractor now produces 76 points (matches Vision schema) instead of 60

### Documentation

- v0.2.0 release readme at `memory-bank/release/v0.2.0/readme.md` with 10 milestone specs (M11–M20)
- ADR-0012 in `memory-bank/decisions.md` documents the Xcode toolchain decision

---

## v0.1.0 — "First Light" — 2026-05-19

**Theme**: Capture-to-watermarked-output pipeline end-to-end, headless, Apple Silicon, ≤2 ms synthetic E2E on M5 Max.

### Added

- Monorepo SwiftPM scaffold for Apple Silicon (M1)
- `MirrorMeshCore` — `FrameID`, `Telemetry` actor, `JSONLLogger`, `LatencyHistogram`, `RingBufferSink`, `Signpost`, `PixelBufferPool`, shared frame types (M2)
- `MirrorMeshCapture` — `AVCaptureSession`-backed `LiveCaptureSource` + procedural `SyntheticFrameSource` (M3)
- `MirrorMeshVision` — `LandmarkExtractor` (Apple Vision, 76-pt), One-Euro smoother, synthetic landmark generator (M4)
- `MirrorMeshSolver` — `GeometricSolver` with calibration + smoothing producing ARKit-52 blendshape coefficients (M5)
- `MirrorMeshRender` — Metal-based passthrough + landmark overlay + cartoon avatar mask, zero-copy via `CVMetalTextureCache` (M6)
- `MirrorMeshWatermark` — three-layer trust: visible badge (Core Graphics), Ed25519 per-frame signing (CryptoKit), signed session manifest (M7, M8)
- `mirrormesh-bench` CLI + JSON scenarios + `summarize.py` (M10)
- `mirrormesh-verify` CLI — manifest verifier (M7)
- `mirrormesh-selftest` CLI — 35-assertion smoke suite (M1+M5+M7)
- SwiftUI library (`MirrorMeshAppKit`) — `ContentView`, `ConsentSheet`, `PipelineViewModel`, `SettingsView`, `TelemetryPanel` (M9)
- Pipeline orchestrator (`Sources/MirrorMeshOutput/Pipeline.swift`) wiring all stages end-to-end (M10)
- Memory Bank framework at `memory-bank/` (AGENTS.md v2.2 conformant)
- v0.1.0 release readme at `memory-bank/release/v0.1.0/readme.md` with 10 milestone specs (M1–M10)

### Verified

- E2E (synthetic) P50 = 1.4 ms on Mac17,6 / Apple M5 Max
- 120-frame demo produces signed manifest; verifier accepts intact, rejects tampered

[v0.2.0]: ./memory-bank/release/v0.2.0/readme.md
[v0.1.0]: ./memory-bank/release/v0.1.0/readme.md
