# M28 — Whisper Transcription Stub

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M30

## Objective

A first scoped piece of the voice pipeline: realtime transcription of microphone input via `whisper.cpp` (MIT-licensed). Outputs `TranscriptFrame` events on the telemetry bus. v0.3.0 stops at "we can transcribe locally" — voice transform and TTS are v0.4.0.

## Deliverables

- New module `Sources/MirrorMeshVoice/`
- Depends on a checked-in `whisper.cpp` git submodule (or a pre-built `libwhisper.a`) — Apache 2.0 / MIT licensed
- `MicrophoneSource` actor — `AVCaptureSession` audio path, produces `AudioBuffer` chunks
- `WhisperTranscriber` actor — feeds buffers into whisper.cpp, emits `TranscriptFrame { startMs, endMs, text, confidence }` on the telemetry bus
- New telemetry event: `TelemetryEvent.transcript(TranscriptFrame)`
- New `Sources/mirrormesh-listen` CLI executable — runs the audio path standalone for debugging
- `bench/scenarios/whisper.json` — runs the full pipeline + audio side by side, JSONL includes `transcript` records
- `models/whisper-tiny.en.bin` — tiny English-only Whisper model (~40 MB) with provenance sidecar
- `docs/voice-pipeline.md` — what's wired, what's not, what v0.4.0 will add

## Verification

```bash
swift run mirrormesh-listen --model models/whisper-tiny.en.bin
# speak; transcripts print as they're produced

swift run mirrormesh-bench --scenario bench/scenarios/whisper.json
grep transcript bench/out/whisper_*.jsonl   # should show transcript records
```

## Notes

- whisper.cpp is well-maintained, MIT-licensed, runs on Metal — natural fit
- The tiny.en model is the smallest acceptable for realtime transcription on M-series; whisper-base.en (~150 MB) is a v0.4.0 upgrade
- All audio processing is local — no cloud STT under any circumstance per `projectRules.md` R3, R4
- Microphone permission requested at runtime; surfaced through the same permission-denied UX as Camera
