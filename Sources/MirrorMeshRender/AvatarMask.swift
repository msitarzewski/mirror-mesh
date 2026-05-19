import Foundation
import CoreGraphics
import Metal
import simd
import MirrorMeshCore

public enum AvatarMaskError: Error {
    case missingFunction(String)
    case pipelineCreationFailed(String)
}

/// Cartoon-face overlay positioned in the upper-right of the output frame. The face is composed
/// in the fragment shader from analytic primitives; per-frame state comes from blendshapes.
public final class AvatarMask {
    public struct Placement {
        /// Normalized rect in output image space (origin top-left, [0,1]).
        public var rectNorm: CGRect
        public init(rectNorm: CGRect = CGRect(x: 0.72, y: 0.03, width: 0.25, height: 0.30)) {
            self.rectNorm = rectNorm
        }
    }

    private struct AvatarUniforms {
        var rectOriginClip: SIMD2<Float>
        var rectSizeClip: SIMD2<Float>
        var jawOpen: Float
        var browInnerUp: Float
        var browDownLeft: Float
        var browDownRight: Float
        var eyeBlinkLeft: Float
        var eyeBlinkRight: Float
        var mouthSmileLeft: Float
        var mouthSmileRight: Float
    }

    public let pipelineState: MTLRenderPipelineState
    public var placement: Placement

    public init(context: MetalContext, placement: Placement = .init()) throws {
        guard let vfn = context.library.makeFunction(name: "avatar_vertex") else {
            throw AvatarMaskError.missingFunction("avatar_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "avatar_fragment") else {
            throw AvatarMaskError.missingFunction("avatar_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try context.device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw AvatarMaskError.pipelineCreationFailed(String(describing: error))
        }
        self.placement = placement
    }

    /// Display-side amplification so the cartoon mask reacts visibly to subtle expressions
    /// from the geometric solver. Will be reduced to 1.0 once M34 (CoreML weights) replaces
    /// the geometric path with model-driven coefficients that are already well-scaled.
    public var responsivenessGain: Float = 2.2

    public func encode(into encoder: MTLRenderCommandEncoder, blendshapes: BlendshapeFrame?) {
        // Convert top-left normalized rect to clip-space rect (-1..1, +y up).
        let r = placement.rectNorm
        let originXClip = Float(r.minX) * 2.0 - 1.0
        let topYClip    = 1.0 - Float(r.minY) * 2.0
        let widthClip   = Float(r.width) * 2.0
        let heightClip  = Float(r.height) * 2.0
        let bottomYClip = topYClip - heightClip

        let c = blendshapes
        let g = responsivenessGain
        // Amplify each coefficient, clamping to [0, 1] so the shader doesn't see >1 inputs.
        let amp = { (v: Float) -> Float in min(1, max(0, v * g)) }
        var uniforms = AvatarUniforms(
            rectOriginClip: SIMD2(originXClip, bottomYClip),
            rectSizeClip:   SIMD2(widthClip, heightClip),
            jawOpen:        amp(c?.coefficient(.jawOpen) ?? 0),
            browInnerUp:    amp(c?.coefficient(.browInnerUp) ?? 0),
            browDownLeft:   amp(c?.coefficient(.browDownLeft) ?? 0),
            browDownRight:  amp(c?.coefficient(.browDownRight) ?? 0),
            eyeBlinkLeft:   amp(c?.coefficient(.eyeBlinkLeft) ?? 0),
            eyeBlinkRight:  amp(c?.coefficient(.eyeBlinkRight) ?? 0),
            mouthSmileLeft: amp(c?.coefficient(.mouthSmileLeft) ?? 0),
            mouthSmileRight: amp(c?.coefficient(.mouthSmileRight) ?? 0)
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AvatarUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AvatarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
