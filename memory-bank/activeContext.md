# MirrorMesh — Active Context

**Updated**: 2026-05-25 (photoreal correctness resolved — Phase 1 of v2 plan complete; driver-crop fix uncommitted)
**Current state machine position**: `APPROVAL` (Phase 1 fix awaiting user review)
**Substate**: `IDLE`

**Photoreal status — verified correct**: The Swift LivePortrait inference graph is correct. Five `mirrormesh-photoreal-bench` runs on `Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg` (LP's own upstream demo assets) settled it:

- `s0 → s0` (self): faithful reconstruction
- `d0 → d0` (self): faithful reconstruction
- `d0 → s0` and `s0_face_crop → d0` (cross-identity): clean reenactment with correct identity preservation and head-pose transfer
- Original `s0 → d0` failure mode: center-crop pulled in dress fabric from the full-body portrait, not an inference bug

Color path, channel order, `transform_keypoint`, appearance/motion/warp/generator are all correct.

**Actual root cause of 2026-05-20 broken output**: `PhotorealStage.apply` was passing the raw camera frame (`captured.pixelBuffer`) to `PhotorealBackend.reenact(driver:)` with no face-bbox crop. `PixelBufferConversion.makeMLInput` then did a square center-crop — for a 1280×720 camera that's a 720×720 input where the face is only ~30% of area, so LP's motion extractor produced incoherent keypoints. The source side (`IdentitySelfCapture`) was already cropping correctly via `expandedAndSquaredCrop`; the driver side wasn't.

**Fix landed (uncommitted)**:
- `Sources/mirrormesh-photoreal-bench/PhotorealBenchCLI.swift` — standalone inference CLI for fixture-based testing (Phase 1 deliverable per `memory project_photoreal_v2_plan.md`)
- `PixelBufferConversion.expandedAndSquaredCrop(faceBoundingBoxNorm:imageSize:paddingFraction:)` — same math as `IdentitySelfCapture`, lives in the shared low-level module so source + driver paths use identical crop policy
- `PixelBufferConversion.cropped(_:to:ciContext:)` — pixel-rect → fresh BGRA IOSurface CVPixelBuffer
- `PhotorealStage.apply(_:faceBoundingBoxNorm:)` — pre-crops the driver when a bbox is supplied
- `Sources/MirrorMeshOutput/Pipeline.swift` — fetches `landmarks?.faceBoundingBoxNorm` BEFORE the apply call, passes it through (was fetching AFTER, only for the composite)
- `Tests/MirrorMeshReenactTests/FaceBoxCropTests.swift` — 5 unit tests pinning crop math + buffer dimensions
- `Tests/MirrorMeshReenactTests/fixtures/lp_diff/{s0,d0}.jpg` + README — fixture set + re-fetch instructions
- `Package.swift` — adds `mirrormesh-photoreal-bench` executable target
- **214 tests / 41 suites green** (was 209 / 40)

**Next move (UI validation)**:
```bash
swift run mirrormesh-app
# Click "Capture as my identity" → wait for chirp → switch style to Mirror or Mask
# Should now show coherent face substitution
```

If output is still broken, run `mirrormesh-photoreal-bench --source <your .mmid's source.png> --driver <a-camera-still.png>` to isolate IdentitySelfCapture from the live pipeline.

What IS working (unchanged from v1.0):
- Trust layer (consent bundles, watermark, chirp, manifest, R12 refusals enforced)
- Stylized 3D head reenactment in Wireframe (parametric, license-clean)
- Apple on-device Speech, translation pipeline, capture-as-identity, notarization scaffolding, paper draft v1

Lesson confirmed: the bench-against-fixture approach (`memory feedback_ml_integration_validation.md`) settled in ~1 hour what 6 hours of UI-screenshot iteration on 2026-05-20 couldn't. Treat this as the standard ML-integration workflow going forward.

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
- **GitHub `<user>/<repo>` URL** → CI badge + Homebrew tap URLs (v0.7.0)
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
