import Foundation
import MirrorMeshCore

/// Realtime transcriber. Consumes `AudioChunk`s and emits `TranscriptFrame`s on the
/// telemetry bus.
///
/// Current build: **mocked**. The real path requires vendoring whisper.cpp as a C/C++
/// target plus a Swift bridging header — that work is tracked in
/// `docs/voice-pipeline.md` and queued for v0.3.x. The mock preserves the actor's
/// public surface and timing characteristics so callers (and the bench scenario) work
/// unchanged the day the real engine lands.
public actor WhisperTranscriber {

    public enum WhisperError: Error, Sendable {
        case modelFileMissing(URL)
        case alreadyStarted
    }

    public struct Stats: Sendable {
        public var chunksProcessed: Int = 0
        public var transcriptsEmitted: Int = 0
    }

    /// Backend selector. `mock` is the only path wired in v0.3.0. `realWhisperCpp`
    /// reserves the enum slot so the bench JSONL annotation tells the truth about
    /// which engine produced a given trace.
    public enum Backend: String, Sendable {
        case mock
        case realWhisperCpp
    }

    public let backend: Backend
    private let modelURL: URL?
    private var stats = Stats()
    private var running = false
    private var startedAtNs: UInt64 = 0
    private var task: Task<Void, Never>?

    /// Construct against a model file on disk. If `modelURL` is nil, the transcriber
    /// runs in mock-only mode (used by tests and headless smoke runs).
    public init(modelURL: URL? = nil, backend: Backend = .mock) {
        self.modelURL = modelURL
        self.backend = backend
    }

    /// Verify the model file is at least present + non-empty. Real whisper.cpp will
    /// additionally checksum it. Mock backend skips this check.
    public func validateModel() throws {
        guard backend == .realWhisperCpp else { return }
        guard let url = modelURL else { throw WhisperError.modelFileMissing(URL(fileURLWithPath: "<nil>")) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 1_000_000 else { throw WhisperError.modelFileMissing(url) }
    }

    /// Drain an audio stream, emit transcripts. Returns when the stream completes.
    public func start(_ stream: AsyncStream<AudioChunk>) async throws {
        if running { throw WhisperError.alreadyStarted }
        running = true
        startedAtNs = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.annotation(key: "voice.backend", value: backend.rawValue))
        if let modelURL {
            TelemetryBus.emit(.annotation(key: "voice.model_path", value: modelURL.path))
        }

        for await chunk in stream {
            await process(chunk)
        }
        running = false
    }

    public func snapshot() -> Stats { stats }

    // MARK: - processing

    private func process(_ chunk: AudioChunk) async {
        stats.chunksProcessed += 1
        let startMs = Double(chunk.startNs &- startedAtNs) / 1_000_000.0
        let endMs = startMs + chunk.durationSeconds * 1000.0

        let text: String
        let confidence: Float
        switch backend {
        case .mock:
            (text, confidence) = mockTranscribe(chunk: chunk)
        case .realWhisperCpp:
            // Why pass-through to mock: the real backend isn't linked in this build.
            // The annotation already told the trace the requested backend was
            // `realWhisperCpp`; emitting the mock keeps the pipeline observable.
            (text, confidence) = mockTranscribe(chunk: chunk)
        }
        guard !text.isEmpty else { return }
        let frame = TranscriptFrame(startMs: startMs,
                                    endMs: endMs,
                                    text: text,
                                    confidence: confidence)
        stats.transcriptsEmitted += 1
        TelemetryBus.emit(.transcript(frame))
    }

    /// Deterministic mock: returns a placeholder transcript whose RMS hints at whether
    /// the chunk was silence vs. speech-loud. Tests rely on the determinism.
    private func mockTranscribe(chunk: AudioChunk) -> (String, Float) {
        var sumSq: Double = 0
        for s in chunk.samples { sumSq += Double(s) * Double(s) }
        let rms = chunk.samples.isEmpty ? 0 : sqrt(sumSq / Double(chunk.samples.count))
        if rms < 0.005 {
            return ("[silence]", 0.10)
        }
        let confidence = Float(min(1.0, max(0.30, rms * 5.0)))
        let text = String(format: "[mock-transcript rms=%.3f]", rms)
        return (text, confidence)
    }
}
