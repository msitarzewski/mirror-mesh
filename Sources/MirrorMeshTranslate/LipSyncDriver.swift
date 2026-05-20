import Foundation
import MirrorMeshCore
import MirrorMeshReenact

// ─────────────────────────────────────────────────────────────────────────────
// ORCHESTRATOR INTEGRATION POINTS  (v0.8.0 accessibility — multilingual lip-sync)
// ─────────────────────────────────────────────────────────────────────────────
//
// This module (`MirrorMeshTranslate`) is built as a standalone library so the
// translation + TTS + lip-sync surface can be exercised end-to-end without the
// GUI. To wire it into the live pipeline the orchestrator must make the
// following edits — none of them are made here (we own only Sources/MirrorMeshTranslate/,
// Sources/mirrormesh-translate/, and Tests/MirrorMeshTranslateTests/).
//
// 1) Package.swift — add the library, executable, and test target. Insert under
//    the existing library list:
//
//        .library(name: "MirrorMeshTranslate", targets: ["MirrorMeshTranslate"]),
//
//    and under products:
//
//        .executable(name: "mirrormesh-translate", targets: ["mirrormesh-translate"]),
//
//    Under `targets:`, add:
//
//        .target(
//            name: "MirrorMeshTranslate",
//            dependencies: [
//                "MirrorMeshCore",
//                "MirrorMeshReenact",   // StylizedBlendshape + ReenactedFrame
//            ],
//            path: "Sources/MirrorMeshTranslate"
//        ),
//        .executableTarget(
//            name: "mirrormesh-translate",
//            dependencies: ["MirrorMeshCore", "MirrorMeshTranslate"],
//            path: "Sources/mirrormesh-translate"
//        ),
//        .testTarget(
//            name: "MirrorMeshTranslateTests",
//            dependencies: [
//                "MirrorMeshTranslate",
//                "MirrorMeshReenact",
//                "MirrorMeshCore",
//            ],
//            path: "Tests/MirrorMeshTranslateTests"
//        ),
//
//    Then add MirrorMeshTranslate as a dependency of MirrorMeshOutput and
//    MirrorMeshAppKit so the Pipeline + Settings UI can `import MirrorMeshTranslate`.
//
// 2) Sources/MirrorMeshOutput/Pipeline.swift — add an optional `TranslationStage`
//    that sits between the voice transcript bus and the renderer's blendshape input.
//    Suggested integration (mirrors the existing `ReenactStage` pattern):
//
//        import MirrorMeshTranslate
//
//        // In PipelineOptions:
//        public var translation: TranslationStageOptions? = nil   // see this file
//
//        // In Pipeline.run(), after the reenactStage is constructed:
//        var translationStage: TranslationStage? = nil
//        if let opts = options.translation {
//            translationStage = TranslationStage(options: opts)
//            // Subscribe the stage to TranscriptFrame events from the voice bus.
//            // The stage exposes an async overlay() method whose return value is
//            // merged into the renderer's stylized-head coefficients via
//            // ReenactedFrame.overlayLipSync(_:).
//        }
//
//        // In the per-frame loop, AFTER ReenactStage.apply produced `reenacted`:
//        if let stage = translationStage,
//           let coeffs = await stage.currentOverlay(at: hostTimeNs) {
//            reenacted = reenacted.overlayLipSync(coeffs)  // see LipSyncCoefficients.overlay
//        }
//
//    The pipeline then passes `reenacted` to the renderer unchanged. The renderer
//    treats the overlaid coefficients identically to the solver's output.
//
// 3) Sources/MirrorMeshReenact/FaceReenactor.swift — extend with a method that
//    accepts `LipSyncCoefficients` and merges them into the next reenact() call's
//    output. The orchestrator owns this edit; the API surface this module needs is:
//
//        public extension ReenactFrame {
//            /// Return a new ReenactFrame with the given lip-sync coefficients
//            /// replacing the mouth-region coefficients from the geometric solver.
//            /// Used when audio-driven lip-sync is active so the avatar's mouth
//            /// matches the synthesized speech, not the operator's silent mouth.
//            func overlayLipSync(_ overlay: LipSyncCoefficients) -> ReenactFrame
//        }
//
//    The implementation should: (a) start from `self.coefficients`, (b) for each
//    key in `overlay.values` (which is restricted to mouth-region shapes), replace
//    the solver's coefficient with the overlay's, (c) re-call
//    `StylizedHeadModel.deform(coefficients:)` to regenerate vertices and normals.
//    This module ships `LipSyncCoefficients` already; the merge / re-deform lives
//    on the Reenact side because it owns the model. See `LipSyncCoefficients.mouthShapeKeys`.
//
// 4) Sources/MirrorMeshAppKit — owned by the AppKit-touching agent. The Settings
//    inspector gains a "Translation" section with:
//      • toggle: "Translate speech in real time" (off by default)
//      • picker: source language (defaults to system locale)
//      • picker: target language
//      • picker: Ollama model (text field with a sensible default of `llama3.2:3b`)
//      • read-only line: "Translation provided by local Ollama at http://localhost:11434/"
//    The AppKit agent calls `Pipeline.setTranslationOptions(_:)` (a new public
//    method analogous to `setRendererOptions`) to drive the stage at runtime.
//
// 5) Sources/MirrorMeshWatermark/PipelineConfig.swift — when the translation
//    stage is active the watermark must record it. Orchestrator MUST extend
//    `WatermarkConfig` with:
//
//        public var voice_transformed: Bool
//
//    surfaced from this module via `TranslationStage.isActive`. The visible
//    watermark badge and the signed manifest then both record that the avatar
//    spoke a translated language. R2 — disclosure is mandatory.
//
//    ORCHESTRATOR: extend WatermarkConfig with voice_transformed: bool
//
// 6) R12 — disclosure chirp must remain audible whenever translation is on.
//    The existing `chirpEnabled` setting in AppSettings already has the
//    `chirpLockedInRelease` pattern; reuse it. Orchestrator should treat
//    "translation enabled" as another locked-on condition for the chirp so
//    operators who can disable the chirp in debug builds cannot do so while
//    a voice transform is running. Pattern:
//
//        public var effectiveChirpEnabled: Bool {
//            chirpLockedInRelease || translationActive ? true : chirpEnabled
//        }
//
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - LipSyncCoefficients

/// The audio-driven mouth-region overlay that `LipSyncDriver` emits. Restricted, by
/// construction, to the four mouth-shape blendshapes the stylized head supports — `jawOpen`,
/// `mouthPucker`, `mouthWide`, plus the soft smile (`smileL`/`smileR`) that we open during
/// `/e/` vowels.
///
/// **Why a dedicated type, not just `[StylizedBlendshape: Float]`**: the overlay is a contract.
/// `FaceReenactor.overlay` (added by the orchestrator per integration step 3) needs to know
/// *which* keys are mouth-region so it leaves the operator's brow / eye coefficients alone.
/// Bundling the keys with the values prevents callers from accidentally muting an unrelated
/// shape.
public struct LipSyncCoefficients: Sendable, Equatable {
    /// The mouth-region keys this overlay is allowed to touch. Used by the renderer-side merge
    /// to "passthrough everything else". Static so it's a compile-time constant.
    public static let mouthShapeKeys: Set<StylizedBlendshape> = [
        .jawOpen,
        .mouthPucker,
        .mouthWide,
        .smileL,
        .smileR,
    ]

    /// `[StylizedBlendshape: Float]` restricted to `mouthShapeKeys`. Values are clamped to
    /// `[0, 1]` at construction time so the renderer can apply them without re-saturating.
    public let values: [StylizedBlendshape: Float]

    /// Host-time of the audio sample this overlay was derived from. The pipeline uses this to
    /// pick the most recent overlay whose hostTimeNs is ≤ the current video frame's hostTimeNs
    /// (one-sided nearest-neighbor — we never want to show a mouth shape that hasn't been
    /// "heard" yet by the audio path).
    public let hostTimeNs: UInt64

    public init(values: [StylizedBlendshape: Float], hostTimeNs: UInt64) {
        // Filter to the allowed mouth-region keys; saturate.
        var clean: [StylizedBlendshape: Float] = [:]
        for (k, v) in values where Self.mouthShapeKeys.contains(k) {
            clean[k] = min(1.0, max(0.0, v))
        }
        self.values = clean
        self.hostTimeNs = hostTimeNs
    }

    /// All-zero overlay (mouth at rest). Useful as a sentinel between utterances.
    public static func rest(at hostTimeNs: UInt64) -> LipSyncCoefficients {
        return LipSyncCoefficients(values: [
            .jawOpen: 0,
            .mouthPucker: 0,
            .mouthWide: 0,
            .smileL: 0,
            .smileR: 0,
        ], hostTimeNs: hostTimeNs)
    }
}

// MARK: - Configurable overlay behaviour

public struct LipSyncOptions: Sendable, Equatable {
    /// Smoothing time constant in seconds. The driver feeds each output channel through a
    /// One-Euro filter (already used elsewhere in the project for landmark smoothing); this
    /// `minCutoff` sets the baseline cutoff for that filter. Lower = smoother + laggier,
    /// higher = snappier + jitterier. Default 1.5 Hz gives natural lip motion at 60 FPS.
    public var smoothingMinCutoff: Double

    /// Beta term for the One-Euro filter — how aggressively it relaxes the cutoff on fast
    /// motion. Defaults to the value used by `MirrorMeshVision/LandmarkExtractor` so the
    /// behaviour feels consistent with the existing pipeline.
    public var smoothingBeta: Double

    /// Maximum value the jaw-open coefficient can reach. The stylized head can technically
    /// take coefficients up to 1.5 (see StylizedHeadModel.deform clamp) but voice rarely
    /// drives the mouth fully open; capping at 0.85 keeps the deformation in the
    /// well-tuned range.
    public var jawOpenMax: Float

    /// How much the dominant vowel contributes to the mouth-shape coefficients. Set to 0 for
    /// "amplitude-only" mode (jaw drives mouth, no pucker/wide); 1 for full vowel-shaped
    /// motion. Default 0.8 leaves a touch of audio-amplitude variation visible even on
    /// pure-vowel sustained tones.
    public var vowelShapeStrength: Float

    public init(
        smoothingMinCutoff: Double = 1.5,
        smoothingBeta: Double = 0.5,
        jawOpenMax: Float = 0.85,
        vowelShapeStrength: Float = 0.8
    ) {
        self.smoothingMinCutoff = smoothingMinCutoff
        self.smoothingBeta = smoothingBeta
        self.jawOpenMax = jawOpenMax
        self.vowelShapeStrength = vowelShapeStrength
    }
}

// MARK: - LipSyncDriver

/// Converts a stream of `TTSFrame` (amplitude + vowel class, from `TTSSpeaker`) into a
/// stream of `LipSyncCoefficients` (mouth-region blendshape values, fed into the renderer's
/// `StylizedHead` overlay).
///
/// **Mapping** (per the task spec):
///   • /a/, /æ/ (`.openA`)  → high `jawOpen`, low `mouthPucker`
///   • /o/, /u/ (`.roundO`, `.roundU`) → low `jawOpen`, high `mouthPucker`
///   • /i/, /e/ (`.spreadE`) → wide `mouthWide`, mid `jawOpen`, soft smile lift
///   • silence (`.silence`) → all toward zero
///
/// **Smoothing**: each output channel is fed through a One-Euro filter (the same pattern
/// used in `MirrorMeshVision/LandmarkExtractor`) so the mouth doesn't jitter on noisy
/// amplitude readings. Filters are stored as instance state — one per channel.
///
/// **Why a final class, not an actor**: the driver runs synchronously inside the consuming
/// task's executor. Wrapping it in an actor would force every audio frame through a hop.
/// All mutable state (the One-Euro filter set) is private; the public surface is
/// `update(_:) -> LipSyncCoefficients` which is a value-in, value-out function.
public final class LipSyncDriver: @unchecked Sendable {
    public private(set) var options: LipSyncOptions

    // Per-channel One-Euro filters. Initialized lazily on first `update(...)`.
    private var jawFilter: OneEuroSmoother
    private var puckerFilter: OneEuroSmoother
    private var wideFilter: OneEuroSmoother
    private var smileLFilter: OneEuroSmoother
    private var smileRFilter: OneEuroSmoother

    public init(options: LipSyncOptions = LipSyncOptions()) {
        self.options = options
        self.jawFilter   = OneEuroSmoother(minCutoff: options.smoothingMinCutoff, beta: options.smoothingBeta)
        self.puckerFilter = OneEuroSmoother(minCutoff: options.smoothingMinCutoff, beta: options.smoothingBeta)
        self.wideFilter  = OneEuroSmoother(minCutoff: options.smoothingMinCutoff, beta: options.smoothingBeta)
        self.smileLFilter = OneEuroSmoother(minCutoff: options.smoothingMinCutoff, beta: options.smoothingBeta)
        self.smileRFilter = OneEuroSmoother(minCutoff: options.smoothingMinCutoff, beta: options.smoothingBeta)
    }

    public func updateOptions(_ newOptions: LipSyncOptions) {
        self.options = newOptions
        self.jawFilter.minCutoff   = newOptions.smoothingMinCutoff
        self.puckerFilter.minCutoff = newOptions.smoothingMinCutoff
        self.wideFilter.minCutoff  = newOptions.smoothingMinCutoff
        self.smileLFilter.minCutoff = newOptions.smoothingMinCutoff
        self.smileRFilter.minCutoff = newOptions.smoothingMinCutoff
        self.jawFilter.beta   = newOptions.smoothingBeta
        self.puckerFilter.beta = newOptions.smoothingBeta
        self.wideFilter.beta  = newOptions.smoothingBeta
        self.smileLFilter.beta = newOptions.smoothingBeta
        self.smileRFilter.beta = newOptions.smoothingBeta
    }

    /// Reset the smoothing filters. Call between utterances so the mouth returns to rest
    /// without carrying jitter from the previous phrase.
    public func reset() {
        jawFilter.reset()
        puckerFilter.reset()
        wideFilter.reset()
        smileLFilter.reset()
        smileRFilter.reset()
    }

    /// Convert a TTSFrame into a LipSyncCoefficients overlay. Deterministic — same input
    /// frame stream produces the same output stream (modulo the filter's time-dependent
    /// smoothing).
    public func update(_ frame: TTSFrame) -> LipSyncCoefficients {
        // Step 1: raw per-shape targets from amplitude + vowel class.
        let amp = max(0, min(1, frame.amplitude))
        let raw = vowelShapeTargets(vowel: frame.dominantVowel, amplitude: amp)

        // Step 2: smooth each channel through the One-Euro filter.
        let t = frame.hostTimeNs
        let jaw    = Float(jawFilter.filter(Double(raw.jawOpen),    atTimeNs: t))
        let pucker = Float(puckerFilter.filter(Double(raw.mouthPucker), atTimeNs: t))
        let wide   = Float(wideFilter.filter(Double(raw.mouthWide),  atTimeNs: t))
        let smL    = Float(smileLFilter.filter(Double(raw.smileL),    atTimeNs: t))
        let smR    = Float(smileRFilter.filter(Double(raw.smileR),    atTimeNs: t))

        // Step 3: cap jaw, build the coefficient dictionary.
        let cappedJaw = min(jaw, options.jawOpenMax)
        return LipSyncCoefficients(values: [
            .jawOpen:    cappedJaw,
            .mouthPucker: pucker,
            .mouthWide:  wide,
            .smileL:     smL,
            .smileR:     smR,
        ], hostTimeNs: frame.hostTimeNs)
    }

    // MARK: - Internal target shaping

    /// Pure mapping vowel + amplitude → target channel values, before smoothing. Tested
    /// directly so the integration tests don't need to fight the filter time constants.
    public func vowelShapeTargets(vowel: VowelClass, amplitude amp: Float) -> (jawOpen: Float, mouthPucker: Float, mouthWide: Float, smileL: Float, smileR: Float) {
        let shape = options.vowelShapeStrength
        let one: Float = 1.0
        switch vowel {
        case .openA:
            // High jaw, low pucker, low wide. amp scales the absolute jaw.
            return (
                jawOpen: amp * 1.0,
                mouthPucker: amp * 0.05 * (one - shape),
                mouthWide: amp * 0.10 * (one - shape),
                smileL: 0,
                smileR: 0
            )
        case .spreadE:
            // Mid jaw, high wide, soft smile. amp scales wide.
            return (
                jawOpen: amp * 0.45,
                mouthPucker: 0,
                mouthWide: amp * 0.85 * shape + amp * 0.30 * (one - shape),
                smileL: amp * 0.30 * shape,
                smileR: amp * 0.30 * shape
            )
        case .roundO:
            // Mid jaw, mid pucker.
            return (
                jawOpen: amp * 0.55,
                mouthPucker: amp * 0.55 * shape + amp * 0.20 * (one - shape),
                mouthWide: 0,
                smileL: 0,
                smileR: 0
            )
        case .roundU:
            // Low jaw, high pucker.
            return (
                jawOpen: amp * 0.25,
                mouthPucker: amp * 0.90 * shape + amp * 0.30 * (one - shape),
                mouthWide: 0,
                smileL: 0,
                smileR: 0
            )
        case .silence:
            // All zeros — the smoothing will glide the mouth back to rest.
            return (0, 0, 0, 0, 0)
        }
    }
}

// MARK: - OneEuroSmoother

/// Minimal copy of the One-Euro smoothing function used in `MirrorMeshVision/OneEuroFilter`.
/// We don't depend on MirrorMeshVision here because that target also pulls in MirrorMeshCapture
/// (and transitively AVFoundation in a different role); duplicating ~30 lines of math keeps
/// the dependency footprint of MirrorMeshTranslate strictly to Core + Reenact.
///
/// **R6 (reuse before create) note**: this is the only piece of code that's a direct port —
/// it's small, well-tested, and the alternative (depending on MirrorMeshVision) would create
/// a circular flavour when AppKit later wires both modules into the Settings UI.
internal struct OneEuroSmoother {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double = 1.0

    private var lastValue: Double = .nan
    private var lastDerivative: Double = 0
    private var lastTimeNs: UInt64 = 0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ value: Double, atTimeNs t: UInt64) -> Double {
        defer { lastTimeNs = t }
        guard lastValue.isFinite else {
            lastValue = value
            return value
        }
        let dt = max(1e-6, Double(t &- lastTimeNs) / 1_000_000_000)
        let derivative = (value - lastValue) / dt
        let alphaD = smoothingFactor(dt: dt, cutoff: dCutoff)
        let smoothD = alphaD * derivative + (1 - alphaD) * lastDerivative
        let cutoff = minCutoff + beta * abs(smoothD)
        let alpha = smoothingFactor(dt: dt, cutoff: cutoff)
        let smoothed = alpha * value + (1 - alpha) * lastValue
        lastValue = smoothed
        lastDerivative = smoothD
        return smoothed
    }

    mutating func reset() {
        lastValue = .nan
        lastDerivative = 0
        lastTimeNs = 0
    }

    private func smoothingFactor(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

// MARK: - TranslationStageOptions + TranslationStage façade

/// Options the orchestrator passes to `TranslationStage`. Mirrors `PipelineOptions` style.
public struct TranslationStageOptions: Sendable, Equatable {
    public var enabled: Bool
    public var sourceLocale: Locale
    public var targetLocale: Locale
    public var ollama: OllamaConfig
    public var tts: TTSSpeaker.Config
    public var lipSync: LipSyncOptions

    public init(
        enabled: Bool = false,
        sourceLocale: Locale = Locale(identifier: "en-US"),
        targetLocale: Locale = Locale(identifier: "es-ES"),
        ollama: OllamaConfig = OllamaConfig(),
        tts: TTSSpeaker.Config = TTSSpeaker.Config(),
        lipSync: LipSyncOptions = LipSyncOptions()
    ) {
        self.enabled = enabled
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.ollama = ollama
        self.tts = tts
        self.lipSync = lipSync
    }
}

/// Cohesive façade that the orchestrator instantiates inside `Pipeline.run()`. Wraps the
/// three subsystems behind a single async surface so the pipeline doesn't have to know
/// about Ollama / AVSpeech / the driver directly.
///
/// **Lifecycle**: construct once per pipeline. Call `speak(_:)` whenever the upstream voice
/// transcript bus emits a finalized `TranscriptFrame` (the orchestrator handles the
/// subscription). The stage drives Ollama → TTSSpeaker → LipSyncDriver internally and stores
/// the most recent `LipSyncCoefficients` for the pipeline to pull via `currentOverlay(at:)`.
public actor TranslationStage {
    public private(set) var options: TranslationStageOptions

    private let translator: OllamaTranslator
    private let speaker: TTSSpeaker
    private let driver: LipSyncDriver

    /// Latest overlay produced. Read by the pipeline on each render frame.
    private var latestOverlay: LipSyncCoefficients

    /// True iff the stage has produced at least one overlay since the last `speak(_:)`.
    /// Surfaced via `isActive` so the watermark/manifest can flag "voice_transformed".
    private var hasActiveOverlay: Bool = false

    public init(options: TranslationStageOptions) {
        self.options = options
        self.translator = OllamaTranslator(config: options.ollama)
        self.speaker = TTSSpeaker(config: options.tts)
        self.driver = LipSyncDriver(options: options.lipSync)
        self.latestOverlay = LipSyncCoefficients.rest(at: MirrorMeshCore.hostTimeNs())
    }

    /// True iff a voice transform has produced a non-rest overlay since the last reset. The
    /// orchestrator surfaces this to `WatermarkConfig.voice_transformed`.
    public var isActive: Bool { hasActiveOverlay }

    public func updateOptions(_ newOptions: TranslationStageOptions) async {
        self.options = newOptions
        await translator.updateConfig(newOptions.ollama)
        await speaker.updateConfig(newOptions.tts)
        driver.updateOptions(newOptions.lipSync)
    }

    /// Drive the full translate-then-speak-then-lipsync pipeline for one transcript. Returns
    /// when the synthesizer finishes the utterance. While running, calls to
    /// `currentOverlay(at:)` return the latest mouth shape.
    ///
    /// Errors bubble up to the caller; the pipeline orchestrator decides whether to surface
    /// them as telemetry warnings or silently fall back to no-translation.
    public func speak(_ text: String) async throws {
        guard options.enabled else { return }

        // 1) Translate.
        let translated = try await translator.translate(text, from: options.sourceLocale, to: options.targetLocale)
        guard !translated.isEmpty else { return }

        // 2) Reset the lip-sync driver so the previous utterance's smoothing doesn't bleed in.
        driver.reset()

        // 3) Synthesize + drive lip-sync.
        let stream = try await speaker.speak(translated, locale: options.targetLocale)
        for await ttsFrame in stream {
            let overlay = driver.update(ttsFrame)
            latestOverlay = overlay
            hasActiveOverlay = true
        }

        // 4) After the utterance, glide the mouth back to rest.
        let restFrame = TTSFrame(
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            amplitude: 0,
            dominantVowel: .silence
        )
        latestOverlay = driver.update(restFrame)
    }

    /// Return the most recent overlay if it's still fresh relative to `hostTimeNs`. The
    /// pipeline calls this on every video frame and merges the result into the renderer's
    /// stylized-head coefficients.
    ///
    /// **Freshness**: we hold the overlay for up to 200 ms after the audio sample so a slight
    /// audio-video clock skew doesn't drop frames; older than that, we return a rest overlay
    /// so the mouth doesn't "stick" between utterances.
    public func currentOverlay(at hostTimeNs: UInt64) -> LipSyncCoefficients {
        let staleNs: UInt64 = 200_000_000  // 200 ms
        if hostTimeNs &- latestOverlay.hostTimeNs > staleNs {
            return LipSyncCoefficients.rest(at: hostTimeNs)
        }
        return latestOverlay
    }
}
