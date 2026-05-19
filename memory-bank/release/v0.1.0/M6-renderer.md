# M6 — Metal Renderer (Overlay Compositor)

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M3, M4
**Blocks**: M10

## Objective

Render camera frames with debug landmark overlay and a basic stylized avatar mask driven by blendshape coefficients. All on the GPU, zero-copy from `CVPixelBuffer`.

## Deliverables

In `Sources/MirrorMeshRender/`:

- `MetalContext.swift` — `MTLDevice`, command queue, shader library
- `PassthroughPipeline.swift` — sample camera CVPixelBuffer to texture, blit to drawable
- `LandmarkOverlay.swift` — draws landmark points as a colored sprite cloud
- `AvatarMask.swift` — simple mesh rig responding to blendshape coefficients (cartoon face)
- `RendererOutput.swift` — produces a `CVPixelBuffer` for downstream watermarking + display

In `shaders/`:

- `Passthrough.metal` — vertex+fragment for textured quad
- `LandmarkSprite.metal` — instanced sprite shader
- `AvatarMask.metal` — vertex shader consuming blendshape uniforms

## Behavior

- Driven by an `AsyncStream<(CapturedFrame, LandmarkFrame, BlendshapeFrame)>`
- Outputs `RenderedFrame { frameID, pixelBuffer }`
- Renders into an offscreen `CVPixelBuffer` (IOSurface-backed) so the watermark stage and the display layer can both consume
- Toggle flags: showLandmarks, showAvatarMask (default both on for demo)

## Tests

- Snapshot test on a fixture frame at fixed seed; tolerance via hashed downsample
- Latency: P95 under 8 ms on M3 reference (warning-level assertion)

## Notes

- Render at capture resolution; upscale handled by the display layer
- Don't use SceneKit / RealityKit — raw Metal keeps the pipeline measurable
