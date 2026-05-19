# M30 — Paper Draft v0

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M24, M25, M26, M27, M28
**Blocks**: (release)

## Objective

A submittable-quality paper draft v0 in `docs/paper/`, backed by reproducible numbers from the bench harness. Target venue class: SIGGRAPH / CHI / ASSETS — pick one after seeing v0.

## Deliverables

- `docs/paper/mirrormesh-v0.md` (Markdown master) and `.tex` (Pandoc-built)
- Sections:
  1. Abstract (sub-100ms claim, local-only, trust-preserving)
  2. Introduction (mission narrative: accessibility-first synthetic presence, the deepfake-tool divergence)
  3. Related work (LivePortrait, FOMM, ARKit blendshapes, deepfake-detection literature)
  4. System architecture (the 8-stage pipeline; this readme essentially)
  5. Trust layer (watermark/manifest cryptographic design; verifier UX)
  6. Evaluation (bench numbers from `docs/figures/`, MediaPipe vs Vision comparison from M26, geometric vs CoreML solver from M27, power numbers from M17)
  7. Limitations (no real-face fixture in CI, voice transform deferred, identity transfer deferred)
  8. Discussion (synthetic-accessibility framing; the open-source-with-architectural-constraints model)
  9. Reproducibility (Apache 2.0, all scripts in `bench/`, fixed-tag reproduction commands)
- `bench/scripts/paper_figures.sh` — wraps `figures.py` with the paper's specific scenario list, regenerates every figure from JSONL traces tagged for this paper revision
- `docs/paper/figures.tex` — auto-included by the master document

## Verification

```bash
bench/scripts/paper_figures.sh
pandoc docs/paper/mirrormesh-v0.md -o docs/paper/mirrormesh-v0.pdf --pdf-engine=xelatex
open docs/paper/mirrormesh-v0.pdf
```

PDF should compile cleanly with all referenced figures present.

## Notes

- This is "draft v0" — internal review only. Submission readiness is v0.4.0+.
- All claims must be backed by a runnable scenario in `bench/scenarios/` — no hand-edited numbers
- Reproducibility section includes: macOS version, Xcode version, hardware model, commit hash, scenario name → JSONL → figure
