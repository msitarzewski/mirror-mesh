import SwiftUI
import MirrorMeshCore

// v0.7.0 — Settings-inspector section for the voice (Apple on-device Speech) stage. Slots into
// the existing `Form` in `ContentView.swift > SettingsInspector` between `IdentityInspector`
// and `TranslationInspector`. Returns a `Section` directly so it composes without extra padding.
//
// Lifecycle: toggle drives `PipelineViewModel.setVoiceEnabled(_:)` which wires up the transcript
// callback into the pipeline (built by the parallel agent). Errors surface via
// `viewModel.voiceError`; the status block re-uses the same shape as IdentityInspector.

/// Curated locale list — limited to BCP-47 strings Apple Speech is known to support on-device
/// across recent macOS versions. The full `SFSpeechRecognizer.supportedLocales()` list is
/// device-dependent and includes ~50 server-only locales; surfacing those here would let
/// users pick a locale that throws `.onDeviceUnavailable` at session start. Curated keeps the
/// UI honest.
private let curatedVoiceLocales: [(String, String)] = [
    ("en-US", "English (United States)"),
    ("en-GB", "English (United Kingdom)"),
    ("es-ES", "Spanish (Spain)"),
    ("es-MX", "Spanish (Mexico)"),
    ("fr-FR", "French (France)"),
    ("de-DE", "German (Germany)"),
    ("it-IT", "Italian (Italy)"),
    ("pt-BR", "Portuguese (Brazil)"),
    ("ja-JP", "Japanese (Japan)"),
    ("zh-CN", "Mandarin (Simplified)"),
    ("ko-KR", "Korean (Korea)"),
]

@MainActor
public struct VoiceInspector: View {
    @ObservedObject var viewModel: PipelineViewModel
    @ObservedObject var settings: AppSettings

    public init(viewModel: PipelineViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
    }

    public var body: some View {
        Section {
            Toggle("Enable speech transcription", isOn: voiceBinding)

            Picker("Locale", selection: $settings.voiceLocale) {
                ForEach(curatedVoiceLocales, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }
            .disabled(!settings.voiceEnabled)

            transcriptDisplay
                .frame(maxHeight: 60)

            statusRow
        } header: {
            Text("Voice")
        } footer: {
            Text("On-device Apple Speech. Audio never leaves your machine. Transcription begins when you enable the toggle and ends when the session stops.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sub-views

    /// Live caption area. Partial results render dimmed; finals render in primary text.
    /// Scrollable so a long transcript doesn't blow out the inspector width.
    @ViewBuilder
    private var transcriptDisplay: some View {
        let display = viewModel.currentTranscript.isEmpty
            ? "(no transcript yet)"
            : viewModel.currentTranscript
        ScrollView {
            Text(display)
                .font(.callout.monospacedDigit())
                .foregroundStyle(
                    viewModel.currentTranscript.isEmpty
                        ? .secondary
                        : (viewModel.currentTranscriptIsFinal ? .primary : .secondary)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Status pill: green when transcribing, orange on error, gray when idle.
    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            statusDot
            statusLabel
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let err = viewModel.voiceError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(err)
            }
        }
    }

    private var statusDot: some View {
        let (color, tip) = statusColorAndTooltip
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(tip)
    }

    private var statusLabel: Text {
        if viewModel.voiceError != nil {
            return Text("Error · on-device")
        }
        if viewModel.voiceActive {
            return Text("On-device · listening")
        }
        return Text("Off")
    }

    /// Why a tuple: SwiftUI's `Color` and the tooltip string change together; bundling them
    /// avoids two parallel switch statements that could drift out of sync.
    private var statusColorAndTooltip: (Color, String) {
        if let err = viewModel.voiceError {
            return (.orange, "Voice error: \(err)")
        }
        if viewModel.voiceActive {
            return (.green, "Transcribing on-device.")
        }
        return (.secondary.opacity(0.7), "Voice transcription is off.")
    }

    // MARK: - Binding

    /// Why a custom binding instead of `$settings.voiceEnabled`: flipping the toggle must drive
    /// the async bridge (`setVoiceEnabled`), not just persist the value. We persist here AND
    /// kick off the pipeline call so the order is deterministic.
    private var voiceBinding: Binding<Bool> {
        Binding(
            get: { settings.voiceEnabled },
            set: { newValue in
                settings.voiceEnabled = newValue
                Task { await viewModel.setVoiceEnabled(newValue) }
            }
        )
    }
}
