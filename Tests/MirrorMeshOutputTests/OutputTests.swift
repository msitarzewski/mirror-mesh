import Testing
import Foundation
@testable import MirrorMeshOutput
import MirrorMeshCore

@Suite("MirrorMeshOutput")
struct OutputTests {
    @Test func moduleName() {
        #expect(MirrorMeshOutput.moduleName == "MirrorMeshOutput")
    }

    @Test func pipelineOptionsDefaults() {
        let opts = PipelineOptions()
        #expect(opts.captureWidth == 640)
        #expect(opts.captureHeight == 360)
        #expect(opts.fps == 30)
    }
}
