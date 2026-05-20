#!/usr/bin/env python3.11
"""Convert user-supplied LivePortrait checkpoints into four CoreML .mlpackage files.

This script is **never invoked at swift build / swift test time**. It is the
manual on-ramp a contributor runs once after downloading the upstream
LivePortrait checkpoints per `models/training/README.md`. The resulting
.mlpackage files are then consumed by
`Sources/MirrorMeshReenact/PhotorealBackend.swift` at runtime; without them
the Swift backend refuses to load (by design — see R1).

LivePortrait is the **recommended** photorealistic backend as of v0.6.0
(per ADR-0015 — research-only InsightFace deps are now compatible with
MirrorMesh's AGPL-3.0-only research posture). FOMM (see
`models/training/fomm_to_coreml.py`) remains a license-clean fallback that
does not depend on InsightFace.

Why four outputs instead of one fused model:

  1. `appearance_v1.mlpackage` — `AppearanceFeatureExtractor (F)`. Runs
     once on the source identity frame and the result is cached for the
     whole session. This is the only network that operates on the source
     identity image; separating it lets the Swift runtime call it exactly
     once per identity-load and reuse the 3D appearance feature volume
     across every driving frame.

  2. `motion_v1.mlpackage` — `MotionExtractor (M)` (ConvNeXtV2-tiny
     backbone). Runs once per driving frame to predict canonical
     keypoints, head pose (pitch/yaw/roll), translation, expression
     deformation, and scale.

  3. `warp_v1.mlpackage` — `WarpingNetwork (W)` with embedded
     `DenseMotionNetwork`. Given (appearance_feature_3d, kp_source,
     kp_driving) produces a warped feature volume that the SPADE decoder
     consumes. This is the spatially-expensive one — sparse-to-dense
     motion + 3D feature warp.

  4. `generator_v1.mlpackage` — `SPADEDecoder (G)`. Given the warped
     feature volume, produces the final RGB reenacted frame. Hourglass
     decoder with SPADE conditioning.

Splitting the graph this way mirrors LivePortrait's own inference pipeline
(`src/live_portrait_wrapper.py`) and lets the Swift side reuse cached
source-identity state across the driving frame stream.

Why python3.11 and not python3.14: same reason as `fomm_to_coreml.py`.
coremltools 9.0 on Python 3.14 ships without the libmilstoragepython
BlobWriter extension, which crashes during .mlpackage serialisation.
coremltools 9.0 on Python 3.11 has the prebuilt extension and converts
cleanly. The shebang pins us to the working combination.

Usage
-----
    pip install -r models/training/requirements-liveportrait.txt
    python3.11 models/training/liveportrait_to_coreml.py \\
        --weights /path/to/liveportrait_pretrained \\
        --out     models/

The `--weights` argument is a directory containing the upstream
LivePortrait `human` checkpoint files. The exact layout the upstream
release uses is:

    liveportrait/
      base_models/
        appearance_feature_extractor.pth
        motion_extractor.pth
        spade_generator.pth
        warping_module.pth
      retargeting_models/
        stitching_retargeting_module.pth

Pass the path to the `liveportrait/` directory (the parent of
`base_models/`). The script discovers the four base-model checkpoint files
inside automatically.

Outputs (written to <--out>/):
    appearance_v1.mlpackage  + appearance_v1.provenance.json
    motion_v1.mlpackage      + motion_v1.provenance.json
    warp_v1.mlpackage        + warp_v1.provenance.json
    generator_v1.mlpackage   + generator_v1.provenance.json

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
    print("install: python3.11 -m pip install -r models/training/requirements-liveportrait.txt",
          file=sys.stderr)
    sys.exit(1)

# ── Vendored LivePortrait model definitions ───────────────────────────────
# Unlike FOMM (which uses top-level `from modules.X import Y`), LivePortrait
# uses package-relative imports (`from .util import ...`). That means we
# only need the vendored directory to be importable as a package — no alias
# trick required. We add `models/external/` to sys.path and import as
# `liveportrait.<submodule>`.
REPO_ROOT     = Path(__file__).resolve().parents[2]
VENDORED_ROOT = REPO_ROOT / "models" / "external"
if not (VENDORED_ROOT / "liveportrait" / "util.py").exists():
    print(f"vendored LivePortrait sources missing under {VENDORED_ROOT / 'liveportrait'}",
          file=sys.stderr)
    print("re-run after vendoring (see models/external/liveportrait/README.md)",
          file=sys.stderr)
    sys.exit(2)

sys.path.insert(0, str(VENDORED_ROOT))

from liveportrait.appearance_feature_extractor import AppearanceFeatureExtractor  # noqa: E402
from liveportrait.motion_extractor              import MotionExtractor             # noqa: E402
from liveportrait.warping_network               import WarpingNetwork              # noqa: E402
from liveportrait.spade_generator               import SPADEDecoder                # noqa: E402

# ── LivePortrait `human` checkpoint hyperparameters ───────────────────────
# Mirrors src/config/models.yaml in upstream LivePortrait (the `human`
# variant — face reenactment). We hard-code rather than parse the YAML at
# runtime because (a) it's one fewer vendored file to maintain and (b) the
# conversion is per-variant; `animal` checkpoints would need their own
# dict. Edit this and rerun if you want the animal variant.
HUMAN_256 = {
    "image_size": 256,
    "num_kp": 21,                 # LivePortrait implicit-keypoint count
    "num_channels": 3,
    "appearance": {
        "image_channel":     3,
        "block_expansion":   64,
        "num_down_blocks":   2,
        "max_features":      512,
        "reshape_channel":   32,
        "reshape_depth":     16,
        "num_resblocks":     6,
    },
    "motion": {
        # ConvNeXtV2-tiny backbone with LivePortrait's head config.
        "backbone":          "convnextv2_tiny",
        "num_kp":            21,
        "num_bins":          66,
    },
    "warp": {
        "num_kp":                 21,
        "block_expansion":        64,
        "max_features":           512,
        "num_down_blocks":        2,
        "reshape_channel":        32,
        "estimate_occlusion_map": True,
        "dense_motion_params": {
            "block_expansion": 32,
            "max_features":    1024,
            "num_blocks":      5,
            "reshape_depth":   16,
            "compress":        4,
        },
    },
    "generator": {
        "upscale":          1,
        "block_expansion":  64,
        "max_features":     512,
        "out_channels":     64,
        "num_down_blocks":  2,
    },
}

# Spatial size of the 3D appearance-feature volume that gets passed between
# the appearance extractor, the warping network, and the SPADE decoder.
# Derived from the hyperparameters above: 256 -> down-by-2 twice -> 64x64,
# with reshape_depth=16 along the D axis and reshape_channel=32 along C.
FEATURE_D = HUMAN_256["appearance"]["reshape_depth"]    # 16
FEATURE_H = HUMAN_256["image_size"] // (2 ** HUMAN_256["appearance"]["num_down_blocks"])  # 64
FEATURE_W = FEATURE_H                                                                       # 64
FEATURE_C = HUMAN_256["appearance"]["reshape_channel"]  # 32

UPSTREAM_LP_COMMIT  = "49784e879821538ecda5c8e4ca0472f4cb6236cf"
TARGET_MACOS        = ct.target.macOS14
CONVERT_TO          = "mlprogram"
COMPUTE_PRECISION   = ct.precision.FLOAT16   # fp16 weights — halves disk + ~2x ANE inference


# ─────────────────────────────────────────────────────────────────────────────
# Wrappers
#
# CoreML's torch frontend can't trace a forward() that returns a dict, and
# both MotionExtractor.forward and WarpingNetwork.forward do. Each wrapper
# unrolls the dict into a fixed-shape tuple of tensors with deterministic
# ordering, and accepts the inputs as positional tensors so torch.jit.trace
# produces a clean graph.
# ─────────────────────────────────────────────────────────────────────────────

class AppearanceWrapper(torch.nn.Module):
    """AppearanceFeatureExtractor already returns a single tensor — wrapper
    is here for symmetry with the other three (and to give the traced
    module a stable input-name)."""

    def __init__(self, net: AppearanceFeatureExtractor):
        super().__init__()
        self.net = net

    def forward(self, source_image):
        return self.net(source_image)


class MotionWrapper(torch.nn.Module):
    """MotionExtractor returns {pitch, yaw, roll, t, exp, scale, kp}.
    Unroll into a positional tuple in a stable order so the CoreML graph
    has named outputs the Swift side can read by index."""

    def __init__(self, net: MotionExtractor):
        super().__init__()
        self.net = net

    def forward(self, driving_image):
        out = self.net(driving_image)
        return (
            out["pitch"],
            out["yaw"],
            out["roll"],
            out["t"],
            out["exp"],
            out["scale"],
            out["kp"],
        )


class WarpWrapper(torch.nn.Module):
    """WarpingNetwork returns {occlusion_map, deformation, out} — we want
    only `out` (the warped feature volume that the SPADE decoder consumes)
    plus `occlusion_map` (returned for completeness; some callers want it
    for blending). `deformation` is internal and not consumed downstream."""

    def __init__(self, net: WarpingNetwork):
        super().__init__()
        self.net = net

    def forward(self, feature_3d, kp_driving, kp_source):
        ret = self.net(feature_3d, kp_driving, kp_source)
        # `occlusion_map` may be None if estimate_occlusion_map was False;
        # for the human variant it is always present.
        return ret["out"], ret["occlusion_map"]


class GeneratorWrapper(torch.nn.Module):
    """SPADEDecoder returns the final RGB frame — already a single tensor."""

    def __init__(self, net: SPADEDecoder):
        super().__init__()
        self.net = net

    def forward(self, warped_feature):
        return self.net(warped_feature)


# ─────────────────────────────────────────────────────────────────────────────
# Build, load weights, trace, convert
# ─────────────────────────────────────────────────────────────────────────────

def build_appearance() -> AppearanceFeatureExtractor:
    p = HUMAN_256["appearance"]
    return AppearanceFeatureExtractor(
        image_channel=p["image_channel"],
        block_expansion=p["block_expansion"],
        num_down_blocks=p["num_down_blocks"],
        max_features=p["max_features"],
        reshape_channel=p["reshape_channel"],
        reshape_depth=p["reshape_depth"],
        num_resblocks=p["num_resblocks"],
    )


def build_motion() -> MotionExtractor:
    p = HUMAN_256["motion"]
    return MotionExtractor(
        backbone=p["backbone"],
        num_kp=p["num_kp"],
        num_bins=p["num_bins"],
    )


def build_warp() -> WarpingNetwork:
    p = HUMAN_256["warp"]
    return WarpingNetwork(
        num_kp=p["num_kp"],
        block_expansion=p["block_expansion"],
        max_features=p["max_features"],
        num_down_blocks=p["num_down_blocks"],
        reshape_channel=p["reshape_channel"],
        estimate_occlusion_map=p["estimate_occlusion_map"],
        dense_motion_params=p["dense_motion_params"],
    )


def build_generator() -> SPADEDecoder:
    p = HUMAN_256["generator"]
    return SPADEDecoder(
        upscale=p["upscale"],
        max_features=p["max_features"],
        block_expansion=p["block_expansion"],
        out_channels=p["out_channels"],
        num_down_blocks=p["num_down_blocks"],
    )


def find_checkpoints(weights_dir: Path) -> dict[str, Path]:
    """Locate the four base-model .pth files inside the user-supplied
    LivePortrait checkpoint directory. The upstream release lays them out
    under <weights_dir>/base_models/. We tolerate the user pointing at
    either the parent directory or `base_models/` directly."""
    candidates = [weights_dir, weights_dir / "base_models"]
    expected = {
        "appearance": "appearance_feature_extractor.pth",
        "motion":     "motion_extractor.pth",
        "warp":       "warping_module.pth",
        "generator":  "spade_generator.pth",
    }
    found: dict[str, Path] = {}
    for key, fname in expected.items():
        for d in candidates:
            p = d / fname
            if p.exists():
                found[key] = p
                break
        if key not in found:
            raise FileNotFoundError(
                f"could not locate {fname} under {weights_dir} or {weights_dir / 'base_models'}. "
                f"download the LivePortrait `human` checkpoint set and pass --weights "
                f"pointing at the directory that contains base_models/."
            )
    return found


def load_weights_into(nets: dict[str, torch.nn.Module], ckpts: dict[str, Path]):
    for key, net in nets.items():
        state = torch.load(str(ckpts[key]), map_location="cpu", weights_only=False)
        # Upstream LivePortrait checkpoints are saved as raw state_dicts
        # (no wrapping). If a future release wraps them with {"model": ...}
        # we unwrap defensively.
        if isinstance(state, dict) and "model" in state and all(
            not k.startswith(("first.", "down_blocks.", "detector.", "fc.", "G_middle_0.", "third.", "dense_motion_network."))
            for k in state.keys() if isinstance(k, str)
        ):
            state = state["model"]
        ret = net.load_state_dict(state, strict=False)
        # `strict=False` to tolerate the head-filtering convention in
        # MotionExtractor.load_pretrained, but we still surface missing
        # keys for debuggability.
        missing = getattr(ret, "missing_keys", [])
        unexpected = getattr(ret, "unexpected_keys", [])
        if missing or unexpected:
            print(f"[{key}] weight-load report: missing={len(missing)} unexpected={len(unexpected)}")
            if missing[:5]:
                print(f"  first missing keys: {missing[:5]}")
            if unexpected[:5]:
                print(f"  first unexpected keys: {unexpected[:5]}")


def convert_appearance(net: AppearanceFeatureExtractor, out_path: Path):
    wrapper = AppearanceWrapper(net).eval()
    example = torch.zeros(1, 3, HUMAN_256["image_size"], HUMAN_256["image_size"])
    traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="source_image", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="feature_3d", dtype=np.float32)],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh LivePortrait appearance feature extractor (human, fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from LivePortrait, MIT)"
    mlmodel.license = "MIT (architecture) + research-only (InsightFace runtime, not in this package)"
    mlmodel.save(str(out_path))


def convert_motion(net: MotionExtractor, out_path: Path):
    wrapper = MotionWrapper(net).eval()
    example = torch.zeros(1, 3, HUMAN_256["image_size"], HUMAN_256["image_size"])
    traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="driving_image", shape=example.shape, dtype=np.float32)],
        outputs=[
            ct.TensorType(name="pitch", dtype=np.float32),
            ct.TensorType(name="yaw",   dtype=np.float32),
            ct.TensorType(name="roll",  dtype=np.float32),
            ct.TensorType(name="t",     dtype=np.float32),
            ct.TensorType(name="exp",   dtype=np.float32),
            ct.TensorType(name="scale", dtype=np.float32),
            ct.TensorType(name="kp",    dtype=np.float32),
        ],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh LivePortrait motion extractor (ConvNeXtV2-tiny, fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from LivePortrait, MIT)"
    mlmodel.license = "MIT"
    mlmodel.save(str(out_path))


def convert_warp(net: WarpingNetwork, out_path: Path):
    wrapper = WarpWrapper(net).eval()
    feature = torch.zeros(1, FEATURE_C, FEATURE_D, FEATURE_H, FEATURE_W)
    kp      = torch.zeros(1, HUMAN_256["num_kp"], 3)
    traced  = torch.jit.trace(wrapper, (feature, kp, kp))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="feature_3d",   shape=feature.shape, dtype=np.float32),
            ct.TensorType(name="kp_driving",   shape=kp.shape,      dtype=np.float32),
            ct.TensorType(name="kp_source",    shape=kp.shape,      dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="warped_feature", dtype=np.float32),
            ct.TensorType(name="occlusion_map",  dtype=np.float32),
        ],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh LivePortrait warping network + dense motion (fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from LivePortrait, MIT)"
    mlmodel.license = "MIT"
    mlmodel.save(str(out_path))


def convert_generator(net: SPADEDecoder, out_path: Path):
    wrapper = GeneratorWrapper(net).eval()
    # Generator input is the warped 2D feature emitted by WarpingNetwork:
    # 256 channels at 64x64 (= max_features at the post-down-blocks scale).
    warped = torch.zeros(1, HUMAN_256["warp"]["block_expansion"] * (2 ** HUMAN_256["warp"]["num_down_blocks"]),
                         FEATURE_H, FEATURE_W)
    traced = torch.jit.trace(wrapper, warped)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="warped_feature", shape=warped.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="prediction", dtype=np.float32)],
        convert_to=CONVERT_TO,
        minimum_deployment_target=TARGET_MACOS,
        compute_precision=COMPUTE_PRECISION,
    )
    mlmodel.short_description = "MirrorMesh LivePortrait SPADE decoder (fp16)"
    mlmodel.author = "MirrorMesh contributors (vendored from LivePortrait, MIT)"
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
        "source": "models/training/liveportrait_to_coreml.py",
        "license": (
            "MIT (LivePortrait architecture and conversion outputs). The runtime "
            "face-detection weights from InsightFace are research-only and are NOT "
            "included in this .mlpackage — they are used (if at all) only by the "
            "user's host-side preprocessing pipeline. See "
            "LICENSES/InsightFace-research-only.txt and ADR-0015."
        ),
        "training_data_summary": (
            "LivePortrait `human` checkpoint trained by Kuaishou on a curated face dataset "
            "described in the LivePortrait paper (Guo et al. 2024). Training data is the "
            "upstream authors' work and is NOT redistributed by MirrorMesh. End user supplies "
            "the .pth files themselves; see models/training/README.md."
        ),
        "conversion_pipeline": (
            "torch.load(weights) -> AppearanceFeatureExtractor/MotionExtractor/WarpingNetwork/"
            "SPADEDecoder -> torch.jit.trace -> coremltools.convert(convert_to='mlprogram', "
            "precision=FLOAT16, target=macOS14) -> .mlpackage"
        ),
        "upstream_repo":   "https://github.com/KwaiVGI/LivePortrait",
        "upstream_commit": UPSTREAM_LP_COMMIT,
        "input_weights_path":     str(weights_path.name),
        "input_weights_sha256":   weights_sha,
        "conversion_script_sha256": script_sha,
        "config_variant":   "human (face reenactment)",
        "image_size":       HUMAN_256["image_size"],
        "num_kp":           HUMAN_256["num_kp"],
        "feature_volume":   f"{FEATURE_C}x{FEATURE_D}x{FEATURE_H}x{FEATURE_W}",
        "precision":        "fp16",
        "compute_target":   "macOS14 (CoreML mlprogram)",
        "converted_at":     time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime()),
        "size_bytes":       sum(f.stat().st_size for f in mlpkg_path.rglob("*") if f.is_file()),
        "sha256":           pkg_sha,
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

def latency_estimate(appearance_pkg: Path, motion_pkg: Path, warp_pkg: Path, gen_pkg: Path):
    """Run a single CoreML inference per model on the conversion host and
    print wall-clock times. CPU on the conversion box is NOT representative
    of ANE on an M-series device; numbers print as a sanity check only."""
    try:
        app_model = ct.models.MLModel(str(appearance_pkg))
        mot_model = ct.models.MLModel(str(motion_pkg))
        wrp_model = ct.models.MLModel(str(warp_pkg))
        gen_model = ct.models.MLModel(str(gen_pkg))
    except Exception as e:
        print(f"[latency] skipping — could not load mlpackage: {e}")
        return

    rng = np.random.default_rng(seed=0)
    sz  = HUMAN_256["image_size"]
    nk  = HUMAN_256["num_kp"]

    src     = rng.random((1, 3, sz, sz)).astype(np.float32)
    feature = rng.random((1, FEATURE_C, FEATURE_D, FEATURE_H, FEATURE_W)).astype(np.float32)
    kp      = rng.random((1, nk, 3)).astype(np.float32)
    warped  = rng.random((1,
                          HUMAN_256["warp"]["block_expansion"] * (2 ** HUMAN_256["warp"]["num_down_blocks"]),
                          FEATURE_H, FEATURE_W)).astype(np.float32)

    def time_one(label, fn):
        fn()  # warmup
        n = 5
        t0 = time.perf_counter()
        for _ in range(n):
            fn()
        dt = (time.perf_counter() - t0) / n * 1000.0
        print(f"[latency] {label:>12s}: {dt:7.2f} ms/iter (n={n}, host CPU — ANE will be faster)")

    time_one("appearance",  lambda: app_model.predict({"source_image": src}))
    time_one("motion",      lambda: mot_model.predict({"driving_image": src}))
    time_one("warp",        lambda: wrp_model.predict({
        "feature_3d": feature, "kp_driving": kp, "kp_source": kp,
    }))
    time_one("generator",   lambda: gen_model.predict({"warped_feature": warped}))


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--weights", required=True, type=Path,
                    help="Path to the upstream LivePortrait checkpoint directory "
                         "(parent of base_models/ — e.g. ~/Downloads/liveportrait).")
    ap.add_argument("--out", required=True, type=Path,
                    help="Output directory. Four .mlpackage and four .provenance.json "
                         "files will be written here.")
    ap.add_argument("--skip-latency", action="store_true",
                    help="Skip the post-conversion latency-estimate pass.")
    args = ap.parse_args(argv)

    if not args.weights.exists():
        print(f"weights directory not found: {args.weights}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    script_path = Path(__file__).resolve()

    print(f"[1/4] locating LivePortrait checkpoints under {args.weights}")
    ckpts = find_checkpoints(args.weights)
    for k, p in ckpts.items():
        print(f"        {k:>10s}: {p}")

    print(f"[2/4] building LivePortrait networks (human-256 hyperparameters)")
    nets = {
        "appearance": build_appearance(),
        "motion":     build_motion(),
        "warp":       build_warp(),
        "generator":  build_generator(),
    }
    load_weights_into(nets, ckpts)

    app_pkg = args.out / "appearance_v1.mlpackage"
    mot_pkg = args.out / "motion_v1.mlpackage"
    wrp_pkg = args.out / "warp_v1.mlpackage"
    gen_pkg = args.out / "generator_v1.mlpackage"

    print(f"[3/4] converting -> CoreML mlprogram (fp16, macOS14)")
    convert_appearance(nets["appearance"].eval(), app_pkg)
    convert_motion    (nets["motion"].eval(),     mot_pkg)
    convert_warp      (nets["warp"].eval(),       wrp_pkg)
    convert_generator (nets["generator"].eval(),  gen_pkg)

    print(f"[4/4] writing provenance sidecars")
    write_provenance("appearance_v1", app_pkg, ckpts["appearance"], script_path,
                     args.out / "appearance_v1.provenance.json",
                     {"role": "appearance feature extractor (F) — once per source identity, cached"})
    write_provenance("motion_v1", mot_pkg, ckpts["motion"], script_path,
                     args.out / "motion_v1.provenance.json",
                     {"role": "motion extractor (M) — once per driving frame"})
    write_provenance("warp_v1", wrp_pkg, ckpts["warp"], script_path,
                     args.out / "warp_v1.provenance.json",
                     {"role": "warping network with embedded dense motion (W) — once per driving frame"})
    write_provenance("generator_v1", gen_pkg, ckpts["generator"], script_path,
                     args.out / "generator_v1.provenance.json",
                     {"role": "SPADE decoder (G) — once per driving frame, the expensive one"})

    if not args.skip_latency:
        print()
        latency_estimate(app_pkg, mot_pkg, wrp_pkg, gen_pkg)
        print()
        print("Note: host-CPU timings are NOT representative of ANE/M-series performance.")
        print("Target on M5 Max with ANE: appearance ~8ms (cached!), motion ~5ms,")
        print("warp ~15ms, generator ~20ms — total per driving frame <45ms.")

    print()
    print(f"OK. wrote:")
    print(f"  {app_pkg}")
    print(f"  {mot_pkg}")
    print(f"  {wrp_pkg}")
    print(f"  {gen_pkg}")
    print(f"+ matching .provenance.json sidecars in {args.out}")
    return 0


if __name__ == "__main__":
    # Suppress duplicate-OpenMP linker warning between numpy and libtorch
    # (same workaround as models/training/blendshape_solver.py and
    # models/training/fomm_to_coreml.py).
    os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
    os.environ.setdefault("OMP_NUM_THREADS",      "1")
    sys.exit(main(sys.argv[1:]))
