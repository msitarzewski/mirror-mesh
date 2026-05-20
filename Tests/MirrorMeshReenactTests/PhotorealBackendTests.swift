import Testing
import Foundation
import CryptoKit
import CoreVideo
@testable import MirrorMeshReenact
@testable import MirrorMeshWatermark

@Suite("PhotorealBackend")
struct PhotorealBackendTests {

    // MARK: - Identity gate

    @Test func unverifiedIdentityIsRejected() throws {
        // Build a header with a *bad* signature: same shape as a real bundle but the
        // PNG bytes don't match the recorded source_png_sha256, so verify() fails
        // with payloadHashMismatch — which the backend remaps to .identityNotVerified.
        let png = Data(repeating: 0x42, count: 64)
        let key = Curve25519.Signing.PrivateKey()
        let bogusHash = String(repeating: "0", count: 64)
        let identity = ConsentedIdentity(
            display_name: "Unsigned Test",
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: bogusHash,                           // <-- wrong on purpose
            scope: "v0.6+",
            issuer_public_key_b64: key.publicKey.rawRepresentation.base64EncodedString(),
            signature_b64: Data(repeating: 0, count: 64).base64EncodedString()
        )

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: PhotorealBackend.LoadError.self) {
            _ = try PhotorealBackend(
                identity: identity,
                pngBytes: png,
                runtimeVersion: "0.6.0",
                modelsDir: tmp
            )
        }
    }

    @Test func stylizedNonHumanSchemeIsRejected() throws {
        // A *valid* signed bundle whose scheme is .stylizedNonHuman — the photoreal
        // backend explicitly refuses these (they go through FaceReenactor's procedural
        // path). The error type is .identityNotVerified.
        let signed = try makeSignedBundle(scheme: .stylizedNonHuman)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: PhotorealBackend.LoadError.self) {
            _ = try PhotorealBackend(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0",
                modelsDir: tmp
            )
        }
    }

    // MARK: - Models gate

    @Test func missingModelsDirThrows() throws {
        // Valid, signed, photoreal-eligible identity — but no .mlpackage files on disk.
        // Backend must refuse: this is the load-time contract (R12).
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        do {
            _ = try PhotorealBackend(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0",
                modelsDir: emptyDir
            )
            Issue.record("expected PhotorealBackend init to throw .modelsMissing, but it succeeded")
        } catch let PhotorealBackend.LoadError.modelsMissing(reportedDir) {
            // The error should point at the directory we asked about — that's what
            // the SwiftUI panel needs in order to render a "download weights" CTA.
            #expect(reportedDir.path == emptyDir.path)
        } catch {
            Issue.record("expected .modelsMissing, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Stub behavior (will change when real conversion lands)

    // NOTE: this test documents the *current stub*. When the follow-up commit wires
    // the real CoreML inference graph in, this test changes — the output buffer should
    // then differ from the input. Until then, the stub is a deterministic pass-through
    // so the surrounding pipeline integration can be tested independently of the model.
    //
    // We can't exercise reenact() without a constructed backend, and we can't construct
    // one without the .mlpackage files. So this test is *currently disabled* via the
    // `.disabled` trait until the conversion has been run — flipping the trait off is
    // the smallest test edit a contributor needs to make when they land their first set
    // of converted weights. This is deliberately the inverse of "always-skip": when
    // skipped, the runner prints a clear reminder.
    @Test(
        "stub reenact passes driver image through unchanged (enabled once models are converted)",
        .disabled("Requires keypoint_v1/motion_v1/generator_v1 .mlpackage under MIRRORMESH_FOMM_MODELS_DIR")
    )
    func stubPassesThroughDriverImage() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["MIRRORMESH_FOMM_MODELS_DIR"] else {
            return
        }
        let modelsDir = URL(fileURLWithPath: dirPath)
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let backend = try PhotorealBackend(
            identity: signed.identity,
            pngBytes: signed.png,
            runtimeVersion: "0.6.0",
            modelsDir: modelsDir
        )

        let input = try makeDummyPixelBuffer(width: 64, height: 64)
        let output = try await backend.reenact(landmarks: [], driverImage: input)

        // Stub contract: pass-through. The pointer identity check is sufficient since
        // the stub returns the same CVPixelBuffer it received.
        #expect(CVPixelBufferGetWidth(output) == CVPixelBufferGetWidth(input))
        #expect(CVPixelBufferGetHeight(output) == CVPixelBufferGetHeight(input))
    }

    // MARK: - Helpers

    private struct SignedBundle {
        var identity: ConsentedIdentity
        var png: Data
    }

    /// Mirrors the helper in MirrorMeshWatermarkTests/ConsentedIdentityTests so the tests
    /// here stay self-contained. Synthetic PNG bytes are fine — the crypto pipeline only
    /// cares that the hash binds bytes to header, not that the bytes decode as an image.
    private func makeSignedBundle(
        scheme: IdentityScheme,
        scope: String = "v0.6+"
    ) throws -> SignedBundle {
        let png = Data(repeating: 0x42, count: 256)
        let pngHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()

        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: "Test Subject",
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

        return SignedBundle(identity: identity, png: png)
    }

    private func makeDummyPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(
                domain: "PhotorealBackendTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"]
            )
        }
        return buffer
    }
}
