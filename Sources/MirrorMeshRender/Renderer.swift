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
    /// v1.1 photoreal composite: draws the photoreal generator output as a feathered quad
    /// over the live passthrough at the face bbox each frame. Replaces the v1.0 full-buffer
    /// substitution path that was aspect-stretching a 256x256 square to the full viewport.
    public let photorealOverlay: PhotorealOverlay

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
        self.photorealOverlay = try PhotorealOverlay(context: context)
    }

    /// Per-frame photoreal composite input handed to `render(...)`. When non-nil, the renderer
    /// wraps `pixelBuffer` as a Metal texture and composites it as a feathered quad at
    /// `bboxNorm` (Vision normalized image-space, origin top-left) over the camera passthrough.
    /// The stylized 3D head payload should be omitted by the caller for the same frame —
    /// composing a procedural head on top of a photoreal face would double the head.
    public struct PhotorealComposite {
        public var pixelBuffer: CVPixelBuffer
        public var bboxNorm: CGRect
        public init(pixelBuffer: CVPixelBuffer, bboxNorm: CGRect) {
            self.pixelBuffer = pixelBuffer
            self.bboxNorm = bboxNorm
        }
    }

    public func render(captured: CapturedFrame,
                       landmarks: LandmarkFrame?,
                       blendshapes: BlendshapeFrame?,
                       stylizedHead payload: StylizedHeadPayload? = nil,
                       photoreal photorealComposite: PhotorealComposite? = nil) -> RenderedFrame? {
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

        // v1.1: photoreal face composite. Sits BETWEEN the camera passthrough (background +
        // hair + neck + shoulders stay visible from the live frame) and the landmark / mesh /
        // stylized layers (which still draw on top, anchored to the original capture's
        // landmark coords). The bbox is the same one Vision reported for this frame, so the
        // photoreal face lands exactly where the operator's face actually is.
        //
        // Kept alive across GPU completion via the `cvPhotoreal` slot below — the
        // `CVMetalTexture` wrapper must outlive the command buffer's commit.
        var cvPhotoreal: CVMetalTexture?
        if let composite = photorealComposite,
           let (cv, tex) = context.makeTexture(from: composite.pixelBuffer, usage: [.shaderRead]) {
            cvPhotoreal = cv
            photorealOverlay.encode(
                into: enc,
                photorealTexture: tex,
                bboxNorm: composite.bboxNorm,
                viewportWidth: outputWidth,
                viewportHeight: outputHeight
            )
        }

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
        //
        // v1.3 lip-sync-over-photoreal: when a photoreal composite is active AND a stylized
        // payload is present, we KEEP rendering the stylized head — but at the same compact
        // "ghost preview" scale Wireframe uses (0.18). This keeps the audio-driven mouth
        // motion (which deforms the procedural mesh via `frame.overlayLipSync`) visible as
        // a small puppet cue floating over the photoreal face, since LP's own mouth tracking
        // is approximate. The full-size head substitute is suppressed (doubling up faces
        // would look broken); the small ghost is unambiguously an overlay, not the face.
        if let payload = payload {
            // Style-dependent sizing. `headScale` is NDC-relative (the projection maps to the
            // [-1, 1] envelope), not bbox-relative — so a value of 1.0 fills the entire viewport
            // height. Calibrated for typical webcam framing (face ≈ 30-40% of frame):
            //   Wireframe — tiny ghost preview that coexists with the operator's face + landmarks
            //   Mirror    — head matches face size to act as a translucent replacement
            //   Mask      — head slightly larger than face for hero presentation
            //   Photoreal active — small ghost overlay that surfaces audio-driven mouth motion
            //                      on top of the photoreal face (regardless of style)
            let photorealActive = photorealComposite != nil
            if photorealActive {
                stylizedHead.options.headScale = 0.18
            } else {
                stylizedHead.options.headScale = options.isWireframeStyle ? 0.18 : 0.42
            }
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
        _ = cvPhotoreal

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
