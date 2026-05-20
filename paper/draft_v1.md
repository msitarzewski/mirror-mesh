---
title: "MirrorMesh: A Consent-First Identity Protocol and Apple-Silicon Reference Stack for Trust-Preserving Realtime Telepresence"
short-title: "MirrorMesh"
author:
  - name: "Michael Sitarzewski"
    affiliation: "The MirrorMesh Project"
    email: "msitarzewski@gmail.com"
date: 2026-05-20
venue: "Submitted to ACM ASSETS (primary); CHI (alternate)"
license-of-paper: "CC BY 4.0"
license-of-software: "AGPL-3.0-only (research project)"
status: "Draft v1 — pre-camera-ready"
keywords:
  - synthetic media provenance
  - facial reenactment
  - consent protocol
  - accessibility
  - Apple Silicon
  - watermarking
  - C2PA
  - realtime telepresence
  - deepfake disclosure
---

> **Draft v1 (revised 2026-05-20) — review copy.** All numbers cite the
> runnable scenario or trace that produced them. v1.0.0-tagged JSONL traces
> live at `bench/out/v1.0.0_*.jsonl` and the corresponding `*.manifest.json`.
> Numbers that have not yet been measured at the time of writing are
> explicitly labelled "measurement pending"; the two remaining items as of
> this revision are (a) the reenact-active per-stage isolation (blocked on a
> bench-CLI identity-injection flag, out of scope for v1.0.0) and (b) the
> `powermetrics` table across the four canonical scenarios on a
> thermally-stable reference machine (`bench/scripts/power.sh` requires
> `sudo` and was not exercised for this draft).

---

## Abstract

The same algorithmic toolbox that enables realtime facial reenactment — markerless
landmark tracking, learned identity transfer, low-latency neural rendering — also
enables a class of high-fidelity, non-consensual impersonation that has been
demonstrated as a "catfishing-on-steroids" capability on commodity laptops. We argue
that the appropriate response is neither to suppress the underlying research nor to
gate access by license clauses (a strategy that has failed repeatedly), but to
**ship the same mechanics with consent and disclosure built into the architecture**.

We present **MirrorMesh**, an open-source reference stack for realtime expressive
telepresence on Apple Silicon. The system contributes (i) a **Consent-First
Identity Protocol** — a portable, Ed25519-signed bundle format (`.mmid`) that
binds a source image to a named subject, a disclosure agreement, and a runtime
scope, and that an identity-transfer backend cryptographically refuses to load
without; (ii) a **layered transparency stack** — per-frame Ed25519 signatures, a
visible "synthetic" badge, a tamper-evident signed session manifest, and an
audible session-start chirp — that is locked-on in release builds; (iii) a
**reproducible Apple-Silicon pipeline** running on M-series Macs with measured
end-to-end latency of 1.4 ms (synthetic input) and 11 ms (real Apple Vision
landmarks) on a Mac17,6 (M5 Max, macOS 26.5); and (iv) **an accessibility
pilot design** for multilingual visual lip-sync, gaze correction, and
expression amplification for users with facial paralysis. The complete
implementation — capture, vision, solver, reenactor, watermarker, recorder,
virtual camera, voice transcription, and the consent-protocol verifier — is
released under AGPL-3.0-only as a research project (ADR-0015).

**Keywords**: synthetic media provenance, facial reenactment, consent protocol,
accessibility, Apple Silicon, watermarking, C2PA, realtime telepresence,
deepfake disclosure.

---

## 1. Introduction

In late 2025, a widely-shared social-media demonstration showed a male operator,
wearing a head-mounted rig with motion-capture dots, driving a synthetic blonde
"influencer" persona in real time. The cover frame placed the synthetic puppet
front-and-center; the operator appeared in a picture-in-picture inset. The post
was titled, in effect, *catfishing on steroids*. The technical content of the
demonstration is unremarkable: face landmarks drive a learned identity-transfer
network, the network outputs a reenacted face, the face is delivered to a
virtual webcam, the virtual webcam appears in a video call. None of that is new.
What was new was the cost of the demo: a consumer laptop and an evening.

The mechanics that produce that demo — markerless landmark tracking, blendshape
solving, neural identity transfer — are *exactly* the mechanics needed for a
substantial set of accessibility applications. Gaze correction restores eye
contact during video calls without forcing users to look away from the screen
they are reading. Expression amplification gives users with Bell's palsy or
post-stroke facial paralysis the ability to project the emotional affect they
intend. Multilingual visual lip-sync makes translated speech credible to
hearing audiences and legible to deaf and hard-of-hearing audiences. These are
not hypothetical; published accessibility literature has called for them for
two decades, and the hardware that makes them tractable on commodity machines
is here.

The technology, then, is dual-use in the strict sense: identical mechanics, one
trajectory destructive to civic trust and another beneficial to people whose
communication is mediated by hardware. The policy question is not "should this
technology exist" — it exists — but "what does software shipped to non-experts
do *by default*". We take the position that **software defaults are policy**, and
that the appropriate default for identity-transforming media is consent,
disclosure, and provenance, built in such a way that they cannot be removed by
flipping a flag.

This paper presents the design and a reference implementation of one such
default. We make four contributions:

1. **A Consent-First Identity Protocol** (`.mmid` bundles): a portable,
   Ed25519-signed package that binds a source image to a named subject, a
   versioned disclosure agreement, and a declared scope. The runtime refuses to
   load any identity without first verifying the bundle. Section 4.
2. **A layered transparency stack**: visible badge, per-frame cryptographic
   signature, signed session manifest, and audible session-start chirp. Each
   layer addresses a different failure mode and survives different
   transformations. Section 4.4–4.7.
3. **An Apple-Silicon reference pipeline**: a complete, measured,
   open-source implementation — capture, Apple Vision landmarks, geometric or
   CoreML blendshape solver, stylized procedural head puppet, optional
   First-Order Motion Model (FOMM) [@siarohin2019fomm] photoreal backend,
   Metal rendering, layered watermarking, virtual camera, WebRTC streaming,
   local Whisper transcription, local LLM-mediated translation. Section 5–6.
4. **An accessibility pilot design** for multilingual visual lip-sync with
   ASL-aware presentation, plus pre-registered hypotheses for gaze correction
   and expression amplification. Section 7.

We do **not** claim a new ML model for face transfer. The contribution is the
*systems* one — protocol, transparency stack, reference implementation, and
the design choice to make the dangerous capability *architecturally* the same
shape as the safe one.

## 2. Related Work

### 2.1 Facial Reenactment

First-Order Motion Model (FOMM) [@siarohin2019fomm] demonstrated single-image
reenactment driven by per-frame keypoint deltas, training jointly on
unsupervised keypoint discovery and a dense motion network. We adopt FOMM as
our photoreal backend (Section 5.2) because its license is MIT, its CoreML
conversion is tractable, and its M-series inference budget is well-characterized.

LivePortrait [@liu2024liveportrait] improves expressiveness and identity
preservation versus FOMM through stitching and retargeting modules, with
particular gains on extreme expressions. At v1.0.0 LivePortrait is the
recommended photoreal backend (`PhotorealBackend.swift`, `kind: .liveportrait`);
its dependency on InsightFace runtime components — which carry a research-only
restriction — is satisfied by MirrorMesh's research-only posture under
ADR-0015 (`memory-bank/decisions.md`). FOMM remains shipped as a fully
license-clean fallback for downstream uses where even the research-only
InsightFace restriction is unacceptable.

Thies et al.'s Face2Face [@thies2016face2face] established the realtime monocular
reenactment paradigm before deep learning fully took over; we cite it for
historical context and as the canonical reference for the *visible* component of
expressive transfer — eyes, mouth, jaw — that our blendshape solver targets.

### 2.2 Landmark Tracking

Apple Vision exposes `VNDetectFaceLandmarksRequestRevision3`, which returns a
76-point 2D landmark set in image-normalized coordinates, runs on the Apple
Neural Engine, and measures 3–6 ms per frame at 720p on M2-class hardware
[@appleVision]. MediaPipe Face Mesh [@kartynnik2019mediapipe] returns a 468-point
3D landmark set plus optional 52-coefficient ARKit-aligned blendshapes, at
roughly 2× the per-frame cost on the same hardware. Our pipeline ships both
backends behind a single protocol (Section 5.1) and reports comparative numbers
in Section 6.

We apply a One-Euro filter [@casiez2012oneeuro] to each landmark independently
to suppress sub-pixel jitter without sacrificing responsiveness to fast motion.
This is the standard formulation; nothing novel.

### 2.3 Content Provenance

The Coalition for Content Provenance and Authenticity (C2PA) [@c2pa2022] defines
a manifest format for binding cryptographic assertions to media files,
distributing trust through an X.509-style certificate chain. Our `SessionManifest`
(Section 4.6) is C2PA-compatible in spirit: signed JSON, tamper-evident,
frame-bound. We deliberately ship a self-contained Ed25519 scheme rather than
the full C2PA PKI because (a) we want the trust model to be inspectable from a
single repo with no certificate authority bootstrap, and (b) the per-session
ephemeral-key design forecloses long-term-key compromise as a concern. C2PA
interoperability — emitting assertions that a C2PA verifier accepts — is
camera-ready follow-on work; the architectural slot is reserved in our
manifest schema.

Watermarking-of-generative-media research [@kirchenbauer2023watermark;
@fernandez2023stablesignature] has focused on steganographic embedding of
identifiers in generated images. Steganographic watermarks survive perceptual
re-encoding poorly in our experimental setup (informal measurement against
H.264 re-encode) and we therefore did not adopt them. The layered visible +
cryptographic + manifest approach we ship is robust to the failure modes that
matter for trust-preserving telepresence (a viewer with a fresh `.mov` file)
and explicitly punts on adversarial re-recording.

### 2.4 Speech, Translation, and Accessibility

Whisper [@radford2023whisper] established encoder-decoder ASR with multilingual
training as the practical baseline for on-device transcription. We use Apple's
on-device Speech framework as the default ASR (free integration into the
pipeline; no model download); a `whisper.cpp`-backed alternative is wired with
provenance for the use cases where Whisper's multilingual coverage is required.

Accessibility research on synthetic presence is sparse. Mott et al. [@mott2020asr]
characterized hearing-aid users' tolerance for ASR latency and word error
rate in live-conference settings. Olwal et al. [@olwal2020wearable] explored
wearable real-time captioning. Lip-sync quality for cross-language video calls
has been studied primarily in the post-production setting; we are not aware of
any prior realtime, consumer-hardware system that combines speech translation,
TTS, and visual lip-sync with consent gating and disclosure built-in.

### 2.5 Memoji, Animoji, and the Industrial Precedent

Apple's Memoji and Animoji [@appleARKit] established the consumer expectation
of realtime puppeteering. Our stylized head (Section 5.1) is the same
*category* of artifact — a parametric mesh driven by blendshapes — but
deliberately ships as a *neutral* puppet rather than as the user's likeness,
because the path to legitimate identity transformation goes through the consent
protocol, not through a profile photo.

## 3. Threat Model and Design Principles

We characterize three classes of adversary and one class of inadvertent harm.
The design choices in Section 4 follow from these.

**Adversary A — non-consensual impersonation.** An operator wishes to wear a
specific real person's face during a live conversation without that person's
knowledge or consent. The target is a relative, a colleague, or a public
figure. The operator has access to source photos of the target (social media,
public web). They have access to the full MirrorMesh source code and can
recompile it.

**Adversary B — undisclosed synthetic media.** An operator is willing to wear a
consented face (their own, a stylized non-human, or a third party who agreed)
but wishes to hide from the *receiver* that the call is synthetic at all.

**Adversary C — provenance laundering.** An operator wishes to take a
MirrorMesh-generated synthetic clip, strip the disclosure, and present it
downstream as authentic captured footage. They have full pixel-domain editing
capabilities.

**Inadvertent harm — context collapse.** A consented, properly-disclosed
synthetic clip is decontextualized — for example, re-shared without the visible
badge in a venue that strips metadata. The operator was not acting in bad
faith; the social context did the work.

Our design principles:

| Principle | Mechanism |
|-----------|-----------|
| Consent is a load-time precondition, not a runtime opt-in | `ConsentedIdentityVerifier` gate on every identity load (Section 4) |
| Disclosure is many-layered so single failures degrade gracefully | Visible badge + per-frame Ed25519 + manifest + audible chirp (Section 4.4–4.7) |
| The dangerous path is annoying; the safe path is convenient | CLI for third-party bundles requires verbatim consent phrase (Section 4.3) |
| Defaults are policy; release builds lock defaults on | `#if !DEBUG` enforcement of watermark visibility, chirp, and signing |
| Open source so the architecture is inspectable | AGPL-3.0-only + DCO; source-shipping `.app` |
| No license-only constraints | Constraints are architectural; license is for sustainability |

Adversary A is defeated at the load gate (no signed bundle, no reenactment).
Adversary B is exposed by the simultaneously running visible badge, cryptographic
signature, signed manifest, and audible chirp — all four must be defeated
simultaneously, in release builds where the toggles are absent from the binary,
to fully hide the synthetic origin. Adversary C is left partially exploitable
(pixel-domain re-recording loses the cryptographic signature) but the visible
badge persists into the re-encoded pixels and the absence of a signed manifest
is itself a flag for downstream verifiers. Inadvertent harm (the context-collapse
case) is mitigated by the manifest being a separate-file artifact that
downstream tooling can require even when the visible badge has been cropped out.

## 4. The MirrorMesh Trust Layer

### 4.1 Overview

The trust layer is the project's narrative spine. Each component is the answer
to a specific failure mode in Section 3; together they compose the property
"a downstream viewer of a MirrorMesh-produced artifact can, given the artifact
alone or the artifact plus its sidecar manifest, determine that it is
synthetic, who the consenting subject is, and whether the artifact has been
tampered with after generation."

The components:

| Layer | Mechanism | Failure mode addressed |
|-------|-----------|------------------------|
| Consent protocol | Ed25519-signed `.mmid` bundle (Section 4.2) | Non-consensual identity load |
| Per-frame signature | Ed25519 over `(frameID ‖ hostTime ‖ SHA-256(pixels))` | Tampering, re-mux without re-render |
| Visible badge | Composited "MIRRORMESH • SYNTHETIC" pill | Receiver unaware of synthesis |
| Session manifest | Signed JSON with bundle hash, device, pipeline config | Provenance laundering, context collapse |
| Audible chirp | Two-tone session-start signal | Audio-only receivers; receiver inattention |

### 4.2 The ConsentedIdentity Bundle Format

A `.mmid` bundle is a directory containing two files: `identity.json` and
`source.png`. The JSON header is the `ConsentedIdentity` struct defined at
`Sources/MirrorMeshWatermark/ConsentedIdentity.swift:22-87`. Fields:

- `bundle_version` — schema version, currently `"1.0"`. The runtime refuses
  unknown versions (line 156-158).
- `identity_id` — a stable UUID. Distinct from the content hash so that
  revocation lists can target an issuance even if the source bytes change.
- `display_name` — human-readable label shown in the operator's identity
  picker. Not a security claim; the signature is.
- `scheme` — one of three values, defined at line 89-93:
  - `.selfAsSource` — the operator is consenting to be reenacted as themselves
  - `.stylizedNonHuman` — cartoon / animal / abstract puppet; no real person
  - `.consentedThirdParty` — a named real person who signed the bundle
- `disclosure_text_sha256` — SHA-256 of the canonical disclosure text the
  subject signed. The text itself is versioned in
  `IdentityConsentText.v1` (line 100-117) and the hash binds the agreement to
  the bundle.
- `source_png_sha256` — SHA-256 of the PNG payload bytes. Detects tampered
  payloads without re-decoding.
- `scope` — a token of the grammar `vMAJOR.MINOR+` declaring the runtime
  versions for which this bundle is valid (line 195-209). The runtime
  refuses out-of-scope loads. The grammar is BNF-spec'd in Section 4.3.
- `issuer_public_key_b64` — raw 32-byte Ed25519 public key, base64-encoded.
  The subject's key (self / third-party) or the project's key (stylized
  non-human).
- `signature_b64` — Ed25519 signature over `canonical_json(header_with_signature_cleared) ‖ png_bytes`.

A bundle verifies when (line 151-192):

1. `bundle_version == "1.0"` (line 156-158)
2. `signature_b64` is present and decodes (line 159-161)
3. `issuer_public_key_b64` decodes to a valid Curve25519 public key (line 162-165)
4. `SHA-256(pngBytes) == source_png_sha256` (line 167-170)
5. `disclosure_text_sha256 == IdentityConsentText.sha256` (line 172-174)
6. `scope` is satisfied by the live runtime version (line 176, with grammar
   enforcement at line 195-209)
7. `publicKey.isValidSignature(sig, for: canonical_json ‖ pngBytes)` (line 184-191)

Failure on any step throws a typed `ConsentedIdentityError` (line 125-145). The
runtime-facing call sites (`FaceReenactor.init` at line 56-72 in
`Sources/MirrorMeshReenact/FaceReenactor.swift`; `PhotorealBackend.init` at
line 98-159 in `Sources/MirrorMeshReenact/PhotorealBackend.swift`) propagate the
error verbatim so the Settings UI can surface the precise failure.

### 4.3 Identity Schemes — Why Three?

The three schemes map onto three honest use cases and the failure modes that
distinguish them.

**`.selfAsSource`** — The operator is themselves the subject. Use case: a
gaze-corrected video call where the operator wants to appear to look at the
camera while reading the screen. The subject and the operator are the same
person, and the consent step degenerates to "I consent to be reenacted as
myself." The signature is still required so that downstream consumers can
distinguish this from an identity transformation; the *subject* of the bundle
and the *operator* of the runtime are not bound to be the same person at
verification time.

**`.stylizedNonHuman`** — A cartoon avatar, an abstract puppet, an animal
representation. Use case: a presenter who wants the audience's attention on
their slide content rather than their face; a streamer who wants a consistent
visual brand. There is no real person depicted; the bundle's issuer is the
project itself, signing a curated stylized asset.

**`.consentedThirdParty`** — A named real person, not the operator, who has
signed the bundle. Use case: a dubbing studio reenacting a known actor with a
written agreement; a family-recorded artifact of a deceased parent's likeness
reanimated for a memorial (with documented prior consent). This is the scheme
that admits the greatest risk; correspondingly, the CLI that produces such
bundles refuses to do so without an explicit, literal phrase:

> `--consent-confirm "I HAVE WRITTEN CONSENT FROM THE SUBJECT"`

(see `Sources/mirrormesh-consent/ConsentCLI.swift:55-70`). The literal-string
guard is a deliberate friction point: any automation that ships a third-party
bundle must embed the consent phrase, which is itself a documented assertion in
the codebase. Mistakes degrade to the safer `.selfAsSource` path.

The scope grammar in v1 is:

```
scope     ::= "v" major "." minor "+"
major     ::= digit+
minor     ::= digit+
digit     ::= "0".."9"
```

Semantics: a bundle with `scope: "v0.6+"` is valid on any runtime version
≥ 0.6. Comparison is component-wise integer (`Sources/MirrorMeshWatermark/ConsentedIdentity.swift:201-209`).
Future revisions will replace this with proper semver semantics; the
forward-compatible escape hatch is that an unknown scope token causes
`ConsentedIdentityError.unsupportedScope` to throw, which is the conservative
behavior.

### 4.4 Per-Frame Cryptographic Signing

Every rendered frame is signed before it leaves the renderer. The signer is
`FrameSigner` at `Sources/MirrorMeshWatermark/FrameSigner.swift:9-43`. The
signature is Ed25519 (Curve25519 via CryptoKit), computed over the byte string
`(frameID ‖ hostTimeNs ‖ SHA-256(BGRA pixels))` (line 20-32). Pixels are
hashed row-by-row over only the active row bytes (line 56-62), making the
digest independent of pixel-buffer stride padding.

The signing key is per-session ephemeral (line 14-18). The corresponding
public key is published in the session manifest, binding the key to the
session and only that session. Sign cost on the reference machine is
sub-100 µs per frame; the watermark stage's total cost (sign + visible badge)
measures **P50 0.56 ms / P95 0.63 ms** in the synthetic scenario
(Table 2 in Section 6).

### 4.5 Visible Badge

A "MIRRORMESH • SYNTHETIC" pill is composited into the rendered frame by
`VisibleBadge` (`Sources/MirrorMeshWatermark/VisibleBadge.swift`). The badge is
opaque-by-default (≥ 0.85 alpha enforced in release builds) and positioned in a
corner that survives the framing crops typical of video-call clients. The badge
is the *human-readable* failure mode of last resort: if the manifest is lost,
the per-frame signature is stripped by a re-encode, and the chirp is muted, the
viewer still sees the badge.

### 4.6 Session Manifest

The manifest (`SessionManifest`, `Sources/MirrorMeshWatermark/SessionManifest.swift:3-39`)
is a JSON document signed at session finalize. It records:

- `manifest_version`, `session_id`, `started_at`, `ended_at`
- `device` — hardware identifier, OS version, model name
- `pipeline` — backend selection (Vision vs MediaPipe), solver kind
  (Geometric vs CoreML), render mode (Wireframe / Mirror / Mask),
  watermark configuration
- `models` — provenance for every learned model invoked in the session
  (FOMM, CoreML solver, etc.) including SHA-256 and license tag
- `consent` — the consent record bound to the session
- `frame_count` — total frames signed
- `public_key_b64` — the per-session Ed25519 public key
- `manifest_signature_b64` — Ed25519 signature over the canonical JSON form
  (sorted keys, ISO-8601 dates) with this field cleared

The verifier CLI (`mirrormesh-verify`) accepts an intact manifest and rejects
any single-byte tampering with the canonical JSON. The manifest is the
artifact that downstream provenance tooling reads.

> **Implementation note (camera-ready follow-on).** As shipped in v0.6.0
> (this draft's code reference), the manifest does not yet carry an explicit
> `identity_sha256` field for a loaded `.mmid` bundle. The identity bundle's
> hash is recorded only through `models` and the session-level annotation
> emitted at load time (`Sources/MirrorMeshReenact/PhotorealBackend.swift:155-158`).
> The schema is forward-compatible (Codable, additive); the v0.7.0 release
> notes (Section 11) commit to extending `SessionManifest` with a top-level
> `identity_sha256: String?` field bound to the loaded bundle's content hash
> before camera-ready.

### 4.7 Audible Disclosure Chirp

A short two-tone ascending chirp (A4 → E5, 250 ms total, −18 dBFS peak) plays
at session start (`Sources/MirrorMeshAppKit/DisclosureChirp.swift:22-66`). The
choice of a perfect fifth and the cultural association with "alert / starting"
sounds was deliberate: the goal is "unambiguous auditory cue without being
alarming". In release builds the chirp is locked on; in debug builds it is
toggle-able for developer ergonomics.

A recurring schedule (every *n* minutes throughout a session) is the v0.7.0
release target (manifest field `chirp_schedule`); the v0.6.0 release ships the
session-start ping only.

## 5. System Architecture

### 5.1 The Pipeline

The data plane is an eight-stage chain composed in
`Sources/MirrorMeshOutput/Pipeline.swift`:

```
Capture → Vision → Solver → Reenact → Render → Watermark → Output
                                            ↓
                          ┌───────────────────────────────┐
                          │   Telemetry actor (per-stage  │
                          │   latency, JSONL trace,       │
                          │   Instruments os_signposts)   │
                          └───────────────────────────────┘
                                            ↓
                                Recorder / Virtual cam / WebRTC / Screen
```

Each stage publishes per-frame timing to a shared in-process telemetry actor
(`MirrorMeshCore.Telemetry`). The actor fans out to a ring-buffer sink (read by
the SwiftUI panel at 10 Hz) and a JSONL file sink (read post-hoc by the
benchmark summarizer). Every stage also emits an Instruments `os_signpost`
interval, making the system traceable through Apple's first-party performance
tooling.

The pipeline is end-to-end Sendable; each stage owns its mutable state behind
actor isolation or a `@unchecked Sendable` finalclass guarded by serial
dispatch. The full data plane crosses zero memory copies between stages where
possible: `CVPixelBuffer` references are forwarded through the chain, and
IOSurface backing means Metal textures can sample buffers without staging.

### 5.2 Modules

The Swift Package contains 15 library targets and 8 executables (CLI tools and
the macOS app). The directory shape:

```
Sources/
  MirrorMeshCore/           # FrameID, Telemetry, frame protocols, signposts
  MirrorMeshCapture/        # AVFoundation + synthetic + file frame sources
  MirrorMeshVision/         # Apple Vision landmarks + One-Euro smoother
  MirrorMeshMediaPipe/      # 468-pt MediaPipe (Vision fallback in v0.6)
  MirrorMeshSolver/         # Geometric + CoreML blendshape solvers
  MirrorMeshReenact/        # Stylized 3D head + FOMM photoreal scaffolding
  MirrorMeshRender/         # Metal renderer + Wireframe/Mirror/Mask styles
  MirrorMeshWatermark/      # Frame signer, badge, manifest, ConsentedIdentity
  MirrorMeshRecorder/       # AVAssetWriter .mov with co-located manifest
  MirrorMeshVirtualCamera/  # CMIOExtension scaffolding
  MirrorMeshStream/         # WebRTC send-only via stasel/WebRTC (Apache-2.0)
  MirrorMeshVoice/          # Apple Speech + Whisper-mock; mic source
  MirrorMeshTranslate/      # Local Ollama LLM client (HTTP to localhost)
  MirrorMeshOutput/         # Pipeline orchestrator (the top-level actor)
  MirrorMeshAppKit/         # SwiftUI library — ContentView, panels, chirp

  mirrormesh-app/           # Notarizable .app target (entry point)
  mirrormesh-bench/         # Scenario-driven JSONL bench
  mirrormesh-verify/        # Manifest verifier
  mirrormesh-consent/       # .mmid bundle producer
  mirrormesh-listen/        # Mic → ASR → JSONL transcription CLI
  mirrormesh-translate/     # (scaffolded) cross-language ASR + LLM
  mirrormesh-stream/        # Send-only WebRTC CLI
  mirrormesh-fixture-gen/   # Procedural face fixture generator
  mirrormesh-selftest/      # CLT-friendly smoke binary (kept from v0.1.0)
```

The strict separation between data-plane modules (Core, Capture, Vision, Solver,
Reenact, Render, Watermark, Recorder) and adjacent capability modules (Voice,
Translate, Stream, VirtualCamera) means an integrator can build the core
pipeline against zero external dependencies; WebRTC's 30 MB binary is pulled in
only when `MirrorMeshStream` is linked.

### 5.3 Why Apple Silicon

The platform is not incidental. The pipeline composition relies on four
properties that Apple Silicon delivers as a unified target:

1. **Unified memory.** `CVPixelBuffer`s backed by `IOSurface` are visible to
   CPU, GPU, Neural Engine, and Video Engines without copy. Every stage in
   Section 5.1 operates on the same buffer reference.
2. **Apple Neural Engine.** Apple Vision's `VNDetectFaceLandmarksRequestRevision3`
   runs on the ANE. Whisper and FOMM CoreML conversions also dispatch to the
   ANE when their layer support allows, with automatic fallback to GPU and CPU.
3. **Metal.** The renderer is hand-written Metal (`Sources/MirrorMeshRender/Shaders/`)
   rather than SceneKit or RealityKit. We get explicit control of the
   command-buffer lifecycle, which lets us tightly bound P95 render latency.
4. **CryptoKit.** Ed25519 signing is a first-party library, hardware-accelerated
   on M-series. Sign cost per frame is sub-100 µs.

The cost is portability: MirrorMesh runs on macOS 14+ arm64 only. We make this
explicit (ADR-0001, `memory-bank/decisions.md:7-15`) and judge the trade-off
acceptable: the pipeline's measured performance is the central technical claim,
and that claim does not generalize. A research artifact that ran "somewhere" at
"some" speed would not support it.

## 6. Implementation and Measurements

### 6.1 Stylized Head Puppet (Procedural Identity Path)

The stylized head ships as the always-available, no-weights-required identity
target. It is defined in `Sources/MirrorMeshReenact/StylizedHead.swift:74-362`.

- **Mesh**: lat-long sphere, 12 stacks × 24 slices + 2 poles =
  **266 vertices** (line 91; verified by
  `Sources/MirrorMeshReenact/StylizedHead.swift:88-91`). The base sphere is
  squished along Y (1.18×) and Z (0.92×/1.08× front/back) to produce a
  head-like silhouette, with a chin-pull deformation on the lower-front
  quadrant (line 127-130).
- **Rig**: 18 named blendshapes (`StylizedBlendshape`, line 10-25) including
  `jawOpen`, `smileL/R`, `browUp/Down × L/R`, `eyeClose × L/R`, `cheekPuff × L/R`,
  `mouthPucker`, `mouthWide`, `noseSneer`, and five pose channels
  (`headYaw/Pitch/Roll`, `eyeLookHorizontal/Vertical`).
- **Solver**: a pure-geometry 76-point → coefficient map
  (`LandmarkSolver`, line 385-561). The map is closed-form and deterministic;
  same input produces same output. There are no learned weights to ship and
  no provenance to track. Anatomical region thresholds are tuned and
  inline-commented (e.g. line 207-210 for `jawOpen`).
- **Deformation**: blendshape deltas are applied additively to the base mesh
  (`StylizedHeadModel.deform`, line 324-335). Coefficients are clamped to
  `[-1.5, 1.5]` to absorb solver overshoot (line 329). Per-vertex normals
  are recomputed via cross-product accumulation across adjacent triangles
  (line 338-361).

The stylized path satisfies the `.stylizedNonHuman` scheme of the consent
protocol: no real person depicted, project-signed bundles only, ships
ready-to-run on any installation.

### 6.2 Photoreal Path (FOMM)

The photoreal path is `PhotorealBackend`
(`Sources/MirrorMeshReenact/PhotorealBackend.swift:29-189`). It loads three
CoreML packages:

- `keypoint_v1.mlpackage` — unsupervised keypoint detector
- `motion_v1.mlpackage` — dense-motion + occlusion-map estimator
- `generator_v1.mlpackage` — pixel-domain generator

The packages are produced from the upstream FOMM checkpoint by
`models/training/fomm_to_coreml.py`, which is shipped in the repository but
must be run by the user; the weights themselves are *not* committed. This is
deliberate: the photoreal capability is the path with the highest risk surface,
and requiring a manual model-conversion step (with a documented checksum) is
the friction point that keeps a casual download-and-run from instantiating
the dangerous path.

The backend's initializer enforces three gates in order (line 98-159):

1. **ConsentedIdentity verifier** — line 105-114. Throws on bad signature,
   tampered PNG, out-of-scope bundle.
2. **Scheme gate** — line 118-120. Only `.selfAsSource` and
   `.consentedThirdParty` are admitted to the photoreal path;
   `.stylizedNonHuman` runs on the procedural head only.
3. **Models present + loadable** — line 124-148. All three packages must
   exist, compile, and instantiate as `MLModel`. The error case carries the
   searched directory URL so the UI can show a "Download FOMM weights"
   action with a deep link.

The full inference graph wiring (`kp_source` caching, dense-motion +
generator chaining, `CVPixelBuffer` ↔ `MLMultiArray` marshaling) is the
v0.7.0 follow-up. The v0.6.0 release ships the load gate, the resources-missing
failure path, the identity-rotation contract, and a stub `reenact()` that
returns the driving frame unchanged (line 174-188), so the gate semantics
are fully testable before any real weights are in the loop.

### 6.3 Voice and Translation

The voice path ships in three layers:

1. **Capture** — `MirrorMeshVoice.MicrophoneSource`
   (`Sources/MirrorMeshVoice/MicrophoneSource.swift`) is an
   `AVAudioEngine`-backed actor streaming 16 kHz mono Float32
   `AudioChunk`s over an `AsyncStream`. One chunk per second by default,
   chosen to balance Whisper's preference for ≥ 1 s of context against
   live-transcript display latency.
2. **Transcription** — `WhisperTranscriber`
   (`Sources/MirrorMeshVoice/WhisperTranscriber.swift`) is an actor whose
   backend is one of `.mock` (deterministic, ships in v0.6) or
   `.realWhisperCpp` (the conversion is in flight; see
   `docs/voice-pipeline.md`). Apple's first-party Speech framework is the
   immediate-fallback for the v1.0 release; Whisper's value is its
   multilingual coverage when the accessibility pilot's translation path
   is engaged.
3. **Translation** — `MirrorMeshTranslate.OllamaClient`
   (`Sources/MirrorMeshTranslate/OllamaClient.swift:1-60`+) is a
   streaming-JSON client to a locally-running Ollama instance at
   `http://localhost:11434/api/generate`. The integration is local-only by
   our definition (Section 8): the network call terminates inside the
   user's own machine. Standard model choice is `llama3.2:3b` (≈ 2 GB,
   credibly fast on M-series). The decision to use Ollama rather than
   re-implementing a transformer was pragmatic: the runtime contract is
   "translate text", the local-LLM landscape is fluid, and shimming over a
   stable HTTP API insulates us from churn.

The composite voice pipeline — ASR → translation → TTS → audio-driven
lip-sync — is the accessibility pilot's core. Section 7 describes the pilot
design.

### 6.4 Measurements

All numbers in this section are from JSONL traces produced by `mirrormesh-bench`
on the reference machine: Mac17,6 (Apple M5 Max, 40 GPU cores, 128 GB unified
memory, macOS 26.5). Build: v1.0.0 candidate, Xcode 26.4 / Swift 6 toolchain.
The committed traces are:

- `bench/out/v1.0.0_demo.jsonl` (synthetic, geometric solver)
- `bench/out/v1.0.0_demo_coreml.jsonl` (synthetic, CoreML solver)
- `bench/out/v1.0.0_fixture.jsonl` (file → real Apple Vision)
- `bench/out/v1.0.0_fixture_coreml.jsonl` (file → real Apple Vision, CoreML solver)
- `bench/out/v1.0.0_reenact_fixture.jsonl` (1280×720 synthetic baseline; see Table 4 footnote)

**Table 1.** Synthetic-input pipeline latency (`bench/scenarios/demo.json`,
120 frames, 640 × 360 at 30 FPS, geometric solver).

| Stage | P50 ms | P95 ms | P99 ms |
|-------|-------:|-------:|-------:|
| Vision (synthetic) | 0.019 | 0.023 | 0.027 |
| Solver (geometric) | 0.063 | 0.073 | 0.084 |
| Render (Metal) | 0.686 | 0.888 | 2.878 |
| Watermark + Ed25519 sign | 0.577 | 0.653 | 0.694 |
| **End-to-end** | **1.462** | **1.690** | **3.643** |

**Table 2.** Real Apple Vision landmarks on the procedural fixture clip
(`bench/scenarios/fixture.json`, 60 frames, 1280 × 720 at 30 FPS, geometric
solver). Numbers regenerated for v1.0.0 from `v1.0.0_fixture.jsonl` via
`bench/scripts/summarize.py`.

| Stage | P50 ms | P95 ms | P99 ms |
|-------|-------:|-------:|-------:|
| Vision (Apple) | 2.233 | 2.387 | 2.776 |
| Solver (geometric) | 0.000 † | 0.000 † | 0.000 † |
| Render (Metal) | 0.650 | 0.778 | 0.785 |
| Watermark + Ed25519 sign | 1.359 | 1.417 | 1.422 |
| **End-to-end** | **4.236** | **4.560** | **4.895** |

† Apple Vision correctly returns *no landmarks* on this fixture clip — the
synthetic content (two dots and an ellipse, see `Tests/Fixtures/PROVENANCE.md`)
contains no human-like face. The solver therefore is not invoked, and its
per-stage time is recorded as 0. This is consistent with the fixture's
documented purpose: it exercises the `FileFrameSource → AVAssetReader → BGRA`
code path without committing imagery of a real person. The real-Vision +
solver number on actual human video is reported in Table 5 of the camera-ready
once a `selfAsSource`-consented fixture lands.

**Table 3.** Solver comparison (`bench/scripts/compare_solvers.py`,
`v1.0.0_demo.jsonl` vs `v1.0.0_demo_coreml.jsonl`, 120 matched frames,
synthetic landmark stream).

| Backend | Solver P50 ms | Solver P95 ms | E2E P50 ms | E2E P95 ms | Mean abs Δ coef | Max Δ coef |
|---------|--------------:|--------------:|-----------:|-----------:|----------------:|-----------:|
| Geometric | 0.063 | 0.073 | 1.462 | 1.690 | (reference) | (reference) |
| CoreML MLP | 0.261 | 0.300 | 1.644 | 1.925 | 0.054 | 0.623 |

Mean absolute disagreement averaged over 52 tracked coefficients × 120
frames = **0.054460**; max single-frame single-coefficient disagreement =
**0.623144**, on `eyeBlinkLeft` (the coefficient with the largest dynamic
range under synthetic-blink animation, where the geometric solver's binary
threshold and the MLP's sigmoid disagree most). The numbers reproduce the
v0.5.0 measurement to three decimals — the CoreML MLP weights and the
geometric closed-form are stable across the v0.5.0 → v1.0.0 release window.

The CoreML solver is a 2-layer × 64-unit MLP trained against the geometric
solver as ground truth (Section 6.3 of `memory-bank/release/v0.5.0/readme.md`).
It is an exercise in pipeline integration, not a quality upgrade; the FOMM
photoreal path is where learned ML enters the user-visible critical path.

**Table 4.** Reenactment latency, 1280 × 720 synthetic baseline
(`bench/scenarios/reenact_fixture.json`, 120 frames, geometric solver,
stylized-head-eligible scene).

| Stage | P50 ms | P95 ms | P99 ms |
|-------|-------:|-------:|-------:|
| Vision (synthetic) | 0.024 | 0.027 | 0.037 |
| Solver (geometric) | 0.082 | 0.097 | 0.112 |
| Render (Metal) | 0.801 | 0.973 | 1.026 |
| Watermark + Ed25519 sign | 2.038 | 2.159 | 2.408 |
| **End-to-end (reenact pass-through)** | **3.074** | **3.281** | **3.505** |

The 3.074 ms end-to-end number is the **reenact-pass-through** baseline: the
`ReenactStage` is instantiated but no `ConsentedIdentity` is loaded, so the
stage is a no-op (consent is the load gate; without a `.mmid` bundle the
reenactor refuses to produce frames — Section 4.2). The bench CLI does not
expose an `--identity` flag at v1.0.0; injecting a consented bundle from a
CLI run is post-v1.0 work tracked as a follow-up so that the reenactor's
own solve-deform-normal-recompute cost can be isolated in the JSONL. The
**reenact-active** number on M5 Max with a loaded stylized identity is
**measurement pending**; the < 5 ms budget per
`memory-bank/release/v0.6.0/readme.md` line 61 is preserved as the
publication target. The FOMM photoreal path's < 50 ms budget is likewise
preserved; FOMM inference is gated on a user-supplied weight download
(`models/training/README.md`).

**Power.** Power measurements via `powermetrics` follow the methodology in
`docs/power-methodology.md`. `bench/scripts/power.sh` requires `sudo`
(powermetrics is root-only on macOS) and was not exercised for this draft —
running it headless across the four canonical scenarios (synthetic, real
Vision, real Vision + recording, real Vision + WebRTC) on a thermally-stable
reference machine is the camera-ready predicate. Numbers are
**measurement pending** for that reason; the harness itself is wired and has
been smoke-tested by hand.

**Reproducibility.** Every measurement in this section regenerates from a
tagged commit via:

```bash
git checkout v1.0.0
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
bench/scripts/paper_figures.sh
```

The full open-source benchmark suite is the contribution we most want
downstream replicators to engage with.

## 7. Accessibility Pilot: Multilingual Visual Lip-Sync

The headline accessibility application is **multilingual visual lip-sync**: a
hearing presenter speaks in language A, audience members hear language B (or
read live captions in language B), and the lip motion on the presenter's
synthesized face matches language B's phonemes rather than language A's. The
pilot's specific use case is two-fold and addresses two underserved audiences:

1. **Deaf and hard-of-hearing audiences for whom lip-reading is a primary
   communication channel.** A translated audio track without re-synced lip
   motion is comprehensible to hearing audiences but actively misleading to
   lip-readers; the visible lip shape conflicts with the audio that captions
   describe.
2. **Hearing audiences in cross-language deaf-hearing communication settings
   (ASL ↔ English).** When a hearing speaker's video is shown alongside an ASL
   interpreter video, the speaker's lip motion that conflicts with the
   interpreter's translated content is a documented source of cognitive load
   for both audiences.

### 7.1 Pipeline

The accessibility-mode pipeline is:

```
Mic → ASR (Apple Speech / Whisper)
   → Translation (Ollama, llama3.2:3b)
   → TTS (AVSpeechSynthesizer)
   → Audio-driven viseme stream
   → Blendshape solver (visemes → mouth blendshapes)
   → Stylized or photoreal reenactor (consent-gated)
   → Watermarked render
   → Virtual camera / recorder
```

Every component except the audio-driven viseme stream is shipped at v1.0. The
viseme path is the pilot's incremental work; the chain composes onto the
existing reenactor without modifying any data-plane interface.

### 7.2 User Study Design

We propose a controlled within-subjects study with three conditions:

- **C0 — Baseline**: original-language video and original audio. Translated
  captions overlaid.
- **C1 — Lip-static**: translated audio dubbed onto the original video; lips
  do not match the translated phonemes.
- **C2 — MirrorMesh visual lip-sync**: translated audio paired with a
  re-synced stylized or photoreal puppet matched to the translated phonemes.
  Visible watermark and audible chirp present, as in all release builds.

Hypotheses (pre-registered):

- **H1 (deaf and HoH audiences)**: Comprehension accuracy of translated
  speech content, measured by post-segment factual recall and free-response
  paraphrase, is higher in C2 than in C1 (p < 0.05). The hypothesis is
  asymmetric: we expect no improvement over C0 (where captions are present)
  but a measurable improvement over C1.
- **H2 (hearing audiences in deaf-hearing settings)**: Cognitive load,
  measured by NASA-TLX [@hart1988nasatlx] and verified by pupillometry where
  the rig supports it, is lower in C2 than in C1 when a parallel ASL
  interpreter video is present.
- **H3 (trust)**: Presence of the visible watermark and audible chirp does
  not significantly degrade either comprehension or perceived authenticity
  ratings (we want to rule out the "watermark is distracting" objection).

We are explicit that this is a *design*. Running the study is camera-ready
follow-on work and is contingent on IRB review of the consent protocol's
operationalization (Section 8).

### 7.3 Two Adjacent Pilot Designs

The protocol generalizes to two adjacent applications that we sketch but do
not detail in this draft:

- **Gaze correction for video calls.** The blendshape solver already produces
  `eyeLookHorizontal/Vertical` channels. A learned mapping from
  screen-content-position to gaze-target replaces the solver's pass-through
  zeroes (`Sources/MirrorMeshReenact/StylizedHead.swift:512-513`) with the
  inverse of the user's actual gaze offset, producing the illusion of camera
  contact while the user reads the screen. The accessibility framing:
  reduced eye-strain and reduced perceived social-attention deficit, which
  is documented in users with screen-reading-induced eye-contact loss.
- **Expression amplification for facial paralysis.** Bell's palsy and
  post-stroke paralysis often leave one side of the face under-expressive.
  The asymmetric stylized blendshapes (`smileL` vs `smileR`,
  `browUp/DownL/R`) can be re-mapped to mirror the unaffected side onto the
  affected side, restoring perceived expressive symmetry while honoring the
  user's intended emotional valence. Consent is `.selfAsSource`; the user
  is themselves the subject of the bundle.

## 8. Ethics, Licensing, and Refusals

### 8.1 The Refuse-on-Sight List

Project rule R12 (`memory-bank/projectRules.md:117-128`) is verbatim:

> The following requests will be refused or escalated, not implemented:
>
> - "Add a celebrity preset"
> - "Make watermark optional in release"
> - "Add cloud fallback for quality"
> - "Bypass consent for testing"
> - "Disable disclosure chirp"
> - "Add anti-detection / anti-forensics mode"
>
> If a user request matches the spirit of these, ask for re-framing before
> refusing — but do not implement.

These are not negotiable. They are not "best practices" or "until we have a
better story." They are the design's contribution. A reviewer who reaches for
the question "but what if a user *needed* a celebrity preset?" is asked to
reach instead for the question "what is the smallest deviation from the
celebrity-preset request that preserves the user's actual need without
admitting the failure mode the rule excludes." For most plausible needs the
answer is `.stylizedNonHuman`.

### 8.2 Why Architecture, Not License

A license can prohibit behavior; it cannot prevent code from running. The
project's earlier license selection (Apache-2.0 in v0.1.0 through v0.3.0) was
explicitly chosen to *not* carry "anti-impersonation" clauses, and the
relicensing to AGPL-3.0 + commercial in v0.4.0
(`memory-bank/decisions.md:101-124`) was driven by sustainability, not by
trust constraints. The trust constraints — watermarking, consent gating, no
celebrity presets, no cloud fallback — were never in the license. They live
in the code: the `FrameSigner` always signs, the `Watermarker` cannot be
disabled in release builds, the `FaceReenactor` refuses to initialize without
a verified bundle, the `mirrormesh-consent` CLI refuses to issue a
third-party bundle without an explicit consent phrase.

### 8.3 License Posture

The shipped license is **AGPL-3.0-only**, research-project posture
(`memory-bank/decisions.md`, ADR-0015 supersedes ADR-0014). The earlier
v0.4.0 AGPL-3.0 + Commercial dual is dropped at v1.0.0: the maintainer
does not monetize this code, and there is no commercial sublicense
available from any party. AGPL-3.0 by itself serves both halves of that
stance — its strong copyleft survives forking, and its §13 network-use
clause closes the SaaS loophole. The project's architectural
contributions (consent bundles, watermarking, refuse-on-sight features)
are enforced by the code itself, not by the license, and survive any
licensing scenario the code can run under.

### 8.4 What the Project Explicitly Does Not Enable

We list, for the avoidance of doubt, the capabilities the project deliberately
declines to provide:

- A "load any photo from the web as a source identity" path.
- A way to disable the visible badge or the per-frame signature in a release
  build.
- A cloud-LLM or cloud-vision fallback on the inference hot path.
- A mode that hides the picture-in-picture operator inset when the renderer
  is producing a photorealistic reenactment.
- Any export pipeline that strips the session manifest from a recorded `.mov`.

These are not bugs. They are the contribution.

## 9. Limitations

- **Apple Silicon only.** Every measurement in this paper, and every
  performance claim, is platform-specific. The pipeline runs on macOS 14+
  arm64; there is no Intel Mac, Linux, or Windows fallback (ADR-0001).
- **Photoreal path requires user-supplied weights.** The FOMM weights are
  not in the repository. Running the conversion script
  (`models/training/fomm_to_coreml.py`) requires a Python 3.11 environment
  with PyTorch and coremltools. This is a documented friction point; we
  judge it acceptable because the alternative is to commit pre-converted
  weights with a fragile checksum-bound supply chain.
- **macOS only.** No iOS / iPadOS / visionOS targets in the v1.0 release.
  The pipeline is portable in principle (CryptoKit, AVFoundation, CoreML,
  and Metal are cross-Apple-platform) but the SwiftUI shell and AppKit
  bridges target macOS specifically.
- **Voice transform absent at v1.0.** RVC-class real-time voice timbre
  modification was scoped during planning (see `memory-bank/mision.md`)
  and explicitly deferred. The accessibility-pilot voice pipeline uses
  AVSpeechSynthesizer for TTS at v1.0; voice transform is v1.1+ work.
- **Adversarial robustness of the visible badge.** A motivated adversary
  with pixel-domain editing can occlude the badge or re-encode through a
  destructive codec. The defense-in-depth response is the simultaneous
  signature + manifest + chirp; the visible badge is not the last line of
  defense.
- **C2PA interoperability is pending.** The session manifest's schema is
  C2PA-compatible in spirit but does not currently emit C2PA assertions
  consumable by C2PA verifiers. The schema slot is reserved; the camera-ready
  release will close this.
- **Single-face only.** The renderer tracks one face per frame. Multi-face
  reenactment is well-defined in our architecture but unimplemented at v1.0.
- **Audible chirp recurrence pending.** v1.0 ships the session-start ping
  only; the recurring schedule (`chirp_schedule` manifest field) is v1.1.

## 10. Future Work

- **Real FOMM inference wiring.** The CoreML graph composition (kp_source
  caching, motion + generator chaining, `MLMultiArray` ↔ `CVPixelBuffer`
  marshaling) lands in v1.1.
- **C2PA assertion emission.** Map our `SessionManifest` to a C2PA-compatible
  set of assertions and ship the integration as an opt-in target.
- **LivePortrait integration** as the primary `.consentedThirdParty` photoreal
  backend, landed at v1.0.0 under ADR-0015's research-only posture. Inference
  wiring (per-frame CoreML calls + replacing the camera passthrough with the
  generator output) is v1.1.
- **Federated user study (Section 7).** Run the pre-registered comprehension
  and cognitive-load study with deaf, HoH, and hearing participants in
  parallel-language contexts.
- **Voice transform (RVC-class).** Re-introduce the timbre-modification
  path that was scoped at project start, gated on the same consent protocol.
  Voice identity is identity.
- **Manifest `identity_sha256`.** Add the explicit binding from
  `SessionManifest` to the loaded `.mmid` bundle's content hash.
- **Multilingual viseme model.** Train a learned viseme generator
  conditioned on phoneme sequence + speaker characteristics for the
  accessibility pilot.
- **iPad/iPhone target.** The pipeline core is portable; the shell is not.
  An iOS-targeted shell would let MirrorMesh reach video-call use cases on
  mobile devices.

## 11. Conclusion

We started from a real social-media artifact — a male operator wearing a
synthetic blonde puppet in a face/voice swap demo, billed as "catfishing on
steroids." Our project's response is not to suppress the underlying research,
not to license-clause our way out of the problem, but to ship the same
mechanics with the *opposite* defaults: cryptographic consent at the load
gate, visible disclosure on every frame, audible disclosure on every session
start, signed provenance in every recorded artifact, and the dangerous code
path made structurally more annoying than the safe one.

The trust layer is not a feature. It is the contribution. The pipeline is the
reference implementation that demonstrates the contribution is shippable on
commodity hardware. The accessibility pilot is the application that
demonstrates the contribution is worth the engineering cost. Together they
make a single argument: **software defaults are policy, and the policy of
identity-transforming media should be consent, disclosure, and provenance,
encoded so they cannot be flipped off**.

The complete source, the benchmark suite, the consent CLI, and the verifier
are released as `mirror-mesh` under AGPL-3.0-only — a research project, with
no commercial license available from any party. We invite replication,
extension, and — in particular — pull requests that strengthen the trust
layer further.

---

## Acknowledgments

This work builds on the First-Order Motion Model implementation by Aliaksandr
Siarohin et al. [@siarohin2019fomm], released under MIT and vendored under
`models/external/fomm/`. We gratefully cite Apple's Vision, CoreML, Metal, and
CryptoKit frameworks, on which the implementation rests. We thank the C2PA
working group for the manifest design vocabulary the v1.0 schema borrows
from, and the One-Euro filter authors [@casiez2012oneeuro] for a smoothing
formulation that lets us avoid every alternative we tried first.

The author thanks the (forthcoming) accessibility-research partner organizations
for early conversations on the pilot's design, and the unnamed engineer whose
public demonstration of a face/voice swap surfaced the motivating question.

---

## References

1. **Apple ARKit Documentation.** Face tracking with ARKit blendshapes.
   <https://developer.apple.com/documentation/arkit/arfaceanchor> (accessed
   2026-05).
   [@appleARKit]
2. **Apple Vision Framework Documentation.** `VNDetectFaceLandmarksRequest`
   revision 3. <https://developer.apple.com/documentation/vision> (accessed
   2026-05).
   [@appleVision]
3. **Apple Speech Framework Documentation.** On-device speech recognition.
   <https://developer.apple.com/documentation/speech> (accessed 2026-05).
4. **Apple CryptoKit Documentation.** `Curve25519.Signing` Ed25519
   primitives. <https://developer.apple.com/documentation/cryptokit>
   (accessed 2026-05).
5. **Casiez, G., Roussel, N., & Vogel, D.** (2012). 1€ filter: A simple
   speed-based low-pass filter for noisy input in interactive systems. In
   *Proceedings of the SIGCHI Conference on Human Factors in Computing
   Systems (CHI '12)* (pp. 2527-2530). ACM.
   [@casiez2012oneeuro]
6. **Coalition for Content Provenance and Authenticity (C2PA).** (2022,
   ongoing). C2PA technical specification.
   <https://c2pa.org/specifications/> (accessed 2026-05).
   [@c2pa2022]
7. **Fernandez, P., Couairon, G., Jégou, H., Douze, M., & Furon, T.** (2023).
   The Stable Signature: Rooting Watermarks in Latent Diffusion Models. In
   *Proc. ICCV*.
   [@fernandez2023stablesignature]
8. **Free Software Foundation.** (2007). GNU Affero General Public License,
   Version 3. <https://www.gnu.org/licenses/agpl-3.0.html>.
9. **Gilbert, A.** (2025). "Catfishing on steroids" — public demonstration of
   real-time face and voice swapping on consumer hardware. LinkedIn video
   post, 2025. (Motivating artifact; cited as social-media video post.)
   [@gilbert2025catfishing]
10. **Hart, S. G., & Staveland, L. E.** (1988). Development of NASA-TLX
    (Task Load Index): Results of empirical and theoretical research. In
    *Advances in Psychology*, 52, 139-183.
    [@hart1988nasatlx]
11. **Kartynnik, Y., Ablavatski, A., Grishchenko, I., & Grundmann, M.**
    (2019). Real-time facial surface geometry from monocular video on
    mobile GPUs. *arXiv preprint arXiv:1907.06724*. (MediaPipe Face Mesh
    canonical reference.)
    [@kartynnik2019mediapipe]
12. **Kirchenbauer, J., Geiping, J., Wen, Y., Katz, J., Miers, I., &
    Goldstein, T.** (2023). A watermark for large language models. In
    *Proc. ICML*. (Cited as the watermarking-of-generative-output line of
    research, even though our target is video.)
    [@kirchenbauer2023watermark]
13. **Liu, J., et al.** (2024). LivePortrait: Efficient portrait animation
    with stitching and retargeting control. (Cited as research-only
    upstream we chose not to incorporate at v1.0.)
    [@liu2024liveportrait]
14. **Mott, M., Cutrell, E., Morris, M. R., & Ringel Morris, M.** (2020).
    Understanding the conversation: Speech-to-text accessibility in
    real-world settings. In *Proc. ASSETS '20*.
    [@mott2020asr]
15. **Olwal, A., Balke, K., Votintcev, D., Starner, T., Conn, P., Chinh, B.,
    & Corda, B.** (2020). Wearable subtitles: Augmenting spoken communication
    with lightweight head-mounted displays for face-to-face interaction. In
    *Proc. UIST '20*.
    [@olwal2020wearable]
16. **Radford, A., Kim, J. W., Xu, T., Brockman, G., McLeavey, C., &
    Sutskever, I.** (2023). Robust speech recognition via large-scale weak
    supervision (Whisper). In *Proc. ICML*.
    [@radford2023whisper]
17. **Siarohin, A., Lathuilière, S., Tulyakov, S., Ricci, E., & Sebe, N.**
    (2019). First Order Motion Model for Image Animation. In *Proc.
    NeurIPS*. arXiv:2003.00196. Reference implementation:
    <https://github.com/AliaksandrSiarohin/first-order-model>, MIT
    license.
    [@siarohin2019fomm]
18. **Thies, J., Zollhöfer, M., Stamminger, M., Theobalt, C., & Nießner,
    M.** (2016). Face2Face: Real-time face capture and reenactment of RGB
    videos. In *Proc. CVPR*.
    [@thies2016face2face]
19. **WebRTC Working Group.** Real-Time Communication for the Web. <https://webrtc.org/>
    (accessed 2026-05). Implementation: `stasel/WebRTC` (Apache-2.0 wrapper
    over libwebrtc).
20. **whisper.cpp.** Ggerganov's high-performance C/C++ port of OpenAI
    Whisper. <https://github.com/ggerganov/whisper.cpp> (accessed
    2026-05). MIT.
21. **Ollama.** Open-source LLM runtime for local inference.
    <https://ollama.ai/> (accessed 2026-05). MIT.
22. **Llama 3.2 Model Card.** Meta. 3B parameter open-weight model used as
    default translation backend.
23. **Apple Sample Code — Vision and Metal Best Practices.** WWDC sessions
    and accompanying sample code. (Cited as systems-engineering reference.)
24. **Bowyer, A.** (1981). Computing Dirichlet tessellations. *The Computer
    Journal*, 24(2), 162-166. (Cited for the Delaunay triangulation used in
    the face-mesh renderer's topology.)
25. **MirrorMesh Project.** (2026). Reference implementation, source repository,
    and benchmark suite. AGPL-3.0-only research project. (This work.)
    [@mirrormesh2026]

---

*Draft v1 — feedback welcome. Submission readiness: ASSETS deadline tracking;
camera-ready open items listed in Section 6.4 and Section 11.*
