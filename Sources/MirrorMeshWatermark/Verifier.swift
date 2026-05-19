import Foundation
import CoreVideo
import CryptoKit

public final class Verifier: Sendable {
    public static func verifyFrame(buffer: CVPixelBuffer,
                                   signature: Data,
                                   expectedFrameID: UInt64,
                                   expectedHostTimeNs: UInt64,
                                   publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        let digest = PixelBufferDigest.sha256(of: buffer)
        var message = Data()
        message.reserveCapacity(8 + 8 + digest.count)
        var fid = expectedFrameID.littleEndian
        var ts = expectedHostTimeNs.littleEndian
        withUnsafeBytes(of: &fid) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { message.append(contentsOf: $0) }
        message.append(digest)
        return pk.isValidSignature(signature, for: message)
    }

    public static func verifyDigest(_ digest: Data,
                                    signature: Data,
                                    expectedFrameID: UInt64,
                                    expectedHostTimeNs: UInt64,
                                    publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        var message = Data()
        var fid = expectedFrameID.littleEndian
        var ts = expectedHostTimeNs.littleEndian
        withUnsafeBytes(of: &fid) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { message.append(contentsOf: $0) }
        message.append(digest)
        return pk.isValidSignature(signature, for: message)
    }

    public static func verifyManifest(_ manifest: SessionManifest) -> Bool {
        guard let sigB64 = manifest.manifest_signature_b64,
              let signature = Data(base64Encoded: sigB64),
              let pubKey = Data(base64Encoded: manifest.public_key_b64) else {
            return false
        }
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKey) else { return false }
        // Verification re-canonicalizes the manifest with signature blanked, exactly matching
        // what ManifestWriter signs at finalize time.
        var copy = manifest
        copy.manifest_signature_b64 = nil
        guard let canonical = try? ManifestCodec.canonicalEncode(copy) else { return false }
        return pk.isValidSignature(signature, for: canonical)
    }
}
