import Foundation
import SwiftUI
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshOutput
import MirrorMeshVoice
import MirrorMeshTranslate

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
    /// M58: the currently-loaded ConsentedIdentity, if any. `nil` means "no puppet loaded;
    /// reenactment paths are gated off." Set only by `loadIdentity(from:)` after the
    /// signature has been verified.
    @Published public var consentedIdentity: ConsentedIdentity? = nil
    /// PNG bytes of the loaded identity's source image. Held so the ReenactStage can pick
    /// it up without a second disk read. Published so views can preview the loaded face.
    @Published public var identityPngData: Data? = nil
    /// User-facing error from the last identity-load attempt. Cleared on the next successful load.
    @Published public var identityVerificationError: String? = nil
    @Published public var perStageLatencyMs: [StageID: StageLatency] = [:]
    @Published public var latestFramePreview: LatestFramePreview?
    /// Latest rendered frame from the pipeline. Drives `CameraPreviewView` Metal blits.
    @Published public var latestFrame: RenderedFrame?
    /// Latest *raw* captured frame, pre-render. Drives the camera-as-PIP overlay (M43) when
    /// the style is Mirror or Mask — i.e., when the hero view is synthetic and the operator
    /// is verifiable as the small corner overlay.
    @Published public var latestCapturedFrame: CapturedFrame?
    /// Surface for UI-actionable errors (e.g., camera permission denied).
    @Published public var error: PipelineError?

    /// Watermark visible-overlay status. Wired to settings; the renderer is the source of truth in release.
    @Published public var watermarkActive: Bool = true
    /// True while `startPreview()` is driving an auto-running synthetic loop on launch.
    /// False after the user has explicitly hit "Start Session" with consent.
    @Published public var isPreview: Bool = false

    // MARK: - Voice / Translation (v0.7.0 / v0.8.0)

    /// Latest transcript text surfaced by the voice stage. Updated on every partial result so
    /// the UI can show a live caption; final results overwrite the partial. Empty string means
    /// "nothing transcribed yet" (used by VoiceInspector to render a placeholder).
    @Published public var currentTranscript: String = ""
    /// True if the most recent transcript update was a finalized utterance (not a partial).
    /// Used by VoiceInspector to render partials in muted color and finals in primary.
    @Published public var currentTranscriptIsFinal: Bool = false
    /// Latest translation string emitted by the translation stage. Mirrors `currentTranscript`
    /// — the UI shows the most recent translated utterance.
    @Published public var lastTranslation: String = ""
    /// True while the voice stage is actively transcribing. Drives the green/orange/gray
    /// status dot in VoiceInspector and the toolbar pill.
    @Published public var voiceActive: Bool = false
    /// True while the translation stage is actively translating. Drives the status dot in
    /// TranslationInspector and the toolbar pill. ALSO coerces the disclosure chirp on per
    /// R2/R12 (the AppSettings side of that lock is owned by the parallel agent; the UI
    /// always shows the locked-on footer regardless).
    @Published public var translationActive: Bool = false
    /// User-facing error from the most recent voice-stage attempt. Nil when healthy.
    @Published public var voiceError: String? = nil
    /// User-facing error from the most recent translation-stage attempt. Nil when healthy.
    @Published public var translationError: String? = nil

    // MARK: - Photoreal (M88/M89, LivePortrait CoreML graph)

    /// True when all four LivePortrait `.mlpackage` files were discovered on disk at one of the
    /// candidate locations checked by `detectPhotorealModelsDir()`. False when any are missing.
    /// Drives the "available" vs "not available" branches in `IdentityInspector`.
    @Published public var photorealAvailable: Bool = false
    /// True when the pipeline's `PhotorealStage` is actively substituting frames. Set by
    /// `setPhotorealEnabled(_:)` after the pipeline confirms the stage loaded and is in the
    /// frame path; toggled off on stage error or explicit disable.
    @Published public var photorealActive: Bool = false
    /// Filesystem path where the four mlpackages were discovered. Nil when models are not
    /// available. Surfaced in the inspector for transparency.
    @Published public var photorealModelsDir: URL? = nil
    /// User-facing error from the most recent photoreal-stage attempt. Nil when healthy.
    @Published public var photorealError: String? = nil

    public let ringBuffer: RingBufferSink
    public let settings: AppSettings

    /// M59 — owns the AVAudioEngine for the start-of-session disclosure chirp. Lazy so we
    /// don't init audio on import (some test harnesses run without an output device).
    private lazy var chirp = DisclosureChirp()

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

        // v0.6.0+ "no gating" default: auto-provision a self-as-source ConsentedIdentity at
        // first launch so the stylized 3D head pass is live without the user having to mint a
        // .mmid via the CLI. R1 still holds — `self-as-source` is one of the three legitimate
        // schemes; the user IS the source. Subsequent launches re-use the persisted bundle.
        // Best-effort: if provisioning fails (rare), the app continues with no identity loaded
        // and the user can still load one via the inspector.
        if let (identity, png) = try? DefaultIdentityProvider.loadOrCreate() {
            self.consentedIdentity = identity
            self.identityPngData = png
        }

        // M88/M89 — sync filesystem probe (< 1 ms; safe to run on @MainActor init). Sets
        // `photorealAvailable` so the inspector renders the right branch on first paint and
        // the post-start hop in `start()` knows whether to auto-enable photoreal.
        if let dir = Self.detectPhotorealModelsDir() {
            self.photorealAvailable = true
            self.photorealModelsDir = dir
        } else {
            self.photorealAvailable = false
            self.photorealModelsDir = nil
        }
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
        // M53: seed the renderer with style-aware options so the very first frame respects the
        // current render style (no AvatarMask leak before applySettings() ticks).
        let initialOpts = rendererOptions(for: settings.renderStyle)
        // v0.6.0+ "no gating": pass the auto-provisioned (or user-loaded) identity through so
        // the stylized 3D head renders from frame one. Translation options are seeded from
        // AppSettings; the pipeline turns the stage on after start() per `voiceEnabled` /
        // `translationEnabled` (see post-launch hop below).
        let translationOpts = translationOptionsFromSettings()
        let opts = PipelineOptions(
            mode: mode,
            captureWidth: 640,
            captureHeight: 360,
            fps: 30,
            maxFrames: nil,
            rendererOptions: initialOpts,
            consentedIdentity: consentedIdentity,
            consentedIdentityPNG: identityPngData,
            voiceEnabled: false,            // turned on post-start via setVoiceEnabled
            voiceLocale: settings.voiceLocale,
            translationEnabled: false,      // turned on post-start via setTranslationEnabled
            translationOptions: translationOpts
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

        // M43: parallel sink for raw captured frames feeding the PIP overlay.
        let captureSink: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            Task { @MainActor in
                self?.latestCapturedFrame = frame
            }
        }

        let runTask: Task<Void, Never> = Task { [weak self] in
            await newPipeline.setOnRender(sink)
            await newPipeline.setOnCapture(captureSink)
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

        // M59 — disclosure chirp on session start. Suppressed for the synthetic preview
        // (would fire every launch); fired exactly once per real session start (cold start
        // or preview→live handoff). Locked-on in release per R2 and coerced-on whenever
        // translation is active per R12; in dev the user can disable via AppSettings.chirpEnabled.
        if !modeIsSynthetic && settings.chirpShouldBeAudible {
            chirp.playChirp()
        }

        // v0.7.0 / v0.8.0 "no gating": auto-enable voice + translation per AppSettings as soon as
        // the pipeline is up. The backends fail-soft — voice errors land in `voiceError`,
        // translation errors land in `translationError`. Neither tears down the pipeline; the user
        // sees what's working and what isn't via the inspector status rows.
        if settings.voiceEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setVoiceEnabled(true)
            }
        }
        if settings.translationEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let opts = self.translationOptionsFromSettings()
                await self.setTranslationEnabled(true, options: opts)
            }
        }

        // M88/M89 "no gating": auto-enable the photoreal substitution stage if all four
        // LivePortrait mlpackages are present on disk. Models missing → silently stays off
        // and the inspector shows the user the install hint. Fails soft via `photorealError`.
        if photorealAvailable {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setPhotorealEnabled(true)
            }
        }
    }

    /// M58: read + verify a `.mmid` ConsentedIdentity bundle and publish the result. On
    /// success the verified `ConsentedIdentity` + PNG bytes are exposed via `consentedIdentity`
    /// and `identityPngData` for the ReenactStage (built by another agent) to pick up.
    /// On failure the bundle is rejected and the user-facing reason lands in
    /// `identityVerificationError`. The runtime version supplied to the verifier is the
    /// `MirrorMeshCore.version` constant — same source of truth the manifest uses, so a
    /// bundle whose scope satisfies the build also satisfies the running runtime.
    public func loadIdentity(from url: URL) {
        do {
            let (identity, png) = try ConsentedIdentityBundle.read(from: url)
            try ConsentedIdentityVerifier.verify(
                identity: identity,
                pngBytes: png,
                runtimeVersion: MirrorMeshCore.version
            )
            self.consentedIdentity = identity
            self.identityPngData = png
            self.identityVerificationError = nil
            // v1.1.0: push the verified identity into the running pipeline so the
            // photoreal stage reloads with the new source PNG. If no pipeline is
            // running (yet) the helper is a no-op and the start() path will pick it
            // up from `options.consentedIdentity` on cold start.
            Task { [weak self] in await self?.refreshPhotorealIdentity() }
        } catch let e as ConsentedIdentityError {
            self.consentedIdentity = nil
            self.identityPngData = nil
            self.identityVerificationError = e.description
        } catch {
            self.consentedIdentity = nil
            self.identityPngData = nil
            self.identityVerificationError = "Failed to read bundle: \(error)"
        }
    }

    /// Hot-swap the currently-loaded `consentedIdentity` into the live Pipeline so
    /// the photoreal stage reloads with the new source. Called by `IdentityInspector`
    /// after a successful self-capture mint and by `loadIdentity(from:)` after a
    /// fresh bundle verifies. No-op when nothing is loaded or no pipeline is running.
    ///
    /// When photoreal is currently active, we cycle the stage (off → on) so it
    /// re-runs `prepareSource()` against the new PNG. Without the cycle the cached
    /// appearance feature volume would still reflect the previous source — exactly
    /// the bug this whole task closes.
    ///
    /// `setConsentedIdentity` already propagates through to the photoreal stage
    /// internally (see `Pipeline.swift:setConsentedIdentity`), so the cycle is only
    /// needed to force a clean re-prepare of the appearance cache. Belt-and-braces.
    public func refreshPhotorealIdentity() async {
        guard let id = consentedIdentity, let png = identityPngData else { return }
        guard let p = pipeline else { return }
        do {
            try await p.setConsentedIdentity(id, pngBytes: png)
            // If photoreal is currently active, cycle it so the appearance cache rebuilds.
            if photorealAvailable && photorealActive {
                await setPhotorealEnabled(false)
                await setPhotorealEnabled(true)
            }
        } catch {
            photorealError = "Identity hot-swap failed: \(error)"
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
        // Why: "Watermark active" tracks the cryptographic signing state (always on during a
        // running session — release-locked, no off switch). The visible-badge composite is a
        // separate toggle. Keeping the badge tied to `running` matches what's actually happening
        // to the output frames; previously it could read "idle" even though signing was on.
        watermarkActive = running
    }

    // MARK: - Voice / Translation bridge (v0.7.0 / v0.8.0)

    /// Enable / disable the voice stage on the live pipeline. Wires the transcript callback so
    /// `currentTranscript` updates in real time. The pipeline-side API is being landed by a
    /// parallel agent; if it errors (e.g. mic permission denied) we surface the message on
    /// `voiceError` instead of throwing.
    ///
    /// Why @Sendable hop: the pipeline invokes the transcript callback from its own actor
    /// executor; we hop to MainActor before touching `@Published` state.
    public func setVoiceEnabled(_ on: Bool) async {
        // Why capture: `pipeline` is actor-mutable; pin the reference before crossing isolation.
        guard let p = pipeline else {
            voiceActive = on
            voiceError = on ? "Pipeline not running. Start a session first." : nil
            return
        }
        do {
            try await p.setVoiceEnabled(on)
            if on {
                let sink: @Sendable (Transcript) -> Void = { [weak self] t in
                    Task { @MainActor in
                        guard let self else { return }
                        self.currentTranscript = t.text
                        self.currentTranscriptIsFinal = t.isFinal
                    }
                }
                await p.setOnTranscript(sink)
            } else {
                await p.setOnTranscript(nil)
                currentTranscript = ""
                currentTranscriptIsFinal = false
            }
            voiceActive = on
            voiceError = nil
        } catch {
            voiceActive = false
            voiceError = "\(error)"
        }
    }

    /// Enable / disable the translation stage. When enabled, the pipeline drives the stylized
    /// head's mouth-region blendshapes from synthesized speech in the target locale. Requires
    /// a verified `consentedIdentity` (translation drives a stylized-head pass — see R1 and
    /// the `.stylizedNonHuman` scheme path).
    ///
    /// R2/R12: enabling translation locks the disclosure chirp on. The UI presents this as an
    /// always-visible footer; the runtime lock is owned by AppSettings via the parallel agent.
    public func setTranslationEnabled(_ on: Bool, options: TranslationStageOptions?) async {
        guard let p = pipeline else {
            translationActive = on
            settings.setTranslationActive(on)
            translationError = on ? "Pipeline not running. Start a session first." : nil
            return
        }
        if on && consentedIdentity == nil {
            translationError = "Translation requires a loaded ConsentedIdentity (.mmid bundle)."
            translationActive = false
            settings.setTranslationActive(false)
            return
        }
        do {
            try await p.setTranslationEnabled(on, options: options)
            if on {
                let sink: @Sendable (String) -> Void = { [weak self] translated in
                    Task { @MainActor in
                        self?.lastTranslation = translated
                    }
                }
                await p.setOnTranslation(sink)
            } else {
                await p.setOnTranslation(nil)
                lastTranslation = ""
            }
            translationActive = on
            settings.setTranslationActive(on)
            translationError = nil
        } catch {
            translationActive = false
            settings.setTranslationActive(false)
            translationError = "\(error)"
        }
    }

    /// Enable / disable the photoreal substitution stage on the live pipeline (M88/M89).
    /// When enabled, the pipeline's `PhotorealStage` runs the four-`.mlpackage` LivePortrait
    /// graph (appearance cached → motion + warp + generator per driving frame) and substitutes
    /// the captured frame in Mirror/Mask styles. Wireframe stays untouched as the debug view.
    ///
    /// Models are auto-discovered via `detectPhotorealModelsDir()`; the resolved URL is passed
    /// through to the pipeline. If discovery returned nil and the caller passes `on=true`, we
    /// surface a user-readable error instead of starting the stage.
    public func setPhotorealEnabled(_ on: Bool) async {
        guard let p = pipeline else {
            photorealActive = on
            photorealError = on ? "Pipeline not running. Start a session first." : nil
            return
        }
        if on && photorealModelsDir == nil {
            photorealActive = false
            photorealError = "LivePortrait models not found. See models/training/README.md."
            return
        }
        do {
            try await p.setPhotorealEnabled(on, modelsDir: photorealModelsDir)
            photorealActive = on
            photorealError = nil
        } catch {
            photorealActive = false
            photorealError = "\(error)"
        }
    }

    /// Required mlpackages for the LivePortrait CoreML graph (agent A's `PhotorealBackend`).
    /// All four must be present at the same candidate location; a partial set returns nil.
    private static let photorealRequiredFiles: [String] = [
        "appearance_v1.mlpackage",
        "motion_v1.mlpackage",
        "warp_v1.mlpackage",
        "generator_v1.mlpackage",
    ]

    /// Look for the four LivePortrait mlpackages in the standard candidate locations and
    /// return the URL of the first directory that contains all of them. Returns nil when
    /// no candidate is complete (the inspector then renders the install-hint branch).
    ///
    /// Order:
    /// 1. `<repo-root>/models/` — dev / `swift run` invocations from the workspace
    /// 2. `~/Library/Application Support/MirrorMesh/models/` — user-installed weights
    /// 3. `<app bundle>/Contents/Resources/models/` — shipped weights (unlikely for v1.0)
    ///
    /// Why @MainActor-safe: pure `FileManager.fileExists` stats; no I/O blocking beyond a
    /// handful of inode lookups. Measured << 1 ms on M5 Max.
    private static func detectPhotorealModelsDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 0) Explicit env-var override — same one the tests honor. Wins over auto-detection
        //    so a contributor can point the app at any directory without recompiling.
        if let env = ProcessInfo.processInfo.environment["MIRRORMESH_LIVEPORTRAIT_MODELS_DIR"],
           !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }

        // 1) Dev / repo-root probe. `CommandLine.arguments[0]` is the executable; walk up
        //    until we find a sibling `Package.swift` and then look at `models/`. This catches
        //    `swift run mirrormesh-app` from `/Users/<u>/.../mirror-mesh/`.
        //    Why fileURLWithPath: arguments[0] is a filesystem path, not a URL string.
        //    URL(string:) on a path without scheme returns a schemeless URL whose
        //    .deletingLastPathComponent + .appendingPathComponent path math silently drops
        //    the absolute root — detection then quietly fails. Bug fixed 2026-05-20.
        let exePath = CommandLine.arguments.first ?? ""
        if !exePath.isEmpty {
            let exe = URL(fileURLWithPath: exePath)
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                let pkg = dir.appendingPathComponent("Package.swift")
                if fm.fileExists(atPath: pkg.path) {
                    candidates.append(dir.appendingPathComponent("models", isDirectory: true))
                    break
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        // Also try the actual cwd, since `swift run` resolves arguments[0] to .build/... but the
        // working directory is the repo root.
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true))

        // 2) User-installed.
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: false) {
            candidates.append(appSupport
                .appendingPathComponent("MirrorMesh", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true))
        }

        // 3) Shipped in the app bundle.
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("models", isDirectory: true))
        }

        for dir in candidates {
            if hasAllPhotorealFiles(at: dir, fm: fm) {
                return dir
            }
        }
        // Print the candidate list so the user can see what paths were tried. Stderr only,
        // no popup — the inspector's "not available" branch surfaces the user-facing message.
        FileHandle.standardError.write(
            ("[mirrormesh] photoreal detection: no candidate contained all of " +
             "\(photorealRequiredFiles.joined(separator: ", ")). " +
             "Candidates tried (in order):\n" +
             candidates.map { "  - \($0.path)" }.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        )
        return nil
    }

    /// True when every required mlpackage is present at `dir`. Used by `detectPhotorealModelsDir`
    /// to filter partial installs (e.g. a user who downloaded one but not all four weights).
    private static func hasAllPhotorealFiles(at dir: URL, fm: FileManager) -> Bool {
        for name in photorealRequiredFiles {
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return false }
        }
        return true
    }

    /// Build a `TranslationStageOptions` from the current `AppSettings`. Used by
    /// `TranslationInspector` when the user flips the toggle on.
    public func translationOptionsFromSettings() -> TranslationStageOptions {
        var ollama = OllamaConfig()
        ollama.model = settings.ollamaModel
        return TranslationStageOptions(
            enabled: true,
            sourceLocale: Locale(identifier: settings.voiceLocale),
            targetLocale: Locale(identifier: settings.translationTargetLocale),
            ollama: ollama
        )
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
                meshColor: SIMD4(0.0, 1.0, 0.4, 0.9),
                isWireframeStyle: true
            )
        case .mirror:
            return Renderer.Options(
                showLandmarks: false,
                showAvatarMask: false,
                showFaceMesh: false,
                isWireframeStyle: false
            )
        case .mask:
            return Renderer.Options(
                showLandmarks: false,
                showAvatarMask: false,
                showFaceMesh: true,
                meshStyle: .filled,
                meshColor: SIMD4(0.92, 0.74, 0.58, 0.95),  // warm skin-toned fill for the synthetic face
                isWireframeStyle: false
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
        /// M59 — persisted dev-build override. In release the toggle is locked on; the key
        /// is read but always coerced to true via `chirpLockedInRelease` (same pattern as
        /// `watermarkLockedInRelease`).
        public static let chirpEnabled    = "mirrormesh.chirpEnabled"
        // v0.7.0 / v0.8.0 — voice + translation persistence.
        public static let voiceEnabled    = "mirrormesh.voiceEnabled"
        public static let voiceLocale     = "mirrormesh.voiceLocale"
        public static let translationEnabled       = "mirrormesh.translationEnabled"
        public static let translationTargetLocale  = "mirrormesh.translationTargetLocale"
        public static let ollamaModel    = "mirrormesh.ollamaModel"
    }

    /// Default suite name. Tests pass their own to stay isolated.
    public static let defaultSuiteName = "ai.mirrormesh"

    @Published public var showLandmarks: Bool { didSet { defaults.set(showLandmarks, forKey: Keys.showLandmarks) } }
    @Published public var showAvatarMask: Bool { didSet { defaults.set(showAvatarMask, forKey: Keys.showAvatarMask) } }
    @Published public var watermarkVisible: Bool { didSet { defaults.set(watermarkVisible, forKey: Keys.watermarkVisible) } }
    @Published public var renderStyle: RenderStyle { didSet { defaults.set(renderStyle.rawValue, forKey: Keys.renderStyle) } }
    /// M59 — audible disclosure chirp. Default true; locked-on in release builds (R2/R12).
    /// Mutating this in release is a no-op against `effectiveChirpEnabled`, but we still
    /// persist the user's preference so flipping back to a dev build remembers it.
    @Published public var chirpEnabled: Bool { didSet { defaults.set(chirpEnabled, forKey: Keys.chirpEnabled) } }

    // v0.7.0 — voice (Apple Speech). Default off; user opts in. Locale is a BCP-47 string so
    // we round-trip through UserDefaults without an explicit codec.
    @Published public var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Keys.voiceEnabled) } }
    @Published public var voiceLocale: String { didSet { defaults.set(voiceLocale, forKey: Keys.voiceLocale) } }

    // v0.8.0 — translation (local Ollama + AVSpeech). Default off; enabling locks the
    // disclosure chirp on per R2/R12 (orchestrator wires `effectiveChirpEnabled` to
    // honor `translationActive`).
    @Published public var translationEnabled: Bool { didSet { defaults.set(translationEnabled, forKey: Keys.translationEnabled) } }
    @Published public var translationTargetLocale: String { didSet { defaults.set(translationTargetLocale, forKey: Keys.translationTargetLocale) } }
    @Published public var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) } }

    /// Release builds never let users hide the watermark. We surface that as a locked toggle.
    public let watermarkLockedInRelease: Bool
    /// Same locking semantics as `watermarkLockedInRelease` — true in release, false in DEBUG.
    /// Used by both the UI (to disable the toggle) and by `effectiveChirpEnabled` (to coerce
    /// the runtime value to true regardless of the persisted preference).
    public let chirpLockedInRelease: Bool

    /// The actual runtime value: chirpEnabled OR locked-in-release. The audio path should
    /// read this, never `chirpEnabled` directly.
    public var effectiveChirpEnabled: Bool {
        chirpLockedInRelease ? true : chirpEnabled
    }

    private let defaults: UserDefaults

    public init(showLandmarks: Bool = true,
                showAvatarMask: Bool = true,
                watermarkVisible: Bool = true,
                renderStyle: RenderStyle = .wireframe,
                chirpEnabled: Bool = true,
                // v0.7.0 / v0.8.0 "no gating": voice + translation default-on. Backends fail-soft
                // when permissions / Ollama aren't available; the inspector status rows surface
                // what's working. The user can flip these off at any time and the change persists.
                voiceEnabled: Bool = true,
                voiceLocale: String = "en-US",
                translationEnabled: Bool = true,
                translationTargetLocale: String = "es-ES",
                ollamaModel: String = "llama3.2:3b",
                suiteName: String? = "ai.mirrormesh") {
        // Why: a named suite avoids polluting the host process's standard defaults and lets
        // tests inject a unique suite for isolation. Falls back to standard if the suite fails.
        let store = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = store
        // Why: `object(forKey:)` returns nil when unset, so we distinguish "not stored" from "stored false".
        self.showLandmarks    = (store.object(forKey: Keys.showLandmarks)    as? Bool) ?? showLandmarks
        self.showAvatarMask   = (store.object(forKey: Keys.showAvatarMask)   as? Bool) ?? showAvatarMask
        self.watermarkVisible = (store.object(forKey: Keys.watermarkVisible) as? Bool) ?? watermarkVisible
        self.chirpEnabled     = (store.object(forKey: Keys.chirpEnabled)     as? Bool) ?? chirpEnabled
        // v0.7.0 / v0.8.0 — voice + translation persistence. Strings via `string(forKey:)`
        // because UserDefaults distinguishes "missing" from "" via the nil return.
        self.voiceEnabled            = (store.object(forKey: Keys.voiceEnabled)        as? Bool) ?? voiceEnabled
        self.voiceLocale             = store.string(forKey: Keys.voiceLocale)              ?? voiceLocale
        self.translationEnabled      = (store.object(forKey: Keys.translationEnabled)  as? Bool) ?? translationEnabled
        self.translationTargetLocale = store.string(forKey: Keys.translationTargetLocale)  ?? translationTargetLocale
        self.ollamaModel             = store.string(forKey: Keys.ollamaModel)              ?? ollamaModel
        if let raw = store.string(forKey: Keys.renderStyle), let style = RenderStyle(rawValue: raw) {
            self.renderStyle = style
        } else {
            self.renderStyle = renderStyle
        }
        #if DEBUG
        self.watermarkLockedInRelease = false
        self.chirpLockedInRelease     = false
        #else
        self.watermarkLockedInRelease = true
        self.chirpLockedInRelease     = true
        #endif
    }
}
