import SwiftUI
import MirrorMeshCore

/// Live per-stage P50/P95 latency view. Refreshes from `PipelineViewModel.perStageLatencyMs`
/// which is itself updated at ~10Hz, so this view re-draws cheaply.
public struct TelemetryPanel: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    /// Stages we surface to the operator in this order; matches the pipeline diagram in docs.
    private static let displayStages: [StageID] = [
        .capture, .vision, .solver, .render, .watermark, .pipeline,
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Telemetry")
                    .font(.headline)
                Spacer()
                Text("ring \(viewModel.ringBuffer.seenCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("stage").font(.caption.bold())
                    Text("p50").font(.caption.bold())
                    Text("p95").font(.caption.bold())
                    Text("n").font(.caption.bold())
                }
                Divider().gridCellColumns(4)
                ForEach(Self.displayStages, id: \.self) { stage in
                    GridRow {
                        Text(stage.rawValue)
                            .font(.caption.monospaced())
                        if let s = viewModel.perStageLatencyMs[stage] {
                            Text(format(s.p50)).font(.caption.monospaced())
                            Text(format(s.p95)).font(.caption.monospaced())
                            Text("\(s.samples)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("—").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("0").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func format(_ v: Double) -> String {
        String(format: "%.2f ms", v)
    }
}
