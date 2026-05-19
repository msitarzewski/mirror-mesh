# MirrorMesh — Tech Context

**Last updated**: 2026-05-19

---

## Platform

- **OS**: macOS 14+ (Sonoma minimum; Sequoia / 15+ preferred for `CMIOExtension` maturity)
- **Architecture**: Apple Silicon only (arm64). Intel macOS explicitly out of scope.
- **Devices**: M3 / M4 / M5 family. M1 / M2 supported but not benchmark targets.

## Language & Build

- **Primary**: Swift 5.10+ / Swift 6 once Concurrency-strict mode is comfortable
- **Secondary**: C++ where libraries demand (MediaPipe, libwebrtc bindings)
- **Shaders**: Metal Shading Language (MSL)
- **Scripts**: Python 3.11+ for benchmark harness, model conversion, paper figure generation
- **Build**: Swift Package Manager primary; Xcode project for app shell
- **CI**: GitHub Actions on macOS runners (M-series runners required for end-to-end tests)

## Frameworks (First-Party)

| Layer | Framework | Use |
|-------|-----------|-----|
| Capture | AVFoundation | Camera + audio capture |
| Vision | Vision (`VNDetectFaceLandmarksRequest`) | Default landmark path |
| ML | CoreML | Model inference on Neural Engine |
| GPU | Metal + MetalPerformanceShaders | Rendering, compute |
| Audio | CoreAudio + AVAudioEngine | Realtime audio pipeline |
| Virtual Cam | CoreMediaIO (`CMIOExtension`) | Virtual camera output |
| UI | SwiftUI | Settings, monitoring, consent UI |
| Crypto | CryptoKit | Frame signing, manifest signatures |
| System | os.log, os.signpost | Tracing |

## Frameworks (Third-Party — Candidate List)

Final selection pending evaluation in tasks/2026-05.

- **MediaPipe Tasks** (Apache 2.0) — face landmarker comparison path
- **OpenSeeFace** (BSD-2) — lightweight fallback / comparison
- **LivePortrait** (research license — confirm before depending) — reenactment reference
- **libwebrtc** (BSD) — peer-to-peer streaming
- **Whisper.cpp** (MIT) — local transcription if voice features adopted
- **Piper TTS** (MIT) — local TTS comparison
- **swift-log**, **swift-collections** — utility

Any GPL / non-commercial-restricted dependency is rejected.

## Models

- Curated bundled model set only (no arbitrary downloads at runtime)
- Models distributed as CoreML packages, signed
- Source weights and conversion scripts checked into `models/` with provenance docs
- Each model file has a sidecar `.provenance.json` describing: source, license, training data summary, conversion pipeline, hash

## Telemetry & Power

- `powermetrics` (system tool) for power benchmarks — requires sudo, documented in `build-deployment.md`
- `signpost` markers consumed by Instruments for trace-based latency analysis
- Custom JSONL log format for headless benchmark runs

## Packaging & Distribution

- **Source**: GitHub, public
- **Binary**: Signed `.app` via Developer ID; notarized
- **CLI**: Homebrew tap for `mirrormesh-bench`
- **App Store**: deferred — entitlements for virtual camera and microphone may complicate review

## Versioning

- Semantic version on releases (`MAJOR.MINOR.PATCH`)
- Pre-1.0 during research phase; minor bumps may break APIs
- Model format version separate from app version

## Development Environment

- **Xcode** (current at session date) — full install at `/Applications/Xcode.app`. Required for: `swift test` with `import Testing`, app-bundle builds, Instruments, Metal-shader cached compile path. CLT alone is insufficient from v0.2.0 onward (see ADR-0012).
- Toolchain selection: prefer `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` for persistent setup. CI / scripts that can't sudo should `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before invoking `swift`/`xcrun`.
- `swift-format` for style
- `swiftlint` for lint (warnings non-blocking, errors blocking — see `projectRules.md`)
- `pre-commit` hook checks: lint, format, license headers, no committed model binaries

## Hardware Test Matrix (Target)

| Device | Role | Notes |
|--------|------|-------|
| M4 MacBook Air | Primary thermal-constrained target | Battery + plugged benches both |
| M4 Pro MacBook Pro | Sustained-load target | Should not throttle |
| M3 Mac mini | Headless / CI reference | Continuous benchmark runner |
| M5 Mac Studio | Ceiling reference | Best-case numbers |

iPhone with TrueDepth is reference-only; not a build target.

## What's Not in the Stack

- Python at runtime in the shipped app (Python is dev / bench only)
- CUDA / NVIDIA anything
- Cloud inference SDKs (OpenAI, Anthropic, ElevenLabs, etc.) on inference path
- Electron / web-based UI
- Rosetta-translated dependencies
