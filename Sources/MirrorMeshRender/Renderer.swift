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
    public struct Options: Sendable {
        public var showLandmarks: Bool
        public var showAvatarMask: Bool
        public init(showLandmarks: Bool = true, showAvatarMask: Bool = true) {
            self.showLandmarks = showLandmarks
            self.showAvatarMask = showAvatarMask
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
    }

    public func render(captured: CapturedFrame,
                       landmarks: LandmarkFrame?,
                       blendshapes: BlendshapeFrame?) -> RenderedFrame? {
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

        if options.showAvatarMask {
            avatarMask.encode(into: enc, blendshapes: blendshapes)
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
