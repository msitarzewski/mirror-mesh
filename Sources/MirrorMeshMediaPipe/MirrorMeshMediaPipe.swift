import Foundation
import MirrorMeshCore
import MirrorMeshVision

/// Module marker for the MediaPipe Face Mesh landmark backend.
///
/// State at v0.3.0: this target ships a Vision-fallback stub (`MediaPipeLandmarkBackend`
/// delegates to `VisionLandmarkBackend`) so a default `swift build` works in environments
/// without the MediaPipe Tasks XCFramework. The protocol surface, telemetry, manifest tag,
/// and bench scenario are all wired up — the actual MediaPipe binary lands in a follow-up.
///
/// See `docs/landmark-comparison.md` for the comparison harness and the planned migration.
public enum MirrorMeshMediaPipe {
    public static let moduleName = "MirrorMeshMediaPipe"

    /// Tag recorded in the session manifest's `landmarks.backend` field when this backend runs.
    /// Stable across the stub and the future real-binary implementation so JSONL traces remain
    /// directly comparable.
    public static let manifestBackendTag = "mediapipe"
}
