import Testing
import Foundation
import MirrorMeshCore
import MirrorMeshOutput
import MirrorMeshWatermark

@Suite("End-to-end pipeline (synthetic)")
struct EndToEndTests {
    @Test func syntheticPipelineRunsAndManifestVerifies() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifestURL = tmp.appendingPathComponent("session.manifest.json")
        let jsonlURL = tmp.appendingPathComponent("session.jsonl")
        let pipeline = Pipeline(
            options: PipelineOptions(mode: .synthetic, captureWidth: 320, captureHeight: 180, fps: 60, maxFrames: 30),
            manifestURL: manifestURL,
            jsonlURL: jsonlURL
        )
        let result = try await pipeline.run()
        #expect(result.framesProcessed == 30)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonlURL.path))

        let data = try Data(contentsOf: manifestURL)
        let manifest = try ManifestCodec.decode(data)
        #expect(manifest.frame_count == 30)
        #expect(Verifier.verifyManifest(manifest))
    }
}
