# MirrorMesh

![CI](https://github.com/<user>/<repo>/actions/workflows/ci.yml/badge.svg)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Commercial license available](https://img.shields.io/badge/commercial-available-green.svg)](./COMMERCIAL.md)

> **Maintainers**: replace `<user>/<repo>` in the CI badge URL with the actual GitHub `owner/repository` once this project is published. See [`docs/ci.md`](./docs/ci.md).

**Open realtime telepresence research for Apple Silicon. Local-only inference. Watermarked by default. Consent-gated by design.**

---

## What this is

> Modern Apple Silicon equipped only with integrated HD cameras can achieve low-latency realtime facial reenactment and expressive avatarization — with local-only inference, built-in cryptographic disclosure, and no specialized motion-capture hardware.

The pipeline: **Camera → Apple Vision landmarks → blendshape solver → Metal renderer → visible watermark + Ed25519 frame signing + signed session manifest → screen / `.mov`**.

End-to-end latency on the reference Mac (M5 Max, macOS 26.5): **P50 1.4 ms** (synthetic landmarks) / **P50 5.1 ms** (real Vision on the procedural fixture).

## What this is not

- Not an impersonation toolkit
- Not an ID-verification bypass tool
- Not a celebrity / public-figure cloning system
- Not a hidden / undisclosed synthetic media generator

The constraints are enforced architecturally, not just in the license — see [`memory-bank/projectRules.md`](./memory-bank/projectRules.md).

## Quickstart

Requires macOS 14+, Apple Silicon, and Xcode (full install — Command Line Tools alone is no longer enough as of v0.2.0; see [ADR-0012](./memory-bank/decisions.md)).

```bash
# One-time: point swift at Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# Or, per-invocation:
#   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

git clone <repo> mirror-mesh && cd mirror-mesh

swift build
swift test                                                    # 44 tests, 13 suites
swift run mirrormesh-app                                      # opens an NSWindow
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-verify --manifest bench/out/demo_*.manifest.json
python3 bench/scripts/summarize.py bench/out/demo_*.jsonl
```

To exercise the real-Vision path against the bundled procedural fixture (no camera required):

```bash
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json
```

To record a watermarked `.mov`:

```bash
swift run mirrormesh-bench --scenario bench/scenarios/recorded.json
open bench/out/recorded_*.mov   # plays in QuickTime; badge visible
```

## What you'll see

- The bench CLIs produce JSONL traces in `bench/out/`. `bench/scripts/summarize.py` and `bench/scripts/figures.py` (matplotlib) turn them into per-stage P50/P95/P99 tables and PDFs in `docs/figures/`.
- Every output frame carries a visible "MIRRORMESH • SYNTHETIC" badge + an Ed25519 signature; tampering with the manifest causes `mirrormesh-verify` to exit non-zero. See `docs/demo.md`.
- The SwiftUI app (`mirrormesh-app`) shows a live `MTKView` preview, a telemetry panel with per-stage latency histograms, and a consent flow before any session starts.

## Architecture

```
Capture (AVFoundation / Synthetic / File)
  → Vision (Apple Vision face landmarks + One-Euro smoothing / Synthetic)
  → Solver (Geometric / CoreML, both conform to ExpressionSolver)
  → Render (Metal — passthrough + landmark overlay + stylized avatar mask)
  → Watermark (visible badge + Ed25519 frame signing)
  → Output (screen / virtual camera [v0.3.0] / .mov recorder / WebRTC [v0.3.0])
  ╰── Session manifest (signed, tamper-evident)
  ╰── JSONL telemetry trace (per-stage timings)
  ╰── Instruments os_signpost intervals
```

Modules live under `Sources/`:

| Module | Role |
|--------|------|
| `MirrorMeshCore` | Frame types, telemetry actor, JSONL logger, signposts, pixel-buffer pool |
| `MirrorMeshCapture` | `FrameSource` protocol; `Live`/`Synthetic`/`File` sources |
| `MirrorMeshVision` | Vision landmark extractor + One-Euro filter |
| `MirrorMeshSolver` | `ExpressionSolver` protocol; geometric + CoreML implementations |
| `MirrorMeshRender` | Metal renderer with overlay compositors |
| `MirrorMeshWatermark` | Ed25519 frame signer, visible badge, signed manifest |
| `MirrorMeshRecorder` | `AVAssetWriter`-based watermarked `.mov` recorder |
| `MirrorMeshOutput` | Top-level `Pipeline` orchestrator |
| `MirrorMeshAppKit` | SwiftUI views consumed by the `mirrormesh-app` executable |

## Layout

```
Sources/           Swift modules + executables (bench, verify, app, selftest, fixture-gen)
Tests/             Swift Testing suites + Fixtures/
shaders/           Metal source (under Sources/MirrorMeshRender/Shaders)
bench/             Scenarios, scripts (perf + power + figures), outputs
models/            CoreML packages + provenance sidecars + training scripts
docs/              demo.md, instruments.md, power-methodology.md, ci.md, figures/, screenshots/
memory-bank/       AGENTS.md framework, ADRs, release roadmaps
.github/workflows/ CI + release pipelines
```

## Releases & roadmap

- **v0.1.0** "First Light" — ✅ end-to-end pipeline on synthetic frames, signed manifest, JSONL bench. [Roadmap](./memory-bank/release/v0.1.0/readme.md)
- **v0.2.0** "Living Window" — ✅ real Xcode tests, app executable, live camera UI, frame recorder, real-face fixture, signposts, power bench, CoreML solver scaffolding, CI, figures. [Roadmap](./memory-bank/release/v0.2.0/readme.md)
- **v0.3.0** (planned) — notarized `.app` bundle, virtual camera (`CMIOExtension`), WebRTC streaming, MediaPipe comparison, real trained CoreML weights, voice pipeline.

## Documentation

- [`docs/demo.md`](./docs/demo.md) — what the demo does and how to read its output
- [`docs/instruments.md`](./docs/instruments.md) — interpreting the `.trace` lanes
- [`docs/power-methodology.md`](./docs/power-methodology.md) — `powermetrics` recipe
- [`docs/figures.md`](./docs/figures.md) — paper-figure regeneration
- [`docs/ci.md`](./docs/ci.md) — CI pipeline reference
- [`memory-bank/`](./memory-bank/) — Memory Bank (AGENTS.md v2.2) + ADRs

## License

MirrorMesh is **dual-licensed**:

- **[AGPL-3.0](./LICENSE)** for open-source use — clone, fork, redistribute under the terms of AGPL-3.0. Researchers, academics, hobbyists, and anyone happy to release derivatives under AGPL are covered for free. The "A" closes the SaaS loophole that plain GPL has.
- **[Commercial license](./COMMERCIAL.md)** for closed-source / proprietary / non-AGPL-compatible use — separate paid agreement with the maintainer.

The MirrorMesh constraints (watermark on by default, no third-party impersonation, consent gating) live in [`projectRules.md`](./memory-bank/projectRules.md) and the architecture itself — **not** in removable license terms. Every commercial license carries them as contractual obligations.

Contributing: see [`CONTRIBUTING.md`](./CONTRIBUTING.md). DCO sign-off (`git commit -s`) on every commit. No CLA required.

History: the project was Apache-2.0 through v0.3.0; relicensed to AGPL-3.0 + Commercial at v0.4.0 kickoff (see [ADR-0014](./memory-bank/decisions.md)).
