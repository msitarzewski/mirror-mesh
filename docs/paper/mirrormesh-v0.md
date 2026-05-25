---
title: "MirrorMesh: Realtime Expressive Telepresence Using Commodity Apple Silicon"
subtitle: "Local-only, watermark-by-default, consent-gated"
author: "The MirrorMesh Project Authors"
date: 2026-05-19
toc: true
geometry: margin=1in
---

> **Draft v0 — internal review.** All numbers in this draft come from runnable scenarios in `bench/scenarios/`. To regenerate: `bench/scripts/paper_figures.sh`.

## Abstract

We present MirrorMesh, an open-source realtime expressive-telepresence system running entirely on Apple Silicon. The system captures camera frames, extracts facial landmarks via Apple Vision (or, optionally, MediaPipe Face Mesh), solves for ARKit-compatible blendshape coefficients, renders a watermarked composite via Metal, and outputs to a virtual camera or local file. Every output frame carries a visible disclosure badge, an Ed25519 signature, and an entry in a tamper-evident session manifest. The full pipeline achieves P50 latencies of 1.4 ms (procedural input) and 5.1 ms (real-Vision path against a procedural fixture) on a Mac17,6 (Apple M5 Max). We argue that the combination of (i) commodity Apple hardware, (ii) local-only inference, and (iii) cryptographic transparency moves synthetic-presence research out of the "deepfake tool" framing into a defensible accessibility-and-trust framing suitable for academic publication.

**Keywords**: realtime facial reenactment, blendshape solving, synthetic media transparency, Apple Silicon, accessibility, telepresence

---

## 1. Introduction

Three converging conditions in 2026 motivate this work:

1. **Hardware**. Apple Silicon's unified memory + Neural Engine + Metal stack delivers sub-100ms local inference at HD without specialized motion-capture hardware.
2. **Capture quality**. Apple-platform integrated webcams, post the Continuity Camera era, produce stable face-landmarks without markers.
3. **Trust crisis**. Synthetic-media generation is ubiquitous; provenance and transparency infrastructure is underdeveloped.

The combination admits a *commodity, local, transparent* stack that, to our knowledge, no prior work has delivered as an open reference implementation.

We do **not** present a new ML model for face transfer. We present a systems contribution: an end-to-end measurable pipeline that ships an open-source benchmark suite, a verifiable watermark layer, and reproducible latency/power numbers on consumer hardware. We also argue for a disciplined framing of synthetic presence as accessibility infrastructure, not deepfake tooling.

## 2. Related Work

- **Face reenactment.** LivePortrait (Liu et al., 2024) and First-Order Motion Model (Siarohin et al., 2019) demonstrate single-image-driven reenactment. Both require GPU inference; neither ships with built-in transparency or consent gating.
- **ARKit blendshapes.** Apple's ARKit exposes a 52-coefficient face-tracking surface tied to TrueDepth hardware. We adopt the same coefficient schema for compatibility but compute it from monocular RGB landmarks.
- **Synthetic media provenance.** C2PA (2022, ongoing) standardizes content provenance manifests. Our session-manifest format is C2PA-compatible in spirit (signed, tamper-evident, frame-bound) but uses a self-contained Ed25519 scheme rather than the full PKI required by C2PA assertions.
- **Open-source realtime facial tools.** OBS plugins, OpenSeeFace, VTube Studio target hobbyist audiences on Windows; none publish reproducible latency benchmarks on Apple hardware.

## 3. System Architecture

The pipeline is an eight-stage chain (Fig. 1):

```
Capture → Landmarks → Solver → Renderer → Watermark → Output
            │
            ├── Vision (default) or MediaPipe Face Mesh (M26)
            ├── Geometric or CoreML solver (M18, M27)
            └── Virtual camera (M24) / WebRTC stream (M25) / .mov recorder (M14)
```

Each stage publishes per-frame latency to a shared telemetry bus (in-process actor with attachable sinks). The default sinks are a JSONL file logger (paper-grade trace) and an in-memory ring buffer (live UI). Instruments `os_signpost` intervals are emitted at every stage for trace-based attribution.

### 3.1 Capture

`AVCaptureSession` with explicit format selection (1280×720@60 default). Locked exposure / white balance / focus once the session stabilizes for benchmark reproducibility. Frames flow as `CVPixelBuffer` references backed by `IOSurface`, enabling zero-copy Metal texture creation downstream.

### 3.2 Landmark extraction

`VNDetectFaceLandmarksRequest` (revision 3) yields a 76-point set in image-normalized coordinates. A per-landmark, per-axis One-Euro filter (Casiez et al., CHI 2012) suppresses jitter while staying responsive to fast motion. A second backend (`MediaPipeLandmarkBackend`) is selectable via scenario config; it projects MediaPipe's 468-point output down to our 76-point schema. In v0.3.0 the MediaPipe backend defaults to a Vision-fallback when the MediaPipe binary is not bundled; this lets the protocol surface ship without forcing the 12 MB dependency.

### 3.3 Blendshape solving

Two implementations conforming to a single `ExpressionSolver` protocol:
- **GeometricSolver** — closed-form mapping from landmark deltas (vs a 30-frame neutral-pose calibration) to ARKit-52 coefficients. Hysteresis and per-coefficient smoothing applied. Coefficients not derivable from monocular 2D (e.g. `tongueOut`, `eyeLookIn/Out`) are emitted as zero, never fabricated.
- **CoreMLSolver** — a small MLP (2 hidden layers × 64 units, ReLU, sigmoid output) trained on synthetic landmark configurations paired with rule-derived coefficients. Falls back to the geometric solver when the `.mlpackage` is absent.

### 3.4 Rendering

Raw Metal — no SceneKit / RealityKit. Three render passes:
1. Passthrough of the captured `CVPixelBuffer` (sampled as a Metal texture via `CVMetalTextureCache`).
2. Instanced landmark sprites for debug overlay.
3. Parametric cartoon-face mask driven by blendshape coefficients (toggleable).

Output is an `IOSurface`-backed `CVPixelBuffer` consumed by both the watermark stage and the display.

### 3.5 Trust layer

Every synthetic frame carries three independent disclosures:
1. **Visible badge** — "MIRRORMESH • SYNTHETIC" composited into a corner. Configurable position; opacity ≥ 0.85 enforced in release builds.
2. **Cryptographic frame signature** — Ed25519 (CryptoKit) over `(frameID || hostTimeNs || SHA-256(BGRA pixels))`. Per-session ephemeral key; public key published in the session manifest.
3. **Signed session manifest** — JSON with device, pipeline configuration, consent record, frame count, and an Ed25519 signature over the canonical JSON form. Tampering with any field causes the bundled `mirrormesh-verify` tool to reject the manifest.

### 3.6 Output

Three sinks, all driven from `WatermarkedFrame`s:
- **Screen** (SwiftUI `MTKView` preview)
- **Recorder** — `AVAssetWriter` writing H.264/HEVC `.mov` with a co-located signed manifest
- **Virtual camera** — `CMIOExtension` system extension publishing "MirrorMesh" as a device the OS treats as a real webcam
- **WebRTC stream** — one-way send via libwebrtc Swift bindings

## 4. Evaluation

All numbers in this section come from JSONL traces produced by `mirrormesh-bench`. Hardware: Mac17,6 (Apple M5 Max, 128 GB RAM, macOS 26.5). Build: v0.3.0 development tag, Xcode-bundled Swift 6.3 toolchain.

### 4.1 Per-stage latency

**Synthetic-everything scenario** (`bench/scenarios/demo.json`, 120 frames, 640×360@30):

| Stage | P50 ms | P95 ms | P99 ms |
|-------|-------:|-------:|-------:|
| Vision (synthetic backend) | 0.017 | 0.019 | 0.030 |
| Solver (geometric) | 0.061 | 0.071 | 0.103 |
| Render (Metal) | 0.729 | 0.968 | 1.038 |
| Watermark + Ed25519 sign | 0.562 | 0.625 | 0.753 |
| **End-to-end** | **1.408** | **1.643** | **4.587** |

**Real-Vision scenario** (`bench/scenarios/fixture.json`, 60 frames, 1280×720@30, procedural fixture clip):

| Stage | P50 ms | P95 ms | P99 ms |
|-------|-------:|-------:|-------:|
| Vision (Apple) | (varies) | | |
| Solver (geometric) | (varies) | | |
| Render (Metal) | (varies) | | |
| Watermark | (varies) | | |
| **End-to-end** | **5.12** | **5.12** | **5.12** |

Figures in `docs/figures/`: `latency_by_stage.pdf`, `e2e_distribution.pdf`, `per_session.pdf` (generated by `bench/scripts/figures.py`).

### 4.2 Power

Power measurements via `bench/scripts/power.sh` (wraps `powermetrics`, requires sudo). Methodology in `docs/power-methodology.md`. Numbers for this draft: **to be filled** once the user runs the power harness on the reference machine.

### 4.3 Backend comparisons

- **Geometric vs. CoreML solver** (`bench/scripts/compare_solvers.py`): mean per-coefficient absolute disagreement is bounded by the MLP's training-time convergence; the model approximates the geometric solver (not an upgrade in quality, an alternative for future model-driven work).
- **Vision vs. MediaPipe landmark backends** (`bench/scripts/compare_landmarks.py`): in v0.3.0 the MediaPipe backend falls back to Vision when the MediaPipe XCFramework is absent. Once the binary is bundled, this section quantifies the latency/fidelity tradeoff.

### 4.4 Trust-layer overhead

Watermarking adds **0.56 ms P50** to the end-to-end frame budget (synthetic scenario). The visible badge composite is the dominant cost; Ed25519 signing of the per-frame digest is sub-100 µs.

### 4.5 Reproducibility

Every number in this section is regenerated by `bench/scripts/paper_figures.sh`. Commit-tagged scenarios + JSONL traces are committed to `bench/baselines/`. Anyone with a Mac17,6-class device should reproduce within thermal variance.

## 5. Trust-Layer Design

Section 3.5 summarized the three layers; this section describes the threat model and design rationale.

**Threat model.** We assume a downstream consumer who receives a `.mov` file (or live stream) and wants to know whether it is synthetic and whether it has been tampered with after generation. We do **not** defend against adversaries who can re-record the screen — that's intentional; pixel-faithful re-recording loses the cryptographic signature, and the visible badge survives by design.

**Why Ed25519.** Fast signing (sub-100 µs per frame), 64-byte signatures, 32-byte public keys. CryptoKit ships with Apple platforms. Per-session ephemeral keys avoid long-term key management; the public key is the manifest's `public_key_b64` field.

**Why three layers.** Each layer addresses a different failure mode:
- Visible badge — human-readable disclosure; survives codec re-encoding.
- Crypto signature — machine-verifiable; binds frame to session.
- Session manifest — exogenous record; verifiable independent of the media itself.

A future revision will integrate with C2PA assertions for cross-tool interoperability.

## 6. Limitations

- **No real-face fixture in CI.** The shipped fixture clip is a 26 KB procedural cartoon. Vision detects no face in it, so the file-source path exercises plumbing but not detection quality. A consented-likeness fixture is v0.4.0 work.
- **CoreML solver weights approximate the geometric solver.** Training on synthetic data + geometric labels means the ML solver is an exercise in pipeline integration, not a quality improvement. v0.4.0 would train against captured ARKit ground-truth.
- **MediaPipe backend currently falls back to Vision.** The MediaPipe XCFramework adds ~12 MB; the v0.3.0 release surfaces the protocol and dispatch logic but defers binding the binary.
- **Voice pipeline ships transcription only.** Voice transform (RVC-class) and TTS (Piper-class) are out of scope.
- **No identity-transfer model.** LivePortrait / FOMM integration is explicitly deferred — these models carry research-only licensing terms that conflict with Apache-2.0 distribution.
- **Single-face only.** Multi-face tracking is v0.4.0+.

## 7. Discussion

We chose to frame MirrorMesh as accessibility infrastructure rather than deepfake tooling for three reasons:

1. **Defensibility.** A peer reviewer evaluating "synthetic presence on commodity hardware, with consent and watermarking" can engage with the technical claims. A reviewer evaluating "deepfake app #482" is reaching for the desk-reject button.
2. **Architectural constraint.** Watermarking-by-default, refusal-on-sight of celebrity presets, and consent-gated identity loads define what the tool *is* — they are not policy bolted on top.
3. **Practical applications.** Facial-paralysis compensation, gaze correction, multilingual lip-sync, telepresence-fatigue reduction. These are socially defensible and technically rich.

We also argue that "open source with architectural constraints" beats "anti-open-source morality clauses." Constraint-by-architecture is testable; constraint-by-license has a history of failing both legally and culturally.

## 8. Conclusion

MirrorMesh shows that the hardware moment for trust-preserving realtime telepresence on consumer Apple Silicon has arrived. The contributions of v0.3.0 are: (i) a reference pipeline with measured sub-2-ms synthetic E2E latency, (ii) a three-layer cryptographic trust scheme integrated into the realtime path, and (iii) a reproducible open-source artifact under Apache-2.0 with explicit architectural constraints against impersonation use.

## 9. Reproducibility Checklist

- **Code**: this repository at the v0.3.0 tag
- **License**: Apache 2.0
- **Hardware**: Mac17,6 (Apple M5 Max) — comparable: any M3/M4/M5 with ≥ 36 GB RAM
- **OS**: macOS 14.5 minimum; tested on 26.5
- **Toolchain**: Xcode-bundled Swift 6.3
- **Reproduction**:
  ```bash
  git clone https://github.com/msitarzewski/mirror-mesh.git && cd mirror-mesh
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  swift test
  swift run mirrormesh-bench --scenario bench/scenarios/demo.json
  swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
  python3 bench/scripts/figures.py bench/out/*.jsonl
  swift run mirrormesh-verify --manifest bench/out/demo_*.manifest.json
  ```
- **Figures**: `docs/figures/{latency_by_stage,e2e_distribution,per_session}.pdf`

---

*Draft v0 — feedback welcome via GitHub issues. Submission readiness is v0.4.0+ work.*
