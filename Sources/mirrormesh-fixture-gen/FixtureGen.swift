import Foundation
// @preconcurrency: AVAssetWriterInput and AVAssetWriterInputPixelBufferAdaptor are not
// formally Sendable yet, but the documented requestMediaDataWhenReady(on:using:) contract
// hands them to a serial queue — no concurrent access from us. See R14-adjacent footgun.
@preconcurrency import AVFoundation
import CoreVideo
import CoreGraphics
import CoreImage

// Procedurally renders a 3-second 720p BGRA H.264 clip of a moving-mouth, blinking-eyes
// synthetic face. Output path defaults to Tests/Fixtures/face_synthetic_3s.mp4.
// No human likeness — this clip is solely to exercise the FileFrameSource code path.

@main
struct FixtureGen {
    static func main() async {
        let args = CommandLine.arguments
        let outPath = args.firstIndex(of: "--out")
            .flatMap { i -> String? in i + 1 < args.count ? args[i + 1] : nil }
            ?? "Tests/Fixtures/face_synthetic_3s.mp4"

        let outURL = URL(fileURLWithPath: outPath)
        do {
            try await render(to: outURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            print("wrote \(outURL.path) (\(size) bytes)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func render(to url: URL) async throws {
        let width = 1280
        let height = 720
        let fps: Int32 = 30
        let durationFrames = 90 // 3 seconds at 30fps

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Why: low bitrate keeps the committed fixture small (target ≤ 4 MB).
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 600_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "FixtureGen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add writer input"])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "FixtureGen", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "ai.mirrormesh.fixturegen")
        // requestMediaDataWhenReady serializes calls onto `queue`, so the captured
        // `input`/`adaptor` are never touched concurrently. They're not formally Sendable;
        // wrap in nonisolated(unsafe) so Swift 6 strict concurrency stops warning.
        nonisolated(unsafe) let unsafeInput = input
        nonisolated(unsafe) let unsafeAdaptor = adaptor
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var frameIndex: Int64 = 0
            unsafeInput.requestMediaDataWhenReady(on: queue) {
                while unsafeInput.isReadyForMoreMediaData {
                    if frameIndex >= durationFrames {
                        unsafeInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    guard let pool = unsafeAdaptor.pixelBufferPool,
                          let pb = createBuffer(pool: pool,
                                                width: width,
                                                height: height,
                                                index: frameIndex) else {
                        unsafeInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    let pts = CMTime(value: frameIndex, timescale: fps)
                    if !unsafeAdaptor.append(pb, withPresentationTime: pts) {
                        unsafeInput.markAsFinished()
                        cont.resume()
                        return
                    }
                    frameIndex += 1
                }
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "FixtureGen", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "finishWriting status=\(writer.status.rawValue)"])
        }
    }

    static func createBuffer(pool: CVPixelBufferPool,
                             width: Int,
                             height: Int,
                             index: Int64) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard status == kCVReturnSuccess, let pb = buf else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)

        // Solid skin-tone background — keeps file size small and gives clear "face" silhouette.
        for y in 0..<height {
            let row = p.advanced(by: y * bpr)
            for x in 0..<width {
                let off = x * 4
                row[off + 0] = 140 // B
                row[off + 1] = 175 // G
                row[off + 2] = 210 // R
                row[off + 3] = 255 // A
            }
        }

        let t = Double(index) / 30.0
        let cx = width / 2
        let cy = height / 2
        let s = min(width, height) / 3

        // Blink cycle: eyes closed briefly at t≈1.0 and t≈2.0 seconds.
        let blink = (abs(t - 1.0) < 0.08) || (abs(t - 2.0) < 0.08)
        let eyeRadius = blink ? max(2, s / 40) : s / 14
        let eyeY = cy - s / 3
        drawDisc(p, bpr, width, height, cx: cx - s / 3, cy: eyeY, r: eyeRadius, color: (40, 40, 40, 255))
        drawDisc(p, bpr, width, height, cx: cx + s / 3, cy: eyeY, r: eyeRadius, color: (40, 40, 40, 255))

        // Nose dot.
        drawDisc(p, bpr, width, height, cx: cx, cy: cy, r: s / 22, color: (90, 110, 150, 255))

        // Mouth — vertical openness oscillates so motion is visible across frames.
        let openness = Int(Double(s / 6) * (0.5 + 0.5 * sin(t * 2.0 * .pi / 1.5)))
        for dy in -max(1, openness)...max(1, openness) {
            let denom = max(1, openness * openness)
            let halfW = Int(Double(s / 3) * sqrt(max(0.0, 1.0 - Double(dy * dy) / Double(denom))))
            for dx in -halfW...halfW {
                let px = cx + dx
                let py = cy + s / 3 + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let off = py * bpr + px * 4
                p[off + 0] = 60
                p[off + 1] = 50
                p[off + 2] = 160
                p[off + 3] = 255
            }
        }

        return pb
    }

    static func drawDisc(_ p: UnsafeMutablePointer<UInt8>,
                         _ bpr: Int,
                         _ w: Int, _ h: Int,
                         cx: Int, cy: Int, r: Int,
                         color: (UInt8, UInt8, UInt8, UInt8)) {
        for dy in -r...r {
            for dx in -r...r {
                if dx * dx + dy * dy > r * r { continue }
                let px = cx + dx
                let py = cy + dy
                guard px >= 0, px < w, py >= 0, py < h else { continue }
                let off = py * bpr + px * 4
                p[off + 0] = color.0
                p[off + 1] = color.1
                p[off + 2] = color.2
                p[off + 3] = color.3
            }
        }
    }
}
