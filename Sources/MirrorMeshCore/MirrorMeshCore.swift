import Foundation

public enum MirrorMeshCore {
    public static let version = "0.1.0-dev"

    /// Monotonic host time in nanoseconds; cheaper and steadier than wall clock for frame timing.
    @inlinable
    public static func hostTimeNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
