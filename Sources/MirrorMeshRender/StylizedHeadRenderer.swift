import Foundation
import Metal
import simd
import MirrorMeshCore

public enum StylizedHeadRendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
    case mismatchedBuffers(String)

    public var description: String {
        switch self {
        case .missingFunction(let n):       return "StylizedHeadRenderer: missing Metal function '\(n)'"
        case .pipelineCreationFailed(let s): return "StylizedHeadRenderer: pipeline creation failed (\(s))"
        case .bufferAllocationFailed:        return "StylizedHeadRenderer: Metal buffer allocation failed"
        case .mismatchedBuffers(let s):      return "StylizedHeadRenderer: \(s)"
        }
    }
}

/// Renders the rigged stylized head produced by `MirrorMeshReenact`. Stays in MirrorMeshRender
/// so it can share the project's MetalContext + shader-bundle conventions (R14). To avoid a
/// backward dependency from MirrorMeshRender → MirrorMeshReenact, this renderer's `draw` API
/// takes raw vertex/normal/index arrays; the orchestrator (Pipeline) bridges the `ReenactFrame`
/// value type into these parameters.
public final class StylizedHeadRenderer {
    public enum Style: Sendable {
        case filled
        case wireframe
        case filledWithWireframe
    }

    /// Visual tuning knobs. Sendable so the SwiftUI Settings panel can hold a copy.
    public struct Options: Sendable {
        public var tintHighlight: SIMD4<Float>
        public var tintShadow: SIMD4<Float>
        public var rimColor: SIMD4<Float>      // .a = strength
        public var rimPower: Float
        public var lightDir: SIMD3<Float>      // toward-the-light unit vector
        public var style: Style
        public var wireframeAmount: Float      // 0..1 for `filledWithWireframe`
        public var outlineFeatherPx: Float
        /// Scale of the head in world units. The base mesh extends roughly +/- 1 along x,
        /// so a scale of `0.5` makes the head fill roughly half the vertical viewport.
        public var headScale: Float
        /// Vertical offset for the head's world position. Positive moves the head up.
        public var headYOffset: Float

        public init(
            tintHighlight: SIMD4<Float> = SIMD4(1.00, 0.78, 0.62, 1.0),  // warm peach
            tintShadow: SIMD4<Float>    = SIMD4(0.32, 0.30, 0.55, 1.0),  // cool indigo
            rimColor: SIMD4<Float>      = SIMD4(0.40, 0.90, 1.00, 0.75), // cyan rim
            rimPower: Float = 2.6,
            lightDir: SIMD3<Float> = simd_normalize(SIMD3(-0.35, 0.65, 0.65)),
            style: Style = .filledWithWireframe,
            wireframeAmount: Float = 0.35,
            outlineFeatherPx: Float = 1.5,
            headScale: Float = 0.55,
            headYOffset: Float = 0.0
        ) {
            self.tintHighlight = tintHighlight
            self.tintShadow = tintShadow
            self.rimColor = rimColor
            self.rimPower = rimPower
            self.lightDir = lightDir
            self.style = style
            self.wireframeAmount = wireframeAmount
            self.outlineFeatherPx = outlineFeatherPx
            self.headScale = headScale
            self.headYOffset = headYOffset
        }
    }

    /// Pose channels resolved by the LandmarkSolver. Optional — when nil the head sits at
    /// rest pose (no yaw/pitch/roll). All values are in radians except eyeLook* which are
    /// `[-1, 1]` and unused at the moment (no eye geometry in v0.6).
    public struct Pose: Sendable {
        public var yaw: Float
        public var pitch: Float
        public var roll: Float
        public init(yaw: Float = 0, pitch: Float = 0, roll: Float = 0) {
            self.yaw = yaw; self.pitch = pitch; self.roll = roll
        }
    }

    /// Uniforms MUST byte-for-byte match `StylizedHeadUniforms` in StylizedHead.metal.
    private struct Uniforms {
        var modelMatrix: simd_float4x4
        var projectionMatrix: simd_float4x4
        var tintHighlight: SIMD4<Float>
        var tintShadow: SIMD4<Float>
        var rimColor: SIMD4<Float>
        var lightDir: SIMD3<Float>
        var rimPower: Float
        var wireframeAmount: Float
        var outlineFeatherPx: Float
        var viewportWidth: Float
        var viewportHeight: Float
        var style: UInt32
    }

    public let pipelineState: MTLRenderPipelineState
    public var options: Options

    private let device: MTLDevice
    private var positionBuffer: MTLBuffer
    private var normalBuffer: MTLBuffer
    private var positionCapacity: Int
    private var normalCapacity: Int

    public init(context: MetalContext, options: Options = .init()) throws {
        guard let vfn = context.library.makeFunction(name: "stylized_head_vertex") else {
            throw StylizedHeadRendererError.missingFunction("stylized_head_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "stylized_head_fragment") else {
            throw StylizedHeadRendererError.missingFunction("stylized_head_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Additive alpha so we composite over the camera passthrough without overwriting it.
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
            throw StylizedHeadRendererError.pipelineCreationFailed(String(describing: error))
        }
        self.device = context.device
        self.options = options

        // Initial capacity = generous default (one StylizedHeadModel = ~290 verts, max expanded
        // index list ≈ 290 * 6 = 1740). Buffer grows on demand.
        let initialCap = 2048
        guard let pBuf = device.makeBuffer(
            length: initialCap * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ) else { throw StylizedHeadRendererError.bufferAllocationFailed }
        guard let nBuf = device.makeBuffer(
            length: initialCap * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ) else { throw StylizedHeadRendererError.bufferAllocationFailed }
        self.positionBuffer = pBuf
        self.normalBuffer = nBuf
        self.positionCapacity = initialCap
        self.normalCapacity = initialCap
    }

    /// Encode a draw of the stylized head against `vertices` (deformed positions), `normals`
    /// (recomputed for those positions), and `indices` (triangle list into `vertices`). The
    /// renderer expands the indexed mesh into a non-indexed vertex stream on the CPU so the
    /// shader can derive barycentric coords from `vid % 3` (same trick FaceMesh.metal uses).
    ///
    /// `pose` and `landmarkBoundingBox` together place the head in world space:
    /// - `pose` rotates the head (yaw/pitch/roll in radians)
    /// - `landmarkBoundingBox` (normalized image-space [0,1]) anchors the head's projected
    ///   center; when nil the head sits at world (0, headYOffset, 0)
    ///
    /// **Pass-through**: if `vertices.isEmpty` the call is a no-op (the orchestrator hands us
    /// an empty mesh when no identity is loaded).
    public func encode(
        into encoder: MTLRenderCommandEncoder,
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt16],
        pose: Pose,
        landmarkBoundingBox: CGRect?,
        viewportWidth: Int,
        viewportHeight: Int
    ) throws {
        guard !vertices.isEmpty, !indices.isEmpty else { return }
        guard vertices.count == normals.count else {
            throw StylizedHeadRendererError.mismatchedBuffers(
                "vertices(\(vertices.count)) != normals(\(normals.count))"
            )
        }

        // Expand the indexed mesh into a non-indexed stream. One MTLBuffer hop, no per-frame
        // allocation churn — we grow the buffers if they're too small, never shrink.
        let expandedCount = indices.count
        try ensureCapacity(expandedCount)

        let posPtr = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: expandedCount)
        let nrmPtr = normalBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: expandedCount)
        for i in 0..<expandedCount {
            let vid = Int(indices[i])
            posPtr[i] = vertices[vid]
            nrmPtr[i] = normals[vid]
        }

        // Build the model matrix. Pose first, then translate to bounding-box center, then
        // scale to a head-sized world unit.
        let s = options.headScale
        let scaleM = simd_float4x4(diagonal: SIMD4(s, s, s, 1))
        let yawM = rotationY(pose.yaw)
        let pitchM = rotationX(pose.pitch)
        let rollM = rotationZ(pose.roll)
        var translateM = matrix_identity_float4x4
        // Default placement: world center, with vertical offset.
        var worldCenter = SIMD3<Float>(0, options.headYOffset, 0)
        if let bbox = landmarkBoundingBox {
            // Map the bbox center from normalized image-space (origin top-left, +y down) to
            // our world space (origin center, +y up). Width and height are 2 units (NDC).
            let cx = Float(bbox.midX)
            let cy = Float(bbox.midY)
            worldCenter.x = (cx * 2.0 - 1.0)
            worldCenter.y = -(cy * 2.0 - 1.0) + options.headYOffset
        }
        translateM.columns.3 = SIMD4(worldCenter.x, worldCenter.y, worldCenter.z, 1)
        let model = translateM * scaleM * yawM * pitchM * rollM

        // Orthographic projection sized to fit the [-1,1] NDC envelope, with a slight aspect
        // correction so the head doesn't squish on wide viewports.
        let aspect = max(Float(viewportWidth) / max(Float(viewportHeight), 1), 1e-3)
        let projection = orthographic(left: -aspect, right: aspect,
                                       bottom: -1, top: 1,
                                       near: -2, far: 2)

        var uniforms = Uniforms(
            modelMatrix: model,
            projectionMatrix: projection,
            tintHighlight: options.tintHighlight,
            tintShadow: options.tintShadow,
            rimColor: options.rimColor,
            lightDir: options.lightDir,
            rimPower: options.rimPower,
            wireframeAmount: options.wireframeAmount,
            outlineFeatherPx: options.outlineFeatherPx,
            viewportWidth: Float(viewportWidth),
            viewportHeight: Float(viewportHeight),
            style: styleCode(options.style)
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(normalBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: expandedCount)
    }

    // MARK: - Internals

    private func ensureCapacity(_ count: Int) throws {
        if count > positionCapacity {
            let newCap = max(count, positionCapacity * 2)
            guard let pBuf = device.makeBuffer(
                length: newCap * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            ) else { throw StylizedHeadRendererError.bufferAllocationFailed }
            self.positionBuffer = pBuf
            self.positionCapacity = newCap
        }
        if count > normalCapacity {
            let newCap = max(count, normalCapacity * 2)
            guard let nBuf = device.makeBuffer(
                length: newCap * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            ) else { throw StylizedHeadRendererError.bufferAllocationFailed }
            self.normalBuffer = nBuf
            self.normalCapacity = newCap
        }
    }

    private func styleCode(_ s: Style) -> UInt32 {
        switch s {
        case .filled:                return 0
        case .wireframe:             return 1
        case .filledWithWireframe:   return 2
        }
    }
}

// MARK: - Tiny matrix helpers (kept local — Renderer.swift doesn't need them yet)

private func rotationX(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(1, 0,  0, 0),
        SIMD4(0, c, -s, 0),
        SIMD4(0, s,  c, 0),
        SIMD4(0, 0,  0, 1),
    ])
}

private func rotationY(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4( c, 0, s, 0),
        SIMD4( 0, 1, 0, 0),
        SIMD4(-s, 0, c, 0),
        SIMD4( 0, 0, 0, 1),
    ])
}

private func rotationZ(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(c, -s, 0, 0),
        SIMD4(s,  c, 0, 0),
        SIMD4(0,  0, 1, 0),
        SIMD4(0,  0, 0, 1),
    ])
}

private func orthographic(
    left: Float, right: Float,
    bottom: Float, top: Float,
    near: Float, far: Float
) -> simd_float4x4 {
    let rl = max(right - left, 1e-6)
    let tb = max(top - bottom, 1e-6)
    let fn = max(far - near, 1e-6)
    return simd_float4x4(rows: [
        SIMD4(2 / rl, 0, 0, -(right + left) / rl),
        SIMD4(0, 2 / tb, 0, -(top + bottom) / tb),
        SIMD4(0, 0, -2 / fn, -(far + near) / fn),
        SIMD4(0, 0, 0, 1),
    ])
}
