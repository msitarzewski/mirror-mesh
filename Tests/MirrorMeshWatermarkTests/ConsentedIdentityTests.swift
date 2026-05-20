import Testing
import Foundation
import CryptoKit
@testable import MirrorMeshWatermark

@Suite("ConsentedIdentity")
struct ConsentedIdentityTests {

    @Test func signedBundleVerifies() throws {
        let signed = try makeSignedBundle()
        try ConsentedIdentityVerifier.verify(
            identity: signed.identity,
            pngBytes: signed.png,
            runtimeVersion: "0.6.0"
        )
        // No throw == pass.
    }

    @Test func tamperedPngRejected() throws {
        var signed = try makeSignedBundle()
        signed.png.append(0xFF)
        #expect(throws: ConsentedIdentityError.self) {
            try ConsentedIdentityVerifier.verify(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"
            )
        }
    }

    @Test func tamperedHeaderRejected() throws {
        var signed = try makeSignedBundle()
        signed.identity.display_name = "Different Person"
        #expect(throws: ConsentedIdentityError.self) {
            try ConsentedIdentityVerifier.verify(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"
            )
        }
    }

    @Test func outOfScopeRejected() throws {
        var signed = try makeSignedBundle(scope: "v0.9+")  // requires v0.9 minimum
        // Re-sign because we changed the header.
        signed = try resign(signed)
        #expect(throws: ConsentedIdentityError.self) {
            try ConsentedIdentityVerifier.verify(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"   // older than bundle's minimum
            )
        }
    }

    @Test func bundleWriteAndReadRoundtrip() throws {
        let signed = try makeSignedBundle()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmid-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConsentedIdentityBundle.write(identity: signed.identity, pngBytes: signed.png, to: dir)
        let (read, png) = try ConsentedIdentityBundle.read(from: dir)
        #expect(read.identity_id == signed.identity.identity_id)
        #expect(png == signed.png)
        try ConsentedIdentityVerifier.verify(
            identity: read, pngBytes: png, runtimeVersion: "0.6.0"
        )
    }

    @Test func disclosureHashIsStable() {
        #expect(IdentityConsentText.sha256.count == 64)
        // Re-computing should give the same value — proves it's deterministic.
        let again = ConsentRecord.hashDisclosure(IdentityConsentText.v1)
        #expect(IdentityConsentText.sha256 == again)
    }

    // MARK: - Helpers

    private struct SignedBundle {
        var identity: ConsentedIdentity
        var png: Data
    }

    private func makeSignedBundle(scope: String = "v0.6+") throws -> SignedBundle {
        // Synthetic "PNG" — we don't need it to be a real PNG for the crypto pipeline;
        // it's just bytes that get hashed and concatenated for the signature.
        let png = Data(repeating: 0x42, count: 256)
        let pngHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()

        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: "Test Subject",
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: scope,
            issuer_public_key_b64: pubB64
        )

        // Sign canonical(identity-without-signature) || png.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var clearable = identity
        clearable.signature_b64 = nil
        var message = try enc.encode(clearable)
        message.append(png)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()

        return SignedBundle(identity: identity, png: png)
    }

    private func resign(_ bundle: SignedBundle) throws -> SignedBundle {
        // Helper for tests that mutate the header — they need to re-sign with a fresh key,
        // since the public key in the bundle is what the verifier uses.
        let key = Curve25519.Signing.PrivateKey()
        var identity = bundle.identity
        identity.issuer_public_key_b64 = key.publicKey.rawRepresentation.base64EncodedString()
        identity.signature_b64 = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var message = try enc.encode(identity)
        message.append(bundle.png)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()
        return SignedBundle(identity: identity, png: bundle.png)
    }
}
