import Testing
import Foundation
import CryptoKit
@testable import MirrorMeshOutput
import MirrorMeshReenact
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshSolver
import MirrorMeshCore

/// End-to-end: the expressive avatar runs behind the same identity gate as the classic head, and
/// accessibility transforms are disclosed in the signed manifest exactly when they alter output.
@Suite("ExpressiveAvatarPipeline")
struct ExpressiveAvatarPipelineTests {

    private func tmpManifestURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-expressive-\(UUID().uuidString).manifest.json")
    }

    private func decodeManifest(at url: URL) throws -> SessionManifest {
        try ManifestCodec.decode(Data(contentsOf: url))
    }

    /// Sargent's *Lady Agnew* (public domain), vendored for the photoreal bench.
    static let portraitURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MirrorMeshReenactTests/fixtures/lp_diff/s0.jpg")

    /// Mirrors `PhotorealStageTests.makeSignedBundle` — the crypto path only needs the hash to
    /// bind the bytes to the header; pass a real portrait to exercise the likeness fit.
    private func makeSignedBundle(payload: Data = Data(repeating: 0x42, count: 256)) throws -> (ConsentedIdentity, Data) {
        let png = payload
        let pngHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        var identity = ConsentedIdentity(
            display_name: "Test Subject",
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: "v0.6+",
            issuer_public_key_b64: key.publicKey.rawRepresentation.base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var clearable = identity
        clearable.signature_b64 = nil
        var message = try enc.encode(clearable)
        message.append(png)
        identity.signature_b64 = try key.signature(for: message).base64EncodedString()
        return (identity, png)
    }

    /// Synthetic landmarks animate the mouth, so once the 30-frame calibration finishes the
    /// solver emits non-zero coefficients for transforms to act on.
    private func options(avatar: AvatarKind,
                         transforms: ExpressionTransforms = .none,
                         identity: (ConsentedIdentity, Data)?,
                         frames: Int) -> PipelineOptions {
        PipelineOptions(mode: .synthetic, captureWidth: 160, captureHeight: 120, fps: 30,
                        maxFrames: frames,
                        consentedIdentity: identity?.0, consentedIdentityPNG: identity?.1,
                        avatar: avatar, expressionTransforms: transforms)
    }

    @Test func defaultSessionRecordsClassicAvatarAndNoTransforms() async throws {
        let url = tmpManifestURL()
        let pipeline = Pipeline(options: PipelineOptions(mode: .synthetic, captureWidth: 160, captureHeight: 120,
                                                         fps: 30, maxFrames: 3),
                                manifestURL: url, jsonlURL: nil)
        _ = try await pipeline.run()
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.render.avatar == "classic")
        #expect(manifest.pipeline.render.expression_transforms == nil)
        #expect(manifest.pipeline.watermark.expression_transformed == false)
    }

    @Test func expressiveAvatarRendersEveryFrame() async throws {
        let url = tmpManifestURL()
        let pipeline = Pipeline(options: options(avatar: .expressive, identity: try makeSignedBundle(), frames: 12),
                                manifestURL: url, jsonlURL: nil)
        let result = try await pipeline.run()
        #expect(result.framesProcessed == 12)
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.render.avatar == "expressive")
        #expect(manifest.pipeline.watermark.expression_transformed == false)
    }

    @Test func activeTransformsAreDisclosedOnceTheyAlterOutput() async throws {
        let url = tmpManifestURL()
        let transforms = ExpressionTransforms(symmetry: .init(affectedSide: .left, strength: 0.8), gain: 2)
        let pipeline = Pipeline(options: options(avatar: .expressive, transforms: transforms,
                                                 identity: try makeSignedBundle(), frames: 45),
                                manifestURL: url, jsonlURL: nil)
        _ = try await pipeline.run()
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.watermark.expression_transformed == true)
        let tags = manifest.pipeline.render.expression_transforms ?? []
        #expect(tags.contains("gain:2.00"))
        #expect(tags.contains("symmetry:left:0.80"))
        // The manifest stays verifiable after the hot updates.
        #expect(manifest.manifest_signature_b64 != nil)
    }

    /// No identity → no avatar drawn → transforms changed nothing → nothing to disclose.
    @Test func transformsWithoutARenderedAvatarAreNotDisclosed() async throws {
        let url = tmpManifestURL()
        let pipeline = Pipeline(options: options(avatar: .expressive, transforms: ExpressionTransforms(gain: 2),
                                                 identity: nil, frames: 40),
                                manifestURL: url, jsonlURL: nil)
        _ = try await pipeline.run()
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.watermark.expression_transformed == false)
        #expect(manifest.pipeline.render.expression_transforms == nil)
    }

    @Test func classicAvatarIgnoresTransformsAndDoesNotDiscloseThem() async throws {
        let url = tmpManifestURL()
        let pipeline = Pipeline(options: options(avatar: .classic, transforms: ExpressionTransforms(gain: 2),
                                                 identity: try makeSignedBundle(), frames: 40),
                                manifestURL: url, jsonlURL: nil)
        _ = try await pipeline.run()
        #expect(try decodeManifest(at: url).pipeline.watermark.expression_transformed == false)
    }

    @Test func settersBeforeRunAreHonoured() async throws {
        let url = tmpManifestURL()
        let pipeline = Pipeline(options: options(avatar: .classic, identity: try makeSignedBundle(), frames: 40),
                                manifestURL: url, jsonlURL: nil)
        await pipeline.setAvatarKind(.expressive)
        await pipeline.setExpressionTransforms(ExpressionTransforms(gain: 1.5))
        _ = try await pipeline.run()
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.render.avatar == "expressive")
        #expect(manifest.pipeline.render.expression_transforms == ["gain:1.50"])
    }

    @Test func portraitLikenessIsFittedAndDisclosed() async throws {
        let url = tmpManifestURL()
        let bundle = try makeSignedBundle(payload: Data(contentsOf: Self.portraitURL))
        var opts = options(avatar: .expressive, identity: bundle, frames: 0)
        opts.maxFrames = nil
        opts.likenessEnabled = true
        let pipeline = Pipeline(options: opts, manifestURL: url, jsonlURL: nil)
        let run = Task { try await pipeline.run() }
        var active = false
        for _ in 0..<150 where !active {
            try await Task.sleep(nanoseconds: 100_000_000)
            active = await pipeline.likenessActive
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let a few fitted frames render
        await pipeline.stop()
        _ = try await run.value
        #expect(active, "likeness never installed")
        let manifest = try decodeManifest(at: url)
        #expect(manifest.pipeline.watermark.likeness_mapped == true)
        #expect(manifest.models.allSatisfy { $0.name != "depth_v1" }, "no depth dir configured → no depth model recorded")
    }

    @Test func faceFreeIdentityNeverMapsALikeness() async throws {
        let url = tmpManifestURL()
        var opts = options(avatar: .expressive, identity: try makeSignedBundle(), frames: 40)
        opts.likenessEnabled = true
        let pipeline = Pipeline(options: opts, manifestURL: url, jsonlURL: nil)
        _ = try await pipeline.run()
        #expect(await pipeline.likenessActive == false)
        #expect(try decodeManifest(at: url).pipeline.watermark.likeness_mapped == false)
    }

    @Test func depthModelRefComesFromTheProvenanceSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Pipeline.depthModelRef(modelsDir: dir) == nil)
        try Data(#"{"name":"depth_v1","sha256":"abc123"}"#.utf8).write(to: dir.appendingPathComponent("depth_v1.provenance.json"))
        #expect(Pipeline.depthModelRef(modelsDir: dir)?.sha256 == "abc123")
    }

    @Test func transformTagsKeepOneEntryPerKind() {
        var tags = Pipeline.mergeTransformTags([], ["symmetry:left:0.80", "gain:1.50"])
        tags = Pipeline.mergeTransformTags(tags, ["gain:1.60"])
        tags = Pipeline.mergeTransformTags(tags, ["gain:1.70", "eye_contact:0.40"])
        tags = Pipeline.mergeTransformTags(tags, ["symmetry:right:0.50"])
        #expect(tags == ["symmetry:left:0.80", "gain:1.70", "eye_contact:0.40", "symmetry:right:0.50"])
    }

    @Test func oldManifestsDecodeWithoutTheNewFields() throws {
        let legacy = """
        {"visible":true,"signed":true,"audible_chirp":false}
        """
        let w = try JSONDecoder().decode(WatermarkConfig.self, from: Data(legacy.utf8))
        #expect(w.expression_transformed == false)
        let r = try JSONDecoder().decode(RenderConfig.self, from: Data(#"{"overlay":["landmarks"]}"#.utf8))
        #expect(r.avatar == nil && r.expression_transforms == nil)
    }
}

@Suite("ExpressiveAvatar pipeline preview")
struct ExpressiveAvatarPipelinePreviewTests {
    /// Dev loop, not CI: records a short synthetic session per render style so the composite
    /// (placement over the face box, ghost sizing, watermark on top) can be eyeballed.
    ///   MIRRORMESH_AVATAR_PREVIEW_DIR=/tmp/x swift test --filter "ExpressiveAvatar pipeline preview"
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"] != nil))
    func recordStyles() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = Data(repeating: 0x42, count: 256)
        let key = Curve25519.Signing.PrivateKey()
        var identity = ConsentedIdentity(
            display_name: "Preview", scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            scope: "v0.6+", issuer_public_key_b64: key.publicKey.rawRepresentation.base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var message = try enc.encode(identity)
        message.append(png)
        identity.signature_b64 = try key.signature(for: message).base64EncodedString()

        let styles: [(String, Renderer.Options)] = [
            ("mirror", .init(showLandmarks: false, showAvatarMask: false, showFaceMesh: false, isWireframeStyle: false)),
            ("wireframe", .init(showLandmarks: true, showAvatarMask: false, showFaceMesh: true, isWireframeStyle: true)),
        ]
        for (name, renderer) in styles {
            let opts = PipelineOptions(mode: .synthetic, captureWidth: 640, captureHeight: 360, fps: 30,
                                       maxFrames: 75, rendererOptions: renderer,
                                       recorderURL: dir.appendingPathComponent("\(name).mov"),
                                       consentedIdentity: identity, consentedIdentityPNG: png,
                                       avatar: .expressive)
            _ = try await Pipeline(options: opts, manifestURL: dir.appendingPathComponent("\(name).manifest.json"),
                                   jsonlURL: nil).run()
        }
    }
}
