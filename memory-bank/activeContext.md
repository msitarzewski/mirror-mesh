# MirrorMesh — Active Context

**Updated**: 2026-05-19 (end of long session — v0.6.0 in flight)
**Current state machine position**: `BUILD` (v0.6.0 — M56 next)
**Substate**: `IDLE` (handoff point — see `RESUME.md` at repo root)

---

## Current Focus

**v0.6.0 "Identity" — in progress 2026-05-19**

Theme: real face-reenactment on Apple Silicon. The "wear a different face" magic from Arlo Gilbert's deepfake-warning video, rebuilt with MirrorMesh's trust layer intact.

What's landed in v0.6.0 so far:
- **M43** — Camera-as-PIP overlay (`OperatorPIPView`). Pipeline gained `setOnCapture(_:)`; PipelineViewModel exposes `latestCapturedFrame`. PIP visible in Mirror/Mask styles only. Layout matches the LinkedIn inspiration but inverted ethics — operator small, synthetic puppet hero.
- **M55** — `ConsentedIdentity` Codable struct + bundle format + Ed25519-signed verifier. `IdentityConsentText.v1` is the disclosure subjects sign. 6-test suite covers signed-bundle-verifies / tampered-png-rejected / tampered-header-rejected / out-of-scope-rejected / write+read-roundtrip / disclosure-hash-stable.

What's next in v0.6.0 (single big rock):
- **M56** — FOMM CoreML port. New `MirrorMeshReenact` module. Three CoreML submodels (keypoint / motion / generator). `FaceReenactor` actor refuses to load without a verified `ConsentedIdentity`. Pipeline gains a `ReenactStage` between Vision and Render. See `RESUME.md` for the kickoff recipe.

Other v0.6.0 pending:
- **M52** App icon refresh to mesh motif (~15 min)
- **M53** Mask polish — hide cartoon `AvatarMask` in non-Wireframe styles (~15 min)
- **M57** `mirrormesh-consent` CLI — blocked on M55 ✅ now unblocked
- **M58** Identity-load UX in app — blocked on M56
- **M59** Audible disclosure chirp

Status board: `memory-bank/release/v0.6.0/readme.md`.

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
