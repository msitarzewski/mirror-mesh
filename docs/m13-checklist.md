# M13 — Live Camera + Vision End-to-End Manual Checklist

Run this after every change that touches `MirrorMeshAppKit`, `LiveCaptureSource`,
`LandmarkExtractor`, or the `Pipeline` orchestrator.

## Setup

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift run mirrormesh-app
```

The first run will need camera permission via the standard macOS prompt. On an
SPM-launched binary the prompt is attributed to the parent process (Terminal,
Xcode); a real `.app` bundle in v0.3.0+ will surface MirrorMesh by name.

## Checks

- [ ] **Cold launch**: window opens with the indigo→purple gradient placeholder.
      Toolbar shows **Start Session**; no live frames yet.
- [ ] **Start Session → Consent**: clicking Start opens the Consent sheet with
      the v1 disclosure text. Decline closes without starting.
- [ ] **Accept → Live**: accepting the consent immediately starts the pipeline
      in `.live` mode. If permission is undetermined the system camera dialog
      appears now.
- [ ] **Permission denied → alert**: deny in System Settings → Privacy &
      Security → Camera, restart, accept consent. The in-app alert appears
      titled **"Camera Access Required"** with **Open System Settings** and
      **Dismiss** buttons. Clicking Open System Settings deep-links to the
      Camera privacy pane.
- [ ] **Permission granted → live frames**: real camera frames render in the
      preview; the placeholder fades out. The overlay label shows
      `frame N — WxH — host T ms` and N increments monotonically.
- [ ] **Landmarks visible**: with `Show landmarks overlay` on, dots track facial
      features. Latency `Telemetry → vision p50` < ~30 ms on Apple Silicon.
- [ ] **Avatar mask responds**: with `Show avatar mask` on, opening the mouth
      raises `jawOpen` in the top-right mask. Smile lifts `mouthSmileLeft/Right`.
- [ ] **Watermark active**: bottom-right of the main pane shows
      `● watermark active`. Settings toggle remains locked in release builds.
- [ ] **Stop Session**: toolbar **Stop** halts the pipeline. The preview freezes
      on the last frame; running indicator turns gray.
- [ ] **Manifest persisted**: after Stop, a fresh file exists at
      `~/Library/Application Support/MirrorMesh/sessions/<timestamp>.manifest.json`.
      Contents include the session id, signed frame digests, and consent record.

## Performance smoke

- [ ] End-to-end `pipeline p50` < 33 ms (30 fps budget) on the reference device.
- [ ] No console errors from Metal, AVFoundation, or Vision.
- [ ] Closing the window terminates the process cleanly (no orphaned capture
      session — confirm with `lsof | grep VDC` returning no entries).

## Automated coverage (separate)

- `swift test --filter LiveCaptureWiringTests` exercises the permission-denied
  surface via the `PipelineOptions(mode: .live)` path. See
  `Tests/MirrorMeshOutputTests/LiveCaptureWiringTests.swift`.
