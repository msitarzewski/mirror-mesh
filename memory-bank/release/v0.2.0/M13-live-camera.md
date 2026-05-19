# M13 — Live Camera + Vision Verified End-to-End

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M12
**Blocks**: M20

## Objective

Run the **real** pipeline (real AVFoundation capture, real Vision landmarks, real Metal renderer, real watermark) in `mirrormesh-app`. Prove that the pipeline that was unit-tested in v0.1.0 also works against actual hardware.

## Deliverables

- `MirrorMeshAppKit.CameraPreviewView` upgraded from a placeholder rect to an `MTKView` (or `NSViewRepresentable<NSView with CAMetalLayer>`) that displays the latest `RenderedFrame` from the pipeline
- Wire `PipelineViewModel.start()` so the consent flow can pass `mode: .live`
- Permission-denied UX: clear "Camera access required" alert with a "Open System Settings" button
- A manual test checklist documented in `docs/m13-checklist.md` covering: permission dialog, landmark visibility, avatar response to expression, watermark visible on output, performance feels live
- A short automated check that confirms `AVCaptureDevice.authorizationStatus(for: .video)` is queried before any session starts

## Behavior

- Launch app → click Start → consent sheet → Accept → if camera permission undetermined, system dialog appears
- On Accept + Permission granted: live frames flow, landmarks track the user's face, avatar mask responds
- On Permission denied: user-facing alert; pipeline stays stopped

## Verification

Manual (recorded in checklist):
1. Cold launch shows the synthetic gradient as default
2. Start session, accept consent → switches to live
3. Real Vision landmarks visible on face (sub-100ms feel)
4. Avatar mask top-right opens/closes with user's jaw
5. Watermark visible bottom-right of preview
6. Stop session → pipeline halts, manifest saved to default location

Automated:
- `swift test` includes a `LiveCaptureWiringTests` suite that constructs a `PipelineViewModel`, asks for `.live` mode, and asserts that without permission the error surface is hit (mock the auth status)

## Notes

- `Info.plist` from M12 must carry `NSCameraUsageDescription`
- Avoid blocking the main thread; pipeline runs on its own actor
