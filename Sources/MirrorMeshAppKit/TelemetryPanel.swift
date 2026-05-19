import SwiftUI
import MirrorMeshCore

/// Live per-stage P50/P95 latency view. Refreshes from `PipelineViewModel.perStageLatencyMs`
/// (updated at ~10Hz) so this view re-draws cheaply.
@MainActor
public struct TelemetryPanel: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    /// Stages we surface to the operator. Matches the pipeline diagram in docs.
    private static let displayStages: [StageID] = [
        .capture, .vision, .solver, .render, .watermark, .pipeline,
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            grid
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Telemetry")
                .font(.headline)
            Spacer()
            HStack(spacing: 12) {
                metric("frames", value: "\(viewModel.ringBuffer.seenCount)")
                metric("e2e P50", value: formatOrDash(viewModel.perStageLatencyMs[.pipeline]?.p50))
                metric("e2e P95", value: formatOrDash(viewModel.perStageLatencyMs[.pipeline]?.p95))
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced().weight(.semibold))
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
                Text("stage").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("p50").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("p95").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("n").font(.caption2.bold()).foregroundStyle(.secondary)
            }
            Divider().gridCellColumns(4)
            ForEach(Self.displayStages, id: \.self) { stage in
                GridRow {
                    Text(stage.rawValue)
                        .font(.caption.monospaced())
                    if let s = viewModel.perStageLatencyMs[stage] {
                        Text(format(s.p50))
                            .font(.caption.monospaced())
                            .foregroundStyle(barColor(s.p50))
                        Text(format(s.p95))
                            .font(.caption.monospaced())
                            .foregroundStyle(barColor(s.p95))
                        Text("\(s.samples)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text("—").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text("—").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func format(_ v: Double) -> String {
        String(format: "%.2f ms", v)
    }

    private func formatOrDash(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f ms", v)
    }

    /// Heuristic color: green under 5ms, yellow under 20ms, red beyond.
    private func barColor(_ ms: Double) -> Color {
        if ms < 5 { return .green }
        if ms < 20 { return .yellow }
        return .red
    }
}
