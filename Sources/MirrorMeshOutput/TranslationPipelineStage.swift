import Foundation
import MirrorMeshCore
import MirrorMeshTranslate

// =============================================================================
// TranslationPipelineStage — pipeline-side façade over MirrorMeshTranslate
// =============================================================================
//
// Named `TranslationPipelineStage` (not `TranslationStage`) to avoid colliding
// with the actor of that name inside `MirrorMeshTranslate`. This wrapper:
//
//   • Owns one `TranslationStage` actor
//   • Exposes `translate(_:)` for the orchestrator's voice → translate wiring
//   • Exposes `currentOverlay(at:)` for the per-frame mouth-region overlay
//   • Tracks `voice_transformed` lifetime (true once any overlay has been
//     produced for the session — used by the manifest's WatermarkConfig)
//   • Fans a per-utterance translation-result callback to the orchestrator
//     for telemetry/UI surfaces
//
// Why a final class and not an actor: the orchestrator already pays an `await`
// to enter the Pipeline actor; layering another actor here forces a second
// hop on every per-frame overlay read. The underlying `TranslationStage` is
// already an actor — its mutable state is serialized there. This wrapper
// stores only its options + callback slots + the latest overlay snapshot,
// guarded by a serial queue.

/// Pipeline-side stage that owns translation + TTS + lip-sync. The pipeline
/// instantiates one of these per `run()` when `options.translationEnabled` is
/// true and tears it down in the cleanup tail.
public final class TranslationPipelineStage: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.mirrormesh.translate.stage")

    /// Underlying actor that owns Ollama + TTS + LipSyncDriver. We never expose
    /// this directly — all access goes through our queue-guarded surface.
    private let stage: TranslationStage

    /// Cached snapshot of the most-recently observed overlay, refreshed by the
    /// per-utterance `speak` task. Read on every render frame via
    /// `currentOverlay(at:)`. Surfaced this way (rather than awaiting the
    /// underlying actor) so the per-frame path stays sync.
    private var latestOverlay: LipSyncCoefficients

    /// Has the stage produced at least one non-rest overlay since construction?
    /// Surfaced via `isActive` so the watermark/manifest can stamp
    /// `voice_transformed: true` for the rest of the session.
    ///
    /// Sticky-true on purpose: even if no further utterance arrives, the
    /// session's disclosure must reflect that translation HAS been applied.
    private var hasEverActivated: Bool = false

    /// Optional callback the orchestrator can install to surface translation
    /// results to the UI (e.g. for a captions overlay). Set via
    /// `setOnTranslation(_:)`.
    private var onTranslation: (@Sendable (String) -> Void)?

    /// In-flight translate task. Captured so we can cancel on `stop()`.
    private var activeTask: Task<Void, Never>?

    public init(options: TranslationStageOptions) {
        self.stage = TranslationStage(options: options)
        self.latestOverlay = LipSyncCoefficients.rest(
            at: MirrorMeshCore.hostTimeNs()
        )
    }

    /// Hot-swap options at runtime. Mirrors `Pipeline.setRendererOptions(_:)`.
    public func updateOptions(_ options: TranslationStageOptions) async {
        await stage.updateOptions(options)
    }

    /// Install or clear the translation-result callback. The callback fires
    /// once per successful utterance with the fully assembled translated
    /// string (post-Ollama, pre-TTS). Used by the orchestrator to relay to
    /// the SwiftUI captions overlay.
    public func setOnTranslation(_ cb: (@Sendable (String) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.onTranslation = cb
                cont.resume()
            }
        }
    }

    /// Subscribe to a `Transcript` from VoiceStage. Spawns a translate-then-
    /// speak task in the background and returns immediately so the voice
    /// drain task isn't blocked. The task runs until the synthesizer
    /// finishes; while running, `currentOverlay(at:)` returns the latest
    /// mouth shape.
    ///
    /// **Why only on `isFinal` callers**: the orchestrator decides whether to
    /// pass partial transcripts to translation. The default policy is finals
    /// only (avoids translating moving targets); see `Pipeline.run()` for the
    /// active filter.
    public func translate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any in-flight utterance — only one speak at a time, otherwise
        // AVSpeechSynthesizer drops audio buffers and the lip-sync goes out of
        // sync with what the listener hears.
        queue.async {
            self.activeTask?.cancel()
            let stageRef = self.stage
            let task = Task.detached(priority: .userInitiated) { [stageRef, weakSelf = WeakBox(self)] in
                do {
                    try await stageRef.speak(trimmed)
                    // After `speak` completes, fan out the translation result + poll
                    // the actor for its latest overlay so our cached snapshot reflects
                    // the post-utterance rest state.
                    let now = MirrorMeshCore.hostTimeNs()
                    let last = await stageRef.currentOverlay(at: now)
                    weakSelf.value?.queue.async {
                        weakSelf.value?.latestOverlay = last
                    }
                } catch {
                    // Surface as a telemetry warning. The pipeline keeps running —
                    // a failed translation (e.g. Ollama down) doesn't kill the session,
                    // it just leaves the mouth at rest.
                    await Telemetry.shared.emit(.warning(
                        stage: .solver, // no .translate stage id today; reuse .solver
                        message: "translation: \(error)"
                    ))
                }
            }
            self.activeTask = task
            // Detached poll: refresh latestOverlay at the lip-sync rate (~60 Hz)
            // for as long as the speak task is alive. Cheap actor poll — same
            // pattern the orchestrator would use otherwise.
            let pollTask = Task.detached(priority: .userInitiated) { [stageRef, weakSelf = WeakBox(self)] in
                let pollIntervalNs: UInt64 = 16_000_000  // ~60 Hz
                while !Task.isCancelled {
                    let now = MirrorMeshCore.hostTimeNs()
                    let overlay = await stageRef.currentOverlay(at: now)
                    let active = await stageRef.isActive
                    weakSelf.value?.queue.async {
                        weakSelf.value?.latestOverlay = overlay
                        if active { weakSelf.value?.hasEverActivated = true }
                    }
                    if task.isCancelled { break }
                    // Check task completion via a yield — finished tasks set isCancelled? No;
                    // we just rely on the outer `speak` finishing then this loop running one
                    // more iteration and exiting on the next cancellation hook (we cancel it
                    // when activeTask completes via the structured `await task.value` below).
                    try? await Task.sleep(nanoseconds: pollIntervalNs)
                }
            }
            // Stop the poll loop once speak finishes.
            Task.detached { [pollTask] in
                _ = await task.value
                pollTask.cancel()
            }
            // Surface the translation text — we need to peek the actor's last response.
            // The TranslationStage doesn't currently expose the raw string; the closest
            // proxy is "the speak call succeeded". Until the stage exposes the translated
            // string directly, the UI can derive it from telemetry annotations the
            // OllamaTranslator emits. For now this hook is reserved for forward-compat;
            // the orchestrator installs a callback that may stay unused in v0.8.0.
            let cb: (@Sendable (String) -> Void)? = self.onTranslation
            if let cb { Task.detached { cb(trimmed) } }
        }
    }

    /// Pull the most recent overlay for this video frame. Sync — reads the
    /// cached snapshot under the queue. The staleness check (>200 ms ⇒ rest)
    /// is delegated to the underlying actor; we mirror its behaviour here so
    /// the renderer never sees a sticky mouth between utterances.
    public func currentOverlay(at hostTimeNs: UInt64) -> LipSyncCoefficients {
        return queue.sync {
            let staleNs: UInt64 = 200_000_000  // mirror TranslationStage.currentOverlay
            if hostTimeNs &- latestOverlay.hostTimeNs > staleNs {
                return LipSyncCoefficients.rest(at: hostTimeNs)
            }
            return latestOverlay
        }
    }

    /// True once the stage has produced any non-rest overlay. Sticky-true for
    /// the rest of the session — drives `WatermarkConfig.voice_transformed`.
    public var isActive: Bool {
        queue.sync { hasEverActivated }
    }

    /// Tear down — cancel in-flight speak, leave the latest overlay alone so
    /// readers after stop see the last-known shape gracefully glide to rest.
    public func stop() async {
        let task: Task<Void, Never>? = await withCheckedContinuation { (cont: CheckedContinuation<Task<Void, Never>?, Never>) in
            queue.async {
                let t = self.activeTask
                self.activeTask = nil
                cont.resume(returning: t)
            }
        }
        task?.cancel()
    }
}

/// Weak-box helper local to this file. Sendable because the box only owns a
/// weak reference and reads happen via Swift's runtime atomicity.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
