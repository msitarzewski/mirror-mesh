# 261018_ci-vision-headless

**Milestone ID**: none (bug fix following the expressive-avatar merge). Branch: `fix/ci-vision-headless`.

## Objective

Make CI pass on GitHub's `macos-14` runner after the expressive-avatar merge (`3d41c0b`). The first
run on main (39151152028) failed in `swift test`: the hosted VM cannot create a Vision inference
context, which crashed the test process in `IdentitySelfCapture` and failed the new
`PortraitAnalyzer` tests.

## Outcome

- ✅ Tests: 289 passing / 56 suites under a plain `swift test` (same invocation as CI, nothing skipped locally)
- ✅ Build: clean; also removes a Swift 6 isolation warning on `bboxPaddingFraction`
- ✅ Review: maintainer asked to "update the memory bank, then commit push merge"
- On CI's virtual GPU the 7 ExpressiveHead goldens and the render property tests already passed;
  the head rendered in 17.4 ms per frame (33 ms budget)

## Root cause

- Vision on the hosted VM fails every request with
  `Error Domain=com.apple.Vision Code=9 "Could not create inference context"`.
- `IdentitySelfCapture.detectLargestFaceBoundingBox` wrapped a completion-handler request in
  `withCheckedThrowingContinuation`. When Vision fails it *both* calls the completion handler with
  the error *and* throws from `perform`, so the continuation resumed twice →
  `SWIFT TASK CONTINUATION MISUSE` → signal 5, killing the test process.
- `PortraitAnalyzer` tests need face landmarks and so fail outright without Vision.

## Files Modified

- `Sources/MirrorMeshAppKit/IdentitySelfCapture.swift` — synchronous `perform` + `request.results`
  (no continuation); new `CaptureError.visionUnavailable`; `bboxPaddingFraction` marked `nonisolated`.
- `Sources/MirrorMeshReenact/PortraitAnalyzer.swift` — `AnalyzerError.visionUnavailable`;
  `isVisionAvailable` probe (face-rectangles request on a blank 64×64 image: empty results on a
  working host, an error on a headless VM).
- `Tests/MirrorMeshReenactTests/PortraitAnalyzerTests.swift` — Vision-dependent tests gated on
  `isVisionAvailable`; the tampered-bundle rejection still runs everywhere (verification precedes Vision).
- `Tests/MirrorMeshOutputTests/ExpressiveAvatarPipelineTests.swift` — likeness pipeline test gated.
- `Tests/MirrorMeshAppKitTests/IdentitySelfCaptureTests.swift` — `visionUnavailable` is an accepted
  outcome for the synthetic-image mint test (it must surface as an error, never a crash).

## Patterns Applied

- Environmental skips use `.enabled(if:)` with a reason string, the same shape as the existing
  camera / Speech / model-presence gates (`testing-patterns.md#Hosted CI limits`).

## Lessons

- Don't bridge a Vision request's completion handler into a continuation while also catching
  `perform`'s throw; Vision reports one failure through both. Run `perform` synchronously and read
  `request.results`.
