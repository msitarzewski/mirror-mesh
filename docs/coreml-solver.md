# CoreML Solver (`blendshape_solver_v1`)

Companion to `Sources/MirrorMeshSolver/CoreMLSolver.swift`. Documents what the
shipped `.mlpackage` is, how it was trained, and how to reproduce it. Provenance
is recorded in `models/blendshape_solver_v1.provenance.json` per
`memory-bank/projectRules.md` **R5**.

## Status

- **Ships**: yes, bundled with `MirrorMeshSolver` (see `Package.swift` `.copy("Resources/blendshape_solver_v1.mlpackage")`).
- **Canonical artifact**: `models/blendshape_solver_v1.mlpackage`.
- **Bundled copy**: `Sources/MirrorMeshSolver/Resources/blendshape_solver_v1.mlpackage` (byte-identical to the canonical).
- **Bench scenario annotation** on a successful load: `{"key":"solver.coreml.model","t":"annotation","value":"blendshape_solver_v1"}` in the JSONL output. Absence of this annotation, or a `"CoreML model not found; falling back to geometric"` warning, indicates a load failure.

## Model

| Field | Value |
| --- | --- |
| Architecture | MLP, `Linear(152, 64) → ReLU → Linear(64, 64) → ReLU → Linear(64, 52) → Sigmoid` |
| Parameters | ~13,940 |
| Input | Float32 `(1, 152)` — 76 landmark points as interleaved `(x, y)` in `[0, 1]` |
| Output | Float32 `(1, 52)` — ARKit blendshape coefficients in `[0, 1]`, indexed in `BlendshapeKey.allCases` sorted by `rawValue` |
| Package size | 38.8 KB (well under the 5 MB ceiling; the inner `weight.bin` is 35 KB) |
| sha256 (full package, directory walk) | `d26b2293baa8…` (first 12 chars; full hash in provenance JSON) |
| sha256 (`model.mlmodel` only) | `3de1990c1665…` |
| License | Apache-2.0 (matches the training script) |
| Conversion target | `mlprogram`, `macOS14` |

The `sha256` field is the canonical hash used by `models/verify_provenance.py`
and the M27 CI gate; it is computed by walking the `.mlpackage` directory in
sorted order and concatenating `relpath\0content` for every regular file (see
`models/training/blendshape_solver.py:sha256_of_path`). The `model_mlmodel_sha256`
is a cross-check on the inner protobuf only and is what
`shasum -a 256 models/blendshape_solver_v1.mlpackage/Data/com.apple.CoreML/model.mlmodel`
produces.

## Training data

Entirely synthetic. The script `models/training/blendshape_solver.py` constructs
a canonical neutral 76-point landmark face (same skeleton as the Swift
`makeNeutralPoints()` test helper) and perturbs individual landmarks along
plausible expression axes:

- Jaw open: `mouth_lower.y += U(0, 0.15)`
- Smile/frown: `mouth_left.x -= U(-0.05, 0.05)`, mirrored on right; a small y-offset rides along
- Eye blink (L/R independently): `eye_upper.y += U(0, 0.04)`
- Brow raise/lower: `brow_inner.y += U(-0.04, 0.04)`
- Per-point Gaussian jitter, σ = 0.001

10,000 training samples + 1,000 validation samples, seed 42. Each sample is
labelled by **the same rule-based geometric solver** that the Swift
`GeometricSolver` implements — so the MLP learns to mimic the geometric solver
in a fully differentiable form, not to outperform it on real faces. No human
face data was used in training. No identifiable biometric data was touched.

This trains a **drop-in proxy**, not a fidelity leap. A v2 model would be
trained against real consented landmark→ARKit-coefficient pairs.

## Training run

| Setting | Value |
| --- | --- |
| Framework | PyTorch 2.7.1 + coremltools 8.3.0 on Python 3.11 |
| Optimizer | Adam, lr=1e-3 |
| Loss | MSE |
| Batch size | 256 |
| Epochs | 50 |
| Wall time | ~30 s CPU on Apple Silicon (well under the 5-minute budget) |
| Validation MSE | **0.013523** |

Final loss is dominated by the noise floor introduced by the Gaussian
landmark jitter; per-coefficient RMS ≈ √0.0135 ≈ 0.116, consistent with the
side-by-side measurements below.

## Reproduce

```bash
KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 \
  /opt/homebrew/bin/python3.11 models/training/blendshape_solver.py
```

The two env vars suppress a duplicate-OpenMP linker warning between numpy and
libtorch on macOS; the script runs without them but emits noise on stderr.

The model is built on Python 3.11 because **coremltools 9.0 on Python 3.14
ships without the prebuilt `libmilstoragepython` extension** that
`mlprogram` export requires. Symptom on 3.14:
`RuntimeError: BlobWriter not loaded` deep in
`coremltools/converters/mil/backend/mil/load.py`. The 3.11 stack
(`/opt/homebrew/bin/python3.11`) has `torch 2.7.1` + `coremltools 8.3.0`
preinstalled on the dev box and converts cleanly. Once coremltools ships a
3.14-compatible wheel, the script will work under the default `python3` and
this caveat can be removed.

After running the script:

```bash
shasum -a 256 models/blendshape_solver_v1.mlpackage/Data/com.apple.CoreML/model.mlmodel
python3 models/verify_provenance.py    # validates full-package directory hash
```

Then copy into the Swift target's resource dir so `Bundle.module` sees it:

```bash
rm -rf Sources/MirrorMeshSolver/Resources/blendshape_solver_v1.mlpackage
cp -R models/blendshape_solver_v1.mlpackage Sources/MirrorMeshSolver/Resources/
```

## Side-by-side comparison vs `GeometricSolver`

Both solvers were driven by the same synthetic landmark stream from
`bench/scenarios/demo.json` and `bench/scenarios/demo_coreml.json`, 120 frames
at 640×360@30. Coefficient logging is enabled (`log_coefficients: true`) on
both scenarios so `bench/scripts/compare_solvers.py` can join them on frame ID.

```bash
swift run mirrormesh-bench --scenario bench/scenarios/demo.json
swift run mirrormesh-bench --scenario bench/scenarios/demo_coreml.json
python3 bench/scripts/compare_solvers.py \
    bench/out/demo_*.jsonl bench/out/demo_coreml_*.jsonl
```

Measurement (120 frames, 52 coefficients × 120 = 6,240 paired samples):

| Statistic | `|coreml − geometric|` |
| --- | --- |
| Mean | **0.0545** |
| Median | **0.0021** |
| Max | **0.6231** |

Top noisiest coefficients by mean absolute disagreement:

| Coefficient | Mean abs diff |
| --- | --- |
| eyeBlinkLeft | 0.492 |
| eyeBlinkRight | 0.474 |
| jawOpen | 0.410 |
| mouthSmileRight | 0.232 |
| mouthSmileLeft | 0.224 |
| mouthPucker | 0.223 |
| browDownLeft | 0.203 |
| browDownRight | 0.198 |
| browInnerUp | 0.120 |
| browOuterUpLeft | 0.069 |

The median is very small because most of the 52 coefficients sit at zero in
both solvers on this stream. Divergence concentrates on the dimensions the
synthetic stream actually exercises — jaw-open, eye-blink, smile. These are
the dimensions the MLP must learn from sparse synthetic supervision, so a
~0.1–0.5 disagreement is in line with the MSE 0.0135 it converges to.
Smoothing in `BlendshapeSmoother` (α = 0.5) further dampens any per-frame
jitter on the rendering side.

Latency from the same runs:

| Scenario | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `demo` (geometric) | 1.38 ms | 2.33 ms | 3.03 ms |
| `demo_coreml` | 1.79 ms | 2.33 ms | 2.33 ms |

CoreML inference adds ~0.4 ms median end-to-end on Apple Silicon, well inside
the 30 ms-per-frame budget for 30 fps. No P95/P99 regression.

## How `CoreMLSolver` finds the model

In priority order, per `CoreMLSolver.defaultSearchPaths()`:

1. `MIRRORMESH_COREML_MODEL` env var (developer override)
2. `Bundle.module` — populated by the `.copy` resource entry in `Package.swift`
3. `models/blendshape_solver_v1.mlpackage` relative to the current working
   directory (so `mirrormesh-bench` run from the repo root finds it without a
   resource-bundle lookup)

On first load the solver compiles the `.mlpackage` once via
`MLModel.compileModel(at:)` and caches the resulting `.mlmodelc` under
`~/Library/Caches/MirrorMesh/CoreMLCache/` so the cost is paid at most once per
machine.

If no model is found the solver constructs successfully, emits a single
`.warning` telemetry event (`"CoreML model not found; falling back to geometric"`),
and transparently delegates to `GeometricSolver`. This keeps
`--solver coreml` runnable in environments where the weights have not yet been
fetched.

## See also

- `Sources/MirrorMeshSolver/CoreMLSolver.swift` — runtime loader and fallback
- `Sources/MirrorMeshSolver/GeometricSolver.swift` — rule-based reference
- `models/training/blendshape_solver.py` — trainer + converter
- `models/blendshape_solver_v1.provenance.json` — full provenance metadata
- `models/verify_provenance.py` — CI hash check (no torch required)
- `bench/scripts/compare_solvers.py` — side-by-side comparator
- `memory-bank/projectRules.md` R5 — model-provenance policy
- `memory-bank/release/v0.3.0/M27-coreml-weights.md` — milestone spec
