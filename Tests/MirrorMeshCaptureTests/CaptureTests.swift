import Testing
import Foundation
@testable import MirrorMeshCapture
import MirrorMeshCore

@Suite("MirrorMeshCapture")
struct CaptureTests {
    @Test func moduleNamePresent() {
        #expect(MirrorMeshCapture.moduleName == "MirrorMeshCapture")
    }

    @Test func captureConfigDefaults() {
        let cfg = CaptureConfig()
        #expect(cfg.width == 1280)
        #expect(cfg.height == 720)
        #expect(cfg.fps == 60)
        #expect(cfg.lockExposure)
    }

    @Test func benchSmallPreset() {
        #expect(CaptureConfig.benchSmall.width == 640)
        #expect(CaptureConfig.benchSmall.fps == 30)
    }

    @Test func syntheticFrameSourceProducesFrames() async throws {
        let source = SyntheticFrameSource(config: CaptureConfig(width: 320, height: 180, fps: 60))
        let stream = try await source.start()
        var count = 0
        for await frame in stream {
            #expect(frame.width == 320)
            #expect(frame.height == 180)
            #expect(frame.frameID.value > 0)
            count += 1
            if count >= 5 { break }
        }
        await source.stop()
        #expect(count == 5)
    }
}
