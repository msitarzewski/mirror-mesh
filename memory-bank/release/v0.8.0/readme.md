# Release v0.8.0 — "Accessibility"

**Goal**: One headline accessibility-first application that the rest of the v0.x work has been building toward. Picked: **multilingual lip-sync**.

**The flow**: User speaks English → on-device Apple Speech transcribes → local Ollama translates to a target locale → AVSpeechSynthesizer reads the translated text → audio amplitude + vowel detection drives lip-sync blendshapes → stylized 3D head from v0.6.0 mouths the target language in real time. Fully on-device (LLM via local Ollama, TTS via system synth, render via Metal). Watermarked, chirped, consented.

**Why this and not the alternatives**: gaze correction is pure CV (less WOW from the LLM stack); paralysis amplification needs medical-grade validation; multilingual lip-sync shows the whole MirrorMesh stack working in one demo — and it's the most universal accessibility win (deaf-hearing communication, cross-language conferencing, language-learning).

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M66** | `MirrorMeshTranslate` module — `OllamaClient` actor | 🟡 in flight |
| **M67** | `TTSSpeaker` wrapping `AVSpeechSynthesizer` with amplitude tap | 🟡 in flight |
| **M68** | `LipSyncDriver` — amplitude + vowel → blendshape coefficients | 🟡 in flight |
| **M69** | `mirrormesh-translate` CLI | 🟡 in flight |
| **M70** | Settings panel "Translation" section | ⚪ orchestrator |
| **M71** | Watermark extension: `voice_transformed: bool` field | ⚪ orchestrator |
| **M72** | Pipeline `TranslationStage` between voice and reenact | ⚪ orchestrator |

## Exit criteria

1. With Ollama running and `llama3.2:3b` pulled, `mirrormesh-translate --from en-US --to es-ES --text "Hello"` prints `Hola` and speaks it
2. App's "Translation" settings section lets user pick target locale; when enabled, live captured speech is transcribed → translated → spoken with the stylized avatar lip-syncing the translated audio
3. No network egress beyond `localhost:11434`
4. Watermark records `voice_transformed: true` in the per-frame signature payload when translation is active
5. End-to-end demo video — operator speaks one sentence in English, stylized avatar speaks the same sentence in Spanish/French/Mandarin in their own voice, latency observably real-time
