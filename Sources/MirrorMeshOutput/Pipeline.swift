import Foundation
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshVision
import MirrorMeshSolver
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshRecorder
import MirrorMeshVirtualCamera
import MirrorMeshReenact
import MirrorMeshVoice
import MirrorMeshTranslate

/// Choose how the pipeline ingests frames and how it produces landmarks.
public enum PipelineMode: Sendable {
    /// Real camera + Apple Vision landmarks. SwiftUI app default.
    case live
    /// Procedural frames + procedural landmarks. CI / headless bench / no-camera demos.
    case synthetic
    /// File-backed frames + Apple Vision landmarks. Lets headless CI exercise the live path.
    case file(URL)
}

public struct PipelineOptions: Sendable {
    /// Which expression solver to instantiate. Default `.geometric` preserves existing behavior.
    public enum SolverKind: String, Sendable, Codable {
        case geometric
        case coreml
    }

    public var mode: PipelineMode
    public var captureWidth: Int
    public var captureHeight: Int
    public var fps: Int
    public var maxFrames: Int?      // nil = run until stop()
    public var rendererOptions: Renderer.Options
    public var recorderURL: URL?    // nil = recorder disabled
    public var recorderCodec: VideoCodec
    public var solverKind: SolverKind
    /// Optional override for the landmark backend. When nil, the pipeline picks
    /// `SyntheticLandmarkExtractor` for `.synthetic` mode and `VisionLandmarkBackend` otherwise.
    /// Set this to inject `MediaPipeLandmarkBackend` (M26) or any future backend.
    public var landmarkBackend: (any LandmarkBackend)?
    /// Tag for the chosen backend recorded in the session manifest. Defaults to
    /// `"vision"` (or `"synthetic"` in synthetic mode); MediaPipe scenarios set `"mediapipe"`.
    public var landmarkBackendTag: String?
    /// When true, push each watermarked frame to the MirrorMesh CMIO extension over XPC.
    /// Silent no-op when the extension isn't installed (unsigned dev builds, missing Team ID).
    public var virtualCameraEnabled: Bool
    /// When true, emit a `.coefficients` telemetry event per frame. Off by default — only bench
    /// traces and solver-comparison runs enable it because the payload (52 floats per frame)
    /// dominates the JSONL volume.
    public var logCoefficients: Bool
    /// M56: optional verified identity bundle. When both fields are non-nil and the pair verifies
    /// at start, the pipeline composites a stylized 3D head driven by the live landmark stream.
    public var consentedIdentity: ConsentedIdentity?
    public var consentedIdentityPNG: Data?

    /// v0.7.0 voice integration. When true, the pipeline spins up a `VoiceStage` that drives the
    /// on-device Apple Speech recognizer for transcripts. Manifest's `audible_chirp` is forced
    /// true (R2 disclosure).
    public var voiceEnabled: Bool
    /// BCP-47 locale used to construct the speech backend. Honored only when `voiceEnabled`.
    public var voiceLocale: String
    /// v0.8.0 translation integration. When true, the pipeline spins up a `TranslationPipelineStage`
    /// that consumes voice transcripts, drives Ollama → AVSpeechSynthesizer → LipSyncDriver, and
    /// applies the resulting mouth-region overlay to each rendered frame. Implies `voiceEnabled`
    /// at runtime (the pipeline will turn it on if you forget); manifest's `voice_transformed`
    /// flips true on first overlay produced.
    public var translationEnabled: Bool
    /// Options for the translation stage. Required when `translationEnabled`; ignored otherwise.
    /// Carries source/target locale, Ollama config, TTS config, and lip-sync smoothing options.
    public var translationOptions: TranslationStageOptions?

    public init(mode: PipelineMode = .synthetic,
                captureWidth: Int = 640,
                captureHeight: Int = 360,
                fps: Int = 30,
                maxFrames: Int? = nil,
                rendererOptions: Renderer.Options = .init(),
                recorderURL: URL? = nil,
                recorderCodec: VideoCodec = .h264,
                solverKind: SolverKind = .geometric,
                landmarkBackend: (any LandmarkBackend)? = nil,
                landmarkBackendTag: String? = nil,
                virtualCameraEnabled: Bool = false,
                logCoefficients: Bool = false,
                consentedIdentity: ConsentedIdentity? = nil,
                consentedIdentityPNG: Data? = nil,
                voiceEnabled: Bool = false,
                voiceLocale: String = "en-US",
                translationEnabled: Bool = false,
                translationOptions: TranslationStageOptions? = nil) {
        self.mode = mode
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.fps = fps
        self.maxFrames = maxFrames
        self.rendererOptions = rendererOptions
        self.recorderURL = recorderURL
        self.recorderCodec = recorderCodec
        self.solverKind = solverKind
        self.landmarkBackend = landmarkBackend
        self.landmarkBackendTag = landmarkBackendTag
        self.virtualCameraEnabled = virtualCameraEnabled
        self.logCoefficients = logCoefficients
        self.consentedIdentity = consentedIdentity
        self.consentedIdentityPNG = consentedIdentityPNG
        self.voiceEnabled = voiceEnabled
        self.voiceLocale = voiceLocale
        self.translationEnabled = translationEnabled
        self.translationOptions = translationOptions
    }
}

public struct PipelineResult: Sendable {
    public let framesProcessed: Int
    public let manifestURL: URL
    public let endToEndP50Ms: Double
    public let endToEndP95Ms: Double
    public let endToEndP99Ms: Double
}

/// Configuration errors raised by `Pipeline` when the requested option combination is
/// inconsistent. Distinct from runtime errors (capture, vision, etc.) so callers can branch.
public enum PipelineConfigurationError: Error, CustomStringConvertible, Sendable, Equatable {
    /// `setTranslationEnabled(true, ...)` was called with no `TranslationStageOptions` set
    /// — neither in the previous options nor in the call's `newOptions` param.
    case translationOptionsRequired

    public var description: String {
        switch self {
        case .translationOptionsRequired:
            return "Pipeline: translation enabled but no TranslationStageOptions provided"
        }
    }
}

/// End-to-end orchestrator: capture → vision → solver → render → watermark.
/// Owns a session manifest and a JSONL telemetry sink.
public actor Pipeline {
    public private(set) var options: PipelineOptions
    public let manifestURL: URL
    public let jsonlURL: URL?

    private var stopped = false
    // Why: SwiftUI preview needs the latest RenderedFrame after each render; the callback fires
    // post-render and pre-watermark accounting so a Metal preview sees pixels with minimum delay.
    private var onRender: (@Sendable (RenderedFrame) -> Void)?
    /// Why: M43 PIP — the SwiftUI camera-as-PIP overlay needs the raw `CapturedFrame` before
    /// rendering applies any synthetic styling, so the operator can verify themselves.
    private var onCapture: (@Sendable (CapturedFrame) -> Void)?
    /// v0.7.0: every transcript from the active VoiceStage fans out here for the UI / captions.
    private var onTranscript: (@Sendable (Transcript) -> Void)?
    /// v0.8.0: every successful translation fans out here for the UI / captions.
    private var onTranslation: (@Sendable (String) -> Void)?
    private var renderer: Renderer?
    private var watermarker: Watermarker?
    private var reenactStage: ReenactStage?
    /// v0.7.0/v0.8.0: live voice + translation stages. Constructed lazily inside `run()` when
    /// the corresponding option is enabled. Lifetime is bounded by the run-loop's cleanup tail.
    private var voiceStage: VoiceStage?
    private var translationStage: TranslationPipelineStage?
    /// Manifest writer held so `setTranslationEnabled` can hot-update the manifest when
    /// translation is toggled mid-session. Pre-`run()` this is nil; the in-memory option flag
    /// still flips, but the persisted manifest is updated on the next finalize.
    private var manifestWriter: ManifestWriter?

    public init(options: PipelineOptions,
                manifestURL: URL,
                jsonlURL: URL?) {
        self.options = options
        self.manifestURL = manifestURL
        self.jsonlURL = jsonlURL
    }

    /// Install a callback invoked after every successful render. Pass `nil` to detach.
    /// Note: invoked from the pipeline actor; downstream code must hop to its own isolation.
    public func setOnRender(_ cb: (@Sendable (RenderedFrame) -> Void)?) {
        self.onRender = cb
    }

    /// Install a callback invoked for every captured frame *before* render. Used by the
    /// camera-as-PIP overlay so the operator's real face is verifiable when the hero view is
    /// a synthetic transformation.
    public func setOnCapture(_ cb: (@Sendable (CapturedFrame) -> Void)?) {
        self.onCapture = cb
    }

    /// Update the renderer's overlay toggles live (driven by the SwiftUI Settings panel).
    /// No-op when the pipeline hasn't started yet — the next start() reads `options.rendererOptions`.
    public func setRendererOptions(_ opts: Renderer.Options) {
        options.rendererOptions = opts
        renderer?.options = opts
    }

    /// Toggle the visible watermark badge live. In release builds, the underlying Watermarker
    /// ignores attempts to disable it (per projectRules R2).
    public func setWatermarkVisible(_ visible: Bool) {
        watermarker?.visible = visible
    }

    /// M56: hot-swap the consented identity while the pipeline is running. Passing `(nil, nil)`
    /// clears the identity and disables the stylized-head pass. Throws on verification failure;
    /// the previous identity (if any) stays loaded on failure.
    public func setConsentedIdentity(_ identity: ConsentedIdentity?, pngBytes: Data?) async throws {
        options.consentedIdentity = identity
        options.consentedIdentityPNG = pngBytes
        if let stage = reenactStage {
            if let id = identity, let png = pngBytes {
                try await stage.setIdentity(id, pngBytes: png)
            } else {
                await stage.clearIdentity()
            }
        }
    }

    /// v0.7.0: install/clear the transcript fan-out callback. Mirrors `setOnRender`/`setOnCapture`.
    public func setOnTranscript(_ cb: (@Sendable (Transcript) -> Void)?) async {
        self.onTranscript = cb
        if let stage = voiceStage {
            await stage.setOnTranscript(makeTranscriptForwarder())
        }
    }

    /// v0.8.0: install/clear the translation-result fan-out callback. The orchestrator surfaces
    /// the translated string to the captions UI without coupling AppKit to MirrorMeshTranslate.
    public func setOnTranslation(_ cb: (@Sendable (String) -> Void)?) async {
        self.onTranslation = cb
        if let stage = translationStage {
            await stage.setOnTranslation(cb)
        }
    }

    /// v0.7.0: enable/disable voice capture at runtime. When called pre-`run()` this only
    /// updates the option flag; the next `run()` honors it. When called mid-run with the
    /// pipeline active, the stage is brought up / torn down in place. Throws if voice
    /// startup fails (locale unsupported, permission denied, audio engine failure).
    public func setVoiceEnabled(_ on: Bool) async throws {
        options.voiceEnabled = on
        // Mid-run flip — only valid when the pipeline is already mid-loop. Pre-run flips just
        // update options and let `run()` honour them.
        guard !stopped else { return }
        if on && voiceStage == nil {
            try await startVoiceStage()
        } else if !on, let stage = voiceStage {
            await stage.stop()
            self.voiceStage = nil
        }
    }

    /// v0.8.0: enable/disable translation at runtime. Updates the manifest's watermark config
    /// in-place when toggled mid-run, so the persisted record reflects the policy in force at
    /// each transition. Pre-`run()` just updates the option flag. Throws when translation
    /// is requested without `options.translationOptions` set.
    public func setTranslationEnabled(_ on: Bool,
                                       options newOptions: TranslationStageOptions? = nil) async throws {
        if let new = newOptions { options.translationOptions = new }
        options.translationEnabled = on
        guard !stopped else { return }

        if on {
            // Translation depends on voice being on for the transcript stream. Lift voice
            // implicitly if it isn't already — the alternative (refuse) leaves the user with
            // a non-functional translation toggle.
            if voiceStage == nil {
                options.voiceEnabled = true
                try await startVoiceStage()
            }
            guard let topts = options.translationOptions else {
                throw PipelineConfigurationError.translationOptionsRequired
            }
            if translationStage == nil {
                let stage = TranslationPipelineStage(options: topts)
                await stage.setOnTranslation(self.onTranslation)
                self.translationStage = stage
                // Re-route the transcript forwarder so finals reach the new translation stage.
                if let vs = voiceStage {
                    await vs.setOnTranscript(makeTranscriptForwarder())
                }
            } else {
                await translationStage?.updateOptions(topts)
            }
            // R2/R12: update the manifest in-place so the persisted record carries the new
            // disclosure (audible_chirp: true, voice_transformed: true) from this point onward.
            await refreshManifestWatermark()
        } else {
            if let stage = translationStage {
                await stage.stop()
                self.translationStage = nil
            }
            await refreshManifestWatermark()
        }
    }

    // MARK: - Internal helpers (voice/translation glue)

    private func startVoiceStage() async throws {
        let stage = try VoiceStage(locale: options.voiceLocale)
        try await stage.start()
        await stage.setOnTranscript(makeTranscriptForwarder())
        self.voiceStage = stage
    }

    /// Build a fan-out callback that:
    ///   1. forwards every transcript to the orchestrator's `onTranscript` (if set)
    ///   2. forwards finalized transcripts to the active translation stage (if enabled)
    /// Re-built on every wiring change so the closure captures the latest stage references.
    private func makeTranscriptForwarder() -> @Sendable (Transcript) -> Void {
        let userCallback = self.onTranscript
        let translation = self.translationStage
        return { transcript in
            userCallback?(transcript)
            if transcript.isFinal, let translation {
                // Translation stage spawns its own task; this call is non-blocking.
                translation.translate(transcript.text)
            }
        }
    }

    /// Re-encode the manifest's `watermark` block from current options so a hot toggle is
    /// reflected in the persisted record. No-op pre-`run()` (writer is nil).
    private func refreshManifestWatermark() async {
        guard let writer = manifestWriter else { return }
        let current = await writer.currentManifest
        let chirp = options.voiceEnabled || options.translationEnabled
        let updated = WatermarkConfig(
            visible: current.pipeline.watermark.visible,
            signed: current.pipeline.watermark.signed,
            audible_chirp: chirp,
            voice_transformed: options.translationEnabled
        )
        var newPipeline = current.pipeline
        newPipeline.watermark = updated
        await writer.updatePipeline(newPipeline)
    }

    public func run() async throws -> PipelineResult {
        // ── telemetry ───────────────────────────────────────────────
        // Don't clearSinks — earlier versions wiped sinks the caller had attached (e.g. the
        // SwiftUI app's RingBufferSink), so the UI's telemetry panel stayed at zero forever.
        // Pipeline adds its own JSONL logger when configured; callers manage the rest.
        var jsonlSink: JSONLLogger?
        if let url = jsonlURL {
            jsonlSink = try JSONLLogger(url: url)
            await Telemetry.shared.attach(jsonlSink!)
        }

        // ── stages ───────────────────────────────────────────────
        let captureCfg = CaptureConfig(
            width: options.captureWidth,
            height: options.captureHeight,
            fps: options.fps,
            lockExposure: true
        )
        let frameSource: FrameSource = {
            switch options.mode {
            case .synthetic:        return SyntheticFrameSource(config: captureCfg)
            case .live:             return LiveCaptureSource(config: captureCfg)
            case .file(let url):    return FileFrameSource(url: url, looping: false, pace: .asFast)
            }
        }()
        // Synthetic mode is the only one that uses procedural landmarks; file mode runs real Vision.
        let useSyntheticLandmarks: Bool = {
            if case .synthetic = options.mode { return true } else { return false }
        }()

        // Backend selection: explicit override > mode-default. Tag is reported in the manifest.
        let landmarkBackend: any LandmarkBackend = {
            if let injected = options.landmarkBackend { return injected }
            return useSyntheticLandmarks ? SyntheticLandmarkExtractor() : VisionLandmarkBackend()
        }()
        let backendTag: String = options.landmarkBackendTag
            ?? (useSyntheticLandmarks ? "synthetic" : "vision")
        // Polymorphic dispatch via the `ExpressionSolver` protocol. `.coreml` falls back to
        // geometric internally if the .mlpackage is absent.
        let solver: any ExpressionSolver = {
            switch options.solverKind {
            case .geometric: return GeometricSolver()
            case .coreml:    return CoreMLSolver()
            }
        }()
        let metal = try MetalContext()
        let renderer = try Renderer(
            context: metal,
            outputSize: (options.captureWidth, options.captureHeight),
            options: options.rendererOptions
        )
        self.renderer = renderer
        let signer = FrameSigner()
        let badge = try VisibleBadge()
        let watermarker = Watermarker(signer: signer, badge: badge)
        self.watermarker = watermarker

        // M56: instantiate the reenactment stage and (if configured) load the identity. Failure
        // to verify is a load-time refusal (R12) — pipeline continues without a reenactor and
        // emits a telemetry warning so the operator can investigate.
        let reenactStage = ReenactStage()
        self.reenactStage = reenactStage
        if let id = options.consentedIdentity, let png = options.consentedIdentityPNG {
            do {
                try await reenactStage.setIdentity(id, pngBytes: png)
            } catch {
                await Telemetry.shared.emit(.warning(
                    stage: .solver,
                    message: "Identity bundle rejected: \(error)"
                ))
            }
        }

        // ── manifest ───────────────────────────────────────────────
        let consent = ConsentRecord(
            scheme: .selfAsSource,
            accepted_at: Date(),
            user_disclosure_text_sha256: ConsentRecord.hashDisclosure(
                "MirrorMesh v0.1.0 — synthetic self-presence, watermarked output."
            )
        )
        let deviceID: String = {
            switch options.mode {
            case .synthetic:     return "synthetic"
            case .file(let url): return "file:\(url.lastPathComponent)"
            case .live:          return "default"
            }
        }()
        let pipelineCfg = PipelineConfig(
            capture: ManifestCaptureConfig(
                format: "\(options.captureWidth)x\(options.captureHeight)@\(options.fps)",
                device_id: deviceID
            ),
            landmarks: LandmarksConfig(
                backend: backendTag,
                smoothing: "one-euro"
            ),
            solver: SolverConfig(type: options.solverKind.rawValue, calibration_frames: 30),
            render: RenderConfig(overlay: ["landmarks", "avatar_mask"]),
            // R2 disclosure: chirp is mandatory whenever voice OR translation is active.
            // R12: the chirp is locked-on whenever translation is on (see AppSettings docs); the
            // manifest reflects whatever the *runtime* policy ended up doing, so we record true.
            // `voice_transformed` is sticky-true for the rest of the session once translation
            // produces any output; here we seed it from the option flag at start.
            watermark: WatermarkConfig(
                visible: true,
                signed: true,
                audible_chirp: options.voiceEnabled || options.translationEnabled,
                voice_transformed: options.translationEnabled
            )
        )
        // M55: bind the loaded ConsentedIdentity into the manifest. SHA-256 over canonical header
        // JSON (signature-stripped, sorted keys) concatenated with PNG bytes — same input the
        // bundle verifier hashed at load time. Downstream verifiers can re-derive this value
        // from the .mmid bundle they retrieve out-of-band and confirm it drove this session.
        let identitySHA256: String? = {
            guard let id = options.consentedIdentity, let png = options.consentedIdentityPNG else {
                return nil
            }
            return ConsentedIdentityVerifier.canonicalSHA256(identity: id, pngBytes: png)
        }()
        let manifest = SessionManifest(
            started_at: Date(),
            device: DeviceInfo.current(),
            pipeline: pipelineCfg,
            consent: consent,
            public_key_b64: signer.publicKey.base64EncodedString(),
            identity_sha256: identitySHA256
        )
        let writer = ManifestWriter(url: manifestURL, signer: signer, manifest: manifest)
        self.manifestWriter = writer

        // ── voice + translation (v0.7 + v0.8) ───────────────────────
        // Voice first because translation depends on the transcript stream. If voice fails to
        // start (permission denied, locale unsupported, audio engine failure), translation is
        // implicitly disabled — surfaced as a telemetry warning, not a hard failure, so the rest
        // of the pipeline still runs.
        if options.voiceEnabled || options.translationEnabled {
            do {
                try await startVoiceStage()
            } catch {
                await Telemetry.shared.emit(.warning(
                    stage: .vision,  // no .voice stage id today; reuse .vision
                    message: "voice stage start failed: \(error)"
                ))
                // Disable both — translation can't operate without transcripts.
                options.voiceEnabled = false
                options.translationEnabled = false
            }
        }
        if options.translationEnabled, let topts = options.translationOptions {
            let tstage = TranslationPipelineStage(options: topts)
            await tstage.setOnTranslation(self.onTranslation)
            self.translationStage = tstage
            // Re-route the transcript forwarder so the voice → translate edge is live.
            if let vs = voiceStage {
                await vs.setOnTranscript(makeTranscriptForwarder())
            }
        } else if options.translationEnabled {
            // Enabled but no options provided — degrade gracefully + warn.
            await Telemetry.shared.emit(.warning(
                stage: .solver,
                message: "translation enabled but TranslationStageOptions is nil; disabling"
            ))
            options.translationEnabled = false
        }

        // Optional .mov recorder — attached only when recorderURL is set.
        let recorder: VideoRecorder? = try options.recorderURL.map { url in
            try VideoRecorder(
                url: url,
                width: options.captureWidth,
                height: options.captureHeight,
                fps: options.fps,
                codec: options.recorderCodec
            )
        }

        // Optional virtual-camera XPC sink. Lazy-connects on first push; no-ops when
        // the CMIO extension isn't installed, so the unsigned dev build is unaffected.
        let virtualCamera: VirtualCameraXPCClient? = options.virtualCameraEnabled
            ? VirtualCameraXPCClient()
            : nil

        await Telemetry.shared.emit(.meta(
            sessionID: manifest.session_id,
            deviceModel: manifest.device.model,
            osVersion: manifest.device.os_version,
            commit: nil
        ))

        // ── run loop ───────────────────────────────────────────────
        var e2eHist = LatencyHistogram()
        var perStage: [StageID: LatencyHistogram] = [:]
        for s in StageID.allCases { perStage[s] = LatencyHistogram() }
        var framesProcessed = 0

        let stream = try await frameSource.start()

        outer: for await captured in stream {
            if stopped { break }
            if let cap = options.maxFrames, framesProcessed >= cap { break outer }

            // M43: hand the raw CapturedFrame to the PIP consumer (if attached) before any
            // synthetic styling. Lets the UI render the operator's actual face alongside the
            // transformed hero view.
            onCapture?(captured)

            let e2eStart = MirrorMeshCore.hostTimeNs()
            // End-to-end signpost: one umbrella interval per frame in Instruments, containing
            // each stage's nested interval.
            let pipelineSp = Signpost.begin(Signpost.pipeline, frame: captured.frameID)

            // Capture stage end (synthetic source doesn't emit one for us)
            let captureEnd = MirrorMeshCore.hostTimeNs()
            await Telemetry.shared.emit(.stageEnd(stage: .capture, frame: captured.frameID, hostTimeNs: captureEnd))
            let captureMs = Double(captureEnd &- captured.hostTimeNs) / 1_000_000

            // Vision (or any LandmarkBackend implementation, e.g. MediaPipe).
            let visionStart = MirrorMeshCore.hostTimeNs()
            let landmarks: LandmarkFrame? = landmarkBackend.extract(from: captured)
            let visionEnd = MirrorMeshCore.hostTimeNs()
            let visionMs = Double(visionEnd &- visionStart) / 1_000_000

            // Solver
            var blendshapes: BlendshapeFrame? = nil
            var solverMs = 0.0
            if let lf = landmarks {
                let solverStart = MirrorMeshCore.hostTimeNs()
                blendshapes = solver.solve(lf)
                let solverEnd = MirrorMeshCore.hostTimeNs()
                solverMs = Double(solverEnd &- solverStart) / 1_000_000
                // Why: bench traces consume per-frame coefficients to compute solver-vs-solver MAE.
                if let bf = blendshapes, options.logCoefficients {
                    var dict: [String: Float] = [:]
                    dict.reserveCapacity(bf.coefficients.count)
                    for (k, v) in bf.coefficients { dict[k.rawValue] = v }
                    await Telemetry.shared.emit(.coefficients(frame: bf.frameID, values: dict))
                }
            }

            // M56: reenactment stage between solver and render. Pass-through when no identity
            // is loaded (the existing landmark/mesh overlays still render). The stage is cheap
            // when active (~sub-ms geometric solver) and a no-op when idle.
            //
            // v0.8.0: if a translation stage is active, fetch the current lip-sync overlay and
            // merge it into the reenacted frame's mouth-region coefficients BEFORE the payload
            // is built. Pose channels and non-mouth blendshapes pass through untouched — the
            // operator's silent face still drives everything above the mouth.
            var stylizedPayload: Renderer.StylizedHeadPayload? = nil
            if let lf = landmarks {
                let reenacted = await reenactStage.apply(lf)
                if var frame = reenacted.frame {
                    if let tstage = self.translationStage,
                       let model = await reenactStage.currentModel() {
                        let overlay = tstage.currentOverlay(at: lf.hostTimeNs)
                        if !overlay.values.isEmpty {
                            frame = frame.overlayLipSync(overlay.values, using: model)
                        }
                    }
                    stylizedPayload = Renderer.StylizedHeadPayload(
                        vertices: frame.vertices,
                        normals: frame.normals,
                        indices: frame.indices,
                        yaw: frame.coefficients[.headYaw] ?? 0,
                        pitch: frame.coefficients[.headPitch] ?? 0,
                        roll: frame.coefficients[.headRoll] ?? 0,
                        landmarkBoundingBoxNorm: lf.faceBoundingBoxNorm
                    )
                }
            }

            // Render
            let renderStart = MirrorMeshCore.hostTimeNs()
            guard let rendered = renderer.render(captured: captured,
                                                  landmarks: landmarks,
                                                  blendshapes: blendshapes,
                                                  stylizedHead: stylizedPayload) else {
                await Telemetry.shared.emit(.warning(stage: .render, message: "render returned nil"))
                // Close pipeline signpost on early-out so Instruments doesn't show an open interval.
                Signpost.end(Signpost.pipeline, frame: captured.frameID, id: pipelineSp)
                continue
            }
            let renderEnd = MirrorMeshCore.hostTimeNs()
            let renderMs = Double(renderEnd &- renderStart) / 1_000_000

            // Why: notify UI of the freshly rendered frame before the (slower) watermarking step
            // so the preview stays responsive even when the signer is under load.
            onRender?(rendered)

            // Watermark
            let wmStart = MirrorMeshCore.hostTimeNs()
            let watermarked = watermarker.watermark(rendered)
            let wmEnd = MirrorMeshCore.hostTimeNs()
            let wmMs = Double(wmEnd &- wmStart) / 1_000_000

            await writer.recordFrame(watermarked)
            // Append to .mov after manifest accounting so failure stays observable.
            if let recorder { await recorder.append(watermarked) }
            // Fan out to the virtual camera last — failures don't block the manifest path.
            virtualCamera?.push(watermarked)

            // End-to-end
            let e2eEnd = MirrorMeshCore.hostTimeNs()
            let e2eMs = Double(e2eEnd &- e2eStart) / 1_000_000
            e2eHist.record(e2eMs)
            perStage[.capture]?.record(captureMs)
            perStage[.vision]?.record(visionMs)
            perStage[.solver]?.record(solverMs)
            perStage[.render]?.record(renderMs)
            perStage[.watermark]?.record(wmMs)

            await Telemetry.shared.emit(.frame(
                frame: watermarked.frameID,
                perStageMs: [
                    .capture: captureMs,
                    .vision: visionMs,
                    .solver: solverMs,
                    .render: renderMs,
                    .watermark: wmMs,
                ],
                endToEndMs: e2eMs
            ))
            Signpost.end(Signpost.pipeline, frame: captured.frameID, id: pipelineSp)

            framesProcessed &+= 1
        }

        await frameSource.stop()
        // Tear down voice + translation BEFORE finalizing the manifest so the writer's last
        // updatePipeline sees the truthiest values.
        if let vs = voiceStage {
            await vs.stop()
            self.voiceStage = nil
        }
        // v0.8.0: `voice_transformed` is sticky-true if the translation stage produced any
        // overlay during the session. We re-check here so a session that started with the
        // toggle off but had it flipped on mid-run still records the disclosure correctly.
        if let tstage = translationStage {
            if tstage.isActive {
                // refreshManifestWatermark uses option flags; ensure the option reflects
                // the runtime fact before we refresh.
                options.voiceEnabled = true
                options.translationEnabled = true
            }
            await refreshManifestWatermark()
            await tstage.stop()
            self.translationStage = nil
        }
        // Finalize recorder before manifest so the .mov is closed when the manifest references it.
        if let recorder { try await recorder.finalize() }
        virtualCamera?.stop()
        try await writer.finalize()
        self.manifestWriter = nil
        jsonlSink?.flush()

        return PipelineResult(
            framesProcessed: framesProcessed,
            manifestURL: manifestURL,
            endToEndP50Ms: e2eHist.p50,
            endToEndP95Ms: e2eHist.p95,
            endToEndP99Ms: e2eHist.p99
        )
    }

    public func stop() {
        stopped = true
        // Voice + translation stages are also drained by the run-loop's cleanup tail when it
        // observes `stopped`; cancelling here lets the frame source's pending wait return
        // sooner. Stages are idempotent against double-stop.
        let vs = self.voiceStage
        let ts = self.translationStage
        Task {
            await vs?.stop()
            await ts?.stop()
        }
    }
}
