# M25 — WebRTC Streaming (One-Way Send)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11 (tests)
**Blocks**: M30

## Objective

A `WebRTCSender` that takes watermarked frames and pushes them to an SDP-paired peer over libwebrtc. Send-only in v0.3.0 (no receive, no two-way). Use case: lightweight remote demo where the sender's machine runs MirrorMesh and the viewer just renders the watermarked stream.

## Deliverables

- New module `Sources/MirrorMeshStream/`
- Depends on the [stasel/WebRTC](https://github.com/stasel/WebRTC) Swift package (Apache 2.0, pre-built libwebrtc binaries)
- `WebRTCSender` actor:
  - `start(offer: SDP, onAnswer: (SDP) -> Void)` — accepts an offer, generates an answer
  - `append(_ frame: WatermarkedFrame)` — feeds frames into the outgoing video track
- A minimal test harness: a local SDP-pair receiver that consumes the stream, dumps every frame as PNG, and runs `mirrormesh-verify` on the session manifest emitted in parallel by the sender
- Bench scenario `bench/scenarios/stream.json` — runs the pipeline and pushes through WebRTC at the same time, measures the added latency

## Verification

```bash
swift run mirrormesh-bench --scenario bench/scenarios/stream.json
# Receiver in another process picks up the stream; recorded sample frames verify
```

## Notes

- libwebrtc adds an arm64 binary blob (~30 MB). Acceptable for v0.3.0 since the project already ships with the Vision/Metal/CoreML SDK weight. Documented in `docs/dependencies.md` (M26 will write this).
- Encryption is whatever WebRTC's DTLS-SRTP provides by default; we don't strip it
