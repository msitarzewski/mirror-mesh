# lp_diff fixtures — Phase 1 of the photoreal v2 plan

These two images are upstream LivePortrait demo assets, mirrored here so the
`mirrormesh-photoreal-bench` CLI has a stable, license-aware source + driver
pair for value-equivalence diffing against the upstream Python reference.

| File | Origin | Size |
|------|--------|------|
| `s0.jpg` | `KwaiVGI/LivePortrait/assets/examples/source/s0.jpg` (main) | 113 KB |
| `d0.jpg` | `KwaiVGI/LivePortrait/assets/examples/driving/d12.jpg` (renamed) | 96 KB |

We renamed `d12.jpg` → `d0.jpg` so the source/driver naming reads symmetrically;
it is the same upstream bytes. Both files are LivePortrait research demo content
covered by the same license posture that gates the rest of the LP vendoring
under `models/external/liveportrait/` (see `decisions.md#ADR-0015`).

## How to use

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run mirrormesh-photoreal-bench \
    --source Tests/MirrorMeshReenactTests/fixtures/lp_diff/s0.jpg \
    --driver Tests/MirrorMeshReenactTests/fixtures/lp_diff/d0.jpg \
    --out /tmp/swift_output.png
```

Then run the upstream LivePortrait Python on the same pair and `diff` the
outputs — see `memory project_photoreal_v2_plan.md` for the bisection tree.

## Re-fetch

```bash
curl -sSL -o Tests/MirrorMeshReenactTests/fixtures/lp_diff/s0.jpg \
    https://raw.githubusercontent.com/KwaiVGI/LivePortrait/main/assets/examples/source/s0.jpg
curl -sSL -o Tests/MirrorMeshReenactTests/fixtures/lp_diff/d0.jpg \
    https://raw.githubusercontent.com/KwaiVGI/LivePortrait/main/assets/examples/driving/d12.jpg
```
