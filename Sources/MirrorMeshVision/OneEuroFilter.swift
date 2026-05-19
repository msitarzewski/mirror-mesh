import Foundation

/// One-Euro filter (Casiez et al., CHI 2012). Smooths a noisy signal while staying responsive
/// during fast motion. Used per-landmark, per-axis.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var lastValue: Double = .nan
    private var lastDerivative: Double = 0
    private var lastTimeNs: UInt64 = 0

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func filter(_ value: Double, atTimeNs t: UInt64) -> Double {
        defer { lastTimeNs = t }
        guard lastValue.isFinite else {
            lastValue = value
            return value
        }
        let dt = max(1e-6, Double(t &- lastTimeNs) / 1_000_000_000)
        let derivative = (value - lastValue) / dt
        let alphaD = smoothingFactor(dt: dt, cutoff: dCutoff)
        let smoothD = alphaD * derivative + (1 - alphaD) * lastDerivative
        let cutoff = minCutoff + beta * abs(smoothD)
        let alpha = smoothingFactor(dt: dt, cutoff: cutoff)
        let smoothed = alpha * value + (1 - alpha) * lastValue
        lastValue = smoothed
        lastDerivative = smoothD
        return smoothed
    }

    public mutating func reset() {
        lastValue = .nan
        lastDerivative = 0
        lastTimeNs = 0
    }

    private func smoothingFactor(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
