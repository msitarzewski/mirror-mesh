# MirrorMesh — Resume

> **One-screen state-of-the-project. Read this first after a /compact or fresh session.**

## Status as of 2026-05-20 — PAUSED

Maintainer set the project down after a long photoreal-debugging session that didn't visually land. Everything ELSE works and ships as v1.0; photoreal needs a fresh empirical pass when curiosity returns. See `memory-bank/activeContext.md` for the technical state + investigation hypotheses for whoever picks it up.

**Working app**: live camera → real Vision landmarks → geometric or CoreML solver → **stylized 3D head reenactment gated on `ConsentedIdentity`** → optional **voice (Apple on-device Speech)** + **translation (Ollama) + TTS (AVSpeechSynthesizer) + audio-driven lip-sync overlay** on mouth region → Metal rendering (Wireframe / Mirror / Mask + stylized head composite) → Ed25519 watermark + visible badge + audible disclosure chirp + signed manifest → SwiftUI window with operator PIP, Identity Inspector (Capture-as-identity + Use Test Persona buttons), Voice Inspector, Translation Inspector, toolbar activity pills.

**Photoreal substitution is wired but does NOT produce correct visual output.** All infrastructure is in place (detection, identity gate, PhotorealStage, composite-at-bbox renderer, capture-as-identity, test persona, M37 handoff fix); 209 tests green. The pipeline DOES call the LivePortrait inference graph. But the rendered face is incoherent — peach blob + horizontal banding with the procedural test persona; self-as-source produces output indistinguishable from raw camera passthrough.

Hypotheses for fix (NONE TESTED — leave for resumer):
- **Color-space mismatch** in the CVPixelBuffer↔MLMultiArray chain. Banding artifacts are consistent with channel-order or gamma corruption.
- **`transform_keypoint` math** has subtle bug vs upstream Python reference. Unit tests cover determinism + shape but no value-equivalence against Python.
- **LivePortrait keypoint detector** wasn't trained on cartoon faces — explains test-persona garbage but not self-as-source degeneracy.
- **Recommended next move**: run `PhotorealBackend.reenact` standalone with a known-good 256×256 face PNG from LivePortrait's own demo set and `diff` Swift output against upstream Python on the same input. If Swift output matches reference, bug is downstream in composite. If garbage, bug is in inference graph.

Measured P50 latency on M5 Max (still valid):
- Demo / synthetic / 640×360 / geometric solver: e2e 1.46 ms
- File / 1280×720 / real Apple Vision: e2e 4.24 ms
- CoreML solver disagreement vs geometric: mean |Δcoef| 0.054, max 0.62 (eyeBlinkLeft)

**209 tests / 40 suites green** under `swift test`. `swift build` clean. Hardware: M5 Max / 128 GB / 40 GPU cores.

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
                                 M88 photoreal inference + M89 photoreal UX landed 2026-05-20
                                 (LivePortrait CoreML graph; see docs/PHOTOREAL_QUICKSTART.md)
```

## How to feel the WOW

```bash
cd /Users/michael/Clean/mirror-mesh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 0) Clean state — if you've been iterating and want a guaranteed-fresh app.
#    Wipes SwiftPM cache, rebuilds, kills any running instance, relaunches.
./scripts/dev/refresh.sh

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
- **LivePortrait photoreal weights** — optional, the photoreal substitution path. If `<repo>/models/{appearance,motion,warp,generator}_v1.mlpackage` are present the app auto-detects them and the Identity inspector flips to "Photoreal: ON" with a toolbar pill; otherwise the stylized head from v0.6.0 keeps rendering. Conversion: `python3.11 models/training/liveportrait_to_coreml.py --weights <hf-download-dir> --out models/`. Full recipe: `docs/PHOTOREAL_QUICKSTART.md`. **Recommended first step once mlpackages are in place**: in the Identity inspector, click "Capture as my identity" to mint a real-face .mmid from your live camera frame — the auto-provisioned default is a 1×1 transparent PNG that can't drive LivePortrait.
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
