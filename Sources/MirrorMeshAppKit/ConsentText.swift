import Foundation
import MirrorMeshWatermark

/// Canonical, versioned consent disclosure text. The exact bytes here are what get hashed into
/// the `MirrorMeshWatermark.ConsentRecord` — changing this string is a contract change and
/// requires bumping `version`.
public enum ConsentText {
    public static let version = "1.0"

    public static let body: String = """
    MirrorMesh Consent Disclosure (v1.0)

    By tapping "Accept" you consent to the following for the duration of this session:

    1. Capture. MirrorMesh will read live frames from your camera at the
       configured resolution and frame rate.

    2. Transformation. Each captured frame is analyzed for facial landmarks
       and re-rendered as an avatar-mapped composite. Raw camera frames are
       not retained between frames and are not written to disk by MirrorMesh.

    3. Watermarked output. Every output frame carries a visible watermark
       and a cryptographic signature that binds it to this session. The
       watermark cannot be disabled in release builds.

    4. Session manifest. A signed manifest is written at session end recording
       the disclosure version, your consent timestamp, and a digest of the
       output. No raw faces or landmarks are included in the manifest.

    5. Revocation. You may stop the session at any time. Stopping ends capture
       immediately and finalizes the manifest.

    This consent applies only to this session on this device.
    """

    /// Lowercase hex SHA-256 of `body`, computed via the watermark module's helper so the UI
    /// stores exactly what the manifest expects.
    public static func bodyHashHex() -> String {
        ConsentRecord.hashDisclosure(body)
    }
}

extension ConsentRecord {
    /// Convenience: record acceptance with the canonical text + scheme defaulted to self-as-source.
    public static func acceptForCurrentDisclosure(
        scheme: ConsentScheme = .selfAsSource
    ) -> ConsentRecord {
        ConsentRecord(
            scheme: scheme,
            accepted_at: Date(),
            user_disclosure_text_sha256: ConsentText.bodyHashHex()
        )
    }
}
