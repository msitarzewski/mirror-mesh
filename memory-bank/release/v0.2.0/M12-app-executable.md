# M12 — `mirrormesh-app` Executable + Window

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M13, M14

## Objective

A SwiftPM `executableTarget` named `mirrormesh-app` that launches an `NSApplication`, hosts the existing `MirrorMeshAppKit.ContentView`, and runs the pipeline live. Runnable from Xcode's target dropdown **and** from `swift run mirrormesh-app`. No `.xcodeproj` file required for v0.2.0 (notarized `.app` bundle is v0.3.0+ scope).

## Deliverables

- New SwiftPM executable target `Sources/mirrormesh-app/MirrorMeshAppMain.swift`
- Updates `Package.swift` to declare the new target with `dependencies: ["MirrorMeshAppKit"]`
- `Sources/mirrormesh-app/Info.plist` with `NSCameraUsageDescription` (required for AVCaptureSession permission prompt)
- Wires `PipelineViewModel` to start in synthetic mode by default; consent flow flips to live when user clicks Start
- README quickstart updated to include `swift run mirrormesh-app`

## Behavior

- `swift run mirrormesh-app` opens a 1280×720 `NSWindow` showing the existing SwiftUI `ContentView`
- The app responds to ⌘Q
- Synthetic frame source runs by default (so demo works without camera permission)
- Consent flow can switch to `LiveCaptureSource` — permission dialog handled gracefully

## Verification

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run mirrormesh-app
# Manual: window appears, pipeline runs, Start/Stop and Settings work
```

For automated CI, the app must at minimum **launch without crashing** for ~2 seconds then exit cleanly when sent SIGTERM. Add a `--smoke-test` flag that auto-exits after 2 s with exit 0.

## Notes

- For SPM-based executable to host SwiftUI, use `NSApplication.shared` directly (don't rely on the `@main` `App` protocol — it doesn't ship a full menu without an Xcode app target). Pattern:
  ```swift
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
  ```
- AppDelegate constructs an `NSHostingController(rootView: ContentView())` and an `NSWindow` to host it.
