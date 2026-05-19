# M27 — Real Trained CoreML Solver Weights

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M11
**Blocks**: M30

## Objective

Actually run `models/training/blendshape_solver.py` and ship the produced `.mlpackage`. v0.2.0 stubbed this; v0.3.0 finishes it.

## Deliverables

- `models/blendshape_solver_v1.mlpackage` — trained, signed, < 5 MB
- `models/blendshape_solver_v1.provenance.json` — sha256 filled in (was placeholder)
- `bench/scripts/compare_solvers.py` — runs both `geometric` and `coreml` scenarios against the fixture, prints per-coefficient mean error vs the geometric baseline
- `docs/coreml-solver.md` — what the model architecture is, what the training data was, how to reproduce
- Auto-download path: if the user clones the repo, the `.mlpackage` is fetched on first run with a checksum verify (per `techContext.md`)

## Verification

```bash
python3 models/training/blendshape_solver.py     # produces models/blendshape_solver_v1.mlpackage
swift run mirrormesh-bench --scenario bench/scenarios/fixture_coreml.json
python3 bench/scripts/compare_solvers.py bench/out/fixture_*.jsonl bench/out/fixture_coreml_*.jsonl
```

## Notes

- Training environment needs `torch` and `coremltools` — documented in `models/training/requirements.txt`
- Training is fast (synthetic data, ~10k samples, 2-layer MLP); should complete in <1 min on CPU
- The model approximates the geometric solver — it's a learnable proxy, not a quality leap. v0.4.0 would train against real-face landmarks with consented ground-truth ARKit coefficients
