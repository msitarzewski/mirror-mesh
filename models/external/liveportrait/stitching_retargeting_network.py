# =============================================================================
# Vendored from: https://github.com/KwaiVGI/LivePortrait
# Path:         src/modules/stitching_retargeting_network.py
# Upstream commit: 49784e879821538ecda5c8e4ca0472f4cb6236cf (main, 2026-05-20 fetch)
# Upstream license: MIT  (LICENSE file in the source repository)
# Original copyright: Copyright (c) 2024 Kuaishou Visual Generation and
#                     Interaction Center
#
# MirrorMesh vendors this file for the v0.6.0+ LivePortrait CoreML conversion
# path (see models/training/liveportrait_to_coreml.py). The stitching /
# retargeting MLPs are small auxiliary heads that LivePortrait uses to paste
# the animated portrait back into the full image and to handle eye/lip
# normalisation. Vendored for completeness so the conversion script can
# materialise them on demand; the v0.6.0 PhotorealBackend wires only the
# four primary submodels (appearance / motion / warp / generator) — see
# Sources/MirrorMeshReenact/PhotorealBackend.swift.
#
# Local modifications: none.
# =============================================================================

# coding: utf-8

"""
Stitching module(S) and two retargeting modules(R) defined in the paper.

- The stitching module pastes the animated portrait back into the original image space without pixel misalignment, such as in
the stitching region.

- The eyes retargeting module is designed to address the issue of incomplete eye closure during cross-id reenactment, especially
when a person with small eyes drives a person with larger eyes.

- The lip retargeting module is designed similarly to the eye retargeting module, and can also normalize the input by ensuring that
the lips are in a closed state, which facilitates better animation driving.
"""
from torch import nn


class StitchingRetargetingNetwork(nn.Module):
    def __init__(self, input_size, hidden_sizes, output_size):
        super(StitchingRetargetingNetwork, self).__init__()
        layers = []
        for i in range(len(hidden_sizes)):
            if i == 0:
                layers.append(nn.Linear(input_size, hidden_sizes[i]))
            else:
                layers.append(nn.Linear(hidden_sizes[i - 1], hidden_sizes[i]))
            layers.append(nn.ReLU(inplace=True))
        layers.append(nn.Linear(hidden_sizes[-1], output_size))
        self.mlp = nn.Sequential(*layers)

    def initialize_weights_to_zero(self):
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.zeros_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, x):
        return self.mlp(x)
