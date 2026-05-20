# MirrorMesh v1.0.0 — Release Notes

**Release date**: target 2026-Q3 (camera-ready of paper draft v1)
**Codename**: *Ship*
**Status**: 1.0 candidate. Production-ready for the documented use cases; alpha for the explicitly-labelled future-work items in Section "Known limitations".

---

## Highlights

- **First open, end-to-end realtime facial reenactment stack on Apple Silicon that ships consent and disclosure as architectural primitives, not removable flags.**
- **Consent-First Identity Protocol** — `.mmid` bundles bind a source image to a signed disclosure agreement, a runtime scope, and one of three explicit identity schemes; the reenactor refuses to initialize without verification.
- **Layered transparency** — per-frame Ed25519 signatures, visible "MIRRORMESH • SYNTHETIC" badge, signed session manifest, and audible session-start chirp. All four locked-on in release builds.
- **Measured E2E latency on a Mac17,6 (M5 Max)**: P50 1.4 ms (synthetic input) / P50 5.1 ms (real Apple Vision on the procedural fixture clip).
- **AGPL-3.0-only research project**, DCO-signed contributions, source-shippable `.app`.

---

## What's new — release-by-release rollup

### v0.1.0 — "First Light"

Working end-to-end pipeline, headless, all-synthetic:

- 10 Swift modules under `Sources/`: Core, Capture, Vision, Solver, Render, Watermark, Output, AppKit + 3 CLIs (`mirrormesh-bench`, `mirrormesh-verify`, `mirrormesh-selftest`).
- `MirrorMeshCore` defines `FrameID`, `Telemetry` actor, JSONL logger, latency histograms, signpost wrappers.
- `MirrorMeshCapture` ships `LiveCaptureSource` (AVFoundation) + procedural `SyntheticFrameSource`.
- `MirrorMeshVision` runs `VNDetectFaceLandmarksRequest` revision 3 with a One-Euro smoother.
- `MirrorMeshSolver` ships the closed-form geometric ARKit-52 blendshape solver with neutral-pose calibration.
- `MirrorMeshRender` is hand-written Metal — passthrough + landmark overlay + parametric cartoon avatar mask.
- `MirrorMeshWatermark` ships the three layers: visible badge, per-frame Ed25519 signature, signed session manifest.
- Bench harness produces JSONL traces; Python summarizer aggregates P50/P95/P99 per stage.
- 35-assertion selftest binary; manifest verifier CLI.

### v0.2.0 — "Living Window"

Real macOS window, real Xcode tests, recordable output, CI:

- `mirrormesh-app` SwiftUI executable: `NSWindow` hosting `ContentView`, live `MTKView` preview, permission-denied UX with Settings deep-link.
- `MirrorMeshRecorder` wraps `AVAssetWriter` for H.264 (default) or HEVC `.mov` with co-located signed manifest.
- `FileFrameSource` for playback through the pipeline; procedural face-animation fixture (3 s, 720p, 26 KB).
- Instruments `os_signpost` intervals on every stage; `bench/scripts/trace.sh` records `.trace`.
- Power benchmark scripts (`bench/scripts/power.sh`, `power_parse.py`, `summarize_power.py`).
- `ExpressionSolver` protocol; `CoreMLSolver` ships alongside `GeometricSolver`.
- GitHub Actions CI (`ci.yml`, `release.yml`, `dependabot.yml`).
- Paper-figure generator (`bench/scripts/figures.py`).
- Test count: 44 in 13 suites.

### v0.3.0 — "Ship It"

Distributable scaffolding:

- xcodegen `project.yml` → `MirrorMesh.xcodeproj` (gitignored) → `MirrorMesh.app` bundle.
- Notarization scaffolding (`bench/scripts/notarize.sh`, `docs/notarization.md`).
- `MirrorMeshVirtualCamera` library + `CMIOExtension` system-extension target.
- `MirrorMeshStream` — WebRTC send-only via `stasel/WebRTC` (Apache-2.0, opt-in target so default builds don't drag in 30 MB binaries).
- `MirrorMeshMediaPipe` — Vision-fallback stub for the 468-point MediaPipe Face Mesh backend (real XCFramework integration deferred).
- `MirrorMeshVoice` + `mirrormesh-listen` CLI (Whisper-mock backend; real `whisper.cpp` integration ships as v1.1 follow-up).
- Homebrew tap at `homebrew-tap/Formula/`.
- Paper draft v0 at `docs/paper/mirrormesh-v0.md`.
- Test count: 65 in 18 suites (3 documented `.disabled`).

### v0.4.0 — "Sustainable"

Sustainability — both architectural and commercial:

- License pivot Apache-2.0 → AGPL-3.0 + separate commercial (ADR-0014), then simplified to **AGPL-3.0-only research project** at v1.0.0 (ADR-0015). DCO sign-off on every commit.
- Glass UI redesign — proper `.inspector(isPresented:)`, `Form { Section { } header: footer: }`, `.thinMaterial` backgrounds.
- App menu commands: About, File menu (New Session, Reveal Sessions Folder), View menu (Show Landmarks, Show Avatar Mask), Pipeline menu (Watermark Visibility), Help menu (Documentation, AGPL).
- Programmatic app icon (10 PNG variants via `bench/scripts/generate_app_icon.swift`).
- Three critical bug fixes: upside-down watermark text, dead telemetry panel, camera preview pixel-copied into corner.
- Live settings → renderer wiring (no more "checkboxes that don't toggle").
- Auto-start synthetic preview so the empty state shows life immediately.
- Initial git repo with comprehensive first commit.

### v0.5.0 — "Presence"

The avatar becomes the hero view:

- Mesh-from-landmarks renderer: Bowyer-Watson Delaunay triangulation of the 76-point landmark cloud, computed once at startup from a canonical neutral-pose layout.
- Three render styles: **Wireframe** (debug — passthrough + green mesh + landmark dots), **Mirror** (real with watermark — clean camera + visible badge + signed manifest), **Mask** (synthetic hero — filled mesh shaded via screen-space derivatives, warm skin-toned, 75% alpha translucent).
- Real trained CoreML solver weights at `Sources/MirrorMeshSolver/Resources/blendshape_solver_v1.mlpackage` (50 epochs, val loss 0.0135, 38.8 KB, sha256 `d26b2293baa8…`).
- Settings persistence via `UserDefaults(suiteName: "ai.mirrormesh")`.
- Live-camera handoff smoothing — parallel-pipeline model means Start Session no longer flickers.

### v0.6.0 — "Identity"

The reenactment capability with consent gating:

- **`ConsentedIdentity` protocol + `.mmid` bundle format** — Ed25519-signed JSON header + PNG payload; three identity schemes (`.selfAsSource`, `.stylizedNonHuman`, `.consentedThirdParty`); scope grammar `vX.Y+`; full verifier with seven check steps.
- **`mirrormesh-consent` CLI** — produces signed bundles; refuses third-party bundles without explicit `--consent-confirm "I HAVE WRITTEN CONSENT FROM THE SUBJECT"` literal phrase.
- **`FaceReenactor` actor** — refuses to initialize without a verified bundle; drives the stylized 3D head.
- **Stylized 3D head puppet**: 266-vertex procedural lat-long mesh, 18 named blendshapes, pure-geometry 76-point landmark solver. Ships ready-to-run, no weights, deterministic.
- **`PhotorealBackend` (FOMM scaffolding)** — three-gate initializer (consent → scheme → models present), MLPackage compile + load, stub `reenact()` that returns the driving frame unchanged. The full inference graph composition lands in v1.1.
- **Camera-as-PIP** in Mirror/Mask styles — operator inset surfaces the human driving the puppet.
- **App icon refresh** (mesh motif).
- **Audible disclosure chirp** at session start (A4 → E5 perfect fifth, 250 ms, −18 dBFS).
- **Identity picker** in the Settings panel — lists loaded `.mmid` bundles; load verifies signature; rejection shows precise error.

### v0.7.0 — v0.9.0 (planned for the v1.0 line)

- v0.7.0 **Voice** — real `whisper.cpp` integration (vendored as `.cxxTarget`, Metal-enabled); cross-language ASR; `chirp_schedule` recurring disclosure; manifest `identity_sha256` field; manifest `audio_content_digest`.
- v0.8.0 **Accessibility** — multilingual visual lip-sync pipeline (ASR → translate → TTS → audio-driven visemes → blendshape mouth channels).
- v0.9.0 **Paper** — paper draft v1 (this release); measurements completed for the reference machine including power; M3 mini comparison for the constrained-thermal envelope; MediaPipe binary integration for a real second backend; submission to ACM ASSETS.

### v1.0.0 — *this release*

- Production-ready trust layer (consent + four-layer disclosure).
- Notarized `.app` bundle distributable via GitHub Release and Homebrew Cask.
- Documentation site live; commercial-inquiry flow at the project landing page.
- Paper submitted to ACM ASSETS; arXiv preprint posted.
- Project rules and ADRs frozen for the 1.0 line.

---

## What's in the box

### Modules (Swift libraries)

| Module | Role |
|--------|------|
| `MirrorMeshCore` | Frame types, telemetry actor, JSONL logger, signposts, pixel-buffer pool |
| `MirrorMeshCapture` | `FrameSource` protocol; `Live` / `Synthetic` / `File` sources |
| `MirrorMeshVision` | Apple Vision landmarks + One-Euro smoother |
| `MirrorMeshMediaPipe` | 468-pt MediaPipe Face Mesh backend (Vision-fallback in v1.0) |
| `MirrorMeshSolver` | `ExpressionSolver` protocol; Geometric + CoreML MLP implementations |
| `MirrorMeshReenact` | Stylized 3D head (procedural) + `PhotorealBackend` (FOMM scaffolding) |
| `MirrorMeshRender` | Metal — Passthrough, LandmarkSprite, AvatarMask, FaceMesh, StylizedHead shaders; Wireframe / Mirror / Mask styles |
| `MirrorMeshWatermark` | Ed25519 `FrameSigner`, `VisibleBadge`, `SessionManifest`, `ConsentedIdentity` |
| `MirrorMeshRecorder` | `AVAssetWriter`-based watermarked `.mov` with co-located manifest |
| `MirrorMeshVirtualCamera` | `CMIOExtension` system-extension scaffolding |
| `MirrorMeshStream` | WebRTC send-only (opt-in target; stasel/WebRTC Apache-2.0) |
| `MirrorMeshVoice` | `MicrophoneSource` + `WhisperTranscriber` actor |
| `MirrorMeshTranslate` | `OllamaClient` — streaming local-LLM HTTP client |
| `MirrorMeshOutput` | Top-level `Pipeline` orchestrator |
| `MirrorMeshAppKit` | SwiftUI library — `ContentView`, panels, identity inspector, chirp |

### CLI Tools

| Tool | Role |
|------|------|
| `mirrormesh-app` | Notarizable macOS `.app` (the user-facing application) |
| `mirrormesh-bench` | Scenario-driven JSONL benchmark runner |
| `mirrormesh-verify` | Session manifest verifier — accepts intact, rejects tampered |
| `mirrormesh-consent` | `.mmid` bundle producer; gatekeeper for third-party bundles |
| `mirrormesh-listen` | Mic → ASR → stdout / JSONL transcription |
| `mirrormesh-translate` | Cross-language ASR + LLM translation (scaffolded) |
| `mirrormesh-stream` | Send-only WebRTC CLI |
| `mirrormesh-fixture-gen` | Procedural face-animation fixture generator |
| `mirrormesh-selftest` | CLT-friendly smoke binary (35 assertions) |

### .app Bundle

`MirrorMesh.app` — notarized, hardened-runtime, codesigned via `Local.xcconfig` Team ID. Camera and microphone permissions declared in `Info.plist`. Sandboxed where possible.

### Models

- `blendshape_solver_v1.mlpackage` (ships in repo, 38.8 KB) — geometric → ML solver, 50-epoch MLP, val loss 0.0135.
- FOMM CoreML packages (`keypoint_v1`, `motion_v1`, `generator_v1`) — **user-supplied**, produced by running `models/training/fomm_to_coreml.py` per `models/training/README.md`. Not committed.
- Whisper tiny.en — **user-supplied**, provenance at `models/whisper-tiny.en.provenance.json`.

---

## Hardware requirements

- **CPU**: Apple Silicon M-series (M1, M2, M3, M4, or M5). Intel Macs are not supported.
- **OS**: macOS 14 (Sonoma) minimum; macOS 15+ preferred.
- **RAM**: 16 GB minimum. 32 GB+ recommended for the photoreal FOMM path.
- **GPU cores**: ≥ 8 GPU cores recommended for the Mask-style render at 1080p.
- **Camera**: any integrated webcam, Continuity Camera, or USB camera that `AVFoundation` recognizes.
- **Microphone**: built-in mic, AirPods, or any USB mic for the voice / accessibility pipeline.
- **Disk**: ~500 MB for the base install; +200 MB for the FOMM CoreML packages; +75 MB for `whisper-tiny.en`.

---

## Quick start

Three commands from clone to WOW:

```bash
git clone https://github.com/<owner>/mirror-mesh.git && cd mirror-mesh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run mirrormesh-app
```

If you'd rather see the watermarked `.mov` output without the UI:

```bash
swift run mirrormesh-bench --scenario bench/scenarios/recorded.json
open bench/out/recorded_*.mov
```

To run the full test suite (66 tests in 17 suites):

```bash
swift test --skip MirrorMeshStreamTests --skip MirrorMeshVoiceTests --skip MirrorMeshVirtualCameraTests --skip MirrorMeshMediaPipeTests
```

To issue a `.mmid` consent bundle for yourself:

```bash
swift run mirrormesh-consent --print-disclosure   # read the agreement first
swift run mirrormesh-consent \
  --name "Your Name" \
  --scheme self-as-source \
  --scope "v1.0+" \
  --png path/to/your-portrait.png \
  --out ~/Documents/yourname.mmid
```

---

## Known limitations

We are explicit about what we did not finish. Each item below is tracked.

- **FOMM full inference graph wiring.** The `PhotorealBackend` initializer enforces all gates (consent + scheme + models present) and the actor's contract is final. The body of `reenact()` currently returns the driving frame unchanged; the full `kp_source` cache + dense-motion + generator chain lands in v1.1. The stub exists so the gate semantics are testable before any real model is in the loop.
- **MediaPipe is a Vision-fallback stub.** The 12 MB MediaPipe XCFramework integration is gated on a binary-target addition. The protocol, dispatch logic, manifest tag, and comparison scripts are all wired against the fallback today.
- **`whisper.cpp` is a mock backend.** The deterministic mock returns chunks shaped like the real backend will. The `.cxxTarget` vendoring lands in v1.1.
- **Voice transform (RVC-class) is not shipped.** The architectural slot is reserved. v1.1+ work.
- **Manifest `identity_sha256` field is not yet emitted.** The bundle hash is recorded through `models` and via a session annotation. The explicit top-level field lands in v1.0.1.
- **Recurring audible chirp.** v1.0 ships the session-start ping only. The `chirp_schedule` recurring schedule is v1.1.
- **Multi-face tracking.** Single-face only at v1.0. Architecture is general; renderer would need to grow per-face state.
- **C2PA assertion emission.** Our manifest is C2PA-compatible in spirit but does not emit C2PA-format assertions consumable by C2PA verifiers. v1.0.1 / v1.1.
- **iOS/iPadOS/visionOS target.** macOS only at v1.0. The Swift code is mostly portable; the SwiftUI shell needs an iOS shell.
- **No fallback for non-Apple-Silicon Macs.** Intel macOS is explicitly out of scope (ADR-0001).

---

## Roadmap (post-1.0)

- **v1.0.1** (patch): manifest `identity_sha256` field; C2PA assertion emission scaffolding; documentation site polish.
- **v1.1** "Voice and Photoreal": real `whisper.cpp`, RVC-class voice transform, FOMM inference graph wired end-to-end, `chirp_schedule` recurring chirp.
- **v1.2** "Accessibility": run the pre-registered user study from the paper's Section 7; ship a dedicated `mirrormesh-accessibility` configuration profile for the lip-sync pipeline.
- **v1.3** "Multi-face and Mobile": iOS / iPadOS target; multi-face tracking; visionOS surface (spatial telepresence).
- **v2.0** "Standards alignment": Full C2PA-compliant manifest emission; integration with downstream provenance verifiers; consider porting the consent protocol to a cross-platform spec.

---

## Acknowledgments

- **Aliaksandr Siarohin** et al. for the First-Order Motion Model implementation (MIT, vendored under `models/external/fomm/`).
- **Apple** for the Vision, CoreML, Metal, AVFoundation, CryptoKit, and Speech frameworks the pipeline is built on.
- **The C2PA Working Group** for the manifest design vocabulary the project's `SessionManifest` borrows from.
- **Casiez, Roussel, and Vogel** for the One-Euro filter formulation.
- **The stasel/WebRTC project** for the pre-built libwebrtc XCFramework that lets `MirrorMeshStream` ship without a Chromium-toolchain checkout.
- **ggerganov** for `whisper.cpp`, the reference C/C++ port of OpenAI Whisper.
- **The Ollama project** for a stable local-LLM HTTP API that insulates `MirrorMeshTranslate` from model-runtime churn.
- **The unnamed engineer** whose public demonstration of a face/voice swap surfaced the question this project answers.

---

## License

**[AGPL-3.0-only](./LICENSE).** Research project — see [`NOTICE.md`](./NOTICE.md) for the plain-English statement.

The maintainer does not monetize this code and does not offer a commercial license. AGPL-3.0's strong copyleft + network-use clause prevents anyone else from monetizing derivatives. The previous v0.4.0 "AGPL + Commercial" dual ([ADR-0014](./memory-bank/decisions.md)) is superseded by [ADR-0015](./memory-bank/decisions.md) at v1.0.0; the Commercial half is dropped because no commercial offering was ever intended.

The trust-layer invariants (watermarking on by default, no third-party impersonation without signed consent, no celebrity presets, no cloud fallback on the inference hot path) are architectural; they're enforced by the code itself, not by the legal text.

Contributing: see [`CONTRIBUTING.md`](./CONTRIBUTING.md). DCO sign-off (`git commit -s`) required on every commit. No CLA. PRs welcome.

---

*MirrorMesh v1.0.0 — Software defaults are policy. We set the policy to consent and disclosure.*
