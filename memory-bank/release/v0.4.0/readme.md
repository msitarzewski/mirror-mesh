# Release v0.4.0 — "Sustainable"

**Goal**: A polished, commercially-licensable, distributable MirrorMesh. License pivot to AGPL-3.0 + Commercial is done. The remaining work is finishing notarization, polishing the app UX so it stops looking like a CS-249 final, training the CoreML weights, and standing up commercial-inquiry plumbing.

**Started**: 2026-05-19 (license pivot landed first, see ADR-0014)

---

## Theme

v0.3.0 made it buildable. v0.4.0 makes it **sustainable** — both senses:
- Sustainable architecture: warnings cleaned up, source headers consistent, CI gates the DCO
- Sustainable business: commercial-license channel set up, app polished enough to demo to a paying customer

## Status

| # | Title | Status |
|---|-------|--------|
| **License pivot (M0)** | AGPL-3.0 + Commercial dual; ADR-0014 | ✅ done |
| **M31** | Source-header sweep (`SPDX-License-Identifier: AGPL-3.0-or-later`) + DCO CI check | ⚪ pending |
| **M32** | Finish notarization (gated on user's Team ID in `Local.xcconfig`) | ⚪ blocked on user |
| **M33** | Proper-app polish (the "derpy chicken" fix) — app icon, empty-state, watermark hero card, telemetry treatment, button hierarchy, auto-start synthetic preview | 🟡 in progress |
| **M34** | Real trained CoreML weights — run `models/training/blendshape_solver.py`, ship .mlpackage | ⚪ pending |
| **M35** | Commercial-inquiry plumbing — sales contact, terms summary page, license-request issue template | ⚪ pending |
| **M36** | Warning cleanup pass (Sendable warnings, naturalTimeScale deprecation, @preconcurrency annotations) | 🟡 in progress |
| **M37** | Live-camera UX (when user presses Start, the consent → permission → live preview path works cleanly in both `mirrormesh-app` and `MirrorMesh.app`) | ⚪ pending |
| **M38** | Settings persistence (UserDefaults round-trip for show-landmarks / show-avatar / watermark-visible) | ⚪ pending |
| **M39** | First public push (after M32) — README badges live, GitHub repo public, status visible | ⚪ blocked on M32 |
| **M40** | Paper draft v1 — fill in actual numbers from M27/M34/M17 measurements; submission-ready section pass | ⚪ pending |

## Notes

- M33 and M36 are bundled into the same commit run because they touch overlapping files (Pipeline.swift, ContentView.swift).
- M37 covers what user noticed today: "Camera UI is not present btw." Empty state sits at the gradient placeholder until Start Session is pressed; the consent/permission flow runs but the call-to-action is buried in the toolbar.

## Open inputs from user

- `DEVELOPMENT_TEAM` for `Local.xcconfig` (blocks M32, M39)
- App Store Connect API key for notarization (blocks M32)
- GitHub `<user>/<repo>` URL for badges + Homebrew tap URLs (blocks M39)
- Decision: train CoreML weights now or defer (M34 trigger)
