#!/usr/bin/env python3
"""Train a tiny MLP that approximates the MirrorMesh GeometricSolver, then convert to CoreML.

This script is *illustrative*. It is **not** invoked during `swift build` / `swift test`.
It exists so the provenance of `models/blendshape_solver_v1.mlpackage` is fully transparent
per `memory-bank/projectRules.md` R5.

NOTE: This environment may not have `torch` or `coremltools` installed, and may have no GPU.
If you cannot run this script locally, the Swift `CoreMLSolver` will detect the missing
.mlpackage and transparently fall back to `GeometricSolver`, emitting a single warning
telemetry event. The training script is committed regardless so the conversion pipeline is
reproducible by anyone with a Python environment.

Inputs
------
- A flat Float32 vector of length 152 = 76 landmark points * (x, y)
- All inputs in normalized image space [0, 1]

Outputs
-------
- 52 ARKit blendshape coefficients in [0, 1], ordered by `BlendshapeKey.rawValue` ascending

Training data
-------------
Synthetic. We sample a random "neutral" face, perturb individual landmarks along plausible
axes (mouth open, eye blink, brow raise, etc.), and label each sample with the same
geometric rules the Swift `GeometricSolver` uses. The model therefore learns to **mimic**
the geometric solver — not to outperform it on real faces — but does so in a fully
differentiable form suitable for later fine-tuning on a real consented dataset.

No human face data is used. No identifiable biometric data is touched.

Output
------
`models/blendshape_solver_v1.mlpackage`
"""

from __future__ import annotations

import math
import os
import sys
from pathlib import Path

# Hard-fail with a clear message if the optional ML stack is missing. CI does not invoke
# this script; only humans regenerating weights need these.
try:
    import numpy as np
    import torch
    import torch.nn as nn
    import coremltools as ct
except ImportError as e:
    print(f"missing dependency: {e}", file=sys.stderr)
    print("install: pip install torch coremltools numpy", file=sys.stderr)
    sys.exit(1)


# ── Schema constants — must stay in sync with Sources/MirrorMeshCore/FrameProtocols.swift
BLENDSHAPE_KEYS = sorted([
    "browDownLeft", "browDownRight", "browInnerUp",
    "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "eyeBlinkLeft", "eyeBlinkRight",
    "eyeLookDownLeft", "eyeLookDownRight",
    "eyeLookInLeft", "eyeLookInRight",
    "eyeLookOutLeft", "eyeLookOutRight",
    "eyeLookUpLeft", "eyeLookUpRight",
    "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimpleLeft", "mouthDimpleRight",
    "mouthFrownLeft", "mouthFrownRight",
    "mouthFunnel", "mouthLeft",
    "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthPressLeft", "mouthPressRight",
    "mouthPucker", "mouthRight",
    "mouthRollLower", "mouthRollUpper",
    "mouthShrugLower", "mouthShrugUpper",
    "mouthSmileLeft", "mouthSmileRight",
    "mouthStretchLeft", "mouthStretchRight",
    "mouthUpperUpLeft", "mouthUpperUpRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
])
assert len(BLENDSHAPE_KEYS) == 52

# Landmark indices mirror Sources/MirrorMeshSolver/MirrorMeshSolver.swift
MOUTH_UPPER = 44
MOUTH_LOWER = 52
MOUTH_LEFT  = 40
MOUTH_RIGHT = 48
LEFT_EYE_UP  = 18
LEFT_EYE_LO  = 22
RIGHT_EYE_UP = 26
RIGHT_EYE_LO = 30
BROW_L_INNER = 64
BROW_R_INNER = 70


def clamp01(x: np.ndarray) -> np.ndarray:
    return np.clip(x, 0.0, 1.0)


def make_neutral() -> np.ndarray:
    """Canonical neutral face — same skeleton the Swift `makeNeutralPoints()` test helper uses."""
    pts = np.full((76, 2), 0.5, dtype=np.float32)
    # Face outline ellipse 0..15
    for i in range(16):
        th = i / 16.0 * 2 * math.pi
        pts[i] = (0.5 + 0.25 * math.cos(th), 0.5 + 0.3 * math.sin(th))
    # Mouth ring 40..55
    for i in range(16):
        th = i / 16.0 * 2 * math.pi
        pts[40 + i] = (0.5 + 0.1 * math.cos(th), 0.62 + 0.02 * math.sin(th))
    pts[MOUTH_LEFT]  = (0.40, 0.62)
    pts[MOUTH_UPPER] = (0.50, 0.60)
    pts[MOUTH_RIGHT] = (0.60, 0.62)
    pts[MOUTH_LOWER] = (0.50, 0.64)
    # Eyes
    pts[LEFT_EYE_UP]  = (0.40, 0.40)
    pts[LEFT_EYE_LO]  = (0.40, 0.44)
    pts[RIGHT_EYE_UP] = (0.60, 0.40)
    pts[RIGHT_EYE_LO] = (0.60, 0.44)
    # Brows
    pts[BROW_L_INNER] = (0.43, 0.34)
    pts[BROW_R_INNER] = (0.57, 0.34)
    return pts


def geometric_label(current: np.ndarray, neutral: np.ndarray) -> np.ndarray:
    """Reproduce the Swift solver's rule-based coefficients for supervision."""
    coef = {k: 0.0 for k in BLENDSHAPE_KEYS}
    face_h = 0.6
    face_w = 0.5

    def scale(v, gain): return float(max(0.0, min(1.0, v * gain)))

    # jawOpen
    cur = current[MOUTH_LOWER, 1] - current[MOUTH_UPPER, 1]
    neu = neutral[MOUTH_LOWER, 1] - neutral[MOUTH_UPPER, 1]
    coef["jawOpen"] = scale((cur - neu) / face_h, 6.0)

    # smile / frown
    dxL = (current[MOUTH_LEFT, 0] - neutral[MOUTH_LEFT, 0]) / face_w
    dxR = (current[MOUTH_RIGHT, 0] - neutral[MOUTH_RIGHT, 0]) / face_w
    dyL = (current[MOUTH_LEFT, 1] - neutral[MOUTH_LEFT, 1]) / face_h
    dyR = (current[MOUTH_RIGHT, 1] - neutral[MOUTH_RIGHT, 1]) / face_h
    coef["mouthSmileLeft"]  = scale(-dxL - dyL, 8.0)
    coef["mouthSmileRight"] = scale(dxR - dyR, 8.0)
    coef["mouthFrownLeft"]  = scale(dyL, 8.0)
    coef["mouthFrownRight"] = scale(dyR, 8.0)

    # eye blink L/R
    def blink(up, lo):
        c = current[lo, 1] - current[up, 1]
        n = neutral[lo, 1] - neutral[up, 1]
        if n <= 1e-5: return 0.0, 0.0
        r = c / n
        return float(max(0.0, min(1.0, 1 - r))), float(max(0.0, min(1.0, r - 1)))
    bl, wl = blink(LEFT_EYE_UP, LEFT_EYE_LO)
    br, wr = blink(RIGHT_EYE_UP, RIGHT_EYE_LO)
    coef["eyeBlinkLeft"], coef["eyeWideLeft"] = bl, wl
    coef["eyeBlinkRight"], coef["eyeWideRight"] = br, wr

    # brow raise (inner)
    dyLi = (current[BROW_L_INNER, 1] - neutral[BROW_L_INNER, 1]) / face_h
    dyRi = (current[BROW_R_INNER, 1] - neutral[BROW_R_INNER, 1]) / face_h
    coef["browInnerUp"]   = scale(-(dyLi + dyRi) * 0.5, 12.0)
    coef["browDownLeft"]  = scale(dyLi, 12.0)
    coef["browDownRight"] = scale(dyRi, 12.0)

    return np.array([coef[k] for k in BLENDSHAPE_KEYS], dtype=np.float32)


def sample_batch(batch_size: int, neutral: np.ndarray, rng: np.random.Generator):
    """Random plausible perturbations of the neutral face."""
    landmarks = np.tile(neutral[None, :, :], (batch_size, 1, 1)).astype(np.float32)
    # Random jaw open
    open_amt = rng.uniform(0.0, 0.15, size=batch_size).astype(np.float32)
    landmarks[:, MOUTH_LOWER, 1] += open_amt
    # Random smile/frown
    smile = rng.uniform(-0.05, 0.05, size=batch_size).astype(np.float32)
    landmarks[:, MOUTH_LEFT, 0]  -= smile
    landmarks[:, MOUTH_RIGHT, 0] += smile
    landmarks[:, MOUTH_LEFT, 1]  -= smile * 0.3
    landmarks[:, MOUTH_RIGHT, 1] -= smile * 0.3
    # Random blink L/R
    blink_l = rng.uniform(0.0, 0.04, size=batch_size).astype(np.float32)
    blink_r = rng.uniform(0.0, 0.04, size=batch_size).astype(np.float32)
    landmarks[:, LEFT_EYE_UP, 1]  += blink_l
    landmarks[:, RIGHT_EYE_UP, 1] += blink_r
    # Random brow raise
    brow = rng.uniform(-0.04, 0.04, size=batch_size).astype(np.float32)
    landmarks[:, BROW_L_INNER, 1] += brow
    landmarks[:, BROW_R_INNER, 1] += brow
    # Add small per-point jitter
    landmarks += rng.normal(0, 0.001, size=landmarks.shape).astype(np.float32)
    landmarks = np.clip(landmarks, 0.0, 1.0)

    targets = np.stack([geometric_label(landmarks[i], neutral) for i in range(batch_size)])
    return landmarks.reshape(batch_size, -1), targets


class TinyMLP(nn.Module):
    """2 hidden layers x 64 units, ReLU, sigmoid output. ~14K parameters; <100 KB on disk."""

    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(152, 64), nn.ReLU(),
            nn.Linear(64, 64),  nn.ReLU(),
            nn.Linear(64, 52),  nn.Sigmoid(),
        )

    def forward(self, x):
        return self.net(x)


def train(
    epochs: int = 50,
    train_samples: int = 10_000,
    val_samples: int = 1_000,
    batch_size: int = 256,
    lr: float = 1e-3,
) -> tuple[TinyMLP, float]:
    """Train the MLP on a fixed synthetic dataset; return (model, final_val_loss)."""
    rng = np.random.default_rng(seed=42)
    neutral = make_neutral()

    # Pre-generate one large fixed dataset so each epoch is a real pass over the same data.
    x_train, y_train = sample_batch(train_samples, neutral, rng)
    x_val,   y_val   = sample_batch(val_samples,   neutral, rng)
    xt_train = torch.from_numpy(x_train)
    yt_train = torch.from_numpy(y_train)
    xt_val   = torch.from_numpy(x_val)
    yt_val   = torch.from_numpy(y_val)

    model = TinyMLP()
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    loss_fn = nn.MSELoss()

    n = xt_train.shape[0]
    last_val = float("nan")
    print(f"train_samples={n}  val_samples={xt_val.shape[0]}  epochs={epochs}  batch={batch_size}  lr={lr}")
    for epoch in range(epochs):
        model.train()
        perm = torch.randperm(n)
        running = 0.0
        steps = 0
        for start in range(0, n, batch_size):
            idx = perm[start:start + batch_size]
            pred = model(xt_train[idx])
            loss = loss_fn(pred, yt_train[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
            running += float(loss.item())
            steps += 1
        train_loss = running / max(steps, 1)
        model.eval()
        with torch.no_grad():
            val_loss = float(loss_fn(model(xt_val), yt_val).item())
        last_val = val_loss
        print(f"epoch {epoch:3d}  train_loss={train_loss:.6f}  val_loss={val_loss:.6f}")
    model.eval()
    return model, last_val


def convert_to_coreml(model: TinyMLP, out_path: Path):
    example = torch.zeros(1, 152)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="landmarks", shape=(1, 152), dtype=np.float32)],
        outputs=[ct.TensorType(name="coefficients", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "MirrorMesh blendshape solver v1 (synthetic-trained MLP)"
    mlmodel.author = "MirrorMesh contributors"
    mlmodel.license = "Apache-2.0"
    mlmodel.save(str(out_path))


def sha256_of_path(path: Path) -> str:
    """sha256 over a file or, for an .mlpackage directory, over its concatenated sorted contents."""
    import hashlib
    h = hashlib.sha256()
    if path.is_dir():
        for f in sorted(path.rglob("*")):
            if f.is_file():
                # Include the relative path so structural changes also alter the hash.
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


def main():
    out_dir = Path(__file__).resolve().parent.parent
    out_path = out_dir / "blendshape_solver_v1.mlpackage"
    print(f"output: {out_path}")
    model, val_loss = train()
    convert_to_coreml(model, out_path)
    digest = sha256_of_path(out_path)
    print(f"validation MSE: {val_loss:.6f}")
    print(f"sha256: {digest}")
    print(f"path:   {out_path}")
    print("done. Provenance sidecar should record this sha256.")


if __name__ == "__main__":
    main()
