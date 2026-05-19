import Foundation
import CoreVideo
import CryptoKit
import MirrorMeshCore

// Per-session ephemeral Ed25519 signer. The private key never leaves the process.
// Why ephemeral: long-term identity keys are out of scope for v0.1.0; each session
// publishes its own public key in the manifest, binding signatures to that session only.
public final class FrameSigner: @unchecked Sendable {
    private let lock = NSLock()
    private let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Data

    public init() {
        let key = Curve25519.Signing.PrivateKey()
        self.privateKey = key
        self.publicKey = key.publicKey.rawRepresentation
    }

    public func sign(_ frame: RenderedFrame, contentDigest: Data) -> Data {
        var message = Data()
        message.reserveCapacity(8 + 8 + contentDigest.count)
        var frameID = frame.frameID.value.littleEndian
        var ts = frame.hostTimeNs.littleEndian
        withUnsafeBytes(of: &frameID) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { message.append(contentsOf: $0) }
        message.append(contentDigest)
        lock.lock(); defer { lock.unlock() }
        // try? is fine: CryptoKit's sign(_:) only throws on malformed input — and we control the bytes.
        guard let sig = try? privateKey.signature(for: message) else { return Data() }
        return sig
    }

    public func contentDigest(of frame: RenderedFrame) -> Data {
        PixelBufferDigest.sha256(of: frame.pixelBuffer)
    }

    public func signManifest(_ canonicalJSON: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let sig = try? privateKey.signature(for: canonicalJSON) else { return Data() }
        return sig
    }
}

enum PixelBufferDigest {
    static func sha256(of pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Data() }
        // Pixel buffers can be padded; hash only the active 4-byte-per-pixel BGRA region per row
        // so the digest is independent of row-stride differences across allocators.
        let rowBytes = width * 4
        var hasher = SHA256()
        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
            let buf = UnsafeRawBufferPointer(start: rowPtr, count: rowBytes)
            hasher.update(bufferPointer: buf)
        }
        return Data(hasher.finalize())
    }
}
