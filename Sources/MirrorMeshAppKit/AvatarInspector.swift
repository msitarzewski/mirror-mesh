import SwiftUI
import MirrorMeshCore
import MirrorMeshSolver

// Settings-inspector sections for the avatar choice and the accessibility transforms. Slots into
// the `Form` in `ContentView.swift > SettingsInspector` after `IdentityInspector`. Returns
// `Section`s directly so it composes like VoiceInspector / TranslationInspector.
//
// Every change is pushed live through `PipelineViewModel.applyAvatarSettings()`; the pipeline
// records transforms in the session manifest the first time they alter a rendered frame.

@MainActor
public struct AvatarInspector: View {
    @ObservedObject var viewModel: PipelineViewModel
    @ObservedObject var settings: AppSettings

    public init(viewModel: PipelineViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
    }

    public var body: some View {
        Section {
            Picker("Avatar", selection: $settings.avatarKind) {
                ForEach(AvatarKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Match identity portrait", isOn: $settings.likenessEnabled)
                .disabled(settings.avatarKind != .expressive)
        } header: {
            Text("Avatar")
        } footer: {
            Text(avatarFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: settings.avatarKind) { _, _ in viewModel.applyAvatarSettings() }
        .onChange(of: settings.likenessEnabled) { _, _ in viewModel.applyAvatarSettings() }

        Section {
            Toggle("Symmetry assist", isOn: $settings.symmetryAssistEnabled)
            if settings.symmetryAssistEnabled {
                Picker("Affected side", selection: $settings.symmetryAffectedSide) {
                    Text("Left of preview").tag(ExpressionTransforms.Side.left)
                    Text("Right of preview").tag(ExpressionTransforms.Side.right)
                }
                strengthSlider("Strength", value: $settings.symmetryStrength, range: 0...1)
            }

            Toggle("Expression boost", isOn: $settings.expressionGainEnabled)
            if settings.expressionGainEnabled {
                strengthSlider("Gain", value: $settings.expressionGain,
                               range: ExpressionTransforms.gainRange, format: "%.1f×")
            }

            Toggle("Eye-contact assist", isOn: $settings.eyeContactEnabled)
            if settings.eyeContactEnabled {
                strengthSlider("Strength", value: $settings.eyeContactStrength, range: 0...1)
            }
        } header: {
            Text("Accessibility")
        } footer: {
            Text(accessibilityFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(settings.avatarKind != .expressive)
        .onChange(of: settings.expressionTransforms) { _, _ in viewModel.applyAvatarSettings() }
    }

    private var avatarFooter: String {
        guard settings.avatarKind == .expressive else { return "The original low-poly head, driven by 18 shapes." }
        var text = "Drawn entirely in code from your expression, gaze and head pose — no generated footage. Shows once an identity is loaded."
        if settings.likenessEnabled {
            text += viewModel.likenessModelsDir == nil
                ? " Portrait matching uses the identity's photo for proportions and skin; install models/depth_v1.mlpackage to add surface relief."
                : " Portrait matching fits proportions, skin and surface relief to the identity's photo."
            text += " Recorded in the session manifest."
        }
        return text
    }

    private var accessibilityFooter: String {
        if settings.avatarKind != .expressive {
            return "Accessibility transforms drive the Expressive avatar."
        }
        return "Symmetry assist mirrors your unaffected side onto the affected one (facial paralysis). "
            + "Expression boost amplifies small movements. Eye-contact assist steadies your gaze toward "
            + "the viewer. Any active transform is recorded in the signed session manifest."
    }

    private func strengthSlider(_ title: String,
                                value: Binding<Float>,
                                range: ClosedRange<Float>,
                                format: String = "%.0f%%") -> some View {
        let shown = format.hasSuffix("%%") ? value.wrappedValue * 100 : value.wrappedValue
        return LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
