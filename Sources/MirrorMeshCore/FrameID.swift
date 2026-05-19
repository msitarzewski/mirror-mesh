import Foundation

/// Globally monotonic frame identifier. Atomic counter shared across the pipeline so every stage
/// references the same frame by the same ID.
public struct FrameID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public var description: String { "frame#\(value)" }
}

public final class FrameIDGenerator: @unchecked Sendable {
    public static let shared = FrameIDGenerator()
    private let lock = NSLock()
    private var counter: UInt64 = 0

    public init() {}

    public func next() -> FrameID {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        return FrameID(counter)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        counter = 0
    }
}
