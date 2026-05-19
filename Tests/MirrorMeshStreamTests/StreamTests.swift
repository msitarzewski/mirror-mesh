import Testing
import Foundation
import CoreVideo
import MirrorMeshCore
@testable import MirrorMeshStream
import WebRTC

@Suite("MirrorMeshStream")
struct StreamTests {

    // Disabled in CI: WebRTC peer-connection construction begins ICE candidate gathering
    // immediately, which doesn't terminate cleanly in headless / no-network sandboxes.
    // The offer SDP shape is exercised manually via `mirrormesh-stream --mode local`.
    @Test(.disabled("ICE gathering doesn't terminate in headless test runners"))
    func senderOfferHasVideoSection() async throws {
        let sender = WebRTCSender()
        let offer = try await sender.createOffer()
        #expect(offer.type == .offer)
        #expect(offer.sdp.contains("m=video"))
        sender.stop()
    }

    // Disabled in CI / headless: real ICE negotiation needs network setup that the unit-test
    // sandbox doesn't provide. The local-loop CLI (`mirrormesh-stream --mode local`) exercises
    // the same code path interactively. Re-enable when a deterministic SDP signaling shim lands.
    @Test(.disabled("real ICE doesn't terminate in headless test runners"))
    func localLoopReceivesMostFrames() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmstream-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sender = WebRTCSender()
        let receiver = WebRTCReceiver(outputDirectory: tmp, dumpEveryN: 1)
        sender.onLocalIceCandidate = { [weak receiver] c in receiver?.addRemoteIceCandidate(c) }
        receiver.onLocalIceCandidate = { [weak sender] c in sender?.addRemoteIceCandidate(c) }

        let offer = try await sender.createOffer()
        let answer = try await receiver.setRemoteOffer(offer)
        try await sender.setRemoteAnswer(answer)

        let frames = makeFrames(count: 30, width: 320, height: 240, fps: 30)
        for f in frames {
            sender.append(f)
            // Why: real-time pacing so libwebrtc's encoder + jitter buffer behave normally.
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        sender.stop()
        receiver.stop()

        let pngs = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }) ?? []
        // Why: lossy realtime path; ≥25 of 30 is the documented success bar.
        #expect(pngs.count >= 25, "expected ≥25 PNG dumps, got \(pngs.count); received=\(receiver.framesReceived)")
    }

    // MARK: - helpers

    private func makeFrames(count: Int, width: Int, height: Int, fps: Int) -> [WatermarkedFrame] {
        var out: [WatermarkedFrame] = []
        out.reserveCapacity(count)
        let stride = UInt64(1_000_000_000 / max(1, fps))
        let base = MirrorMeshCore.hostTimeNs()
        for i in 0..<count {
            guard let pb = bgra(width: width, height: height, phase: i) else { continue }
            out.append(WatermarkedFrame(
                frameID: FrameID(UInt64(i + 1)),
                hostTimeNs: base &+ UInt64(i) * stride,
                pixelBuffer: pb,
                width: width,
                height: height,
                signature: Data(),
                contentDigest: Data()
            ))
        }
        return out
    }

    private func bgra(width: Int, height: Int, phase: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = ptr.advanced(by: y * bpr)
            for x in 0..<width {
                let px = row.advanced(by: x * 4)
                px[0] = UInt8((x + phase) & 0xff)
                px[1] = UInt8((y + phase) & 0xff)
                px[2] = UInt8((phase * 3) & 0xff)
                px[3] = 255
            }
        }
        return buf
    }
}
