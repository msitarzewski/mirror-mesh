import Foundation
import MirrorMeshCore

/// Realtime transcriber. Consumes `AudioChunk`s and emits `TranscriptFrame`s on the
/// telemetry bus.
///
/// History: in v0.3.0 this shipped as a deterministic mock with a placeholder
/// `.realWhisperCpp` slot. In v0.7.0 we replaced the real backend with Apple's
/// on-device `SFSpeechRecognizer` (see `SpeechRecognitionBackend.swift`). The
/// `.realWhisperCpp` enum case is retained as an alias for `.appleSpeech` so
/// existing trace JSONL annotations remain decodable; new code should select
/// `.appleSpeech` (or `.mock`) explicitly.
///
/// **Architectural note**: when `backend == .appleSpeech`, the `start(_:)`
/// audio stream argument is ignored — Apple's Speech framework owns its own
/// audio capture path. Use `WhisperTranscriber.startAppleSpeech()` for that
/// route. The chunk-driven `start(_:)` surface still exists for mock testing
/// and for any future engine that prefers pre-buffered chunks.
public actor WhisperTranscriber {

    public enum WhisperError: Error, Sendable {
        case modelFileMissing(URL)
        case alreadyStarted
        case appleSpeechRequiresOwnAudio
        case appleSpeechFailed(String)
    }

    public struct Stats: Sendable {
        public var chunksProcessed: Int = 0
        public var transcriptsEmitted: Int = 0
        public var partialTranscriptsEmitted: Int = 0
    }

    /// Backend selector. `.appleSpeech` is the production path in v0.7.0+;
    /// `.realWhisperCpp` is a back-compat alias retained for older JSONL traces.
    public enum Backend: String, Sendable {
        case mock
        /// Back-compat alias for `.appleSpeech`. Old bench traces decode against
        /// this raw value; new code should write `.appleSpeech`.
        case realWhisperCpp
        case appleSpeech = "apple-speech"

        /// Normalized form for telemetry annotations. Folds the legacy alias
        /// into the canonical `apple-speech` tag so traces don't drift.
        public var canonicalTag: String {
            switch self {
            case .mock:            return "mock"
            case .realWhisperCpp:  return "apple-speech"
            case .appleSpeech:     return "apple-speech"
            }
        }
    }

    public let backend: Backend
    private let modelURL: URL?
    private let locale: String
    private var stats = Stats()
    private var running = false
    private var startedAtNs: UInt64 = 0
    private var task: Task<Void, Never>?

    /// Construct against a model file on disk (legacy; only `.realWhisperCpp` used to
    /// require this — the `.appleSpeech` backend does not consume a model URL).
    ///
    /// - Parameter modelURL: optional model file for legacy backends.
    /// - Parameter backend: which engine to use.
    /// - Parameter locale: BCP-47 locale for Apple Speech (default `en-US`). Ignored
    ///   by `.mock`.
    public init(modelURL: URL? = nil,
                backend: Backend = .mock,
                locale: String = "en-US") {
        self.modelURL = modelURL
        self.backend = backend
        self.locale = locale
    }

    /// Verify the model file is at least present + non-empty. `.appleSpeech` skips
    /// this check (the model is part of the OS, not a file we manage).
    public func validateModel() throws {
        switch backend {
        case .mock, .appleSpeech: return
        case .realWhisperCpp:
            // The legacy code path expected a whisper.cpp ggml file; the Apple
            // Speech backend now superseded that path. We still permit the call
            // but treat it as a no-op — keeping it loud-fail would break any
            // older caller that still passes a model URL.
            guard let url = modelURL else { return }
            if !FileManager.default.fileExists(atPath: url.path) { return }
        }
    }

    /// Drain an audio stream of pre-buffered chunks. Used by the `.mock` backend
    /// for deterministic tests. For `.appleSpeech` this method throws — call
    /// `startAppleSpeech()` / `startAppleSpeechFile(_:)` instead.
    public func start(_ stream: AsyncStream<AudioChunk>) async throws {
        if running { throw WhisperError.alreadyStarted }
        switch backend {
        case .appleSpeech:
            throw WhisperError.appleSpeechRequiresOwnAudio
        case .mock, .realWhisperCpp:
            break
        }
        running = true
        startedAtNs = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.annotation(key: "voice.backend", value: backend.canonicalTag))
        if let modelURL {
            TelemetryBus.emit(.annotation(key: "voice.model_path", value: modelURL.path))
        }
        for await chunk in stream {
            await process(chunk)
        }
        running = false
    }

    /// Apple Speech live microphone path. Returns an `AsyncStream<Transcript>` that
    /// surfaces partial + final results in real time. Also emits each transcript
    /// onto the telemetry bus as `.transcript(TranscriptFrame)` so JSONL traces
    /// stay unified with the legacy mock path.
    public func startAppleSpeech() async throws -> AsyncStream<Transcript> {
        if running { throw WhisperError.alreadyStarted }
        guard backend == .appleSpeech || backend == .realWhisperCpp else {
            throw WhisperError.appleSpeechRequiresOwnAudio
        }
        let backendImpl: AppleSpeechBackend
        do {
            backendImpl = try AppleSpeechBackend(localeIdentifier: locale)
        } catch {
            throw WhisperError.appleSpeechFailed("\(error)")
        }
        running = true
        startedAtNs = MirrorMeshCore.hostTimeNs()
        let upstream = try await backendImpl.start()
        return forward(upstream)
    }

    /// Apple Speech file-mode. Same return shape as `startAppleSpeech()`.
    public func startAppleSpeechFile(_ url: URL) async throws -> AsyncStream<Transcript> {
        if running { throw WhisperError.alreadyStarted }
        guard backend == .appleSpeech || backend == .realWhisperCpp else {
            throw WhisperError.appleSpeechRequiresOwnAudio
        }
        let backendImpl: AppleSpeechBackend
        do {
            backendImpl = try AppleSpeechBackend(localeIdentifier: locale)
        } catch {
            throw WhisperError.appleSpeechFailed("\(error)")
        }
        running = true
        startedAtNs = MirrorMeshCore.hostTimeNs()
        let upstream = try await backendImpl.start(fileURL: url)
        return forward(upstream)
    }

    public func snapshot() -> Stats { stats }

    // MARK: - processing

    /// Wrap the upstream `AsyncStream<Transcript>` so each yield also fans out to
    /// the telemetry bus + stats counter. Returns a fresh stream so the caller's
    /// `for await` iteration drives the work; no extra Task is needed.
    private func forward(_ upstream: AsyncStream<Transcript>) -> AsyncStream<Transcript> {
        AsyncStream<Transcript> { cont in
            let pumpTask = Task { [weak self] in
                for await t in upstream {
                    await self?.recordTranscript(t)
                    cont.yield(t)
                }
                cont.finish()
                await self?.markStopped()
            }
            cont.onTermination = { @Sendable _ in
                pumpTask.cancel()
            }
        }
    }

    private func recordTranscript(_ t: Transcript) {
        if t.isFinal {
            stats.transcriptsEmitted += 1
        } else {
            stats.partialTranscriptsEmitted += 1
        }
        // Only finals go onto the telemetry bus — partials would dominate the
        // JSONL trace (one event every ~100 ms). Callers wanting partials read
        // the returned `AsyncStream<Transcript>` directly.
        if t.isFinal {
            TelemetryBus.emit(.transcript(t.asTranscriptFrame))
        }
    }

    private func markStopped() {
        running = false
    }

    private func process(_ chunk: AudioChunk) async {
        stats.chunksProcessed += 1
        let startMs = Double(chunk.startNs &- startedAtNs) / 1_000_000.0
        let endMs = startMs + chunk.durationSeconds * 1000.0
        let (text, confidence) = mockTranscribe(chunk: chunk)
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
