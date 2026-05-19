# M24 — Virtual Camera (`CMIOExtension`)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M21, M22 (entitlement)
**Blocks**: M30 (paper claim)

## Objective

Ship a CoreMediaIO system extension that exposes a "MirrorMesh" device the OS treats as a real webcam. QuickTime, Zoom, Meet, FaceTime all see it and pick it up.

## Deliverables

- New target `MirrorMeshVirtualCamera` (system extension) — Swift, `CMIOExtensionProvider`-based
- Stream pulls `WatermarkedFrame`s from a shared XPC channel published by the main app
- XPC service in `MirrorMeshOutput/VirtualCameraChannel.swift`
- Install path: app's first run prompts the user to install the system extension (`OSSystemExtensionRequest.activationRequest(...)`)
- `docs/virtual-camera.md` — how the OS sees the device, how to uninstall (`systemextensionsctl uninstall <team> <bundle>`)

## Verification

```bash
# After running MirrorMesh.app once and approving the extension prompt:
system_profiler SPCameraDataType | grep -A2 MirrorMesh
# QuickTime → New Movie Recording → camera dropdown shows "MirrorMesh"
# Recorded frames carry the visible watermark; mirrormesh-verify accepts the manifest the app emits in parallel
```

## Notes

- `CMIOExtension` (modern, macOS 12.3+) replaces the deprecated DAL plugin path
- Requires `com.apple.developer.system-extension.install` entitlement (set in M22)
- Distributed inside the app bundle; OS handles install/uninstall via `systemextensionsctl`
