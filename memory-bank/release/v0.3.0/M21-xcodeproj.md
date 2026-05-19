# M21 — Xcode Project + `.app` Bundle

**Status**: 🟡 in progress
**Owner**: lead
**Blocks**: M22, M23, M24, M29

## Objective

Produce a real `MirrorMesh.xcodeproj` (alongside `Package.swift`) that builds a macOS `.app` bundle wrapping the existing `MirrorMeshAppKit` SwiftUI library. The `.app` consumes the existing `Info.plist`, has its own entitlements file, and is the source-of-truth for v0.3.0 distribution.

## Deliverables

- `MirrorMesh.xcodeproj/` — Xcode project file
- `MirrorMesh/MirrorMesh.entitlements` — entitlements (Camera, Microphone, App Sandbox off for now since v0.3.0 ships outside the App Store; system-extension install will be added in M24)
- `MirrorMesh/Info.plist` — copy of (or symlink to) `Sources/mirrormesh-app/Info.plist`
- `Local.xcconfig` (gitignored) — template file `Local.xcconfig.example` checked in
- `MirrorMesh.xcconfig` — non-secret build settings shared across configs
- README / build-deployment.md updated with `xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh archive`

## Approach

Two options for project generation:
1. **Hand-write the `.pbxproj`** — fragile, but no dependency
2. **Use `xcodegen`** — declarative `project.yml` → generated project. Adds a dev-time tool dependency.

Pick (2) for maintainability. If `xcodegen` isn't on the system, the milestone owner installs via `brew install xcodegen` and documents that in `docs/build-deployment.md`. Generation isn't required at build time once the `.pbxproj` is committed.

## Verification

```bash
xcodegen generate
xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh -configuration Debug build
ls build/Debug/MirrorMesh.app
```

CI workflow updated to also build the `.app` (skip signing in CI; just verify the build).

## Notes

- The `.app` consumes `MirrorMeshAppKit` as a SwiftPM package dependency declared in the Xcode project
- Bundle ID defaults to `ai.mirrormesh.MirrorMesh` (overridable via `Local.xcconfig`)
