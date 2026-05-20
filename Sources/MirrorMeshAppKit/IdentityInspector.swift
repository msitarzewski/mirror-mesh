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
            photorealStatusBlock
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

    // MARK: - Photoreal status (M88/M89)

    /// Three-state row that mirrors `PipelineViewModel.photoreal*`:
    /// - `photorealError` set  → red triangle + error string
    /// - `photorealActive`     → green sparkles + "ON" + models-dir path
    /// - `photorealAvailable`  → secondary sparkles + "available (off)" + "Tap to enable"
    /// - otherwise             → secondary tray + "not available" + install hint (clickable)
    ///
    /// Matches the layout pattern in `statusBlock` above — leading SF Symbol + 4 pt VStack.
    @ViewBuilder
    private var photorealStatusBlock: some View {
        if let err = viewModel.photorealError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photoreal: error")
                        .font(.caption.weight(.semibold))
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if viewModel.photorealActive {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photoreal: ON")
                        .font(.callout.weight(.medium))
                    Text("LivePortrait models loaded at \(viewModel.photorealModelsDir?.path ?? "—")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        } else if viewModel.photorealAvailable {
            Button {
                Task { await viewModel.setPhotorealEnabled(true) }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photoreal: available (off)")
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Text("Tap to enable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openPhotorealInstallReadme()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photoreal: not available")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Run models/training/liveportrait_to_coreml.py to install")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("models/training/README.md")
                                .font(.caption2.monospaced())
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Click to open the install guide in your default viewer.")
        }
    }

    /// Open the models/training/README.md in the system viewer. Walks up from CWD looking
    /// for the repo root (the file sibling to `Package.swift`) so it works regardless of
    /// whether the app was launched from `swift run` or a `.app` bundle. Best-effort: if the
    /// file isn't found we open the `models/training/` directory if it exists, otherwise no-op.
    private func openPhotorealInstallReadme() {
        let fm = FileManager.default
        var roots: [URL] = []
        // 1) Anchored to the running executable.
        if let exe = URL(string: CommandLine.arguments.first ?? "") {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    roots.append(dir); break
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        // 2) The current working directory (covers `swift run` from repo root).
        roots.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))

        for root in roots {
            let readme = root.appendingPathComponent("models/training/README.md")
            if fm.fileExists(atPath: readme.path) {
                NSWorkspace.shared.open(readme)
                return
            }
            let dir = root.appendingPathComponent("models/training", isDirectory: true)
            if fm.fileExists(atPath: dir.path) {
                NSWorkspace.shared.open(dir)
                return
            }
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
