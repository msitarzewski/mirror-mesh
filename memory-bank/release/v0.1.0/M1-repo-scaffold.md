# M1 — Monorepo Scaffold

**Status**: 🟡 in progress
**Owner**: lead (this session)
**Blocks**: M2, M3, M7, M9

## Objective

Stand up a monorepo that `swift build` accepts, with module directories matching `projectRules.md#R7`.

## Deliverables

- `Package.swift` declaring all v0.1.0 modules and their dependency graph
- Empty-but-buildable Swift sources for each module (`public func ping()` placeholder until real code lands)
- Top-level dirs: `Sources/`, `Tests/`, `app/`, `shaders/`, `models/`, `bench/`, `docs/`
- `.gitignore` (Swift / Xcode / macOS standard)
- `.swift-format` and `.swiftlint.yml` configs
- `README.md` at repo root with quickstart placeholder

## Module Graph

```
MirrorMeshCore         (base types, telemetry, frame protocols)
  ↑
MirrorMeshCapture      → depends on Core
MirrorMeshVision       → depends on Core, Capture
MirrorMeshSolver       → depends on Core, Vision
MirrorMeshRender       → depends on Core, Capture, Vision, Solver
MirrorMeshWatermark    → depends on Core
MirrorMeshOutput       → depends on Core, Render, Watermark

mirrormesh-bench (CLI executable) → depends on all
MirrorMesh.app (Xcode-managed)    → depends on all
```

## Verification

- `swift package resolve` clean
- `swift build` succeeds
- `swift test` passes (placeholder tests OK)

## Notes

- Minimum platform: macOS 14
- Swift tools version: 5.10
- No third-party dependencies added in this milestone; all stdlib + Apple frameworks
