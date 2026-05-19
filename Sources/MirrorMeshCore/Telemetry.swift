import Foundation

/// A sink consumes telemetry events. Implementations include JSONL file, in-memory ring buffer,
/// and (future) signpost-only.
public protocol TelemetrySink: Sendable {
    func consume(_ event: TelemetryEvent)
}

/// Telemetry actor — every stage emits into here. Sinks are attached at session start.
///
/// Why an actor: all sinks see events in the order they're emitted, even under contention
/// from multiple pipeline stages.
public actor Telemetry {
    public static let shared = Telemetry()

    private var sinks: [any TelemetrySink] = []

    public init() {}

    public func attach(_ sink: any TelemetrySink) {
        sinks.append(sink)
    }

    public func clearSinks() {
        sinks.removeAll()
    }

    public func emit(_ event: TelemetryEvent) {
        for sink in sinks { sink.consume(event) }
    }
}

/// Synchronous helper for hot paths that can't `await Telemetry.shared.emit(...)`.
/// Events are forwarded via a detached Task — order is best-effort, but per-stage cause and
/// effect remain monotonic because each stage emits from a single executor.
public enum TelemetryBus {
    public static func emit(_ event: TelemetryEvent) {
        Task.detached(priority: .utility) {
            await Telemetry.shared.emit(event)
        }
    }
}
