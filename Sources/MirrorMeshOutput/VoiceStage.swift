import Foundation
import MirrorMeshCore
import MirrorMeshVoice

// =============================================================================
// VoiceStage — pipeline-side wrapper around `AppleSpeechBackend`
// =============================================================================
//
// This stage mirrors the shape of `ReenactStage` (final class, @unchecked Sendable):
// pipeline orchestrator owns one instance per `Pipeline.run()` and tears it down
// alongside the frame source. It owns:
//
//   • a `SpeechRecognitionBackend` (default: `AppleSpeechBackend`, on-device only)
//   • a draining `Task` that converts the backend's `AsyncStream<Transcript>` into
//     fan-out callback invocations
//   • a single `onTranscript` callback slot the orchestrator sets at start time
//
// Lifecycle invariants:
//   • `start()` is idempotent against double-start: a second call when already
//     active throws `SpeechRecognitionError.alreadyRunning` (propagated from the
//     backend).
//   • `stop()` is idempotent against double-stop: cancels the drain task and
//     calls backend.stop(); calling it a second time is a no-op.
//   • `setOnTranscript(_:)` may be called before or after `start()`; the new
//     callback applies to all subsequently-drained transcripts.
//
// Why not an actor: the stage's only mutable state is the drain task and the
// callback slot. The backend is already an actor (AppleSpeechBackend) or thread-
// safe (MockSpeechBackend), so the stage just funnels their output. A serial
// queue + final class lets the orchestrator subscribe without an extra await.

/// Pipeline-side voice capture stage. Wraps a `SpeechRecognitionBackend` so the
/// orchestrator doesn't need to know about Speech / AVAudioEngine directly.
///
/// The stage emits a `TranscriptFrame` telemetry event for every transcript so
/// `JSONLLogger` records the on-device voice activity on the same timeline as
/// rendered frames. The optional `onTranscript` callback fans out the typed
/// `Transcript` (with `isFinal`) for the orchestrator to forward to
/// `TranslationPipelineStage`.
public final class VoiceStage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mirrormesh.voice.stage")
    private let backend: any SpeechRecognitionBackend

    /// Drain task that pumps the backend's `AsyncStream<Transcript>` into our
    /// callback. Owned exclusively here so `stop()` can cancel it.
    private var drainTask: Task<Void, Never>?

    /// Mirror of the callback slot, set by `setOnTranscript`. Accessed under
    /// `queue` for safety even though the read happens on the drain task and
    /// the write may happen from the orchestrator's actor.
    private var onTranscript: (@Sendable (Transcript) -> Void)?

    /// True once `start()` has launched its drain task and the task hasn't
    /// finished yet. Used by `setOnTranscript(_:)` and `isActive` queries.
    private var running: Bool = false

    /// Default initializer: builds an `AppleSpeechBackend` (on-device, fails if
    /// the locale lacks an on-device model). Throws `SpeechRecognitionError`
    /// pre-start so the orchestrator can refuse the session before the rest
    /// of the pipeline initializes.
    public init(locale: String) throws {
        self.backend = try AppleSpeechBackend(localeIdentifier: locale)
    }

    /// Test-injection initializer. Accepts any `SpeechRecognitionBackend` —
    /// production callers should prefer the locale-string init above.
    public init(backend: any SpeechRecognitionBackend) {
        self.backend = backend
    }

    /// Begin live mic capture. Throws if the backend refuses (permission,
    /// already running, audio engine failure). On success, spawns the drain
    /// task; calls to `setOnTranscript` from here on get fanned the stream.
    public func start() async throws {
        // Atomically claim "running" — same idea as `AppleSpeechBackend`'s own
        // alreadyRunning check, but at the stage layer so callers see a single
        // error surface.
        let claimed: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                if self.running {
                    cont.resume(returning: false)
                } else {
                    self.running = true
                    cont.resume(returning: true)
                }
            }
        }
        guard claimed else {
            throw SpeechRecognitionError.alreadyRunning
        }

        let stream: AsyncStream<Transcript>
        do {
            stream = try await backend.start()
        } catch {
            // Roll back the running flag so a retry can succeed.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async {
                    self.running = false
                    cont.resume()
                }
            }
            throw error
        }

        // Drain in a detached task so the orchestrator's run-loop never blocks
        // on a transcript. Each transcript fan-outs to (a) telemetry as a
        // TranscriptFrame and (b) the callback set via setOnTranscript.
        let weakSelf = WeakBox(self)
        drainTask = Task.detached(priority: .userInitiated) {
            for await transcript in stream {
                // Telemetry first — even if the callback is nil we want JSONL
                // to record voice activity.
                await Telemetry.shared.emit(.transcript(transcript.asTranscriptFrame))

                guard let stage = weakSelf.value else { continue }
                let cb: (@Sendable (Transcript) -> Void)? = stage.queue.sync { stage.onTranscript }
                cb?(transcript)
            }
            // Stream finished — clear running so `stop()` is a no-op and a
            // future `start()` can succeed cleanly.
            guard let stage = weakSelf.value else { return }
            stage.queue.async { stage.running = false }
        }
    }

    /// Stop the backend and cancel the drain task. Idempotent.
    public func stop() async {
        let task: Task<Void, Never>? = await withCheckedContinuation { (cont: CheckedContinuation<Task<Void, Never>?, Never>) in
            queue.async {
                let t = self.drainTask
                self.drainTask = nil
                self.running = false
                cont.resume(returning: t)
            }
        }
        task?.cancel()
        await backend.stop()
    }

    /// Install or clear the transcript callback. Calls cross the actor boundary;
    /// `@Sendable` is mandatory.
    public func setOnTranscript(_ cb: (@Sendable (Transcript) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.onTranscript = cb
                cont.resume()
            }
        }
    }

    /// True iff `start()` succeeded and the drain task hasn't finished.
    public var isActive: Bool {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async {
                    cont.resume(returning: self.running)
                }
            }
        }
    }
}

/// Tiny weak-box helper. Sendable because the box itself only carries an
/// optional reference; reads + writes go through Swift's atomic-pointer
/// semantics, and we only read in the drain task.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
