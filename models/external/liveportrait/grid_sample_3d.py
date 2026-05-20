"""
grid_sample_3d.py — manual trilinear shim for rank-5 grid_sample.

MirrorMesh ADR-0015 vendor patch (2026-05-20).

`coremltools.converters.mil` lowers `torch.nn.functional.grid_sample` to the
`mb.resample` MIL op, which only accepts rank-4 inputs. LivePortrait's
3D-feature-volume warp uses `F.grid_sample` with rank-5 input + rank-5 grid,
so the direct conversion fails with:

    ValueError: input "x" to the "resample" op must be a rank 4 tensor.
                Got rank 5 tensor of shape (B*(K+1), C, D, H, W).

This module implements the rank-5 case in pure PyTorch tensor ops
(clamp / floor / gather / multiply / add) so the converted CoreML graph
stays single-pass. Numerical match to `F.grid_sample(..., mode='bilinear',
padding_mode='zeros', align_corners=False/True)` to within fp32 round-off.

Both `warping_network.py` and `dense_motion.py` are patched to call
`grid_sample_3d(inp, grid, align_corners=...)` instead of `F.grid_sample`.

Why not 2D-slice-by-slice: a 3D deformation field has a Z component that
crosses depth slices, so per-slice 2D sampling is not equivalent — you would
lose the trilinear blend along Z. The 8-corner gather + trilinear blend
below is the only direct rank-5 substitute that survives conversion.

License: AGPL-3.0-only (per ADR-0015). New MirrorMesh code, not derived
from upstream LivePortrait.
"""
from __future__ import annotations

import torch


def grid_sample_3d(inp: torch.Tensor, grid: torch.Tensor, align_corners: bool = False) -> torch.Tensor:
    """Trilinear sample a rank-5 volume by a rank-5 grid.

    Args:
        inp:  (N, C, D, H, W)
        grid: (N, Dout, Hout, Wout, 3) — last dim is (x, y, z) in [-1, 1]
              matching `F.grid_sample`'s convention.
        align_corners: same semantics as `F.grid_sample`.

    Returns:
        (N, C, Dout, Hout, Wout)
    """
    N, C, D, H, W = inp.shape
    _, Dout, Hout, Wout, _ = grid.shape

    # Normalize → continuous source-space index. F.grid_sample's grid stores
    # (x, y, z) → (W, H, D); preserve that ordering here.
    if align_corners:
        ix = (grid[..., 0] + 1.0) * (W - 1) * 0.5
        iy = (grid[..., 1] + 1.0) * (H - 1) * 0.5
        iz = (grid[..., 2] + 1.0) * (D - 1) * 0.5
    else:
        ix = ((grid[..., 0] + 1.0) * W - 1.0) * 0.5
        iy = ((grid[..., 1] + 1.0) * H - 1.0) * 0.5
        iz = ((grid[..., 2] + 1.0) * D - 1.0) * 0.5

    ix0 = torch.floor(ix).to(torch.int64)
    iy0 = torch.floor(iy).to(torch.int64)
    iz0 = torch.floor(iz).to(torch.int64)
    ix1 = ix0 + 1
    iy1 = iy0 + 1
    iz1 = iz0 + 1

    fx = ix - ix0.to(ix.dtype)
    fy = iy - iy0.to(iy.dtype)
    fz = iz - iz0.to(iz.dtype)

    # padding_mode='zeros' equivalent: build a per-corner validity mask so any
    # out-of-bounds gather contributes nothing to the blend. Clamp the index
    # tensors to safe range so the gather itself never errors.
    mask_x0 = ((ix0 >= 0) & (ix0 < W)).to(fx.dtype)
    mask_x1 = ((ix1 >= 0) & (ix1 < W)).to(fx.dtype)
    mask_y0 = ((iy0 >= 0) & (iy0 < H)).to(fx.dtype)
    mask_y1 = ((iy1 >= 0) & (iy1 < H)).to(fx.dtype)
    mask_z0 = ((iz0 >= 0) & (iz0 < D)).to(fx.dtype)
    mask_z1 = ((iz1 >= 0) & (iz1 < D)).to(fx.dtype)

    ix0c = ix0.clamp(0, W - 1)
    ix1c = ix1.clamp(0, W - 1)
    iy0c = iy0.clamp(0, H - 1)
    iy1c = iy1.clamp(0, H - 1)
    iz0c = iz0.clamp(0, D - 1)
    iz1c = iz1.clamp(0, D - 1)

    # Flatten spatial dims for `torch.gather` along the (D*H*W) axis. Any
    # rank-3 gather is convertible by coremltools (gather_along_axis).
    flat_inp = inp.reshape(N, C, D * H * W)

    def _gather(z_idx: torch.Tensor, y_idx: torch.Tensor, x_idx: torch.Tensor) -> torch.Tensor:
        flat_idx = z_idx * (H * W) + y_idx * W + x_idx               # (N, Dout, Hout, Wout)
        flat_idx = flat_idx.unsqueeze(1).expand(N, C, Dout, Hout, Wout)
        flat_idx = flat_idx.reshape(N, C, Dout * Hout * Wout)
        out = torch.gather(flat_inp, 2, flat_idx)                    # (N, C, Dout*Hout*Wout)
        return out.reshape(N, C, Dout, Hout, Wout)

    # 8 trilinear corners, each masked for out-of-bounds.
    c000 = _gather(iz0c, iy0c, ix0c) * (mask_z0 * mask_y0 * mask_x0).unsqueeze(1)
    c001 = _gather(iz0c, iy0c, ix1c) * (mask_z0 * mask_y0 * mask_x1).unsqueeze(1)
    c010 = _gather(iz0c, iy1c, ix0c) * (mask_z0 * mask_y1 * mask_x0).unsqueeze(1)
    c011 = _gather(iz0c, iy1c, ix1c) * (mask_z0 * mask_y1 * mask_x1).unsqueeze(1)
    c100 = _gather(iz1c, iy0c, ix0c) * (mask_z1 * mask_y0 * mask_x0).unsqueeze(1)
    c101 = _gather(iz1c, iy0c, ix1c) * (mask_z1 * mask_y0 * mask_x1).unsqueeze(1)
    c110 = _gather(iz1c, iy1c, ix0c) * (mask_z1 * mask_y1 * mask_x0).unsqueeze(1)
    c111 = _gather(iz1c, iy1c, ix1c) * (mask_z1 * mask_y1 * mask_x1).unsqueeze(1)

    fx_ = fx.unsqueeze(1)
    fy_ = fy.unsqueeze(1)
    fz_ = fz.unsqueeze(1)

    # X-axis blend
    c00 = c000 * (1.0 - fx_) + c001 * fx_
    c01 = c010 * (1.0 - fx_) + c011 * fx_
    c10 = c100 * (1.0 - fx_) + c101 * fx_
    c11 = c110 * (1.0 - fx_) + c111 * fx_
    # Y-axis blend
    c0 = c00 * (1.0 - fy_) + c01 * fy_
    c1 = c10 * (1.0 - fy_) + c11 * fy_
    # Z-axis blend
    return c0 * (1.0 - fz_) + c1 * fz_
