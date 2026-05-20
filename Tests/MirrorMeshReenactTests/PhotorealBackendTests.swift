import Testing
import Foundation
import CryptoKit
import CoreVideo
@testable import MirrorMeshReenact
@testable import MirrorMeshWatermark

@Suite("PhotorealBackend")
struct PhotorealBackendTests {

    // MARK: - Identity gate

    @Test func unverifiedIdentityIsRejected() async throws {
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

        await #expect(throws: PhotorealBackend.LoadError.self) {
            _ = try await PhotorealBackend(
                identity: identity,
                pngBytes: png,
                runtimeVersion: "0.6.0",
                modelsDir: tmp
            )
        }
    }

    @Test func stylizedNonHumanSchemeIsRejected() async throws {
        // A *valid* signed bundle whose scheme is .stylizedNonHuman — the photoreal
        // backend explicitly refuses these (they go through FaceReenactor's procedural
        // path). The error type is .identityNotVerified.
        let signed = try makeSignedBundle(scheme: .stylizedNonHuman)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: PhotorealBackend.LoadError.self) {
            _ = try await PhotorealBackend(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0",
                modelsDir: tmp
            )
        }
    }

    // MARK: - Models gate (default kind = LivePortrait per ADR-0015)

    @Test func missingModelsDirThrowsForLivePortraitByDefault() async throws {
        // Valid, signed, photoreal-eligible identity — but no .mlpackage files on disk.
        // The default `kind:` is `.liveportrait` (ADR-0015), so the surfaced error must
        // (a) carry the LivePortrait kind and (b) name LivePortrait's expected files in
        // its description so the SwiftUI panel can render the right "download" CTA.
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        do {
            _ = try await PhotorealBackend(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0",
                modelsDir: emptyDir
            )
            Issue.record("expected PhotorealBackend init to throw .modelsMissing, but it succeeded")
        } catch let PhotorealBackend.LoadError.modelsMissing(reportedDir, reportedKind) {
            #expect(reportedDir.path == emptyDir.path)
            #expect(reportedKind == .liveportrait)
            // Description must name the LivePortrait files so the user-facing CTA is
            // accurate. We assert the specific file names rather than the whole string
            // to avoid coupling the test to wording.
            let desc = PhotorealBackend.LoadError.modelsMissing(reportedDir, reportedKind).description
            #expect(desc.contains("appearance_v1.mlpackage"))
            #expect(desc.contains("warp_v1.mlpackage"))
            #expect(desc.contains("liveportrait_to_coreml.py"))
        } catch {
            Issue.record("expected .modelsMissing, got \(type(of: error)): \(error)")
        }
    }

    @Test func missingModelsDirThrowsForFOMM() async throws {
        // Explicit `kind: .fomm` — the FOMM fallback path. Same gate behavior, but the
        // surfaced error names the FOMM file set + the FOMM conversion script.
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photoreal-empty-fomm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        do {
            _ = try await PhotorealBackend(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0",
                modelsDir: emptyDir,
                kind: .fomm
            )
            Issue.record("expected PhotorealBackend init to throw .modelsMissing, but it succeeded")
        } catch let PhotorealBackend.LoadError.modelsMissing(reportedDir, reportedKind) {
            #expect(reportedDir.path == emptyDir.path)
            #expect(reportedKind == .fomm)
            let desc = PhotorealBackend.LoadError.modelsMissing(reportedDir, reportedKind).description
            #expect(desc.contains("keypoint_v1.mlpackage"))
            #expect(desc.contains("generator_v1.mlpackage"))
            #expect(desc.contains("fomm_to_coreml.py"))
            #expect(!desc.contains("appearance_v1.mlpackage"))
        } catch {
            Issue.record("expected .modelsMissing, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Kind-selection — the file lists differ

    @Test func modelFileNamesAreKindSpecific() throws {
        // The contract between this backend and the two conversion scripts.
        // LivePortrait splits the forward pass four ways (appearance cached + motion +
        // warp + generator); FOMM splits three ways (keypoint + motion + generator).
        let lp = PhotorealBackend.modelFileNames(for: .liveportrait)
        let fomm = PhotorealBackend.modelFileNames(for: .fomm)

        #expect(lp.count == 4)
        #expect(lp.contains("appearance_v1.mlpackage"))
        #expect(lp.contains("motion_v1.mlpackage"))
        #expect(lp.contains("warp_v1.mlpackage"))
        #expect(lp.contains("generator_v1.mlpackage"))

        #expect(fomm.count == 3)
        #expect(fomm.contains("keypoint_v1.mlpackage"))
        #expect(fomm.contains("motion_v1.mlpackage"))
        #expect(fomm.contains("generator_v1.mlpackage"))
        #expect(!fomm.contains("appearance_v1.mlpackage"))
        #expect(!fomm.contains("warp_v1.mlpackage"))
    }

    // MARK: - Stub behavior (will change when real conversion lands)

    // NOTE: this test documents the *current stub*. When M56-photoreal-inference lands,
    // the output buffer should then differ from the input. Until then, the stub is a
    // deterministic pass-through so the surrounding pipeline integration can be tested
    // independently of the model.
    //
    // We can't exercise reenact() without a constructed backend, and we can't construct
    // one without the .mlpackage files. So this test is *currently disabled* via the
    // `.disabled` trait until the conversion has been run — flipping the trait off is
    // the smallest test edit a contributor needs to make when they land their first set
    // of converted weights. This is deliberately the inverse of "always-skip": when
    // skipped, the runner prints a clear reminder.
    @Test(
        "stub reenact passes driver image through unchanged (enabled once models are converted)",
        .disabled("Requires LivePortrait .mlpackage set under MIRRORMESH_LIVEPORTRAIT_MODELS_DIR (or FOMM via MIRRORMESH_FOMM_MODELS_DIR)")
    )
    func stubPassesThroughDriverImage() async throws {
        let env = ProcessInfo.processInfo.environment
        let (modelsDir, kind): (URL, PhotorealBackendKind)
        if let lpPath = env["MIRRORMESH_LIVEPORTRAIT_MODELS_DIR"] {
            modelsDir = URL(fileURLWithPath: lpPath)
            kind = .liveportrait
        } else if let fommPath = env["MIRRORMESH_FOMM_MODELS_DIR"] {
            modelsDir = URL(fileURLWithPath: fommPath)
            kind = .fomm
        } else {
            return
        }
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let backend = try await PhotorealBackend(
            identity: signed.identity,
            pngBytes: signed.png,
            runtimeVersion: "0.6.0",
            modelsDir: modelsDir,
            kind: kind
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
