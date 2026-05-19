# M9 — SwiftUI App Shell + Consent UI

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M1, M3
**Blocks**: M10

## Objective

A SwiftUI macOS app that hosts the pipeline, presents the consent flow, and visualizes telemetry live.

## Deliverables

In `app/` (Xcode project) and `Sources/MirrorMeshAppKit/` (shared UI components consumable by tests):

- `MirrorMeshApp.swift` — `@main` entry
- `ContentView.swift` — main window
- `ConsentSheet.swift` — modal at session start; records hash of disclosed text
- `CameraPreview.swift` — `MTKView`/`NSViewRepresentable` showing `RenderedFrame`s
- `TelemetryPanel.swift` — live latency histogram, FPS, drop counter
- `SettingsView.swift` — device picker, landmark/avatar/watermark toggles (watermark toggle inert in release)
- `ConsentText.swift` — versioned disclosure copy; the canonical user-facing text

## Behavior

- App launch -> permissions check (camera) -> consent sheet -> pipeline start
- Session-stop button finalizes manifest and writes to user-chosen location (default `~/Library/Application Support/MirrorMesh/sessions/`)
- Watermark visible-overlay status indicator on the main window
- Crash / error states surface to the UI; not silent

## Tests

- View snapshot tests where feasible
- Consent flow: simulate accept/decline; pipeline only starts on accept
- Settings persistence (UserDefaults) round-trip

## Notes

- Use SwiftUI exclusively; AppKit interop only where required (MTKView host)
- Target macOS 14 minimum; @available guards for newer APIs
