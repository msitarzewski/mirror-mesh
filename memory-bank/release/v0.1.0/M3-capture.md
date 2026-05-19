# M3 — Capture Stage (AVFoundation)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M1, M2
**Blocks**: M4, M6, M9

## Objective

Pull frames from the camera with low jitter and known timing, delivering `CVPixelBuffer` refs to downstream stages via an `AsyncStream<CapturedFrame>`.

## Deliverables

In `Sources/MirrorMeshCapture/`:

- `CaptureSession.swift` — wraps `AVCaptureSession`, manages device, format, and lifecycle
- `CapturedFrame.swift` — typed wrapper around `CMSampleBuffer` carrying frame ID, timestamps, and unified-memory pixel buffer
- `CaptureDevice.swift` — enumerates eligible devices (built-in, Continuity)
- `CaptureConfig.swift` — explicit format selection (1280×720@60 default; user-configurable)

## Behavior

- Explicit format selection (no `AVCaptureSession.Preset.high` magic — pick exact `AVCaptureDevice.Format`)
- Locked exposure / white balance / focus once session stabilizes (configurable; default locked for reproducibility)
- Frames delivered as `CapturedFrame { id, hostTimeNs, pixelBuffer }`
- Emits `stageStart`/`stageEnd` events to Telemetry per frame
- Backpressure: drop oldest if downstream lags by more than N frames (default 2), counter incremented

## Tests

- Mock `AVCaptureSession` not used — instead a `MockFrameSource` for downstream tests
- Real device test (excluded from headless CI; runs locally only)
- Format selection picks expected device format from a stubbed list

## Notes

- Camera permission must be requested before `start()`; surface `CaptureError.permissionDenied`
- No frame `memcpy`; pixel buffers flow as `IOSurface`-backed refs
