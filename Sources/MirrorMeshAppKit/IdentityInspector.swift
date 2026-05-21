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

    /// True while a self-capture mint is in flight. Drives the inline spinner and
    /// disables the button so the user can't double-fire.
    @State private var capturing: Bool = false

    /// True while a test-persona mint is in flight. Same role as `capturing` but for
    /// the procedural-persona path — kept separate so the two buttons can't show a
    /// spurious spinner on each other.
    @State private var loadingPersona: Bool = false

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
            captureAsIdentityButton
            useTestPersonaButton
        } header: {
            Text("Identity")
        } footer: {
            Text("Only `.mmid` bundles with a verifying signature are accepted. The bundle's scope must satisfy the running runtime. Bundles are created via `mirrormesh-consent`.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Capture-as-identity (v1.1.0)

    /// Replaces the auto-provisioned 1×1 transparent default `.mmid` with a real head
    /// crop from the live camera. This is what makes the photoreal pipeline render the
    /// operator's *actual* face instead of generator noise on an empty source image.
    ///
    /// Disabled until a captured frame is available (i.e., a session is running).
    /// While the mint is in flight `capturing == true`, the label swaps to a spinner +
    /// "Capturing…" so the user can't double-fire. On success we hot-swap the new
    /// identity into the running pipeline via `viewModel.refreshPhotorealIdentity()`.
    @ViewBuilder
    private var captureAsIdentityButton: some View {
        Button {
            triggerSelfCapture()
        } label: {
            HStack(spacing: 6) {
                if capturing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Capturing…")
                } else {
                    Image(systemName: "camera.viewfinder")
                    Text("Capture as my identity")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .disabled(capturing || viewModel.latestCapturedFrame == nil)
        .help("Replaces the loaded identity with a 256×256 face crop from the live camera. Requires Mirror or live capture session running.")
    }

    /// Loads a procedurally-generated, obviously-not-the-operator face (teal skin,
    /// magenta hair) as a `self-as-source` `.mmid` and hot-swaps it into the running
    /// pipeline. Designed for verifying that the photoreal substitution is actually
    /// replacing the operator's face — capture-as-identity is a degenerate visual
    /// test (you see "yourself" because the source IS you), while the test persona
    /// makes substitution obvious: the rendered face is clearly cartoony.
    ///
    /// R1 compliance: `selfAsSource` is correct here — the operator is consenting to
    /// use an algorithmically-drawn face as their avatar; no real third party.
    /// R12: watermark, badge, and chirp are unchanged; same trust surfaces apply.
    @ViewBuilder
    private var useTestPersonaButton: some View {
        Button {
            triggerTestPersona()
        } label: {
            HStack(spacing: 6) {
                if loadingPersona {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading…")
                } else {
                    Image(systemName: "theatermasks")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use Test Persona")
                        Text("Loads a clearly-distinctive generated face so you can verify photoreal is replacing your face (not just rendering yourself).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .disabled(loadingPersona)
        .help("Loads a generated cartoony face as your identity. The rendered face will obviously not be you — so if photoreal is on you can SEE the substitution.")
    }

    /// Spawn the test-persona mint on a detached Task to avoid blocking the SwiftUI
    /// run loop. Same MainActor hop-back pattern as `triggerSelfCapture`. On success
    /// we publish the verified identity + PNG and ask the view-model to hot-swap the
    /// running pipeline (which cycles the photoreal stage so the appearance cache
    /// rebuilds against the new source — same flow as the self-capture button).
    private func triggerTestPersona() {
        loadingPersona = true
        Task { @MainActor in
            defer { loadingPersona = false }
            do {
                let (identity, png) = try await TestPersona.mintAndPersist()
                viewModel.consentedIdentity = identity
                viewModel.identityPngData = png
                viewModel.identityVerificationError = nil
                await viewModel.refreshPhotorealIdentity()
            } catch let e as TestPersona.PersonaError {
                viewModel.identityVerificationError = e.description
            } catch {
                viewModel.identityVerificationError = "Test persona load failed: \(error)"
            }
        }
    }

    /// Spawn the async self-capture task. We hop off the SwiftUI button action onto a
    /// detached Task because Vision + CoreImage on a 720p frame can take several tens
    /// of ms; blocking the main run loop would freeze the live preview during the call.
    /// The task hops back to @MainActor before mutating `@Published` state.
    private func triggerSelfCapture() {
        guard let frame = viewModel.latestCapturedFrame else {
            viewModel.identityVerificationError = "No live frame available. Start a session and face the camera."
            return
        }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let (identity, png) = try await IdentitySelfCapture.mintFromFrame(frame)
                viewModel.consentedIdentity = identity
                viewModel.identityPngData = png
                viewModel.identityVerificationError = nil
                await viewModel.refreshPhotorealIdentity()
            } catch let e as IdentitySelfCapture.CaptureError {
                viewModel.identityVerificationError = e.description
            } catch {
                viewModel.identityVerificationError = "Capture failed: \(error)"
            }
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
