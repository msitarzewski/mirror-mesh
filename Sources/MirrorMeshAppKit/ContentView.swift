import SwiftUI
import AppKit
import MirrorMeshCore

/// Main window: camera preview as hero, telemetry strip beneath, settings in an inspector panel
/// per Apple's canonical macOS layout. Toolbar drives session lifecycle. Materials carry the
/// Liquid-Glass aesthetic — `.containerBackground` for the window, `.thinMaterial` for cards.
@MainActor
public struct ContentView: View {
    @StateObject private var viewModel: PipelineViewModel
    @State private var showConsent: Bool = false
    @State private var showInspector: Bool = true

    public init(viewModel: PipelineViewModel? = nil) {
        // Why: `PipelineViewModel()` is @MainActor; defer instantiation into the @MainActor init.
        self._viewModel = StateObject(wrappedValue: viewModel ?? PipelineViewModel())
    }

    public var body: some View {
        mainContent
            .navigationTitle("MirrorMesh")
            .navigationSubtitle(navigationSubtitle)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                SettingsInspector(
                    viewModel: viewModel,
                    settings: viewModel.settings
                )
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .background(.thinMaterial)
            .frame(minWidth: 980, minHeight: 600)
            .onAppear {
                // Auto-start synthetic preview so the empty state is alive.
                if !viewModel.running { viewModel.startPreview() }
            }
            .onChange(of: viewModel.settings.showLandmarks) { _, _ in viewModel.applySettings() }
            .onChange(of: viewModel.settings.showAvatarMask) { _, _ in viewModel.applySettings() }
            .onChange(of: viewModel.settings.watermarkVisible) { _, _ in viewModel.applySettings() }
            .sheet(isPresented: $showConsent) { consentSheet }
            .alert(
                "Camera Access Required",
                isPresented: Binding(
                    get: { viewModel.error == .permissionDenied },
                    set: { presented in if !presented { viewModel.error = nil } }
                )
            ) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                    viewModel.error = nil
                }
                Button("Dismiss", role: .cancel) { viewModel.error = nil }
            } message: {
                Text("MirrorMesh needs camera permission to run live mode. Open System Settings → Privacy & Security → Camera and enable access for this app.")
            }
    }

    // MARK: - Layout

    private var mainContent: some View {
        VStack(spacing: 12) {
            previewCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            telemetryCard
                .frame(maxWidth: .infinity)
                .frame(height: 180)
        }
        .padding(16)
    }

    private var previewCard: some View {
        ZStack(alignment: .topTrailing) {
            CameraPreviewView(viewModel: viewModel)
            // M43: operator-cam PIP for Mirror/Mask styles — small overlay in the bottom-left
            // so the synthetic hero view (top-right watermark + center frame) stays clean.
            if showsOperatorPIP {
                VStack {
                    Spacer()
                    HStack {
                        OperatorPIPView(viewModel: viewModel)
                            .frame(width: 140, height: 105)
                            .padding(12)
                        Spacer()
                    }
                }
            }
            watermarkHeroBadge
                .padding(12)
        }
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// PIP shows when the hero view is synthetic so the operator can be verified.
    private var showsOperatorPIP: Bool {
        switch viewModel.settings.renderStyle {
        case .wireframe: return false
        case .mirror, .mask: return true
        }
    }

    /// Hero card for the watermarking thesis. Green when active, dim when idle. The whole project
    /// argues this is the differentiator — give it real estate.
    private var watermarkHeroBadge: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(viewModel.watermarkActive && viewModel.running
                          ? Color.green.opacity(0.9)
                          : Color.secondary.opacity(0.45))
                    .frame(width: 10, height: 10)
                if viewModel.watermarkActive && viewModel.running {
                    Circle()
                        .stroke(Color.green.opacity(0.4), lineWidth: 6)
                        .frame(width: 10, height: 10)
                        .scaleEffect(1.8)
                        .opacity(0.5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.watermarkActive && viewModel.running ? "Watermark active" : "Watermark idle")
                    .font(.caption.weight(.semibold))
                Text("Ed25519 + visible badge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .help("Every output frame carries an Ed25519 signature bound to the session manifest plus a visible disclosure badge. Policy enforced by the renderer.")
    }

    private var telemetryCard: some View {
        TelemetryPanel(viewModel: viewModel)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if viewModel.running {
                sessionStatusPill
            }
        }
        ToolbarItem(placement: .navigation) {
            // v0.7.0 / v0.8.0 — voice + translation activity chips. Only render when active so
            // the toolbar stays uncluttered during the common case.
            if viewModel.voiceActive || viewModel.translationActive {
                voiceTranslationPills
            }
        }
        ToolbarItem(placement: .primaryAction) {
            sessionButton
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the settings panel")
        }
    }

    /// Composite chip row. SF Symbols (no emoji) per the project's existing style.
    @ViewBuilder
    private var voiceTranslationPills: some View {
        HStack(spacing: 6) {
            if viewModel.voiceActive {
                Label("Listening", systemImage: "mic.fill")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .help("On-device speech transcription is active.")
            }
            if viewModel.translationActive {
                Label(translationPillLabel, systemImage: "globe")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .help("Translating to \(viewModel.settings.translationTargetLocale) via local Ollama. Disclosure chirp is locked on.")
            }
        }
    }

    /// Short uppercase language tag for the translation chip — e.g. "ES" / "JA" / "ZH".
    private var translationPillLabel: String {
        let code = viewModel.settings.translationTargetLocale
        // Take the language subtag (before "-") and uppercase. "es-ES" → "ES".
        let lang = code.split(separator: "-").first.map(String.init) ?? code
        return lang.uppercased()
    }

    private var sessionButton: some View {
        Group {
            if viewModel.running && !viewModel.isPreview {
                Button(role: .destructive) {
                    viewModel.stop()
                } label: {
                    Label("Stop Session", systemImage: "stop.circle.fill")
                }
            } else {
                Button {
                    // Why M37: do NOT stop the preview here — viewModel handles the handoff so
                    // the user sees synthetic frames until the live pipeline emits its first one.
                    showConsent = true
                } label: {
                    Label("Start Session", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
    }

    private var sessionStatusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isPreview ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(viewModel.isPreview ? "Preview" : "Session")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    private var navigationSubtitle: String {
        if viewModel.running && !viewModel.isPreview { return "Session running" }
        if viewModel.isPreview { return "Synthetic preview" }
        return "Idle"
    }

    // MARK: - Consent sheet

    private var consentSheet: some View {
        ConsentSheet(consent: Binding(
            get: { viewModel.consent },
            set: { newValue in
                viewModel.consent = newValue
                if newValue != nil { viewModel.start() }
            }
        ))
    }
}

// MARK: - Inspector

/// Form-with-Sections inspector. Standard Apple pattern; the section headers + footers do the
/// hierarchy work that flat checkboxes can't.
@MainActor
private struct SettingsInspector: View {
    @ObservedObject var viewModel: PipelineViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                // Picker hero: this is the master switch in v0.5.0.
                Picker("Render style", selection: $settings.renderStyle) {
                    ForEach(RenderStyle.allCases, id: \.self) { style in
                        Label(style.displayName, systemImage: style.symbolName).tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(settings.renderStyle.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Style")
            }

            IdentityInspector(viewModel: viewModel)

            VoiceInspector(viewModel: viewModel, settings: settings)

            TranslationInspector(viewModel: viewModel, settings: settings)

            Section {
                Toggle("Show landmarks overlay", isOn: $settings.showLandmarks)
                    .disabled(settings.renderStyle != .wireframe)
                Toggle("Show avatar mask", isOn: $settings.showAvatarMask)
                    .disabled(settings.renderStyle != .wireframe)
            } header: {
                Text("Wireframe overlays")
            } footer: {
                Text("These overrides only apply in Wireframe style. Mirror and Mask hide them by design.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 6) {
                    Toggle("Watermark visible", isOn: watermarkBinding)
                        .disabled(settings.watermarkLockedInRelease)
                    if settings.watermarkLockedInRelease {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("Watermark is required in release builds and cannot be disabled.")
                    }
                }
                HStack(spacing: 6) {
                    Toggle("Disclosure chirp on session start", isOn: chirpBinding)
                        .disabled(settings.chirpLockedInRelease)
                    if settings.chirpLockedInRelease {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("Audible disclosure is required in release builds and cannot be disabled.")
                    }
                }
            } header: {
                Text("Trust")
            } footer: {
                Text("Watermarking policy is enforced by the renderer. The toggle affects whether the visible badge is composited; cryptographic signing of every output frame is always on. The disclosure chirp plays once per session start; it is locked on in release builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Pipeline", value: viewModel.running ? "Running" : "Stopped")
                LabeledContent("Mode", value: viewModel.isPreview ? "Synthetic (preview)" : (viewModel.running ? "Live capture" : "—"))
                LabeledContent("Frames seen", value: "\(viewModel.ringBuffer.seenCount)")
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }

    private var watermarkBinding: Binding<Bool> {
        Binding(
            get: { settings.watermarkLockedInRelease ? true : settings.watermarkVisible },
            set: { newValue in
                if !settings.watermarkLockedInRelease { settings.watermarkVisible = newValue }
            }
        )
    }

    // M59: matches `watermarkBinding`. Release builds pin to true regardless of UI state.
    private var chirpBinding: Binding<Bool> {
        Binding(
            get: { settings.chirpLockedInRelease ? true : settings.chirpEnabled },
            set: { newValue in
                if !settings.chirpLockedInRelease { settings.chirpEnabled = newValue }
            }
        )
    }
}
