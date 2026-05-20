# Package marker so the conversion script can import vendored FOMM modules.
#
# The vendored upstream uses `from modules.util import ...` style imports.
# models/training/fomm_to_coreml.py works around this by inserting
# `models/external/fomm/` onto sys.path *as* the package root named `modules`
# (i.e. it aliases `models/external/fomm` -> `modules`), preserving the
# original import statements in the vendored files unchanged.
