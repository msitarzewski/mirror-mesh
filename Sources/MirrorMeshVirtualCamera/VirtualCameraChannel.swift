import Foundation
import CoreVideo
import MirrorMeshCore

/// On-wire frame payload: a Codable snapshot of a `WatermarkedFrame`.
///
/// We send raw BGRA bytes plus shape/timing/signature so the receiver can re-wrap
/// into a `CVPixelBuffer` on its side. Watermark provenance survives the hop because
/// the signature was computed pre-serialization over the same pixel bytes.
public struct VirtualCameraFramePayload: Codable, Sendable {
    public let frameID: UInt64
    public let hostTimeNs: UInt64
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// Tightly packed BGRA8 pixel bytes (`bytesPerRow * height`).
    public let pixels: Data
    public let signature: Data
    public let contentDigest: Data

    public init(frameID: UInt64,
                hostTimeNs: UInt64,
                width: Int,
                height: Int,
                bytesPerRow: Int,
                pixels: Data,
                signature: Data,
                contentDigest: Data) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.signature = signature
        self.contentDigest = contentDigest
    }
}

/// XPC vending protocol. The main app calls these on the extension's listener.
///
/// `@objc` because `NSXPCConnection` requires Objective-C-visible protocols and
/// reply blocks. Methods are one-way pushes; the reply block exists only so the
/// caller can backpressure on serialization completion.
@objc public protocol VirtualCameraXPCProtocol {
    /// Push one frame into the extension. `data` is a `JSONEncoder`-encoded
    /// `VirtualCameraFramePayload`. Reply fires when the extension has accepted it.
    func pushFrame(_ data: Data, reply: @escaping (Bool) -> Void)

    /// Tell the extension to stop publishing frames. Sent on pipeline shutdown.
    func stop(reply: @escaping () -> Void)
}

/// Wire-format helpers used by both ends. Kept here so a future binary encoding
/// (e.g., raw `NSData` slabs) only needs to be added in one place.
public enum VirtualCameraWire {
    /// JSON is verbose but lets us evolve the payload without versioning code right now.
    /// Swap to a length-prefixed binary format if profiling shows this is the bottleneck
    /// at 30/60 fps (BGRA at 640x360 is ~900 KB; at 1080p it's ~8 MB — JSON adds ~33% via base64).
    public static func encode(_ payload: VirtualCameraFramePayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decode(_ data: Data) throws -> VirtualCameraFramePayload {
        try JSONDecoder().decode(VirtualCameraFramePayload.self, from: data)
    }

    /// Copy a `WatermarkedFrame`'s pixel bytes into a tightly packed Data blob.
    /// Returns `nil` if the pixel buffer cannot be locked or has an unsupported format.
    public static func packPixels(from frame: WatermarkedFrame) -> (pixels: Data, bytesPerRow: Int)? {
        let pb = frame.pixelBuffer
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        // Why: a single contiguous copy keeps the wire format trivial. The extension can
        // reconstruct a CVPixelBuffer from this slab via CVPixelBufferCreateWithBytes.
        let pixels = Data(bytes: base, count: stride * height)
        return (pixels, stride)
    }

    /// Make a Codable payload from a `WatermarkedFrame`. Returns `nil` if the pixel
    /// buffer cannot be read.
    public static func makePayload(from frame: WatermarkedFrame) -> VirtualCameraFramePayload? {
        guard let (pixels, bpr) = packPixels(from: frame) else { return nil }
        return VirtualCameraFramePayload(
            frameID: frame.frameID.value,
            hostTimeNs: frame.hostTimeNs,
            width: frame.width,
            height: frame.height,
            bytesPerRow: bpr,
            pixels: pixels,
            signature: frame.signature,
            contentDigest: frame.contentDigest
        )
    }
}

/// Client side of the XPC channel. Lives in the main app's `Pipeline`.
///
/// We connect lazily on first frame push; if the extension isn't installed yet
/// (`isInstallable == false` or user hasn't approved), every push is a no-op.
/// That keeps the unsigned dev build crash-free.
public final class VirtualCameraXPCClient: @unchecked Sendable {
    private let machServiceName: String
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    public init(machServiceName: String = MirrorMeshVirtualCamera.machServiceName) {
        self.machServiceName = machServiceName
    }

    /// Push a frame. Best-effort; failures are swallowed so the pipeline never blocks.
    public func push(_ frame: WatermarkedFrame) {
        guard let payload = VirtualCameraWire.makePayload(from: frame),
              let data = try? VirtualCameraWire.encode(payload) else { return }
        let proxy = remoteProxy()
        proxy?.pushFrame(data) { _ in /* fire-and-forget */ }
    }

    public func stop() {
        let proxy = remoteProxy()
        proxy?.stop { /* fire-and-forget */ }
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    // Why: lazy connect so we don't trip the XPC framework when the extension is
    // not yet installed; if the proxy is nil, `push` is a silent no-op.
    private func remoteProxy() -> VirtualCameraXPCProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            // .privileged: extension runs as a launchd-managed system extension.
            let c = NSXPCConnection(machServiceName: machServiceName, options: [.privileged])
            c.remoteObjectInterface = NSXPCInterface(with: VirtualCameraXPCProtocol.self)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.connection = nil
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? VirtualCameraXPCProtocol
    }
}
