# Changelog

## v1.4 — 2026-05-25

### Added
- **Photoreal lip-sync ghost overlay**: when photoreal is active, the stylized 3D head still renders at 0.18 scale as a small puppet cue over the photoreal face, so the audio-driven mouth motion (baked into the procedural mesh via `frame.overlayLipSync`) remains visible. Supplements LP's approximate mouth tracking with the audio path's precision.
- **Identity inspector thumbnail**: the inspector now shows a 48px source-PNG preview in the status row so the loaded identity is unambiguous at a glance.
- **Phase 2 v2 plan tooling — `--dump-tensors`**: `PhotorealBackend.reenact(driver:tensorDumpDir:)` and `mirrormesh-photoreal-bench --dump-tensors <dir>` write each LP submodel-boundary `MLMultiArray` to raw float32 `.bin` plus JSON sidecar (shape + dtype + count). Gating diff tool for incremental MPSGraph porting against the CoreML reference. 3 new tests.

## v1.3 — 2026-05-25

### Fixed
- **Photoreal driver-side face crop** (the 2026-05-20 "broken visual output" root cause). `PhotorealStage.apply` was passing the raw 1280×720 camera frame to `PhotorealBackend.reenact(driver:)`; the backend's internal square center-crop made the face only ~30% of the input, so LP's motion extractor produced incoherent keypoints. Fixed by pre-cropping the driver to the Vision face bbox + 25% padding before handing to the backend — matching the policy `IdentitySelfCapture` already uses on the source side. Live UI validation: photoreal substitution now visually works end-to-end. The 2026-05-20 pause is over.

### Added
- **`mirrormesh-photoreal-bench`**: standalone inference CLI that runs `PhotorealBackend.reenact` on PNG source + driver pairs. Per `memory feedback_ml_integration_validation.md`, this is the surgical-instrument layer for validating LP inference outside the UI pipeline. Five fixture runs against the upstream LP demo assets settled the inference-correctness question in under an hour (color path, channel order, `transform_keypoint`, and the appearance/motion/warp/generator graph all correct).
- **Face-crop helpers** in `PixelBufferConversion`: `expandedAndSquaredCrop(faceBoundingBoxNorm:imageSize:paddingFraction:)` + `cropped(_:to:ciContext:)`. Shared by source + driver paths so the crop policy stays in lockstep.
- **Phase 1 fixture set** at `Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg` + README. Mirrored from upstream LivePortrait `assets/examples/`. 5 new tests pinning crop math + buffer dimensions.

## v1.0.0 — 2026-05-20

### Changed
- **License simplification**: AGPL-3.0 + Commercial dual → **AGPL-3.0-only** (ADR-0015 supersedes ADR-0014). `COMMERCIAL.md` deleted; `NOTICE.md` added stating the research-only posture in plain English. Research-only model dependencies (LivePortrait + InsightFace runtime weights) are now usable under this posture.

## v0.4.0 — "Sustainable" — 2026-05-19

### Changed
- **License pivot**: Apache-2.0 → AGPL-3.0 + Commercial dual-license (ADR-0014). Apache-2.0 commits remain Apache; new contributions land under AGPL + commercial.
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
