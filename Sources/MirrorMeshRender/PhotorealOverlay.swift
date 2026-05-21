import Foundation
import Metal
import CoreGraphics
import simd

public enum PhotorealOverlayError: Error, CustomStringConvertible {
    case missingFunction(String)
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .missingFunction(let n):        return "PhotorealOverlay: missing Metal function '\(n)'"
        case .pipelineCreationFailed(let s): return "PhotorealOverlay: pipeline creation failed (\(s))"
        }
    }
}

/// Composites a photoreal generator's RGB output (LivePortrait / FOMM) over the already-
/// rendered camera passthrough at the face bounding-box location. Replaces the v1.0
/// "swap the whole captured pixel buffer" approach that was aspect-stretching a 256x256
/// square to a 640x360 viewport and erasing the user's background.
///
/// The class follows the same shape as `PassthroughPipeline` / `StylizedHeadRenderer`:
/// a single `MTLRenderPipelineState` built at construction, a stateless `encode(...)` API
/// driven by per-frame uniforms passed via `setVertexBytes` (no per-call MTLBuffer
/// allocation), and source-over alpha blending so the composite layers cleanly atop the
/// existing color attachment.
///
/// Per-frame inputs:
///   • `photorealTexture`: the photoreal generator output as a `MTLTexture` (BGRA8Unorm).
///     The renderer wraps the CVPixelBuffer produced by `PhotorealBackend.reenact` via
///     `MetalContext.makeTexture`. Origin is top-left (matches Vision's normalized image-
///     space convention).
///   • `bboxNorm`: the face bounding box in normalized image space [0,1] with origin top-left
///     (the standard `LandmarkFrame.faceBoundingBoxNorm` convention). The class converts
///     to NDC internally.
///   • Viewport dimensions are accepted for API symmetry with the other overlay encoders;
///     they aren't used in the per-frame math because the bbox is already viewport-relative.
///
/// Thread / actor model: not Sendable. The renderer owns one instance and drives it from
/// its single render executor, exactly like `PassthroughPipeline` and `LandmarkOverlay`.
public final class PhotorealOverlay {
    /// Mirrors `PhotorealOverlayUniforms` in PhotorealOverlay.metal byte-for-byte.
    /// `_pad0/_pad1` keep the struct at a 32-byte size so the `constant` buffer alignment
    /// rules on Metal don't reinterpret subsequent stages' bytes.
    private struct Uniforms {
        var bboxNDC: SIMD4<Float>   // (x, y) = bottom-left in NDC, (z, w) = width, height
        var opacity: Float
        var edgeFeather: Float
        var _pad0: Float = 0
        var _pad1: Float = 0
    }

    public let pipelineState: MTLRenderPipelineState

    public init(context: MetalContext) throws {
        guard let vfn = context.library.makeFunction(name: "photoreal_overlay_vertex") else {
            throw PhotorealOverlayError.missingFunction("photoreal_overlay_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "photoreal_overlay_fragment") else {
            throw PhotorealOverlayError.missingFunction("photoreal_overlay_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied source-over: the fragment shader emits (rgb * a, a) so the blend
        // factors are (1, 1-srcA) per channel. Same shape as StylizedHeadRenderer's blend
        // setup, just premultiplied here because the edge feather modulates alpha directly.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try context.device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw PhotorealOverlayError.pipelineCreationFailed(String(describing: error))
        }
    }

    /// Encode the composite draw into an already-active render command encoder. The encoder
    /// must have a color attachment bound (typically the renderer's destination texture,
    /// already populated by the passthrough pass).
    ///
    /// - Parameters:
    ///   - encoder: the active `MTLRenderCommandEncoder`.
    ///   - photorealTexture: the photoreal RGB texture to composite (origin top-left).
    ///   - bboxNorm: face bounding box in normalized image space [0,1], origin top-left
    ///               (Vision convention). When this rect is empty or degenerate the encode
    ///               is a no-op — no draw is issued.
    ///   - viewportWidth / viewportHeight: render-target dimensions. Accepted for API symmetry
    ///               with `LandmarkOverlay`/`FaceMeshRenderer`; not currently consumed here.
    ///   - opacity: global multiplier on the final alpha. Default 1.0 = fully opaque face.
    ///              Use < 1.0 for a translucent "ghost" debug effect.
    ///   - edgeFeather: width of the edge ramp as a fraction of the bbox size. Default 0.10
    ///                  = a 10%-of-bbox soft band on each side. 0 disables feathering (hard
    ///                  rectangle cut). Clamped at 0.5 by the shader.
    public func encode(
        into encoder: MTLRenderCommandEncoder,
        photorealTexture: MTLTexture,
        bboxNorm: CGRect,
        viewportWidth: Int,
        viewportHeight: Int,
        opacity: Float = 1.0,
        edgeFeather: Float = 0.10
    ) {
        // Defensive: viewport dims are accepted for API symmetry. Acknowledge them so a
        // future feather-in-pixels mode doesn't need a signature change.
        _ = viewportWidth
        _ = viewportHeight
        // Skip degenerate bboxes — Vision occasionally reports zero-area boxes when the face
        // briefly leaves the frame. Drawing them would clip to a single pixel column and look
        // worse than just not drawing.
        guard bboxNorm.width > 0, bboxNorm.height > 0 else { return }

        // Convert the [0,1] top-left-origin bbox to NDC [-1,1] with bottom-left origin (the
        // shader projects quad corners by `bboxNDC.x + cx * bboxNDC.z`).
        //
        // Image-space x in [0,1] maps to NDC x in [-1,1] via: nx = 2*x - 1
        // Image-space y (top-left, y down) maps to NDC y (bottom-left, y up) via flipping;
        // a top edge at y_img = bboxNorm.minY corresponds to NDC y = 1 - 2 * bboxNorm.minY.
        // Since the shader treats quad-local v in [0,1] as "bottom -> top" (cy from corners),
        // the bbox's NDC bottom-left is at NDC-y = 1 - 2 * bboxNorm.maxY.
        let xNDC = Float(2.0 * bboxNorm.minX - 1.0)
        let yNDC = Float(1.0 - 2.0 * bboxNorm.maxY)       // bottom edge in NDC
        let wNDC = Float(2.0 * bboxNorm.width)
        let hNDC = Float(2.0 * bboxNorm.height)

        var uniforms = Uniforms(
            bboxNDC: SIMD4<Float>(xNDC, yNDC, wNDC, hNDC),
            opacity: max(0, min(1, opacity)),
            // Hard upper bound at 0.5 — at exactly 0.5 the smoothstep edges from both sides
            // meet in the middle and the whole quad has alpha ~1; beyond 0.5 the math is
            // ill-defined. Clamp here so a misconfigured caller can't blank the overlay.
            edgeFeather: max(0, min(0.5, edgeFeather))
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(photorealTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
