# MirrorMesh — Progress

**Updated**: 2026-05-25

---

## Current Status

**Phase**: v1.4 "Photoreal Working" — 🟢 ACTIVE. Phase 1 of photoreal v2 plan complete; Phase 2 tooling shipped.
**Build status**: `swift build` clean across 15 library modules + 10 CLIs (added mirrormesh-photoreal-bench) + 1 app target
**Tests**: 217 tests / 42 suites passing under Swift Testing
**Closed today (2026-05-25)**: Photoreal correctness investigation (Phase 1 of v2 plan); driver-side face-crop fix; bench CLI for standalone inference + value-equivalence diffing; lip-sync ghost overlay over photoreal; identity inspector thumbnail; Phase 2 tensor-dump tooling.
**Open milestones**: M81/M82/M83 (notarization — blocked on Team ID); M75/M76 (paper bench measurements for camera-ready); Phase 2 actual MPSGraph porting (multi-week, gated on user direction); Phase 3-5 of v2 plan (zero-copy GPU, pipelined async, model distillation).
**License**: **AGPL-3.0-only research project** (ADR-0015 supersedes ADR-0014). Copyright "Michael Sitarzewski".
**Hardware**: User on M5 Max / 128 GB / 40 GPU cores — ML model selection unconstrained.
**Open inputs from user**: `DEVELOPMENT_TEAM`, App Store Connect API key, GitHub remote URL.
**Project status (2026-05-25)**: ACTIVE again. Photoreal substitution visually works end-to-end (user: "JPG over my face, head tracking working, mouth was off but way closer than anything we've done before"). The 2026-05-20 pause is over.

## Done

- 2026-05-19 — Mission captured in `memory-bank/mision.md`
- 2026-05-19 — Memory Bank framework scaffolded
- 2026-05-19 — Monorepo decision approved (ADR-0011)
- 2026-05-19 — Release v0.1.0 roadmap created at `memory-bank/release/v0.1.0/`
- 2026-05-19 — **v0.1.0 demo functioning end-to-end**: 120 frames through capture→vision→solver→render→watermark, JSONL trace + signed manifest, all 35 selftest assertions green. Details: `docs/demo.md`.
- 2026-05-19 — **v0.2.0 "Living Window" delivered**: Xcode toolchain adopted (ADR-0012). Apache 2.0 license (ADR-0005). 10 milestones M11–M20 complete across one session via parallel agents. App executable, MTKView preview, frame recorder (.mov), procedural face fixture + FileFrameSource exercising real Vision, Instruments signposts, power bench scripts, CoreML solver scaffold with geometric fallback, GitHub Actions CI, real Swift Testing test targets (44 tests / 13 suites), paper-ready figure generator (matplotlib). Release readme: `memory-bank/release/v0.2.0/readme.md`.
- 2026-05-19 — **v0.4.0 "Sustainable" delivered**: License pivoted Apache-2.0 → AGPL-3.0 + Commercial dual (ADR-0014). Glass UI redesign with `.inspector()` + Form/Section + materials. Apple shell-app menu commands. Programmatic app icon generator. Three critical bug fixes: upside-down watermark text (CG double-flip), dead telemetry panel (Pipeline.clearSinks wiping caller-attached sinks), shader-resource subdir + CAMetalLayer aspect-fit. Live settings → renderer wiring. Auto-start synthetic preview. Rule R14 added (`.copy` not `.process`). Rule R13 expanded with inverse case. Initial git commit captured project-start-to-v0.4.0-kickoff.
- 2026-05-19 — **v0.5.0 "Presence" delivered**: M41 Bowyer-Watson Delaunay face mesh renderer (orientation-agnostic in-circle test for image-space landmarks; ~120 triangles, dropped convex-hull spurious ones). M34 real CoreML solver weights (val loss 0.0135, 38.8 KB, side-by-side mean abs disagreement 0.054 vs geometric). M37+M38 preview→live parallel-pipeline handoff + UserDefaults settings persistence. M42 three RenderStyles (Wireframe/Mirror/Mask). M44 recorder bakes style. Python pinned to 3.11. Avatar Mask shader upgraded with screen-space-derivative shading + edge fade + lower alpha.
- 2026-05-19 — **v0.6.0 "Identity" kickoff** (after watching the Arlo Gilbert LinkedIn deepfake-warning video cover frame): M43 Camera-as-PIP overlay (`OperatorPIPView` + `Pipeline.setOnCapture` + `PipelineViewModel.latestCapturedFrame`). M55 ConsentedIdentity protocol + `.mmid` bundle format with Ed25519 signature, scope grammar, tamper detection, 6-test verification suite. RESUME.md at repo root for clean session bootup. Tests: 66/17 green.
- 2026-05-19/20 — **v0.6.0 "Identity" complete + v0.7.0/v0.8.0/v0.9.0 delivered via two parallel agent waves**:
    - Wave 1 (3 agents): M52 icon refresh, M53 mask cleanup, M56 stylized-head reenactor in `Sources/MirrorMeshReenact/` (266-vert procedural mesh, 18 blendshapes, 76-pt landmark solver, gated on `ConsentedIdentityVerifier.verify`), M56b FOMM photoreal scaffolding (MIT-licensed vendored source + python3.11 conversion script + manual weight-download docs), M57 `mirrormesh-consent` CLI with R1 third-party guard phrase, M58 Identity inspector panel, M59 disclosure chirp (A4→E5, locked-on in release). Orchestrator: integrated all three modules into Package.swift, Pipeline.swift, ContentView.swift, Renderer.swift. Renderer.render() gains optional `stylizedHead: Renderer.StylizedHeadPayload?` param; Pipeline ReenactStage between solver and render.
    - Wave 2 (3 agents): v0.7.0 Voice — replaced mock Whisper backend with on-device `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true` enforced); `Sources/MirrorMeshVoice/SpeechRecognitionBackend.swift` + `AudioCapture.swift`; mirrormesh-listen CLI rewired. v0.8.0 Accessibility — new `MirrorMeshTranslate` module: `OllamaClient` actor (localhost:11434, streaming NDJSON, 6 distinct error cases) + `TTSSpeaker` (AVSpeechSynthesizer wrapping with audio amplitude + Goertzel formant detection) + `LipSyncDriver` (vowel + amplitude → mouth blendshape coefficients, One-Euro smoothed, mouth-region-only overlay); `mirrormesh-translate` CLI with `--dry-run --silent --amplitude-trace`. v0.9.0 Paper — `paper/draft_v1.md` ASSETS-targeted draft v1 (7.5k words, 11 sections, 25 refs), `RELEASE_NOTES_v1.0.0.md`, `README.md` rewrite, `docs/CONSENT_PROTOCOL.md` standalone spec.
    - Final polish: added `SessionManifest.identity_sha256` (paper-flagged gap) + helper `ConsentedIdentityVerifier.canonicalSHA256(...)`. Clarified R3 wording from "no network call" → "no off-device network call" to legitimize localhost Ollama.
    - Test count: 66/17 → 110/23 (after wave 1) → 149/29 (after wave 2). All green.
    - Total: 15 library modules, 9 CLI executables, 1 .app target.
- 2026-05-20 — **Photoreal landed**: LivePortrait inference wired end-to-end.
  PhotorealBackend.reenact runs the full 4-mlpackage graph (appearance cached,
  motion + warp + generator per driving frame). PhotorealStage substitutes the
  captured frame in Mirror/Mask styles; Wireframe stays as debug. UX surfaces
  in IdentityInspector + toolbar pill. Auto-enabled on session start when
  models are present (per "no gating" policy from 2026-05-20).
- 2026-05-20 — **Photoreal v1.1 follow-ups landed**: capture-as-identity
  one-click flow lets users mint a usable .mmid from their live camera
  frame in seconds (replaces the 1×1 transparent auto-default that
  couldn't drive LivePortrait). transform_keypoint composition ports
  upstream's intrinsic-XYZ Euler + scale + exp + t math to Swift,
  producing meaningfully more expressive driving. FOMM photoreal path
  now wires real inference with parity to LivePortrait (separate
  weights, different per-frame graph). scripts/dev/refresh.sh covers
  the "I changed code but don't see it" cache-miss case.
- 2026-05-25 — **Photoreal v1.3 — Phase 1 of v2 plan, correctness
  resolved** (commit `a3b599d`). The 2026-05-20 "broken visual output"
  was a missing face-bbox crop on the driver path, NOT a model graph
  bug. Five `mirrormesh-photoreal-bench` runs against LP's own upstream
  demo assets (`Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg`)
  settled it: `s0→s0` / `d0→d0` faithful self-reconstruction;
  `d0→s0` / `s0_face_crop→d0` clean cross-identity reenactment;
  original `s0→d0` failure was just LP warping the source's dress
  fabric (full-portrait center-crop). Color path, channel order,
  `transform_keypoint`, and the appearance/motion/warp/generator graph
  all correct. Fix: `PixelBufferConversion.expandedAndSquaredCrop` +
  `cropped(_:to:)` in MirrorMeshReenact; `PhotorealStage.apply(_:
  faceBoundingBoxNorm:)` pre-crops the driver; `Pipeline.swift`
  passes the bbox through. 5 new tests, 209/40 → 214/41 green. Live
  UI validation by maintainer: "JPG over my face, head tracking,
  mouth was off but way closer than anything we've done before."
  Phase 2-5 of the v2 plan are still valid for the 25fps target
  but no longer urgent for correctness.
- 2026-05-25 — **Photoreal v1.4 follow-ups + Phase 2 tooling**:
  (a) Lip-sync ghost overlay — when photoreal is active, the audio-
  driven mouth motion (baked into the stylized-head mesh via
  `frame.overlayLipSync`) renders at 0.18 scale as a small puppet
  cue over the photoreal face, so LP's approximate mouth tracking is
  supplemented by the audio path's precision.
  (b) Identity inspector thumbnail — the inspector now shows a 48px
  source-PNG preview so the loaded identity is unambiguous at a
  glance (closes the "wait, what identity is loaded?" UX gap from
  the 2026-05-25 testing session).
  (c) Phase 2 v2 plan tooling — `mirrormesh-photoreal-bench
  --dump-tensors <dir>` writes each LP submodel-boundary `MLMultiArray`
  to raw float32 .bin + JSON sidecar (driver input, source feature_3d,
  source kp_transformed, all 7 motion outputs, motion.kp_transformed,
  warp.warped_feature, warp.occlusion_map, generator.prediction).
  This is the gating diff tool for incrementally replacing each
  CoreML submodel with an MPSGraph port — each port must
  numerically match the CoreML reference on the same input before
  shipping. Actual MPSGraph porting is multi-day per submodel and
  starts in a follow-up session (order per v2 plan: motion → warp
  → generator → appearance).
  3 new tensor-dump tests. 214/41 → 217/42 green.

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
