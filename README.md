# MirrorMesh

![CI](https://github.com/msitarzewski/mirror-mesh/actions/workflows/ci.yml/badge.svg)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Research only](https://img.shields.io/badge/use-research%20only-orange.svg)](./NOTICE.md)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black.svg)](./memory-bank/decisions.md)
[![DCO](https://img.shields.io/badge/DCO-required-orange.svg)](./CONTRIBUTING.md)

**Realtime expressive telepresence for Apple Silicon, with consent and disclosure built into the architecture.** MirrorMesh ships the same realtime face-reenactment mechanics as a generic deepfake stack, but with a Consent-First Identity Protocol at the load gate, layered cryptographic disclosure on every frame, and an audible signal at every session start. Software defaults are policy. We set the policy to consent.

---

## What does it look like

No demo media has been published yet — the live `mirrormesh-app` window is the demo. Public screenshots and a recorded session video are planned for a follow-up release once the photoreal path's performance lands its 25-30 fps target (see [`CHANGELOG.md`](./CHANGELOG.md) for the latest progress).

The shipped app shows your face transformed in the hero view, the source camera as a small picture-in-picture inset, a telemetry panel with per-stage P50/P95/P99 latency histograms, and a watermark hero card with a pulsing green dot when signing is live.

## Quick start

Requires macOS 14+, Apple Silicon, and a full Xcode install (Command Line Tools alone is no longer sufficient as of v0.2.0; see [ADR-0012](./memory-bank/decisions.md)).

```bash
git clone https://github.com/msitarzewski/mirror-mesh.git && cd mirror-mesh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test --skip MirrorMeshStreamTests --skip MirrorMeshVoiceTests --skip MirrorMeshVirtualCameraTests --skip MirrorMeshMediaPipeTests
swift run mirrormesh-app
```

Headless variants (no camera needed):

```bash
# All-synthetic, watermarked, signed manifest
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-verify --manifest bench/out/demo_*.manifest.json

# Real Apple Vision against the bundled procedural fixture
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json

# Record a watermarked .mov + sidecar manifest
swift run mirrormesh-bench --scenario bench/scenarios/recorded.json
open bench/out/recorded_*.mov
```

## Why does this exist

A widely-shared 2025 demo showed a male operator wearing a synthetic blonde "influencer" puppet in a live video swap, billed as *catfishing on steroids*. The mechanics that produce that demo are also the mechanics that enable real accessibility wins: gaze correction for people who lose eye contact while reading the screen, expression amplification for users with facial paralysis, and multilingual visual lip-sync for cross-language deaf-hearing communication. The technology is dual-use. The policy question is what software does **by default**.

We take the position that the appropriate default for identity-transforming media is consent at the load gate, disclosure on every frame, and provenance in every recorded artifact — encoded so they cannot be flipped off with a flag. Constraints by architecture, not by license.

## Architecture

```
Capture (AVFoundation / Synthetic / File)
  → Vision (Apple Vision 76-pt landmarks + One-Euro filter / MediaPipe 468-pt)
  → Solver (Geometric closed-form / CoreML MLP, both conform to ExpressionSolver)
  → Reenact (Stylized 266-vertex procedural head / FOMM photoreal — consent-gated)
  → Render (Metal — Passthrough + Landmarks + Mesh + AvatarMask + Style picker)
  → Watermark (Visible badge + Ed25519 frame signature)
  → Output (Screen / .mov Recorder / Virtual camera CMIOExtension / WebRTC send)
  ╰── Session manifest (signed JSON, tamper-evident)
  ╰── JSONL telemetry trace + Instruments os_signpost intervals
  ╰── Audible disclosure chirp (session start)
```

**Modules** (under `Sources/`):

| Module | Role |
|--------|------|
| `MirrorMeshCore` | Frame types, telemetry actor, JSONL logger, signposts |
| `MirrorMeshCapture` | `FrameSource` protocol; Live, Synthetic, File sources |
| `MirrorMeshVision` | Apple Vision landmarks + One-Euro smoother |
| `MirrorMeshMediaPipe` | 468-pt MediaPipe backend (Vision-fallback in v1.0) |
| `MirrorMeshSolver` | `ExpressionSolver`; Geometric + CoreML implementations |
| `MirrorMeshReenact` | Stylized 3D head puppet + `PhotorealBackend` (FOMM scaffold) |
| `MirrorMeshRender` | Metal renderer; Wireframe / Mirror / Mask styles |
| `MirrorMeshWatermark` | Ed25519 signer, badge, manifest, `ConsentedIdentity` |
| `MirrorMeshRecorder` | `AVAssetWriter`-based watermarked `.mov` |
| `MirrorMeshVirtualCamera` | `CMIOExtension` scaffolding |
| `MirrorMeshStream` | WebRTC send-only (opt-in target) |
| `MirrorMeshVoice` | `MicrophoneSource` + `WhisperTranscriber` |
| `MirrorMeshTranslate` | Local Ollama LLM client |
| `MirrorMeshOutput` | Top-level `Pipeline` orchestrator |
| `MirrorMeshAppKit` | SwiftUI library + disclosure chirp |

**Performance** (Mac17,6 / Apple M5 Max / macOS 26.5):

| Scenario | Mode | E2E P50 ms |
|----------|------|-----------:|
| `demo.json` | synthetic | **1.4** |
| `fixture.json` | file → real Apple Vision | **5.1** |
| Live camera + Vision (interactive) | live | **~11** |

Full per-stage tables in [`paper/draft_v1.md`](./paper/draft_v1.md) Section 6.4.

## The trust layer

Every frame leaving the renderer carries:

1. **Visible "MIRRORMESH • SYNTHETIC" badge** composited into the frame
2. **64-byte Ed25519 signature** over `(frameID ‖ hostTimeNs ‖ SHA-256(BGRA pixels))` — `Sources/MirrorMeshWatermark/FrameSigner.swift:20-32`
3. **Signed session manifest** (canonical JSON, sorted keys, ISO-8601 dates) recording device, pipeline config, models with provenance, frame count, and consent record — verifiable via `mirrormesh-verify`
4. **Audible chirp** at session start (A4 → E5, 250 ms, locked-on in release builds)

Identity transformations additionally require a verified `ConsentedIdentity` bundle (`.mmid`):

- Ed25519-signed JSON header + PNG payload
- Three identity schemes: `.selfAsSource`, `.stylizedNonHuman`, `.consentedThirdParty`
- Scope grammar `vX.Y+` enforces runtime-version compatibility
- The reenactor refuses to initialize without verification — `Sources/MirrorMeshReenact/FaceReenactor.swift:56-72`
- The third-party CLI flow requires a literal consent phrase — `Sources/mirrormesh-consent/ConsentCLI.swift:55-70`

The full protocol spec is in [`docs/CONSENT_PROTOCOL.md`](./docs/CONSENT_PROTOCOL.md).

## Project status

**v1.0.0 candidate.** Production-ready for: the synthetic mesh-overlay path (Wireframe / Mirror / Mask styles), the stylized procedural head reenactor, the consent bundle protocol, the layered watermark, the recorder, the bench harness, and the CLI tools. Alpha for: the FOMM photoreal path (load gate complete, inference graph wiring is v1.1), `whisper.cpp` (mock backend ships; real `.cxxTarget` lands v1.1), MediaPipe (Vision-fallback ships; XCFramework lands v1.1), C2PA emission, multi-face tracking.

Full known-limitations list in [`RELEASE_NOTES_v1.0.0.md`](./RELEASE_NOTES_v1.0.0.md).

## Contribute

PRs welcome. We use [DCO sign-off](./CONTRIBUTING.md) (Linux-kernel-style); no CLA. Every commit needs `git commit -s`.

The project's load-bearing rules live in [`memory-bank/projectRules.md`](./memory-bank/projectRules.md) — please read R1 (no third-party identity spoofing), R2 (watermarking mandatory), R3 (local-only inference), and R12 (refuse-on-sight list) before opening a PR that touches the trust layer.

## License

**[AGPL-3.0-only](./LICENSE).** Research project — see [NOTICE.md](./NOTICE.md) for the plain-English statement of intent.

The maintainer does not monetize this code and does not offer a commercial license. AGPL-3.0's strong copyleft + network-use clause prevents anyone else from monetizing derivatives. If you fork it, your fork is AGPL too; if you host it as a service, you must publish your source.

The trust-layer invariants (R1 / R2 / R12) are architectural and survive licensing. They're enforced by the code, not by the legal text.

History: Apache-2.0 in v0.1.0 through v0.3.0; AGPL-3.0 + Commercial dual at v0.4.0 ([ADR-0014](./memory-bank/decisions.md)); simplified to AGPL-3.0-only at v1.0.0 ([ADR-0015](./memory-bank/decisions.md)).

---

*Realtime telepresence with the receipts. © 2026 Michael Sitarzewski.*
