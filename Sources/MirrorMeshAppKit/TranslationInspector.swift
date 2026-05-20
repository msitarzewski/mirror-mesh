import SwiftUI
import MirrorMeshCore
import MirrorMeshTranslate

// v0.8.0 — Settings-inspector section for the translation stage (local Ollama LLM +
// AVSpeechSynthesizer + audio→blendshape lip-sync). Slots into the existing `Form` in
// `ContentView.swift > SettingsInspector` after `VoiceInspector`. Returns a `Section`.
//
// R1 — translation drives the stylized-head pass; the toggle is gated on a verified
// `ConsentedIdentity` being loaded. The footer makes the dependency explicit.
//
// R2 / R12 — enabling translation locks the audible disclosure chirp on. The footer states this
// unconditionally; the runtime lock is owned by AppSettings via the parallel agent's
// `effectiveChirpEnabled` extension. We never offer a "private mode" that hides the chirp.

/// Curated target-language list. Display name → BCP-47 code. Limited to languages where
/// Ollama models have reasonable translation quality AND AVSpeechSynthesizer ships a default
/// voice on macOS 14+. The set is intentionally small so users don't pick a target locale that
/// produces gibberish lip-sync.
private let curatedTargetLocales: [(String, String)] = [
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

/// Suggested Ollama models. Small-to-mid weights so translation fits comfortably on M-series
/// machines without quantization tuning. The text field accepts any string — these are just
/// autocomplete suggestions.
private let suggestedOllamaModels: [String] = [
    "llama3.2:3b",
    "llama3.2:1b",
    "gemma2:2b",
    "qwen2.5:3b",
]

@MainActor
public struct TranslationInspector: View {
    @ObservedObject var viewModel: PipelineViewModel
    @ObservedObject var settings: AppSettings

    public init(viewModel: PipelineViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
    }

    public var body: some View {
        Section {
            // R1 — disable until a ConsentedIdentity has been loaded. The footer + lock icon
            // explain why so the user isn't left wondering.
            toggleRow

            Picker("Target language", selection: $settings.translationTargetLocale) {
                ForEach(curatedTargetLocales, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }
            .disabled(!settings.translationEnabled || !consentReady)

            ollamaModelPicker
                .disabled(!settings.translationEnabled || !consentReady)

            translationDisplay
                .frame(maxHeight: 60)

            statusRow
        } header: {
            Text("Translation")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !consentReady {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text("Load a `.mmid` identity to enable translation. The translation pass drives the stylized-head pipeline (`.stylizedNonHuman` scheme), which requires a verified ConsentedIdentity.")
                    }
                }
                Text("Translation uses your local Ollama instance at http://localhost:11434/. When enabled, the audible disclosure chirp cannot be disabled.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var toggleRow: some View {
        HStack(spacing: 6) {
            Toggle("Enable real-time translation", isOn: translationBinding)
                .disabled(!consentReady)
            if !consentReady {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Requires a loaded ConsentedIdentity. Use the Identity section above to load a .mmid bundle.")
            }
        }
    }

    /// Why a Picker + free-text field: the picker is the discoverability path (most users want
    /// one of the suggested 3b-class models). The TextField backstop lets power users type any
    /// model identifier their Ollama install has pulled. We don't probe Ollama on launch (would
    /// make startup hang on `connection refused` when Ollama isn't running); the model is only
    /// validated when the toggle flips on.
    @ViewBuilder
    private var ollamaModelPicker: some View {
        Picker("Ollama model", selection: $settings.ollamaModel) {
            ForEach(suggestedOllamaModels, id: \.self) { name in
                Text(name).tag(name)
            }
            if !suggestedOllamaModels.contains(settings.ollamaModel) {
                // Surface a custom-typed value so the picker doesn't drop the selection.
                Text(settings.ollamaModel).tag(settings.ollamaModel)
            }
        }
    }

    @ViewBuilder
    private var translationDisplay: some View {
        let display = viewModel.lastTranslation.isEmpty
            ? "(no translation yet)"
            : viewModel.lastTranslation
        ScrollView {
            Text(display)
                .font(.callout.monospacedDigit())
                .foregroundStyle(viewModel.lastTranslation.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            statusDot
            statusLabel
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let err = viewModel.translationError {
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
        if viewModel.translationError != nil {
            return Text("Local · ollama unreachable")
        }
        if viewModel.translationActive {
            return Text("Local · ollama up")
        }
        return Text("Off")
    }

    private var statusColorAndTooltip: (Color, String) {
        if let err = viewModel.translationError {
            return (.orange, "Translation error: \(err). Is Ollama running? `brew install ollama && ollama serve`.")
        }
        if viewModel.translationActive {
            return (.green, "Translating via local Ollama.")
        }
        return (.secondary.opacity(0.7), "Translation is off.")
    }

    // MARK: - State helpers

    /// True iff a verified ConsentedIdentity is loaded. Required to enable translation per R1
    /// (translation runs the stylized-head pass).
    private var consentReady: Bool {
        viewModel.consentedIdentity != nil
    }

    private var translationBinding: Binding<Bool> {
        Binding(
            get: { settings.translationEnabled },
            set: { newValue in
                settings.translationEnabled = newValue
                let opts: TranslationStageOptions? = newValue
                    ? viewModel.translationOptionsFromSettings()
                    : nil
                Task { await viewModel.setTranslationEnabled(newValue, options: opts) }
            }
        )
    }
}
