# MirrorMesh — Progress

**Updated**: 2026-05-19

---

## Current Status

**Phase**: v0.4.0 "Sustainable" — 🟡 IN PROGRESS (license pivot done 2026-05-19, polish in flight)
**Build status**: `swift build` + `swift test` clean (Xcode toolchain); `MirrorMesh.app` builds ad-hoc-signed; user has confirmed the SwiftUI window renders correctly (M21 + M33 partial)
**Tests**: 65 tests / 18 suites passing under Swift Testing (3 documented `.disabled`)
**Open milestones**: M31, M33, M34, M35, M36, M37, M38, M39, M40 (v0.4.0). M32 blocked on user-paste of Team ID.
**License**: **AGPL-3.0 + Commercial dual** (ADR-0014 supersedes ADR-0005's Apache choice). Copyright "Michael Sitarzewski".
**Open inputs from user (v0.4.0 prerequisites)**: `DEVELOPMENT_TEAM` for `Local.xcconfig`, App Store Connect API key for notarization, GitHub `<user>/<repo>` URL.

## Done

- 2026-05-19 — Mission captured in `memory-bank/mision.md`
- 2026-05-19 — Memory Bank framework scaffolded
- 2026-05-19 — Monorepo decision approved (ADR-0011)
- 2026-05-19 — Release v0.1.0 roadmap created at `memory-bank/release/v0.1.0/`
- 2026-05-19 — **v0.1.0 demo functioning end-to-end**: 120 frames through capture→vision→solver→render→watermark, JSONL trace + signed manifest, all 35 selftest assertions green. Details: `docs/demo.md`.
- 2026-05-19 — **v0.2.0 "Living Window" delivered**: Xcode toolchain adopted (ADR-0012). Apache 2.0 license (ADR-0005). 10 milestones M11–M20 complete across one session via parallel agents. App executable, MTKView preview, frame recorder (.mov), procedural face fixture + FileFrameSource exercising real Vision, Instruments signposts, power bench scripts, CoreML solver scaffold with geometric fallback, GitHub Actions CI, real Swift Testing test targets (44 tests / 13 suites), paper-ready figure generator (matplotlib). Release readme: `memory-bank/release/v0.2.0/readme.md`.

## In Progress

- Awaiting user direction on first development milestone (see `activeContext.md` pending decisions)

## Not Started

- License selection
- Repository / source tree initialization (`Package.swift`, Xcode project)
- Benchmark harness skeleton
- Capture stage
- Landmark stage
- Expression solver
- Identity transfer / avatar stage
- Watermarking subsystem
- Disclosure UI
- Virtual camera output
- Voice pipeline
- Paper outline

## Blockers

None — awaiting first task contract from user.

## Known Risks (carry-forward)

- **Mission drift**: feature requests outside the consented/transparent identity scope will erode the project's defensibility. Refuse at intake.
- **Apple API churn**: `CMIOExtension` and CoreML model formats have changed materially across recent macOS releases — pin minimum and document.
- **Model licensing**: LivePortrait and similar reenactment models have research-only clauses; legal-clear alternatives may be required for release builds.

## Milestones (proposed — not yet adopted)

Listed for reference; adoption requires user approval and an ADR in `decisions.md`.

1. **M0 — Framework + Decisions** (in progress)
2. **M1 — Capture → JSONL landmarks** (smallest end-to-end slice)
3. **M2 — Benchmark harness produces reproducible latency numbers for M1**
4. **M3 — Watermarking spec + reference verifier**
5. **M4 — Self-reenactment minimum viable pipeline**
6. **M5 — Accessibility pilot use case (gaze correction or expression amplification)**
7. **M6 — Paper draft v0**

## Health Metrics

| Metric | Target | Current |
|--------|--------|---------|
| End-to-end latency (P95) | ≤ 100 ms | n/a |
| Sustained FPS | ≥ 30 | n/a |
| Power (plugged, M4 MBP) | < 25 W package | n/a |
| Power (battery, M4 MBA) | < 12 W package, no throttle 10 min | n/a |
| Watermark verifier pass rate | 100% on shipped output | n/a |
