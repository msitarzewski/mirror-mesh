# Release v1.0.0 — "Ship"

**Goal**: Notarized, distributable .app with release notes and a tagged GitHub release. The trust layer is no longer just a research artifact — it's something a stranger can download and run.

**Theme**: Software exists in code form; it becomes a tool when someone outside the project can use it. v1.0.0 is the bridge from "engineering deliverable" to "publicly usable tool."

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M79** | `RELEASE_NOTES_v1.0.0.md` — full version history rollup | 🟡 in flight |
| **M80** | `README.md` rewrite (front-door content) | 🟡 in flight |
| **M81** | Notarization scaffolding — needs `DEVELOPMENT_TEAM` Team ID from user | ⚪ blocked on user input |
| **M82** | App Store Connect API key install (`xcrun notarytool store-credentials`) | ⚪ blocked on user input |
| **M83** | GitHub release artifact assembly (signed .app.zip + dSYM) | ⚪ blocked on M81 |
| **M84** | Homebrew tap (`brew install msitarzewski/mirrormesh/mirrormesh`) | ⚪ blocked on M83 |
| **M85** | DCO + CONTRIBUTING.md final | ⚪ |
| **M86** | License files final (AGPL-3.0-only + DCO + NOTICE.md per ADR-0015) | ✅ |
| **M87** | Demo video for README header | ⚪ post-1.0 |
| **M88** | Photoreal inference wiring (LivePortrait CoreML graph) | ✅ |
| **M89** | Photoreal UX feedback (inspector + toolbar pill + subtitles) | ✅ |
| **M90** | Capture-as-identity UX (mint .mmid from live frame) | ✅ |
| **M91** | transform_keypoint composition for expressive driving | ✅ |
| **M92** | FOMM photoreal inference parity (kind: .fomm) | ✅ |
| **M93** | scripts/dev/refresh.sh clean-rebuild helper | ✅ |

## Exit criteria

1. `https://github.com/msitarzewski/mirrormesh/releases/tag/v1.0.0` exists with a signed + notarized .app.zip
2. `brew install msitarzewski/mirrormesh/mirrormesh` works for a stranger
3. README.md gets a new visitor from "what is this" to "running the demo" in under 5 minutes
4. License + DCO are clear; commercial customers know where to ask
