import Foundation

/// Fixed-bucket latency histogram in milliseconds, optimized for realtime per-frame inserts.
/// Buckets are exponentially spaced from 0.1ms to 1000ms.
public struct LatencyHistogram: Sendable {
    public static let bucketEdgesMs: [Double] = {
        var edges: [Double] = []
        var v = 0.1
        while v < 1000.0 {
            edges.append(v)
            v *= 1.3
        }
        edges.append(1000.0)
        return edges
    }()

    public private(set) var counts: [UInt64]
    public private(set) var sampleCount: UInt64
    public private(set) var minMs: Double
    public private(set) var maxMs: Double

    public init() {
        self.counts = [UInt64](repeating: 0, count: Self.bucketEdgesMs.count + 1)
        self.sampleCount = 0
        self.minMs = .infinity
        self.maxMs = 0
    }

    public mutating func record(_ ms: Double) {
        sampleCount &+= 1
        if ms < minMs { minMs = ms }
        if ms > maxMs { maxMs = ms }
        // Linear scan; bucket count is small (~30). Binary search not worth complexity here.
        var bucket = Self.bucketEdgesMs.count
        for (i, edge) in Self.bucketEdgesMs.enumerated() where ms < edge {
            bucket = i
            break
        }
        counts[bucket] &+= 1
    }

    public func percentile(_ p: Double) -> Double {
        guard sampleCount > 0 else { return 0 }
        let target = UInt64(Double(sampleCount) * p)
        var running: UInt64 = 0
        for (i, c) in counts.enumerated() {
            running &+= c
            if running >= target {
                if i == 0 { return Self.bucketEdgesMs[0] }
                if i >= Self.bucketEdgesMs.count { return Self.bucketEdgesMs.last ?? 0 }
                return Self.bucketEdgesMs[i]
            }
        }
        return Self.bucketEdgesMs.last ?? 0
    }

    public var p50: Double { percentile(0.50) }
    public var p95: Double { percentile(0.95) }
    public var p99: Double { percentile(0.99) }
}
