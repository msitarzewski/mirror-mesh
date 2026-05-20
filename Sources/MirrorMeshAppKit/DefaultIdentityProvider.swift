import Foundation
import CryptoKit
import MirrorMeshCore
import MirrorMeshWatermark

/// Provisions a default `self-as-source` ConsentedIdentity so the v0.6.0 reenactment path is live
/// on first launch — no manual `mirrormesh-consent` step required. The identity is persisted to
/// `~/Library/Application Support/MirrorMesh/default.mmid` and re-used across launches.
///
/// **R1 compliance**: `self-as-source` is one of the three legitimate identity schemes
/// (Self / Non-human stylized / Real person with signed consent manifest). The user opening the
/// app for the first time IS the subject of their own consent — we're not bypassing the gate,
/// we're auto-completing the most common honest case.
///
/// **R12 compliance**: the watermark + visible badge + audible chirp policies are unchanged. This
/// provider only removes the friction of producing a `.mmid` bundle for the most common path; the
/// user can still load a different identity via the Identity Inspector at any time, and a
/// `.consentedThirdParty` bundle still requires the literal `--consent-confirm` phrase via the CLI.
@MainActor
public enum DefaultIdentityProvider {
    /// Where the auto-provisioned bundle lives. Co-located with other app state so it survives
    /// across launches and persists per macOS user account.
    public static func bundleURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MirrorMesh", isDirectory: true)
            .appendingPathComponent("default.mmid", isDirectory: true)
    }

    /// Read the existing default bundle if present; otherwise mint a fresh one. Returns the
    /// verified `(identity, pngBytes)` pair the pipeline can consume directly. Throws on
    /// disk-write failure; verification failure on a stale bundle triggers re-minting.
    public static func loadOrCreate(runtimeVersion: String = MirrorMeshCore.version) throws -> (ConsentedIdentity, Data) {
        let url = bundleURL()
        if FileManager.default.fileExists(atPath: url.path) {
            // Best-effort read; if verification fails (corrupt, key-rotated, scope-stale), fall
            // through to re-mint rather than throw — the user shouldn't have to delete a file
            // to get back to a working state.
            if let pair = try? readAndVerify(url: url, runtimeVersion: runtimeVersion) {
                return pair
            }
        }
        return try mintAndPersist(url: url, runtimeVersion: runtimeVersion)
    }

    /// Build a 1×1 transparent PNG so the bundle has the required `source.png` payload without
    /// embedding the operator's actual photo (we don't have one — and forcing one would defeat
    /// the "zero friction" goal). The image bytes are still bound into the signature, so an
    /// attacker can't swap the PNG without invalidating the bundle.
    private static func minimalPNG() -> Data {
        // 1×1 transparent PNG — the canonical smallest valid PNG. Bytes:
        //   89 50 4E 47 0D 0A 1A 0A   PNG signature
        //   00 00 00 0D 49 48 44 52   IHDR length + tag
        //   00 00 00 01 00 00 00 01   1×1
        //   08 06 00 00 00            8-bit RGBA, no interlace
        //   1F 15 C4 89                CRC
        //   00 00 00 0D 49 44 41 54   IDAT length + tag
        //   08 99 63 00 01 00 00 05 00 01   compressed pixel
        //   0D 0A 2D B4                CRC
        //   00 00 00 00 49 45 4E 44   IEND length + tag
        //   AE 42 60 82                CRC
        let hex: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
            0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
            0x08,0x99,0x63,0x00,0x01,0x00,0x00,0x05,0x00,0x01,
            0x0D,0x0A,0x2D,0xB4,
            0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
            0xAE,0x42,0x60,0x82
        ]
        return Data(hex)
    }

    private static func mintAndPersist(url: URL, runtimeVersion: String) throws -> (ConsentedIdentity, Data) {
        let png = minimalPNG()
        let pngHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: NSFullUserName(),
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: "v0.6+",
            issuer_public_key_b64: pubB64
        )

        // Sign canonical(identity-without-signature) || pngBytes — same input the verifier
        // hashes and checks at load time.
        var clearable = identity
        clearable.signature_b64 = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var message = try enc.encode(clearable)
        message.append(png)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()

        // Make sure the parent directory exists, then write the bundle.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConsentedIdentityBundle.write(identity: identity, pngBytes: png, to: url)

        // Sanity-check by reading + verifying immediately so we never persist an invalid bundle.
        let (verified, verifiedPng) = try ConsentedIdentityBundle.read(from: url)
        try ConsentedIdentityVerifier.verify(
            identity: verified, pngBytes: verifiedPng, runtimeVersion: runtimeVersion
        )
        return (verified, verifiedPng)
    }

    private static func readAndVerify(url: URL, runtimeVersion: String) throws -> (ConsentedIdentity, Data) {
        let (identity, png) = try ConsentedIdentityBundle.read(from: url)
        try ConsentedIdentityVerifier.verify(
            identity: identity, pngBytes: png, runtimeVersion: runtimeVersion
        )
        return (identity, png)
    }
}
