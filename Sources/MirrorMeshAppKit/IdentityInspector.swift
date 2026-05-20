import SwiftUI
import AppKit
import MirrorMeshWatermark

// ORCHESTRATOR: add IdentityInspector() to SettingsInspector Form in ContentView.swift after the Style section.
// Specifically: between the `} header: { Text("Style") }` block and the `Section { Toggle("Show landmarks…"`
// block, insert `IdentityInspector(viewModel: viewModel)` as a sibling Section. The view returns a
// `Section` directly, so it composes cleanly into the existing `Form { … }`.

/// M58 — settings-inspector section that shows the loaded `ConsentedIdentity` and lets the user
/// load a `.mmid` bundle from disk. The view is intentionally a `Section` (not a wrapper VStack)
/// so it slots into the existing `Form` layout in `ContentView.swift > SettingsInspector` without
/// double-padding.
///
/// State machine (display only; the source-of-truth is `viewModel.consentedIdentity` +
/// `viewModel.identityVerificationError`):
///
///   ┌─────────────────────────────────────────────────────────────────────────────┐
///   │ No identity loaded                  [Load Identity…]                         │
///   ├─────────────────────────────────────────────────────────────────────────────┤
///   │ Loaded: <display_name>                                                       │
///   │ <scheme> · scope <vX.Y+>                                                     │
///   │ id: <first 8 of identity_id>                                                 │
///   │ [Load Identity…]                                                             │
///   ├─────────────────────────────────────────────────────────────────────────────┤
///   │ ⚠ Verification failed: <error description>                                   │
///   │ [Load Identity…]                                                             │
///   └─────────────────────────────────────────────────────────────────────────────┘
@MainActor
public struct IdentityInspector: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Section {
            statusBlock
            Button {
                presentOpenPanel()
            } label: {
                Label("Load Identity…", systemImage: "person.crop.rectangle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        } header: {
            Text("Identity")
        } footer: {
            Text("Only `.mmid` bundles with a verifying signature are accepted. The bundle's scope must satisfy the running runtime. Bundles are created via `mirrormesh-consent`.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status block

    @ViewBuilder
    private var statusBlock: some View {
        if let err = viewModel.identityVerificationError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification failed")
                        .font(.caption.weight(.semibold))
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let id = viewModel.consentedIdentity {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Loaded: \(id.display_name)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("\(schemeDisplayName(id.scheme)) · scope \(id.scope)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("id: \(id.identity_id.prefix(8))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.dashed")
                    .foregroundStyle(.secondary)
                Text("No identity loaded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func schemeDisplayName(_ s: IdentityScheme) -> String {
        switch s {
        case .selfAsSource:       return "self-as-source"
        case .stylizedNonHuman:   return "stylized non-human"
        case .consentedThirdParty: return "consented third-party"
        }
    }

    // MARK: - Open panel

    /// Bundles are *directories* (see `ConsentedIdentityBundle.write`), so the open panel is
    /// configured for directory selection. We also accept individual files inside the bundle
    /// (the user might click `identity.json`) and walk up one level — small affordance, no
    /// behavior change.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Load ConsentedIdentity (.mmid)"
        panel.message = "Select a `.mmid` bundle directory. The bundle's Ed25519 signature must verify before MirrorMesh accepts the identity."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var bundleURL = url
        // If they clicked a file inside the bundle (e.g. identity.json), resolve to the parent dir.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir), !isDir.boolValue {
            bundleURL = bundleURL.deletingLastPathComponent()
        }
        viewModel.loadIdentity(from: bundleURL)
    }
}
