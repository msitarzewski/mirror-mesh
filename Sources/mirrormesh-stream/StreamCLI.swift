import Foundation
import CoreVideo
import MirrorMeshCore
import MirrorMeshStream
@preconcurrency import WebRTC

@main
struct StreamCLI {
    enum Mode: String { case sender, receiver, local }

    struct Scenario: Decodable {
        var name: String
        var width: Int
        var height: Int
        var fps: Int
        var frames: Int
    }

    static func main() async {
        let args = CommandLine.arguments
        let mode = arg("--mode", args: args).flatMap(Mode.init(rawValue:)) ?? .local
        let scenarioPath = arg("--scenario", args: args)
        let outDirPath = arg("--out", args: args) ?? "bench/out/stream_recv"
        let outDir = URL(fileURLWithPath: outDirPath)

        do {
            switch mode {
            case .local:    try await runLocal(scenarioPath: scenarioPath, outDir: outDir)
            case .sender:   try await runSender(scenarioPath: scenarioPath)
            case .receiver: try await runReceiver(outDir: outDir)
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - local loop

    static func runLocal(scenarioPath: String?, outDir: URL) async throws {
        let scenario = try loadScenario(scenarioPath ?? "bench/scenarios/stream.json")
        print("mirrormesh-stream \(MirrorMeshCore.version) — mode=local")
        print("scenario:   \(scenario.name)")
        print("resolution: \(scenario.width)x\(scenario.height)@\(scenario.fps)")
        print("frames:     \(scenario.frames)")
        print("out:        \(outDir.path)")

        // Generate procedural frames; measure pipeline-only baseline + sender-attached latency.
        let baseline = generateProceduralFrames(count: scenario.frames,
                                                width: scenario.width,
                                                height: scenario.height,
                                                fps: scenario.fps)

        let sender = WebRTCSender()
        let receiver = WebRTCReceiver(outputDirectory: outDir, dumpEveryN: 1)

        // Why: with no STUN servers configured, both ends will emit host candidates;
        // we plumb them through directly so ICE can complete on loopback.
        sender.onLocalIceCandidate = { [weak receiver] cand in receiver?.addRemoteIceCandidate(cand) }
        receiver.onLocalIceCandidate = { [weak sender] cand in sender?.addRemoteIceCandidate(cand) }

        let offer = try await sender.createOffer()
        let answer = try await receiver.setRemoteOffer(offer)
        try await sender.setRemoteAnswer(answer)

        guard let videoSection = offer.sdp.range(of: "m=video") else {
            throw CLIError.message("offer SDP is missing a video media section")
        }
        _ = videoSection

        // Drive frames at the scenario fps, measure per-frame append latency.
        let frameIntervalNs = UInt64(1_000_000_000 / max(1, scenario.fps))
        var sendLatencies: [Double] = []
        sendLatencies.reserveCapacity(baseline.count)

        for frame in baseline {
            let t0 = MirrorMeshCore.hostTimeNs()
            sender.append(frame)
            let t1 = MirrorMeshCore.hostTimeNs()
            sendLatencies.append(Double(t1 &- t0) / 1_000_000)
            try await Task.sleep(nanoseconds: frameIntervalNs)
        }

        // Why: encoder + jitter buffer hold frames briefly after the last append.
        try await Task.sleep(nanoseconds: 750_000_000)

        sender.stop()
        receiver.stop()

        let sorted = sendLatencies.sorted()
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        print("")
        print(String(format: "append latency  P50: %.3f ms   P95: %.3f ms", p50, p95))
        print("frames sent:     \(baseline.count)")
        print("frames received: \(receiver.framesReceived)")
        let pngs = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }) ?? []
        print("frames dumped:   \(pngs.count)")
    }

    // MARK: - sender

    static func runSender(scenarioPath: String?) async throws {
        let scenario = try loadScenario(scenarioPath ?? "bench/scenarios/stream.json")
        let sender = WebRTCSender()
        let offer = try await sender.createOffer()
        FileHandle.standardError.write(Data("---BEGIN OFFER---\n".utf8))
        print(offer.sdp)
        FileHandle.standardError.write(Data("---END OFFER--- (paste answer SDP then EOF)\n".utf8))

        let answerSDP = readAllStdin()
        let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await sender.setRemoteAnswer(answer)

        let frames = generateProceduralFrames(count: scenario.frames,
                                              width: scenario.width,
                                              height: scenario.height,
                                              fps: scenario.fps)
        let interval = UInt64(1_000_000_000 / max(1, scenario.fps))
        for f in frames {
            sender.append(f)
            try await Task.sleep(nanoseconds: interval)
        }
        sender.stop()
    }

    // MARK: - receiver

    static func runReceiver(outDir: URL) async throws {
        let receiver = WebRTCReceiver(outputDirectory: outDir, dumpEveryN: 1)
        FileHandle.standardError.write(Data("paste offer SDP then EOF...\n".utf8))
        let offerSDP = readAllStdin()
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        let answer = try await receiver.setRemoteOffer(offer)
        FileHandle.standardError.write(Data("---BEGIN ANSWER---\n".utf8))
        print(answer.sdp)
        FileHandle.standardError.write(Data("---END ANSWER---\n".utf8))
        // Run until SIGINT.
        try await Task.sleep(nanoseconds: 60_000_000_000)
        receiver.stop()
    }

    // MARK: - helpers

    enum CLIError: Error, CustomStringConvertible {
        case message(String)
        var description: String { switch self { case .message(let s): return s } }
    }

    static func arg(_ name: String, args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func loadScenario(_ path: String) throws -> Scenario {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Scenario.self, from: data)
    }

    static func readAllStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }

    /// Procedurally-generated BGRA frames wrapped as WatermarkedFrames so we can
    /// exercise the sender without running the full Pipeline (which is unavailable
    /// in tests without a real Metal device on CI).
    static func generateProceduralFrames(count: Int, width: Int, height: Int, fps: Int) -> [WatermarkedFrame] {
        StreamProceduralSource.generate(count: count, width: width, height: height, fps: fps)
    }
}

/// Synthesizes BGRA pixel buffers locally so the CLI doesn't need the Metal renderer.
enum StreamProceduralSource {
    static func generate(count: Int, width: Int, height: Int, fps: Int) -> [WatermarkedFrame] {
        var out: [WatermarkedFrame] = []
        out.reserveCapacity(count)
        let stride = 1_000_000_000 / max(1, fps)
        let base = MirrorMeshCore.hostTimeNs()
        for i in 0..<count {
            guard let pb = makeBGRA(width: width, height: height, phase: i) else { continue }
            let ts = base &+ UInt64(i * stride)
            out.append(WatermarkedFrame(
                frameID: FrameID(UInt64(i + 1)),
                hostTimeNs: ts,
                pixelBuffer: pb,
                width: width,
                height: height,
                signature: Data(),
                contentDigest: Data()
            ))
        }
        return out
    }

    private static func makeBGRA(width: Int, height: Int, phase: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let r = UInt8((phase * 5) % 256)
        let g = UInt8((phase * 7) % 256)
        let b = UInt8((phase * 11) % 256)
        for y in 0..<height {
            let row = ptr.advanced(by: y * bpr)
            for x in 0..<width {
                let px = row.advanced(by: x * 4)
                px[0] = b ^ UInt8(x & 0xff)
                px[1] = g ^ UInt8(y & 0xff)
                px[2] = r
                px[3] = 255
            }
        }
        return buf
    }
}
