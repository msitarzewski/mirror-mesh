import Testing
import Foundation
@testable import MirrorMeshOutput
import MirrorMeshCore

/// M37: smooth preview → live handoff. The view-model brings up the next pipeline in parallel
/// and only swaps once it emits its first frame. The underlying primitive — running two
/// Pipelines back to back with overlapping start/stop calls — must not crash.
@Suite("PreviewToLiveTransition")
struct PreviewToLiveTransitionTests {

    private func tmpManifestURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-m37-\(UUID().uuidString).manifest.json")
    }

    /// Why: the simplest invariant — start a synthetic pipeline, let it produce some frames,
    /// stop it. The preview path lives here in production; if this crashes the whole UX fails.
    @Test func syntheticPipelineRunAndStopIsClean() async throws {
        let opts = PipelineOptions(
            mode: .synthetic,
            captureWidth: 320,
            captureHeight: 240,
            fps: 30,
            maxFrames: 5
        )
        let pipeline = Pipeline(options: opts, manifestURL: tmpManifestURL(), jsonlURL: nil)
        let result = try await pipeline.run()
        #expect(result.framesProcessed == 5)
        await pipeline.stop()  // idempotent after run completes
    }

    /// Why M37: the handoff pattern runs two pipelines in parallel until the second emits its
    /// first frame, then stops the first. This exercises the same lifecycle: two pipelines
    /// alive at once, then one is stopped while the other keeps going.
    @Test func twoPipelinesCanCoexistAndOneStopsWithoutAffectingTheOther() async throws {
        let preview = Pipeline(
            options: PipelineOptions(
                mode: .synthetic,
                captureWidth: 320,
                captureHeight: 240,
                fps: 30,
                maxFrames: nil  // run until stop
            ),
            manifestURL: tmpManifestURL(),
            jsonlURL: nil
        )
        let next = Pipeline(
            options: PipelineOptions(
                mode: .synthetic,
                captureWidth: 320,
                captureHeight: 240,
                fps: 30,
                maxFrames: 3
            ),
            manifestURL: tmpManifestURL(),
            jsonlURL: nil
        )

        let previewTask = Task { try? await preview.run() }
        // Why: brief yield lets the preview start producing frames before next comes up.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Bring "next" up in parallel; await its short run to completion.
        let result = try await next.run()
        #expect(result.framesProcessed == 3)

        // Now stop the preview — analog of `promotePendingPipeline` swapping it out.
        await preview.stop()
        _ = await previewTask.value
    }

    /// Why M37: a frame-arrival callback drives the UI swap. Confirm that `setOnRender` actually
    /// fires once frames are produced — the entire handoff hinges on this trigger.
    @Test func onRenderCallbackFiresForEveryFrame() async throws {
        let opts = PipelineOptions(
            mode: .synthetic,
            captureWidth: 320,
            captureHeight: 240,
            fps: 30,
            maxFrames: 4
        )
        let pipeline = Pipeline(options: opts, manifestURL: tmpManifestURL(), jsonlURL: nil)

        // Why: actor-protected counter avoids data races from the @Sendable callback.
        actor Counter {
            var n = 0
            func inc() { n += 1 }
        }
        let counter = Counter()
        await pipeline.setOnRender { _ in
            Task { await counter.inc() }
        }

        _ = try await pipeline.run()
        // Why: callbacks are dispatched onto detached Tasks; wait a beat for them to settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let observed = await counter.n
        #expect(observed == 4)
    }
}
