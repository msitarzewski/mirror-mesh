import Foundation
import MirrorMeshCore

public final class Watermarker: @unchecked Sendable {
    public let signer: FrameSigner
    public let badge: VisibleBadge

    public init(signer: FrameSigner, badge: VisibleBadge) {
        self.signer = signer
        self.badge = badge
    }

    public func watermark(_ frame: RenderedFrame) -> WatermarkedFrame {
        TelemetryBus.emit(.stageStart(stage: .watermark, frame: frame.frameID, hostTimeNs: MirrorMeshCore.hostTimeNs()))
        // Signpost mirrors telemetry so Instruments shows signer + badge cost per frame.
        let sp = Signpost.begin(Signpost.watermark, frame: frame.frameID)
        // Order matters: visible badge first so its pixels are part of the signed digest.
        try? badge.apply(to: frame.pixelBuffer)
        let digest = signer.contentDigest(of: frame)
        let signature = signer.sign(frame, contentDigest: digest)
        TelemetryBus.emit(.stageEnd(stage: .watermark, frame: frame.frameID, hostTimeNs: MirrorMeshCore.hostTimeNs()))
        Signpost.end(Signpost.watermark, frame: frame.frameID, id: sp)
        return WatermarkedFrame(
            frameID: frame.frameID,
            hostTimeNs: frame.hostTimeNs,
            pixelBuffer: frame.pixelBuffer,
            width: frame.width,
            height: frame.height,
            signature: signature,
            contentDigest: digest
        )
    }
}
