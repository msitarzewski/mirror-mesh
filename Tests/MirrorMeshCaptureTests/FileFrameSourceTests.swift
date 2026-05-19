import Testing
import Foundation
@testable import MirrorMeshCapture
import MirrorMeshCore

@Suite("FileFrameSource")
struct FileFrameSourceTests {
    /// Locate the committed procedural fixture relative to this source file.
    static func fixtureURL() -> URL {
        // Why: SPM doesn't expose a resource bundle here, so resolve by repo-root walk.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // MirrorMeshCaptureTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo root>
        return repoRoot
            .appendingPathComponent("Tests/Fixtures/face_synthetic_3s.mp4")
    }

    @Test func fixtureFileExists() {
        let url = Self.fixtureURL()
        #expect(FileManager.default.fileExists(atPath: url.path),
                "expected committed fixture at \(url.path)")
    }

    @Test func readsFramesWithNonZeroDimensions() async throws {
        let url = Self.fixtureURL()
        try #require(FileManager.default.fileExists(atPath: url.path))

        let source = FileFrameSource(url: url, looping: false, pace: .asFast)
        let stream = try await source.start()

        var frames: [CapturedFrame] = []
        for await frame in stream {
            frames.append(frame)
            if frames.count >= 30 { break }
        }
        await source.stop()

        #expect(frames.count >= 30, "expected ≥30 frames, got \(frames.count)")
        for f in frames {
            #expect(f.width > 0)
            #expect(f.height > 0)
            #expect(f.frameID.value > 0)
        }
    }

    @Test func frameIDsAreMonotonic() async throws {
        let url = Self.fixtureURL()
        try #require(FileManager.default.fileExists(atPath: url.path))

        let source = FileFrameSource(url: url, looping: false, pace: .asFast)
        let stream = try await source.start()

        var ids: [UInt64] = []
        for await frame in stream {
            ids.append(frame.frameID.value)
            if ids.count >= 20 { break }
        }
        await source.stop()

        #expect(ids.count >= 20)
        for i in 1..<ids.count {
            #expect(ids[i] > ids[i - 1], "frameIDs must strictly increase: \(ids[i-1]) → \(ids[i])")
        }
    }

    @Test func terminatesAtEndOfFile() async throws {
        let url = Self.fixtureURL()
        try #require(FileManager.default.fileExists(atPath: url.path))

        let source = FileFrameSource(url: url, looping: false, pace: .asFast)
        let stream = try await source.start()
        var count = 0
        for await _ in stream { count += 1 }
        // 3s @ 30fps = 90 frames. Reader yields all then terminates.
        #expect(count >= 60, "expected file to play to completion, got \(count) frames")
    }
}
