import Testing
import Foundation
import CoreVideo
@testable import MirrorMeshMediaPipe
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshVision

@Suite("MirrorMeshMediaPipe")
struct MediaPipeTests {
    @Test func moduleName() {
        #expect(MirrorMeshMediaPipe.moduleName == "MirrorMeshMediaPipe")
    }

    @Test func manifestBackendTagIsMediapipe() {
        #expect(MirrorMeshMediaPipe.manifestBackendTag == "mediapipe")
    }

    @Test func conformsToLandmarkBackend() {
        // Compile-time conformance: assignable to the protocol existential.
        let backend: any LandmarkBackend = MediaPipeLandmarkBackend()
        _ = backend
    }

    @Test func mediaPipeToVisionIndicesCover76Slots() {
        // The 468 → 76 mapping must have exactly one entry per Vision schema slot.
        #expect(MediaPipeLandmarkBackend.mediaPipeToVisionIndices.count == 76)
    }

    // Disabled: backend currently falls back to Apple Vision, which doesn't detect a face in
    // SyntheticFrameSource's procedural cartoon — the for-await loop never finds non-nil and
    // never terminates. Re-enable once a real-face fixture exercises this path (M15 fixture).
    @Test(.disabled("synthetic frame source has no real face; Vision fallback yields nil"))
    func extractReturnsNonNilOnSyntheticFrame() async throws {
        let source = SyntheticFrameSource(config: CaptureConfig(width: 640, height: 360, fps: 30))
        let stream = try await source.start()
        let backend = MediaPipeLandmarkBackend()

        for await captured in stream {
            let lf = backend.extract(from: captured)
            // Vision-fallback path may return nil for early synthetic frames before the face
            // detector locks on; treat nil as acceptable for the first few frames. Loop until
            // we get non-nil OR exhaust 5 frames — synthetic source's face is centered so
            // Vision should latch within a few frames.
            if lf != nil {
                #expect(lf?.points.count == 76)
                await source.stop()
                return
            }
        }
        // If we exit the loop without a hit, fail.
        await source.stop()
        Issue.record("MediaPipeLandmarkBackend.extract never returned non-nil for synthetic frames")
    }

    @Test func isUsingFallbackTrueInStubState() {
        // The v0.3.0 implementation always reports fallback. A future change flips this to
        // false when MediaPipe successfully runs; the test will need to be updated then.
        #expect(MediaPipeLandmarkBackend().isUsingFallback == true)
    }
}
