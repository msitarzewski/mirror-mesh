# MirrorMesh — Project Brief

**Source**: `memory-bank/mision.md` (filename misspelled; canonical reference)
**Status**: Framework initialized 2026-05-19
**License**: **AGPL-3.0-only research project** (ADR-0015 supersedes ADR-0014 and ADR-0005). Research-only intent: the maintainer does not monetize this code, and AGPL's strong copyleft + network-use clause prevents anyone else from monetizing derivatives either.

---

## Vision

MirrorMesh is an open research project demonstrating that **modern Apple Silicon hardware is sufficient for high-fidelity realtime expressive telepresence without specialized mocap hardware**.

The project produces:

1. A defensible, publishable research paper grounded in measurable benchmarks
2. An open-source prototype on commodity Apple hardware
3. A reference architecture for **trust-preserving** synthetic telepresence

## Core Thesis

Modern Apple Silicon devices equipped only with integrated HD cameras can achieve low-latency realtime facial reenactment and expressive avatarization, with local-only inference and built-in disclosure, without dedicated motion-capture hardware.

## Primary Goals

- **Fully local inference** on Apple Silicon (Neural Engine + Metal + CoreML)
- **Commodity hardware only** — no TrueDepth requirement, no discrete GPU
- **Built-in disclosure / watermarking** by default (not optional)
- **Explicit consent model** for any identity transformation
- **Research-grade documentation** suitable for academic publication
- **Open benchmark suite** for latency, quality, and power

## Non-Goals (Hard Constraints)

The following are explicitly **out of scope** and will be refused at the architectural level:

- Identity spoofing of real third parties without consent
- ID-verification bypass
- Celebrity / public-figure cloning presets
- Hidden / undisclosed operation modes
- Non-consensual face or voice cloning
- Bypassing watermarking or disclosure

These constraints are load-bearing: they define what MirrorMesh **is**, not just what it avoids.

## Target Hardware

- M3 / M4 / M5 Macs (primary)
- Studio Display, Continuity Camera, MacBook integrated webcams
- AirPods and USB microphones for audio capture

No iPhone TrueDepth dependency. ARKit / TrueDepth optional comparison only.

## Key Claims (To Validate)

- Sub-100 ms motion-to-photon pipeline achievable on commodity Apple Silicon
- 30 FPS sustained without thermal throttling on M-series laptops
- No facial markers required (webcam-only)
- Local-only inference viable (no cloud dependency)
- Accessibility applications (gaze correction, expression amplification, lip-sync, paralysis compensation) are first-class, not afterthoughts

## Differentiated Angle: Synthetic Accessibility

Strongest defensible framing: MirrorMesh as **accessibility infrastructure**, not deepfake tooling.

- Facial paralysis compensation
- Gaze correction for video calls
- Expression amplification
- Multilingual lip synchronization
- Speech assistance avatars
- Telepresence fatigue reduction

This framing is socially defensible, technically rich, and academically novel.

## Success Criteria

- Reproducible benchmark numbers published with raw traces
- Open-source release with default-on watermarking
- Demonstrable accessibility use cases beyond entertainment
- Paper acceptable to a peer-reviewed venue (SIGGRAPH / CHI / ASSETS class)

## Open Questions (Routed to `decisions.md` as ADRs)

- License: AGPL-3.0-only (resolved 2026-05-20 via ADR-0015)
- Watermarking scheme (visible-only vs cryptographic frame signing vs both)
- Voice transform inclusion (timbre modification — defaults, disclosure model)
- Distribution channel (Homebrew tap, signed DMG, App Store, source-only)
