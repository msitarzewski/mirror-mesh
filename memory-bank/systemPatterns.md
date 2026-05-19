# MirrorMesh — System Patterns

**Last updated**: 2026-05-19 (initial scaffold)

---

## High-Level Pipeline

```
Camera (AVFoundation)
  → Landmark Detection (Vision / MediaPipe)
  → Expression Solver (blendshape coefficients)
  → Identity Transfer / Avatar (CoreML model)
  → Metal Renderer
  → Watermark + Disclosure Compositor
  → Virtual Camera Output (WebRTC / OBS-compatible)

Microphone (CoreAudio)
  → Voice Activity Detection
  → Optional Voice Transform (local model)
  → Disclosure Chirp / Marker
  → Audio Output
```

**Invariant**: every output frame and audio block passes through the watermark / disclosure stage. Bypass is a build-time, not runtime, capability (and disabled by default in distributed builds).

---

## Architectural Patterns

### Pattern: Local-First Inference

**Context**: All ML inference must run on-device.

**Rule**: No model invocation may make a network call at inference time. Network access is permitted for model downloads (during install / opt-in update), telemetry (opt-in only), and disclosed peer-to-peer streaming.

**Validation**: A `local_only` build flag must be honored — when set, the process refuses to start any network socket except WebRTC streaming (which is the user's own output, not inference).

**Why**: Privacy, latency, reproducibility of benchmarks.

### Pattern: Transparency-By-Default

**Context**: Synthetic media output without transparency erodes the project's defensibility.

**Rule**: Every synthetic output frame carries:
1. A **visible** disclosure badge (configurable position, never fully removable in default builds)
2. A **cryptographic** signature in metadata (frame-level)
3. A **session manifest** record (tamper-evident log of session parameters)

Audio outputs carry a periodic disclosure marker (ultrasonic or audible-low, configurable).

**Validation**: Output capture replayed through verifier tool must produce a valid signed manifest. CI test required.

**Why**: Differentiates MirrorMesh from impersonation tooling; supports downstream provenance verification.

### Pattern: Consent-Gated Identity Transform

**Context**: Identity transfer is the highest-risk capability.

**Rule**: Loading any identity model (avatar template, reenactment target) requires:
1. A signed consent manifest from the identity holder, OR
2. A "self-as-source" assertion (user transforming their own face) verified at session start, OR
3. A "stylized non-human" classification (cartoon, animal, abstract) reviewed at model intake

No model loads from arbitrary URLs without intake review. Bundled curated models only.

**Why**: Prevents the tool from being a drop-in impersonation kit.

### Pattern: Pipeline Stage Isolation

**Context**: The pipeline has 6+ stages, each with independent latency/memory budgets.

**Rule**: Stages communicate via typed buffer queues (ring buffers with backpressure). Each stage owns its Metal command queue or CoreAudio thread. No stage reaches across stage boundaries.

**Benchmarking**: Each stage publishes per-frame latency to a shared telemetry bus (in-process), enabling end-to-end attribution.

### Pattern: Unified-Memory Buffer Reuse

**Context**: Apple Silicon's unified memory removes CPU↔GPU copies; this is the platform's headline advantage.

**Rule**: Camera frames flow as `CVPixelBuffer` / `IOSurface` references end-to-end. CoreML, Metal, and AVFoundation all consume the same surface; no `memcpy` between stages.

**Validation**: Allocation profiler in benchmark suite must report zero per-frame heap allocations on the hot path.

### Pattern: Benchmarkable Everything

**Context**: The paper depends on reproducible numbers.

**Rule**: Every stage exposes:
- `latency_ms` histogram (P50/P95/P99)
- `power_mw` (via `powermetrics` integration)
- `gpu_utilization` and `ane_utilization`
- Frame-accurate timestamps

Logs are JSONL, parseable by the included `bench/` harness.

---

## Stage-Level Notes

### 1. Capture
- AVFoundation `AVCaptureSession` with explicit format selection (prefer 1920×1080@60 or 1280×720@60)
- ISP settings locked at session start for reproducibility
- Continuity Camera path tested separately (different latency profile)

### 2. Landmark Tracking
Comparison matrix maintained in `bench/landmark_comparison.md`:

| Method | Latency | Fidelity | Hardware | Notes |
|--------|---------|----------|----------|-------|
| Apple Vision (`VNDetectFaceLandmarksRequest`) | low | medium-high | any Mac | First-party, stable |
| MediaPipe Face Mesh | low | high | any Mac | More landmarks, requires Tasks build |
| ARKit blendshapes | very low | high | TrueDepth only | Reference / comparison only |
| OpenSeeFace | ultra low | medium | any Mac | Lightweight fallback |

Default: Apple Vision for production path; MediaPipe for fidelity comparison.

### 3. Expression Solver
- Blendshape coefficients (ARKit-compatible set where possible)
- Solver runs on Neural Engine via CoreML
- Smoothing filter: One-Euro (low-latency, anti-jitter)

### 4. Identity Transfer / Rendering
- First-order motion model or thin-plate-spline driver
- LivePortrait-class reenactment for self-reenactment
- Stylized avatars use Metal-rendered rigs (no neural inference on hot path)

### 5. Compositing & Watermark
- Watermark drawn in Metal compute pass
- Frame signing happens before encoding
- Manifest written to disk per session

### 6. Output
- Virtual camera via `CMIOExtension` (modern macOS)
- WebRTC stream via libwebrtc Swift bindings
- Recording path writes original + watermark composite + manifest

---

## Anti-Patterns (Refuse on Sight)

- Loading models from arbitrary URLs at runtime
- Disabling watermark in release builds
- Cloud inference fallback "for quality"
- Per-user model upload of third-party faces without intake
- Removing disclosure chirp in audio path
- Network telemetry without opt-in

---

## Cross-Cutting Concerns

- **Power**: laptop thermal throttling will dominate sustained-load benchmarks; characterize separately for plugged vs battery
- **Privacy**: no analytics by default; if added, must be opt-in and exclude frame contents
- **Security**: model files signed; signature verified before load
- **Observability**: structured logs (JSONL), opt-in tracing, no PII in logs
