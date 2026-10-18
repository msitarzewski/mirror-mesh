import Testing
import Foundation
@testable import MirrorMeshSolver
import MirrorMeshCore

@Suite("ExpressionTransforms")
struct ExpressionTransformTests {
    private let sample: [BlendshapeKey: Float] = [
        .mouthSmileLeft: 0.2, .mouthSmileRight: 0.8,
        .eyeBlinkLeft: 0.0, .eyeBlinkRight: 0.6,
        .browOuterUpLeft: 0.1, .browOuterUpRight: 0.5,
        .jawOpen: 0.3, .mouthLeft: 0.4,
        .eyeLookInLeft: 0.5, .eyeLookOutRight: 0.5,
    ]

    @Test func inactiveTransformsReturnInputUnchanged() {
        #expect(!ExpressionTransforms.none.isActive)
        #expect(ExpressionTransforms.none.apply(sample) == sample)
        #expect(ExpressionTransforms.none.manifestTags.isEmpty)
        // Enabled-but-zero settings are also inactive.
        let zeroed = ExpressionTransforms(symmetry: .init(affectedSide: .left, strength: 0), gain: 1, eyeContact: 0)
        #expect(!zeroed.isActive)
        #expect(zeroed.apply(sample) == sample)
    }

    @Test func fullSymmetryMirrorsHealthySideOntoAffected() {
        let t = ExpressionTransforms(symmetry: .init(affectedSide: .left, strength: 1))
        let out = t.apply(sample)
        #expect(out[.mouthSmileLeft] == 0.8)
        #expect(out[.eyeBlinkLeft] == 0.6)
        #expect(out[.browOuterUpLeft] == 0.5)
        // The healthy side is never touched.
        #expect(out[.mouthSmileRight] == 0.8)
        #expect(out[.eyeBlinkRight] == 0.6)
        // Lateral pull toward the healthy side is removed at full strength.
        #expect(out[.mouthLeft] == 0)
    }

    @Test func partialSymmetryInterpolates() {
        let t = ExpressionTransforms(symmetry: .init(affectedSide: .right, strength: 0.5))
        let out = t.apply(sample)
        // Right is affected: right moves halfway toward left.
        #expect(abs((out[.mouthSmileRight] ?? 0) - 0.5) < 1e-6)
        #expect(out[.mouthSmileLeft] == 0.2)
    }

    @Test func symmetryNeverCopiesGaze() {
        // Copying one eye's eyeLookIn onto the other would cross the eyes; gaze must be untouched.
        let t = ExpressionTransforms(symmetry: .init(affectedSide: .right, strength: 1))
        let out = t.apply(sample)
        #expect(out[.eyeLookInLeft] == 0.5)
        #expect(out[.eyeLookOutRight] == 0.5)
        #expect(out[.eyeLookInRight] == nil)
    }

    @Test func gainAmplifiesSmallMotionAndSaturatesSmoothly() {
        let t = ExpressionTransforms(gain: 2)
        let out = t.apply([.jawOpen: 0.1, .mouthSmileLeft: 1.0, .browInnerUp: 0])
        // 1 − (1 − 0.1)² = 0.19
        #expect(abs((out[.jawOpen] ?? 0) - 0.19) < 1e-5)
        #expect(out[.mouthSmileLeft] == 1.0)
        #expect(out[.browInnerUp] == 0)
    }

    @Test func gainLeavesBlinkAndGazeAlone() {
        let t = ExpressionTransforms(gain: 3)
        let out = t.apply(sample)
        #expect(out[.eyeBlinkRight] == 0.6)
        #expect(out[.eyeLookInLeft] == 0.5)
    }

    @Test func gainIsClampedToSupportedRange() {
        let wild = ExpressionTransforms(gain: 50).apply([.jawOpen: 0.1])
        let max = ExpressionTransforms(gain: 3).apply([.jawOpen: 0.1])
        #expect(wild == max)
    }

    @Test func eyeContactScalesGazeTowardViewer() {
        let gaze = GazeChannels.encode(horizontal: 0.6, vertical: -0.4)
        let out = ExpressionTransforms(eyeContact: 0.75).apply(gaze)
        let decoded = GazeChannels.decode(out)
        #expect(abs(decoded.horizontal - 0.15) < 1e-5)
        #expect(abs(decoded.vertical + 0.10) < 1e-5)
        let full = GazeChannels.decode(ExpressionTransforms(eyeContact: 1).apply(gaze))
        #expect(full.horizontal == 0 && full.vertical == 0)
    }

    @Test func outputIsAlwaysClampedAndFinite() {
        let out = ExpressionTransforms(symmetry: .init(affectedSide: .left, strength: 1), gain: 2.5, eyeContact: 0.5)
            .apply([.mouthSmileLeft: .nan, .mouthSmileRight: 1.7, .jawOpen: -0.3])
        for (_, v) in out {
            #expect(v.isFinite)
            #expect(v >= 0 && v <= 1)
        }
    }

    @Test func manifestTagsDescribeEachActiveTransform() {
        let t = ExpressionTransforms(symmetry: .init(affectedSide: .left, strength: 0.8), gain: 1.5, eyeContact: 0.7)
        #expect(t.isActive)
        #expect(t.manifestTags == ["symmetry:left:0.80", "gain:1.50", "eye_contact:0.70"])
    }
}

@Suite("Gaze measurement")
struct GazeMeasurementTests {
    private let bbox = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)

    private func frame(pupilDX: Float, pupilDY: Float) -> LandmarkFrame {
        func eye(_ cx: Float) -> EyeLandmarks {
            EyeLandmarks(pupil: LandmarkPoint(x: cx + pupilDX, y: 0.4 + pupilDY),
                         center: LandmarkPoint(x: cx, y: 0.4), width: 0.1)
        }
        return LandmarkFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            points: Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76),
            confidence: 0.95,
            faceBoundingBoxNorm: bbox,
            eyes: [eye(0.4), eye(0.6)]
        )
    }

    @Test func pupilOffsetAveragesEyesInEyeWidths() {
        let f = frame(pupilDX: 0.02, pupilDY: -0.01)
        let off = GeometricSolver.pupilOffset(f.eyes)
        #expect(off != nil)
        #expect(abs((off?.x ?? 0) - 0.2) < 1e-5)
        #expect(abs((off?.y ?? 0) + 0.1) < 1e-5)
        #expect(GeometricSolver.pupilOffset([]) == nil)
    }

    @Test func gazeIsMeasuredRelativeToCalibratedRest() {
        let solver = GeometricSolver(calibrationFrames: 5, smoothingAlpha: 1.0)
        // Rest: pupils slightly low (operator reading the screen under the camera).
        for _ in 0..<5 { _ = solver.solve(frame(pupilDX: 0, pupilDY: 0.01)) }
        let atRest = GazeChannels.decode(solver.solve(frame(pupilDX: 0, pupilDY: 0.01)).coefficients)
        #expect(atRest.horizontal == 0 && atRest.vertical == 0)

        // Look to image-right and up.
        let moved = GazeChannels.decode(solver.solve(frame(pupilDX: 0.015, pupilDY: -0.004)).coefficients)
        #expect(moved.horizontal > 0.4)
        #expect(moved.vertical > 0.5)
    }

    @Test func noPupilsMeansStraightAhead() {
        let solver = GeometricSolver(calibrationFrames: 2, smoothingAlpha: 1.0)
        let plain = LandmarkFrame(frameID: FrameIDGenerator.shared.next(), hostTimeNs: 0,
                                  points: Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76),
                                  confidence: 1, faceBoundingBoxNorm: bbox)
        for _ in 0..<3 { _ = solver.solve(plain) }
        let g = GazeChannels.decode(solver.solve(plain).coefficients)
        #expect(g.horizontal == 0 && g.vertical == 0)
    }
}
