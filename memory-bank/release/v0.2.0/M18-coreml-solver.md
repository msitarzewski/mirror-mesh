# M18 — CoreML Expression Solver

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M20

## Objective

An alternative `ExpressionSolver` implementation backed by a CoreML model that takes the 76-point landmark vector as input and produces blendshape coefficients. The existing geometric solver stays as a fallback. The point is to **measure** — quantify quality and latency vs the geometric solver and document the tradeoff for the paper.

## Deliverables

- A bundled CoreML model file at `models/blendshape_solver_v1.mlpackage` (or `.mlmodel`)
  - Provenance documented in `models/blendshape_solver_v1.provenance.json` per `projectRules.md` R5
  - **Acceptable sources**: a training script that we author (`models/training/blendshape_solver.py`) producing a small MLP trained on a synthetic landmark→ARKit-coefficient dataset, OR a permissive-license pre-trained model with documented origin
  - **Not acceptable**: a model with unclear provenance, or trained on non-consenting face data
- `Sources/MirrorMeshSolver/CoreMLSolver.swift` — `public final class CoreMLSolver` conforming to a new protocol `public protocol ExpressionSolver { func solve(_ landmarks: LandmarkFrame) -> BlendshapeFrame }`
- `GeometricSolver` retrofitted to conform to the same protocol
- `Pipeline` gains a `solverKind: SolverKind` option (`.geometric` | `.coreml`)
- Bench scenarios can pick a solver via `"solver": "coreml" | "geometric"`
- A side-by-side test: run both solvers on the fixture clip from M15, log coefficient deltas

## Behavior

```bash
swift run mirrormesh-bench --scenario bench/scenarios/fixture.json   # uses default solver
swift run mirrormesh-bench --scenario bench/scenarios/fixture_coreml.json   # uses CoreML
python3 bench/scripts/diff_coefficients.py geometric.jsonl coreml.jsonl
```

## Verification

- Both solvers produce coefficients clamped to [0,1]
- CoreML solver latency P95 measured and recorded
- Quality is **measured**, not asserted — the milestone is data collection, not "CoreML is better"

## Notes

- The model lives outside the main repo per `techContext.md` (model binaries fetched on first run with consent); v0.2.0 may bundle a small synthetic-trained model directly if size is < 5 MB
- Training script is illustrative; not part of the runtime
