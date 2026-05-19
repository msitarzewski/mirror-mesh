import Foundation
import MirrorMeshCore

/// Converts 2D landmark deltas (vs the neutral pose) into ARKit-52 blendshape coefficients.
///
/// All coefficients are clamped to [0, 1]. Coefficients that cannot be inferred from monocular
/// 2D landmarks (e.g. `tongueOut`, `eyeLookIn/Out`, depth-dependent rolls) are emitted as zero
/// rather than fabricated.
///
/// Telemetry: emits `.stageStart` / `.stageEnd` for `StageID.solver` around every `solve(_:)`.
public final class GeometricSolver: ExpressionSolver, @unchecked Sendable {
    private let calibrator: NeutralPoseCalibrator
    private var smoother: BlendshapeSmoother

    /// Dead-band applied to every coefficient prior to scaling. Suppresses noise from
    /// sub-pixel landmark jitter when the face is at rest.
    public var hysteresis: Float = 0.02

    public init(calibrationFrames: Int = 30,
                neutralAlpha: Float = 0.1,
                smoothingAlpha: Float = 0.5) {
        self.calibrator = NeutralPoseCalibrator(frameTarget: calibrationFrames, alpha: neutralAlpha)
        self.smoother = BlendshapeSmoother(alpha: smoothingAlpha)
    }

    public var isCalibrated: Bool { calibrator.isCalibrated }

    public func resetCalibration() {
        calibrator.reset()
        smoother.reset()
    }

    public func solve(_ landmarks: LandmarkFrame) -> BlendshapeFrame {
        let start = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.stageStart(stage: .solver, frame: landmarks.frameID, hostTimeNs: start))
        // Signpost mirrors telemetry so Instruments shows solver math cost per frame.
        let sp = Signpost.begin(Signpost.solver, frame: landmarks.frameID)
        defer {
            let end = MirrorMeshCore.hostTimeNs()
            TelemetryBus.emit(.stageEnd(stage: .solver, frame: landmarks.frameID, hostTimeNs: end))
            Signpost.end(Signpost.solver, frame: landmarks.frameID, id: sp)
        }

        calibrator.observe(landmarks)

        // During calibration we emit an all-zero frame so downstream stages see a stable
        // schema from frame one without acting on un-calibrated noise.
        guard let neutral = calibrator.neutralPoints(), neutral.count == landmarks.points.count else {
            return BlendshapeFrame(
                frameID: landmarks.frameID,
                hostTimeNs: landmarks.hostTimeNs,
                coefficients: zeroCoefficients()
            )
        }

        let raw = computeCoefficients(
            current: landmarks.points,
            neutral: neutral,
            faceBox: landmarks.faceBoundingBoxNorm
        )
        let smoothed = smoother.smooth(raw)
        let clamped = clamp(smoothed)

        return BlendshapeFrame(
            frameID: landmarks.frameID,
            hostTimeNs: landmarks.hostTimeNs,
            coefficients: clamped
        )
    }

    // MARK: - Coefficient derivation

    private func computeCoefficients(current: [LandmarkPoint],
                                     neutral: [LandmarkPoint],
                                     faceBox: CGRect) -> [BlendshapeKey: Float] {
        var out = zeroCoefficients()

        // Face size for normalization. Falls back to a sensible constant if the bbox is empty.
        let faceH = Float(faceBox.height) > 1e-4 ? Float(faceBox.height) : 0.5
        let faceW = Float(faceBox.width) > 1e-4 ? Float(faceBox.width) : 0.5

        // Helper: bounds check before indexing into the landmark array.
        let n = current.count
        @inline(__always) func valid(_ idx: Int...) -> Bool {
            for i in idx where i < 0 || i >= n { return false }
            return true
        }

        // --- jawOpen ---
        // Vertical distance between upper and lower lip, normalized by face height; subtract neutral.
        if valid(LandmarkIndex.mouthUpperLip, LandmarkIndex.mouthLowerLip) {
            let cur = current[LandmarkIndex.mouthLowerLip].y - current[LandmarkIndex.mouthUpperLip].y
            let neu = neutral[LandmarkIndex.mouthLowerLip].y - neutral[LandmarkIndex.mouthUpperLip].y
            // Scale 6x: a 1/6 face-height mouth opening reads as fully open.
            out[.jawOpen] = scale((cur - neu) / faceH, gain: 6.0)
        }

        // --- mouthSmile L/R, mouthFrown L/R ---
        // Horizontal corner displacement outward (smile) vs downward (frown).
        if valid(LandmarkIndex.mouthLeftCorner, LandmarkIndex.mouthRightCorner) {
            let dxL = (current[LandmarkIndex.mouthLeftCorner].x - neutral[LandmarkIndex.mouthLeftCorner].x) / faceW
            let dxR = (current[LandmarkIndex.mouthRightCorner].x - neutral[LandmarkIndex.mouthRightCorner].x) / faceW
            let dyL = (current[LandmarkIndex.mouthLeftCorner].y - neutral[LandmarkIndex.mouthLeftCorner].y) / faceH
            let dyR = (current[LandmarkIndex.mouthRightCorner].y - neutral[LandmarkIndex.mouthRightCorner].y) / faceH
            // Smile = corner moves outward (-x on left, +x on right) and slightly up (-y).
            out[.mouthSmileLeft] = scale(-dxL - dyL, gain: 8.0)
            out[.mouthSmileRight] = scale(dxR - dyR, gain: 8.0)
            // Frown = corner moves down (+y).
            out[.mouthFrownLeft] = scale(dyL, gain: 8.0)
            out[.mouthFrownRight] = scale(dyR, gain: 8.0)
            // mouthLeft / mouthRight: net horizontal mouth offset (jaw shift).
            let centerShift = ((current[LandmarkIndex.mouthLeftCorner].x + current[LandmarkIndex.mouthRightCorner].x) / 2
                - (neutral[LandmarkIndex.mouthLeftCorner].x + neutral[LandmarkIndex.mouthRightCorner].x) / 2) / faceW
            out[.mouthLeft] = scale(-centerShift, gain: 6.0)
            out[.mouthRight] = scale(centerShift, gain: 6.0)
        }

        // --- eyeBlink L/R ---
        // 1 - (current eye openness / neutral eye openness). Below 0 -> eyeWide.
        if valid(LandmarkIndex.leftEyeUpper, LandmarkIndex.leftEyeLower) {
            let cur = current[LandmarkIndex.leftEyeLower].y - current[LandmarkIndex.leftEyeUpper].y
            let neu = neutral[LandmarkIndex.leftEyeLower].y - neutral[LandmarkIndex.leftEyeUpper].y
            let ratio = neu > 1e-5 ? cur / neu : 1
            out[.eyeBlinkLeft] = clampUnit(1 - ratio)
            out[.eyeWideLeft] = clampUnit(ratio - 1)
        }
        if valid(LandmarkIndex.rightEyeUpper, LandmarkIndex.rightEyeLower) {
            let cur = current[LandmarkIndex.rightEyeLower].y - current[LandmarkIndex.rightEyeUpper].y
            let neu = neutral[LandmarkIndex.rightEyeLower].y - neutral[LandmarkIndex.rightEyeUpper].y
            let ratio = neu > 1e-5 ? cur / neu : 1
            out[.eyeBlinkRight] = clampUnit(1 - ratio)
            out[.eyeWideRight] = clampUnit(ratio - 1)
        }

        // --- browInnerUp, browDown L/R, browOuterUp L/R ---
        // Eyebrow vertical displacement relative to face height (negative = up = brow raised).
        if valid(LandmarkIndex.leftBrowInner, LandmarkIndex.rightBrowInner) {
            let dyLInner = (current[LandmarkIndex.leftBrowInner].y - neutral[LandmarkIndex.leftBrowInner].y) / faceH
            let dyRInner = (current[LandmarkIndex.rightBrowInner].y - neutral[LandmarkIndex.rightBrowInner].y) / faceH
            // Average inner-brow rise drives browInnerUp.
            out[.browInnerUp] = scale(-(dyLInner + dyRInner) * 0.5, gain: 12.0)
            out[.browDownLeft] = scale(dyLInner, gain: 12.0)
            out[.browDownRight] = scale(dyRInner, gain: 12.0)
        }
        if valid(LandmarkIndex.leftBrowOuter, LandmarkIndex.rightBrowOuter) {
            let dyLOuter = (current[LandmarkIndex.leftBrowOuter].y - neutral[LandmarkIndex.leftBrowOuter].y) / faceH
            let dyROuter = (current[LandmarkIndex.rightBrowOuter].y - neutral[LandmarkIndex.rightBrowOuter].y) / faceH
            out[.browOuterUpLeft] = scale(-dyLOuter, gain: 12.0)
            out[.browOuterUpRight] = scale(-dyROuter, gain: 12.0)
        }

        // --- mouthFunnel / mouthPucker ---
        // Compactness of the outer mouth ring vs neutral. A funnel/pucker shrinks horizontal extent
        // and rounds the perimeter. We approximate via width-to-height aspect of the ring.
        if LandmarkIndex.mouthOuterRange.upperBound <= n {
            let curMetrics = ringMetrics(points: current, range: LandmarkIndex.mouthOuterRange)
            let neuMetrics = ringMetrics(points: neutral, range: LandmarkIndex.mouthOuterRange)
            if neuMetrics.width > 1e-5 && neuMetrics.height > 1e-5 {
                let widthRatio = curMetrics.width / neuMetrics.width
                let heightRatio = curMetrics.height / neuMetrics.height
                // Pucker: narrower in both axes.
                out[.mouthPucker] = scale((1 - widthRatio) + (1 - heightRatio) * 0.5, gain: 1.5)
                // Funnel: narrower horizontally but taller vertically (rounded O).
                out[.mouthFunnel] = scale((1 - widthRatio) + (heightRatio - 1) * 0.5, gain: 1.5)
            }
        }

        // --- cheekPuff (very approximate from 2D) ---
        // Outline silhouette widens slightly near the cheek band when puffed.
        if LandmarkIndex.outlineRange.upperBound <= n {
            let curW = ringMetrics(points: current, range: LandmarkIndex.outlineRange).width
            let neuW = ringMetrics(points: neutral, range: LandmarkIndex.outlineRange).width
            if neuW > 1e-5 {
                out[.cheekPuff] = scale(curW / neuW - 1, gain: 8.0)
            }
        }

        // --- noseSneer L/R ---
        // Nose tip rises (y decreases) when sneering. Symmetric for v0.1.0.
        if valid(LandmarkIndex.noseTip) {
            let dy = (current[LandmarkIndex.noseTip].y - neutral[LandmarkIndex.noseTip].y) / faceH
            let v = scale(-dy, gain: 10.0)
            out[.noseSneerLeft] = v
            out[.noseSneerRight] = v
        }

        // Apply hysteresis dead-band: anything below the threshold reads as zero.
        for k in BlendshapeKey.allCases {
            if let v = out[k], abs(v) < hysteresis {
                out[k] = 0
            }
        }
        return out
    }

    // MARK: - Helpers

    private struct RingMetrics { let width: Float; let height: Float }

    private func ringMetrics(points: [LandmarkPoint], range: Range<Int>) -> RingMetrics {
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        for i in range {
            let p = points[i]
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return RingMetrics(width: maxX - minX, height: maxY - minY)
    }

    private func zeroCoefficients() -> [BlendshapeKey: Float] {
        var dict: [BlendshapeKey: Float] = [:]
        dict.reserveCapacity(BlendshapeKey.allCases.count)
        for k in BlendshapeKey.allCases { dict[k] = 0 }
        return dict
    }

    @inline(__always)
    private func scale(_ value: Float, gain: Float) -> Float {
        clampUnit(value * gain)
    }

    @inline(__always)
    private func clampUnit(_ value: Float) -> Float {
        if value.isNaN { return 0 }
        return max(0, min(1, value))
    }

    private func clamp(_ coef: [BlendshapeKey: Float]) -> [BlendshapeKey: Float] {
        var out = coef
        for (k, v) in coef { out[k] = clampUnit(v) }
        return out
    }
}
