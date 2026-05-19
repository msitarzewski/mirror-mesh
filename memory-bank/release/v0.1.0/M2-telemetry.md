# M2 — Logging & Telemetry Primitives

**Status**: ⚪ pending
**Owner**: TBD
**Blocked by**: M1
**Blocks**: M3, M7

## Objective

A telemetry layer that every stage publishes to, enabling reproducible benchmarks and live UI.

## Deliverables

In `Sources/MirrorMeshCore/`:

- `Telemetry.swift` — `Telemetry` actor with `emit(_ event: TelemetryEvent)` and ring-buffer subscription
- `TelemetryEvent.swift` — typed enum: `stageStart`, `stageEnd`, `frameTick`, `error`, `meta`
- `JSONLLogger.swift` — file-backed sink, append-only, line-buffered
- `LatencyHistogram.swift` — fixed-bucket histogram with P50/P95/P99 readouts
- `Signpost.swift` — `os_signpost` wrappers per stage for Instruments traces

## Interface (sketch)

```swift
public actor Telemetry {
    public static let shared = Telemetry()
    public func emit(_ event: TelemetryEvent)
    public func subscribe() -> AsyncStream<TelemetryEvent>
    public func attachSink(_ sink: any TelemetrySink)
}

public protocol TelemetrySink: Sendable {
    func consume(_ event: TelemetryEvent) async
}

public struct StageLatency: Codable, Sendable {
    public let stage: String
    public let frameID: UInt64
    public let durationNs: UInt64
    public let timestampNs: UInt64
}
```

## Tests

- Emit 10 000 events; verify zero drops with default ring size
- JSONL sink: round-trip parse
- Histogram: known input produces expected P95
