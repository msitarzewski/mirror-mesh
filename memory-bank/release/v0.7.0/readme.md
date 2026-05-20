# Release v0.7.0 — "Voice"

**Goal**: Real on-device speech transcription, replacing the v0.3.0 mock backend. Voice is the second sensory channel for telepresence — without it the avatar can mimic expression but can't carry conversation.

**Theme**: The voice equivalent of v0.6.0 Identity. Apple's on-device Speech framework (SFSpeechRecognizer + `requiresOnDeviceRecognition = true`) provides ASR with zero binary dependencies and zero network egress.

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M60** | `AppleSpeechBackend` actor replacing mock Whisper | 🟡 in flight |
| **M61** | `AudioCapture` actor with `AVAudioEngine` taps at 16 kHz Float32 | 🟡 in flight |
| **M62** | `mirrormesh-listen` CLI wired to live mic + file input | 🟡 in flight |
| **M63** | Pipeline `VoiceStage` + `setOnTranscript` callback | ⚪ orchestrator |
| **M64** | Manifest records `audible_chirp: true` when voice is active | ⚪ orchestrator |
| **M65** | Info.plist usage strings (NSSpeechRecognitionUsageDescription, NSMicrophoneUsageDescription) | ⚪ orchestrator |

## Exit criteria

1. `swift run mirrormesh-listen` transcribes live microphone input on-device
2. `swift run mirrormesh-listen --input fixture.wav` transcribes a file
3. Pipeline can attach a transcript callback; transcripts are stamped with frame IDs
4. No network calls. `nettop` shows zero egress during a session.
5. Session manifest records `voice_active: true` and `audible_chirp: true`
