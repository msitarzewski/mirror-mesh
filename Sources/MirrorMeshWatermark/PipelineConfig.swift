import Foundation

public struct ManifestCaptureConfig: Codable, Sendable, Equatable {
    public var format: String
    public var device_id: String
    public init(format: String, device_id: String) {
        self.format = format
        self.device_id = device_id
    }
}

public struct LandmarksConfig: Codable, Sendable, Equatable {
    public var backend: String
    public var smoothing: String
    public init(backend: String, smoothing: String) {
        self.backend = backend
        self.smoothing = smoothing
    }
}

public struct SolverConfig: Codable, Sendable, Equatable {
    public var type: String
    public var calibration_frames: Int
    public init(type: String, calibration_frames: Int) {
        self.type = type
        self.calibration_frames = calibration_frames
    }
}

public struct RenderConfig: Codable, Sendable, Equatable {
    public var overlay: [String]
    public init(overlay: [String]) { self.overlay = overlay }
}

public struct WatermarkConfig: Codable, Sendable, Equatable {
    public var visible: Bool
    public var signed: Bool
    public var audible_chirp: Bool
    public init(visible: Bool, signed: Bool, audible_chirp: Bool) {
        self.visible = visible
        self.signed = signed
        self.audible_chirp = audible_chirp
    }
}

public struct PipelineConfig: Codable, Sendable, Equatable {
    public var capture: ManifestCaptureConfig
    public var landmarks: LandmarksConfig
    public var solver: SolverConfig
    public var render: RenderConfig
    public var watermark: WatermarkConfig

    public init(capture: ManifestCaptureConfig,
                landmarks: LandmarksConfig,
                solver: SolverConfig,
                render: RenderConfig,
                watermark: WatermarkConfig) {
        self.capture = capture
        self.landmarks = landmarks
        self.solver = solver
        self.render = render
        self.watermark = watermark
    }

    // v0.1.0 default — visible badge + signed frames + manifest, no audio chirp yet.
    public static func defaultV0() -> PipelineConfig {
        PipelineConfig(
            capture: ManifestCaptureConfig(format: "1280x720@60", device_id: "default"),
            landmarks: LandmarksConfig(backend: "vision", smoothing: "one-euro"),
            solver: SolverConfig(type: "geometric", calibration_frames: 30),
            render: RenderConfig(overlay: ["landmarks", "avatar_mask"]),
            watermark: WatermarkConfig(visible: true, signed: true, audible_chirp: false)
        )
    }
}

public struct ModelRef: Codable, Sendable, Equatable {
    public var name: String
    public var sha256: String
    public var provenance_path: String
    public init(name: String, sha256: String, provenance_path: String) {
        self.name = name
        self.sha256 = sha256
        self.provenance_path = provenance_path
    }
}
