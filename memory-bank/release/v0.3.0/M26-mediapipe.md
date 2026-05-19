# M26 — MediaPipe Landmark Backend

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M30

## Objective

A second `LandmarkBackend` implementation using Google's MediaPipe Face Mesh (Apache 2.0). Run it alongside the existing Apple Vision path on the same fixture frames, record latency and fidelity differences for the paper.

## Deliverables

- Refactor `LandmarkExtractor` into a `LandmarkBackend` protocol; existing `LandmarkExtractor` becomes `VisionLandmarkBackend`
- New `MediaPipeLandmarkBackend` in `Sources/MirrorMeshVision/MediaPipe/`
- Add MediaPipe Tasks Swift package or vendored XCFramework (the `mediapipe-tasks` repo provides a Swift API)
- Comparison harness `bench/scripts/compare_landmarks.py` — given two JSONL traces (Vision + MediaPipe), prints side-by-side latency table
- `bench/scenarios/fixture_mediapipe.json` — same fixture, MediaPipe backend
- `docs/landmark-comparison.md` — table of pros/cons + measured numbers (going into the paper)

## Verification

```bash
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json            # Vision
swift run mirrormesh-bench --scenario bench/scenarios/fixture_mediapipe.json  # MediaPipe
python3 bench/scripts/compare_landmarks.py bench/out/fixture_*.jsonl bench/out/fixture_mediapipe_*.jsonl
```

## Notes

- MediaPipe Face Mesh produces 468 points vs Vision's 76. The `LandmarkBackend` protocol normalizes by exposing only the 76-point indices the solver uses; richer outputs are accessible via a backend-specific extension
- License: Apache 2.0 — compatible
- The XCFramework adds binary size (~12 MB); document in `docs/dependencies.md`
