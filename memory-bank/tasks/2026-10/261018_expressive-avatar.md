# 261018_expressive-avatar

**Milestone ID**: unassigned (maintainer to assign). Branch: `expressive-avatar`.

## Objective

Un-shelve MirrorMesh with a new approach: instead of making the LivePortrait generator fast enough
(4–6 weeks of MPSGraph porting for 25–30 fps), author a high-fidelity avatar *in code* — an SDF head
raymarched in Metal, driven by the solver's ARKit-52 coefficients — then fit it to the consented
identity's portrait. Add accessibility transforms on the coefficient stream, disclosed in the manifest.

## Outcome

- ✅ Tests: 276 passing / 53 suites (+59 tests, +11 suites from the 217/42 baseline)
- ✅ Performance: ~2 ms GPU per 1280×720 frame (face at 45% frame height, M5 Max); app pipeline
  3.94 ms end-to-end P50 in the synthetic preview (vs 748 ms when LivePortrait photoreal is on)
- ✅ Build: `swift build` clean, no new warnings in touched files
- ✅ Review: approved by maintainer 2026-10-18 ("approved, commit it"); seen running in the app

## Files Modified

**New**
- `Sources/MirrorMeshRender/Shaders/ExpressiveHead.metal` — SDF head: skull/jaw (hinged, condyle
  glide), cheeks, muzzle, nose, ears, eyeballs (iris fibres, limbal ring, cornea catch-light),
  lids with lash line, brows, lips (cupid's bow, per-side width), cavity/teeth/tongue, hair, neck.
  Material-edge AA via runner-up surface, bounding-sphere early-out, occlusion-specific distance.
  Likeness: anatomy uniforms, rest-coordinate (jaw-undone) texture lookup, painted-brow warp,
  relief displacement, hair colour coverage.
- `Sources/MirrorMeshRender/ExpressiveHeadRenderer.swift` — renderer, `Anatomy`, `Likeness`,
  `renderOffscreen` (goldens / previews / future replay verification).
- `Sources/MirrorMeshReenact/PortraitAnalyzer.swift` — R1-gated portrait fit: Vision landmarks →
  anatomy; person segmentation → hair fit + coverage; canonical head-aligned texture; skin-masked
  de-lighting; skin/lip/brow projection mask; optional Core ML depth → band-passed relief.
- `Sources/MirrorMeshSolver/ExpressionTransform.swift` — symmetry assist, expression gain,
  eye-contact assist (pure functions) + manifest tags.
- `Sources/MirrorMeshAppKit/AvatarInspector.swift` — Avatar (Classic/Expressive, Match identity
  portrait) + Accessibility sections.
- Tests: `ExpressiveHeadTests` (index pinning, math, 7 goldens, property tests, GPU budget, opt-in
  preview sheet), `ExpressionTransformTests` (+ gaze measurement), `PortraitAnalyzerTests`,
  `LipSyncARKitBridgeTests`, `ExpressiveAvatarPipelineTests` (+ opt-in recorded-session preview).

**Extended**
- `MirrorMeshCore`: `AvatarKind` (RenderStyle.swift); `EyeLandmarks`, `LandmarkFrame.eyes`,
  `GazeChannels` (FrameProtocols.swift).
- `MirrorMeshVision/LandmarkExtractor.swift`: pupils + eye contours from Vision's named regions.
- `MirrorMeshSolver`: `GeometricSolver` gaze (eyeLook* from pupils, relative to calibrated rest);
  `NeutralPoseCalibrator` averages resting gaze.
- `MirrorMeshRender`: `Renderer` expressive payload; `MetalContext` shader list.
- `MirrorMeshReenact/ReenactFrame+Overlay.swift`: `LipSyncARKitBridge`.
- `MirrorMeshOutput/Pipeline.swift`: `avatar`, `expressionTransforms`, `likenessEnabled`,
  `likenessModelsDir` options; hot setters; detached likeness fit with generation guard;
  disclosure bookkeeping (one tag per transform kind).
- `MirrorMeshWatermark/PipelineConfig.swift`: `render.avatar`, `render.expression_transforms`,
  `watermark.expression_transformed`, `watermark.likeness_mapped` (all decode-defaulted).
- `MirrorMeshAppKit`: settings + persistence, generalized model-dir detection, photoreal no longer
  auto-enables with the expressive avatar, "Tap to disable" on Photoreal: ON.
- `Package.swift`: Reenact → Render dependency; RenderTests exclude `Goldens/`.

## Patterns Applied

- Fixture-first validation (`feedback_ml_integration_validation`) extended to rendering: every
  shader change was checked on a rendered preview sheet before trusting tests.
- Additive, decode-defaulted manifest fields with sticky disclosure semantics (same shape as
  `voice_transformed` / `photoreal_active`).
- Identity gate (R1) reused: `PortraitAnalyzer.analyze(identity:)` verifies like `FaceReenactor`.
- Model provenance (R5): `models/depth_v1.provenance.json`, recorded as a manifest `ModelRef` when used.

## Integration Points

- `Pipeline.run()` per-frame: solver `BlendshapeFrame` → transforms → lip-sync bridge →
  `Renderer.ExpressiveHeadPayload` (pose from `ReenactStage`, so the identity gate still applies).
- `Pipeline.refreshLikeness()` on run start, identity hot-swap, avatar switch, likeness toggle.

## Architectural Decisions

- ADR-0016 (decisions.md): code-authored expressive avatar becomes the main reenactment path;
  LivePortrait stays shelved (not deleted); portrait likeness via Vision + Core ML Depth Anything V2
  Small (Apache-2.0); transforms and likeness are manifest disclosures.

## Lessons (bugs caught by looking at renders / running the app)

- `eh_ellipsoid` underestimates far from flat shapes → slab-bound lips/cavity (cheek "whiskers").
- A bounding-sphere lower bound must never feed smooth unions or occlusion queries (phantom
  surfaces; banded shadows) → exact neck handling + `eh_occluderDistance`.
- Depth Anything's 14-px patch grid survives a high-pass → band-pass the relief.
- Steep height-field cuts (hairline/ear zone) break the Lipschitz bound → stipple; widen ramps.
- Running the app showed photoreal silently overriding the new avatar with no off switch.
- Launching the GUI from inside Claude Code aborts on TCC (voice asks for mic/speech) — run from
  the maintainer's terminal, or disable voice/translation for a headless demo.

## Follow-ups

- Hair silhouette from the segmentation outline (updos / long hair), eye shape from lid contours,
  optional FaceDepth (CC-BY-NC, 668 MB) as a drop-in depth model.
- Replayable provenance (signed coefficient log + `renderOffscreen` re-render verification).
- Re-encode-robust in-band watermark (exact-byte SHA-256 doesn't survive virtual cam → Zoom).
- Observed, not changed: classic head's pitch/roll sign vs `LandmarkSolver` docs; badge text
  overflow at 640 px; operator PIP covers most of the Mask stage at the default window size;
  hard-coded `/Users/michael/Clean` paths + wrong GitHub org in `MirrorMesh/MirrorMeshApp.swift`.
