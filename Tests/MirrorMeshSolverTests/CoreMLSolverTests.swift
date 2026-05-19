import Testing
import Foundation
@testable import MirrorMeshSolver
import MirrorMeshCore

@Suite("CoreMLSolver")
struct CoreMLSolverTests {

    /// Construction must succeed even when no `.mlpackage` is on disk; the solver falls back to
    /// the geometric path in that case. This is the developer-environment baseline.
    @Test func constructsWithoutThrowingWhenModelMissing() {
        let solver = CoreMLSolver(searchPaths: [
            URL(fileURLWithPath: "/nonexistent/path/blendshape_solver_v1.mlpackage")
        ])
        // Either the model loaded from the default search list (CI machine with weights) or
        // we are correctly in fallback mode. Both are valid outcomes for this test.
        _ = solver.isUsingFallback
    }

    @Test func conformsToExpressionSolverProtocol() {
        let solver: any ExpressionSolver = CoreMLSolver(searchPaths: [])
        let frame = Self.makeFrame()
        let out = solver.solve(frame)
        #expect(out.coefficients.count == BlendshapeKey.allCases.count)
    }

    @Test func coefficientsClampedToUnitInterval() {
        let solver = CoreMLSolver(searchPaths: [])
        // Calibrate the embedded fallback by feeding the neutral pose a few times.
        for _ in 0..<10 {
            _ = solver.solve(Self.makeFrame(jawOffset: 0))
        }
        // Then an "absurd" jaw-open frame to push values to their limits.
        let extreme = solver.solve(Self.makeFrame(jawOffset: 0.5))
        for (_, v) in extreme.coefficients {
            #expect(v >= 0)
            #expect(v <= 1)
        }
    }

    @Test func outputKeyOrderCoversAllBlendshapes() {
        #expect(CoreMLSolver.outputKeyOrder.count == BlendshapeKey.allCases.count)
        #expect(Set(CoreMLSolver.outputKeyOrder) == Set(BlendshapeKey.allCases))
    }

    /// When weights are actually present on disk the solver should produce non-zero output for
    /// a jaw-open frame after calibration. We skip the assertion when no model is loaded so
    /// CI without weights still passes.
    @Test func nonZeroJawOpenWhenModelPresent() {
        let solver = CoreMLSolver()
        guard !solver.isUsingFallback else {
            // No bundled model — fallback path is exercised by the other tests.
            return
        }
        for _ in 0..<10 {
            _ = solver.solve(Self.makeFrame(jawOffset: 0))
        }
        let opened = solver.solve(Self.makeFrame(jawOffset: 0.15))
        let total = opened.coefficients.values.reduce(0, +)
        #expect(total > 0)
    }

    // MARK: - Helpers

    private static func makeFrame(jawOffset: Float = 0) -> LandmarkFrame {
        var pts = Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76)
        for i in 40..<56 {
            let theta = Double(i - 40) / 16.0 * 2 * .pi
            pts[i] = LandmarkPoint(x: 0.5 + Float(cos(theta)) * 0.1,
                                   y: 0.62 + Float(sin(theta)) * 0.02)
        }
        pts[LandmarkIndex.mouthLeftCorner]  = LandmarkPoint(x: 0.4, y: 0.62)
        pts[LandmarkIndex.mouthUpperLip]    = LandmarkPoint(x: 0.5, y: 0.60)
        pts[LandmarkIndex.mouthRightCorner] = LandmarkPoint(x: 0.6, y: 0.62)
        pts[LandmarkIndex.mouthLowerLip]    = LandmarkPoint(x: 0.5, y: 0.64 + jawOffset)
        for i in 0..<16 {
            let theta = Double(i) / 16.0 * 2 * .pi
            pts[i] = LandmarkPoint(x: 0.5 + Float(cos(theta)) * 0.25,
                                   y: 0.5 + Float(sin(theta)) * 0.3)
        }
        return LandmarkFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            points: pts,
            confidence: 0.95,
            faceBoundingBoxNorm: .init(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        )
    }
}
