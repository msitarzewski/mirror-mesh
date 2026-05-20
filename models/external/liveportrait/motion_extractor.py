# =============================================================================
# Vendored from: https://github.com/KwaiVGI/LivePortrait
# Path:         src/modules/motion_extractor.py
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
# Local modifications: none.
# =============================================================================

# coding: utf-8

"""
Motion extractor(M), which directly predicts the canonical keypoints, head pose and expression deformation of the input image
"""

from torch import nn
import torch

from .convnextv2 import convnextv2_tiny
from .util import filter_state_dict

model_dict = {
    'convnextv2_tiny': convnextv2_tiny,
}


class MotionExtractor(nn.Module):
    def __init__(self, **kwargs):
        super(MotionExtractor, self).__init__()

        # default is convnextv2_base
        backbone = kwargs.get('backbone', 'convnextv2_tiny')
        self.detector = model_dict.get(backbone)(**kwargs)

    def load_pretrained(self, init_path: str):
        if init_path not in (None, ''):
            state_dict = torch.load(init_path, map_location=lambda storage, loc: storage)['model']
            state_dict = filter_state_dict(state_dict, remove_name='head')
            ret = self.detector.load_state_dict(state_dict, strict=False)
            print(f'Load pretrained model from {init_path}, ret: {ret}')

    def forward(self, x):
        out = self.detector(x)
        return out
