import Testing
import Foundation
import CryptoKit
import CoreVideo
@testable import MirrorMeshOutput
@testable import MirrorMeshReenact
@testable import MirrorMeshWatermark
import MirrorMeshCore

@Suite("PhotorealStage")
struct PhotorealStageTests {

    // MARK: - setIdentity gate

    /// When the modelsDir is empty, `PhotorealStage.setIdentity` rethrows the
    /// `PhotorealBackend.LoadError.modelsMissing` that the backend's init surfaces.
    /// The R1 scheme gate is still satisfied (selfAsSource), so the failure is
    /// pinned on the missing weights, not on the identity. The stage's slot stays
    /// unloaded after the throw.
    @Test func setIdentityWithoutModelsDirThrows() async throws {
        let signed = try makeSignedBundle(scheme: .selfAsSource)
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-photorealstage-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let stage = PhotorealStage()
        do {
            try await stage.setIdentity(
                signed.identity,
                pngBytes: signed.png,
                modelsDir: emptyDir,
                runtimeVersion: "0.6.0"
            )
            Issue.record("expected setIdentity to throw on missing modelsDir, but it succeeded")
        } catch is PhotorealBackend.LoadError {
            // Expected — modelsMissing carries through from the backend init.
            let active = await stage.hasIdentity
            #expect(active == false, "stage slot must stay nil after a failed setIdentity")
        } catch {
            Issue.record("expected PhotorealBackend.LoadError, got \(type(of: error)): \(error)")
        }
    }

    /// R1: stylized-non-human schemes are refused at the stage layer BEFORE the
    /// backend init runs. This means we don't even touch the modelsDir or attempt
    /// to compile any mlpackage — a misconfigured Settings panel can't sneak a
    /// stylized identity through to a photoreal generator.
    @Test func stylizedNonHumanIdentityRejected() async throws {
        let signed = try makeSignedBundle(scheme: .stylizedNonHuman)
        // Use a directory that doesn't even exist — proves the scheme gate runs
        // first; if the gate were skipped, we'd see a modelsMissing error instead.
        let bogusDir = URL(fileURLWithPath: "/nonexistent-dir-for-test-\(UUID().uuidString)")

        let stage = PhotorealStage()
        do {
            try await stage.setIdentity(
                signed.identity,
                pngBytes: signed.png,
                modelsDir: bogusDir,
                runtimeVersion: "0.6.0"
            )
            Issue.record("expected setIdentity to reject stylizedNonHuman scheme, but it succeeded")
        } catch let PhotorealBackend.LoadError.identityNotVerified {
            // Expected — R1 gate.
            let active = await stage.hasIdentity
            #expect(active == false)
        } catch {
            Issue.record("expected .identityNotVerified, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - apply behavior

    /// `apply` is pass-through (returns nil) when no identity is loaded. The
    /// pipeline interprets nil as "keep the original captured frame", so this
    /// path is the normal state when the operator hasn't loaded an identity
    /// or hasn't enabled photoreal.
    @Test func applyPassesThroughWhenNoIdentity() async throws {
        let stage = PhotorealStage()
        let captured = try makeDummyCapturedFrame(width: 64, height: 64)
        let out = await stage.apply(captured)
        #expect(out == nil, "apply must return nil when no backend is loaded")
    }

    // MARK: - CapturedFrame substitution helper

    /// The `with(pixelBuffer:)` extension keeps `frameID`/`hostTimeNs`/`width`/`height`
    /// intact while swapping just the pixel buffer. This is the contract Pipeline
    /// relies on so substituted frames still attribute to the original capture
    /// event in telemetry, signposts, and the manifest.
    @Test func capturedFrameWithPixelBufferPreservesMetadata() throws {
        let original = try makeDummyCapturedFrame(width: 128, height: 96)
        let replacement = try makeDummyPixelBuffer(width: 128, height: 96)
        let substituted = original.with(pixelBuffer: replacement)
        #expect(substituted.frameID == original.frameID)
        #expect(substituted.hostTimeNs == original.hostTimeNs)
        #expect(substituted.width == original.width)
        #expect(substituted.height == original.height)
        // Pointer identity confirms the swap — Foundation doesn't override == for
        // CVPixelBuffer; we compare by object identity via `===` on the
        // CFTypeRef-bridged reference.
        #expect(substituted.pixelBuffer !== original.pixelBuffer)
        #expect(substituted.pixelBuffer === replacement)
    }

    // MARK: - Pipeline integration: existing behavior unchanged when no photoreal opts

    /// PipelineOptions defaults still hold — adding `photorealModelsDir` (default nil)
    /// must not break any existing field, especially the ones the SwiftUI app and
    /// bench tooling depend on. This is the "do no harm" test: PipelineOptions is
    /// the public-facing config struct, and changing its defaults silently would
    /// break callers across the repo.
    @Test func pipelineOptionsDefaultsUnchangedWhenPhotorealOff() {
        let opts = PipelineOptions()
        #expect(opts.photorealModelsDir == nil)
        #expect(opts.captureWidth == 640)
        #expect(opts.captureHeight == 360)
        #expect(opts.fps == 30)
        #expect(opts.voiceEnabled == false)
        #expect(opts.translationEnabled == false)
        #expect(opts.consentedIdentity == nil)
        #expect(opts.consentedIdentityPNG == nil)
    }

    /// Constructing a `Pipeline` with no photoreal options must succeed without
    /// touching `modelsDir`, even when an empty `consentedIdentity/PNG` are also
    /// absent. This proves the photoreal path is fully opt-in.
    @Test func pipelineRunsWithoutPhotorealOptions() async throws {
        let opts = PipelineOptions(mode: .synthetic, maxFrames: 0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let pipeline = Pipeline(options: opts, manifestURL: manifestURL, jsonlURL: nil)
        // Just constructing + reading the options is the smoke test. We don't run()
        // because that pulls in capture/vision/render — the goal here is that
        // PipelineOptions accepts the new field without disturbing the others.
        let snapshot = await pipeline.options
        #expect(snapshot.photorealModelsDir == nil)
        #expect(snapshot.maxFrames == 0)
    }

    /// `setPhotorealEnabled(true, ...)` with no identity loaded must throw the
    /// dedicated `photorealIdentityRequired` config error — distinct from the
    /// backend's own `LoadError` so callers can branch on "you need to load
    /// an identity first" vs "your weights are missing".
    @Test func setPhotorealEnabledWithoutIdentityThrows() async throws {
        let opts = PipelineOptions(mode: .synthetic, maxFrames: 0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pipeline = Pipeline(
            options: opts,
            manifestURL: tmp.appendingPathComponent("manifest.json"),
            jsonlURL: nil
        )
        do {
            try await pipeline.setPhotorealEnabled(true, modelsDir: tmp)
            Issue.record("expected setPhotorealEnabled to throw .photorealIdentityRequired")
        } catch PipelineConfigurationError.photorealIdentityRequired {
            // Expected
        } catch {
            Issue.record("expected .photorealIdentityRequired, got \(error)")
        }
    }

    // MARK: - Helpers

    private struct SignedBundle {
        var identity: ConsentedIdentity
        var png: Data
    }

    /// Mirrors `Tests/MirrorMeshReenactTests/PhotorealBackendTests.makeSignedBundle`.
    /// Synthetic PNG bytes are fine — the crypto pipeline only cares that the hash
    /// binds bytes to header, not that the bytes decode as an image.
    private func makeSignedBundle(scheme: IdentityScheme, scope: String = "v0.6+") throws -> SignedBundle {
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
                domain: "PhotorealStageTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"]
            )
        }
        return buffer
    }

    private func makeDummyCapturedFrame(width: Int, height: Int) throws -> CapturedFrame {
        CapturedFrame(
            frameID: FrameID(42),
            hostTimeNs: 1_000_000_000,
            pixelBuffer: try makeDummyPixelBuffer(width: width, height: height),
            width: width,
            height: height
        )
    }
}
