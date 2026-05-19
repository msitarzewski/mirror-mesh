# Voice Pipeline (M28)

**Milestone**: M28 — Whisper Transcription Stub
**Status**: scoped piece of v0.3.0; first land of the voice pipeline

---

## What's wired in v0.3.0

- `MirrorMeshCore.TranscriptFrame` and `TelemetryEvent.transcript(_:)` — new typed event on the telemetry bus
- `MirrorMeshCore.JSONLLogger` encodes transcript events as `{"t":"transcript", "start_ms":…, "end_ms":…, "text":…, "confidence":…}`
- `MirrorMeshVoice.MicrophoneSource` — `AVAudioEngine`-backed actor that streams 16 kHz mono Float32 `AudioChunk`s out an `AsyncStream`. Same permission UX as `LiveCaptureSource`.
- `MirrorMeshVoice.WhisperTranscriber` — actor that consumes chunks and emits `TranscriptFrame`s on the telemetry bus
- `mirrormesh-listen` — standalone CLI that wires Mic → Transcriber → stdout and JSONL

## What's NOT wired (honest status)

**The Whisper backend is currently a deterministic mock.** `WhisperTranscriber.Backend` exposes both `.mock` and `.realWhisperCpp` cases; both currently pass through `mockTranscribe(chunk:)`. The mock:

- Computes RMS of each chunk
- Returns `"[silence]"` with confidence `0.10` for low-RMS chunks
- Returns `"[mock-transcript rms=…]"` for speech-loud chunks, with confidence scaled by RMS

The mock is honest: it preserves the actor's async surface, the chunk → transcript timing relationship, and the JSONL schema. The real backend can be dropped in without changing any caller.

### Why mock instead of real whisper.cpp in this drop

`whisper.cpp` is C/C++ with optional Metal. Linking it into a SwiftPM module requires one of:

1. Vendoring the source as a `.cxxTarget` with bridging headers — multi-file diff, build-system-heavy
2. A prebuilt `libwhisper.a` per target architecture — needs to be checked in or fetched
3. A community Swift wrapper package — adds an external dependency

None of these fit cleanly into the v0.3.0 milestone budget. The mock unblocks downstream work on `TelemetryEvent.transcript`, the JSONL schema, the bench scenario, and the CLI shape without committing to a build-system change. The real backend lands as a follow-up drop inside v0.3.x.

## Audio chunk format

```swift
public struct AudioChunk: Sendable {
    public let samples: [Float]    // 16 kHz mono, range [-1, 1]
    public let sampleRate: Int     // always 16_000 in the current default config
    public let startNs: UInt64     // wall-clock host time at chunk start
}
```

Chunk size is configurable via `MicrophoneSource.Config.chunkSeconds` (default `1.0`). One chunk per second balances whisper.cpp's preference for ≥ 1 s of context against the latency budget for live transcript display.

## Privacy

- All processing is local. No network calls anywhere on the audio path. (Per `projectRules.md` R3, R4.)
- Microphone permission is requested at runtime via the same `AVCaptureDevice.requestAccess(for: .audio)` path the camera uses.
- The model file is not committed to the repo. The provenance sidecar at `models/whisper-tiny.en.provenance.json` documents the upstream URL, expected sha256, and license.
- `mirrormesh-listen` prints a warning when the model file is missing and points the user at the download URL — it does not silently fetch the binary in v0.3.0.

## CLI usage

```bash
# 10-second mock run (works without a model file):
swift run mirrormesh-listen --mock --duration 10

# Real backend (currently falls back to mock; warns clearly):
swift run mirrormesh-listen --model ~/Library/Application\ Support/MirrorMesh/whisper-tiny.en.bin
```

## Bench

`bench/scenarios/whisper.json` declares `voice: true`. The bench CLI carries the flag through to JSONL as an annotation; the audio path itself lives in `mirrormesh-listen` for v0.3.0 because the bench runner is single-pipeline today. Wiring both pipelines concurrently is a separate spec note in `bench/scenarios/README.md` and lands in v0.4.0.

## v0.4.0 plan

- Vendor whisper.cpp as a `.cxxTarget` with Metal enabled — flip `WhisperTranscriber.Backend.realWhisperCpp` to the real engine
- Add `voice-transform` module (pitch / formant shift over the mic input)
- Add `voice-tts` module for synthesized agent voice
- Co-run mic + camera pipelines in `mirrormesh-bench` against scenarios that exercise both
- Add cross-language support via the multilingual `whisper-base` model (~150 MB, opt-in)

## Files

- `Sources/MirrorMeshCore/FrameProtocols.swift` — `TranscriptFrame`
- `Sources/MirrorMeshCore/TelemetryEvent.swift` — `.transcript` case
- `Sources/MirrorMeshCore/JSONLLogger.swift` — JSONL schema for transcript events
- `Sources/MirrorMeshVoice/AudioChunk.swift`
- `Sources/MirrorMeshVoice/MicrophoneSource.swift`
- `Sources/MirrorMeshVoice/WhisperTranscriber.swift`
- `Sources/MirrorMeshVoice/MirrorMeshVoice.swift`
- `Sources/mirrormesh-listen/ListenCLI.swift`
- `Tests/MirrorMeshVoiceTests/VoiceTests.swift`
- `bench/scenarios/whisper.json`
- `models/whisper-tiny.en.provenance.json`
