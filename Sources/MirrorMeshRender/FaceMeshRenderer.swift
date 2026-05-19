import Foundation
import Metal
import simd
import MirrorMeshCore

public enum FaceMeshRendererError: Error {
    case missingFunction(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
}

/// Triangulated face mesh built from the 76-point landmark cloud. The vertex buffer is
/// rebuilt per frame from `LandmarkFrame.points`; the index buffer is built once from
/// `MeshTopology.indices`.
public final class FaceMeshRenderer {
    public enum Style: Sendable {
        case wireframe
        case filled
    }

    /// Uniform layout MUST match `FaceMeshUniforms` in FaceMesh.metal.
    private struct Uniforms {
        var color: SIMD4<Float>
        var style: UInt32
        var edgeThicknessPx: Float
        var viewportWidth: Float
        var viewportHeight: Float
    }

    public let pipelineState: MTLRenderPipelineState

    private let device: MTLDevice
    private let landmarkBuffer: MTLBuffer    // 76 × float2
    private let expandedIndexBuffer: MTLBuffer  // one ushort per emitted vertex
    private let vertexCount: Int
    private let expectedLandmarkCount = 76

    public init(context: MetalContext) throws {
        guard let vfn = context.library.makeFunction(name: "face_mesh_vertex") else {
            throw FaceMeshRendererError.missingFunction("face_mesh_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "face_mesh_fragment") else {
            throw FaceMeshRendererError.missingFunction("face_mesh_fragment")
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
            throw FaceMeshRendererError.pipelineCreationFailed(String(describing: error))
        }
        self.device = context.device

        // Why a non-indexed expanded stream: per-vertex barycentric coords are derived from
        // `vertex_id % 3` in the shader, which only works when the vertex stream lists each
        // triangle's three corners consecutively. The topology indices remap to landmark
        // positions inside the vertex shader via a second buffer.
        let topo = MeshTopology.indices
        guard let lmBuf = context.device.makeBuffer(
            length: 76 * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ) else { throw FaceMeshRendererError.bufferAllocationFailed }
        self.landmarkBuffer = lmBuf

        guard let idxBuf = context.device.makeBuffer(
            bytes: topo,
            length: topo.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ) else { throw FaceMeshRendererError.bufferAllocationFailed }
        self.expandedIndexBuffer = idxBuf
        self.vertexCount = topo.count
    }

    /// Encode the mesh pass. Caller must have set the render pass / viewport already.
    /// `landmarks` may be nil — the encode becomes a no-op so callers don't need to branch.
    public func encode(into encoder: MTLRenderCommandEncoder,
                       landmarks: LandmarkFrame?,
                       style: Style,
                       color: SIMD4<Float>,
                       viewportWidth: Int,
                       viewportHeight: Int,
                       edgeThicknessPx: Float = 1.25) {
        guard let lm = landmarks, lm.points.count == expectedLandmarkCount else { return }
        guard vertexCount > 0 else { return }

        // Upload current frame's landmark positions (normalized image space).
        let ptr = landmarkBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: expectedLandmarkCount)
        for i in 0..<expectedLandmarkCount {
            let p = lm.points[i]
            ptr[i] = SIMD2(p.x, p.y)
        }

        var uniforms = Uniforms(
            color: color,
            style: style == .wireframe ? 0 : 1,
            edgeThicknessPx: edgeThicknessPx,
            viewportWidth: Float(viewportWidth),
            viewportHeight: Float(viewportHeight)
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(landmarkBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(expandedIndexBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}
