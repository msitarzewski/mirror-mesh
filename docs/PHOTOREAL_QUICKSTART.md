# Photoreal Quick Start

**Status**: M88 (inference) + M89 (UX) — v1.0.0 finishing arc, 2026-05-20.
**v1.1.0**: Capture-as-identity flow lands (see below).

**What you'll see**: with a `.mmid` identity loaded and the LivePortrait weights
converted to Core ML, the **Mirror** style replaces your face on screen with the
identity's face in real time. ~40 ms P50 latency on M5 Max ANE, watermarked and
signed-manifested like every other frame the app emits.

If photoreal weights are missing, the app falls back to the stylized parameterized
head (v0.6.0 default). Nothing breaks; you just don't get the photoreal substitution.

## Quickest path: capture-as-identity

Once you've started a session and you can see yourself in the camera view:

1. Open the Identity inspector (right panel)
2. Click **"Capture as my identity"**
3. The app crops your face, signs it as a self-as-source `.mmid`, hot-swaps
   it into the running pipeline, and (if LivePortrait weights are installed)
   the photoreal stage reloads with your real face as the source
4. Switch to Mirror style → the rendered face is now driven by you

This replaces the auto-provisioned default identity (a 1×1 transparent PNG
that has no facial data) with your actual face. The default is fine for
the stylized 3D-head path; photoreal needs a real face PNG to drive from.

The capture pipeline: Apple Vision `VNDetectFaceRectanglesRequest` finds the
head, expands the bbox 25 % each side, center-squares, clamps to image bounds,
Lanczos-resamples to 256×256 RGBA, then signs the result as a fresh
`self-as-source` bundle with a new Ed25519 keypair (R1-compliant — the user
IS the source of their own face). The bundle is written to
`~/Library/Application Support/MirrorMesh/default.mmid` so subsequent launches
re-use it. The watermark, visible badge, and audible chirp are unchanged (R12).

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

## Trust surfaces (unchanged by photoreal)

- Every output frame still carries the Ed25519 watermark + visible badge (R2).
- The disclosure chirp still fires on session start (R2, locked-on in release).
- The session manifest still records `identity_sha256` so a verifier can
  prove which `.mmid` was active when the frames were emitted.

Photoreal is just another transformation mode behind the same trust layer.

## What's under the hood

The photoreal substitution runs inside `MirrorMeshOutput.PhotorealStage`,
which owns a `PhotorealBackend` (LivePortrait or FOMM). The per-frame
graph: vision lands a `CapturedFrame`, the stage calls `backend.reenact(driver:)`,
the returned CVPixelBuffer replaces `captured.pixelBuffer` (frameID and
hostTimeNs preserved), the substituted frame flows through the renderer
and watermarker. The manifest's `photoreal_active` flag flips to true.

In Wireframe style the substitution is suppressed by design — you keep
the camera + landmark + stylized-ghost debug view so you can verify the
solver is working correctly even when photoreal is loaded.

Latency budget on M5 Max ANE:
  appearance: ~8 ms (cached per session)
  motion:     ~5 ms / frame
  warp:       ~15 ms / frame
  generator:  ~20 ms / frame
  total:      ~40 ms / frame (well under the 100 ms P95 budget at 30 fps)

## Troubleshooting

### "I changed the source code but the app looks the same"
The build cache might be stale, or an old instance might still be running.
Try:

    ./scripts/dev/refresh.sh

That runs `swift package clean`, rebuilds, kills any running instance,
and relaunches. Takes ~30 seconds.

### "Photoreal: ON but Mirror style looks unchanged"
Likely cause: your loaded identity's source PNG isn't a real face. The
auto-provisioned default at `~/Library/Application Support/MirrorMesh/default.mmid`
is a 1×1 transparent PNG (sufficient to satisfy the consent gate but not
to drive LivePortrait). Use the "Capture as my identity" button in the
Identity inspector to mint a fresh self-as-source bundle from your live
camera frame.

### "Conversion script crashed with NotImplementedError: 'upsample_nearest3d'"
You're on a fresh checkout that didn't pick up the vendor patches in
models/external/liveportrait/. Pull the latest main; the patches are in
54e079d.

### "models/*_v1.mlpackage missing after my own conversion script run"
Check the script's last 10 lines of output — coremltools writes the files
even on partial conversions, so a "wrote: ..." line for each of the four
submodels is the success indicator. If any are missing, the conversion
failed silently for that submodel (rare with the vendor patches applied).

### "Apple Speech transcription stays at (no transcript yet)"
First-launch permission flow: macOS prompts for Microphone + Speech
Recognition. Grant both, then restart the app. Verify under System
Settings → Privacy & Security → Speech Recognition that MirrorMesh is
listed and enabled. Also verify the on-device en-US Speech model is
installed (System Settings → Spoken Content → System Voice → Manage Voices).

### "Photoreal: not available"
Confirm all four mlpackages are present via `ls models/*.mlpackage`. A
partial set is treated as missing on purpose; the graph needs all four
nodes.

### "Photoreal: error: …"
Read the error string. Most common causes:
- Model load mismatch (regenerate via `liveportrait_to_coreml.py`)
- Identity scheme not eligible (only `selfAsSource` and `consentedThirdParty`
  can load photoreal — see `R1` + `PhotorealBackend.LoadError`)
- mlpackage corrupted mid-download (re-pull and re-convert)

### "No visible difference in Mirror style"
Confirm "Photoreal: ON" in the inspector. If it says ON but the face
looks the same, the substitution chain may be bypassing the renderer;
check Pipeline integration logs in
`~/Library/Application Support/MirrorMesh/sessions/<latest>.manifest.json`
for a `reenact.photoreal.loaded` event.

### "Wireframe style shows no change"
By design. Wireframe is the debug view; photoreal does not affect it.
