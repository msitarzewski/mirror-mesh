import Foundation
import CryptoKit
@testable import MirrorMeshWatermark

/// Shared helpers for the reenactor test suites. Mirrors the pattern in
/// `Tests/MirrorMeshWatermarkTests/ConsentedIdentityTests.swift` so the gate
/// is exercised the same way the watermark suite exercises it.
enum TestBundle {
    struct Signed {
        var identity: ConsentedIdentity
        var png: Data
    }

    static func makeSigned(
        scope: String = "v0.6+",
        scheme: IdentityScheme = .stylizedNonHuman
    ) throws -> Signed {
        // Synthetic "PNG" — bytes for hashing only.
        let png = Data(repeating: 0x37, count: 512)
        let pngHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()

        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: "Stylized Puppet Alpha",
            scheme: scheme,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: scope,
            issuer_public_key_b64: pubB64
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var clearable = identity
        clearable.signature_b64 = nil
        var message = try enc.encode(clearable)
        message.append(png)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()

        return Signed(identity: identity, png: png)
    }
}
