import Foundation
import MirrorMeshCore

/// Captures a neutral (resting-face) pose by exponentially averaging the first ~N frames.
///
/// Once `frameTarget` frames have been observed, the calibrator is considered locked and
/// further `observe` calls are no-ops until `reset()`. The solver feeds every frame through
/// here; coefficients are computed as deltas from this baseline.
public final class NeutralPoseCalibrator: @unchecked Sendable {
    /// Number of frames to average before the neutral pose is considered stable.
    public let frameTarget: Int

    /// Per-point exponential blend factor. A smaller alpha gives a smoother baseline; 0.1
    /// converges in ~30 frames which matches `frameTarget`'s default.
    public let alpha: Float

    private var averaged: [LandmarkPoint] = []
    private var observed: Int = 0

    public init(frameTarget: Int = 30, alpha: Float = 0.1) {
        self.frameTarget = frameTarget
        self.alpha = alpha
    }

    public var isCalibrated: Bool { observed >= frameTarget && !averaged.isEmpty }

    public func observe(_ landmarks: LandmarkFrame) {
        guard !isCalibrated else { return }
        let pts = landmarks.points
        if averaged.isEmpty {
            averaged = pts
        } else if averaged.count == pts.count {
            for i in 0..<pts.count {
                let nx = averaged[i].x * (1 - alpha) + pts[i].x * alpha
                let ny = averaged[i].y * (1 - alpha) + pts[i].y * alpha
                averaged[i] = LandmarkPoint(x: nx, y: ny)
            }
        } else {
            // Landmark count changed (e.g. extractor swap). Restart from this frame.
            averaged = pts
            observed = 0
        }
        observed += 1
    }

    public func neutralPoints() -> [LandmarkPoint]? {
        averaged.isEmpty ? nil : averaged
    }

    public func reset() {
        averaged.removeAll(keepingCapacity: true)
        observed = 0
    }
}
