# Blendshape Mapping (M5 Geometric Solver)

This is the mapping used by `MirrorMeshSolver.GeometricSolver` to translate 2D landmark deltas
(relative to the neutral pose captured by `NeutralPoseCalibrator`) into ARKit-52 blendshape
coefficients. Coefficients that cannot be derived from monocular 2D landmarks are emitted as
**zero** rather than fabricated.

All landmark indices reference the 76-point Vision schema documented in
`docs/landmark-schema.md`. Indices are defined as constants in
`Sources/MirrorMeshSolver/MirrorMeshSolver.swift` (`LandmarkIndex`).

| Coefficient(s)                          | Landmark inputs                                                 | Formula (delta from neutral)                                                                       | Notes |
|-----------------------------------------|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------|-------|
| `jawOpen`                               | `mouthUpperLip` (44), `mouthLowerLip` (52)                      | `((lower.y - upper.y) - neutral) / faceH * 6`                                                      | Vertical lip gap, normalized by face bbox height |
| `mouthSmileLeft` / `mouthSmileRight`    | `mouthLeftCorner` (40), `mouthRightCorner` (48)                 | Outward horizontal corner displacement minus vertical drop, scaled                                 | Smile pulls corners out and slightly up |
| `mouthFrownLeft` / `mouthFrownRight`    | `mouthLeftCorner`, `mouthRightCorner`                           | Vertical corner drop (`dy > 0`)                                                                    | Mirror of smile's vertical component |
| `mouthLeft` / `mouthRight`              | `mouthLeftCorner`, `mouthRightCorner`                           | Net horizontal mouth-center shift                                                                  | Captures jaw lateral movement |
| `eyeBlinkLeft` / `eyeBlinkRight`        | `leftEyeUpper` (18) / `leftEyeLower` (22), right pair (26, 30)  | `1 - (current openness / neutral openness)`                                                        | Clamped to [0,1] |
| `eyeWideLeft` / `eyeWideRight`          | Same as blink                                                   | `ratio - 1`                                                                                        | Above-neutral openness reads as wide |
| `browInnerUp`                           | `leftBrowInner` (64), `rightBrowInner` (70)                     | Average inner-brow rise (`-dy`)                                                                    | Negative `y` is up in our top-left-origin frame |
| `browDownLeft` / `browDownRight`        | `leftBrowInner`, `rightBrowInner`                               | `dy` (positive = down)                                                                             | |
| `browOuterUpLeft` / `browOuterUpRight`  | `leftBrowOuter` (67), `rightBrowOuter` (73)                     | `-dy`                                                                                              | |
| `mouthPucker`                           | Mouth outer ring (40..55)                                       | `(1 - widthRatio) + (1 - heightRatio) * 0.5`                                                       | Both axes shrink |
| `mouthFunnel`                           | Mouth outer ring                                                | `(1 - widthRatio) + (heightRatio - 1) * 0.5`                                                       | Narrower horizontally, taller vertically |
| `cheekPuff`                             | Face outline (0..15)                                            | `widthRatio - 1`                                                                                   | Coarse 2D approximation |
| `noseSneerLeft` / `noseSneerRight`      | `noseTip` (36)                                                  | `-dy`                                                                                              | Symmetric L/R in v0.1.0 |
| `tongueOut`                             | n/a                                                             | **0**                                                                                              | Not derivable from 2D landmarks |
| `eyeLookIn/Out/Up/Down*`                | n/a                                                             | **0**                                                                                              | Requires iris/gaze detection (future ML solver) |
| `jawForward`, `jawLeft`, `jawRight`     | n/a                                                             | **0**                                                                                              | `jawLeft`/`jawRight` partially covered by `mouthLeft`/`mouthRight` |
| `mouthClose`, `mouthDimple*`, `mouthStretch*`, `mouthRoll*`, `mouthShrug*`, `mouthPress*`, `mouthLowerDown*`, `mouthUpperUp*`, `eyeSquint*`, `cheekSquint*` | n/a | **0** | Requires inner-mouth / micro-feature detail beyond the 76-pt monocular schema; left for the future ML solver |

## Processing pipeline

1. `NeutralPoseCalibrator` averages the first 30 frames (alpha 0.1) to produce a neutral pose.
2. Per frame, raw coefficients are computed from the formulas above.
3. A hysteresis dead-band (default 0.02) zeros out sub-jitter motion.
4. `BlendshapeSmoother` applies per-key exponential smoothing (alpha 0.5).
5. All values are clamped to `[0, 1]`.
6. The result is emitted as a `BlendshapeFrame` and a `solver` telemetry span is recorded.

## Limitations

- All depth-, iris-, and inner-mouth-dependent coefficients are 0 in v0.1.0.
- Brow indices in the 64..75 "detail" band are best-effort; the band's exact ordering may vary
  with the Vision revision in use.
- Gains and the hysteresis threshold are tuned empirically and exposed for future tuning.
