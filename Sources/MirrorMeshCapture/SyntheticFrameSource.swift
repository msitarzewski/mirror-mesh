import Foundation
import CoreVideo
import MirrorMeshCore

/// Procedural frame source for headless benchmarks, CI, and the CLI demo.
/// Renders a moving "face" — two eye dots, a nose, an animated mouth arc — so downstream
/// landmark and solver stages have something to bite into.
public actor SyntheticFrameSource: FrameSource {
    private let config: CaptureConfig
    private let pool: PixelBufferPool
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?

    public init(config: CaptureConfig = .benchSmall) {
        self.config = config
        self.pool = PixelBufferPool(width: config.width, height: config.height)
    }

    public func start() async throws -> AsyncStream<CapturedFrame> {
        let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(2)) { cont in
            self.continuation = cont
        }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    public func stop() async {
        task?.cancel()
        continuation?.finish()
        continuation = nil
        task = nil
    }

    private func runLoop() async {
        let frameInterval = UInt64(1_000_000_000 / max(1, config.fps))
        var frameIndex: UInt64 = 0
        while !Task.isCancelled {
            let id = FrameIDGenerator.shared.next()
            let host = MirrorMeshCore.hostTimeNs()
            if let buffer = pool.acquire(),
               let frame = synthesizeFrame(into: buffer, index: frameIndex, id: id, host: host) {
                continuation?.yield(frame)
            }
            frameIndex &+= 1
            try? await Task.sleep(nanoseconds: frameInterval)
        }
    }

    private func synthesizeFrame(into buffer: CVPixelBuffer,
                                 index: UInt64,
                                 id: FrameID,
                                 host: UInt64) -> CapturedFrame? {
        // Signpost so Instruments traces show synthetic capture cost alongside real capture.
        let sp = Signpost.begin(Signpost.capture, frame: id)
        defer { Signpost.end(Signpost.capture, frame: id, id: sp) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)

        // background gradient
        for y in 0..<h {
            for x in 0..<w {
                let off = y * bpr + x * 4
                p[off + 0] = UInt8((x * 255) / w)        // B
                p[off + 1] = UInt8((y * 255) / h)        // G
                p[off + 2] = 80                          // R
                p[off + 3] = 255                         // A
            }
        }

        // animated "face" — eyes, nose, mouth
        let t = Double(index) * 0.05
        let cx = w / 2
        let cy = h / 2
        let s = min(w, h) / 4

        // left eye
        let eyeY = cy - s / 3 + Int(sin(t) * 2)
        drawDisc(p, bpr, w, h, cx: cx - s / 3, cy: eyeY, r: s / 14, color: (40, 40, 40, 255))
        // right eye
        drawDisc(p, bpr, w, h, cx: cx + s / 3, cy: eyeY, r: s / 14, color: (40, 40, 40, 255))
        // nose
        drawDisc(p, bpr, w, h, cx: cx, cy: cy, r: s / 22, color: (200, 180, 160, 255))
        // mouth (arc rendered as filled ellipse opening with sin t)
        let mouthOpenness = Int(Double(s / 6) * (0.6 + 0.4 * sin(t * 1.3)))
        for dy in -mouthOpenness...mouthOpenness {
            let halfW = Int(Double(s / 3) * sqrt(max(0.0, 1.0 - Double(dy * dy) / Double(max(1, mouthOpenness * mouthOpenness)))))
            for dx in -halfW...halfW {
                let px = cx + dx
                let py = cy + s / 3 + dy
                guard px >= 0, px < w, py >= 0, py < h else { continue }
                let off = py * bpr + px * 4
                p[off + 0] = 50
                p[off + 1] = 50
                p[off + 2] = 180
                p[off + 3] = 255
            }
        }

        return CapturedFrame(frameID: id,
                             hostTimeNs: host,
                             pixelBuffer: buffer,
                             width: w,
                             height: h)
    }

    private func drawDisc(_ p: UnsafeMutablePointer<UInt8>,
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
