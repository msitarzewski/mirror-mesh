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
    /// v0.8.0: true when the session ran with translation active (Ollama-driven
    /// translation + AVSpeechSynthesizer TTS + lip-sync overlay). The avatar's
    /// mouth no longer matches what the operator silently mouthed — disclosure
    /// is mandatory (R2). Optional in Codable: pre-v0.7 manifests decode cleanly
    /// because `init(from:)` supplies `false` when the key is missing.
    public var voice_transformed: Bool
    /// v1.1.0: true when the session ran with the photoreal reenactment path
    /// active — i.e. a `PhotorealBackend` was loaded at start (or hot-swapped
    /// in mid-session) and produced substituted frames for Mirror / Mask
    /// styles. Disclosure-class metadata: the rendered face is a learned
    /// reenactment of a consented identity, not the operator's raw camera
    /// pixels. Optional + defaulted in Codable so pre-v1.1 manifests
    /// round-trip cleanly (same shape as `voice_transformed`).
    public var photoreal_active: Bool

    public init(visible: Bool,
                signed: Bool,
                audible_chirp: Bool,
                voice_transformed: Bool = false,
                photoreal_active: Bool = false) {
        self.visible = visible
        self.signed = signed
        self.audible_chirp = audible_chirp
        self.voice_transformed = voice_transformed
        self.photoreal_active = photoreal_active
    }

    // Custom decode so pre-v0.7 manifests (no voice_transformed key) round-trip
    // cleanly. The synthesized decoder would throw on missing required keys; we
    // make it optional + defaulted instead. Re-encoding writes the new key, so
    // re-serializing an old manifest upgrades its on-disk shape.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.visible = try container.decode(Bool.self, forKey: .visible)
        self.signed = try container.decode(Bool.self, forKey: .signed)
        self.audible_chirp = try container.decode(Bool.self, forKey: .audible_chirp)
        self.voice_transformed = try container.decodeIfPresent(Bool.self, forKey: .voice_transformed) ?? false
        self.photoreal_active = try container.decodeIfPresent(Bool.self, forKey: .photoreal_active) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case visible
        case signed
        case audible_chirp
        case voice_transformed
        case photoreal_active
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
