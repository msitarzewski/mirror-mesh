import Foundation
import Metal

public enum PassthroughPipelineError: Error {
    case missingFunction(String)
    case pipelineCreationFailed(String)
}

/// Full-screen textured-quad blit. Source is sampled at clamp-to-edge; output format is BGRA8Unorm.
public final class PassthroughPipeline {
    public let pipelineState: MTLRenderPipelineState
    public let pixelFormat: MTLPixelFormat = .bgra8Unorm

    public init(context: MetalContext) throws {
        guard let vfn = context.library.makeFunction(name: "passthrough_vertex") else {
            throw PassthroughPipelineError.missingFunction("passthrough_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "passthrough_fragment") else {
            throw PassthroughPipelineError.missingFunction("passthrough_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipelineState = try context.device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw PassthroughPipelineError.pipelineCreationFailed(String(describing: error))
        }
    }

    /// Encodes a 4-vertex triangle-strip draw sampling `source` into the bound color attachment.
    public func encode(into encoder: MTLRenderCommandEncoder, source: MTLTexture) {
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
