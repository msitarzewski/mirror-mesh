# MirrorMesh — Active Context

**Updated**: 2026-05-20 (project paused — photoreal not visually working end-to-end)
**Current state machine position**: `PAUSED`
**Substate**: `IDLE` — maintainer set the project down. Resume when curiosity returns.

**Photoreal status — honest**: All the *infrastructure* is wired (mlpackage detection, identity gate, PhotorealStage, composite-at-bbox renderer, capture-as-identity, test persona, M37 handoff fix). Tests are green. The pipeline DOES call into the LivePortrait inference graph. But the rendered visual output is broken — final user screenshot showed a peach-colored blob with horizontal banding artifacts where the photoreal face should have been. Two known failure modes:

1. **Self-as-source degeneracy**: the operator's captured face → driven by the operator's own face = output looks like passthrough. Visually indistinguishable from "nothing happened." Was misread as a positive several times across this session.
2. **Test persona produces garbage**: the procedural cartoony face (`TestPersona.swift`) doesn't have the structure LivePortrait's `MotionExtractor` was trained to find keypoints on, so the warp+generator output is incoherent — peach blob + banding.

What probably needs investigation when resuming (none done yet, all hypothesis):
- Run `PhotorealBackend.reenact` standalone with a known-good 256×256 face PNG (e.g., a celebrity headshot from LivePortrait's own demo set) and compare against upstream's Python reference output on the same input. If the Swift output is also garbage, the inference graph has a math bug. If the Swift output matches reference, the bug is downstream in the composite or somewhere else in the Swift glue.
- The `transform_keypoint` Swift port (`PhotorealBackend.transformKeypoint`) has unit tests for determinism and shape, but no value-equivalence test against a Python reference. Worth adding.
- Verify color space: the PNG → MLMultiArray → inference → MLMultiArray → CVPixelBuffer chain crosses sRGB/linear conventions. A mishandled gamma at any step would produce washed-out / incorrect-luminance output. The banding artifact in the final screenshot is consistent with channel-order or precision corruption.
- `PixelBufferConversion` writes `rgba[p+3] = 255` (alpha opaque) — confirmed. Not the bug.

What IS working and ships as v1.0:
- Trust layer (consent bundles, watermark, chirp, manifest, R12 refusals enforced)
- Stylized 3D head reenactment in Wireframe (parametric, license-clean)
- Apple on-device Speech (transcription works)
- Translation pipeline (Ollama + TTS + lip-sync driver — CLI works, app integration wired)
- Capture-as-identity mint flow (Vision face crop + signed .mmid persistence works)
- Notarization scaffolding (waits on user-paste Team ID)
- Paper draft v1 (7.5k words, real benches)
- 209 tests / 40 suites green

Lesson recorded: for ML model integration work, run the inference standalone against a known-good reference input and compare against the upstream Python output BEFORE wiring it into the UI. Optimistic interpretation of UI screenshots wasted real time today.

---

## License pivot — ADR-0015

The maintainer clarified intent: research project, no monetization, want to prevent others from monetizing derivatives too. AGPL-3.0-only achieves this without the dual-license dance. ADR-0014's Commercial half is being dropped; LICENSE-COMMERCIAL.md is being deleted; NOTICE.md is being added; all docs (README, RELEASE_NOTES, paper) are being updated to single-license posture. LivePortrait is unblocked because its research-only InsightFace dependency is satisfied by the maintainer's research use.

---

## Current Focus

**v0.6.0 "Identity" — ✅ COMPLETE 2026-05-19**

M43 + M52 + M53 + M55 + M56 + M57 + M58 + M59 all shipped via three parallel agents + orchestrator integration. Test count 66/17 → 110/23.

Pivot taken (per user's "we can always fix things"): M56 ships as a **stylized parameterized head** driven by 76-point landmarks, license-clean and `.stylizedNonHuman`-scheme-aligned. The FOMM photoreal path is scaffolded but requires manual weight download (models/training/README.md). The stylized path renders today.

Wave 1 deliverables:
- `Sources/MirrorMeshReenact/` — FaceReenactor actor, StylizedHead (266 verts, 18 blendshapes), ReenactStage, PhotorealBackend stub
- `Sources/MirrorMeshRender/Shaders/StylizedHead.metal` + `StylizedHeadRenderer.swift` — Pixar-stylized faceted fill with cyan rim light, edge fade
- `Sources/mirrormesh-consent/` — CLI producing signed .mmid bundles; R1 guard requires literal `--consent-confirm` phrase for third-party
- `Sources/MirrorMeshAppKit/IdentityInspector.swift` — settings panel section with NSOpenPanel + verifier
- `Sources/MirrorMeshAppKit/DisclosureChirp.swift` — A4→E5 sine sweep on real session start, locked-on in release
- `models/external/fomm/` — vendored FOMM source (MIT) with provenance; LivePortrait rejected for InsightFace research-only weight dep
- Renderer.render() gains optional stylizedHead payload; Pipeline ReenactStage between solver and render

**v0.7.0/v0.8.0/v0.9.0/v1.0.0 — in flight 2026-05-19 (Wave 2)**

Three parallel agents dispatched:
- **v0.7.0 "Voice"**: Apple on-device Speech framework replacing the mock Whisper backend
- **v0.8.0 "Accessibility"**: multilingual lip-sync — Ollama translation + AVSpeechSynthesizer + audio-amplitude → blendshape driver feeding the stylized head from v0.6.0
- **v0.9.0/v1.0.0**: ASSETS-targeted paper draft + RELEASE_NOTES_v1.0.0.md + README.md rewrite + CONSENT_PROTOCOL.md

Status boards: `memory-bank/release/v0.7.0/readme.md`, `v0.8.0/readme.md`, `v0.9.0/readme.md`, `v1.0.0/readme.md`.

## Releases delivered today

```
v0.1.0  ✅  First Light       v0.4.0  ✅  Sustainable
v0.2.0  ✅  Living Window     v0.5.0  ✅  Presence
v0.3.0  ✅  Ship It           v0.6.0  🟡  Identity
```

## Hardware budget for ML decisions

User's machine: **M5 Max / 128 GB RAM / 40 GPU cores / 8 TB storage**.

This is the consumer-Apple-Silicon ceiling as of 2026. ML model selection is NOT memory- or compute-constrained on this device. Default to higher-fidelity models when license + license permits. The paper's "commodity Apple Silicon" claim, however, requires we also run the M3 Mac mini bench numbers — don't publish only-this-machine results.

## Open user inputs (carry-forward)

These don't block M56 but unlock other work:
- **Apple Developer Team ID** → paste into `Local.xcconfig` (v0.7.0 notarization)
- **App Store Connect API key** → `xcrun notarytool store-credentials mirrormesh-notary` (v0.7.0)
- **GitHub `<user>/<repo>` URL** → CI badge + Homebrew tap URLs (v0.7.0)
- **LivePortrait license re-read** — currently filed as research-only; if it's clarified to be compatible with AGPL+Commercial dual, M56 should use it instead of FOMM. Otherwise FOMM.
- **Pick accessibility-first application** (v0.8.0) — gaze correction / paralysis compensation / multilingual lip-sync.
- **Pick paper venue** (v0.9.0) — SIGGRAPH / CHI / ASSETS / ACM MM.

## State transition log

- 2026-05-19 — Initial scaffold. `PLAN`/`IDLE` after creating core Memory Bank files.
- 2026-05-19 — Release v0.1.0 → v0.5.0 in one extended session. See `tasks/2026-05/250519_session-arc.md` for the full play-by-play.
- 2026-05-19 — Xcode installed. ADR-0012 toolchain pivot.
- 2026-05-19 — License pivoted Apache-2.0 → AGPL-3.0 + Commercial (ADR-0014). Project rule R13 expanded; R14 added.
- 2026-05-19 — v0.6.0 kicked off after the LinkedIn deepfake-warning video clarified the target. M43 + M55 landed in one commit. `BUILD`/`IDLE`.

## Recovery sequence after `/compact` or fresh session

1. Read `RESUME.md` at repo root (one screen — quick state)
2. Read this file (current focus + open items)
3. Read `memory-bank/release/v0.6.0/readme.md` (active milestone plan)
4. Read `memory-bank/tasks/2026-05/250519_session-arc.md` if you need the full history
5. `git log --oneline | head -10` for recent commits
6. `swift build && swift test ...` to confirm green-state
