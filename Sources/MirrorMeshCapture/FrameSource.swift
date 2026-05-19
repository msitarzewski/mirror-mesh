import Foundation
import MirrorMeshCore

/// Any source of captured frames. `LiveCaptureSource` wraps AVFoundation; `SyntheticFrameSource`
/// produces procedural test patterns for headless benchmarks and CI.
public protocol FrameSource: Sendable {
    /// Start producing frames into the returned stream. The stream terminates when `stop()` is called.
    func start() async throws -> AsyncStream<CapturedFrame>
    func stop() async
}

public enum CaptureError: Error, CustomStringConvertible, Sendable {
    case permissionDenied
    case noDeviceAvailable
    case formatUnavailable
    case sessionFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied:   return "Camera permission denied"
        case .noDeviceAvailable:  return "No camera device available"
        case .formatUnavailable:  return "Requested capture format not available"
        case .sessionFailed(let m): return "Capture session failed: \(m)"
        }
    }
}
