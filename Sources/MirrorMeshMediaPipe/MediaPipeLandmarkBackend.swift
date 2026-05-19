import Foundation
import CoreVideo
import MirrorMeshCore
import MirrorMeshVision

/// MediaPipe Face Mesh-backed `LandmarkBackend`.
///
/// ## Current state (v0.3.0): Vision-fallback stub
///
/// A working `swift build` cannot depend on the MediaPipe Tasks XCFramework being available
/// in every developer's environment (no first-party Swift package; CocoaPods or vendored
/// XCFramework only; ~12 MB binary). To unblock the v0.3.0 paper deliverable we ship the
/// protocol, dispatch wiring, manifest tag, bench scenario, and comparison harness now —
/// while the backend itself delegates to `VisionLandmarkBackend` and emits a single
/// `.warning` telemetry event the first time it runs, mirroring the M18 `CoreMLSolver`
/// pattern. A future change vendors the real MediaPipe binary and replaces
/// `extract(from:)`'s body with a real 468 → 76 mapping; the public surface does not move.
///
/// ## When the real binary lands
///
/// MediaPipe Face Mesh produces 468 normalized landmarks. The solver consumes the 76-point
/// Vision schema. The mapping `Self.mediaPipeToVisionIndices` documents which MediaPipe
/// indices correspond to each Vision schema position (face oval, eyes, brows, nose, lips,
/// chin). The values below match `bench/scripts/compare_landmarks.py`'s schema.
///
/// Telemetry: same `.stageStart` / `.stageEnd` `StageID.vision` events the Vision backend
/// emits, so JSONL traces from either backend slot into the same comparison pipeline.
public final class MediaPipeLandmarkBackend: LandmarkBackend, @unchecked Sendable {
    /// Delegate used while the MediaPipe binary is unavailable; also used as a safety net
    /// inside the real-binary path when MediaPipe returns no face.
    private let visionFallback: VisionLandmarkBackend
    private var didWarnAboutFallback = false
    private let lock = NSLock()

    public init(visionFallback: VisionLandmarkBackend = VisionLandmarkBackend()) {
        self.visionFallback = visionFallback
    }

    /// Whether this backend is currently running in fallback mode. Always `true` for the
    /// v0.3.0 stub; a future change flips this to `false` when MediaPipe inference succeeds.
    public var isUsingFallback: Bool { true }

    public func extract(from frame: CapturedFrame) -> LandmarkFrame? {
        let start = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.stageStart(stage: .vision, frame: frame.frameID, hostTimeNs: start))
        let sp = Signpost.begin(Signpost.vision, frame: frame.frameID)
        defer {
            let end = MirrorMeshCore.hostTimeNs()
            TelemetryBus.emit(.stageEnd(stage: .vision, frame: frame.frameID, hostTimeNs: end))
            Signpost.end(Signpost.vision, frame: frame.frameID, id: sp)
        }

        // One-shot warning so JSONL consumers can tell which backend actually ran the inference.
        lock.lock()
        let shouldWarn = !didWarnAboutFallback
        didWarnAboutFallback = true
        lock.unlock()
        if shouldWarn {
            TelemetryBus.emit(.warning(
                stage: .vision,
                message: "MediaPipe backend not available, falling back to Vision"
            ))
            TelemetryBus.emit(.annotation(key: "landmark.backend", value: "mediapipe-stub"))
        }

        // Vision-fallback path. When the real MediaPipe binary lands, replace this with the
        // inference call + 468→76 index remap; keep the same telemetry envelope.
        return visionFallback.extract(from: frame)
    }

    /// Reset internal smoothing state (delegates to the fallback's filter bank). Safe to call
    /// between sessions.
    public func reset() {
        visionFallback.reset()
    }

    // MARK: - 468 → 76 mapping (documentation; consumed by the real-binary path)

    /// Documented mapping from MediaPipe Face Mesh's 468-landmark schema to MirrorMesh's
    /// 76-point Vision schema slot. Indices are MediaPipe's canonical face_landmarker IDs.
    ///
    /// Sources (verify against the model card before flipping the real-binary switch):
    /// - MediaPipe Solutions docs: face_landmarker model card, "Output" → 468 normalized 3D points
    /// - Vision's allPoints layout: face contour first, then eyes, brows, nose, outer/inner lips
    ///
    /// Grouping (slot ranges match `SyntheticLandmarkExtractor`):
    /// - 0..15:  face oval        — MediaPipe indices 10, 338, 297, 332, 284, 251, 389, 356,
    ///                             454, 323, 361, 288, 397, 365, 379, 378
    /// - 16..23: left eye         — 33, 160, 158, 133, 153, 144, 145, 153
    /// - 24..31: right eye        — 263, 387, 385, 362, 380, 373, 374, 380
    /// - 32..39: nose             — 1, 2, 5, 4, 19, 94, 125, 141
    /// - 40..55: outer lips       — 61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375,
    ///                             321, 405, 314, 17
    /// - 56..63: chin/jawline     — 152, 148, 176, 149, 150, 136, 172, 58
    /// - 64..67: left brow        — 70, 63, 105, 66
    /// - 68..71: right brow       — 300, 293, 334, 296
    /// - 72..75: inner mouth      — 78, 95, 88, 178
    public static let mediaPipeToVisionIndices: [Int] = [
        10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378,
        33, 160, 158, 133, 153, 144, 145, 153,
        263, 387, 385, 362, 380, 373, 374, 380,
        1, 2, 5, 4, 19, 94, 125, 141,
        61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17,
        152, 148, 176, 149, 150, 136, 172, 58,
        70, 63, 105, 66,
        300, 293, 334, 296,
        78, 95, 88, 178,
    ]
}
