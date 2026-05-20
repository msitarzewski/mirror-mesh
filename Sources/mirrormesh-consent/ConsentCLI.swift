import Foundation
import CryptoKit
import MirrorMeshCore
import MirrorMeshWatermark

// R13: this file is NOT main.swift. The entry point is `@main` on `ConsentCLI`. All
// executable code lives in `static func main()`. CommandLine-style parsing (mirrors
// `Sources/mirrormesh-verify/VerifyCLI.swift`); no ArgumentParser dependency.

/// `mirrormesh-consent` — produce a signed `.mmid` ConsentedIdentity bundle.
///
/// Usage:
///   mirrormesh-consent \
///     --name "Test Subject" \
///     --scheme self-as-source \      # or stylized-non-human | consented-third-party
///     --scope "v0.6+" \
///     --png path/to/portrait.png \
///     --out path/to/bundle.mmid
///   [--print-disclosure]              # echo the disclosure text the subject signs
///   [--consent-confirm "I HAVE WRITTEN CONSENT FROM THE SUBJECT"]   # required for consented-third-party
///
/// The CLI is deliberately the dangerous path's gatekeeper (R1, R12): it refuses to
/// emit a `consented-third-party` bundle unless `--consent-confirm` is passed with the
/// exact required string. Making the dangerous code path more annoying than the safe
/// one is part of the trust thesis.
@main
struct ConsentCLI {
    static let requiredThirdPartyConsentPhrase = "I HAVE WRITTEN CONSENT FROM THE SUBJECT"

    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        // Optional flag: just dump the disclosure text and exit. Useful for subjects who want to
        // read what they're about to be cryptographically bound to before they ever hit `--out`.
        if args.contains("--print-disclosure") && !args.contains("--out") {
            print(IdentityConsentText.v1)
            exit(0)
        }

        let parsed: ParsedArgs
        do {
            parsed = try ParsedArgs(args: args)
        } catch let e as ArgError {
            FileHandle.standardError.write(Data("ERROR: \(e.message)\n\n".utf8))
            printUsage()
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(2)
        }

        // R1 + R12 enforcement: third-party bundles require an explicit, literal confirmation.
        if parsed.scheme == .consentedThirdParty {
            guard let phrase = parsed.consentConfirm, phrase == requiredThirdPartyConsentPhrase else {
                FileHandle.standardError.write(Data("""
                ERROR: --scheme consented-third-party requires --consent-confirm "\(requiredThirdPartyConsentPhrase)"
                (literal match, quotes included on the command line). This guard exists because
                emitting a real third party's likeness without their explicit, written consent
                violates project rule R1 and rule R12. If you are the subject, use
                --scheme self-as-source instead.

                """.utf8))
                exit(3)
            }
        }

        do {
            let result = try buildAndWriteBundle(parsed)
            print("OK")
            print("bundle:         \(result.outURL.path)")
            print("identity_id:    \(result.identity.identity_id)")
            print("display_name:   \(result.identity.display_name)")
            print("scheme:         \(result.identity.scheme.rawValue)")
            print("scope:          \(result.identity.scope)")
            print("public_key_fp:  \(result.publicKeyFingerprint)")
            print("signature_len:  \(result.signatureByteCount) bytes")
            print("source_sha256:  \(result.identity.source_png_sha256)")
            print("disclosure_v:   \(IdentityConsentText.version) (sha256=\(IdentityConsentText.sha256.prefix(16))…)")

            if parsed.printDisclosure {
                print("")
                print("--- DISCLOSURE TEXT (the subject is cryptographically bound to this) ---")
                print(IdentityConsentText.v1)
                print("--- END DISCLOSURE TEXT ---")
            }
            exit(0)
        } catch let e as ConsentCLIError {
            FileHandle.standardError.write(Data("ERROR: \(e.message)\n".utf8))
            exit(e.exitCode)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(10)
        }
    }

    // MARK: - Internal helpers (also exercised by mirrormeshConsentTests)

    struct BuildResult {
        let identity: ConsentedIdentity
        let outURL: URL
        let publicKeyFingerprint: String
        let signatureByteCount: Int
    }

    /// Read PNG, generate keypair, sign canonical(identity-without-signature) || PNG bytes,
    /// write the bundle. Same shape the test in `Tests/MirrorMeshWatermarkTests/...` uses.
    static func buildAndWriteBundle(_ parsed: ParsedArgs) throws -> BuildResult {
        let pngData: Data
        do {
            pngData = try Data(contentsOf: parsed.pngURL)
        } catch {
            throw ConsentCLIError(message: "cannot read --png at \(parsed.pngURL.path): \(error)", exitCode: 4)
        }
        guard !pngData.isEmpty else {
            throw ConsentCLIError(message: "--png file is empty", exitCode: 4)
        }

        let pngHash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()

        let key = Curve25519.Signing.PrivateKey()
        let pubRaw = key.publicKey.rawRepresentation
        let pubB64 = pubRaw.base64EncodedString()
        let pubFp  = SHA256.hash(data: pubRaw).prefix(8).map { String(format: "%02x", $0) }.joined()

        var identity = ConsentedIdentity(
            display_name: parsed.name,
            scheme: parsed.scheme,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: parsed.scope,
            issuer_public_key_b64: pubB64
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var clearable = identity
        clearable.signature_b64 = nil
        var message: Data
        do {
            message = try enc.encode(clearable)
        } catch {
            throw ConsentCLIError(message: "canonical encoding failed: \(error)", exitCode: 5)
        }
        message.append(pngData)
        let sig: Data
        do {
            sig = try key.signature(for: message)
        } catch {
            throw ConsentCLIError(message: "signing failed: \(error)", exitCode: 6)
        }
        identity.signature_b64 = sig.base64EncodedString()

        do {
            try ConsentedIdentityBundle.write(identity: identity, pngBytes: pngData, to: parsed.outURL)
        } catch {
            throw ConsentCLIError(message: "writing bundle failed: \(error)", exitCode: 7)
        }

        return BuildResult(
            identity: identity,
            outURL: parsed.outURL,
            publicKeyFingerprint: pubFp,
            signatureByteCount: sig.count
        )
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-consent \(MirrorMeshCore.version)
        Produces a signed `.mmid` ConsentedIdentity bundle.

        Usage:
          mirrormesh-consent \\
            --name "Subject Name" \\
            --scheme self-as-source | stylized-non-human | consented-third-party \\
            --scope "v0.6+" \\
            --png path/to/portrait.png \\
            --out path/to/bundle.mmid \\
            [--print-disclosure]                       Print the disclosure text after writing.
            [--consent-confirm "<exact phrase>"]       Required for --scheme consented-third-party.

        Standalone:
          mirrormesh-consent --print-disclosure        Dump the disclosure text and exit.

        Refusal:
          consented-third-party bundles require --consent-confirm "\(requiredThirdPartyConsentPhrase)".
          The phrase must match exactly. This is intentional (project rules R1 + R12).

        Output:
          OK
          bundle:         /path/to/bundle.mmid
          identity_id:    <uuid>
          display_name:   <Subject Name>
          scheme:         <scheme>
          scope:          v0.6+
          public_key_fp:  <8 bytes of SHA-256(pub) in hex>
          signature_len:  <bytes>
          source_sha256:  <hex>
          disclosure_v:   1.0 (sha256=<first 16 hex>…)

        """.utf8))
    }
}

// MARK: - Argument parsing

/// Parsed CLI arguments. Constructed eagerly so all validation errors surface at once.
struct ParsedArgs {
    let name: String
    let scheme: IdentityScheme
    let scope: String
    let pngURL: URL
    let outURL: URL
    let printDisclosure: Bool
    let consentConfirm: String?

    init(args: [String]) throws {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        guard let n = value("--name"), !n.isEmpty else {
            throw ArgError(message: "missing required --name")
        }
        guard let schemeRaw = value("--scheme") else {
            throw ArgError(message: "missing required --scheme (self-as-source | stylized-non-human | consented-third-party)")
        }
        guard let scheme = IdentityScheme(rawValue: schemeRaw) else {
            throw ArgError(message: "unknown --scheme '\(schemeRaw)'. Use self-as-source, stylized-non-human, or consented-third-party.")
        }
        guard let scope = value("--scope"), !scope.isEmpty else {
            throw ArgError(message: "missing required --scope (e.g. \"v0.6+\")")
        }
        guard let pngPath = value("--png") else {
            throw ArgError(message: "missing required --png <path>")
        }
        guard let outPath = value("--out") else {
            throw ArgError(message: "missing required --out <bundle.mmid>")
        }

        self.name = n
        self.scheme = scheme
        self.scope = scope
        self.pngURL = URL(fileURLWithPath: pngPath)
        self.outURL = URL(fileURLWithPath: outPath)
        self.printDisclosure = args.contains("--print-disclosure")
        self.consentConfirm = value("--consent-confirm")
    }
}

struct ArgError: Error { let message: String }
struct ConsentCLIError: Error {
    let message: String
    let exitCode: Int32
}
