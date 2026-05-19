import Foundation

/// All telemetry passes through this typed enum. Adding a case is a contract change — log schema
/// is documented in `memory-bank/release/v0.1.0/M10-demo-integration.md`.
public enum TelemetryEvent: Sendable {
    /// Session-level metadata; one per session at start.
    case meta(sessionID: String, deviceModel: String, osVersion: String, commit: String?)

    /// Stage entry (frame N entered stage X at host time T).
    case stageStart(stage: StageID, frame: FrameID, hostTimeNs: UInt64)

    /// Stage exit (frame N left stage X at host time T).
    case stageEnd(stage: StageID, frame: FrameID, hostTimeNs: UInt64)

    /// One completed frame's full per-stage breakdown.
    case frame(frame: FrameID, perStageMs: [StageID: Double], endToEndMs: Double)

    /// A non-fatal error or warning.
    case warning(stage: StageID, message: String)

    /// A fatal error that aborted a frame.
    case error(stage: StageID, message: String)

    /// Free-form key-value annotation (config dumps, model hashes, ...).
    case annotation(key: String, value: String)

    /// A transcript segment produced by the voice pipeline (M28).
    case transcript(TranscriptFrame)

    /// Per-frame solver output. Emitted only when explicitly enabled (e.g. bench traces); too
    /// noisy for live runs. Keys are `BlendshapeKey.rawValue`; values are clamped to [0, 1].
    case coefficients(frame: FrameID, values: [String: Float])
}

/// All stages with telemetry. Stable string identifiers because the JSONL log is the paper artifact.
public enum StageID: String, Codable, Sendable, CaseIterable, Hashable {
    case capture
    case vision
    case solver
    case render
    case watermark
    case output
    case pipeline   // umbrella for end-to-end measurements
}
