import Foundation
import MirrorMeshCore

public final class Watermarker: @unchecked Sendable {
    public let signer: FrameSigner
    public let badge: VisibleBadge

    /// Whether the visible badge is composited onto each frame. Cryptographic signing always
    /// runs regardless — toggling this only affects the *visible* disclosure. Release builds
    /// pin this to true via UI (`AppSettings.watermarkLockedInRelease`); the runtime check is
    /// debug-only so engineering can A/B without recompiling.
    private let lock = NSLock()
    private var _visible: Bool = true
    public var visible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _visible }
        set {
            #if DEBUG
            lock.lock(); _visible = newValue; lock.unlock()
            #else
            // Release: ignore; watermark stays visible per projectRules R2.
            _ = newValue
            #endif
        }
    }

    public init(signer: FrameSigner, badge: VisibleBadge) {
        self.signer = signer
        self.badge = badge
    }

    public func watermark(_ frame: RenderedFrame) -> WatermarkedFrame {
        TelemetryBus.emit(.stageStart(stage: .watermark, frame: frame.frameID, hostTimeNs: MirrorMeshCore.hostTimeNs()))
        let sp = Signpost.begin(Signpost.watermark, frame: frame.frameID)
        // Order matters: visible badge first so its pixels are part of the signed digest.
        // Signing always runs — only the visible composite is gated.
        if visible {
            try? badge.apply(to: frame.pixelBuffer)
        }
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
