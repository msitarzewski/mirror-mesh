# MirrorMesh — Progress

**Updated**: 2026-05-19

---

## Current Status

**Phase**: v0.6.0 "Identity" — 🟡 IN PROGRESS (M43 + M55 landed; M56 FOMM port next)
**Build status**: `swift build` clean; `MirrorMesh.app` builds ad-hoc-signed; live camera + landmarks + mesh + watermark + manifest + PIP all working
**Tests**: 66 tests / 17 suites passing under Swift Testing (3 documented `.disabled`)
**Open milestones**: M52, M53, M56, M57, M58, M59 (v0.6.0). M32 blocked on user-paste of Team ID.
**License**: **AGPL-3.0 + Commercial dual** (ADR-0014). Copyright "Michael Sitarzewski".
**Hardware**: User on M5 Max / 128 GB / 40 GPU cores — ML model selection unconstrained.
**Open inputs from user**: `DEVELOPMENT_TEAM`, App Store Connect API key, GitHub `<user>/<repo>` URL, LivePortrait license re-read, accessibility-app pick (v0.8.0), paper venue (v0.9.0).

## Done

- 2026-05-19 — Mission captured in `memory-bank/mision.md`
- 2026-05-19 — Memory Bank framework scaffolded
- 2026-05-19 — Monorepo decision approved (ADR-0011)
- 2026-05-19 — Release v0.1.0 roadmap created at `memory-bank/release/v0.1.0/`
- 2026-05-19 — **v0.1.0 demo functioning end-to-end**: 120 frames through capture→vision→solver→render→watermark, JSONL trace + signed manifest, all 35 selftest assertions green. Details: `docs/demo.md`.
- 2026-05-19 — **v0.2.0 "Living Window" delivered**: Xcode toolchain adopted (ADR-0012). Apache 2.0 license (ADR-0005). 10 milestones M11–M20 complete across one session via parallel agents. App executable, MTKView preview, frame recorder (.mov), procedural face fixture + FileFrameSource exercising real Vision, Instruments signposts, power bench scripts, CoreML solver scaffold with geometric fallback, GitHub Actions CI, real Swift Testing test targets (44 tests / 13 suites), paper-ready figure generator (matplotlib). Release readme: `memory-bank/release/v0.2.0/readme.md`.
- 2026-05-19 — **v0.4.0 "Sustainable" delivered**: License pivoted Apache-2.0 → AGPL-3.0 + Commercial dual (ADR-0014). Glass UI redesign with `.inspector()` + Form/Section + materials. Apple shell-app menu commands. Programmatic app icon generator. Three critical bug fixes: upside-down watermark text (CG double-flip), dead telemetry panel (Pipeline.clearSinks wiping caller-attached sinks), shader-resource subdir + CAMetalLayer aspect-fit. Live settings → renderer wiring. Auto-start synthetic preview. Rule R14 added (`.copy` not `.process`). Rule R13 expanded with inverse case. Initial git commit captured project-start-to-v0.4.0-kickoff.
- 2026-05-19 — **v0.5.0 "Presence" delivered**: M41 Bowyer-Watson Delaunay face mesh renderer (orientation-agnostic in-circle test for image-space landmarks; ~120 triangles, dropped convex-hull spurious ones). M34 real CoreML solver weights (val loss 0.0135, 38.8 KB, side-by-side mean abs disagreement 0.054 vs geometric). M37+M38 preview→live parallel-pipeline handoff + UserDefaults settings persistence. M42 three RenderStyles (Wireframe/Mirror/Mask). M44 recorder bakes style. Python pinned to 3.11. Avatar Mask shader upgraded with screen-space-derivative shading + edge fade + lower alpha.
- 2026-05-19 — **v0.6.0 "Identity" kickoff** (after watching the Arlo Gilbert LinkedIn deepfake-warning video cover frame): M43 Camera-as-PIP overlay (`OperatorPIPView` + `Pipeline.setOnCapture` + `PipelineViewModel.latestCapturedFrame`). M55 ConsentedIdentity protocol + `.mmid` bundle format with Ed25519 signature, scope grammar, tamper detection, 6-test verification suite. RESUME.md at repo root for clean session bootup. **Next: M56 FOMM CoreML port.** Tests: 66/17 green.

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
