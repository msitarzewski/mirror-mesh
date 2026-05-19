import Foundation
import SwiftUI
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshOutput

/// User-facing pipeline errors surfaced to SwiftUI. Mirrors the `CaptureError` cases the UI cares
/// about; we keep this enum local so the UI doesn't import the full capture stack just for types.
public enum PipelineError: Error, Equatable, Sendable {
    case permissionDenied
    case unknown(String)
}

/// View-side model owning the pipeline lifecycle. Holds a `RingBufferSink` attached to the
/// shared `Telemetry` actor so the UI can render live histograms without coupling to stages.
///
/// Why @MainActor: all `@Published` mutations must come from the main actor to keep SwiftUI
/// state changes deterministic and avoid threading warnings.
@MainActor
public final class PipelineViewModel: ObservableObject {
    @Published public var running: Bool = false
    @Published public var consent: ConsentRecord?
    @Published public var perStageLatencyMs: [StageID: StageLatency] = [:]
    @Published public var latestFramePreview: LatestFramePreview?
    /// Latest rendered frame from the pipeline. Drives `CameraPreviewView` Metal blits.
    @Published public var latestFrame: RenderedFrame?
    /// Surface for UI-actionable errors (e.g., camera permission denied).
    @Published public var error: PipelineError?

    /// Watermark visible-overlay status. Wired to settings; the renderer is the source of truth in release.
    @Published public var watermarkActive: Bool = true
    /// True while `startPreview()` is driving an auto-running synthetic loop on launch.
    /// False after the user has explicitly hit "Start Session" with consent.
    @Published public var isPreview: Bool = false

    public let ringBuffer: RingBufferSink
    public let settings: AppSettings

    private var pipeline: Pipeline?
    private var pipelineTask: Task<Void, Never>?
    /// Why: M37 — the next-session pipeline runs in parallel with the current one so the preview
    /// keeps producing frames during consent → live handoff. Promoted to `pipeline` on first frame.
    private var pendingPipeline: Pipeline?
    private var pendingPipelineTask: Task<Void, Never>?
    /// True while `pendingPipeline` is the live-mode session that should replace the preview.
    private var pendingIsLive: Bool = false
    private var histograms: [StageID: LatencyHistogram] = [:]
    private var ticker: Task<Void, Never>?

    public init(settings: AppSettings? = nil,
                ringBufferCapacity: Int = 4096) {
        // Why: `AppSettings()` is @MainActor-isolated, so it can't be a default param expression.
        self.settings = settings ?? AppSettings()
        self.ringBuffer = RingBufferSink(capacity: ringBufferCapacity)
        for stage in StageID.allCases { histograms[stage] = LatencyHistogram() }
    }

    /// Start the real pipeline in the requested mode. Defaults to `.live` (camera + Vision).
    /// Synthetic mode is retained for CLI / no-camera environments.
    /// Caller must have a non-nil `consent` set; otherwise this is a no-op.
    ///
    /// M37 handoff: if a preview pipeline is already running, the new pipeline is brought up
    /// in parallel as `pendingPipeline`. When its first `RenderedFrame` arrives we stop the old
    /// pipeline and promote the pending one — no blank frame on screen.
    public func start(mode: PipelineMode = .live) {
        guard consent != nil else { return }
        // Why: if a live session is already running we don't restart it; reserved for preview→live.
        if running && !isPreview { return }
        error = nil

        // Why: only attach on cold start — `Telemetry.attach` is append-only, so re-attaching during
        // a handoff would double-record every event into the ring buffer.
        if !running { Task { await Telemetry.shared.attach(ringBuffer) } }

        let manifestURL = Self.defaultManifestURL()
        let opts = PipelineOptions(
            mode: mode,
            captureWidth: 640,
            captureHeight: 360,
            fps: 30,
            maxFrames: nil,
            rendererOptions: Renderer.Options(
                showLandmarks: settings.showLandmarks,
                showAvatarMask: settings.showAvatarMask
            )
        )
        let newPipeline = Pipeline(options: opts, manifestURL: manifestURL, jsonlURL: nil)

        // Why: if no pipeline currently runs, this is a cold start; install directly. Otherwise
        // park it as pending so the preview keeps driving frames until handoff.
        // Why: PipelineMode has associated values (`.file(URL)`), so equality requires a switch.
        let modeIsSynthetic: Bool = { if case .synthetic = mode { return true }; return false }()
        let isHandoff = running && isPreview
        if isHandoff {
            pendingPipeline = newPipeline
            pendingIsLive = !modeIsSynthetic
        } else {
            running = true
            watermarkActive = true
            isPreview = modeIsSynthetic
            pipeline = newPipeline
        }

        // Why: closure hops back to the @MainActor to mutate @Published, keeping SwiftUI happy
        // even though the callback is invoked from the pipeline actor's executor.
        let sink: @Sendable (RenderedFrame) -> Void = { [weak self] frame in
            Task { @MainActor in
                guard let self else { return }
                // Why: M37 — if this frame came from the pending pipeline, promote now so the
                // preview is replaced atomically and the old one is torn down off the main path.
                if isHandoff, self.pendingPipeline === newPipeline {
                    self.promotePendingPipeline(newPipeline)
                }
                self.latestFrame = frame
                self.latestFramePreview = LatestFramePreview(
                    frameID: frame.frameID,
                    hostTimeNs: frame.hostTimeNs,
                    width: frame.width,
                    height: frame.height
                )
            }
        }

        let runTask: Task<Void, Never> = Task { [weak self] in
            await newPipeline.setOnRender(sink)
            do {
                _ = try await newPipeline.run()
            } catch {
                // Why: hop back to @MainActor to mutate @Published state from the actor's task.
                await MainActor.run { self?.handlePipelineError(error, failed: newPipeline) }
            }
            await MainActor.run { self?.handlePipelineFinished(newPipeline) }
        }

        if isHandoff {
            pendingPipelineTask = runTask
        } else {
            pipelineTask = runTask
            startTicker()
        }
    }

    /// Push the SwiftUI settings panel's current toggle values into the live pipeline so the
    /// renderer + watermarker react to user input without restarting the session. The render
    /// style is the master toggle — it preselects what's visible. Granular overrides
    /// (showLandmarks / showAvatarMask) apply on top within the wireframe style only.
    public func applySettings() {
        let opts = rendererOptions(for: settings.renderStyle)
        let watermarkVisible = settings.watermarkVisible
        let p = pipeline
        Task {
            await p?.setRendererOptions(opts)
            await p?.setWatermarkVisible(watermarkVisible)
        }
        watermarkActive = watermarkVisible || settings.watermarkLockedInRelease
    }

    /// Map a `RenderStyle` to a `Renderer.Options` preset. Wireframe is the only style that
    /// honors the granular landmark/avatar overrides; Mirror and Mask are intentionally clean.
    private func rendererOptions(for style: RenderStyle) -> Renderer.Options {
        switch style {
        case .wireframe:
            return Renderer.Options(
                showLandmarks: settings.showLandmarks,
                showAvatarMask: settings.showAvatarMask,
                showFaceMesh: true,
                meshStyle: .wireframe,
                meshColor: SIMD4(0.0, 1.0, 0.4, 0.9)
            )
        case .mirror:
            return Renderer.Options(
                showLandmarks: false,
                showAvatarMask: false,
                showFaceMesh: false
            )
        case .mask:
            return Renderer.Options(
                showLandmarks: false,
                showAvatarMask: false,
                showFaceMesh: true,
                meshStyle: .filled,
                meshColor: SIMD4(0.92, 0.74, 0.58, 0.95)  // warm skin-toned fill for the synthetic face
            )
        }
    }

    /// Stop the active session. M37: we leave `latestFrame` populated so the last frame stays
    /// on screen until another pipeline emits something — no blank flash on stop.
    public func stop() {
        guard running else { return }
        running = false
        isPreview = false
        pipelineTask?.cancel()
        pendingPipelineTask?.cancel()
        ticker?.cancel()
        let p = pipeline
        let pending = pendingPipeline
        pendingPipeline = nil
        pendingIsLive = false
        Task {
            await p?.stop()
            await pending?.stop()
        }
    }

    /// Auto-running synthetic preview shown on launch so the app shows life immediately,
    /// without requiring the consent sheet. The output is *not* a real session — manifest
    /// lands in `tmp/`, gets overwritten each launch, and the UI shows `Preview` instead
    /// of `Session`. Pressing "Start Session" stops the preview and prompts for consent.
    public func startPreview() {
        guard !running else { return }
        // Why: consent is required by `start(mode:)`. Inject a preview-only record so the
        // gate opens. The hash is of the preview disclosure text — distinguishable from
        // a real user-accepted consent.
        consent = ConsentRecord(
            scheme: .selfAsSource,
            accepted_at: Date(),
            user_disclosure_text_sha256: ConsentRecord.hashDisclosure(
                "MirrorMesh preview — synthetic loop; not a recorded session."
            )
        )
        isPreview = true
        start(mode: .synthetic)
    }

    // MARK: - Internals

    /// Why M37: errors from a pending (live) pipeline must not kill the preview that's still
    /// driving frames. We only surface the error and tear the pending pipeline down.
    private func handlePipelineError(_ err: Error, failed: Pipeline) {
        if let cap = err as? CaptureError {
            switch cap {
            case .permissionDenied: self.error = .permissionDenied
            default:                self.error = .unknown("\(cap)")
            }
        } else {
            self.error = .unknown("\(err)")
        }
    }

    /// Called once per pipeline when its `run()` task exits (success, cancel, or error).
    /// The pending vs current branch decides whether the UI session should stop.
    private func handlePipelineFinished(_ finished: Pipeline) {
        if pendingPipeline === finished {
            // Why: pending never promoted (failed or cancelled before first frame). Drop refs;
            // preview continues running unaffected.
            pendingPipeline = nil
            pendingPipelineTask = nil
            pendingIsLive = false
            return
        }
        if pipeline === finished {
            // Why: if a pending swap is in flight, don't flip `running` off — promotion will own it.
            if pendingPipeline != nil { return }
            running = false
            isPreview = false
            ticker?.cancel()
        }
    }

    /// M37: swap pending → current. Stops the old pipeline off-actor; updates @Published flags
    /// so the UI sees `isPreview=false` exactly when the first live frame paints.
    private func promotePendingPipeline(_ promoted: Pipeline) {
        let oldPipeline = pipeline
        let oldTask = pipelineTask
        pipeline = promoted
        pipelineTask = pendingPipelineTask
        pendingPipeline = nil
        pendingPipelineTask = nil
        isPreview = !pendingIsLive
        pendingIsLive = false
        running = true
        watermarkActive = true
        // Why: stop the preview off the main path; cancel its task so its finish-handler is a no-op
        // for the now-promoted pipeline reference.
        oldTask?.cancel()
        Task { await oldPipeline?.stop() }
    }

    private func recordError(_ stage: StageID, _ msg: String) async {
        await Telemetry.shared.emit(.error(stage: stage, message: msg))
    }

    /// Refresh published latency snapshot ~10Hz so the panel updates without re-rendering each frame.
    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshPublishedLatency()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func refreshPublishedLatency() {
        // Build per-stage histograms from the ring buffer's recent .frame events. The ring
        // buffer is the single source of truth; recomputing each tick avoids a separate sink
        // and any sync headaches. O(ring-capacity) = 4096 entries at 10 Hz = negligible.
        var perStage: [StageID: LatencyHistogram] = [:]
        for stage in StageID.allCases { perStage[stage] = LatencyHistogram() }

        for event in ringBuffer.snapshot() {
            if case let .frame(_, perStageMs, e2eMs) = event {
                for (stage, ms) in perStageMs {
                    perStage[stage]?.record(ms)
                }
                perStage[.pipeline]?.record(e2eMs)
            }
        }

        var out: [StageID: StageLatency] = [:]
        for (stage, h) in perStage where h.sampleCount > 0 {
            out[stage] = StageLatency(p50: h.p50, p95: h.p95, samples: h.sampleCount)
        }
        self.perStageLatencyMs = out
    }

    /// Default location: `~/Library/Application Support/MirrorMesh/sessions/<timestamp>.manifest.json`.
    private static func defaultManifestURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true))
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("MirrorMesh/sessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: Date())
        return dir.appendingPathComponent("\(stamp).manifest.json")
    }
}

/// Snapshot of per-stage latency surfaced to the UI.
public struct StageLatency: Sendable, Equatable {
    public let p50: Double
    public let p95: Double
    public let samples: UInt64
    public init(p50: Double, p95: Double, samples: UInt64) {
        self.p50 = p50; self.p95 = p95; self.samples = samples
    }
}

/// Lightweight preview record. Avoids retaining CVPixelBuffers in the view-model.
public struct LatestFramePreview: Sendable, Equatable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let width: Int
    public let height: Int
    public init(frameID: FrameID, hostTimeNs: UInt64, width: Int, height: Int) {
        self.frameID = frameID; self.hostTimeNs = hostTimeNs
        self.width = width; self.height = height
    }
}

/// User-facing toggles. M38: persisted across launches via a dedicated UserDefaults suite.
/// `didSet` writes on every mutation; init seeds from the suite (or falls back to the supplied
/// defaults). Injectable suite name keeps unit tests hermetic.
@MainActor
public final class AppSettings: ObservableObject {
    /// Key namespace used in the UserDefaults suite.
    public enum Keys {
        public static let showLandmarks   = "mirrormesh.showLandmarks"
        public static let showAvatarMask  = "mirrormesh.showAvatarMask"
        public static let watermarkVisible = "mirrormesh.watermarkVisible"
        public static let renderStyle     = "mirrormesh.renderStyle"
    }

    /// Default suite name. Tests pass their own to stay isolated.
    public static let defaultSuiteName = "ai.mirrormesh"

    @Published public var showLandmarks: Bool { didSet { defaults.set(showLandmarks, forKey: Keys.showLandmarks) } }
    @Published public var showAvatarMask: Bool { didSet { defaults.set(showAvatarMask, forKey: Keys.showAvatarMask) } }
    @Published public var watermarkVisible: Bool { didSet { defaults.set(watermarkVisible, forKey: Keys.watermarkVisible) } }
    @Published public var renderStyle: RenderStyle { didSet { defaults.set(renderStyle.rawValue, forKey: Keys.renderStyle) } }

    /// Release builds never let users hide the watermark. We surface that as a locked toggle.
    public let watermarkLockedInRelease: Bool

    private let defaults: UserDefaults

    public init(showLandmarks: Bool = true,
                showAvatarMask: Bool = true,
                watermarkVisible: Bool = true,
                renderStyle: RenderStyle = .wireframe,
                suiteName: String? = "ai.mirrormesh") {
        // Why: a named suite avoids polluting the host process's standard defaults and lets
        // tests inject a unique suite for isolation. Falls back to standard if the suite fails.
        let store = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = store
        // Why: `object(forKey:)` returns nil when unset, so we distinguish "not stored" from "stored false".
        self.showLandmarks    = (store.object(forKey: Keys.showLandmarks)    as? Bool) ?? showLandmarks
        self.showAvatarMask   = (store.object(forKey: Keys.showAvatarMask)   as? Bool) ?? showAvatarMask
        self.watermarkVisible = (store.object(forKey: Keys.watermarkVisible) as? Bool) ?? watermarkVisible
        if let raw = store.string(forKey: Keys.renderStyle), let style = RenderStyle(rawValue: raw) {
            self.renderStyle = style
        } else {
            self.renderStyle = renderStyle
        }
        #if DEBUG
        self.watermarkLockedInRelease = false
        #else
        self.watermarkLockedInRelease = true
        #endif
    }
}
