import Foundation
import CoreVideo
import MirrorMeshCore

/// Produces a deterministic, animated landmark set for headless benchmarks where Vision
/// can't find a face in synthetic frames. Mimics the geometry of `SyntheticFrameSource`.
public final class SyntheticLandmarkExtractor: LandmarkBackend, @unchecked Sendable {
    private var frameIndex: UInt64 = 0

    public init() {}

    /// `LandmarkBackend` returns optional; the synthetic backend never fails to produce a face,
    /// so this always returns non-nil.
    public func extract(from frame: CapturedFrame) -> LandmarkFrame? {
        return extractAlways(from: frame)
    }

    /// Non-optional variant retained for callers that want to keep the older contract.
    public func extractAlways(from frame: CapturedFrame) -> LandmarkFrame {
        let start = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.stageStart(stage: .vision, frame: frame.frameID, hostTimeNs: start))
        defer {
            let end = MirrorMeshCore.hostTimeNs()
            TelemetryBus.emit(.stageEnd(stage: .vision, frame: frame.frameID, hostTimeNs: end))
        }

        let t = Double(frameIndex) * 0.05
        frameIndex &+= 1

        // Normalized [0,1] image space, origin top-left.
        let cx: Float = 0.5
        let cy: Float = 0.5
        let s: Float = 0.25

        let eyeY = cy - s / 3 + Float(sin(t) * 0.005)
        let mouthOpen = Float(0.6 + 0.4 * sin(t * 1.3)) * (s / 6)

        var pts: [LandmarkPoint] = []
        // 0..15: face outline (rough oval)
        for i in 0..<16 {
            let theta = (Double(i) / 15.0) * .pi - .pi / 2
            let x = cx + Float(cos(theta)) * (s * 0.9)
            let y = cy + Float(sin(theta)) * (s * 1.1)
            pts.append(LandmarkPoint(x: x, y: y))
        }
        // 16..31: left eye cluster (8 around center)
        let leftEye = (cx - s / 3, eyeY)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts.append(LandmarkPoint(
                x: leftEye.0 + Float(cos(theta)) * s / 14,
                y: leftEye.1 + Float(sin(theta)) * s / 18
            ))
        }
        // 32..47: right eye
        let rightEye = (cx + s / 3, eyeY)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts.append(LandmarkPoint(
                x: rightEye.0 + Float(cos(theta)) * s / 14,
                y: rightEye.1 + Float(sin(theta)) * s / 18
            ))
        }
        // 32..39: nose (8 points)
        for i in 0..<8 {
            pts.append(LandmarkPoint(x: cx + Float(i - 4) * s / 80, y: cy + Float(i) * s / 80))
        }
        // 40..55: mouth outer ring (16 points, animated)
        for i in 0..<16 {
            let theta = Double(i) / 15.0 * 2 * .pi
            pts.append(LandmarkPoint(
                x: cx + Float(cos(theta)) * s / 3,
                y: cy + s / 3 + Float(sin(theta)) * mouthOpen
            ))
        }
        // 56..63: chin / jawline (8 points)
        for i in 0..<8 {
            let theta = (Double(i) / 7.0) * .pi  // half-circle along bottom
            pts.append(LandmarkPoint(
                x: cx + Float(cos(theta + .pi)) * s * 0.8,
                y: cy + s * 0.5 + Float(sin(theta + .pi)) * s * 0.2
            ))
        }
        // 64..75: brows + inner mouth detail (12 points)
        // Left brow (4 points)
        for i in 0..<4 {
            let offset = Float(i) * 0.04
            pts.append(LandmarkPoint(x: cx - s / 3 + offset - 0.06, y: eyeY - s / 6))
        }
        // Right brow (4 points)
        for i in 0..<4 {
            let offset = Float(i) * 0.04
            pts.append(LandmarkPoint(x: cx + s / 3 + offset - 0.06, y: eyeY - s / 6))
        }
        // Inner mouth / tongue placeholders (4 points)
        for i in 0..<4 {
            pts.append(LandmarkPoint(x: cx, y: cy + s / 3 + Float(i) * s / 80))
        }

        return LandmarkFrame(
            frameID: frame.frameID,
            hostTimeNs: frame.hostTimeNs,
            points: pts,
            confidence: 0.99,
            faceBoundingBoxNorm: CGRect(x: 0.25, y: 0.18, width: 0.5, height: 0.64)
        )
    }
}
