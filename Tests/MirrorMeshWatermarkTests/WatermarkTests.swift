import Testing
import Foundation
import CoreVideo
import CryptoKit
@testable import MirrorMeshWatermark
import MirrorMeshCore

@Suite("Watermark roundtrip")
struct WatermarkTests {
    @Test func signatureIsEd25519Sized() throws {
        let signer = FrameSigner()
        #expect(signer.publicKey.count == 32)
        let frame = makeFrame()
        let digest = signer.contentDigest(of: frame)
        let sig = signer.sign(frame, contentDigest: digest)
        #expect(sig.count == 64)
        #expect(digest.count == 32)
    }

    @Test func untamperedFrameVerifies() throws {
        let signer = FrameSigner()
        let frame = makeFrame()
        let digest = signer.contentDigest(of: frame)
        let sig = signer.sign(frame, contentDigest: digest)
        let ok = Verifier.verifyFrame(
            buffer: frame.pixelBuffer,
            signature: sig,
            expectedFrameID: frame.frameID.value,
            expectedHostTimeNs: frame.hostTimeNs,
            publicKey: signer.publicKey
        )
        #expect(ok)
    }

    @Test func wrongFrameIDRejected() throws {
        let signer = FrameSigner()
        let frame = makeFrame()
        let digest = signer.contentDigest(of: frame)
        let sig = signer.sign(frame, contentDigest: digest)
        let ok = Verifier.verifyFrame(
            buffer: frame.pixelBuffer,
            signature: sig,
            expectedFrameID: frame.frameID.value + 1,  // wrong
            expectedHostTimeNs: frame.hostTimeNs,
            publicKey: signer.publicKey
        )
        #expect(!ok)
    }

    @Test func manifestRoundtrip() async throws {
        let signer = FrameSigner()
        let manifest = SessionManifest(
            started_at: Date(),
            device: DeviceInfo.current(),
            pipeline: PipelineConfig.defaultV0(),
            consent: ConsentRecord(
                scheme: .selfAsSource,
                accepted_at: Date(),
                user_disclosure_text_sha256: ConsentRecord.hashDisclosure("test")
            ),
            public_key_b64: signer.publicKey.base64EncodedString()
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirrormesh-test-\(UUID().uuidString).manifest.json")
        let writer = ManifestWriter(url: url, signer: signer, manifest: manifest)
        await writer.recordFrames(10)
        try await writer.finalize()
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let loaded = try ManifestCodec.decode(data)
        #expect(loaded.frame_count == 10)
        #expect(Verifier.verifyManifest(loaded))

        // Tamper detection
        var tampered = loaded
        tampered.frame_count = 11
        #expect(!Verifier.verifyManifest(tampered))
    }

    @Test func consentTextHashStable() {
        let h1 = ConsentRecord.hashDisclosure("hello")
        let h2 = ConsentRecord.hashDisclosure("hello")
        #expect(h1 == h2)
        #expect(h1 != ConsentRecord.hashDisclosure("hello!"))
    }

    private func makeFrame() -> RenderedFrame {
        let pool = PixelBufferPool(width: 64, height: 64)
        let buf = pool.acquire()!
        return RenderedFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            pixelBuffer: buf,
            width: 64, height: 64
        )
    }
}
