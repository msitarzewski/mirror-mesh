import Foundation
import CryptoKit

public enum ConsentScheme: String, Codable, Sendable, CaseIterable {
    case selfAsSource = "self-as-source"
    case stylizedNonHuman = "stylized-non-human"
    case consentedThirdParty = "consented-third-party"
}

public struct ConsentRecord: Codable, Sendable, Equatable {
    public var scheme: ConsentScheme
    public var accepted_at: Date
    public var user_disclosure_text_sha256: String

    public init(scheme: ConsentScheme, accepted_at: Date, user_disclosure_text_sha256: String) {
        self.scheme = scheme
        self.accepted_at = accepted_at
        self.user_disclosure_text_sha256 = user_disclosure_text_sha256
    }

    public static func hashDisclosure(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
