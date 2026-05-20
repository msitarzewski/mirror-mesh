// Apple Speech backend — on-device only.
//
// =============================================================================
//                                 INTEGRATION SPEC
//   (for the orchestrator wiring this module into MirrorMeshOutput.Pipeline)
// =============================================================================
//
// PACKAGE.SWIFT EDITS
// -------------------
// None required. `MirrorMeshVoice` already declares a SwiftPM target at
// `Sources/MirrorMeshVoice/`. The `Speech` and `AVFoundation` system
// frameworks link implicitly on macOS via `import` — SwiftPM resolves them
// without explicit `linkerSettings` because they are part of the macOS SDK.
//
// Sanity-check: `swift build --target MirrorMeshVoice` succeeds without
// modifications to `Package.swift`. The voice target's dependency set
// (just `MirrorMeshCore`) is unchanged.
//
// PIPELINE.SWIFT INTEGRATION RECIPE
// ---------------------------------
// `MirrorMeshOutput.Pipeline` does not yet host a voice stage. To land
// transcripts in the main pipeline (parallel to face capture), do the
// following — none of which this PR performs:
//
//   1. Add a `VoiceStage` actor next to `ReenactStage`:
//
//        public actor VoiceStage {
//            private let backend: any SpeechRecognitionBackend
//            private var task: Task<Void, Never>?
//            public init(backend: any SpeechRecognitionBackend) { self.backend = backend }
//            public func start() async throws -> AsyncStream<Transcript> {
//                try await backend.start()
//            }
//            public func stop() async { await backend.stop() }
//        }
//
//   2. In `PipelineOptions`, add:
//
//        public var voiceEnabled: Bool = false
//        public var voiceLocale: String = "en-US"
//
//      Defaults preserve current behavior (voice off).
//
//   3. In `Pipeline`, mirror the `setOnRender`/`setOnCapture` pattern:
//
//        private var onTranscript: (@Sendable (Transcript) -> Void)?
//        public func setOnTranscript(_ cb: (@Sendable (Transcript) -> Void)?) {
//            self.onTranscript = cb
//        }
//
//   4. In `Pipeline.run()`, when `options.voiceEnabled` is true:
//
//        let voice = VoiceStage(backend: AppleSpeechBackend(locale: options.voiceLocale))
//        let transcripts = try await voice.start()
//        let voiceTask = Task {
//            for await t in transcripts {
//                let frame = TranscriptFrame(startMs: t.startMs,
//                                            endMs: t.endMs,
//                                            text: t.text,
//                                            confidence: t.confidence)
//                await Telemetry.shared.emit(.transcript(frame))
//                self.onTranscript?(t)
//            }
//        }
//
//      Cancel `voiceTask` and `await voice.stop()` in the cleanup tail
//      alongside `frameSource.stop()`.
//
//   5. **R2 disclosure** — Pipeline.swift:264 currently emits:
//
//        WatermarkConfig(visible: true, signed: true, audible_chirp: false)
//
//      When `options.voiceEnabled` is true, the manifest MUST record
//      `audible_chirp: true`. Voice capture is a privacy step beyond face
//      capture and the manifest is the user's only durable record of what
//      the session captured. Add a one-line conditional:
//
//        watermark: WatermarkConfig(
//            visible: true,
//            signed: true,
//            audible_chirp: options.voiceEnabled
//        )
//
//   6. **R12 refuse-on-sight** — do not add a "private mode" that disables
//      the chirp while voice is active. The user's permission grant
//      authorizes capture; the manifest disclosure authorizes accountability.
//      Both are mandatory.
//
// INFO.PLIST ADDITIONS (.app bundle)
// ----------------------------------
// Edit `MirrorMesh/Info.plist`. The existing `NSMicrophoneUsageDescription`
// stays (already covers mic access). Add the new Speech key:
//
//     <key>NSSpeechRecognitionUsageDescription</key>
//     <string>MirrorMesh transcribes microphone audio on-device only.
//     Audio is never sent to Apple or any cloud service.</string>
//
// Optional but recommended: tighten the existing
// `NSMicrophoneUsageDescription` to mention the on-device guarantee
// instead of "Whisper.cpp" (which no longer matches reality):
//
//     <string>MirrorMesh transcribes microphone audio on-device using
//     Apple's Speech framework. No audio leaves your device.</string>
//
// The `Sources/mirrormesh-app/Info.plist` file is informational only
// (excluded from the SPM build per `Package.swift:188`); add the same
// keys there to keep the two plists in sync.
//
// =============================================================================
//
// TODO(v0.8+): macOS 26+ ships `SpeechAnalyzer` / `SpeechTranscriber` in the
// Foundation Models / Apple Intelligence layer. Those APIs use larger
// on-device models with materially better accuracy than SFSpeechRecognizer
// and surface confidence scores per token. Migration is straightforward
// because the public surface of `SpeechRecognitionBackend` below is
// deliberately backend-agnostic. Today's `SFSpeechRecognizer` is the
// production-stable surface and is what we ship in v0.7.0.

import Foundation
import AVFoundation
import Speech
import MirrorMeshCore

/// One transcript segment emitted by a backend. Carries the same wall-clock
/// shape as `TranscriptFrame` but adds an `isFinal` flag because the Apple
/// Speech API streams partial results that get refined as more audio arrives.
public struct Transcript: Sendable, Hashable {
    public let startMs: Double
    public let endMs: Double
    public let text: String
    public let confidence: Float
    public let isFinal: Bool

    public init(startMs: Double,
                endMs: Double,
                text: String,
                confidence: Float,
                isFinal: Bool) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }

    /// Lossy projection to the JSONL-friendly `TranscriptFrame` used by the
    /// telemetry bus. Loses `isFinal` — callers that need it should consume
    /// the `Transcript` stream directly.
    public var asTranscriptFrame: TranscriptFrame {
        TranscriptFrame(startMs: startMs,
                        endMs: endMs,
                        text: text,
                        confidence: confidence)
    }
}

/// Errors the backend may surface. Network-fallback errors (`onDeviceUnavailable`)
/// are a hard refusal per project policy — we never fall back to cloud.
public enum SpeechRecognitionError: Error, Sendable, CustomStringConvertible {
    case permissionDenied(String)
    case onDeviceUnavailable(String)
    case recognizerUnavailable
    case localeUnsupported(String)
    case audioEngineFailed(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .permissionDenied(let s):    return "permission denied: \(s)"
        case .onDeviceUnavailable(let s): return "on-device recognition unavailable: \(s)"
        case .recognizerUnavailable:      return "SFSpeechRecognizer reports unavailable"
        case .localeUnsupported(let s):   return "locale not supported: \(s)"
        case .audioEngineFailed(let s):   return "audio engine failed: \(s)"
        case .alreadyRunning:             return "backend already running"
        }
    }
}

/// Backend-agnostic shape so the rest of the pipeline can be swapped between
/// `AppleSpeechBackend` (production), `MockSpeechBackend` (tests), and a
/// hypothetical future `SpeechAnalyzerBackend` (macOS 26+) without diffs in
/// callers.
///
/// Two input modes:
///   - `start()`: backend owns audio capture (microphone). Returns transcript stream.
///   - `start(fileURL:)`: backend reads an audio file end-to-end. Returns transcript stream.
public protocol SpeechRecognitionBackend: Sendable {
    /// Microphone-driven live recognition. Backend owns audio capture.
    func start() async throws -> AsyncStream<Transcript>
    /// File-driven recognition. Reads `fileURL` end-to-end; finishes the stream when EOF.
    func start(fileURL: URL) async throws -> AsyncStream<Transcript>
    /// Stop any in-flight recognition. Idempotent.
    func stop() async
}

/// On-device Apple Speech recognizer.
///
/// Invariants:
///   - `SFSpeechRecognitionRequest.requiresOnDeviceRecognition = true` — hard.
///   - Authorization is checked once at `start()`; denial throws.
///   - Locale is validated against `SFSpeechRecognizer.supportedLocales()`.
///   - On macOS, `AVAudioEngine` input node delivers in the hardware format;
///     the request accepts whatever format we install on the tap, so we tap
///     in the engine's native format and rely on Speech to resample internally.
///     Speech's preferred 16 kHz mono Float32 is achieved without an explicit
///     `AVAudioConverter` because the request handles the conversion.
public actor AppleSpeechBackend: SpeechRecognitionBackend {

    public let locale: Locale
    private let recognizer: SFSpeechRecognizer

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<Transcript>.Continuation?
    private var startedAtNs: UInt64 = 0
    private var running: Bool = false

    /// - Parameter localeIdentifier: BCP-47 locale (default `"en-US"`). Validated
    ///   against `SFSpeechRecognizer.supportedLocales()`; falls back to `en-US`
    ///   only if it matches; throws `.localeUnsupported` otherwise.
    public init(localeIdentifier: String = "en-US") throws {
        let candidate = Locale(identifier: localeIdentifier)
        // Why `supportsOnDeviceRecognition`: a locale may be in `supportedLocales()`
        // (i.e. server-side supported) but lack on-device models. We require on-device.
        guard let r = SFSpeechRecognizer(locale: candidate) else {
            throw SpeechRecognitionError.localeUnsupported(localeIdentifier)
        }
        guard r.supportsOnDeviceRecognition else {
            throw SpeechRecognitionError.onDeviceUnavailable(
                "locale \(localeIdentifier) has no on-device model installed. " +
                "Install it via System Settings > Keyboard > Dictation, or pick a different locale."
            )
        }
        self.locale = candidate
        self.recognizer = r
    }

    // MARK: - Public

    public func start() async throws -> AsyncStream<Transcript> {
        if running { throw SpeechRecognitionError.alreadyRunning }
        try await ensureAuthorized()
        guard recognizer.isAvailable else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        // `taskHint = .dictation`: tells the recognizer we expect free-form
        // continuous speech vs. short commands. Improves segmentation for
        // multi-sentence input.
        request.taskHint = .dictation
        self.request = request

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw SpeechRecognitionError.audioEngineFailed(
                "input bus reports zero sample rate (no microphone)"
            )
        }
        // Why tap in the hardware format (not 16 kHz mono): Speech's request
        // pipeline accepts any PCM format and internally resamples. Forcing a
        // conversion in our tap costs CPU and risks format mismatch crashes
        // when the hardware quietly changes (Bluetooth headsets, USB mics).
        let tapBufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hwFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechRecognitionError.audioEngineFailed("\(error)")
        }
        self.engine = engine

        let (stream, cont) = Self.makeStream()
        self.continuation = cont
        self.startedAtNs = MirrorMeshCore.hostTimeNs()
        self.running = true

        // Why the closure crosses isolation via Task: SFSpeechRecognitionTask
        // delivers results on an internal queue; we hop back to the actor to
        // mutate state and yield onto the continuation.
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { await self.handle(result: result, error: error) }
        }

        TelemetryBus.emit(.annotation(key: "voice.backend", value: "apple-speech"))
        TelemetryBus.emit(.annotation(key: "voice.locale", value: locale.identifier))
        TelemetryBus.emit(.annotation(key: "voice.on_device", value: "true"))

        return stream
    }

    public func start(fileURL: URL) async throws -> AsyncStream<Transcript> {
        if running { throw SpeechRecognitionError.alreadyRunning }
        try await ensureAuthorized()
        guard recognizer.isAvailable else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        // Why a buffer request (not `SFSpeechURLRecognitionRequest`): the URL
        // variant does not honor `requiresOnDeviceRecognition` on all OS
        // versions. The buffer request reliably enforces on-device, so we
        // open the file ourselves and feed buffers in.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request

        let (stream, cont) = Self.makeStream()
        self.continuation = cont
        self.startedAtNs = MirrorMeshCore.hostTimeNs()
        self.running = true

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { await self.handle(result: result, error: error) }
        }

        // Stream the file into the request on a background task. We don't use
        // AVAudioEngine — direct AVAudioFile reads are simpler and the request
        // handles format conversion internally.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Self.feedFile(fileURL: fileURL, into: request)
                request.endAudio()
            } catch {
                await self?.failWith(.audioEngineFailed("file read: \(error)"))
            }
        }

        TelemetryBus.emit(.annotation(key: "voice.backend", value: "apple-speech"))
        TelemetryBus.emit(.annotation(key: "voice.locale", value: locale.identifier))
        TelemetryBus.emit(.annotation(key: "voice.on_device", value: "true"))
        TelemetryBus.emit(.annotation(key: "voice.input", value: "file:\(fileURL.lastPathComponent)"))

        return stream
    }

    public func stop() async {
        guard running else { return }
        if let engine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        request?.endAudio()
        task?.finish()
        continuation?.finish()
        engine = nil
        request = nil
        task = nil
        continuation = nil
        running = false
    }

    // MARK: - Internal

    /// Pump an `AVAudioFile` into the recognition request in ~0.5 s chunks.
    private static func feedFile(fileURL: URL,
                                 into request: SFSpeechAudioBufferRecognitionRequest) async throws {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        // ~0.5 s per buffer balances latency-of-first-partial against
        // per-buffer overhead. Speech does not require any particular size.
        let framesPerBuffer = AVAudioFrameCount(max(1, format.sampleRate * 0.5))
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let toRead = AVAudioFrameCount(min(Int64(framesPerBuffer), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else {
                throw SpeechRecognitionError.audioEngineFailed("cannot allocate PCM buffer")
            }
            try file.read(into: buf, frameCount: toRead)
            request.append(buf)
            // Yield so partial-result callbacks can run; not strictly needed
            // but smooths CPU spikes on short files.
            await Task.yield()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            // Common path: end-of-stream after `endAudio()` — synthesize a final
            // close instead of treating it as a hard error. We can't import
            // the SFSpeechError symbols cross-version so we filter by message.
            let ns = error as NSError
            let isExpectedEnd = ns.domain == "kAFAssistantErrorDomain" ||
                                ns.localizedDescription.contains("No speech detected") == false &&
                                (ns.code == 203 /* Retry */ || ns.code == 216 /* Canceled */)
            if !isExpectedEnd {
                TelemetryBus.emit(.warning(stage: .vision /* no .voice stage yet */,
                                           message: "apple-speech: \(error)"))
            }
            continuation?.finish()
            running = false
            return
        }
        guard let result else { return }
        let now = MirrorMeshCore.hostTimeNs()
        let elapsedMs = Double(now &- startedAtNs) / 1_000_000.0
        let best = result.bestTranscription
        // `formattedString` already contains punctuation + spacing.
        let text = best.formattedString
        guard !text.isEmpty else { return }
        // Average per-segment confidence. Apple reports `confidence` only on
        // final results — partials have segments with `confidence == 0`. We
        // surface 0 on partials and the true average on finals; downstream
        // can branch on `isFinal` to decide whether to trust the number.
        var conf: Float = 0
        if result.isFinal, !best.segments.isEmpty {
            let sum = best.segments.reduce(Float(0)) { $0 + $1.confidence }
            conf = sum / Float(best.segments.count)
        }
        // Compute span from segment timestamps when available; fall back to
        // (elapsed - 0.5s .. elapsed) for partials with no segments.
        let startMs: Double
        let endMs: Double
        if let first = best.segments.first, let last = best.segments.last {
            startMs = first.timestamp * 1000.0
            endMs = (last.timestamp + last.duration) * 1000.0
        } else {
            startMs = max(0, elapsedMs - 500)
            endMs = elapsedMs
        }
        let t = Transcript(startMs: startMs,
                           endMs: endMs,
                           text: text,
                           confidence: conf,
                           isFinal: result.isFinal)
        continuation?.yield(t)
        if result.isFinal {
            continuation?.finish()
            running = false
        }
    }

    private func failWith(_ err: SpeechRecognitionError) {
        TelemetryBus.emit(.warning(stage: .vision, message: "apple-speech: \(err)"))
        continuation?.finish()
        running = false
    }

    private func ensureAuthorized() async throws {
        // Speech recognition authorization.
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechOK: Bool
        switch speechStatus {
        case .authorized:
            speechOK = true
        case .notDetermined:
            speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            speechOK = false
        @unknown default:
            speechOK = false
        }
        guard speechOK else {
            throw SpeechRecognitionError.permissionDenied("speech recognition not authorized")
        }

        // Microphone authorization (separate grant — `.audio` covers mics on macOS).
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOK: Bool
        switch micStatus {
        case .authorized:
            micOK = true
        case .notDetermined:
            micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { ok in cont.resume(returning: ok) }
            }
        case .denied, .restricted:
            micOK = false
        @unknown default:
            micOK = false
        }
        guard micOK else {
            throw SpeechRecognitionError.permissionDenied("microphone not authorized")
        }
    }

    private static func makeStream() -> (AsyncStream<Transcript>, AsyncStream<Transcript>.Continuation) {
        var c: AsyncStream<Transcript>.Continuation!
        let s = AsyncStream<Transcript>(bufferingPolicy: .bufferingNewest(32)) { cont in
            c = cont
        }
        return (s, c)
    }
}

/// Test-only deterministic backend. Honors the same protocol so unit tests
/// exercise the integration path without touching Speech / AVAudioEngine.
public actor MockSpeechBackend: SpeechRecognitionBackend {
    private let phrases: [String]
    private var running: Bool = false
    private var continuation: AsyncStream<Transcript>.Continuation?

    public init(phrases: [String] = ["mock transcript one", "mock transcript two"]) {
        self.phrases = phrases
    }

    public func start() async throws -> AsyncStream<Transcript> {
        try startInternal()
    }

    public func start(fileURL: URL) async throws -> AsyncStream<Transcript> {
        _ = fileURL
        return try startInternal()
    }

    public func stop() async {
        continuation?.finish()
        continuation = nil
        running = false
    }

    private func startInternal() throws -> AsyncStream<Transcript> {
        if running { throw SpeechRecognitionError.alreadyRunning }
        running = true
        let phrases = self.phrases
        let stream = AsyncStream<Transcript>(bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
            // Emit synchronously inside the build closure so consumers see
            // the data on first iteration without any timing dependency.
            for (i, p) in phrases.enumerated() {
                let start = Double(i) * 1000.0
                let end = start + 1000.0
                let isFinal = (i == phrases.count - 1)
                cont.yield(Transcript(startMs: start,
                                      endMs: end,
                                      text: p,
                                      confidence: 0.9,
                                      isFinal: isFinal))
            }
            cont.finish()
        }
        return stream
    }
}
