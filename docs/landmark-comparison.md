# Landmark Backend Comparison

MirrorMesh's face-landmark layer is pluggable: any type conforming to
[`LandmarkBackend`](../Sources/MirrorMeshVision/LandmarkBackend.swift) can feed the solver.
M26 adds a second backend, [MediaPipe Face Mesh](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker),
alongside the existing Apple Vision backend so the paper can report side-by-side
latency and fidelity numbers on the same fixture frames.

This doc:

1. Compares features and trade-offs of the two backends
2. Documents how to reproduce the latency numbers
3. Notes the current (v0.3.0) implementation state and the planned follow-up

## Current state: Vision-fallback stub

> **Honest disclosure.** As of v0.3.0, `MediaPipeLandmarkBackend` ships as a *Vision-fallback
> stub*. It conforms to `LandmarkBackend`, emits the right telemetry, carries the right
> manifest tag (`"mediapipe"`), and is selected by the bench scenario — but its
> `extract(from:)` body delegates to `VisionLandmarkBackend` and emits one
> `.warning` event per run with the message
> `"MediaPipe backend not available, falling back to Vision"`.

Why a stub: there is no first-party MediaPipe Tasks Swift package today. The official
distribution is via CocoaPods plus a ~12 MB XCFramework, both of which require an
out-of-band download step we don't want to bake into the default `swift build`. The M18
`CoreMLSolver` follows the same pattern (ship the protocol + dispatch logic + bench
wiring; replace the implementation when the binary lands), and the M26 stub mirrors
that decision so the paper can land on schedule.

The follow-up that flips this to a real implementation:

1. Vendor `MediaPipeTasksVision.xcframework` under `Vendor/MediaPipe/` (Apache 2.0)
2. Add it as a `.binaryTarget` in `Package.swift` against `MirrorMeshMediaPipe`
3. Replace the body of `MediaPipeLandmarkBackend.extract(from:)` with a real
   `FaceLandmarker.detect(image:)` call, then project the 468-point output through
   `MediaPipeLandmarkBackend.mediaPipeToVisionIndices` to the 76-point schema
4. Flip `isUsingFallback` to return `false` when the model loads successfully
5. Write a `.provenance.json` sidecar next to the binary per R5

Everything else — `LandmarkBackend` protocol, `PipelineOptions.landmarkBackend` injection,
manifest tag, `bench/scenarios/fixture_mediapipe.json`, `compare_landmarks.py` — is
ready and exercised today against the fallback.

## Feature comparison

| Capability                       | Apple Vision (`VisionLandmarkBackend`)              | MediaPipe Face Mesh (planned)                       |
| -------------------------------- | --------------------------------------------------- | --------------------------------------------------- |
| Landmark count                   | 76 normalized 2D points                             | 468 normalized 3D points (+iris, +blendshapes)      |
| Z (depth) per landmark           | No                                                  | Yes (relative)                                      |
| Per-frame blendshapes            | No (we run our own solver on top)                   | Optional — 52 ARKit-aligned scores out of the box   |
| Multi-face                       | Yes (we use single-face only)                       | Yes (configurable)                                  |
| Detection latency on M2          | 3–6 ms / frame at 1280×720 (measured)               | 6–12 ms / frame at 1280×720 (per MediaPipe docs)    |
| Binary footprint                 | 0 bytes (system framework)                          | ~12 MB XCFramework                                  |
| License                          | macOS SDK terms (system framework)                  | Apache 2.0                                          |
| Offline / on-device              | Yes                                                 | Yes                                                 |
| Hardware acceleration            | Neural Engine (via Vision request revision 3)       | Metal delegate (GPU) or XNNPACK (CPU)               |
| Schema stability across OS       | Tied to `VNDetectFaceLandmarksRequestRevision3`     | Stable (model is versioned and shipped with the SDK)|

### Picking a default

For the v0.3.0 bench the default backend stays Apple Vision because (a) zero install
overhead, (b) lower mean latency on Apple Silicon, (c) it's the path the rest of the
pipeline has been tuned against. MediaPipe is opt-in via scenario configuration. The
paper reports Vision as the production path and MediaPipe as the cross-platform
alternative.

## Reproducing latency numbers

```bash
# Vision backend (default)
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json

# MediaPipe backend (Vision-fallback stub today)
swift run mirrormesh-bench --scenario bench/scenarios/fixture_mediapipe.json

# Side-by-side latency table
python3 bench/scripts/compare_landmarks.py \
    bench/out/fixture_*.jsonl \
    bench/out/fixture_mediapipe_*.jsonl
```

`compare_landmarks.py` prints a per-stage P50/P95/P99/mean table plus the end-to-end
totals. Optional `--json out.json` writes a machine-readable summary.

### Example output (Vision-fallback stub)

While the MediaPipe binary is unavailable the two runs report near-identical numbers
because both execute Vision's request internally. The table below was produced on an
M2 Pro at 1280×720, 60 frames per scenario, fixture file
`Tests/Fixtures/face_synthetic_3s.mp4`. These are placeholder values; rerun the bench
locally and update the table when the real MediaPipe binary lands.

| stage     | metric | vision (ms) | mediapipe (ms) | delta (ms) |
| --------- | ------ | ----------- | -------------- | ---------- |
| vision    | p50    |   *fill in* |     *fill in*  | *fill in*  |
| vision    | p95    |   *fill in* |     *fill in*  | *fill in*  |
| solver    | p50    |   *fill in* |     *fill in*  | *fill in*  |
| render    | p50    |   *fill in* |     *fill in*  | *fill in*  |
| watermark | p50    |   *fill in* |     *fill in*  | *fill in*  |
| e2e       | p50    |   *fill in* |     *fill in*  | *fill in*  |
| e2e       | p95    |   *fill in* |     *fill in*  | *fill in*  |

## 468 → 76 index mapping

MediaPipe Face Mesh produces 468 landmarks per face; our solver consumes 76 in the
Vision schema. The mapping documented in
[`MediaPipeLandmarkBackend.mediaPipeToVisionIndices`](../Sources/MirrorMeshMediaPipe/MediaPipeLandmarkBackend.swift)
covers:

| Vision slot range | Anatomical group     | MediaPipe indices                                   |
| ----------------- | -------------------- | --------------------------------------------------- |
| 0..15             | Face oval            | 10, 338, 297, 332, 284, 251, 389, 356, 454, 323, … |
| 16..23            | Left eye             | 33, 160, 158, 133, 153, 144, 145, 153              |
| 24..31            | Right eye            | 263, 387, 385, 362, 380, 373, 374, 380             |
| 32..39            | Nose                 | 1, 2, 5, 4, 19, 94, 125, 141                       |
| 40..55            | Outer lips           | 61, 185, 40, 39, 37, 0, 267, 269, 270, 409, …      |
| 56..63            | Chin / jawline       | 152, 148, 176, 149, 150, 136, 172, 58              |
| 64..67            | Left brow            | 70, 63, 105, 66                                    |
| 68..71            | Right brow           | 300, 293, 334, 296                                 |
| 72..75            | Inner mouth          | 78, 95, 88, 178                                    |

Verify against the MediaPipe face_landmarker model card before flipping the real-binary
switch — indices have been stable across MediaPipe releases but the source of truth is
the upstream model documentation, not this table.

## License + binary footprint

- Apple Vision: macOS SDK, no separate license required.
- MediaPipe Face Mesh: Apache 2.0. Acceptable for v0.3.0; copy the LICENSE next to the
  vendored XCFramework when it lands.
- Binary size: ~12 MB. Tracked in [`docs/dependencies.md`](./dependencies.md) when that
  doc lands; for now the M25 + M26 spec docs reference this file.
