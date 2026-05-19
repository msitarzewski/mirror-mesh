# Release v0.5.0 — "Presence"

**Goal**: The avatar becomes the main view. The window stops being a fancy debug overlay and starts being a synthetic-presence experience. After this release, when someone opens MirrorMesh they see *themselves transformed*, not "themselves with dots on top."

**Theme**: Cross the line from "well-engineered watermarker" to "I have to show this to someone."

---

## The architectural inversion

| | v0.4.0 (now) | v0.5.0 (target) |
|---|---|---|
| Main view | Camera feed | Synthetic render (mesh / mask / mirror) |
| Camera | The whole frame | Small inspector PIP (toggleable) |
| Landmarks | Big green dots on face | Render hints, only shown in Wireframe style |
| Avatar | Cartoon emoji in corner | Replaced by mesh-driven output as the main view |

## Milestones

| # | Title | Status |
|---|-------|--------|
| **M41** | Mesh-from-landmarks renderer (Metal) — triangulated 3D surface driven by 76-pt landmarks, rendered as wireframe + textured surface | 🟡 in flight |
| **M42** | Three style modes (Wireframe / Mirror / Mask) — switchable in inspector; per-style hierarchy of source vs synthetic | ⚪ pending |
| **M43** | Camera-as-PIP — flip the layout so the synthetic render owns the hero slot; source camera collapses to a corner inspector (toggle in View menu) | ⚪ pending |
| **M44** | Style baked into recorded `.mov` (Recorder consumes the style-selected output, not the raw RenderedFrame) | ⚪ pending |
| **M34** | Real trained CoreML solver weights (carried over from v0.4.0) — feeds higher-fidelity blendshapes into the new mesh | ⚪ pending |
| **M38** | Settings persistence (UserDefaults round-trip) | ⚪ pending |
| **M37** | Live-camera UX polish (preview → consent → live transition, no flicker) | ⚪ pending |
| **M52** | App icon refresh to match the v0.5.0 visual identity (mesh motif) | ⚪ pending |

## Round structure (parallel agent dispatch)

Following the "3 agents max per round" lesson from v0.3.0:

**Round 1** (this turn):
- macOS Spatial/Metal Engineer → M41 (the big one)
- AI Engineer → M34 (CoreML training + ship)
- Mobile App Builder → M38 + M37 (settings persistence + UX polish)

**Round 2** (after Round 1 integrates):
- macOS Spatial/Metal Engineer → M42 (three styles)
- inline → M43 (camera-as-PIP layout flip)
- inline → M44 (recorder ingests styled output)

**Round 3** (polish):
- inline → M52 icon refresh

## Exit criteria

1. Opening the app shows your face transformed (wireframe by default, settable to Mirror or Mask)
2. The camera feed is a small toggleable PIP, not the dominant view
3. Style picker in the inspector switches between Wireframe / Mirror / Mask in real time
4. Recording produces a `.mov` of the chosen style, not the raw camera
5. Real CoreML weights drive the underlying coefficients
6. Settings persist across launches
7. All 46+ tests still passing
