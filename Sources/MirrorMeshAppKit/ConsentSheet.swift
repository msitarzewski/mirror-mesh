import SwiftUI
import MirrorMeshWatermark

/// Modal sheet shown before session start. Accept records consent; Decline dismisses without consent.
public struct ConsentSheet: View {
    @Binding public var consent: ConsentRecord?
    @Environment(\.dismiss) private var dismiss

    public init(consent: Binding<ConsentRecord?>) {
        self._consent = consent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MirrorMesh — Consent Required")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                Text(ConsentText.body)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 240, maxHeight: 360)
            .background(Color(white: 0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

            HStack {
                Text("Disclosure v\(ConsentText.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Decline", role: .cancel) {
                    consent = nil
                    dismiss()
                }
                Button("Accept") {
                    // Why: hash + timestamp captured at the click so the record is non-repudiable.
                    consent = ConsentRecord.acceptForCurrentDisclosure()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }
}
