import Foundation
import CryptoKit

/// A signed bundle that authorizes loading a third-party identity (a "puppet") into the
/// face-reenactment pipeline (v0.6.0 M56+). This is the architectural gate that makes
/// MirrorMesh's reenactment capability *not* a catfishing kit: a bundle's signature must
/// verify before the runtime accepts the identity, and the manifest records the bundle's
/// content hash so any session can be traced back to a consented source.
///
/// Bundle format on disk (`.mmid` files):
///   1. JSON header: `ConsentedIdentity` Codable
///   2. PNG payload: the source-frame image (the puppet's neutral pose)
///   3. The whole bundle is signed; signature lives in the JSON header.
///
/// Why this design vs. "load any image as source":
///   - License: the named subject signs the bundle (or a curated/stylized non-human source
///     gets a project-curated signature). Either way there's an audit trail.
///   - Provenance: the bundle hash lands in the session manifest, so any output recording
///     can be linked back to a *specific* identity load.
///   - Scope: the bundle declares which versions / use-cases it permits; the runtime refuses
///     out-of-scope use.
public struct ConsentedIdentity: Codable, Sendable, Equatable {
    /// Schema version for the bundle format itself.
    public var bundle_version: String

    /// Stable identifier (UUID). Different from the content hash so revocations can target
    /// a known issuance even after the source bytes change.
    public var identity_id: String

    /// Human-readable name for the identity. Surfaced in the Settings picker — *not*
    /// a security claim; the signature is the security claim.
    public var display_name: String

    /// Who the identity represents, from the perspective of the consent scheme:
    /// - `selfAsSource` — the user is consenting to be reenacted as themselves
    /// - `stylizedNonHuman` — cartoon / animal / abstract; not a person
    /// - `consentedThirdParty` — a named real person who signed the bundle
    public var scheme: IdentityScheme

    /// Disclosure text the subject signed off on. The hash binds the agreement to the bundle.
    /// Wording lives in `IdentityConsentText.v1`; the hash here is `SHA-256(text.utf8)`.
    public var disclosure_text_sha256: String

    /// SHA-256 of the source PNG bytes. Lets the runtime detect tampered payloads without
    /// re-decoding the image.
    public var source_png_sha256: String

    /// The runtime versions this bundle is valid for. `"v0.6+"` means "v0.6.0 and any later
    /// minor". The runtime rejects out-of-scope loads.
    public var scope: String

    /// Ed25519 public key of the issuer (the subject for self/third-party, or the project
    /// for stylized-non-human). Raw 32-byte base64.
    public var issuer_public_key_b64: String

    /// Ed25519 signature over the canonical JSON form of this struct with `signature_b64 = nil`
    /// concatenated with the source PNG bytes. Base64.
    public var signature_b64: String?

    /// When the subject signed. Informational; the runtime doesn't reject by age but a CLI
    /// could warn on very old bundles.
    public var signed_at: Date

    public init(
        bundle_version: String = "1.0",
        identity_id: String = UUID().uuidString,
        display_name: String,
        scheme: IdentityScheme,
        disclosure_text_sha256: String,
        source_png_sha256: String,
        scope: String,
        issuer_public_key_b64: String,
        signature_b64: String? = nil,
        signed_at: Date = Date()
    ) {
        self.bundle_version = bundle_version
        self.identity_id = identity_id
        self.display_name = display_name
        self.scheme = scheme
        self.disclosure_text_sha256 = disclosure_text_sha256
        self.source_png_sha256 = source_png_sha256
        self.scope = scope
        self.issuer_public_key_b64 = issuer_public_key_b64
        self.signature_b64 = signature_b64
        self.signed_at = signed_at
    }
}

public enum IdentityScheme: String, Codable, Sendable, CaseIterable {
    case selfAsSource = "self-as-source"
    case stylizedNonHuman = "stylized-non-human"
    case consentedThirdParty = "consented-third-party"
}

/// The disclosure text a subject signs off on to issue a self-as-source or third-party
/// bundle. Versioned so revisions are auditable.
public enum IdentityConsentText {
    public static let version = "1.0"

    public static let v1: String = """
    By signing this MirrorMesh ConsentedIdentity bundle (v\(version)), I consent to:

    1. The included source image being used to drive realtime face-reenactment of my likeness
       through the MirrorMesh pipeline.
    2. Every output frame produced from this identity carrying:
       - A visible "MIRRORMESH • SYNTHETIC" badge
       - An Ed25519 cryptographic frame signature
       - A reference (by hash) to this bundle in the session manifest
    3. The bundle being loadable on any device that has access to it. (Distribution is the
       responsibility of the bundle holder. Revocation is best-effort via the issuer.)
    4. The scope declared in the bundle. Use outside that scope is unauthorized.

    I confirm that I am either:
    (a) the subject of the source image, OR
    (b) authorized by the subject to issue this bundle, OR
    (c) issuing a stylized non-human source (no real person depicted).
    """

    public static var sha256: String {
        ConsentRecord.hashDisclosure(v1)
    }
}

/// Errors surfaced by the bundle verifier.
public enum ConsentedIdentityError: Error, CustomStringConvertible, Sendable {
    case invalidPublicKey
    case invalidSignature
    case payloadHashMismatch
    case disclosureHashMismatch
    case unsupportedScope(String)
    case unsupportedBundleVersion(String)
    case malformedBundle(String)

    public var description: String {
        switch self {
        case .invalidPublicKey:           return "ConsentedIdentity: invalid Ed25519 public key"
        case .invalidSignature:           return "ConsentedIdentity: signature verification failed"
        case .payloadHashMismatch:        return "ConsentedIdentity: source PNG hash doesn't match"
        case .disclosureHashMismatch:     return "ConsentedIdentity: disclosure text hash doesn't match the runtime's"
        case .unsupportedScope(let s):    return "ConsentedIdentity: scope '\(s)' not satisfied by this runtime"
        case .unsupportedBundleVersion(let v): return "ConsentedIdentity: unsupported bundle_version '\(v)'"
        case .malformedBundle(let m):     return "ConsentedIdentity: malformed bundle (\(m))"
        }
    }
}

/// Verifies a ConsentedIdentity bundle: signature, payload hash, scope.
public enum ConsentedIdentityVerifier {
    /// Verify a bundle. `runtimeVersion` is the current MirrorMesh version (e.g. "0.6.0")
    /// used for scope satisfaction.
    public static func verify(
        identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String
    ) throws {
        guard identity.bundle_version == "1.0" else {
            throw ConsentedIdentityError.unsupportedBundleVersion(identity.bundle_version)
        }
        guard let sigB64 = identity.signature_b64, let sig = Data(base64Encoded: sigB64) else {
            throw ConsentedIdentityError.malformedBundle("missing signature")
        }
        guard let pubKeyBytes = Data(base64Encoded: identity.issuer_public_key_b64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            throw ConsentedIdentityError.invalidPublicKey
        }

        let actualPngHash = SHA256.hash(data: pngBytes).map { String(format: "%02x", $0) }.joined()
        guard actualPngHash == identity.source_png_sha256 else {
            throw ConsentedIdentityError.payloadHashMismatch
        }

        guard identity.disclosure_text_sha256 == IdentityConsentText.sha256 else {
            throw ConsentedIdentityError.disclosureHashMismatch
        }

        try checkScope(identity.scope, runtimeVersion: runtimeVersion)

        // Build the canonical message: JSON of identity-with-signature-cleared || PNG bytes.
        var clearable = identity
        clearable.signature_b64 = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let canonical = try? enc.encode(clearable) else {
            throw ConsentedIdentityError.malformedBundle("canonical encoding failed")
        }
        var message = canonical
        message.append(pngBytes)
        guard publicKey.isValidSignature(sig, for: message) else {
            throw ConsentedIdentityError.invalidSignature
        }
    }

    /// Scope grammar in v1: a single token `vX.Y+` meaning "this version and later compatible".
    private static func checkScope(_ scope: String, runtimeVersion: String) throws {
        let trimmed = scope.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("v"), trimmed.hasSuffix("+") else {
            throw ConsentedIdentityError.unsupportedScope(scope)
        }
        let minVersion = String(trimmed.dropFirst().dropLast())   // "0.6"
        // Compare lexicographically by component. Good enough for v1; replace with semver later.
        let minComps = minVersion.split(separator: ".").compactMap { Int($0) }
        let curComps = runtimeVersion.split(separator: ".").compactMap { Int($0) }
        for (m, c) in zip(minComps, curComps) {
            if c > m { return }     // runtime newer
            if c < m { throw ConsentedIdentityError.unsupportedScope(scope) }
        }
        // All equal → satisfied (vX.Y+ matches vX.Y).
    }
}

/// On-disk bundle layout. Reader and writer pair so consumers don't have to know the byte
/// layout. Bundle is two files in a directory: `identity.json` + `source.png`.
public enum ConsentedIdentityBundle {
    public static func write(identity: ConsentedIdentity, pngBytes: Data, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try enc.encode(identity)
        try jsonData.write(to: dir.appendingPathComponent("identity.json"))
        try pngBytes.write(to: dir.appendingPathComponent("source.png"))
    }

    public static func read(from dir: URL) throws -> (ConsentedIdentity, Data) {
        let jsonData = try Data(contentsOf: dir.appendingPathComponent("identity.json"))
        let png = try Data(contentsOf: dir.appendingPathComponent("source.png"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let identity = try dec.decode(ConsentedIdentity.self, from: jsonData)
        return (identity, png)
    }
}
