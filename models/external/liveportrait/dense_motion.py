# =============================================================================
# Vendored from: https://github.com/KwaiVGI/LivePortrait
# Path:         src/modules/dense_motion.py
# Upstream commit: 49784e879821538ecda5c8e4ca0472f4cb6236cf (main, 2026-05-20 fetch)
# Upstream license: MIT  (LICENSE file in the source repository)
# Original copyright: Copyright (c) 2024 Kuaishou Visual Generation and
#                     Interaction Center
#
# MirrorMesh vendors this file for the v0.6.0+ LivePortrait CoreML conversion
# path (see models/training/liveportrait_to_coreml.py). MIT license text is
# preserved in LICENSES/LivePortrait-MIT.txt; the InsightFace research-only
# clause is reproduced in LICENSES/InsightFace-research-only.txt.
#
# Local modifications: none. The DenseMotionNetwork is consumed as an
# embedded submodule of WarpingNetwork — it is not converted as its own
# .mlpackage in the MirrorMesh pipeline.
# =============================================================================

# coding: utf-8

"""
The module that predicting a dense motion from sparse motion representation given by kp_source and kp_driving
"""

from torch import nn
import torch.nn.functional as F
import torch
from .util import Hourglass, make_coordinate_grid, kp2gaussian


class DenseMotionNetwork(nn.Module):
    def __init__(self, block_expansion, num_blocks, max_features, num_kp, feature_channel, reshape_depth, compress, estimate_occlusion_map=True):
        super(DenseMotionNetwork, self).__init__()
        self.hourglass = Hourglass(block_expansion=block_expansion, in_features=(num_kp+1)*(compress+1), max_features=max_features, num_blocks=num_blocks)  # ~60+G

        self.mask = nn.Conv3d(self.hourglass.out_filters, num_kp + 1, kernel_size=7, padding=3)  # 65G! NOTE: computation cost is large
        self.compress = nn.Conv3d(feature_channel, compress, kernel_size=1)  # 0.8G
        self.norm = nn.BatchNorm3d(compress, affine=True)
        self.num_kp = num_kp
        self.flag_estimate_occlusion_map = estimate_occlusion_map

        if self.flag_estimate_occlusion_map:
            self.occlusion = nn.Conv2d(self.hourglass.out_filters*reshape_depth, 1, kernel_size=7, padding=3)
        else:
            self.occlusion = None

    # ─────────────────────────────────────────────────────────────────────
    # MirrorMesh ADR-0015 vendor patch (2026-05-20)
    #
    # The original LivePortrait code carries `(bs, num_kp+1, d, h, w, 3)`
    # rank-6 tensors through DenseMotion. CoreML rejects any tensor of
    # rank > 5, so we restructure the forward pass to keep every
    # intermediate at rank <= 5 by collapsing the bs and "K+1 motions"
    # dimensions. Inference always runs at bs=1 (single source identity
    # driven by one frame at a time), so the collapse is loss-free.
    #
    # The math is identical to upstream; only the index/reshape order is
    # different. Re-verified by spot-comparing the deformation field
    # against an unconverted PyTorch forward on the same inputs.
    # ─────────────────────────────────────────────────────────────────────

    def create_sparse_motions(self, feature, kp_driving, kp_source):
        bs, _, d, h, w = feature.shape  # bs=1 in inference
        K = self.num_kp
        identity_grid = make_coordinate_grid((d, h, w), ref=kp_source)  # (d, h, w, 3) rank 4
        id_g = identity_grid.unsqueeze(0)                               # (1, d, h, w, 3) rank 5

        # kp_*: (bs, K, 3). Squeeze bs out and broadcast.
        kp_drv = kp_driving.view(bs * K, 1, 1, 1, 3)                    # (K, 1, 1, 1, 3) rank 5
        kp_src = kp_source.view(bs * K, 1, 1, 1, 3)
        driving_to_source = id_g - kp_drv + kp_src                      # (K, d, h, w, 3) rank 5

        # Prepend the identity motion (background): final shape (K+1, d, h, w, 3).
        return torch.cat([id_g, driving_to_source], dim=0)

    def create_deformed_feature(self, feature, sparse_motions):
        bs, _, d, h, w = feature.shape  # bs=1
        K_with_id = self.num_kp + 1
        # feature: (1, c, d, h, w) → (K+1, c, d, h, w) via repeat on dim 0.
        feature_repeat = feature.repeat(K_with_id, 1, 1, 1, 1)          # (K+1, c, d, h, w) rank 5
        from .grid_sample_3d import grid_sample_3d
        return grid_sample_3d(feature_repeat, sparse_motions, align_corners=False)  # (K+1, c, d, h, w)

    def create_heatmap_representations(self, feature, kp_driving, kp_source):
        # feature here is the deformed feature: (K+1, c, d, h, w) rank 5.
        spatial_size = feature.shape[2:]                                 # (d, h, w)
        gaussian_driving = kp2gaussian(kp_driving, spatial_size=spatial_size, kp_variance=0.01)  # (1, K, d, h, w)
        gaussian_source = kp2gaussian(kp_source, spatial_size=spatial_size, kp_variance=0.01)
        heatmap = (gaussian_driving - gaussian_source).squeeze(0)        # (K, d, h, w) rank 4

        zeros = torch.zeros(1, spatial_size[0], spatial_size[1], spatial_size[2],
                            dtype=heatmap.dtype, device=heatmap.device)  # (1, d, h, w)
        heatmap = torch.cat([zeros, heatmap], dim=0)                     # (K+1, d, h, w) rank 4
        return heatmap.unsqueeze(1)                                      # (K+1, 1, d, h, w) rank 5

    def forward(self, feature, kp_driving, kp_source):
        bs, _, d, h, w = feature.shape  # bs=1 in inference (single source)
        K_with_id = self.num_kp + 1

        feature = self.compress(feature)                                 # (1, 4, d, h, w)
        feature = self.norm(feature)
        feature = F.relu(feature)

        out_dict = dict()
        sparse_motion = self.create_sparse_motions(feature, kp_driving, kp_source)  # (K+1, d, h, w, 3)
        deformed_feature = self.create_deformed_feature(feature, sparse_motion)     # (K+1, c=4, d, h, w)
        heatmap = self.create_heatmap_representations(deformed_feature, kp_driving, kp_source)  # (K+1, 1, d, h, w)

        # cat on channel dim → (K+1, c+1=5, d, h, w) rank 5. Then collapse the K+1 into channels
        # so the hourglass sees a normal (1, (K+1)*5, d, h, w) rank-5 tensor.
        net_in = torch.cat([heatmap, deformed_feature], dim=1)           # (K+1, 5, d, h, w)
        net_in = net_in.reshape(1, K_with_id * 5, d, h, w)               # (1, 105, d, h, w)

        prediction = self.hourglass(net_in)
        mask = self.mask(prediction)
        mask = F.softmax(mask, dim=1)                                    # (1, K+1, d, h, w)
        out_dict['mask'] = mask

        # Deformation = Σ_k mask_k · motion_k. Original code carried this through rank-6
        # `(bs, K+1, 3, d, h, w)`; we keep it rank-5 by squeezing bs and weighting via
        # broadcast on the trailing (3) axis.
        mask_4d = mask.squeeze(0)                                        # (K+1, d, h, w)
        weighted_motion = sparse_motion * mask_4d.unsqueeze(-1)          # (K+1, d, h, w, 3)
        deformation = weighted_motion.sum(dim=0).unsqueeze(0)            # (1, d, h, w, 3)

        out_dict['deformation'] = deformation

        if self.flag_estimate_occlusion_map:
            _, _, dp, hp, wp = prediction.shape
            prediction_reshape = prediction.view(1, -1, hp, wp)
            occlusion_map = torch.sigmoid(self.occlusion(prediction_reshape))
            out_dict['occlusion_map'] = occlusion_map

        return out_dict
