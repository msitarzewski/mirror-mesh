import Testing
import Foundation
import CoreVideo
@testable import MirrorMeshVision
import MirrorMeshCore
import MirrorMeshCapture

@Suite("MirrorMeshVision")
struct VisionTests {
    @Test func moduleName() {
        #expect(MirrorMeshVision.moduleName == "MirrorMeshVision")
    }

    @Test func oneEuroFilterFirstSampleReturnsInput() {
        var filt = OneEuroFilter()
        let v = filt.filter(1.234, atTimeNs: MirrorMeshCore.hostTimeNs())
        #expect(v == 1.234)
    }

    @Test func oneEuroFilterSmoothsSteadyInput() {
        var filt = OneEuroFilter()
        var t: UInt64 = 0
        _ = filt.filter(10.0, atTimeNs: t); t += 16_666_666
        for _ in 0..<30 {
            _ = filt.filter(10.0, atTimeNs: t)
            t += 16_666_666
        }
        let v = filt.filter(10.0, atTimeNs: t)
        #expect(abs(v - 10.0) < 0.01)
    }

    @Test func syntheticLandmarkExtractorProducesSchemaPoints() async throws {
        let source = SyntheticFrameSource(config: CaptureConfig(width: 320, height: 180, fps: 60))
        let stream = try await source.start()
        let extractor = SyntheticLandmarkExtractor()
        for await captured in stream {
            let lf = extractor.extractAlways(from: captured)
            #expect(lf.points.count == 76)
            #expect(lf.confidence > 0.9)
            await source.stop()
            return
        }
    }

    @Test func visionLandmarkBackendConformsToLandmarkBackend() {
        let backend: any LandmarkBackend = VisionLandmarkBackend()
        // Compile-time conformance; runtime behaviour is exercised by file-mode bench/integration.
        _ = backend
    }

    @Test func syntheticBackendConformsToLandmarkBackendAndProducesNonNil() async throws {
        let source = SyntheticFrameSource(config: CaptureConfig(width: 320, height: 180, fps: 60))
        let stream = try await source.start()
        let backend: any LandmarkBackend = SyntheticLandmarkExtractor()
        for await captured in stream {
            let lf = backend.extract(from: captured)
            #expect(lf != nil)
            #expect(lf?.points.count == 76)
            await source.stop()
            return
        }
    }
}
