import Foundation
import MirrorMeshCore

/// Common abstraction over expression solvers — anything that maps a 76-point landmark frame
/// to ARKit-52 blendshape coefficients. Implementations: `GeometricSolver`, `CoreMLSolver`.
public protocol ExpressionSolver: Sendable {
    func solve(_ landmarks: LandmarkFrame) -> BlendshapeFrame
}
