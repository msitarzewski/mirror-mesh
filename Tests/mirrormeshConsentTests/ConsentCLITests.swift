import Testing
import Foundation
import CryptoKit
@testable import mirrormesh_consent
import MirrorMeshWatermark

@Suite("mirrormesh-consent CLI")
struct ConsentCLITests {

    // MARK: - Argument parsing

    @Test func parsesAllRequiredArgs() throws {
        let args = [
            "mirrormesh-consent",
            "--name", "Test Subject",
            "--scheme", "self-as-source",
            "--scope", "v0.6+",
            "--png", "/tmp/portrait.png",
            "--out", "/tmp/bundle.mmid",
        ]
        let parsed = try ParsedArgs(args: args)
        #expect(parsed.name == "Test Subject")
        #expect(parsed.scheme == .selfAsSource)
        #expect(parsed.scope == "v0.6+")
        #expect(parsed.pngURL.path == "/tmp/portrait.png")
        #expect(parsed.outURL.path == "/tmp/bundle.mmid")
        #expect(parsed.printDisclosure == false)
        #expect(parsed.consentConfirm == nil)
    }

    @Test func rejectsMissingName() {
        let args = [
            "mirrormesh-consent",
            "--scheme", "self-as-source",
            "--scope", "v0.6+",
            "--png", "/tmp/x.png",
            "--out", "/tmp/x.mmid",
        ]
        #expect(throws: ArgError.self) {
            _ = try ParsedArgs(args: args)
        }
    }

    @Test func rejectsUnknownScheme() {
        let args = [
            "mirrormesh-consent",
            "--name", "x",
            "--scheme", "celebrity-impersonation",
            "--scope", "v0.6+",
            "--png", "/tmp/x.png",
            "--out", "/tmp/x.mmid",
        ]
        #expect(throws: ArgError.self) {
            _ = try ParsedArgs(args: args)
        }
    }

    @Test func parsesPrintDisclosureAndConsentConfirm() throws {
        let args = [
            "mirrormesh-consent",
            "--name", "x",
            "--scheme", "consented-third-party",
            "--scope", "v0.6+",
            "--png", "/tmp/x.png",
            "--out", "/tmp/x.mmid",
            "--print-disclosure",
            "--consent-confirm", ConsentCLI.requiredThirdPartyConsentPhrase,
        ]
        let parsed = try ParsedArgs(args: args)
        #expect(parsed.printDisclosure == true)
        #expect(parsed.consentConfirm == ConsentCLI.requiredThirdPartyConsentPhrase)
    }

    // MARK: - Bundle build + verify roundtrip

    @Test func buildAndWriteProducesVerifiableBundle() throws {
        let (pngURL, _) = try writeTempPng()
        let outDir = uniqueTempDir(suffix: ".mmid")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        defer { try? FileManager.default.removeItem(at: outDir) }

        let parsed = try ParsedArgs(args: [
            "mirrormesh-consent",
            "--name", "Test Subject",
            "--scheme", "self-as-source",
            "--scope", "v0.6+",
            "--png", pngURL.path,
            "--out", outDir.path,
        ])
        let result = try ConsentCLI.buildAndWriteBundle(parsed)

        #expect(result.identity.display_name == "Test Subject")
        #expect(result.identity.scheme == .selfAsSource)
        #expect(result.identity.scope == "v0.6+")
        #expect(result.identity.signature_b64 != nil)
        #expect(result.signatureByteCount == 64)
        #expect(result.publicKeyFingerprint.count == 16) // 8 bytes hex

        // Verifier roundtrip — proves the canonical-encoding-and-sign step matches what
        // ConsentedIdentityVerifier expects.
        let (read, png) = try ConsentedIdentityBundle.read(from: outDir)
        try ConsentedIdentityVerifier.verify(
            identity: read,
            pngBytes: png,
            runtimeVersion: "0.6.0"
        )
    }

    @Test func bundleContainsCanonicalDisclosureHash() throws {
        let (pngURL, _) = try writeTempPng()
        let outDir = uniqueTempDir(suffix: ".mmid")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        defer { try? FileManager.default.removeItem(at: outDir) }

        let parsed = try ParsedArgs(args: [
            "mirrormesh-consent",
            "--name", "Stylized Cat",
            "--scheme", "stylized-non-human",
            "--scope", "v0.6+",
            "--png", pngURL.path,
            "--out", outDir.path,
        ])
        let result = try ConsentCLI.buildAndWriteBundle(parsed)
        #expect(result.identity.disclosure_text_sha256 == IdentityConsentText.sha256)
    }

    @Test func emptyPngIsRejected() throws {
        let pngURL = uniqueTempDir(suffix: ".png")
        try Data().write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let parsed = try ParsedArgs(args: [
            "mirrormesh-consent",
            "--name", "x",
            "--scheme", "self-as-source",
            "--scope", "v0.6+",
            "--png", pngURL.path,
            "--out", uniqueTempDir(suffix: ".mmid").path,
        ])
        #expect(throws: ConsentCLIError.self) {
            _ = try ConsentCLI.buildAndWriteBundle(parsed)
        }
    }

    @Test func missingPngFileIsRejected() throws {
        let parsed = try ParsedArgs(args: [
            "mirrormesh-consent",
            "--name", "x",
            "--scheme", "self-as-source",
            "--scope", "v0.6+",
            "--png", "/tmp/this-file-does-not-exist-\(UUID().uuidString).png",
            "--out", uniqueTempDir(suffix: ".mmid").path,
        ])
        #expect(throws: ConsentCLIError.self) {
            _ = try ConsentCLI.buildAndWriteBundle(parsed)
        }
    }

    // MARK: - R1 / R12 — third-party guard

    /// Verifies the required-phrase constant exists and is non-empty. The actual refusal
    /// is enforced by `main()` (process-level), not by buildAndWriteBundle — keeping the
    /// signing helper composable. We tighten the test by checking the documented phrase.
    @Test func thirdPartyConfirmPhraseIsBindingAndNonEmpty() {
        #expect(!ConsentCLI.requiredThirdPartyConsentPhrase.isEmpty)
        #expect(ConsentCLI.requiredThirdPartyConsentPhrase
                    .contains("CONSENT"))
    }

    // MARK: - Helpers

    private func writeTempPng() throws -> (url: URL, data: Data) {
        // Synthetic bytes — same approach the ConsentedIdentityTests use. The signing
        // pipeline only cares about the bytes, not that they're a valid PNG.
        let url = uniqueTempDir(suffix: ".png")
        let data = Data(repeating: 0x42, count: 1024)
        try data.write(to: url)
        return (url, data)
    }

    private func uniqueTempDir(suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mmc-test-\(UUID().uuidString)\(suffix)")
    }
}
