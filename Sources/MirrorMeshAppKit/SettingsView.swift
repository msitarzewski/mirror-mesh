import SwiftUI

/// Sidebar settings. The watermark toggle is force-locked in release builds; we still render it
/// so the user can see the policy, but the binding is intercepted to always read true.
public struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            Toggle("Show landmarks overlay", isOn: $settings.showLandmarks)
            Toggle("Show avatar mask", isOn: $settings.showAvatarMask)

            HStack(spacing: 6) {
                Toggle("Watermark visible", isOn: watermarkBinding)
                    .disabled(settings.watermarkLockedInRelease)
                if settings.watermarkLockedInRelease {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Watermark is required in release builds and cannot be disabled.")
                }
            }

            Spacer()
            Text("Watermarking policy is enforced by the renderer. UI toggles only affect overlays.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240, alignment: .topLeading)
    }

    /// In release we pin the watermark on regardless of UI state.
    private var watermarkBinding: Binding<Bool> {
        Binding(
            get: { settings.watermarkLockedInRelease ? true : settings.watermarkVisible },
            set: { newValue in
                if !settings.watermarkLockedInRelease { settings.watermarkVisible = newValue }
            }
        )
    }
}
