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
    public func start(mode: PipelineMode = .live) {
        guard consent != nil, !running else { return }
        error = nil
        running = true
        watermarkActive = true

        Task { await Telemetry.shared.attach(ringBuffer) }

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
        let pipeline = Pipeline(options: opts, manifestURL: manifestURL, jsonlURL: nil)
        self.pipeline = pipeline

        // Why: closure hops back to the @MainActor to mutate @Published, keeping SwiftUI happy
        // even though the callback is invoked from the pipeline actor's executor.
        let sink: @Sendable (RenderedFrame) -> Void = { [weak self] frame in
            Task { @MainActor in
                guard let self else { return }
                self.latestFrame = frame
                self.latestFramePreview = LatestFramePreview(
                    frameID: frame.frameID,
                    hostTimeNs: frame.hostTimeNs,
                    width: frame.width,
                    height: frame.height
                )
            }
        }

        pipelineTask = Task { [weak self] in
            await pipeline.setOnRender(sink)
            do {
                _ = try await pipeline.run()
            } catch {
                // Why: hop back to @MainActor to mutate @Published state from the actor's task.
                await MainActor.run { self?.handlePipelineError(error) }
            }
            await MainActor.run { self?.markStopped() }
        }

        startTicker()
    }

    /// Push the SwiftUI settings panel's current toggle values into the live pipeline so the
    /// renderer + watermarker react to user input without restarting the session.
    public func applySettings() {
        let opts = Renderer.Options(
            showLandmarks: settings.showLandmarks,
            showAvatarMask: settings.showAvatarMask
        )
        let watermarkVisible = settings.watermarkVisible
        let p = pipeline
        Task {
            await p?.setRendererOptions(opts)
            await p?.setWatermarkVisible(watermarkVisible)
        }
        // Mirror in the @Published flag so the watermark hero card dims accordingly.
        watermarkActive = watermarkVisible || settings.watermarkLockedInRelease
    }

    public func stop() {
        guard running else { return }
        running = false
        isPreview = false
        pipelineTask?.cancel()
        ticker?.cancel()
        let p = pipeline
        Task { await p?.stop() }
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

    private func handlePipelineError(_ err: Error) {
        if let cap = err as? CaptureError {
            switch cap {
            case .permissionDenied: self.error = .permissionDenied
            default:                self.error = .unknown("\(cap)")
            }
        } else {
            self.error = .unknown("\(err)")
        }
    }

    private func markStopped() {
        running = false
        ticker?.cancel()
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

/// User-facing toggles. Persisted via `UserDefaults` on demand; default values keep CLI safe.
@MainActor
public final class AppSettings: ObservableObject {
    @Published public var showLandmarks: Bool
    @Published public var showAvatarMask: Bool
    @Published public var watermarkVisible: Bool

    /// Release builds never let users hide the watermark. We surface that as a locked toggle.
    public let watermarkLockedInRelease: Bool

    public init(showLandmarks: Bool = true,
                showAvatarMask: Bool = true,
                watermarkVisible: Bool = true) {
        self.showLandmarks = showLandmarks
        self.showAvatarMask = showAvatarMask
        self.watermarkVisible = watermarkVisible
        #if DEBUG
        self.watermarkLockedInRelease = false
        #else
        self.watermarkLockedInRelease = true
        #endif
    }
}
