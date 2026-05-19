# M4 — Landmark Stage (Apple Vision)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M3
**Blocks**: M5, M6

## Objective

Consume `CapturedFrame`s, produce stable per-frame facial landmarks via `VNDetectFaceLandmarksRequest`, smoothed with a One-Euro filter.

## Deliverables

In `Sources/MirrorMeshVision/`:

- `LandmarkExtractor.swift` — wraps `VNDetectFaceLandmarksRequest` + `VNSequenceRequestHandler`
- `LandmarkFrame.swift` — `{ frameID, points2D: [SIMD2<Float>], confidence: Float, faceBoundingBox: CGRect }`
- `OneEuroFilter.swift` — per-landmark adaptive smoothing (β, mincutoff configurable)
- `LandmarkSchema.swift` — canonical point indices (76-point Vision set)

## Behavior

- Each `CapturedFrame` -> at most one `LandmarkFrame` (no face -> emit `nilLandmarks` event)
- Smoothing applied per-coordinate, per-landmark
- Emits per-frame latency and confidence to Telemetry
- `vision.faceLandmarks.failed` event when request errors

## Tests

- Synthetic mesh-rendered face fixture: landmarks within tolerance of known positions
- Latency under 15 ms P95 on reference M3 hardware (asserted as warning, not failure, in unit tier)
- One-Euro filter: pulse input -> smoothed response within expected bounds

## Notes

- Vision requests are not Sendable across actor boundaries cleanly — wrap in `@unchecked Sendable` box or run on a dedicated dispatch queue
- Per Apple guidance, reuse a `VNSequenceRequestHandler` for temporally adjacent frames
