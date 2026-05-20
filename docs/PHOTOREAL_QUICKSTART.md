# Photoreal Quick Start

**Status**: M88 (inference) + M89 (UX) — v1.0.0 finishing arc, 2026-05-20.

**What you'll see**: with a `.mmid` identity loaded and the LivePortrait weights
converted to Core ML, the **Mirror** style replaces your face on screen with the
identity's face in real time. ~40 ms P50 latency on M5 Max ANE, watermarked and
signed-manifested like every other frame the app emits.

If photoreal weights are missing, the app falls back to the stylized parameterized
head (v0.6.0 default). Nothing breaks; you just don't get the photoreal substitution.

## One-time setup

1. **Convert LivePortrait weights to Core ML** (~3-5 min). Full details in
   `models/training/README.md`. The short version:

   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

   # Pull the weights (research-only InsightFace dep — see ADR-0015).
   huggingface-cli download KwaiVGI/LivePortrait \
       --local-dir ~/.cache/liveportrait/weights

   # Convert all four mlpackages.
   python3.11 models/training/liveportrait_to_coreml.py \
       --weights ~/.cache/liveportrait/weights \
       --out models/
   ```

2. **Verify the four mlpackages exist** in `models/`:

   ```bash
   ls models/*.mlpackage
   # Expect: appearance_v1.mlpackage  motion_v1.mlpackage
   #         warp_v1.mlpackage        generator_v1.mlpackage
   ```

3. **(Optional) Move models to user-domain Application Support** if you'd prefer
   them outside the repo. The app checks both locations:

   ```bash
   mkdir -p "$HOME/Library/Application Support/MirrorMesh/models"
   mv models/*_v1.mlpackage "$HOME/Library/Application Support/MirrorMesh/models/"
   ```

   Detection order: `<repo-root>/models/` → `~/Library/Application Support/MirrorMesh/models/` → `<app bundle>/Resources/models/`.

## Running

1. `swift run mirrormesh-app`
2. **Identity inspector → Load Identity** → pick your `.mmid` (or accept the
   auto-provisioned self-as-source default).
3. **Style picker → Mirror** (or Mask).
4. The Identity inspector should now show **"Photoreal: ON"** with a green
   sparkles icon. The toolbar gains a **"Photoreal"** pill.
5. Your face on screen is now the identity from your `.mmid` bundle.

## Reading the inspector

| Inspector row                             | What it means                                                    |
|-------------------------------------------|------------------------------------------------------------------|
| Photoreal: ON (green sparkles)            | Models loaded; substituting frames in Mirror/Mask                |
| Photoreal: available (off) (gray sparkles)| Models found on disk; not currently active. Click to enable.     |
| Photoreal: not available (gray tray)      | mlpackages missing. Click to open `models/training/README.md`.   |
| Photoreal: error (red triangle)           | Stage failed to load — read the message; usually model mismatch  |

## Troubleshooting

- **"Photoreal: not available"** — confirm all four mlpackages are present
  via `ls models/*.mlpackage`. A partial set is treated as missing on purpose;
  the graph needs all four nodes.
- **"Photoreal: error: …"** — read the error string. Most common causes:
  - Model load mismatch (regenerate via `liveportrait_to_coreml.py`)
  - Identity scheme not eligible (only `selfAsSource` and `consentedThirdParty`
    can load photoreal — see `R1` + `PhotorealBackend.LoadError`)
  - mlpackage corrupted mid-download (re-pull and re-convert)
- **No visible difference in Mirror style** — confirm "Photoreal: ON" in the
  inspector. If it says ON but the face looks the same, the substitution chain
  may be bypassing the renderer; check Pipeline integration logs in
  `~/Library/Application Support/MirrorMesh/sessions/<latest>.manifest.json`
  for a `reenact.photoreal.loaded` event.
- **Wireframe style shows no change** — by design. Wireframe is the debug view;
  photoreal does not affect it.

## Trust surfaces (unchanged by photoreal)

- Every output frame still carries the Ed25519 watermark + visible badge (R2).
- The disclosure chirp still fires on session start (R2, locked-on in release).
- The session manifest still records `identity_sha256` so a verifier can
  prove which `.mmid` was active when the frames were emitted.

Photoreal is just another transformation mode behind the same trust layer.
