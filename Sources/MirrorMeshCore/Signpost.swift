import Foundation
import os.signpost

/// Lightweight wrapper over `os_signpost` so each stage can produce an Instruments-visible
/// interval without boilerplate. The log subsystem is shared so all stages cluster together in
/// the Instruments timeline.
///
/// Signposts are zero-cost when no tracing tool is attached (probe-only), so callers may invoke
/// them unconditionally on hot paths.
public enum Signpost {
    public static let log = OSLog(subsystem: "ai.mirrormesh", category: .pointsOfInterest)

    // MARK: - Named stage signposts
    // Stable static names so Instruments lanes line up with `StageID` cases.
    public static let capture: StaticString = "capture"
    public static let vision: StaticString = "vision"
    public static let solver: StaticString = "solver"
    public static let render: StaticString = "render"
    public static let watermark: StaticString = "watermark"
    public static let pipeline: StaticString = "pipeline"

    /// Begin an interval keyed by a fresh `OSSignpostID`. Caller stores the ID and passes it back
    /// to `end(...)` so concurrent frames don't collide.
    @inlinable
    public static func begin(_ name: StaticString, frame: FrameID) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "frame=%{public}llu", frame.value)
        return id
    }

    /// End the matching interval previously opened by `begin(_:frame:)`.
    @inlinable
    public static func end(_ name: StaticString, frame: FrameID, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id, "frame=%{public}llu", frame.value)
    }

    /// One-shot point event — surfaces in Instruments as a single marker (no duration).
    @inlinable
    public static func event(_ name: StaticString, frame: FrameID, message: String) {
        os_signpost(.event, log: log, name: name,
                    "frame=%{public}llu msg=%{public}s", frame.value, message)
    }

    /// Scoped helper for stages that prefer `defer`-style symmetry. Internally uses begin/end.
    @inlinable
    public static func interval<T>(_ name: StaticString,
                                   _ frame: FrameID,
                                   _ body: () throws -> T) rethrows -> T {
        let id = begin(name, frame: frame)
        defer { end(name, frame: frame, id: id) }
        return try body()
    }
}
