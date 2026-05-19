import Foundation
import MirrorMeshCore

/// Per-coefficient simple exponential smoother. New value = alpha * raw + (1-alpha) * previous.
///
/// Stateful but value-typed: the solver owns one and mutates it in place. Default alpha 0.5
/// halves jitter without adding perceptible lag at 30 fps.
public struct BlendshapeSmoother: Sendable {
    public var alpha: Float
    private var previous: [BlendshapeKey: Float] = [:]

    public init(alpha: Float = 0.5) {
        self.alpha = alpha
    }

    public mutating func smooth(_ coef: [BlendshapeKey: Float]) -> [BlendshapeKey: Float] {
        var out: [BlendshapeKey: Float] = [:]
        out.reserveCapacity(coef.count)
        for (k, v) in coef {
            let prev = previous[k] ?? v
            let blended = alpha * v + (1 - alpha) * prev
            out[k] = blended
            previous[k] = blended
        }
        return out
    }

    public mutating func reset() {
        previous.removeAll(keepingCapacity: true)
    }
}
