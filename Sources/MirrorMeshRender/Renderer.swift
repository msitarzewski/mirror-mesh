import Foundation
import Metal
import CoreVideo
import MirrorMeshCore

public enum RendererError: Error, CustomStringConvertible {
    case poolExhausted
    case textureCreationFailed
    case commandEncodingFailed

    public var description: String {
        switch self {
        case .poolExhausted:           return "Renderer: output pixel-buffer pool exhausted"
        case .textureCreationFailed:   return "Renderer: failed to create Metal texture"
        case .commandEncodingFailed:   return "Renderer: failed to create command buffer/encoder"
        }
    }
}

/// `@unchecked Sendable`: the renderer is designed for single-threaded use from the pipeline's
/// render executor. Metal command-buffer encoding is not Sendable.
public final class Renderer: @unchecked Sendable {
    /// Mirrors `FaceMeshRenderer.Style` so the Renderer's options stay Sendable without leaking
     /// a Metal-bound type to clients that only need to choose a style.
    public enum MeshStyle: Sendable {
        case wireframe
        case filled
    }

    public struct Options: Sendable {
        public var showLandmarks: Bool
        public var showAvatarMask: Bool
        public var showFaceMesh: Bool
        public var meshStyle: MeshStyle
        public var meshColor: SIMD4<Float>
        /// M53: render-level gate. The `AvatarMask` cartoon overlay is a Wireframe-only debug
        /// affordance — Mirror and Mask styles must never composite it, regardless of the
        /// `showAvatarMask` toggle. We carry the style here (rather than coupling the renderer
        /// to `MirrorMeshCore.RenderStyle`) so this module stays a leaf on the dep graph.
        public var isWireframeStyle: Bool
        public init(showLandmarks: Bool = true,
                    showAvatarMask: Bool = false,
                    showFaceMesh: Bool = false,
                    meshStyle: MeshStyle = .wireframe,
                    meshColor: SIMD4<Float> = SIMD4(0.0, 1.0, 0.4, 0.9),
                    isWireframeStyle: Bool = true) {
            self.showLandmarks = showLandmarks
            self.showAvatarMask = showAvatarMask
            self.showFaceMesh = showFaceMesh
            self.meshStyle = meshStyle
            self.meshColor = meshColor
            self.isWireframeStyle = isWireframeStyle
        }
    }

    /// M56: per-frame reenactment payload handed to `render(...)`. Vertices/normals/indices are the
    /// stylized 3D head's deformed mesh; `yaw/pitch/roll` are pose channels in radians; the
    /// optional bounding box anchors the head to where the operator's face appears on screen.
    public struct StylizedHeadPayload: Sendable {
        public var vertices: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        public var indices: [UInt16]
        public var yaw: Float
        public var pitch: Float
        public var roll: Float
        public var landmarkBoundingBoxNorm: CGRect?
        public init(vertices: [SIMD3<Float>],
                    normals: [SIMD3<Float>],
                    indices: [UInt16],
                    yaw: Float,
                    pitch: Float,
                    roll: Float,
                    landmarkBoundingBoxNorm: CGRect?) {
            self.vertices = vertices
            self.normals = normals
            self.indices = indices
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
            self.landmarkBoundingBoxNorm = landmarkBoundingBoxNorm
        }
    }

    public let context: MetalContext
    public let outputWidth: Int
    public let outputHeight: Int
    public var options: Options

    private let pool: PixelBufferPool
    private let passthrough: PassthroughPipeline
    private let landmarkOverlay: LandmarkOverlay
    private let avatarMask: AvatarMask
    public let meshRenderer: FaceMeshRenderer
    public let stylizedHead: StylizedHeadRenderer

    public init(context: MetalContext,
                outputSize: (width: Int, height: Int),
                options: Options = .init()) throws {
        self.context = context
        self.outputWidth = outputSize.width
        self.outputHeight = outputSize.height
        self.options = options
        self.pool = PixelBufferPool(width: outputSize.width, height: outputSize.height)
        self.passthrough = try PassthroughPipeline(context: context)
        self.landmarkOverlay = try LandmarkOverlay(context: context)
        self.avatarMask = try AvatarMask(context: context)
        self.meshRenderer = try FaceMeshRenderer(context: context)
        self.stylizedHead = try StylizedHeadRenderer(context: context)
    }

    public func render(captured: CapturedFrame,
                       landmarks: LandmarkFrame?,
                       blendshapes: BlendshapeFrame?,
                       stylizedHead payload: StylizedHeadPayload? = nil) -> RenderedFrame? {
        TelemetryBus.emit(.stageStart(stage: .render,
                                      frame: captured.frameID,
                                      hostTimeNs: MirrorMeshCore.hostTimeNs()))
        // Signpost mirrors telemetry so Instruments shows GPU/encode cost per frame; defer covers
        // every early-return path below.
        let sp = Signpost.begin(Signpost.render, frame: captured.frameID)
        defer { Signpost.end(Signpost.render, frame: captured.frameID, id: sp) }

        guard let outBuffer = pool.acquire() else {
            TelemetryBus.emit(.error(stage: .render, message: "pool exhausted"))
            return nil
        }
        guard let (cvSource, sourceTexture) =
                context.makeTexture(from: captured.pixelBuffer, usage: [.shaderRead])
        else {
            TelemetryBus.emit(.error(stage: .render, message: "source texture creation failed"))
            return nil
        }
        guard let (cvDest, destTexture) =
                context.makeTexture(from: outBuffer, usage: [.renderTarget])
        else {
            _ = cvSource  // keep alive until source isn't needed
            TelemetryBus.emit(.error(stage: .render, message: "dest texture creation failed"))
            return nil
        }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = destTexture
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = context.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpDesc)
        else {
            _ = cvSource; _ = cvDest
            TelemetryBus.emit(.error(stage: .render, message: "encoder failed"))
            return nil
        }

        passthrough.encode(into: enc, source: sourceTexture)

        if options.showLandmarks, let lm = landmarks, !lm.points.isEmpty {
            landmarkOverlay.encode(into: enc,
                                   landmarks: lm,
                                   viewportWidth: outputWidth,
                                   viewportHeight: outputHeight)
        }

        if options.showFaceMesh, let lm = landmarks, !lm.points.isEmpty {
            let style: FaceMeshRenderer.Style = options.meshStyle == .wireframe ? .wireframe : .filled
            meshRenderer.encode(into: enc,
                                landmarks: lm,
                                style: style,
                                color: options.meshColor,
                                viewportWidth: outputWidth,
                                viewportHeight: outputHeight)
        }

        // M53: enforce Wireframe-only at the render boundary, not just via options plumbing.
        // The cartoon AvatarMask is a debug affordance that previously leaked into Mirror/Mask
        // when options weren't reapplied (e.g., before the first applySettings() tick).
        if options.isWireframeStyle && options.showAvatarMask {
            avatarMask.encode(into: enc, blendshapes: blendshapes)
        }

        // M56: the stylized 3D head composites on top of all other layers. Empty payload is a
        // no-op (no identity loaded). The renderer is the only layer that touches the stylized
        // head's Metal pipeline — MirrorMeshReenact stays free of Metal imports.
        if let payload = payload {
            do {
                try stylizedHead.encode(
                    into: enc,
                    vertices: payload.vertices,
                    normals: payload.normals,
                    indices: payload.indices,
                    pose: StylizedHeadRenderer.Pose(yaw: payload.yaw, pitch: payload.pitch, roll: payload.roll),
                    landmarkBoundingBox: payload.landmarkBoundingBoxNorm,
                    viewportWidth: outputWidth,
                    viewportHeight: outputHeight
                )
            } catch {
                TelemetryBus.emit(.warning(stage: .render, message: "stylized head encode failed: \(error)"))
            }
        }

        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // Keep CVMetalTexture handles alive through GPU completion.
        _ = cvSource
        _ = cvDest

        TelemetryBus.emit(.stageEnd(stage: .render,
                                    frame: captured.frameID,
                                    hostTimeNs: MirrorMeshCore.hostTimeNs()))

        return RenderedFrame(
            frameID: captured.frameID,
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            pixelBuffer: outBuffer,
            width: outputWidth,
            height: outputHeight
        )
    }
}
