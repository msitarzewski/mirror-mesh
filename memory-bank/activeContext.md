# MirrorMesh — Active Context

**Updated**: 2026-10-18 (project un-shelved; Expressive Avatar merged to `main` and pushed; CI fix for headless Vision applied)
**Current state machine position**: `DOCS` complete → `IDLE`. Expressive Avatar + Accessibility Transforms + Portrait Likeness approved ("approved, commit it"), merged to `main` and pushed ("merge it to main and push", `dc81a69` + `3d41c0b`). The first CI run on main failed; the fix (`fix/ci-vision-headless`, see `tasks/2026-10/261018_ci-vision-headless.md`) was committed, merged and pushed at the maintainer's request ("Update the memory bank, then commit push merge").
**Substate**: `IDLE`

**CI (2026-10-18)**: GitHub's `macos-14` VM cannot create a Vision inference context (`VNDetectFaceRectanglesRequest` → "Could not create inference context", Code=9). `IdentitySelfCapture.detectLargestFaceBoundingBox` resumed its continuation twice on that error and killed the test process; `PortraitAnalyzer` tests failed outright. Fixed: synchronous `perform` + `results` (no continuation), new `visionUnavailable` errors, Vision-dependent tests gated on `PortraitAnalyzer.isVisionAvailable`. On the CI GPU all 7 goldens and the render property tests passed; ExpressiveHead renders in 17.4 ms there (33 ms budget). Locally: 289 tests / 56 suites green under a plain `swift test`.

**QA (2026-10-18)**: 266 tests / 52 suites green (was 217/42). ExpressiveHead GPU median ~2.0 ms @ 1280×720 with face at 45% frame height (M5 Max). 7 golden PNGs in `Tests/MirrorMeshRenderTests/Goldens/` (re-record: `MIRRORMESH_RECORD_GOLDENS=1 swift test --filter ExpressiveHeadRenderingTests`). Dev previews: `MIRRORMESH_AVATAR_PREVIEW_DIR=<dir> swift test --filter ExpressiveHeadPreview` (expression sheet) / `--filter ExpressiveAvatarPipelinePreviewTests` (recorded .mov per style). Goldens held within tolerance on CI's virtualized GPU.
**Diff**: 32 files, ~2.6k insertions. New: `ExpressiveHeadRenderer.swift`, `Shaders/ExpressiveHead.metal` (~730 lines SDF), `ExpressionTransform.swift`, `AvatarInspector.swift` + tests. Extended: RenderStyle (AvatarKind), FrameProtocols (EyeLandmarks, GazeChannels), LandmarkExtractor (pupils), GeometricSolver + NeutralPoseCalibrator (gaze), Renderer, MetalContext, Pipeline (avatar option, transforms, disclosure), PipelineConfig (render.avatar, render.expression_transforms, watermark.expression_transformed), ReenactFrame+Overlay (LipSyncARKitBridge), PipelineViewModel/AppSettings, ContentView.
**Portrait likeness (2026-10-18, committed in `dc81a69`)**: `PortraitAnalyzer` (MirrorMeshReenact, R1-gated: verifies the .mmid) fits the expressive head to the identity portrait — Vision landmarks → `Anatomy` (brows, nose, mouth, lips, jaw, cheeks, chin, eyes; hair line/fringe/crown/width from Vision person segmentation), portrait resampled into a head-aligned canonical texture, skin-masked de-lighting, skin/lip/brow projection mask, hair-colour coverage, and optional depth relief from `models/depth_v1.mlpackage` (Apple Core ML Depth Anything V2 Small, Apache-2.0, provenance sidecar, gitignored like other weights). Shader: anatomy uniforms, rest-coordinate texture lookup (jaw undone), painted portrait brows warped by brow coefficients, relief band-passed (removes DINOv2 14-px patch grid). Manifest: sticky `watermark.likeness_mapped` + depth `ModelRef`. App: "Match identity portrait" toggle (default on). QA: 276 tests / 53 suites green, GPU ~2 ms @ 1280×720. Dev preview: `MIRRORMESH_AVATAR_PREVIEW_DIR=<dir> swift test --filter PortraitAnalyzerTests` (fixture: Sargent's *Lady Agnew*, public domain). Honest status: recognisable features on a stylized head; hairstyle shape (e.g. updos) is the largest remaining likeness gap.

**Observed, not changed**: classic `StylizedHeadRenderer` applies pitch/roll with the opposite sign to `LandmarkSolver`'s documented convention (expressive renderer uses the documented one); visible badge text overflows its box at 640 px wide.

## 2026-10-18 — Expressive Avatar milestone (milestone ID: unassigned — maintainer to assign)

**Why**: project was shelved 2026-05-25 because photoreal (LivePortrait) needs 4-6 weeks of MPSGraph porting to hit 25-30fps. New approach: author a high-fidelity *procedural* avatar in code (SDF raymarched in Metal), driven by the ARKit-52 coefficient stream — sidesteps ML inference cost, stays license-clean + asset-free, aligns with the "no AI-generated people" trust thesis. LivePortrait path untouched (shelved, not deleted).

**Scope (items 1+2+5 of the 2026-10-18 review)**:
1. `ExpressiveHeadRenderer` + `Shaders/ExpressiveHead.metal` — SDF head (eyes w/ iris+cornea, lids, teeth, tongue, jaw, lips, brows, hair, ears, neck), driven by 52 coefs + pose + gaze
2. Gaze signal: Vision pupils → `LandmarkFrame.eyes` → `GeometricSolver` eyeLook* keys
3. `ExpressionTransform` (MirrorMeshSolver): symmetry assist (paralysis compensation), expression gain, eye-contact assist; disclosed in manifest (`expression_transformed`, sticky)
4. Pipeline `avatar` option (default `.classic` preserves behavior; app defaults `.expressive`)
5. Avatar & Accessibility inspector + AppSettings persistence
6. Golden-frame + property tests (`MIRRORMESH_RECORD_GOLDENS=1` re-records)

**Repo moved** `~/Clean/mirror-mesh` → `~/Software/mirror-mesh`; required `swift package reset` (stale `.build/workspace-state.json` artifact paths). Baseline before this milestone: 217 tests / 42 suites green.

**Loose context**: maintainer's framing — "remind you [Opus 5.5] that you have this ability [code-authored motion graphics], refresh the ideas, see if your perspectives lead to improvements." openai/math repo reviewed: no load-bearing results (Barker ≤13 and existential merit-factor results only touch future in-band watermark sync-code design). Follow-ups queued (not in this milestone): replayable provenance (signed coefficient log + re-render verify), re-encode-robust in-band watermark (closes the virtual-cam → Zoom verification gap; `FrameSigner.swift:45-60` hashes exact bytes). Hardcoded `/Users/michael/Clean` paths at `MirrorMesh/MirrorMeshApp.swift:102,128` + wrong GitHub org at `:114` flagged, not yet fixed.

---

**Previous state (2026-05-25)**: `DOCS` (v1.4 batch) — since committed as `c12be33` + `c90743e`.

**Photoreal status — verified correct**: The Swift LivePortrait inference graph is correct. Five `mirrormesh-photoreal-bench` runs on `Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg` (LP's own upstream demo assets) settled it:

- `s0 → s0` (self): faithful reconstruction
- `d0 → d0` (self): faithful reconstruction
- `d0 → s0` and `s0_face_crop → d0` (cross-identity): clean reenactment with correct identity preservation and head-pose transfer
- Original `s0 → d0` failure mode: center-crop pulled in dress fabric from the full-body portrait, not an inference bug

Color path, channel order, `transform_keypoint`, appearance/motion/warp/generator are all correct.

**Actual root cause of 2026-05-20 broken output**: `PhotorealStage.apply` was passing the raw camera frame (`captured.pixelBuffer`) to `PhotorealBackend.reenact(driver:)` with no face-bbox crop. `PixelBufferConversion.makeMLInput` then did a square center-crop — for a 1280×720 camera that's a 720×720 input where the face is only ~30% of area, so LP's motion extractor produced incoherent keypoints. The source side (`IdentitySelfCapture`) was already cropping correctly via `expandedAndSquaredCrop`; the driver side wasn't.

**Phase 1 fix committed (`a3b599d`)**:
- `Sources/mirrormesh-photoreal-bench/PhotorealBenchCLI.swift` — standalone inference CLI for fixture-based testing (Phase 1 deliverable per `memory project_photoreal_v2_plan.md`)
- `PixelBufferConversion.expandedAndSquaredCrop(faceBoundingBoxNorm:imageSize:paddingFraction:)` — same math as `IdentitySelfCapture`, in the shared low-level module
- `PixelBufferConversion.cropped(_:to:ciContext:)` — pixel-rect → fresh BGRA IOSurface CVPixelBuffer
- `PhotorealStage.apply(_:faceBoundingBoxNorm:)` — pre-crops the driver when a bbox is supplied
- `Pipeline.swift` — fetches `landmarks?.faceBoundingBoxNorm` BEFORE the apply call, passes it through
- `Tests/MirrorMeshReenactTests/FaceBoxCropTests.swift` — 5 unit tests pinning crop math
- `Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg` + README

**Live UI validation by maintainer (2026-05-25)**: "JPG over my face, head tracking working, mouth was off but way closer than anything we've done before." Phase 1 visually confirmed.

**v1.4 follow-ups + Phase 2 tooling (this batch, uncommitted)**:
- `Renderer.swift` + `Pipeline.swift`: lip-sync ghost overlay — when photoreal is active, the stylized head still renders at 0.18 scale so the audio-driven mouth motion (baked into the procedural mesh via `frame.overlayLipSync`) shows as a small puppet cue over the photoreal face. Supplements LP's approximate mouth tracking with the audio path's precision.
- `IdentityInspector.swift`: 48px source-PNG thumbnail in the inspector status row so the loaded identity is unambiguous at a glance. Closes the "wait, what identity is loaded?" UX gap from the testing session (user saw a cartoon thumbnail after a toggle and couldn't tell what was active).
- `PhotorealBackend.swift`: new `tensorDumpDir: URL?` parameter on `reenact(driver:)`, plus `dumpMultiArray` and `dumpFlatFloats` helpers that write each submodel-boundary tensor to `<dir>/<name>.bin` (raw float32) + `<dir>/<name>.json` (shape + dtype + count). Dumps driver.input, source.feature_3d, source.kp_transformed, all 7 motion driving outputs, motion.driving.kp_transformed, warp.warped_feature, warp.occlusion_map, generator.prediction.
- `mirrormesh-photoreal-bench`: `--dump-tensors <dir>` flag wired to the above. This is the gating diff tool for Phase 2 MPSGraph porting — each submodel rewrite must numerically match the CoreML reference on the same input.
- `Tests/MirrorMeshReenactTests/TensorDumpTests.swift` — 3 unit tests pinning the dump format.

**Test count**: 209/40 → 214/41 (Phase 1) → 217/42 (v1.4 + Phase 2 tooling) green.

**What's STILL working unchanged from v1.0**: trust layer (consent bundles, watermark, chirp, manifest, R12 refusals), Apple on-device Speech, translation pipeline, capture-as-identity, notarization scaffolding, paper draft v1.

**Phase 2-5 of v2 plan**: still valid for the 25-30fps target but no longer urgent for correctness. The tooling layer is shipped; the actual MPSGraph submodel porting is multi-day per submodel and starts in a follow-up session. Order per `memory project_photoreal_v2_plan.md`: motion (smallest, fastest feedback) → warp → generator → appearance.

**Lesson confirmed**: the bench-against-fixture approach (`memory feedback_ml_integration_validation.md`) settled in ~1 hour what 6 hours of UI-screenshot iteration on 2026-05-20 couldn't. Treat this as the standard ML-integration workflow going forward.

---

## License pivot — ADR-0015

The maintainer clarified intent: research project, no monetization, want to prevent others from monetizing derivatives too. AGPL-3.0-only achieves this without the dual-license dance. ADR-0014's Commercial half is being dropped; LICENSE-COMMERCIAL.md is being deleted; NOTICE.md is being added; all docs (README, RELEASE_NOTES, paper) are being updated to single-license posture. LivePortrait is unblocked because its research-only InsightFace dependency is satisfied by the maintainer's research use.

---

## Current Focus

**v0.6.0 "Identity" — ✅ COMPLETE 2026-05-19**

M43 + M52 + M53 + M55 + M56 + M57 + M58 + M59 all shipped via three parallel agents + orchestrator integration. Test count 66/17 → 110/23.

Pivot taken (per user's "we can always fix things"): M56 ships as a **stylized parameterized head** driven by 76-point landmarks, license-clean and `.stylizedNonHuman`-scheme-aligned. The FOMM photoreal path is scaffolded but requires manual weight download (models/training/README.md). The stylized path renders today.

Wave 1 deliverables:
- `Sources/MirrorMeshReenact/` — FaceReenactor actor, StylizedHead (266 verts, 18 blendshapes), ReenactStage, PhotorealBackend stub
- `Sources/MirrorMeshRender/Shaders/StylizedHead.metal` + `StylizedHeadRenderer.swift` — Pixar-stylized faceted fill with cyan rim light, edge fade
- `Sources/mirrormesh-consent/` — CLI producing signed .mmid bundles; R1 guard requires literal `--consent-confirm` phrase for third-party
- `Sources/MirrorMeshAppKit/IdentityInspector.swift` — settings panel section with NSOpenPanel + verifier
- `Sources/MirrorMeshAppKit/DisclosureChirp.swift` — A4→E5 sine sweep on real session start, locked-on in release
- `models/external/fomm/` — vendored FOMM source (MIT) with provenance; LivePortrait rejected for InsightFace research-only weight dep
- Renderer.render() gains optional stylizedHead payload; Pipeline ReenactStage between solver and render

**v0.7.0/v0.8.0/v0.9.0/v1.0.0 — in flight 2026-05-19 (Wave 2)**

Three parallel agents dispatched:
- **v0.7.0 "Voice"**: Apple on-device Speech framework replacing the mock Whisper backend
- **v0.8.0 "Accessibility"**: multilingual lip-sync — Ollama translation + AVSpeechSynthesizer + audio-amplitude → blendshape driver feeding the stylized head from v0.6.0
- **v0.9.0/v1.0.0**: ASSETS-targeted paper draft + RELEASE_NOTES_v1.0.0.md + README.md rewrite + CONSENT_PROTOCOL.md

Status boards: `memory-bank/release/v0.7.0/readme.md`, `v0.8.0/readme.md`, `v0.9.0/readme.md`, `v1.0.0/readme.md`.

## Releases delivered today

```
v0.1.0  ✅  First Light       v0.4.0  ✅  Sustainable
v0.2.0  ✅  Living Window     v0.5.0  ✅  Presence
v0.3.0  ✅  Ship It           v0.6.0  🟡  Identity
```

## Hardware budget for ML decisions

User's machine: **M5 Max / 128 GB RAM / 40 GPU cores / 8 TB storage**.

This is the consumer-Apple-Silicon ceiling as of 2026. ML model selection is NOT memory- or compute-constrained on this device. Default to higher-fidelity models when license + license permits. The paper's "commodity Apple Silicon" claim, however, requires we also run the M3 Mac mini bench numbers — don't publish only-this-machine results.

## Open user inputs (carry-forward)

These don't block M56 but unlock other work:
- **Apple Developer Team ID** → paste into `Local.xcconfig` (v0.7.0 notarization)
- **App Store Connect API key** → `xcrun notarytool store-credentials mirrormesh-notary` (v0.7.0)
- ~~**GitHub `<user>/<repo>` URL**~~ → resolved 2026-05-25: published as [`msitarzewski/mirror-mesh`](https://github.com/msitarzewski/mirror-mesh) (public). CI badge live; Homebrew tap URLs in `homebrew-tap/` updated. Homebrew tap itself not yet published (planned `msitarzewski/homebrew-tap`).
- **LivePortrait license re-read** — currently filed as research-only; if it's clarified to be compatible with AGPL+Commercial dual, M56 should use it instead of FOMM. Otherwise FOMM.
- **Pick accessibility-first application** (v0.8.0) — gaze correction / paralysis compensation / multilingual lip-sync.
- **Pick paper venue** (v0.9.0) — SIGGRAPH / CHI / ASSETS / ACM MM.

## State transition log

- 2026-05-19 — Initial scaffold. `PLAN`/`IDLE` after creating core Memory Bank files.
- 2026-05-19 — Release v0.1.0 → v0.5.0 in one extended session. See `tasks/2026-05/250519_session-arc.md` for the full play-by-play.
- 2026-05-19 — Xcode installed. ADR-0012 toolchain pivot.
- 2026-05-19 — License pivoted Apache-2.0 → AGPL-3.0 + Commercial (ADR-0014). Project rule R13 expanded; R14 added.
- 2026-05-19 — v0.6.0 kicked off after the LinkedIn deepfake-warning video clarified the target. M43 + M55 landed in one commit. `BUILD`/`IDLE`.

## Recovery sequence after `/compact` or fresh session

1. Read `RESUME.md` at repo root (one screen — quick state)
2. Read this file (current focus + open items)
3. Read `memory-bank/release/v0.6.0/readme.md` (active milestone plan)
4. Read `memory-bank/tasks/2026-05/250519_session-arc.md` if you need the full history
5. `git log --oneline | head -10` for recent commits
6. `swift build && swift test ...` to confirm green-state
