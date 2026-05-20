# Package marker so the conversion script can import vendored LivePortrait modules.
#
# Upstream LivePortrait uses package-relative imports throughout
# (`from .util import ...`, `from .convnextv2 import ...`). Those resolve
# correctly as long as this directory is importable as a package. The
# conversion script (models/training/liveportrait_to_coreml.py) adds the
# parent (`models/external/`) to sys.path and imports the four submodels as
#     from liveportrait.appearance_feature_extractor import AppearanceFeatureExtractor
#     from liveportrait.motion_extractor              import MotionExtractor
#     from liveportrait.warping_network               import WarpingNetwork
#     from liveportrait.spade_generator               import SPADEDecoder
# which is the lightest setup that keeps the vendored relative imports
# unchanged. (FOMM's vendor needed an alias trick because the upstream files
# use `from modules.X import ...` — top-level, not relative.)
