import Testing
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
@testable import MirrorMeshRecorder
import MirrorMeshCore
import MirrorMeshWatermark

@Suite("MirrorMeshRecorder")
struct RecorderTests {

    @Test func moduleName() {
        #expect(MirrorMeshRecorder.moduleName == "MirrorMeshRecorder")
    }

    @Test func recordThirtyFramesAndOpen() async throws {
        let width = 320
        let height = 180
        let fps = 30
        let frameCount = 30

        // Temp output URL — cleaned up by the OS, but we still .removeItem on entry.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirrormesh-recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let movURL = tmpDir.appendingPathComponent("test.mov")

        let recorder = try VideoRecorder(
            url: movURL,
            width: width,
            height: height,
            fps: fps,
            codec: .h264
        )

        let signer = FrameSigner()
        let baseHostNs = MirrorMeshCore.hostTimeNs()
        let stepNs: UInt64 = UInt64(1_000_000_000 / fps)

        for i in 0..<frameCount {
            let buf = try makePixelBuffer(width: width, height: height, tick: i)
            let hostNs = baseHostNs &+ UInt64(i) &* stepNs
            let fid = FrameID(UInt64(i + 1))
            let rendered = RenderedFrame(
                frameID: fid,
                hostTimeNs: hostNs,
                pixelBuffer: buf,
                width: width,
                height: height
            )
            let digest = signer.contentDigest(of: rendered)
            let sig = signer.sign(rendered, contentDigest: digest)
            let wm = WatermarkedFrame(
                frameID: fid,
                hostTimeNs: hostNs,
                pixelBuffer: buf,
                width: width,
                height: height,
                signature: sig,
                contentDigest: digest
            )
            await recorder.append(wm)
        }

        try await recorder.finalize()

        // File exists and has bytes.
        let attrs = try FileManager.default.attributesOfItem(atPath: movURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 0)

        // AVAsset can open it and reports a non-zero duration.
        let asset = AVURLAsset(url: movURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)

        // Cleanup.
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - helpers

    /// BGRA buffer with a per-tick gradient so frames differ enough for the encoder to chew on.
    private func makePixelBuffer(width: Int, height: Int, tick: Int) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buf
        )
        guard status == kCVReturnSuccess, let pb = buf else {
            throw NSError(domain: "RecorderTests", code: 1)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw NSError(domain: "RecorderTests", code: 2)
        }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * 4
                ptr[off + 0] = UInt8((x + tick) & 0xFF)         // B
                ptr[off + 1] = UInt8((y + tick) & 0xFF)         // G
                ptr[off + 2] = UInt8((x ^ y ^ tick) & 0xFF)     // R
                ptr[off + 3] = 0xFF                              // A
            }
        }
        return pb
    }
}
