# M11 — Swift Testing Migration

**Status**: 🟡 in progress
**Owner**: lead
**Blocks**: M12, M19, M20, every test-writing milestone

## Objective

With Xcode available (ADR-0012), restore real `.testTarget` entries in `Package.swift` and migrate the v0.1.0 selftest assertions into Swift Testing (`import Testing`) suites. `swift test` becomes the primary correctness gate.

## Deliverables

- One `.testTarget` per library module:
  - `MirrorMeshCoreTests`, `MirrorMeshCaptureTests`, `MirrorMeshVisionTests`, `MirrorMeshSolverTests`, `MirrorMeshRenderTests`, `MirrorMeshWatermarkTests`, `MirrorMeshOutputTests`
- A consolidated `MirrorMeshIntegrationTests` target for cross-module tests (the Watermark/Manifest roundtrip and Solver/Renderer end-to-end checks from selftest)
- Tests written with `@Test` and `#expect` (Swift Testing) — XCTest only where parametrization is awkward
- `mirrormesh-selftest` retained as a CLT-friendly smoke binary, but reduced to module-name pings
- README updated with the canonical `DEVELOPER_DIR` build incantation

## Behavior

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` runs all suites and passes
- A failing assertion produces a Swift-Testing-style error pointing at the file/line
- Tests are deterministic — no flaky retries

## Verification

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```

Must show all green.

## Notes

- Tests live under `Tests/` (a directory that v0.1.0 deleted because XCTest wasn't usable)
- Don't break the build for CLT users: keep `mirrormesh-selftest` working under CLT-only toolchains
