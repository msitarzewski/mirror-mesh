import Testing
import Foundation
import CoreGraphics
import CoreImage
import AppKit
@testable import MirrorMeshAppKit
import MirrorMeshCore
import MirrorMeshWatermark

/// v1.1.0 follow-on — TestPersona unit tests.
///
/// Three behaviors matter:
///   1. The procedural draw produces a valid 256×256 RGBA PNG (sanity for
///      LivePortrait's source resolution expectation).
///   2. The mint path produces a `.mmid` bundle that `ConsentedIdentityVerifier`
///      accepts at the current runtime version.
///   3. `mintAndPersist` is idempotent — calling twice replaces the bundle in
///      place rather than corrupting it.
///
/// No Vision dependency here: TestPersona doesn't run face detection on its own
/// output; LivePortrait's `MotionExtractor` does that *at use-time*. The
/// procedural face's keypoint geometry is fixed (eyes at ~40 % from top, mouth
/// at ~75 %), so if LivePortrait fails to find keypoints, the fix is to adjust
/// the drawing geometry — not the test.
@Suite("TestPersona")
@MainActor
struct TestPersonaTests {

    /// The procedural PNG must decode to exactly 256×256. LivePortrait's
    /// motion/warp/generator graph expects 256² inputs; anything else burns time
    /// on resize and risks aliasing. The render path draws straight into a
    /// 256×256 CGContext so this is really verifying the encoder didn't truncate.
    @Test func generatedPNGIs256x256RGBA() throws {
        let png = TestPersona.generatePNG()
        #expect(!png.isEmpty, "TestPersona.generatePNG returned empty data")

        // Decode via CIImage — same path the photoreal stage uses to consume the
        // bundle PNG. If CIImage rejects the bytes the bundle is unusable downstream.
        let ci = CIImage(data: png)
        #expect(ci != nil, "Generated PNG failed to decode via CIImage")
        guard let ci else { return }
        #expect(Int(ci.extent.width) == 256, "PNG width != 256 (was \(ci.extent.width))")
        #expect(Int(ci.extent.height) == 256, "PNG height != 256 (was \(ci.extent.height))")

        // Sanity-check via NSBitmapImageRep too: the PNG header should decode to an
        // 8-bit-per-channel image (RGBA premultipliedFirst is the format we write).
        if let bitmap = NSBitmapImageRep(data: png) {
            #expect(bitmap.pixelsWide == 256)
            #expect(bitmap.pixelsHigh == 256)
            #expect(bitmap.bitsPerSample == 8)
        } else {
            Issue.record("NSBitmapImageRep failed to decode the generated PNG")
        }
    }

    /// Mint a fresh persona into a tempdir, then run the full verifier path
    /// (signature, PNG hash, scope, disclosure-text hash). If this passes, the
    /// bundle will load through `PipelineViewModel.loadIdentity` without error.
    @Test func mintProducesVerifiableBundle() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestPersonaTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("test-persona.mmid", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir.deletingLastPathComponent())
        }

        let (identity, png) = try await TestPersona.mintAndPersist(persistTo: tmpDir)

        // Mint path runs verify() internally; re-run here so the test pins the
        // contract independently of the implementation. Same args the runtime uses.
        try ConsentedIdentityVerifier.verify(
            identity: identity,
            pngBytes: png,
            runtimeVersion: MirrorMeshCore.version
        )

        #expect(identity.scheme == .selfAsSource)
        #expect(identity.display_name == "Test Persona")
        #expect(identity.scope == "v0.6+")
        #expect(identity.signature_b64 != nil)
        #expect(!identity.issuer_public_key_b64.isEmpty)

        // PNG bytes round-trip through the on-disk bundle byte-identically (this
        // catches any sneaky resampling in ConsentedIdentityBundle.write/read).
        let (reread, reReadPng) = try ConsentedIdentityBundle.read(from: tmpDir)
        #expect(reread.identity_id == identity.identity_id)
        #expect(reReadPng == png)
    }

    /// Calling `mintAndPersist` twice with the same persistTo URL should overwrite
    /// cleanly: both bundles verify, both PNGs are byte-identical (the draw is
    /// deterministic), and the second `identity_id` is fresh (each mint generates
    /// a new UUID + Ed25519 keypair — that's the right behavior; the user pressing
    /// the button twice issues two separate self-as-source consents).
    @Test func mintIsIdempotent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestPersonaTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("test-persona.mmid", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir.deletingLastPathComponent())
        }

        let (id1, png1) = try await TestPersona.mintAndPersist(persistTo: tmpDir)
        let (id2, png2) = try await TestPersona.mintAndPersist(persistTo: tmpDir)

        // PNG bytes are deterministic — same draw, same encoder, same bytes.
        #expect(png1 == png2, "TestPersona.generatePNG should be deterministic across calls")

        // Both verify against the runtime.
        try ConsentedIdentityVerifier.verify(
            identity: id1, pngBytes: png1, runtimeVersion: MirrorMeshCore.version
        )
        try ConsentedIdentityVerifier.verify(
            identity: id2, pngBytes: png2, runtimeVersion: MirrorMeshCore.version
        )

        // Fresh keypair per mint → different identity_id and public key. (We don't
        // require this; we just document it. If we later switch to a stable keypair
        // for the persona, this expect can flip to ==.)
        #expect(id1.identity_id != id2.identity_id, "Each mint should issue a fresh identity_id")

        // After the second write the on-disk bundle reflects id2, not id1.
        let (onDisk, onDiskPng) = try ConsentedIdentityBundle.read(from: tmpDir)
        #expect(onDisk.identity_id == id2.identity_id)
        #expect(onDiskPng == png2)
    }

    /// `defaultBundleURL()` is `nonisolated` so it's usable as a default-parameter
    /// expression. Sanity-check it points at the right place (under MirrorMesh in
    /// Application Support, NOT default.mmid — keeping the persona separate from
    /// the auto-provisioned default is the whole point).
    @Test func defaultBundleURLIsSeparateFromDefaultMmid() {
        let url = TestPersona.defaultBundleURL()
        #expect(url.lastPathComponent == "test-persona.mmid")
        #expect(url.lastPathComponent != "default.mmid",
               "Test persona must NOT clobber the user's default.mmid")
        #expect(url.deletingLastPathComponent().lastPathComponent == "MirrorMesh")
    }
}
