import Foundation
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshVision
import MirrorMeshSolver
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshRecorder
import MirrorMeshVirtualCamera

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
                logCoefficients: Bool = false) {
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
    }
}

public struct PipelineResult: Sendable {
    public let framesProcessed: Int
    public let manifestURL: URL
    public let endToEndP50Ms: Double
    public let endToEndP95Ms: Double
    public let endToEndP99Ms: Double
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
    private var renderer: Renderer?

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

    /// Update the renderer's overlay toggles live (driven by the SwiftUI Settings panel).
    /// No-op when the pipeline hasn't started yet — the next start() reads `options.rendererOptions`.
    public func setRendererOptions(_ opts: Renderer.Options) {
        options.rendererOptions = opts
        renderer?.options = opts
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
            watermark: WatermarkConfig(visible: true, signed: true, audible_chirp: false)
        )
        let manifest = SessionManifest(
            started_at: Date(),
            device: DeviceInfo.current(),
            pipeline: pipelineCfg,
            consent: consent,
            public_key_b64: signer.publicKey.base64EncodedString()
        )
        let writer = ManifestWriter(url: manifestURL, signer: signer, manifest: manifest)

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

            // Render
            let renderStart = MirrorMeshCore.hostTimeNs()
            guard let rendered = renderer.render(captured: captured,
                                                  landmarks: landmarks,
                                                  blendshapes: blendshapes) else {
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
        // Finalize recorder before manifest so the .mov is closed when the manifest references it.
        if let recorder { try await recorder.finalize() }
        virtualCamera?.stop()
        try await writer.finalize()
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
    }
}
