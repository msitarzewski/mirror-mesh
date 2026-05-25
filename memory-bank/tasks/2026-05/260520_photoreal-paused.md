# 260520_photoreal-paused

## STATUS (2026-05-25): RESOLVED — root cause was driver-side face crop, not inference

**Phase 1 of the photoreal v2 plan** (Sources/mirrormesh-photoreal-bench/, Tests/MirrorMeshReenactTests/fixtures/lp_diff/) settled the inference-correctness question in five bench runs:

- `s0→s0`, `d0→d0`: faithful self-reconstruction (color, identity, geometry all correct)
- `d0→s0`, `s0_face_crop→d0`: clean cross-identity reenactment
- Original `s0→d0` failure: center-crop pulled in source's dress fabric, not an inference bug

**Swift inference graph, `transform_keypoint`, and color path are all correct.** All four hypotheses in this doc's "Investigation hypotheses" section were wrong.

**Actual root cause:** `PhotorealStage.apply` passed the raw camera frame to `PhotorealBackend.reenact(driver:)` with no face-bbox crop. LP's motion extractor produced garbage from low face-coverage input.

**Fix landed (uncommitted at time of this update):**
- `PixelBufferConversion.expandedAndSquaredCrop(...)` + `cropped(_:to:)` in MirrorMeshReenact
- `PhotorealStage.apply(_:faceBoundingBoxNorm:)` parameter
- `Pipeline.swift` passes `landmarks?.faceBoundingBoxNorm` through
- 5 new tests in `FaceBoxCropTests.swift`. 214/41 green.

Full context in `memory project_photoreal_v2_plan.md` ("Phase 1 result" section). The remaining work in that plan (Phases 2-5, MPSGraph rewrite + zero-copy GPU + pipelining + model distillation) is still valid for hitting the 25fps target but is **not urgent for correctness** — the live app should now produce coherent reenactment.

---

## Objective

Wire LivePortrait CoreML graph end-to-end so Mirror/Mask styles in the app substitute the operator's face with a photoreal rendering of a loaded `ConsentedIdentity`. Make the deepfake mechanic visually demonstrable to back the v1.0 demo pitch.

## Outcome

**Infrastructure shipped, visual output broken.** Pipeline calls inference, manifest records `photoreal_active`, tests pass, but the rendered face is incoherent. Maintainer paused the project after several debug iterations didn't land.

## What landed (commits `cbed01e` → `e563c22` + uncommitted)

**Inference graph** (`Sources/MirrorMeshReenact/PhotorealBackend.swift`)
- LivePortrait 4-mlpackage forward pass: appearance (cached) → motion → warp → generator → 512×512 RGB → CVPixelBuffer
- FOMM kind parity (untested visually but compiles + tests pass)
- `transform_keypoint` Swift port of upstream's intrinsic-XYZ Euler + scale + exp + t composition
- `prepareSource()` caches feature_3d + kp_source per session
- Pass-through stub replaced with real inference

**Pixel buffer plumbing** (`PixelBufferConversion.swift`)
- CVPixelBuffer (BGRA) ↔ MLMultiArray (1,3,H,W RGB f32 [0,1])
- Alpha hard-set to 255 in conversion
- 512×512 generator output preserved (not downscaled to 256×256 anymore)

**Pipeline + Renderer** (`Sources/MirrorMeshOutput/PhotorealStage.swift`, `Renderer.swift`, new `PhotorealOverlay`)
- PhotorealStage actor pattern mirroring ReenactStage/VoiceStage
- Composite-at-bbox via new PhotorealOverlay Metal shader (feathered quad over passthrough at Vision face bbox)
- Wireframe never gets composite (debug view sacred)
- M37 handoff fix: voice/translation/photoreal re-enable on promoted live pipeline (was loading on preview pipeline that gets stopped)

**UX** (`Sources/MirrorMeshAppKit/`)
- "Capture as my identity" button — Vision face crop + Lanczos resize + signed .mmid mint + hot-swap
- "Use Test Persona" button — procedural teal/magenta cartoony face minted in-process
- Identity inspector status row (ON / off / not available / error)
- Toolbar Photoreal pill
- Reactive style subtitles
- `MIRRORMESH_LIVEPORTRAIT_MODELS_DIR` env var detection
- URL(fileURLWithPath:) fix (was URL(string:) — silently broke path math)

**DevOps** (`scripts/dev/refresh.sh`)
- Clean + rebuild + pkill + relaunch one-shot

**Docs**
- `docs/PHOTOREAL_QUICKSTART.md` — one-time setup, run, troubleshooting
- `models/training/liveportrait_to_coreml.py` — rank-5 patches applied to vendored model code so coremltools accepts the graph (commit `54e079d`)

## What's broken

**Rendered face in Mirror/Mask is incoherent.** Final user screenshot of test-persona Mirror showed a peach blob with horizontal banding artifacts where the photoreal face should be. Self-as-source Mirror showed output visually indistinguishable from camera passthrough.

## Investigation hypotheses (NONE TESTED)

1. **Color-space mismatch**. CVPixelBuffer (BGRA, sRGB) → MLMultiArray (RGB f32 [0,1]) → inference → MLMultiArray → CVPixelBuffer. Each step may handle gamma + channel order differently. Horizontal banding is classic precision/channel-order corruption symptom.
2. **`transform_keypoint` value-equivalence bug**. Swift port has unit tests for determinism + shape + identity-at-zero but no value-equivalence test against the upstream Python reference. Possible Euler axis order, degree/radian conversion, scale multiplication order all silent failures.
3. **LivePortrait keypoint extractor on non-photo input**. `MotionExtractor` was trained on photoreal human faces. The procedural `TestPersona` (geometric eyes/nose/mouth on solid color) may not produce keypoints the warp can use. Explains test-persona blob but NOT self-as-source degeneracy.
4. **Composite-at-bbox NDC math**. PhotorealOverlay vertex shader maps quad corners into NDC via bbox uniform. If the bbox coordinate convention (Vision top-left [0,1] vs NDC bottom-left [-1,1]) has a Y-flip bug, the photoreal could render off-screen or in a wrong region without throwing.

## Recommended first move on resumption

```bash
cd /Users/michael/Clean/mirror-mesh

# 1) Get a known-good face PNG. LivePortrait's demo set has assets/examples/source/s0.jpg or similar.
#    Download one, save as /tmp/ref_face.png (256x256 RGB).

# 2) Run the Swift inference standalone on it.
#    Need to write a small CLI (mirrormesh-photoreal-bench) that does:
#      let id = signed_identity_for(/tmp/ref_face.png)
#      let backend = try await PhotorealBackend(identity: id, pngBytes: pngBytes,
#                                                runtimeVersion: ..., modelsDir: ...,
#                                                kind: .liveportrait)
#      let driverPng = /tmp/ref_driver.png  (another 256x256 face)
#      let out = try await backend.reenact(driver: driverPng_as_CVPixelBuffer)
#      write out to /tmp/swift_output.png

# 3) Run upstream LivePortrait Python on the same source + driver:
#    cd ~/LivePortrait-upstream
#    python inference.py --source /tmp/ref_face.png --driving /tmp/ref_driver.png --output /tmp/py_output.png

# 4) Diff /tmp/swift_output.png vs /tmp/py_output.png.
#    - Bitwise identical: inference graph is correct, bug is downstream in composite/render
#    - Different but recognizable: math bug in transform_keypoint or color-space
#    - Garbage: input pipeline is wrong (PixelBufferConversion or motion extractor input format)
```

Without that diff, every UI-screenshot iteration is guessing.

## Files modified

Committed (latest commit at pause: `e563c22`):
- All Sources/MirrorMeshReenact/, Sources/MirrorMeshOutput/, Sources/MirrorMeshRender/PhotorealOverlay.*, related tests
- See `git log e563c22^..HEAD -- '*.swift' '*.metal'`

Uncommitted at pause (in working tree):
- `Sources/MirrorMeshAppKit/{PipelineViewModel,IdentityInspector}.swift` — M37 handoff fix + Use Test Persona button
- `Sources/MirrorMeshAppKit/TestPersona.swift` — new procedural face
- `Sources/MirrorMeshOutput/Pipeline.swift` — stderr SKIPPED diagnostic
- `Sources/MirrorMeshRender/Shaders/PhotorealOverlay.metal` — reverted to original alpha
- `Tests/MirrorMeshAppKitTests/TestPersonaTests.swift`
- `docs/PHOTOREAL_QUICKSTART.md` — verifying-photoreal section
- `memory-bank/{activeContext,progress}.md` + this doc + RESUME.md

## Patterns Applied

- AGENTS.md parallel-dispatch + scope-partition (3 agents per wave, no file collisions)
- M37 preview→live handoff pattern (now also rehydrates voice/translation/photoreal stages)
- ConsentedIdentityVerifier gate on every model load (R1)
- Watermark/chirp survive every photoreal transformation (R2/R12)

## Lesson

For ML-model integration work, validate the inference graph standalone against a known-good reference input + upstream Python output BEFORE wiring it into UI and chasing visual screenshots. Multiple iterations of UI-screenshot-driven debugging produced optimistic misreads of partial output (cyan tint thought to be visible, glasses thought to prove identity persistence) that wasted real time. Side-by-side Python diff would have settled the inference correctness question in 15 minutes.

## Artifacts

- Commit chain: `e66c2ba` → `463ed71` → `54e079d` → `cbed01e` → `e563c22` → (this commit)
- Final test count: 209 / 40 suites green
- Final session screenshot (peach blob): mentioned in conversation, not stored in repo
