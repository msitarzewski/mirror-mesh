import SwiftUI
import AppKit

/// Main window layout: camera preview (left/center), telemetry panel (bottom), settings sidebar (right).
/// A top toolbar drives session start/stop and gates start on the consent sheet.
@MainActor
public struct ContentView: View {
    @StateObject private var viewModel: PipelineViewModel
    @State private var showConsent: Bool = false

    public init(viewModel: PipelineViewModel? = nil) {
        // Why: `PipelineViewModel()` is @MainActor; defer instantiation into the @MainActor init.
        self._viewModel = StateObject(wrappedValue: viewModel ?? PipelineViewModel())
    }

    public var body: some View {
        HStack(spacing: 0) {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SettingsView(settings: viewModel.settings)
        }
        .onAppear {
            // Why: auto-start the synthetic preview so the empty state is alive, not a flat
            // gradient with "Camera preview" text. The user still has to press "Start Session"
            // for a real consent-gated session.
            if !viewModel.running { viewModel.startPreview() }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(consent: Binding(
                get: { viewModel.consent },
                set: { newValue in
                    viewModel.consent = newValue
                    // Why: only start once Accept actually returned a record.
                    if newValue != nil { viewModel.start() }
                }
            ))
        }
        .alert(
            "Camera Access Required",
            isPresented: Binding(
                get: { viewModel.error == .permissionDenied },
                set: { presented in if !presented { viewModel.error = nil } }
            )
        ) {
            Button("Open System Settings") {
                // Why: deep-link straight to the Camera privacy pane so the user has one step
                // between the alert and granting access.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                viewModel.error = nil
            }
            Button("Dismiss", role: .cancel) {
                viewModel.error = nil
            }
        } message: {
            Text("MirrorMesh needs camera permission to run live mode. Open System Settings → Privacy & Security → Camera and enable access for this app.")
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            CameraPreviewView(viewModel: viewModel)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                TelemetryPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity)
                watermarkIndicator
            }
            .padding(12)
        }
    }

    private var watermarkIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.watermarkActive && viewModel.running ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(viewModel.watermarkActive && viewModel.running ? "watermark active" : "watermark idle")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .help("Visible watermark is applied to every output frame in this session.")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Why: text + icon so the call-to-action is obvious. The old icon-only button
            // hid the affordance and users wondered why nothing happened.
            if viewModel.running && !viewModel.isPreview {
                Button(role: .destructive) {
                    viewModel.stop()
                } label: {
                    Label("Stop Session", systemImage: "stop.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.large)
            } else {
                Button {
                    // Stop the auto-running preview before showing the consent sheet so
                    // the pipeline isn't busy when the real session takes over.
                    if viewModel.running { viewModel.stop() }
                    showConsent = true
                } label: {
                    Label("Start Session", systemImage: "play.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
    }
}
