import Foundation

/// Fixed-capacity ring buffer sink for live UI. Drops the oldest event when full.
public final class RingBufferSink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [TelemetryEvent]
    private var nextWrite: Int
    private var totalSeen: UInt64
    public let capacity: Int

    public init(capacity: Int = 4096) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
        self.nextWrite = 0
        self.totalSeen = 0
    }

    public func consume(_ event: TelemetryEvent) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count < capacity {
            buffer.append(event)
        } else {
            buffer[nextWrite] = event
            nextWrite = (nextWrite + 1) % capacity
        }
        totalSeen &+= 1
    }

    /// Snapshot events in insertion order.
    public func snapshot() -> [TelemetryEvent] {
        lock.lock(); defer { lock.unlock() }
        if buffer.count < capacity { return buffer }
        return Array(buffer[nextWrite..<capacity]) + Array(buffer[0..<nextWrite])
    }

    public var seenCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return totalSeen
    }
}
