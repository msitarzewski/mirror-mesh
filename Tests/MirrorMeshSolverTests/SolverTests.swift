import Testing
import Foundation
@testable import MirrorMeshSolver
import MirrorMeshCore

@Suite("MirrorMeshSolver")
struct SolverTests {
    @Test func moduleName() {
        #expect(MirrorMeshSolver.moduleName == "MirrorMeshSolver")
    }

    @Test func calibratesAfterTargetFrames() {
        let cal = NeutralPoseCalibrator(frameTarget: 5, alpha: 0.5)
        #expect(!cal.isCalibrated)
        for _ in 0..<5 {
            let f = LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76),
                confidence: 0.95,
                faceBoundingBoxNorm: .init(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
            )
            cal.observe(f)
        }
        #expect(cal.isCalibrated)
        #expect(cal.neutralPoints() != nil)
    }

    @Test func coefficientsClampedUnderExtremeInput() {
        let solver = GeometricSolver(calibrationFrames: 5)
        let neutral = makeNeutralPoints()
        let bbox = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        for _ in 0..<5 {
            _ = solver.solve(LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: neutral, confidence: 0.95, faceBoundingBoxNorm: bbox
            ))
        }
        var extreme = neutral
        extreme[LandmarkIndex.mouthLowerLip] = LandmarkPoint(x: 0.5, y: 5.0)  // absurd
        let result = solver.solve(LandmarkFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            points: extreme, confidence: 0.95, faceBoundingBoxNorm: bbox
        ))
        for (_, v) in result.coefficients {
            #expect(v >= 0)
            #expect(v <= 1)
        }
    }

    private func makeNeutralPoints() -> [LandmarkPoint] {
        var pts = Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76)
        for i in 40..<56 {
            let theta = Double(i - 40) / 16.0 * 2 * .pi
            pts[i] = LandmarkPoint(x: 0.5 + Float(cos(theta)) * 0.1,
                                   y: 0.62 + Float(sin(theta)) * 0.02)
        }
        pts[LandmarkIndex.mouthLeftCorner]  = LandmarkPoint(x: 0.4, y: 0.62)
        pts[LandmarkIndex.mouthUpperLip]    = LandmarkPoint(x: 0.5, y: 0.6)
        pts[LandmarkIndex.mouthRightCorner] = LandmarkPoint(x: 0.6, y: 0.62)
        pts[LandmarkIndex.mouthLowerLip]    = LandmarkPoint(x: 0.5, y: 0.64)
        for i in 0..<16 {
            let theta = Double(i) / 16.0 * 2 * .pi
            pts[i] = LandmarkPoint(x: 0.5 + Float(cos(theta)) * 0.25,
                                   y: 0.5 + Float(sin(theta)) * 0.3)
        }
        return pts
    }
}
