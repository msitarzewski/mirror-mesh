# Vendored: First Order Motion Model (FOMM)

This directory contains a snapshot of the model-architecture Python files from
[AliaksandrSiarohin/first-order-model](https://github.com/AliaksandrSiarohin/first-order-model),
sufficient to materialise the FOMM networks (`KPDetector`, `DenseMotionNetwork`,
`OcclusionAwareGenerator`) and load published checkpoints for CoreML
conversion.

## What is here

| File                     | Upstream path                  |
|--------------------------|--------------------------------|
| `keypoint_detector.py`   | `modules/keypoint_detector.py` |
| `dense_motion.py`        | `modules/dense_motion.py`      |
| `generator.py`           | `modules/generator.py`         |
| `util.py`                | `modules/util.py`              |
| `__init__.py`            | (added — package marker)       |

**Upstream commit**: `c0274845cb2dd8f0f2fe6da580d97b60fef90c91` (master, 2026-05-19 fetch)
**Upstream license**: MIT — full text in `LICENSES/FOMM-MIT.txt`

## What is NOT here

- **Weights** (`*.pth.tar`) — the user must download them from upstream; see
  `models/training/README.md` for the link and rationale.
- **Training code** (`train.py`, `frames_dataset.py`, etc.) — MirrorMesh does
  not retrain FOMM; we only consume published checkpoints.
- **Discriminator** (`discriminator.py`) — training-only, not used at
  inference time.
- **Configs** (`config/*.yaml`) — the conversion script hard-codes the
  `vox-256` hyperparameters because that is the published checkpoint variant
  we target. Users converting a different variant (`taichi-256`, `nemo-256`)
  edit `models/training/fomm_to_coreml.py` and pass a matching `.pth.tar`.

## Modifications from upstream

Single deliberate change in `util.py`: `SynchronizedBatchNorm2d` (multi-GPU
training primitive shipped in the `sync_batchnorm` extension that FOMM
distributes alongside `modules/`) is swapped for the stock
`torch.nn.BatchNorm2d`. At inference with `batch_size==1` they are
numerically identical, and only the stock form is recognised by
`coremltools`'s torch frontend. No other architectural changes.

All other files are byte-for-byte identical to the upstream snapshot apart
from the attribution header prepended to each.

## Per project rule R5 (model provenance)

The `.mlpackage` produced by `models/training/fomm_to_coreml.py` ships with
a `.provenance.json` sidecar (one per output: keypoint, motion, generator)
that records this directory's commit SHA, the user-supplied weight file's
SHA-256, conversion-script SHA, and the resulting mlpackage SHA. CI's
`models/verify_provenance.py` validates the sidecars at build time.
