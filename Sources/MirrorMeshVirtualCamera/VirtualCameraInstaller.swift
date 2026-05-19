import Foundation
#if canImport(SystemExtensions)
import SystemExtensions
#endif

/// Errors surfaced by `VirtualCameraInstaller`. The unsigned dev build returns
/// `.notInstallable` from every entry point so a missing Team ID never crashes the app.
public enum VirtualCameraInstallerError: Error, Sendable, Equatable {
    /// Build cannot install a system extension (no signing, ad-hoc, or non-app context).
    case notInstallable(reason: String)
    /// `OSSystemExtensionRequest` reported a failure. `code` is the raw `OSSystemExtensionError.Code`.
    case activationFailed(code: Int, message: String)
    /// User declined the system prompt to approve the extension.
    case userDenied
    /// Platform doesn't ship `SystemExtensions.framework` (only macOS does today).
    case unsupportedPlatform
}

/// Wraps `OSSystemExtensionRequest` so the app can install / uninstall the CMIO
/// virtual camera extension. Every entry point is gated behind `isInstallable` so
/// ad-hoc-signed dev builds no-op instead of crashing on the missing entitlement.
public enum VirtualCameraInstaller {

    /// True when the current process can legitimately call `OSSystemExtensionRequest.activate`.
    ///
    /// Conservative checks: must be running from an app bundle (not a CLI / SwiftPM test),
    /// must have a non-empty Team ID in the embedded provisioning profile, and the
    /// SystemExtensions framework must be available. The unsigned dev build fails the
    /// Team-ID check and we short-circuit before requesting activation.
    public static var isInstallable: Bool {
        installabilityDiagnosis() == nil
    }

    /// Returns a human-readable reason the build is not installable, or nil if it is.
    /// Exposed for the install-flow UI so the user sees *why* the button is disabled.
    public static func installabilityDiagnosis() -> String? {
        #if !canImport(SystemExtensions)
        return "SystemExtensions framework is unavailable on this platform."
        #else
        #if !os(macOS)
        return "System extensions are macOS-only."
        #else
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return "No host bundle identifier (likely running from a CLI / SwiftPM test, not an .app)."
        }
        // Why: ad-hoc dev signing produces no embedded provisioning profile, and the
        // system-extension entitlement requires a real Developer ID. Refuse cleanly.
        guard hasEmbeddedProvisioningProfile() else {
            return "No embedded provisioning profile — extension install requires a signed build with a real Developer ID Team."
        }
        // Why: extension bundle must actually be embedded in Contents/Library/SystemExtensions.
        guard hasEmbeddedExtensionBundle() else {
            return "Extension bundle not embedded in this app — rebuild with the MirrorMeshVirtualCameraExtension target."
        }
        return nil
        #endif
        #endif
    }

    /// Request that macOS install the embedded CMIO extension. The user will see a
    /// "System Extension Blocked" prompt and must approve it in System Settings.
    ///
    /// Returns when the activation request reaches a terminal state. Throws on failure;
    /// the unsigned dev build throws `.notInstallable` immediately.
    public static func install() async throws {
        if let reason = installabilityDiagnosis() {
            throw VirtualCameraInstallerError.notInstallable(reason: reason)
        }
        #if canImport(SystemExtensions) && os(macOS)
        try await submit(.activation)
        #else
        throw VirtualCameraInstallerError.unsupportedPlatform
        #endif
    }

    /// Request that macOS uninstall the extension. The user is also expected to be able
    /// to run `systemextensionsctl uninstall <team> ai.mirrormesh.VirtualCameraExtension`
    /// from the terminal; this method exists for an in-app uninstall button.
    public static func uninstall() async throws {
        if let reason = installabilityDiagnosis() {
            throw VirtualCameraInstallerError.notInstallable(reason: reason)
        }
        #if canImport(SystemExtensions) && os(macOS)
        try await submit(.deactivation)
        #else
        throw VirtualCameraInstallerError.unsupportedPlatform
        #endif
    }

    // MARK: - Internals

    private enum RequestKind { case activation, deactivation }

    #if canImport(SystemExtensions) && os(macOS)
    @MainActor
    private static func submit(_ kind: RequestKind) async throws {
        let bundleID = MirrorMeshVirtualCamera.extensionBundleIdentifier
        let request: OSSystemExtensionRequest = {
            switch kind {
            case .activation:
                return .activationRequest(forExtensionWithIdentifier: bundleID, queue: .main)
            case .deactivation:
                return .deactivationRequest(forExtensionWithIdentifier: bundleID, queue: .main)
            }
        }()
        let delegate = InstallerDelegate()
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        try await delegate.awaitOutcome()
    }

    /// Bridges the `OSSystemExtensionRequestDelegate` callbacks into a single `async` outcome.
    private final class InstallerDelegate: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?

        func awaitOutcome() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
            }
        }

        // Why: replacing an existing extension is fine for upgrades; we always say "replace".
        func request(_ request: OSSystemExtensionRequest,
                     actionForReplacingExtension existing: OSSystemExtensionProperties,
                     withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
            .replace
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
            // The OS shows the approval prompt; we'll get either `didFinishWithResult` or
            // `didFailWithError` once the user acts.
        }

        func request(_ request: OSSystemExtensionRequest,
                     didFinishWithResult result: OSSystemExtensionRequest.Result) {
            continuation?.resume(returning: ())
            continuation = nil
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            let nserr = error as NSError
            // `OSSystemExtensionErrorRequestCanceled` maps to "user denied" in practice.
            let mapped: VirtualCameraInstallerError = {
                if nserr.domain == OSSystemExtensionErrorDomain,
                   nserr.code == OSSystemExtensionError.requestCanceled.rawValue {
                    return .userDenied
                }
                return .activationFailed(code: nserr.code, message: nserr.localizedDescription)
            }()
            continuation?.resume(throwing: mapped)
            continuation = nil
        }
    }
    #endif

    private static func hasEmbeddedProvisioningProfile() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile") else {
            return false
        }
        return (try? Data(contentsOf: url).count) ?? 0 > 0
    }

    private static func hasEmbeddedExtensionBundle() -> Bool {
        // Why: built apps embed system extensions at Contents/Library/SystemExtensions/<bundleID>.systemextension.
        guard let appBundleURL = Bundle.main.bundleURL.absoluteString.isEmpty
                ? nil : Bundle.main.bundleURL else { return false }
        let extURL = appBundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(MirrorMeshVirtualCamera.extensionBundleIdentifier).systemextension", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: extURL.path, isDirectory: &isDir) && isDir.boolValue
    }
}
