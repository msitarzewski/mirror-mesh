import Foundation

public struct CaptureConfig: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var lockExposure: Bool
    public var preferContinuityCamera: Bool

    public init(width: Int = 1280,
                height: Int = 720,
                fps: Int = 60,
                lockExposure: Bool = true,
                preferContinuityCamera: Bool = false) {
        self.width = width
        self.height = height
        self.fps = fps
        self.lockExposure = lockExposure
        self.preferContinuityCamera = preferContinuityCamera
    }

    public static let `default` = CaptureConfig()
    public static let benchSmall = CaptureConfig(width: 640, height: 360, fps: 30, lockExposure: true)
}
