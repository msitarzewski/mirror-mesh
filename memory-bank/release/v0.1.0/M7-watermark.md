# M7 — Watermarking Subsystem

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M1, M2
**Blocks**: M8, M10

## Objective

Three-layer watermark on every synthetic output: visible badge, cryptographic frame signature, signed session manifest. Verifier included.

## Deliverables

In `Sources/MirrorMeshWatermark/`:

- `VisibleBadge.swift` — Metal compute pass that composites a "MIRRORMESH SYNTHETIC" badge into a configurable corner of the frame
- `FrameSigner.swift` — Ed25519 over (frameID || hostTimeNs || sha256(pixelBytes)) using CryptoKit
- `Manifest.swift` — session manifest struct (see M8)
- `Verifier.swift` — given a frame + signature + manifest, return verification result
- `WatermarkConfig.swift` — toggles (development only — release builds force-on)

In `bench/scripts/verify-output.swift` — CLI verifier

## Behavior

- Visible badge: ~120×40 px composited bottom-right by default, opacity 0.85, never alpha-zero in release builds
- Frame signing: per-frame, public key written to manifest; signature blob attached as sidecar metadata (per-codec where embeddable, else as a `.sigs` sidecar)
- Session manifest signed at session end with the same key
- Release-build flag forces all three layers on regardless of user preferences

## Tests

- Round-trip: sign a frame, verify; flip one byte, verifier rejects
- Manifest integrity: tamper with manifest, verifier rejects
- Release-mode guard: in `.release` configuration, attempts to disable any layer fail at compile time (or runtime panic with clear message)

## Notes

- Use `Curve25519.Signing.PrivateKey` from CryptoKit
- Per-session ephemeral key; public key persisted to manifest. Long-term identity keys are out of scope for v0.1.0.
- Document scheme for the paper in `docs/watermark-spec.md`
