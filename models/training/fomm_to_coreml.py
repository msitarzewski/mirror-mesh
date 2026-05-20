#!/usr/bin/env python3.11
"""Convert a user-supplied FOMM checkpoint into three CoreML .mlpackage files.

This script is **never invoked at swift build / swift test time**. It is the
manual on-ramp a contributor runs once after downloading the upstream FOMM
checkpoint per `models/training/README.md`. The resulting .mlpackage files
are then consumed by Sources/MirrorMeshReenact/PhotorealBackend.swift at
runtime; without them the Swift backend refuses to load (by design — see R1).

Why three outputs instead of one fused model:

  1. `keypoint_v1.mlpackage`  — runs once on the source identity frame
     (cached after first call) AND once per driving frame. Splitting it out
     lets the runtime reuse the source-frame keypoints across all driving
     frames and only invoke this network per-driving-frame.

  2. `motion_v1.mlpackage`    — given (source_image, kp_source, kp_driving)
     produces a dense optical-flow field plus an occlusion mask. Pure
     spatial-warp prediction; no decode.

  3. `generator_v1.mlpackage` — given (source_image, dense_motion,
     occlusion_mask) produces the final reenacted frame. This is the
     expensive one (decoder hourglass).

Splitting the graph this way lets the Swift side reuse cached source-frame
state and is also what the FOMM authors do at inference (`animate.py`).

Why python3.11 and not python3.14: per project history, coremltools 9.0 on
Python 3.14 ships without the libmilstoragepython BlobWriter extension,
which crashes during .mlpackage serialisation. coremltools 8.3+ on
Python 3.11 has the prebuilt extension and converts cleanly. The shebang
pins us to the working combination.

Usage
-----
    pip install -r models/training/requirements.txt
    python3.11 models/training/fomm_to_coreml.py \\
        --weights /path/to/vox-cpk.pth.tar \\
        --out    models/

Outputs (written to <--out>/):
    keypoint_v1.mlpackage         + keypoint_v1.provenance.json
    motion_v1.mlpackage           + motion_v1.provenance.json
    generator_v1.mlpackage        + generator_v1.provenance.json

Per project rule R5 (model provenance) each .mlpackage ships with a
sidecar .provenance.json recording: upstream commit of the vendored
source files, sha256 of this script, sha256 of the input weight file,
sha256 of the produced .mlpackage, and the conversion knobs (precision,
target macOS version) — verifiable via models/verify_provenance.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

# ── Hard-fail with a clear message if the ML stack is missing ──────────────
try:
    import numpy as np
    import torch
    import coremltools as ct
except ImportError as e:
    print(f"missing dependency: {e}", file=sys.stderr)
    print("install: python3.11 -m pip install -r models/training/requirements.txt",
          file=sys.stderr)
    sys.exit(1)

# ── Vendored FOMM model definitions: aliased so `from modules.X` works ─────
# The vendored files at models/external/fomm/*.py keep their original imports
# (`from modules.util import ...`). Rather than rewrite every import we just
# install the vendored directory under the package name `modules` on sys.path.
REPO_ROOT     = Path(__file__).resolve().parents[2]
VENDORED_ROOT = REPO_ROOT / "models" / "external"
if not (VENDORED_ROOT / "fomm" / "util.py").exists():
    print(f"vendored FOMM sources missing under {VENDORED_ROOT / 'fomm'}", file=sys.stderr)
    print("re-run after vendoring (see models/external/fomm/README.md)", file=sys.stderr)
    sys.exit(2)

# Alias models/external/fomm  ->  module name `modules`
import importlib
import importlib.util

def _alias_package(pkg_dir: Path, as_name: str):
    """Load pkg_dir's __init__.py as the importable package `as_name`."""
    init_py = pkg_dir / "__init__.py"
    spec = importlib.util.spec_from_file_location(
        as_name, init_py, submodule_search_locations=[str(pkg_dir)]
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot create spec for {pkg_dir}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[as_name] = mod
    spec.loader.exec_module(mod)
    return mod

_alias_package(VENDORED_ROOT / "fomm", "modules")

from modules.keypoint_detector import KPDetector             # noqa: E402
from modules.dense_motion import DenseMotionNetwork           # noqa: E402
from modules.generator import OcclusionAwareGenerator         # noqa: E402

# ── FOMM vox-256 hyperparameters ────────────────────────────────────────────
# Hard-coded from config/vox-256.yaml in the upstream repo. We do NOT load the
# YAML at runtime because (a) it's one more vendored file to maintain and
# (b) the conversion is per-checkpoint-variant and we explicitly target
# vox-cpk only. Other variants (taichi-256, nemo-256) need the corresponding
# params; edit this dict and re-run.
VOX_256 = {
    "num_kp": 10,
    "num_channels": 3,
    "image_size": 256,
    "estimate_jacobian": True,
    "estimate_occlusion_map": True,
    "kp_detector": {
        "block_expansion": 32,
        "max_features": 1024,
        "num_blocks": 5,
        "temperature": 0.1,
        "scale_factor": 0.25,
        "single_jacobian_map": False,
        "pad": 3,
    },
    "generator": {
        "block_expansion": 64,
        "max_features": 512,
        "num_down_blocks": 2,
        "num_bottleneck_blocks": 6,
    },
    "dense_motion": {
        "block_expansion": 64,
        "num_blocks": 5,
        "max_features": 1024,
        "scale_factor": 0.25,
    },
}

UPSTREAM_FOMM_COMMIT = "c0274845cb2dd8f0f2fe6da580d97b60fef90c91"
TARGET_MACOS         = ct.target.macOS14
CONVERT_TO           = "mlprogram"
COMPUTE_PRECISION    = ct.precision.FLOAT16   # fp16 weights — halves disk + ~2x inference on ANE


# ─────────────────────────────────────────────────────────────────────────────
# Wrappers
#
# CoreML's torch frontend can't trace a forward() that returns a dict, and
# FOMM's networks all do. Each wrapper unrolls the dict into a fixed-shape
# tuple of tensors with deterministic ordering, and accepts the inputs as
# positional tensors so torch.jit.trace produces a clean graph.
# ─────────────────────────────────────────────────────────────────────────────

class KPDetectorWrapper(torch.nn.Module):
    """KPDetector -> (kp_value [B,10,2], kp_jacobian [B,10,2,2])."""

    def __init__(self, kp_detector: KPDetector):
        super().__init__()
        self.kp_detector = kp_detector

    def forward(self, image):
        out = self.kp_detector(image)
        # FOMM always estimates jacobian for the vox-cpk checkpoint.
        return out["value"], out["jacobian"]


class DenseMotionWrapper(torch.nn.Module):
    """DenseMotionNetwork unrolled to positional tensors -> (deformation [B,H,W,2], occlusion [B,1,H,W])."""

    def __init__(self, dense_motion: DenseMotionNetwork):
        super().__init__()
        self.dense_motion = dense_motion

    def forward(self, source_image, kp_source_value, kp_source_jacobian,
                kp_driving_value, kp_driving_jacobian):
        kp_source  = {"value": kp_source_value,  "jacobian": kp_source_jacobian}
        kp_driving = {"value": kp_driving_value, "jacobian": kp_driving_jacobian}
        out = self.dense_motion(source_image, kp_driving, kp_source)
        # estimate_occlusion_map=True → both fields present
        return out["deformation"], out["occlusion_map"]


class GeneratorWrapper(torch.nn.Module):
    """OcclusionAwareGenerator without its embedded DenseMotionNetwork —
    the Swift runtime feeds in deformation + occlusion as already-computed
    inputs so the generator becomes a pure (source, motion) -> frame net."""

    def __init__(self, generator: OcclusionAwareGenerator):
        super().__init__()
        # Strip the embedded motion net so trace doesn't pull it in (it's
        # converted as its own .mlpackage).
        generator.dense_motion_network = None
        self.generator = generator

    def forward(self, source_image, deformation, occlusion_map):
        # Mimic the relevant slice of OcclusionAwareGenerator.forward,
        # but skip the internal dense_motion call (the caller supplied it).
        import torch.nn.functional as F
        out = self.generator.first(source_image)
        for db in self.generator.down_blocks:
            out = db(out)
        # Apply deformation
        if deformation.shape[1] != out.shape[2] or deformation.shape[2] != out.shape[3]:
            d = deformation.permute(0, 3, 1, 2)
            d = F.interpolate(d, size=(out.shape[2], out.shape[3]), mode="bilinear")
            d = d.permute(0, 2, 3, 1)
        else:
            d = deformation
        out = F.grid_sample(out, d)
        # Apply occlusion
        if out.shape[2] != occlusion_map.shape[2] or out.shape[3] != occlusion_map.shape[3]:
            occ = F.interpolate(occlusion_map, size=out.shape[2:], mode="bilinear")
        else:
            occ = occlusion_map
        out = out * occ
        out = self.generator.bottleneck(out)
        for ub in self.generator.up_blocks:
            out = ub(out)
        out = self.generator.final(out)
        out = torch.sigmoid(out)
        return out


# ─────────────────────────────────────────────────────────────────────────────
# Build, load weights, trace, convert
# ─────────────────────────────────────────────────────────────────────────────

def build_kp_detector() -> KPDetector:
    p = VOX_256["kp_detector"]
    return KPDetector(
        block_expansion=p["block_expansion"],
        num_kp=VOX_256["num_kp"],
        num_channels=VOX_256["num_channels"],
        max_features=p["max_features"],
        num_blocks=p["num_blocks"],
        temperature=p["temperature"],
        estimate_jacobian=VOX_256["estimate_jacobian"],
        scale_factor=p["scale_factor"],
        single_jacobian_map=p["single_jacobian_map"],
        pad=p["pad"],
    )


def build_dense_motion() -> DenseMotionNetwork:
    p = VOX_256["dense_motion"]
    return DenseMotionNetwork(
        block_expansion=p["block_expansion"],
        num_blocks=p["num_blocks"],
        max_features=p["max_features"],
        num_kp=VOX_256["num_kp"],
        num_channels=VOX_256["num_channels"],
        estimate_occlusion_map=VOX_256["estimate_occlusion_map"],
        scale_factor=p["scale_factor"],
    )


def build_generator() -> OcclusionAwareGenerator:
    p = VOX_256["generator"]
    return OcclusionAwareGenerator(
        num_channels=VOX_256["num_channels"],
        num_kp=VOX_256["num_kp"],
        block_expansion=p["block_expansion"],
        max_features=p["max_features"],
        num_down_blocks=p["num_down_blocks"],
        num_bottleneck_blocks=p["num_bottleneck_blocks"],
        estimate_occlusion_map=VOX_256["estimate_occlusion_map"],
        # The Generator's embedded DenseMotionNetwork is stripped by
        # GeneratorWrapper; pass empty dict to satisfy the constructor's
        # `dense_motion_params is not None` branch since we still need the
        # field to exist briefly during weight-loading.
        dense_motion_params={
            "block_expansion": VOX_256["dense_motion"]["block_expansion"],
            "num_blocks":      VOX_256["dense_motion"]["num_blocks"],
            "max_features":    VOX_256["dense_motion"]["max_features"],
            "scale_factor":    VOX_256["dense_motion"]["scale_factor"],
        },
        estimate_jacobian=VOX_256["estimate_jacobian"],
    )


def load_weights(checkpoint_path: Path, kp: KPDetector, gen: OcclusionAwareGenerator):
    """FOMM checkpoint layout: dict with keys 'kp_detector', 'generator',
    'discriminator', 'optimizer_kp_detector', ... — we use the first two."""
    ckpt = torch.load(str(checkpoint_path), map_location="cpu", weights_only=False)
    if "kp_detector" not in ckpt or "generator" not in ckpt:
        raise RuntimeError(
            f"checkpoint {checkpoint_path} missing expected keys 'kp_detector'/'generator'. "
            f"got: {list(ckpt.keys())}"
        )
    kp.load_state_dict(ckpt["kp_detector"])
    gen.load_state_dict(ckpt["generator"])
    # Extract dense_motion sub-state from the generator state-dict for the
    # standalone dense-motion model.
    dm_state = {
        k.removeprefix("dense_motion_network."): v
        for k, v in ckpt["generator"].items()
        if k.startswith("dense_motion_network.")
    }
    return dm_state


def convert_kp(kp: KPDetector, out_path: Path):
    wrapper = KPDetectorWrapper(kp).eval()
    example = torch.zeros(1, 3, VOX_256["image_size"], VOX_256["image_size"])
    traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image",
                              shape=(1, 3, VOX_256["image_size"], VOX_256["image_size"]),
                              dtype=np.float32)],
        outputs=[
            ct.TensorType(name="kp_value",    dtype=np.float32),
            ct.TensorType(name="kp_jacobian", dtype=np.float32),
        ],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh FOMM keypoint detector (vox-cpk, fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from FOMM, MIT)"
    mlmodel.license = "MIT"
    mlmodel.save(str(out_path))


def convert_motion(dm: DenseMotionNetwork, out_path: Path):
    wrapper = DenseMotionWrapper(dm).eval()
    src = torch.zeros(1, 3, VOX_256["image_size"], VOX_256["image_size"])
    kpv = torch.zeros(1, VOX_256["num_kp"], 2)
    kpj = torch.eye(2).expand(1, VOX_256["num_kp"], 2, 2).contiguous()
    traced = torch.jit.trace(wrapper, (src, kpv, kpj, kpv, kpj))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="source_image",        shape=src.shape, dtype=np.float32),
            ct.TensorType(name="kp_source_value",     shape=kpv.shape, dtype=np.float32),
            ct.TensorType(name="kp_source_jacobian",  shape=kpj.shape, dtype=np.float32),
            ct.TensorType(name="kp_driving_value",    shape=kpv.shape, dtype=np.float32),
            ct.TensorType(name="kp_driving_jacobian", shape=kpj.shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="deformation",   dtype=np.float32),
            ct.TensorType(name="occlusion_map", dtype=np.float32),
        ],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh FOMM dense-motion estimator (vox-cpk, fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from FOMM, MIT)"
    mlmodel.license = "MIT"
    mlmodel.save(str(out_path))


def convert_generator(gen: OcclusionAwareGenerator, out_path: Path, motion_hw: int):
    wrapper = GeneratorWrapper(gen).eval()
    src  = torch.zeros(1, 3, VOX_256["image_size"], VOX_256["image_size"])
    defm = torch.zeros(1, motion_hw, motion_hw, 2)
    occ  = torch.zeros(1, 1, motion_hw, motion_hw)
    traced = torch.jit.trace(wrapper, (src, defm, occ))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="source_image",   shape=src.shape,  dtype=np.float32),
            ct.TensorType(name="deformation",    shape=defm.shape, dtype=np.float32),
            ct.TensorType(name="occlusion_map",  shape=occ.shape,  dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="prediction", dtype=np.float32)],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh FOMM occlusion-aware generator (vox-cpk, fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from FOMM, MIT)"
    mlmodel.license = "MIT"
    mlmodel.save(str(out_path))


# ─────────────────────────────────────────────────────────────────────────────
# Hashing + provenance sidecar (matches models/verify_provenance.py)
# ─────────────────────────────────────────────────────────────────────────────

def sha256_of_path(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_dir():
        for f in sorted(path.rglob("*")):
            if f.is_file():
                h.update(str(f.relative_to(path)).encode("utf-8"))
                h.update(b"\x00")
                with f.open("rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
    else:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def write_provenance(name: str, mlpkg_path: Path, weights_path: Path,
                     script_path: Path, sidecar_path: Path,
                     extra: dict):
    pkg_sha     = sha256_of_path(mlpkg_path)
    weights_sha = sha256_of_path(weights_path)
    script_sha  = sha256_of_path(script_path)
    meta = {
        "name": name,
        "source": "models/training/fomm_to_coreml.py",
        "license": "MIT (FOMM upstream and converted weights)",
        "training_data_summary": (
            "FOMM vox-cpk checkpoint (VoxCeleb1 talking-head dataset). Training data is the "
            "upstream authors' work and is NOT redistributed by MirrorMesh. End user supplies "
            "the .pth.tar checkpoint themselves; see models/training/README.md."
        ),
        "conversion_pipeline": (
            "torch.load(weights) -> KPDetector/DenseMotion/Generator -> torch.jit.trace -> "
            "coremltools.convert(convert_to='mlprogram', precision=FLOAT16, target=macOS14) -> .mlpackage"
        ),
        "upstream_repo": "https://github.com/AliaksandrSiarohin/first-order-model",
        "upstream_commit": UPSTREAM_FOMM_COMMIT,
        "input_weights_path": str(weights_path.name),
        "input_weights_sha256": weights_sha,
        "conversion_script_sha256": script_sha,
        "config_variant": "vox-256 (vox-cpk)",
        "image_size": VOX_256["image_size"],
        "num_kp": VOX_256["num_kp"],
        "precision": "fp16",
        "compute_target": "macOS14 (CoreML mlprogram)",
        "converted_at": time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime()),
        "size_bytes": sum(f.stat().st_size for f in mlpkg_path.rglob("*") if f.is_file()),
        "sha256": pkg_sha,
        "sha256_algorithm": (
            "Concatenated sha256 over each file in the .mlpackage directory, sorted by relative "
            "path. Each file's relative-path bytes are written, then a NUL byte, then the file "
            "contents. Verifiable via models/verify_provenance.py."
        ),
    }
    meta.update(extra)
    sidecar_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# Latency estimate (best-effort — no actual ANE timing on the conversion host)
# ─────────────────────────────────────────────────────────────────────────────

def latency_estimate(kp_pkg: Path, motion_pkg: Path, gen_pkg: Path):
    """Run a single CoreML inference per model on the conversion host and print
    wall-clock times. CPU on the conversion box is *not* representative of ANE
    on an M-series device; numbers print as a sanity check only."""
    try:
        kp_model     = ct.models.MLModel(str(kp_pkg))
        motion_model = ct.models.MLModel(str(motion_pkg))
        gen_model    = ct.models.MLModel(str(gen_pkg))
    except Exception as e:
        print(f"[latency] skipping — could not load mlpackage: {e}")
        return

    sz = VOX_256["image_size"]
    nk = VOX_256["num_kp"]
    rng = np.random.default_rng(seed=0)
    src = rng.random((1, 3, sz, sz)).astype(np.float32)
    kpv = rng.random((1, nk, 2)).astype(np.float32)
    kpj = np.eye(2, dtype=np.float32)[None, None].repeat(nk, axis=1).repeat(1, axis=0)

    def time_one(label, fn):
        # warmup
        fn()
        n = 5
        t0 = time.perf_counter()
        for _ in range(n):
            fn()
        dt = (time.perf_counter() - t0) / n * 1000.0
        print(f"[latency] {label:>14s}: {dt:7.2f} ms/iter (n={n}, host CPU — ANE will be faster)")

    time_one("kp_detector",  lambda: kp_model.predict({"image": src}))
    time_one("dense_motion", lambda: motion_model.predict({
        "source_image": src,
        "kp_source_value": kpv, "kp_source_jacobian": kpj,
        "kp_driving_value": kpv, "kp_driving_jacobian": kpj,
    }))
    # Motion-output spatial size at scale_factor=0.25 of 256 = 64.
    motion_hw = sz // 4
    defm = rng.random((1, motion_hw, motion_hw, 2)).astype(np.float32)
    occ  = rng.random((1, 1, motion_hw, motion_hw)).astype(np.float32)
    time_one("generator", lambda: gen_model.predict({
        "source_image": src, "deformation": defm, "occlusion_map": occ,
    }))


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--weights", required=True, type=Path,
                    help="Path to a FOMM .pth.tar checkpoint (vox-cpk recommended).")
    ap.add_argument("--out", required=True, type=Path,
                    help="Output directory. .mlpackage and .provenance.json files written here.")
    ap.add_argument("--skip-latency", action="store_true",
                    help="Skip the post-conversion latency-estimate pass.")
    args = ap.parse_args(argv)

    if not args.weights.exists():
        print(f"weights file not found: {args.weights}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    script_path = Path(__file__).resolve()

    print(f"[1/4] building FOMM networks (vox-256 hyperparameters)")
    kp_net  = build_kp_detector()
    gen_net = build_generator()
    print(f"[2/4] loading weights from {args.weights}")
    dm_state = load_weights(args.weights, kp_net, gen_net)
    # Materialise a standalone DenseMotionNetwork and load the sliced state
    # we pulled out of the generator checkpoint above.
    dm_net = build_dense_motion()
    dm_net.load_state_dict(dm_state)

    kp_pkg  = args.out / "keypoint_v1.mlpackage"
    mo_pkg  = args.out / "motion_v1.mlpackage"
    gen_pkg = args.out / "generator_v1.mlpackage"
    motion_hw = VOX_256["image_size"] // int(1 / VOX_256["dense_motion"]["scale_factor"])

    print(f"[3/4] converting -> CoreML mlprogram (fp16, macOS14)")
    convert_kp(kp_net.eval(),       kp_pkg)
    convert_motion(dm_net.eval(),   mo_pkg)
    convert_generator(gen_net.eval(), gen_pkg, motion_hw)

    print(f"[4/4] writing provenance sidecars")
    write_provenance("keypoint_v1",  kp_pkg, args.weights, script_path,
                     args.out / "keypoint_v1.provenance.json",
                     {"role": "keypoint detector — runs per source+driving frame"})
    write_provenance("motion_v1",    mo_pkg, args.weights, script_path,
                     args.out / "motion_v1.provenance.json",
                     {"role": "dense-motion estimator — runs per driving frame",
                      "motion_spatial_size": motion_hw})
    write_provenance("generator_v1", gen_pkg, args.weights, script_path,
                     args.out / "generator_v1.provenance.json",
                     {"role": "occlusion-aware generator — runs per driving frame"})

    if not args.skip_latency:
        print()
        latency_estimate(kp_pkg, mo_pkg, gen_pkg)
        print()
        print("Note: host-CPU timings are NOT representative of ANE/M-series performance.")
        print("Target on M5 Max with ANE: kp ~3ms, motion ~10ms, generator ~25ms — total <50ms.")

    print()
    print(f"OK. wrote:")
    print(f"  {kp_pkg}")
    print(f"  {mo_pkg}")
    print(f"  {gen_pkg}")
    print(f"+ matching .provenance.json sidecars in {args.out}")
    return 0


if __name__ == "__main__":
    # Suppress duplicate-OpenMP linker warning between numpy and libtorch
    # (same workaround as models/training/blendshape_solver.py).
    os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
    os.environ.setdefault("OMP_NUM_THREADS",      "1")
    sys.exit(main(sys.argv[1:]))
