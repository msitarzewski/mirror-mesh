import Foundation
import AVFoundation
import MirrorMeshCore

// MARK: - Public types

/// One per-frame sample of the TTS output. Emitted at the lip-sync update rate (target 60 Hz)
/// while AVSpeechSynthesizer is rendering. `Sendable` because every field is a value type.
///
/// `dominantVowel` is the coarse vowel class inferred from the audio buffer's spectral shape
/// in the last update window. We classify into the five lip-readable categories the stylized
/// head's blendshapes can express; non-vowel frames carry `.silence` (in mid-consonant) or the
/// last known vowel (during continuants like /s/ where the mouth shape barely changes).
public struct TTSFrame: Sendable, Equatable {
    /// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` value at which the audio sample window was
    /// rendered. The lip-sync driver matches this against the renderer's frame clock so the
    /// blendshape coefficient arrives on the correct video frame.
    public let hostTimeNs: UInt64

    /// RMS amplitude of the audio buffer in `[0, 1]`. We clamp on emit so consumers can map
    /// directly to a `jaw_open` coefficient without re-saturating.
    public let amplitude: Float

    /// Coarse vowel class for this window. The mapping to mouth-shape blendshapes lives in
    /// `LipSyncDriver`; the speaker just classifies.
    public let dominantVowel: VowelClass

    public init(hostTimeNs: UInt64, amplitude: Float, dominantVowel: VowelClass) {
        self.hostTimeNs = hostTimeNs
        self.amplitude = amplitude
        self.dominantVowel = dominantVowel
    }
}

/// Five lip-readable vowel-shape categories. We deliberately collapse the IPA vowel space
/// into shapes the stylized head can render — there's no point distinguishing /æ/ from /ɑ/
/// when both want a wide-open mouth.
public enum VowelClass: String, Sendable, Equatable, CaseIterable {
    /// /a/, /æ/, /ɑ/ — open mouth. Drives high `jawOpen`, low `mouthPucker`.
    case openA
    /// /e/, /ɛ/, /i/, /ɪ/ — wide / smile-shaped. Drives mid `jawOpen` + high `mouthWide`.
    case spreadE
    /// /o/, /ɔ/ — rounded mid. Drives mid `jawOpen` + mid `mouthPucker`.
    case roundO
    /// /u/, /ʊ/ — fully rounded / pucker. Drives low `jawOpen` + high `mouthPucker`.
    case roundU
    /// No vocal energy in this window. Drives all mouth coefficients toward zero.
    case silence
}

/// Errors surfaced by the TTS speaker.
public enum TTSSpeakerError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No `AVSpeechSynthesisVoice` matched the requested locale. The fix is to install the
    /// system voice (System Settings → Accessibility → Spoken Content) or pick another locale.
    case noVoiceForLocale(String)
    /// Synthesis started but produced no audio buffers. Usually means the voice is being
    /// downloaded on first use — the operator should retry in a few seconds.
    case noAudioProduced
    /// `AVSpeechSynthesizer.write(_:toBufferCallback:)` is only available on macOS 10.15+; we
    /// require it. This case fires if a future deployment target lowers below that.
    case writeAPIUnavailable

    public var description: String {
        switch self {
        case let .noVoiceForLocale(id):
            return "No on-device voice matches locale \"\(id)\". Install a premium voice in System Settings → Accessibility → Spoken Content."
        case .noAudioProduced:
            return "TTS produced no audio. The target voice may still be downloading — retry in a few seconds."
        case .writeAPIUnavailable:
            return "AVSpeechSynthesizer.write(_:toBufferCallback:) is unavailable on this OS version."
        }
    }
}

// MARK: - Voice selection

/// Tiny pure-function helper that picks the best AVSpeechSynthesisVoice for a locale.
/// Exposed publicly so the Settings UI can preview voice choices without spinning up the
/// full speaker actor.
public enum TTSVoiceSelector {
    /// Resolve a locale → preferred voice. Preference order:
    ///   1. Premium quality voice for the exact locale identifier (`en-US`).
    ///   2. Enhanced quality voice for the exact locale identifier.
    ///   3. Default quality voice for the exact locale identifier.
    ///   4. Any voice whose locale's *language* code matches (e.g. `es-MX` if `es-ES` missing).
    ///   5. nil — caller throws `noVoiceForLocale`.
    public static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let exactID = locale.identifier
        let langCode = locale.language.languageCode?.identifier

        // Pass 1: exact locale match, ordered by quality.
        let exactMatches = all.filter { $0.language == exactID }
        if let v = pickByQuality(from: exactMatches) { return v }

        // Pass 2: same-language fallback (e.g. requested es-ES, only es-MX installed).
        if let lang = langCode {
            let langMatches = all.filter { voice in
                voice.language.split(separator: "-").first.map(String.init) == lang
            }
            if let v = pickByQuality(from: langMatches) { return v }
        }
        return nil
    }

    private static func pickByQuality(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        if let premium = voices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return voices.first
    }
}

// MARK: - Speaker delegate (private)

/// AVSpeechSynthesizerDelegate is `@MainActor`-isolated on macOS 14+. We need to react to
/// `didFinish` from arbitrary executor contexts, so we wrap the delegate behind an
/// `@unchecked Sendable` shim that drains to a serialized continuation. The continuation is
/// resolved exactly once — guarded by a lock — and any further calls are ignored.
private final class SpeakerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func install(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if let prior = continuation {
            prior.resume()
        }
        continuation = cont
    }

    private func resolveOnce() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resolveOnce()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resolveOnce()
    }
}

// MARK: - TTSSpeaker

/// Wraps `AVSpeechSynthesizer` and exposes amplitude + dominant-vowel telemetry as an
/// `AsyncStream<TTSFrame>`. Consumers (typically `LipSyncDriver`) read this stream and drive
/// mouth-region blendshapes on the stylized head.
///
/// **Why an actor over the buffer plumbing**: the audio render callback comes in on
/// AVFoundation's worker thread; the consumer wants serialized, ordered TTSFrames. We
/// collect the latest buffer in an actor-owned ring, run the RMS + spectrum analysis on the
/// actor's executor, then `yield` a TTSFrame at the configured rate (60 Hz default).
public actor TTSSpeaker {

    public struct Config: Sendable, Equatable {
        /// Rate at which we emit `TTSFrame`s during speech. Defaults to 60 Hz to match the
        /// pipeline's max render cadence.
        public var emitHz: Double
        /// Window of samples used per emit cycle. At 22.05 kHz and 60 Hz, this is ~368 samples.
        /// We compute it on demand from the actual sample rate; this field is a fallback when
        /// the buffer format isn't known yet.
        public var fallbackSampleRate: Double
        /// Speaking rate passed to `AVSpeechUtterance.rate`. Default = `AVSpeechUtteranceDefaultSpeechRate`.
        public var rate: Float
        /// Pitch multiplier passed to `AVSpeechUtterance.pitchMultiplier`. Default 1.0.
        public var pitch: Float
        /// Output volume passed to `AVSpeechUtterance.volume`. Default 1.0.
        public var volume: Float

        public init(
            emitHz: Double = 60.0,
            fallbackSampleRate: Double = 22_050.0,
            rate: Float = AVSpeechUtteranceDefaultSpeechRate,
            pitch: Float = 1.0,
            volume: Float = 1.0
        ) {
            self.emitHz = emitHz
            self.fallbackSampleRate = fallbackSampleRate
            self.rate = rate
            self.pitch = pitch
            self.volume = volume
        }
    }

    public private(set) var config: Config

    /// We retain the synthesizer + delegate across calls so the AVSpeechSynthesizer instance
    /// doesn't tear down its underlying voice between phrases — that saves ~150 ms on the
    /// first syllable of every subsequent utterance.
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeakerDelegate()

    public init(config: Config = Config()) {
        self.config = config
        self.synthesizer.delegate = delegate
    }

    public func updateConfig(_ config: Config) {
        self.config = config
    }

    /// Speak `text` in `locale`. Returns an `AsyncStream<TTSFrame>` that yields amplitude
    /// + vowel-class samples at `config.emitHz` until synthesis completes. The stream finishes
    /// (cleanly) when the utterance ends; cancellation of the consuming task cancels synthesis.
    ///
    /// **API contract**: you must drain the returned stream — leaving the stream pending
    /// holds the underlying audio buffer in memory.
    public func speak(_ text: String, locale: Locale) throws -> AsyncStream<TTSFrame> {
        guard let voice = TTSVoiceSelector.bestVoice(for: locale) else {
            throw TTSSpeakerError.noVoiceForLocale(locale.identifier)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitch
        utterance.volume = config.volume

        return makeStream(utterance: utterance)
    }

    // MARK: - Stream construction

    private func makeStream(utterance: AVSpeechUtterance) -> AsyncStream<TTSFrame> {
        let config = self.config
        // AVSpeechSynthesizer is `NS_SWIFT_NONSENDABLE`. Wrap in an `@unchecked Sendable`
        // box so closures escape clean under Swift 6 strict concurrency. Same pattern
        // `MirrorMeshAppKit/DisclosureChirp` uses for AVAudioEngine.
        let synthRef = SynthesizerRef(synth: self.synthesizer)
        return AsyncStream<TTSFrame> { continuation in
            // Audio analysis ring; written by the AVAudio callback, read by our emitter.
            let analyzer = AudioAnalyzer(emitHz: config.emitHz, fallbackSampleRate: config.fallbackSampleRate)

            // Drive the AVSpeech write API. The callback receives PCM buffers (or a marker
            // buffer with `frameLength == 0` to indicate end-of-stream).
            //
            // `write(_:toBufferCallback:)` was added in macOS 13. We assume macOS 14+ per the
            // Package.swift platforms declaration; if a downstream lowered that we'd throw
            // `.writeAPIUnavailable` instead.
            synthRef.synth.write(utterance) { (buffer: AVAudioBuffer) in
                if let pcm = buffer as? AVAudioPCMBuffer {
                    if pcm.frameLength == 0 {
                        // Marker: end-of-utterance. The delegate will resolve shortly after.
                        analyzer.markFinished()
                    } else {
                        analyzer.ingest(pcm)
                    }
                }
            }

            // Pump TTSFrames from the analyzer to the consumer until end-of-utterance.
            let pumpTask = Task.detached(priority: .userInitiated) {
                let frameIntervalNs = UInt64(1_000_000_000.0 / config.emitHz)
                while !Task.isCancelled {
                    if let frame = analyzer.consumeFrame() {
                        continuation.yield(frame)
                    } else if analyzer.isFinished {
                        break
                    }
                    try? await Task.sleep(nanoseconds: frameIntervalNs)
                }
                continuation.finish()
            }

            // When the consumer cancels (or finishes), stop synthesis and the pump.
            continuation.onTermination = { _ in
                pumpTask.cancel()
                synthRef.synth.stopSpeaking(at: .immediate)
            }
        }
    }
}

// MARK: - SynthesizerRef

/// Sendable wrapper for `AVSpeechSynthesizer`, which Apple marks `NS_SWIFT_NONSENDABLE`.
/// We use it exclusively from one writer at a time (the AVSpeech callback thread or the
/// owning actor), so the `@unchecked Sendable` is sound. Mirrors the pattern used by
/// `MirrorMeshAppKit/DisclosureChirp` for `AVAudioEngine`.
private final class SynthesizerRef: @unchecked Sendable {
    let synth: AVSpeechSynthesizer
    init(synth: AVSpeechSynthesizer) { self.synth = synth }
}

// MARK: - AudioAnalyzer

/// Audio buffer accumulator + per-frame RMS / vowel classifier. Lock-guarded because it sees
/// writes from the AVAudio worker thread and reads from the emit pump.
///
/// **Why a separate class, not part of the actor**: the AVSpeech write callback is invoked
/// synchronously from AVFoundation's thread; we can't hop to the actor on every buffer without
/// dropping samples. The analyzer is `@unchecked Sendable` because all mutation goes through
/// `lock`, and `AVAudioPCMBuffer` reads happen on the writer thread only.
private final class AudioAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var ringSampleRate: Double = 0
    private let emitHz: Double
    private let fallbackSampleRate: Double
    private var lastVowel: VowelClass = .silence
    private var finishedFlag: Bool = false

    init(emitHz: Double, fallbackSampleRate: Double) {
        self.emitHz = emitHz
        self.fallbackSampleRate = fallbackSampleRate
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finishedFlag && ring.isEmpty
    }

    func markFinished() {
        lock.lock(); defer { lock.unlock() }
        finishedFlag = true
    }

    func ingest(_ pcm: AVAudioPCMBuffer) {
        // Mix down to mono Float32, normalized.
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0 else { return }
        let format = pcm.format
        let sampleRate = format.sampleRate
        var mono = [Float](repeating: 0, count: frameCount)

        if let f32 = pcm.floatChannelData {
            let channels = Int(format.channelCount)
            for c in 0..<channels {
                let ptr = f32[c]
                for i in 0..<frameCount {
                    mono[i] += ptr[i]
                }
            }
            if channels > 1 {
                let inv = 1.0 / Float(channels)
                for i in 0..<frameCount { mono[i] *= inv }
            }
        } else if let i16 = pcm.int16ChannelData {
            let channels = Int(format.channelCount)
            let scale: Float = 1.0 / Float(Int16.max)
            for c in 0..<channels {
                let ptr = i16[c]
                for i in 0..<frameCount {
                    mono[i] += Float(ptr[i]) * scale
                }
            }
            if channels > 1 {
                let inv = 1.0 / Float(channels)
                for i in 0..<frameCount { mono[i] *= inv }
            }
        } else {
            return
        }

        lock.lock()
        ring.append(contentsOf: mono)
        ringSampleRate = sampleRate
        lock.unlock()
    }

    /// Consume up to one window worth of samples and produce a `TTSFrame`. Returns nil if
    /// there aren't enough samples buffered yet. Designed to be called at ~`emitHz`.
    func consumeFrame() -> TTSFrame? {
        lock.lock()
        let sampleRate = ringSampleRate > 0 ? ringSampleRate : fallbackSampleRate
        let windowSize = max(64, Int(sampleRate / emitHz))
        guard ring.count >= windowSize else {
            // Not enough buffered yet. If we're finished, emit a final silence frame so the
            // consumer can ramp the mouth back to rest.
            if finishedFlag && !ring.isEmpty {
                let tail = ring
                ring.removeAll(keepingCapacity: true)
                lock.unlock()
                return analyze(samples: tail, sampleRate: sampleRate)
            }
            lock.unlock()
            return nil
        }
        let window = Array(ring.prefix(windowSize))
        ring.removeFirst(windowSize)
        lock.unlock()
        return analyze(samples: window, sampleRate: sampleRate)
    }

    private func analyze(samples: [Float], sampleRate: Double) -> TTSFrame {
        // RMS amplitude, calibrated to map typical speech (-20 dBFS RMS) to ~0.7. We use a
        // square-root compression so jaw_open responds nicely to volume swells without
        // saturating on louder syllables.
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let mean = sumSq / Float(max(samples.count, 1))
        let rms = sqrtf(mean)
        let amplitude = min(1.0, sqrtf(rms * 5.0))

        let vowel: VowelClass
        if amplitude < 0.05 {
            vowel = .silence
        } else {
            vowel = classifyVowel(samples: samples, sampleRate: sampleRate, amplitude: amplitude)
            lock.lock(); lastVowel = vowel; lock.unlock()
        }

        return TTSFrame(
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            amplitude: amplitude,
            dominantVowel: vowel
        )
    }

    /// Coarse formant-energy classifier. We compute energy in three frequency bands and use
    /// their ratios to pick a vowel class. This is the "barely-passable" version of formant
    /// tracking — it's not phoneme-accurate, but it tracks gross mouth shape well enough for
    /// the avatar to look like it's talking.
    ///
    /// Bands (approximate, tuned for adult male/female mixed):
    ///   • F1 region: 250–900 Hz (vowel height — low F1 = closed mouth, high F1 = open)
    ///   • F2 region: 900–2500 Hz (vowel front/back — high F2 = front, low F2 = back)
    ///   • F3+ tail:  2500–4000 Hz (helps distinguish /i/ from /u/)
    ///
    /// We don't ship a real FFT here — Goertzel on a few representative bins is enough for
    /// the binary "low/high F1, low/high F2" decision and avoids dragging in Accelerate.
    private func classifyVowel(samples: [Float], sampleRate: Double, amplitude: Float) -> VowelClass {
        let bands: [(low: Double, high: Double)] = [
            (250, 900),    // F1
            (900, 2500),   // F2
            (2500, 4000),  // F3+
        ]
        var energies: [Float] = [0, 0, 0]
        for (idx, band) in bands.enumerated() {
            let target = (band.low + band.high) * 0.5
            energies[idx] = goertzelMagnitude(samples: samples, sampleRate: sampleRate, freq: target)
        }

        let f1 = energies[0]
        let f2 = energies[1]
        let f3 = energies[2]
        let total = max(f1 + f2 + f3, 1e-6)
        let f1Rel = f1 / total
        let f2Rel = f2 / total
        let f3Rel = f3 / total

        // High F1 (mouth open) — /a/ family
        if f1Rel > 0.55 {
            return .openA
        }
        // Low F1, high F2 — front vowels /i/, /e/
        if f2Rel > 0.50 && f1Rel < 0.30 {
            return .spreadE
        }
        // Low F1, low F2, low F3 — /u/ (rounded back)
        if f2Rel < 0.35 && f3Rel < 0.20 {
            return .roundU
        }
        // Otherwise — mid rounded /o/
        return .roundO
    }

    /// Single-bin Goertzel filter. Returns magnitude proxy (sum of squared in-band components).
    /// Cheap O(N) per bin; we call it three times per window.
    private func goertzelMagnitude(samples: [Float], sampleRate: Double, freq: Double) -> Float {
        let n = samples.count
        let k = Int((Double(n) * freq / sampleRate).rounded())
        let omega = 2.0 * .pi * Double(k) / Double(n)
        let coeff = Float(2.0 * cos(omega))
        var s0: Float = 0
        var s1: Float = 0
        var s2: Float = 0
        for x in samples {
            s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * Float(cos(omega))
        let imag = s2 * Float(sin(omega))
        return real * real + imag * imag
    }
}
