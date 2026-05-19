# M5 — Expression Solver (Blendshapes)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M4
**Blocks**: M6, M10

## Objective

Convert 2D landmark positions into a stable set of blendshape coefficients (ARKit-compatible names), using a geometric solver only — no CoreML yet.

## Deliverables

In `Sources/MirrorMeshSolver/`:

- `BlendshapeFrame.swift` — `{ frameID, coefficients: [BlendshapeKey: Float] }`
- `BlendshapeKey.swift` — enum of the ARKit-52 set (jawOpen, mouthSmileLeft, browInnerUp, eyeBlinkLeft, …)
- `GeometricSolver.swift` — derive coefficients from landmark deltas vs a neutral pose baseline
- `NeutralPoseCalibrator.swift` — captures the first ~30 frames as baseline; configurable manual reset

## Behavior

- First N frames calibrate neutral pose; thereafter coefficients are deltas
- Output values clamped to [0, 1] per ARKit conventions
- Hysteresis on small movements to suppress jitter
- Emits `solver.coefficients` event per frame with sparse non-zero entries

## Tests

- Synthetic landmark drift -> expected coefficient response (e.g., move chin landmarks down -> jawOpen rises)
- Calibration converges within 30 frames on stable input
- Coefficients clamp correctly under extreme inputs

## Notes

- This is intentionally a coarse first cut; an ML-based solver is a future milestone
- Document the mapping table in `docs/blendshape-mapping.md` for the paper
