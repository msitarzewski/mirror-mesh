# MirrorMesh — Resume

> **One-screen state-of-the-project. Read this first after a /compact or fresh session.**

## Status as of 2026-05-20

**Working app**: live camera → real Vision landmarks → geometric or CoreML solver → **stylized 3D head reenactment gated on `ConsentedIdentity`** → optional **voice (Apple on-device Speech)** + **translation (Ollama) + TTS (AVSpeechSynthesizer) + audio-driven lip-sync overlay** on mouth region → Metal rendering (Wireframe / Mirror / Mask styles + stylized head composite) → Ed25519 watermark + visible badge + audible disclosure chirp + signed manifest carrying `identity_sha256` + `voice_transformed` + `audible_chirp` flags → SwiftUI window with operator PIP, Identity Inspector, Voice Inspector, Translation Inspector, toolbar activity pills.

Measured P50 latency on M5 Max:
- Demo / synthetic / 640×360 / geometric solver: e2e 1.46 ms (vision 0.02, solver 0.06, render 0.69, watermark 0.58)
- File / 1280×720 / real Apple Vision: e2e 4.24 ms (vision 2.23, render 0.65, watermark 1.36)
- CoreML solver disagreement vs geometric: mean |Δcoef| 0.054, max 0.62 (eyeBlinkLeft)

**176 tests / 34 suites green** under `swift test`. `swift build` clean across all 17 modules + 10 CLIs. Hardware: M5 Max / 128 GB / 40 GPU cores.

**License**: AGPL-3.0-only research project (ADR-0015 supersedes ADR-0014). Copyright "Michael Sitarzewski". DCO sign-off on commits. See `NOTICE.md`.

## Where we are in the release arc

```
v0.1.0  ✅  First Light        — pipeline + watermark + manifest
v0.2.0  ✅  Living Window      — Xcode tests + app exec + recorder + signposts
v0.3.0  ✅  Ship It            — xcodegen + signing scaffolding + WebRTC + Whisper stub + paper
v0.4.0  ✅  Sustainable        — AGPL pivot + Glass UI + menu + icon + 3 critical bug fixes
v0.5.0  ✅  Presence           — face mesh + CoreML weights + RenderStyle picker + handoff polish
v0.6.0  ✅  Identity           — stylized head reenactor + ConsentedIdentity protocol +
                                 mirrormesh-consent CLI + Identity inspector + disclosure chirp +
                                 FOMM photoreal scaffolding (manual weight download)
v0.7.0  ✅  Voice              — Apple on-device Speech (SFSpeechRecognizer + on-device required)
                                 wired into Pipeline as VoiceStage; chirp + manifest flip on activation
v0.8.0  ✅  Accessibility      — multilingual lip-sync via Ollama + AVSpeechSynthesizer + audio→
                                 blendshape driver wired through TranslationPipelineStage +
                                 ReenactFrame.overlayLipSync; Voice + Translation inspectors in app
v0.9.0  ✅  Paper              — ASSETS-targeted draft v1 (7.5k words) + CONSENT_PROTOCOL.md;
                                 Tables 1–4 filled with real measured benches
v1.0.0  ✅  Ship-ready         — RELEASE_NOTES + README; notarization scripts work end-to-end;
                                 blocked only on user-paste Team ID + App Store Connect API key
```

## How to feel the WOW

```bash
cd /Users/michael/Clean/mirror-mesh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 1) The app — stylized head, consent flow, watermark, chirp
swift run mirrormesh-app

# 2) Make a consent bundle
printf 'fake png' > /tmp/me.png
swift run mirrormesh-consent --name "You" --scheme self-as-source \
    --scope "v0.6+" --png /tmp/me.png --out /tmp/you.mmid

# 3) Voice transcription (on-device Apple Speech)
swift run mirrormesh-listen --backend apple-speech --locale en-US

# 4) Multilingual lip-sync — translate, speak target language
# Prereq: brew install ollama; ollama serve; ollama pull llama3.2:3b
swift run mirrormesh-translate --from en-US --to es-ES --text "Hello, world."

# 5) Bench
swift run mirrormesh-bench bench/scenarios/fixture.json
```

## What's still gated on user input (not blocking the WOW)

- **Notarization** — blocked on user-paste of `DEVELOPMENT_TEAM` Team ID. Scripts are at `scripts/release/{archive,notarize}.sh`; template at `Local.xcconfig.template`; recipe at `scripts/release/README.md`.
- **App Store Connect API key** — needed by `xcrun notarytool store-credentials mirrormesh-notary` once Team ID lands
- **GitHub remote** — no remote configured; `gh release create v1.0.0` is a one-liner once the remote URL exists
- **FOMM photoreal weights** — optional path; user runs `python3.11 models/training/fomm_to_coreml.py --weights ~/Downloads/vox-cpk.pth.tar --out models/` to convert weights for the photoreal alternative to the stylized head
- **Reenact-active bench number** — paper Table 4 has the pass-through baseline (3.07 ms); the reenact-active cell awaits a `mirrormesh-bench --identity <.mmid>` flag (v1.1 follow-up)
- **Power benches** — `bench/scripts/power.sh` requires sudo, headless run is pending

## Recovery commands

```bash
cat memory-bank/activeContext.md | head -25
cat memory-bank/release/v1.0.0/readme.md
git log --oneline | head -15

# Is it still working?
swift build && swift test --skip MirrorMeshStreamTests --skip MirrorMeshVirtualCameraTests --skip MirrorMeshMediaPipeTests
```

## Session arcs

- **2026-05-19**: v0.1.0 → v0.5.0 in one extended session — `memory-bank/tasks/2026-05/250519_session-arc.md`
- **2026-05-19/20**: v0.6.0 → v1.0.0 candidate via three parallel agent waves — files committed in `git log` after the last RESUME push

---

*Last updated 2026-05-20 by Claude Opus 4.7. If this file is older than the most recent commit, trust the commit log over this file.*
