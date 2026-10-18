# Tasks — 2026-10

## Summary

October 2026: MirrorMesh un-shelved. New main line: a code-authored expressive avatar (SDF head in
Metal, ~2 ms/frame) with accessibility transforms and a consented-portrait likeness fit, replacing
"make LivePortrait real-time" as the path forward.

## Tasks Completed

### 2026-10-18: Expressive avatar + accessibility transforms + portrait likeness
- SDF head driven by ARKit-52 coefficients, pose and pupil-measured gaze
- Symmetry assist / expression gain / eye-contact assist, disclosed in the manifest
- Portrait likeness: Vision landmarks + person segmentation + Core ML depth (Depth Anything V2 Small)
- Files: `ExpressiveHead.metal`, `ExpressiveHeadRenderer.swift`, `PortraitAnalyzer.swift`,
  `ExpressionTransform.swift`, `AvatarInspector.swift`, Pipeline/Solver/Vision/Core extensions
- Pattern: render → look → fix loop with preview sheets; goldens + property tests
- See: [261018_expressive-avatar.md](./261018_expressive-avatar.md)

## In Progress

- Milestone ID for this work (maintainer to assign)

## Blocked / Open Questions

- Notarization still waits on Team ID + App Store Connect key (unchanged since May)
