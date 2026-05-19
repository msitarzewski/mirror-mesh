import Foundation
import Vision
import CoreVideo
import MirrorMeshCore

/// Apple Vision-backed `LandmarkBackend`. Pulls 76-point face landmarks via `VNDetectFaceLandmarksRequest`
/// (revision 3) and applies One-Euro smoothing. Stateless across faces (single-face tracking only).
public final class VisionLandmarkBackend: LandmarkBackend, @unchecked Sendable {
    private let handler = VNSequenceRequestHandler()
    private var xFilters: [OneEuroFilter] = []
    private var yFilters: [OneEuroFilter] = []

    public init() {}

    /// Returns a smoothed `LandmarkFrame` for the given captured frame, or nil if no face.
    public func extract(from frame: CapturedFrame) -> LandmarkFrame? {
        let start = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.stageStart(stage: .vision, frame: frame.frameID, hostTimeNs: start))
        // Signpost mirrors the telemetry emit so Instruments shows Vision request cost per frame.
        let sp = Signpost.begin(Signpost.vision, frame: frame.frameID)
        defer {
            let end = MirrorMeshCore.hostTimeNs()
            TelemetryBus.emit(.stageEnd(stage: .vision, frame: frame.frameID, hostTimeNs: end))
            Signpost.end(Signpost.vision, frame: frame.frameID, id: sp)
        }

        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        do {
            try handler.perform([request], on: frame.pixelBuffer)
        } catch {
            TelemetryBus.emit(.warning(stage: .vision, message: "vision request failed: \(error)"))
            return nil
        }
        guard let face = request.results?.first,
              let landmarks = face.landmarks?.allPoints else {
            return nil
        }

        let raw = landmarks.normalizedPoints  // [CGPoint] in face-bounding-box-local space
        // Convert to image-normalized space by combining with the face bounding box.
        let bbox = face.boundingBox  // normalized image space; Vision origin is bottom-left
        var imagePoints: [LandmarkPoint] = []
        imagePoints.reserveCapacity(raw.count)
        for p in raw {
            let ix = Float(bbox.origin.x + p.x * bbox.size.width)
            // Flip Y: Vision origin is bottom-left, our convention is top-left.
            let iy = Float(1.0 - (bbox.origin.y + p.y * bbox.size.height))
            imagePoints.append(LandmarkPoint(x: ix, y: iy))
        }

        // Lazily initialise per-landmark One-Euro filters.
        if xFilters.count != imagePoints.count {
            xFilters = Array(repeating: OneEuroFilter(), count: imagePoints.count)
            yFilters = Array(repeating: OneEuroFilter(), count: imagePoints.count)
        }
        var smoothed: [LandmarkPoint] = []
        smoothed.reserveCapacity(imagePoints.count)
        for i in 0..<imagePoints.count {
            let sx = xFilters[i].filter(Double(imagePoints[i].x), atTimeNs: frame.hostTimeNs)
            let sy = yFilters[i].filter(Double(imagePoints[i].y), atTimeNs: frame.hostTimeNs)
            smoothed.append(LandmarkPoint(x: Float(sx), y: Float(sy)))
        }

        // Vision's bbox is bottom-left origin; flip to top-left for our LandmarkFrame.
        let flippedBox = CGRect(x: bbox.origin.x,
                                y: 1.0 - bbox.origin.y - bbox.size.height,
                                width: bbox.size.width,
                                height: bbox.size.height)

        return LandmarkFrame(
            frameID: frame.frameID,
            hostTimeNs: frame.hostTimeNs,
            points: smoothed,
            confidence: Float(face.confidence),
            faceBoundingBoxNorm: flippedBox
        )
    }

    public func reset() {
        for i in 0..<xFilters.count {
            xFilters[i].reset()
            yFilters[i].reset()
        }
    }
}

/// Back-compat alias. Existing callers reference `LandmarkExtractor`; the type is now the
/// Vision-specific backend behind the `LandmarkBackend` protocol introduced in M26.
public typealias LandmarkExtractor = VisionLandmarkBackend
