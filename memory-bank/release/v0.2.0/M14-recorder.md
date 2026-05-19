# M14 — Frame Recorder (.mov + sidecar manifest)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M17, M20

## Objective

A frame recorder that writes the **watermarked** output stream to a `.mov` via `AVAssetWriter`. The session manifest is written alongside, identical in schema to v0.1.0's bench manifest. Producing a shareable artifact closes the loop on the trust narrative: the file you hand someone is the file the verifier can prove came from this session.

## Deliverables

In a new module `Sources/MirrorMeshRecorder/`:

- `VideoRecorder.swift` — `public actor VideoRecorder`:
  - `init(url: URL, width: Int, height: Int, fps: Int)`
  - `func append(_ frame: WatermarkedFrame) async`
  - `func finalize() async throws`
  - Uses `AVAssetWriter` + `AVAssetWriterInput` + `AVAssetWriterInputPixelBufferAdaptor`
  - HEVC encoding (or H.264 fallback) — configurable
- `Pipeline` (in `MirrorMeshOutput`) extended with optional `recorderURL: URL?` — when non-nil, every `WatermarkedFrame` is appended
- Bench scenario gains optional `"record": true` flag
- App: Settings has a "Record session" toggle; UI updates when recording is active

## Behavior

- Recording start: opens `AVAssetWriter`, begins session at first frame's PTS
- Recording end: finalizes writer, flushes, calls `await manifestWriter.finalize()`
- The recorded `.mov` and the manifest land in the same directory with the same base name
- A "RECORDING" red dot is visible in the app UI when active

## Verification

```bash
swift run mirrormesh-bench --scenario bench/scenarios/recorded.json
ls bench/out/recorded_*.mov  bench/out/recorded_*.manifest.json
swift run mirrormesh-verify --manifest bench/out/recorded_*.manifest.json
open bench/out/recorded_*.mov   # plays in QuickTime, badge visible
```

Test suite: round-trip — record N frames, finalize, then re-open the .mov and re-verify frame hashes from the manifest. (Detailed verification of every frame is v0.3.0 work; v0.2.0 verifies the manifest digests + the recording exists and plays.)

## Notes

- `AVAssetWriter` requires `kCVPixelFormatType_32BGRA` source, which is what the pipeline already uses
- New module added to `Package.swift` — keep dependency order: `MirrorMeshRecorder` depends on `MirrorMeshWatermark`, `MirrorMeshCore`
