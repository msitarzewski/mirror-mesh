# External Dependencies

This file documents third-party packages and binaries pulled in by MirrorMesh.
Default `swift build` only requires Apple frameworks; optional targets pull
additional artifacts as noted below.

## Apple frameworks (always required)

- AVFoundation, CoreMedia, CoreVideo, VideoToolbox
- Vision (live landmark backend)
- Metal, MetalKit, MetalPerformanceShaders
- CoreML
- CryptoKit (Ed25519 signing)

No version pins — system frameworks track the OS deployment target
(`macOS 14`).

## stasel/WebRTC (optional, opt-in via MirrorMeshStream)

- URL: <https://github.com/stasel/WebRTC>
- License: Apache 2.0 (libwebrtc upstream is BSD-3 + IP-grant patent file)
- Version: `from: "147.0.0"` (M147; April 2025)
- Artifact: pre-built `WebRTC.xcframework` (~30 MB compressed, ~120 MB extracted)
- Platforms: macOS arm64 + x86_64, iOS arm64, iOS simulator

### Why this package

The official libwebrtc build pipeline is a multi-hour Chromium-toolchain
checkout. The `stasel/WebRTC` package is a community-maintained mirror that
ships pre-compiled `XCFramework` binaries matching upstream `branch-heads/*`
release branches. It is the de-facto SwiftPM source for libwebrtc on Apple
platforms.

### Build isolation

The dependency is **not** transitively required by any default target:

- `MirrorMeshCore`, `MirrorMeshOutput`, `mirrormesh-bench`, `mirrormesh-app`
  do **not** link `WebRTC`.
- Only `MirrorMeshStream`, `mirrormesh-stream`, and `MirrorMeshStreamTests`
  declare it as a dependency.

A user who never builds the stream targets will still trigger a resolve
of the package URL (SwiftPM evaluates all dependencies during manifest
load) but the binary download is deferred until a stream target is built.
If you need to remove the resolve step entirely, comment out the
`MirrorMeshStream*` targets in `Package.swift`.

### Verification

To bring up just the stream targets:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --target MirrorMeshStream
swift test --filter MirrorMeshStreamTests
swift run mirrormesh-stream --mode local --scenario bench/scenarios/stream.json
```

### Alternative packages considered

- `webrtc-sdk/Specs` — CocoaPods only, no SwiftPM manifest.
- Self-built libwebrtc — multi-GB Chromium toolchain; rejected for CI cost.
- `livekit-ios/client-sdk-swift` — pulls livekit framing on top; over-scoped
  for one-way RTP.

If `stasel/WebRTC` becomes unmaintained, the migration path is to swap the
package URL in `Package.swift` and re-confirm the Obj-C class names exposed
to Swift remain stable (no `RTC_OBJC_TYPE_PREFIX` rename).
