import Foundation
import CoreMediaIO
import CoreVideo
import CoreMedia

/// Bridges the XPC frame channel into the CMIO stream's sample buffer queue.
///
/// On `startStream`, we publish a `MachServiceListener` so the main app can connect
/// over XPC and call `pushFrame(_:reply:)`. Each incoming payload is converted to a
/// `CMSampleBuffer` and handed to the OS via `stream.send(_:discontinuity:hostTimeInNanoseconds:)`.
final class MirrorMeshVirtualCameraStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private weak var device: CMIOExtensionDevice?

    private var xpcListener: XPCFrameListener?
    private var running = false

    init(localizedName: String,
         streamID: UUID,
         streamFormat: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice) {
        self.format = streamFormat
        self.device = device
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: 30)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // Single fixed format; nothing to set today.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard !running else { return }
        running = true
        // Why: only spin the XPC listener while a client is consuming frames; otherwise the
        // main app's encoder spins for nothing and burns power.
        let listener = XPCFrameListener { [weak self] payload in
            self?.handle(payload)
        }
        listener.start()
        xpcListener = listener
    }

    func stopStream() throws {
        running = false
        xpcListener?.stop()
        xpcListener = nil
    }

    // MARK: - Frame ingestion

    private func handle(_ payload: VirtualCameraFramePayload) {
        guard running else { return }
        guard let pb = makePixelBuffer(from: payload) else { return }
        guard let sample = makeSampleBuffer(pb: pb, hostTimeNs: payload.hostTimeNs) else { return }
        stream.send(sample,
                    discontinuity: [],
                    hostTimeInNanoseconds: payload.hostTimeNs)
    }

    private func makePixelBuffer(from p: VirtualCameraFramePayload) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        // Why: copying the bytes into a fresh CVPixelBuffer keeps the lifetime contract
        // with CMIO simple (we own the buffer until the OS releases the sample).
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            p.width, p.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        guard CVPixelBufferLockBaseAddress(buf, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(buf)
        p.pixels.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            // Row-by-row copy handles src/dst stride mismatch (CVPixelBuffer may pad rows).
            for row in 0..<p.height {
                memcpy(
                    dst.advanced(by: row * dstStride),
                    src.advanced(by: row * p.bytesPerRow),
                    min(p.bytesPerRow, dstStride)
                )
            }
        }
        return buf
    }

    private func makeSampleBuffer(pb: CVPixelBuffer, hostTimeNs: UInt64) -> CMSampleBuffer? {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }
}

// MARK: - XPC listener (inside the extension)

/// Lightweight `NSXPCListener` wrapper. We register on the Mach service name the
/// `Info.plist` advertises (`CMIOExtensionMachServiceName`) so the host app's
/// `VirtualCameraXPCClient` can connect.
final class XPCFrameListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let onFrame: (VirtualCameraFramePayload) -> Void
    private var listener: NSXPCListener?

    init(onFrame: @escaping (VirtualCameraFramePayload) -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        // The CMIO extension publishes its Mach service automatically via Info.plist;
        // we attach the per-process listener to that same name.
        let l = NSXPCListener(machServiceName: "ai.mirrormesh.VirtualCamera")
        l.delegate = self
        l.resume()
        listener = l
    }

    func stop() {
        listener?.invalidate()
        listener = nil
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: VirtualCameraXPCProtocol.self)
        let exported = ExportedXPC(onFrame: onFrame)
        conn.exportedObject = exported
        conn.resume()
        return true
    }

    /// The object the main app actually calls into over XPC.
    final class ExportedXPC: NSObject, VirtualCameraXPCProtocol {
        let onFrame: (VirtualCameraFramePayload) -> Void
        init(onFrame: @escaping (VirtualCameraFramePayload) -> Void) {
            self.onFrame = onFrame
        }

        func pushFrame(_ data: Data, reply: @escaping (Bool) -> Void) {
            do {
                let payload = try VirtualCameraWire.decode(data)
                onFrame(payload)
                reply(true)
            } catch {
                reply(false)
            }
        }

        func stop(reply: @escaping () -> Void) {
            reply()
        }
    }
}
