# Vendored: LivePortrait

This directory contains a snapshot of the model-architecture Python files
from [KwaiVGI/LivePortrait](https://github.com/KwaiVGI/LivePortrait),
sufficient to materialise the four LivePortrait inference networks
(`AppearanceFeatureExtractor`, `MotionExtractor`, `WarpingNetwork`,
`SPADEDecoder`) and load published checkpoints for CoreML conversion.

LivePortrait is the **recommended** photorealistic identity-transfer
backend as of v0.6.0 (per ADR-0015). The vendored FOMM scaffolding at
`models/external/fomm/` is retained as a license-clean fallback — both
backends coexist behind `Sources/MirrorMeshReenact/PhotorealBackend.swift`
and the operator picks which `.mlpackage` set to load.

## What is here

| File                                  | Upstream path                                |
|---------------------------------------|----------------------------------------------|
| `__init__.py`                         | (added — package marker)                     |
| `appearance_feature_extractor.py`     | `src/modules/appearance_feature_extractor.py` |
| `convnextv2.py`                       | `src/modules/convnextv2.py`                  |
| `dense_motion.py`                     | `src/modules/dense_motion.py`                |
| `motion_extractor.py`                 | `src/modules/motion_extractor.py`            |
| `spade_generator.py`                  | `src/modules/spade_generator.py`             |
| `stitching_retargeting_network.py`    | `src/modules/stitching_retargeting_network.py` |
| `util.py`                             | `src/modules/util.py`                        |
| `warping_network.py`                  | `src/modules/warping_network.py`             |

**Upstream commit**: `49784e879821538ecda5c8e4ca0472f4cb6236cf`
(main, 2026-05-20 fetch)

**Upstream license**: MIT (code) + research-only restriction on the
runtime InsightFace face-detection weights. Verbatim text:

- `LICENSES/LivePortrait-MIT.txt` — MIT license body
- `LICENSES/InsightFace-research-only.txt` — research-only clause + the
  ADR-0015 framing that satisfies this restriction for MirrorMesh's use
  case.

## What is NOT here

- **Weights** (`*.pth`, `*.safetensors`) — the user must download them
  from the upstream release / Hugging Face mirror; see
  `models/training/README.md` for the exact link and rationale.
- **Runtime pipeline** — face detection (InsightFace), face cropping,
  driving-template extraction, stitching/retargeting drivers,
  `inference.py`, `app.py`. MirrorMesh wires a minimal inference loop
  inside `Sources/MirrorMeshReenact/PhotorealBackend.swift`; it does
  NOT pull the upstream runtime. This is the primary reason vendoring is
  small here: we vendor the *model classes* (so weight-loading and
  conversion can run), not the *runtime* (which would pull InsightFace
  into our binary surface).
- **Training code** — MirrorMesh does not retrain LivePortrait; we
  only consume published checkpoints.
- **`live_portrait_wrapper.py` / pipeline.py** — orchestration glue
  that ties the four submodels together. The conversion script in
  `models/training/liveportrait_to_coreml.py` reimplements the minimal
  trace path; the Swift runtime reimplements the inference path. No
  need to vendor the upstream Python glue.
- **Configs** (`src/config/*.yaml`) — the conversion script hard-codes
  the `human` checkpoint variant hyperparameters because that is the
  variant we target (face reenactment). Other variants (`animal`) need
  the corresponding params; edit
  `models/training/liveportrait_to_coreml.py`.

## Modifications from upstream

None of the vendored files required architectural changes for CoreML
conversion. Specifically:

- `util.py` uses stock `nn.BatchNorm2d` / `nn.BatchNorm3d` /
  `nn.InstanceNorm2d` throughout — no SyncBatchNorm to swap (unlike
  FOMM's `util.py`, which we patched). LivePortrait's authors already
  ship inference-friendly norms.
- The only header change across all files is the attribution block
  prepended to each `.py` (origin URL, commit SHA, MIT license note,
  InsightFace research-only caveat where applicable).

## Per project rule R5 (model provenance)

The `.mlpackage` files produced by
`models/training/liveportrait_to_coreml.py` each ship with a
`.provenance.json` sidecar recording: this directory's upstream commit
SHA, the user-supplied weight file's SHA-256, the conversion script's
SHA-256, and the resulting mlpackage SHA-256. CI's
`models/verify_provenance.py` validates the sidecars at build time.

## Per project rule R1 (no identity spoofing) and ADR-0015

The LivePortrait path produces photorealistic reenactment. It is gated
behind `ConsentedIdentityVerifier` exactly like the FOMM path — see
`Sources/MirrorMeshReenact/PhotorealBackend.swift` and the load-time
contract. ADR-0015 (AGPL-3.0-only research posture) makes the
InsightFace research-only restriction compatible with MirrorMesh's
use, because MirrorMesh itself is now a non-commercial research
project; commercial redistribution by downstream users is forbidden
by the AGPL surface, so the research-only weights stay within their
license terms.
