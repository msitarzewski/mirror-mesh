import Foundation
import MirrorMeshCore

/// Common surface for any face-landmark extractor that produces the 76-point Vision schema
/// MirrorMesh's solver consumes. Implementations may internally produce richer outputs (e.g.
/// MediaPipe Face Mesh's 468 points) and project down before returning.
///
/// Implementations are responsible for their own telemetry (`.stageStart` / `.stageEnd` with
/// `StageID.vision`) so the pipeline doesn't need to know which backend it has.
public protocol LandmarkBackend: Sendable {
    /// Returns up to one face's 76-point landmarks for the captured frame, or nil if no face.
    func extract(from frame: CapturedFrame) -> LandmarkFrame?
}
