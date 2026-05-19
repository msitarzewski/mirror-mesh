# Release v0.1.0 — "First Light"

**Goal**: A functioning local demo on Apple Silicon: camera → landmarks → expression coefficients → Metal-rendered overlay → watermarked output, with a SwiftUI shell and a JSONL benchmark harness.

**Started**: 2026-05-19
**Demo working as of**: 2026-05-19 18:02 UTC

---

## Status: ✅ Functioning demo achieved

End-to-end pipeline runs on the included scenarios. All 35 selftest assertions pass. Session manifest signs and verifies. JSONL trace produced and summarized.

Reference run (Mac17,6 / Apple M5 Max / macOS 26.5):

| stage | p50 ms | p95 ms |
|-------|--------|--------|
| vision (synthetic) | 0.017 | 0.019 |
| solver | 0.061 | 0.071 |
| render (Metal) | 0.729 | 0.968 |
| watermark + sign | 0.562 | 0.625 |
| **end-to-end** | **1.408** | **1.643** |

(Real Vision landmarks add ~5–10 ms; not exercised in the headless demo because the procedural test pattern doesn't contain a real face.)

## Scope (in — delivered)

- ✅ Monorepo, `swift build` and selftest clean on Command Line Tools
- ✅ Capture stage (AVFoundation + synthetic procedural source)
- ✅ Landmark stage (Apple Vision + synthetic deterministic source)
- ✅ Geometric blendshape solver (ARKit-52 keys, with calibration + smoothing)
- ✅ Metal renderer (passthrough + landmark overlay + cartoon avatar mask)
- ✅ Three-layer watermark (visible badge, Ed25519 frame signature, signed session manifest)
- ✅ SwiftUI app shell library (compiles via SPM; Xcode wrapper deferred)
- ✅ `mirrormesh-bench` CLI with scenario files
- ✅ `mirrormesh-verify` CLI
- ✅ JSONL trace + Python summarizer

## Scope (out — deferred to v0.2.0+)

- LivePortrait / first-order motion reenactment (avatar identity transfer)
- Voice pipeline (transcription, transform, TTS)
- Virtual camera (`CMIOExtension`)
- WebRTC streaming
- MediaPipe landmark backend comparison
- CoreML expression solver
- Notarized release build / Homebrew tap
- Power benchmarks via `powermetrics`
- Real Vision landmarks exercised by an end-to-end test (needs a real-face fixture clip)

---

## Phases — outcomes

| Phase | Milestones | Outcome |
|-------|------------|---------|
| 1. Foundation | M1, M2 | ✅ Monorepo builds; telemetry primitives in Core |
| 2. Capture pipeline | M3, M4 | ✅ Synthetic + live capture; Vision + synthetic landmark sources |
| 3. Processing | M5, M6 | ✅ Geometric solver, Metal renderer |
| 4. Trust layer | M7, M8 | ✅ Watermark + signed manifest |
| 5. Demo | M9, M10 | ✅ SwiftUI library + bench CLI + end-to-end run |

## Milestones — Status Board

| # | Title | File | Status | Owner |
|---|-------|------|--------|-------|
| M1 | Monorepo scaffold | [M1-repo-scaffold.md](./M1-repo-scaffold.md) | ✅ done | lead |
| M2 | Logging & telemetry | [M2-telemetry.md](./M2-telemetry.md) | ✅ done | lead |
| M3 | Capture stage | [M3-capture.md](./M3-capture.md) | ✅ done | lead |
| M4 | Landmark stage | [M4-landmarks.md](./M4-landmarks.md) | ✅ done | lead |
| M5 | Expression solver | [M5-solver.md](./M5-solver.md) | ✅ done | AI Engineer agent |
| M6 | Metal renderer | [M6-renderer.md](./M6-renderer.md) | ✅ done | macOS Spatial/Metal Engineer agent |
| M7 | Watermarking | [M7-watermark.md](./M7-watermark.md) | ✅ done | Security Engineer agent |
| M8 | Session manifest | [M8-manifest.md](./M8-manifest.md) | ✅ done | Security Engineer agent |
| M9 | SwiftUI app shell | [M9-app-shell.md](./M9-app-shell.md) | ✅ done | Mobile App Builder agent |
| M10 | Demo integration + bench | [M10-demo-integration.md](./M10-demo-integration.md) | ✅ done | lead |

## Exit Criteria — final check

1. ✅ `swift build` succeeds on macOS Apple Silicon
2. ✅ `swift run mirrormesh-selftest` — 35/35 pass
3. ✅ `swift run mirrormesh-bench --scenario bench/scenarios/demo.json` produces a JSONL trace
4. ⚠️ SwiftUI app launches — **library compiles; Xcode `.app` build deferred** because the environment has Command Line Tools only. AppKit-level view tests are deferred to the Xcode test plan.
5. ✅ Session manifest written and verifies via `mirrormesh-verify`
6. ✅ End-to-end P50 latency recorded: **1.408 ms** (synthetic landmarks); see `docs/demo.md` for full trace
7. ✅ README quickstart works (verified locally)

## Demo quickstart

See [`docs/demo.md`](../../../docs/demo.md).

## Lessons / artifacts for v0.2.0

- Multi-agent parallel build worked: 4 agents in parallel produced ~30 files of integrated code; only 1 small rename was needed during integration (the `CaptureConfig` namespace collision → `ManifestCaptureConfig`)
- Sendable warnings on Apple-framework wrappers (Metal, CVPixelBuffer) — documented in code; full Swift 6 strict concurrency cleanup is v0.2.0
- The "synthetic everything" path made headless CI possible without a camera or face fixture; keeping that path first-class is worth the small extra surface
