# MirrorMesh — Resume

> **One-screen state-of-the-project. Read this first after a /compact or fresh session.**

## Status as of 2026-05-19

**Working app**: live camera → real Vision landmarks → geometric or CoreML solver → Metal rendering (Wireframe / Mirror / Mask styles) → Ed25519 watermark + signed manifest → SwiftUI window with operator PIP. P50 ~11 ms with real Vision, ~1.4 ms synthetic.

**11 commits on `main`**. 66 tests / 17 suites green under `swift test`. Hardware: user is on **M5 Max / 128 GB / 40 GPU cores** — ML model selection is unconstrained.

**License**: AGPL-3.0 + Commercial dual. Copyright "Michael Sitarzewski". DCO sign-off on commits.

## Where we are in the release arc

```
v0.1.0  ✅  First Light       — pipeline + watermark + manifest
v0.2.0  ✅  Living Window     — Xcode tests + app exec + recorder + signposts
v0.3.0  ✅  Ship It           — xcodegen + signing scaffolding + WebRTC + Whisper stub + paper
v0.4.0  ✅  Sustainable       — AGPL pivot + Glass UI + menu + icon + 3 critical bug fixes
v0.5.0  ✅  Presence          — face mesh + CoreML weights + RenderStyle picker + handoff polish
v0.6.0  🟡  Identity          — M43 PIP ✅, M55 ConsentedIdentity ✅, M56 FOMM ⚪ ← NEXT
v0.7.0  ⚪  Voice             — Whisper real + RVC
v0.8.0  ⚪  Accessibility app — pick one of three (user decision)
v0.9.0  ⚪  Paper draft v1
v1.0.0  ⚪  Ship
```

## The single next action

**Start M56 — FOMM CoreML port.** This is the technical work that turns the project from "synthetic-mesh-overlay-with-watermarks" into "wear-a-different-face-in-realtime-with-watermarks." It's the magic that backs the entire project pitch.

```bash
cd /Users/michael/Clean/mirror-mesh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Pre-work for the session:
# 1. Re-read LivePortrait's license — currently "research-only" but may have clarified;
#    if it's compatible with AGPL+Commercial, use it instead of FOMM (higher fidelity).
# 2. Otherwise: vendor github.com/AliaksandrSiarohin/first-order-model as a submodule
#    or copy the model definitions.

# M56 deliverables:
# - New module Sources/MirrorMeshReenact/
#   - FaceReenactor actor (load gate requires verified ConsentedIdentity — see M55)
#   - KeypointDetector, DenseMotionEstimator, Generator (CoreML wrappers)
# - Conversion script models/training/fomm_to_coreml.py
# - models/fomm_v1.mlpackage shipped via .copy in Package.swift
# - Pipeline integration: ReenactStage between Vision and Render
# - bench/scenarios/reenact_fixture.json
# - Latency target: < 50 ms FOMM path on M5 Max
```

## What's loaded into the project — the must-knows

1. **Toolchain**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (system python3 is 3.14; pin scripts to python3.11)
2. **R13 + R14** are the two rules that catch people. Read them once.
3. **`memory-bank/release/vX.Y.0/readme.md`** is the per-release plan; the active one is v0.6.0
4. **M55's `ConsentedIdentity` bundle is the gate for M56.** Without a verified bundle, `FaceReenactor.init` should refuse.
5. **The user's hardware is M5 Max**. Don't pick low-end models thinking they're constrained.
6. **Open user inputs that block other work** (not M56): Apple Developer Team ID (notarization), GitHub repo URL (CI badge + Homebrew tap), accessibility-app pick (v0.8.0), paper venue (v0.9.0).

## Recover commands

```bash
# Where am I?
cat memory-bank/activeContext.md | head -20
cat memory-bank/release/v0.6.0/readme.md
git log --oneline | head -10

# Is it still working?
swift build && swift test --skip MirrorMeshStreamTests --skip MirrorMeshVoiceTests --skip MirrorMeshVirtualCameraTests --skip MirrorMeshMediaPipeTests

# Run the app
swift run mirrormesh-app    # or open MirrorMesh.xcodeproj
```

## Session arc

The full play-by-play of how we got here lives at **`memory-bank/tasks/2026-05/250519_session-arc.md`** (409 lines). Read it if you need to understand decisions; skim if you just want the current state.

---

*Last updated 2026-05-19 by Claude Opus 4.7. If this file is older than the most recent commit, trust the commit log over this file.*
