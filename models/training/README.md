# models/training/

Conversion scripts that turn user-supplied PyTorch weights into the
`.mlpackage` artifacts the Swift runtime consumes. **None of these scripts
runs during `swift build` / `swift test`.** They produce on-disk artifacts;
the Swift side only ever reads the artifacts.

| Script                         | Output(s)                                                                                  | When you run it                                                          |
|--------------------------------|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| `blendshape_solver.py`         | `models/blendshape_solver_v1.mlpackage` + provenance                                       | Once. Already produced and shipped (v0.5.0).                             |
| `fomm_to_coreml.py`            | `keypoint_v1.mlpackage`, `motion_v1.mlpackage`, `generator_v1.mlpackage` + provenance      | Once, after you download FOMM weights yourself (v0.6.0 photorealistic path). |

---

## FOMM (`fomm_to_coreml.py`) — the photorealistic identity-transfer path

### Why we don't ship the weights

Three reasons, in priority order:

1. **License clarity over convenience.** The vendored architecture source
   (`models/external/fomm/`) is MIT; the *weights* are derived from VoxCeleb,
   which has its own (research-use) terms. Asking each contributor to
   download from the upstream Google Drive once keeps MirrorMesh's
   redistribution footprint clean and traceable.

2. **Size.** The vox-cpk checkpoint is ~700 MB. Shipping it in the repo /
   release artifact balloons every install and every CI cache.

3. **Provenance traceability (R5).** Every `.mlpackage` we ship carries a
   `.provenance.json` sidecar with a sha256 of the upstream weight file it
   was derived from. When the user runs the conversion, the sidecar
   captures *their* download's sha256, so any downstream output frame
   that references the model is auditable end-to-end.

### One-time setup

```bash
# 1. Use python3.11 — python3.14 crashes coremltools' BlobWriter.
#    Install via homebrew if you don't have it:
#    brew install python@3.11
#
# 2. Conversion-time Python deps (kept separate from the solver script's pins):
/opt/homebrew/bin/python3.11 -m pip install -r models/training/requirements-fomm.txt
```

### Step 1 — Download the upstream checkpoint

The FOMM authors host pretrained checkpoints on Google Drive. From the
upstream README:

> Checkpoints can be found under following link:
> https://drive.google.com/open?id=1PyQJmkdCsAkOYwUyaj_l-l0as-iLDgeH

Download **`vox-cpk.pth.tar`** (the VoxCeleb-trained variant — face
reenactment). Other variants (taichi, nemo, mgif, bair, fashion) exist
for non-face animation; if you want one of those, also edit `VOX_256` in
`fomm_to_coreml.py` to match the config of that variant (see the
upstream `config/*.yaml`).

Place the file anywhere you like — pass the path to `--weights`.

### Step 2 — Run the conversion

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

/opt/homebrew/bin/python3.11 models/training/fomm_to_coreml.py \
    --weights ~/Downloads/vox-cpk.pth.tar \
    --out     models/
```

Wall-clock: ~2 minutes on Apple Silicon CPU.

You should now have, in `models/`:

```
keypoint_v1.mlpackage         keypoint_v1.provenance.json
motion_v1.mlpackage           motion_v1.provenance.json
generator_v1.mlpackage        generator_v1.provenance.json
```

### Step 3 — Wire into the Swift package

The three `.mlpackage` files are loaded at runtime by
`Sources/MirrorMeshReenact/PhotorealBackend.swift`. There are two
deployment options:

- **Per-user opt-in (recommended for v0.6.0)**. Leave the mlpackages
  under `models/` and pass that directory as `modelsDir` when
  constructing `PhotorealBackend`. The Swift side resolves them at
  runtime. Nothing in `Package.swift` changes.

- **Shipped in the bundle (future)**. To ship them inside
  `MirrorMeshReenact.bundle`, add to `Package.swift` under the
  `MirrorMeshReenact` target:

  ```swift
  resources: [
      .copy("Resources/keypoint_v1.mlpackage"),
      .copy("Resources/motion_v1.mlpackage"),
      .copy("Resources/generator_v1.mlpackage"),
  ]
  ```

  and copy the three packages into
  `Sources/MirrorMeshReenact/Resources/`. **Do not** check the binary
  packages into git — they are user-supplied derivatives of FOMM
  weights.

### Step 4 — Verify provenance (optional but recommended)

```bash
/opt/homebrew/bin/python3.11 models/verify_provenance.py
```

Verifies that the on-disk `.mlpackage` files match the sha256 recorded
in their `.provenance.json` sidecars. Fails build if they drift.

---

## Per-output role split

The FOMM forward pass is decomposed into three CoreML packages instead
of one fused model. Reasons:

| Package                | When the runtime invokes it                          | Why split |
|------------------------|------------------------------------------------------|-----------|
| `keypoint_v1`          | Once on source identity (cached), once per driving frame | The source-frame keypoint result is identity-invariant within a session and gets cached. |
| `motion_v1`            | Once per driving frame                               | Pure spatial-warp prediction; ~10 ms on ANE.    |
| `generator_v1`         | Once per driving frame                               | The expensive decoder; ~25 ms on ANE.           |

This mirrors what the upstream FOMM `animate.py` does at inference and
lets us reuse cached source-frame state.

---

## License posture

| Component                                  | License | Where it comes from                       |
|--------------------------------------------|---------|-------------------------------------------|
| Vendored architecture (`models/external/fomm/`) | MIT     | Snapshot of upstream FOMM `modules/`      |
| Conversion script (`fomm_to_coreml.py`)    | AGPL-3.0 + Commercial | New MirrorMesh code                       |
| Weights (vox-cpk.pth.tar)                  | (upstream) | User-supplied; **never** ours to redistribute |
| Converted `.mlpackage` files               | MIT (per upstream weights) | Generated locally by the script           |

MIT license text for the vendored architecture lives at
`LICENSES/FOMM-MIT.txt` (root of repo).
