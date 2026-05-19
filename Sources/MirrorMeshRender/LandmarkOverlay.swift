import Foundation
import Metal
import simd
import MirrorMeshCore

public enum LandmarkOverlayError: Error {
    case missingFunction(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
}

/// Instanced sprite cloud for landmark points. Each point is a small antialiased disc drawn
/// directly in clip space. Geometry is a single 4-vertex triangle-strip; per-instance UV in
/// normalized image space comes from `LandmarkFrame.points`.
public final class LandmarkOverlay {
    public struct Style {
        public var color: SIMD4<Float>
        public var pointRadiusPx: Float
        public init(color: SIMD4<Float> = SIMD4(0.20, 1.00, 0.55, 0.95),
                    pointRadiusPx: Float = 3.0) {
            self.color = color
            self.pointRadiusPx = pointRadiusPx
        }
    }

    private struct LandmarkInstance { var uv: SIMD2<Float> }
    private struct LandmarkUniforms {
        var pointRadiusPx: Float
        var viewportWidth: Float
        var viewportHeight: Float
        var _pad: Float
        var color: SIMD4<Float>
    }

    public let pipelineState: MTLRenderPipelineState
    public var style: Style

    private let device: MTLDevice
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    public init(context: MetalContext,
                style: Style = .init(),
                initialCapacity: Int = 128) throws {
        guard let vfn = context.library.makeFunction(name: "landmark_vertex") else {
            throw LandmarkOverlayError.missingFunction("landmark_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "landmark_fragment") else {
            throw LandmarkOverlayError.missingFunction("landmark_fragment")
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
            throw LandmarkOverlayError.pipelineCreationFailed(String(describing: error))
        }
        self.device = context.device
        self.style = style
        let cap = max(initialCapacity, 1)
        guard let buf = context.device.makeBuffer(
            length: cap * MemoryLayout<LandmarkInstance>.stride,
            options: .storageModeShared)
        else { throw LandmarkOverlayError.bufferAllocationFailed }
        self.instanceBuffer = buf
        self.instanceCapacity = cap
    }

    private func ensureCapacity(_ n: Int) {
        guard n > instanceCapacity else { return }
        var newCap = instanceCapacity
        while newCap < n { newCap *= 2 }
        if let buf = device.makeBuffer(
            length: newCap * MemoryLayout<LandmarkInstance>.stride,
            options: .storageModeShared) {
            instanceBuffer = buf
            instanceCapacity = newCap
        }
    }

    public func encode(into encoder: MTLRenderCommandEncoder,
                       landmarks: LandmarkFrame,
                       viewportWidth: Int,
                       viewportHeight: Int) {
        let count = landmarks.points.count
        guard count > 0 else { return }
        ensureCapacity(count)

        let ptr = instanceBuffer.contents().bindMemory(to: LandmarkInstance.self, capacity: count)
        for i in 0..<count {
            let p = landmarks.points[i]
            ptr[i] = LandmarkInstance(uv: SIMD2(p.x, p.y))
        }

        var uniforms = LandmarkUniforms(
            pointRadiusPx: style.pointRadiusPx,
            viewportWidth: Float(viewportWidth),
            viewportHeight: Float(viewportHeight),
            _pad: 0,
            color: style.color
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LandmarkUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: count)
    }
}
