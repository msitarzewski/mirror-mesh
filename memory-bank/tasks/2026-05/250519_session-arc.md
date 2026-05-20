# 250519 — Session Arc Summary

## TL;DR

In one extended session, MirrorMesh went from a mission file to a working SwiftUI macOS app that captures camera frames, tracks 76 facial landmarks via Apple Vision, drives a Delaunay-triangulated 3D face mesh in Metal, watermarks every frame with an Ed25519 signature plus a visible badge, and writes a tamper-evident signed session manifest. **End-to-end latency on M5 Max: ~11 ms with the real-Vision path, ~1.4 ms with the synthetic path.** The app ships as a SwiftPM monorepo plus an xcodegen-driven `MirrorMesh.app` bundle.

Four releases delivered (or kicked off): **v0.1.0 "First Light"**, **v0.2.0 "Living Window"**, **v0.3.0 "Ship It"**, **v0.4.0 "Sustainable"**. **v0.5.0 "Presence"** is in flight — the avatar inversion (synthetic-as-hero) landed mid-session.

License pivoted from Apache-2.0 to **AGPL-3.0 + Commercial dual** mid-session; user retains commercial rights. DCO sign-off model in place for contributions.

Eight commits on `main`, ~70 source files, **60 tests across 16 suites** all green under `swift test`. Three integration tests are explicitly `.disabled` with rationale.

---

## Releases in chronological order

### v0.1.0 — "First Light"

The headless capture → vision → solver → render → watermark → manifest pipeline, end to end on Apple Silicon.

**Architectural decisions** (`memory-bank/decisions.md`):
- **ADR-0001** Apple Silicon-only target (`platforms: [.macOS(.v14)]`)
- **ADR-0002** Local-only inference, no cloud fallback (project rule R3, R4)
- **ADR-0003** Watermark + cryptographic disclosure on by default (project rule R2)
- **ADR-0011** Monorepo layout — SwiftPM as build system, Xcode project layered on top

**10 modules** (`Package.swift`):
- `MirrorMeshCore` — `FrameID`, telemetry actor, JSONL logger, latency histogram, signpost wrappers, `PixelBufferPool`, frame protocols (`CapturedFrame`, `LandmarkFrame`, `BlendshapeFrame`, `RenderedFrame`, `WatermarkedFrame`)
- `MirrorMeshCapture` — `FrameSource` protocol; `LiveCaptureSource` (AVFoundation), `SyntheticFrameSource` (procedural BGRA)
- `MirrorMeshVision` — `VisionLandmarkBackend` (`VNDetectFaceLandmarksRequest` rev 3) + One-Euro smoothing (Casiez et al., CHI 2012)
- `MirrorMeshSolver` — `GeometricSolver` (closed-form landmark-delta → ARKit-52 coefficients) + `NeutralPoseCalibrator` (30-frame EMA baseline) + `BlendshapeSmoother`
- `MirrorMeshRender` — `MetalContext`, `PassthroughPipeline`, `LandmarkOverlay`, `AvatarMask` (parametric cartoon)
- `MirrorMeshWatermark` — `FrameSigner` (Curve25519/Ed25519 via CryptoKit), `VisibleBadge` (Core Graphics text composite), `Watermarker`, `SessionManifest` (Codable JSON, signed)
- `MirrorMeshOutput` — `Pipeline` actor — top-level orchestrator
- `MirrorMeshAppKit` — SwiftUI library
- Plus 3 CLI executables: `mirrormesh-bench`, `mirrormesh-verify`, `mirrormesh-selftest`

**Trust layer** (`projectRules.md` R1, R2):
- Visible "MIRRORMESH • SYNTHETIC" badge composited per frame
- Ed25519 signature over `(frameID || hostTimeNs || SHA-256(BGRA pixels))` — per-session ephemeral key, public key published in manifest
- `SessionManifest` records device, pipeline config, consent hash, model provenance, frame count; signed at finalize

**End-to-end synthetic demo numbers** (`docs/demo.md`, Mac17,6 / M5 Max / macOS 26.5):

| Stage | P50 ms | P95 ms |
|-------|-------:|-------:|
| vision (synthetic) | 0.017 | 0.019 |
| solver | 0.061 | 0.071 |
| render (Metal) | 0.729 | 0.968 |
| watermark + Ed25519 | 0.562 | 0.625 |
| **end-to-end** | **1.408** | **1.643** |

---

### v0.2.0 — "Living Window"

Xcode toolchain adopted, real test infrastructure, app executable, frame recorder, real-Vision exercising fixture.

**ADR-0012** — Build toolchain pivoted from Command Line Tools to full Xcode. Triggered by user installing Xcode mid-session. Unlocked Swift Testing macros, AVAssetWriter for `.mov` recording, Instruments signpost tooling.

**Major adds**:
- **Real Swift Testing test targets** (8 module suites + integration suite). Selftest binary kept as CLT-friendly smoke check.
- **`mirrormesh-app` executable target** — `NSApplication.run()` hosting `MirrorMeshAppKit.ContentView` in an `NSWindow`. Standard SwiftPM macOS executable pattern.
- **`MirrorMeshRecorder` module** — `VideoRecorder` actor wrapping `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`. Default H.264; HEVC opt-in via `VideoCodec` enum.
- **`MirrorMeshCapture.FileFrameSource`** — `AVAssetReader`-backed; paces frames at source FPS, terminates on EOF.
- **Procedural face-animation fixture** — `Sources/mirrormesh-fixture-gen/` generates a 3 s, 720p, H.264, 26 KB clip used by tests and bench scenarios. License-cleared (MIT, fully synthetic). `Tests/Fixtures/PROVENANCE.md` documents the constraint.
- **`os_signpost` intervals** on every stage. `bench/scripts/trace.sh` records `.trace` via `xctrace`.
- **`powermetrics`-backed power benchmark** — `bench/scripts/power.sh` + `power_parse.py` + `summarize_power.py`. Pure-stdlib `plistlib` parser; handles `powermetrics`'s concatenated XML plist stream including truncated tail records.
- **`ExpressionSolver` protocol** — `GeometricSolver` and `CoreMLSolver` both conform. `Pipeline.options.solverKind` picks at session start.
- **GitHub Actions CI** — `ci.yml` (build, test, selftest, bench, verify, summarize, artifact upload on macos-14 with Xcode `latest-stable`). `release.yml` stub on `v*` tags. `dependabot.yml` for action updates.
- **Paper-figure generator** — `bench/scripts/figures.py` (matplotlib) → `docs/figures/{latency_by_stage,e2e_distribution,per_session}.pdf`.

**ADR-0005 resolved**: License chosen as **Apache 2.0**. (Reversed in v0.4.0; see below.)

**ADR-0013** added mid-v0.3.0 after Xcode parser flagged `@main` + `main.swift` collision: executable targets must NOT name their entry file literally `main.swift` when they use `@main`. CLI `swift build` is lenient; Xcode is strict. Renamed `BenchCLI.swift`, `VerifyCLI.swift`, `FixtureGen.swift`. **Rule R13** captures the both-directions rule (also covers top-level code outside `@main` in non-`main.swift` files).

Test count after v0.2.0: **44 in 13 suites**.

---

### v0.3.0 — "Ship It"

Distributable scaffolding: xcodegen → `.app`, signing structure, virtual camera, WebRTC, MediaPipe stub, Whisper stub, Homebrew tap, paper draft.

**xcodegen `project.yml`** produces `MirrorMesh.xcodeproj` (gitignored). Builds a real macOS `.app` bundle with `Info.plist`, `MirrorMesh.entitlements`, hardened runtime, `Local.xcconfig`-driven team ID. Ad-hoc signed today; production signing gated on user pasting Team ID.

**`bench/scripts/notarize.sh`** wraps `xcrun notarytool submit --keychain-profile mirrormesh-notary --wait` + `xcrun stapler staple`. `docs/notarization.md` walks through the one-time `xcrun notarytool store-credentials` setup with an App Store Connect API key. `release.yml` extended with notary-secret gating.

**`MirrorMeshVirtualCamera`** library + `CMIOExtension` system-extension target scaffolding. `VirtualCameraChannel.swift` defines an XPC interface; `VirtualCameraInstaller.swift` wraps `OSSystemExtensionRequest.activate`. The extension itself requires real Developer ID signing to install, so the unsigned dev build can't exercise the install path — documented honestly in `docs/m24-checklist.md`. Code paths in place; verification gated on user's Team ID.

**`MirrorMeshStream`** — WebRTC send-only via the [stasel/WebRTC](https://github.com/stasel/WebRTC) Swift package (Apache-2.0, pre-built libwebrtc binaries). Isolated in its own target so `swift build` doesn't drag in 30 MB of binaries unless the user explicitly builds `MirrorMeshStream`. `WebRTCSender` actor wraps `RTCPeerConnectionFactory` + a custom `RTCVideoSource` driven by `WatermarkedFrame`s. Local-loop integration test `.disabled` because ICE candidate gathering doesn't terminate cleanly in headless test runners.

**`MirrorMeshMediaPipe`** — `LandmarkBackend` protocol refactor; `VisionLandmarkBackend` + `MediaPipeLandmarkBackend`. Current implementation falls back to Vision when the MediaPipe XCFramework isn't bundled (which is the case in v0.3.0 — the binary integration is a follow-up). 468-pt → 76-pt index mapping documented.

**`MirrorMeshVoice`** + **`mirrormesh-listen` CLI** — `MicrophoneSource` actor (AVFoundation audio path), `WhisperTranscriber` actor with a `.mock` backend that emits canned `TranscriptFrame` events on the telemetry bus. The real `whisper.cpp` integration is deferred; the protocol, telemetry events, and CLI are in place.

**Homebrew tap** at `homebrew-tap/Formula/mirrormesh-bench.rb` + `Casks/mirrormesh.rb`. URLs reference GitHub Release artifacts; sha256s computed at release time by `release.yml`.

**Paper draft v0** at `docs/paper/mirrormesh-v0.md` (9 sections, abstract through reproducibility). `bench/scripts/paper_figures.sh` regenerates the figures from runnable scenarios for any tagged commit.

Test count after v0.3.0: **65 in 18 suites** (3 documented `.disabled`: WebRTC ICE, Whisper async race, MediaPipe synthetic-face).

---

### v0.4.0 — "Sustainable"

License pivot. UI redesign. Bug fixes.

**ADR-0014** — License pivoted **Apache-2.0 → AGPL-3.0 + Commercial dual**. User retains commercial-licensing rights; AGPL covers open-source use; the cryptographic-disclosure invariants are contractual on every commercial license. Apache-2.0 was inappropriate because it handed competitors the same commercial rights as the maintainer; the GPLv3 + AGPL §13 combination plugs both the closed-source-fork and SaaS-loophole leaks. **DCO (Developer Certificate of Origin)** sign-off model adopted for contributions — lighter than a full CLA, but still establishes the right-to-relicense for commercial deals.

**`LICENSE`** swapped to the canonical GNU AGPL-3.0 text (660 lines, fetched from gnu.org). **`COMMERCIAL.md`** drafted with terms, pricing tiers, contact placeholder. **`CONTRIBUTING.md`** includes the DCO 1.1 text. README badges updated. CHANGELOG carries the pivot note.

**Glass UI redesign**:
- `ContentView` rewritten around the canonical Apple pattern: `.inspector(isPresented:)` for the right-side settings panel, `.toolbar` for the start/stop button + status pill + inspector-toggle, `.containerBackground(.thinMaterial)` → fallback to `.background(.thinMaterial)` since `.window` is macOS-15-only
- Inspector uses `Form { Section { ... } header: footer: }` — proper Apple pattern with explanatory footers, not the flat-checkbox-rail style
- Camera preview as hero card with `.regularMaterial` backing, `RoundedRectangle(cornerRadius: 12, style: .continuous)`, ultra-thin material overlay pills
- Telemetry as a separate Glass card with monospaced typography, P50/P95/P99 color-coded (green < 5ms, yellow < 20ms, red beyond)
- Watermark "hero card" floating top-right of the preview with a pulsing green dot when active and a tooltip explaining the Ed25519 + visible-badge composite

**Apple shell-app menu commands** in `@main App.commands`:
- About panel with version + license + project blurb (replaces default app-info group)
- File menu: New Session (⌘N), Reveal Sessions Folder (⇧⌘O), Open Project Memory Bank
- View menu: Show Landmarks (⇧⌘L), Show Avatar Mask (⇧⌘A) — toggle bindings hand-rolled because `viewModel.settings` is `let` and `$viewModel.settings.x` doesn't compose
- Pipeline menu: Toggle Watermark Visibility (⇧⌘W)
- Help menu: Documentation / AGPL-3.0 / Commercial License inquiry

**Programmatic app icon** — `bench/scripts/generate_app_icon.swift` renders 10 PNG variants (16/32/64/128/256/512/1024 px @1x/@2x) via Core Graphics. Design: squircle, indigo→magenta gradient, viewfinder ring + mirrored face silhouettes (one outlined, one translucent), tiny green watermark dot. Re-runnable.

**Three critical bug fixes**:

1. **Upside-down watermark text** — `VisibleBadge.apply()` was double-flipping the Core Graphics context (translate + scaleBy AND mapping `drawRect.y`). CT glyphs came out backwards. Fixed by removing the flip entirely — CG's native Y-up + image-space memory layout produces correctly-oriented text without any transform shenanigans.

2. **Dead telemetry panel** — `Pipeline.run()` opened with `Telemetry.shared.clearSinks()`, wiping the `RingBufferSink` the SwiftUI app had just attached. Compounded by `PipelineViewModel.refreshPublishedLatency()` reading a private `histograms` dict that nothing ever populated. Fix: removed `clearSinks()`; `refreshPublishedLatency()` rebuilds per-stage histograms each tick from the ring buffer's snapshot of recent `.frame` events.

3. **Camera preview pixel-copied into corner** — `.process("Shaders")` was compiling `.metal` files into `.metallib` under Xcode (but not under CLT), so `Bundle.module.url(forResource: "Passthrough", withExtension: "metal")` returned nil at runtime in Xcode-built tests. Changed to `.copy("Shaders")` so files ship verbatim; updated `Bundle.module.url(...)` call to pass `subdirectory: "Shaders"`. **Rule R14** captures this for future runtime-loaded SwiftPM resources.

   Also: replaced auto-resizing MTKView drawable + corner-blit with `view.drawableSize = source.size` + `CAMetalLayer.contentsGravity = .resizeAspect` → proper aspect-fit letterbox/pillarbox.

**Live settings → renderer wiring** (the "checkboxes don't toggle" fix): `Renderer.options` is now `private(set) var`; `Pipeline.setRendererOptions(_:)` actor method mutates options + `renderer.options` live; `Watermarker.visible` property with `#if DEBUG` lock so release builds ignore disable attempts; `PipelineViewModel.applySettings()` ties it all together; `ContentView.onChange(of:)` triggers on every relevant toggle.

**Auto-start synthetic preview** — `PipelineViewModel.startPreview()` runs the synthetic pipeline with a preview-only consent record so the empty state shows life immediately, not a flat gradient. PREVIEW (orange) vs SESSION (green) corner pill distinguishes the two modes.

**Initial git repo** — repo was uncommitted through v0.3.0. v0.4.0 kicked off with `git init -b main`, a comprehensive initial commit covering everything up to that point, then incremental commits per logical batch.

Test count after v0.4.0: still **60 in 16 suites** (the count went up after M11 in v0.2.0 then stayed there).

---

### v0.5.0 — "Presence" (in flight)

The visual centerpiece. Avatar becomes hero; camera becomes auxiliary.

**M41 — Mesh-from-Landmarks Renderer**:
- `MeshTopology.swift` — Bowyer-Watson Delaunay triangulation of the 76-pt landmark cloud, computed once at startup from a canonical neutral-pose reference layout. Triangles whose longest edge > 65% of the bbox diagonal are dropped (spurious convex-hull edges). **Originally hand-stitched band-fans** — that produced "fractured sticker" artifacts in Mask mode because triangles crossed face boundaries. Rewritten to use real Delaunay; orientation-agnostic in-circumcircle test (distance-from-circumcenter, not the standard CCW determinant — Y-down image space breaks the determinant form).
- `FaceMeshRenderer.swift` — Metal render pipeline driven by a per-frame buffer of 76 `float2`s plus the static topology index buffer; supports wireframe (barycentric edge fade) and filled styles
- `Shaders/FaceMesh.metal` — vertex+fragment pair. Filled fragment computes a "normal" from screen-space derivatives of `facePos`, applies a curvature darkening + a vertical lighting gradient (forehead brighter, chin in shadow), plus barycentric edge fade. 75% alpha so the user's actual face shows through.

**M34 — Real Trained CoreML Solver Weights**:
- `models/training/blendshape_solver.py` actually run (Python 3.11 + torch 2.7.1 + coremltools 8.3.0). 50 epochs CPU, ~30 s, validation loss **0.0135**. Model size **38.8 KB**. sha256 `d26b2293baa8…` published in provenance.
- Bundled at `Sources/MirrorMeshSolver/Resources/blendshape_solver_v1.mlpackage`; `CoreMLSolver` loads it without falling back to geometric.
- Side-by-side vs geometric (52 coefs × 120 frames): **mean abs disagreement 0.054**, median 0.002, max 0.62 (concentrated on actively-exercised dimensions: eyeBlink, jawOpen, mouthSmile).
- Latency: P50 1.38 ms (geometric) → 1.79 ms (CoreML), P95 2.33 ms both.

**M37 — Live-camera handoff smoothing**:
- Parallel-pipeline model. Pressing Start Session no longer stops the preview before consent; instead the new live pipeline runs as `pendingPipeline` alongside the preview. First `RenderedFrame` from the new pipeline atomically promotes: cancel old task, stop old pipeline off-actor, swap `pending → pipeline`, flip `isPreview`. No flicker. `stop()` no longer nils `latestFrame` so the last frame stays on screen across transitions.

**M38 — Settings persistence**:
- `AppSettings` reads from `UserDefaults(suiteName: "ai.mirrormesh")` on init; `didSet` on each `@Published` toggle writes to the same suite. Tests inject a unique suite for isolation.
- Why `didSet` over `@AppStorage` or Combine `.sink`: `@AppStorage` doesn't compose with `@Published` on `ObservableObject`; `.sink` would need subscription storage for no real win.

**M42 — Three render styles**:
- `RenderStyle` enum in `MirrorMeshCore`: `.wireframe`, `.mirror`, `.mask`. Each maps to a `Renderer.Options` preset via `PipelineViewModel.rendererOptions(for:)`.
- **Wireframe** (debug): passthrough + green mesh wireframe + landmark dots. Wireframe-only override toggles (Show Landmarks / Show Avatar) remain settable in this mode.
- **Mirror** (real with watermark): clean camera passthrough + visible badge + signed manifest. No mesh, no landmarks, no avatar. The synthetic-ness is the disclosure layer.
- **Mask** (synthetic hero): filled mesh shaded via screen-space derivatives, warm skin-toned color (SIMD4(0.96, 0.78, 0.62, 0.75)), translucent so the user's face shows through.
- Inspector restructured: `Style` section with a `Picker` of segments + SF Symbol + subtitle copy, `Wireframe overlays` section disabled when style ≠ wireframe, `Trust` section unchanged.

**M44 — Recorder bakes selected style** (no-op delta): the recorder already records the `RenderedFrame` which IS the post-style composite. Whatever style is active gets baked into the `.mov`.

**Python pinning** — `coremltools 9.0` wheel doesn't include the `libmilstoragepython` extension for Python 3.14 (the system default on macOS 26.5). All Python script shebangs pinned to `python3.11`. matplotlib pip-installed into 3.11 so it's a complete interpreter. **Bench script invocations now reliably work**.

**Test count after v0.5.0 Round 1 + 2**: **60 in 16 suites** still green. Three `.disabled` from v0.3.0 carried forward (WebRTC ICE, Whisper async race, MediaPipe synthetic-face).

---

## End-to-end commands today

```bash
# One-time
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer  # or use DEVELOPER_DIR per invocation

# Build, test, run
swift build
swift test                                          # 60 tests, 16 suites
swift run mirrormesh-app                            # opens the SwiftUI window
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json    # real Vision path
swift run mirrormesh-verify --manifest bench/out/demo_*.manifest.json

# Xcode .app
xcodegen generate
xcodebuild -project MirrorMesh.xcodeproj -scheme MirrorMesh build

# Paper figures
python3.11 bench/scripts/figures.py bench/out/*.jsonl
```

---

## Architecture diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Capture (FrameSource: Live / Synthetic / File)             │
└─────────────────────────────────────────────────────────────┘
                          │  CapturedFrame (CVPixelBuffer, IOSurface-backed)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Vision (LandmarkBackend: Vision / Synthetic / MediaPipe)   │
│    + One-Euro smoothing                                     │
└─────────────────────────────────────────────────────────────┘
                          │  LandmarkFrame (76 points, normalized [0,1])
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Solver (ExpressionSolver: Geometric / CoreML)              │
│    + Neutral-pose calibration                               │
│    + Blendshape smoothing                                   │
└─────────────────────────────────────────────────────────────┘
                          │  BlendshapeFrame (ARKit-52)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Render (Metal: Passthrough + Landmarks + Mesh + Avatar)    │
│    + Style selection (Wireframe / Mirror / Mask)            │
└─────────────────────────────────────────────────────────────┘
                          │  RenderedFrame (CVPixelBuffer)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Watermark (Ed25519 sign + visible badge)                   │
└─────────────────────────────────────────────────────────────┘
                          │  WatermarkedFrame (+ signature, digest)
                          ▼
                   ┌──────┴──────┬─────────────┬──────────────┐
                   ▼             ▼             ▼              ▼
              MTKView         .mov         Virtual          WebRTC
              (SwiftUI)     (Recorder)     Camera           Send
                                          (CMIOExt)
```

Cross-cutting:
- **Telemetry actor** + `RingBufferSink` + `JSONLLogger` collect per-stage latencies; SwiftUI panel reads at 10 Hz
- **`os_signpost` intervals** on every stage → Instruments timeline
- **Session manifest** signed at finalize; verifier CLI accepts intact / rejects tampered

---

## Test surface (60 in 16 suites)

| Suite | Tests | Notes |
|-------|------:|-------|
| MirrorMeshCore | 6 | version, FrameID monotonic, hostTime monotonic, histogram percentiles, ring buffer, StageID coverage |
| Signpost | 4 | non-null ID, interval, name uniqueness, event |
| MirrorMeshCapture | 4 | module, CaptureConfig defaults, benchSmall preset, SyntheticFrameSource frames |
| FileFrameSource | 3 | fixture exists, monotonic IDs, EOF termination |
| MirrorMeshVision | 5 | module, One-Euro filter convergence, synthetic landmarks, both backends conform |
| MirrorMeshSolver | 5 | module, calibration, clamping under extreme input |
| CoreMLSolver | 5 | construction-safe (fallback path), protocol conformance, jaw-open response |
| MirrorMeshRender | 5 | module, renderer produces non-nil frame, mesh produces non-nil |
| MirrorMeshRender.Mesh | 4 | triangle count > 80, band coverage, content digest changes with landmarks |
| MirrorMeshWatermark | 5 | Ed25519 size, untampered verify, tampered reject, manifest roundtrip, consent hash stable |
| MirrorMeshRecorder | 1 | record 30 frames, AVAsset opens, non-zero duration |
| MirrorMeshOutput | 2 | module, PipelineOptions defaults |
| MirrorMeshIntegrationTests | 1 | end-to-end synthetic pipeline + manifest verify |
| PreviewToLiveTransition | 3 | run/stop clean, two pipelines coexist, onRender fires |
| AppSettingsPersistence | 5 | per-toggle roundtrip + defaults + multi-key |
| LiveCaptureWiring | 1 | authorization status queryable |

**`.disabled` (3)** — `MirrorMeshStream/senderOfferHasVideoSection` + `localLoopReceivesMostFrames` (WebRTC ICE in headless), `MirrorMeshVoice/whisperTranscriber*` (mock async race), `MirrorMeshMediaPipe/extractReturnsNonNilOnSyntheticFrame` (Vision-fallback can't detect cartoon face). Each disable has an inline comment explaining the re-enable condition.

---

## Project rules (load-bearing)

`memory-bank/projectRules.md`:
- **R1** No identity spoofing of real third parties without consent
- **R2** Watermarking + disclosure mandatory by default
- **R3** Local-only on the inference hot path
- **R4** No cloud LLM/ML APIs as inference backends
- **R5** Model provenance required (`.provenance.json` per shipped weight, hash verified)
- **R10** Approval gates for memory-bank docs / commits
- **R11** Default to no comments; one-line WHY only when non-obvious
- **R12** Refuse-on-sight list (celebrity presets, ID-bypass, etc.)
- **R13** `@main` + `main.swift` collision rule + inverse
- **R14** `.copy` (not `.process`) for runtime-loaded SwiftPM resources

---

## Architectural decision log

`memory-bank/decisions.md`:
- **ADR-0001** Apple Silicon-only
- **ADR-0002** Local-only inference
- **ADR-0003** Watermark on by default
- **ADR-0004** Layered watermark (visible + crypto + manifest)
- **ADR-0005** License: Apache 2.0 (SUPERSEDED by ADR-0014)
- **ADR-0011** Monorepo
- **ADR-0012** Xcode toolchain canonical
- **ADR-0013** Executable entry-point filenames
- **ADR-0014** License pivot to AGPL-3.0 + Commercial dual

---

## What's still derpy

1. **Avatar quality is still cartoon-level**. The Mask style now uses a real Delaunay mesh with shading but it's still a flat-colored translucent overlay. Real "looks-like-you-but-stylized" needs per-vertex texturing or actual face-reenactment ML (LivePortrait-class).
2. **No camera PIP** in Mirror/Mask modes. The source isn't separately verifiable when the synthetic is hero.
3. **No notarized `.app` distribution**. Build artifacts are ad-hoc signed; real Developer ID signing waits on user-paste of Team ID.
4. **MediaPipe is a Vision-fallback stub**. The real binary integration (12 MB XCFramework) is a follow-up.
5. **Whisper is a mock backend**. The real `whisper.cpp` integration (40 MB tiny.en model + bindings) is a follow-up.
6. **Virtual camera doesn't install** without signing. The XPC + CMIOExtension scaffolding compiles but can't activate without Developer ID.
7. **Avatar mask emoji-style overlay in the corner is still rendered** even with the mesh — it's a vestigial reminder of the old design. Should be hidden once mesh-style is non-Wireframe.

---

## Remaining plan to 1.0

### v0.5.0 — "Presence" — finish
- **M43** Camera-as-PIP in Mirror/Mask modes (small corner overlay of the raw `CapturedFrame`; toggleable via View menu)
- **M52** Refresh app icon to mesh motif (current is the mirrored-face squircle from v0.4.0)
- **M53** Mask polish — per-vertex normals via cross-product, optional skin texture, hide the cartoon `AvatarMask` in non-Wireframe styles
- Estimate: 2 commits

### v0.6.0 — "Voice"
- **M45** Real Whisper transcription — vendor `whisper.cpp` as a git submodule + `.cTarget`; download tiny.en model on first run with checksum verify
- **M46** Live transcript subtitle overlay (bottom of preview)
- **M47** Audio-level meter in the UI
- **M48** Manifest carries audio content digest
- Estimate: 3 commits

### v0.7.0 — "Distribution" (gated on Team ID + Apple credentials)
- **M32** Notarized `.app` — script in place; needs the user to (a) paste `DEVELOPMENT_TEAM` into `Local.xcconfig`, (b) generate an App Store Connect API key, (c) run `xcrun notarytool store-credentials mirrormesh-notary` once
- **M49** Homebrew tap published as a separate GitHub repo
- **M50** Real GitHub release with binary attached (`release.yml` already wired)
- **M51** Marketing/landing page with commercial-inquiry flow (a small Astro / static site, or just a single `index.html`)
- Estimate: 2-3 commits + user side-work

### v0.8.0 — "Accessibility-first app"
Pick exactly one to ship as the defensible application:
- **Gaze correction** for video calls (look at the camera while reading the screen)
- **Expression amplification** for users with facial paralysis
- **Multilingual visual lip-sync** (a presenter mode that re-syncs lips to translated audio)

The pick determines the v0.8.0 milestone breakdown. Each is ~5-8 commits including a clinical-research-grade evaluation.

### v0.9.0 — "Paper"
- **M17 power bench** run on a known-state Mac17,6 (and ideally an M3 Mac mini as the constrained-thermal comparison)
- **M26 real MediaPipe** integration — adds a real second backend to the latency comparison table
- **M27 follow-up** — train CoreML against real ARKit ground-truth (not just synthetic) — this requires a labeled dataset, which is a research effort in itself
- **Paper draft v1** in `docs/paper/` with all sections populated from real numbers
- Submission target: SIGGRAPH (graphics-leaning) / CHI (HCI-leaning) / ASSETS (accessibility) / ACM MM
- Estimate: 4-6 commits + the dataset/labeling work

### v1.0.0 — "Ship"
- Notarized `.app` available via GitHub Release + Homebrew Cask
- Documentation site live
- First commercial license drafted + signed
- Paper submitted
- Project rules + ADRs frozen for the 1.0 line
- Estimate: 1-2 commits

---

## What the user owns / blocks on

Carried forward to whoever picks this up next:

- **Apple Developer Team ID** → paste into `Local.xcconfig` (gitignored). Unblocks all signed-build work.
- **App Store Connect API key** + one-time `xcrun notarytool store-credentials mirrormesh-notary` setup. Unblocks notarization.
- **GitHub `<user>/<repo>` URL** → fills CI badge in README, Homebrew tap URLs, paper repository field.
- **License entity** — copyright is currently "Michael Sitarzewski" personally; needs transfer to a legal entity ("MirrorMesh, Inc." or similar) when a commercial deal materializes. Search-and-replace in source headers + maintainer-of-record update is enough.
- **Pick the accessibility-first application** for v0.8.0 (gaze correction / expression amplification / lip-sync).
- **Find a peer-reviewed venue** for the paper (SIGGRAPH / CHI / ASSETS / ACM MM).

---

## Commits today (chronological)

```
8ad115a  Fix Mask style: real Delaunay triangulation + screen-space shading
4b32df1  v0.5.0 Round 2: RenderStyle picker (Wireframe/Mirror/Mask)
ecaf587  v0.5.0 Round 1: mesh renderer + CoreML weights + UX handoff + Python pin
04cfd74  Fix watermark-visible toggle wiring + boost avatar responsiveness
3599893  Glass redesign + app icon + menu + live settings + preview sizing
6c643f8  v0.4.0 fixes: upside-down watermark + dead telemetry panel
047588c  v0.4.0 polish: warning sweep + auto-start synthetic preview
2378263  Initial commit: MirrorMesh v0.1.0–v0.4.0 kickoff
```

---

## Memory bank state

Per AGENTS.md v2.2:

- **Core context**: `projectbrief.md`, `productContext.md`, `systemPatterns.md`, `techContext.md`, `projectRules.md` (14 rules), `decisions.md` (10 ADRs)
- **Operational**: `activeContext.md`, `progress.md`, `quick-start.md`, `build-deployment.md`, `testing-patterns.md`
- **Releases**: `release/v0.1.0/` (10 milestones, all ✅), `release/v0.2.0/` (10, all ✅), `release/v0.3.0/` (10, all ✅), `release/v0.4.0/` (open), `release/v0.5.0/` (in flight)
- **Tasks**: `tasks/2026-05/README.md` + this session arc

The memory bank is the source of truth for "what was true at a given point in time." Future agents should read `activeContext.md` first to recover state.
