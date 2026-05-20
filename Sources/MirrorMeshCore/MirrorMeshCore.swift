import Foundation

public enum MirrorMeshCore {
    /// Runtime version. Used as the scope-satisfaction baseline by `ConsentedIdentityVerifier`:
    /// a bundle whose scope is `vX.Y+` is rejected when this string parses to anything less than
    /// `X.Y`. Bump this on every minor/major release so v0.6+-scoped bundles continue to verify.
    public static let version = "1.0.0-dev"

    /// Monotonic host time in nanoseconds; cheaper and steadier than wall clock for frame timing.
    @inlinable
    public static func hostTimeNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
