import Foundation
import SwiftUI

// =============================================================================
// AppSettings — chirp-lock-when-translation-active rule (R12 mandate)
// =============================================================================
//
// The base `AppSettings` class lives in `PipelineViewModel.swift` (kept there
// to avoid touching the UI-owning agent's file). This file ADDS the v0.8.0
// translation-aware chirp policy: whenever translation is active, the
// disclosure chirp is locked on regardless of the user's persisted dev-build
// preference. Implementation strategy:
//
//   1. Track `translationActive` via an associated `ObservableObject` slot.
//      We can't add a `@Published` stored property in an extension; instead a
//      lightweight `TranslationActivityBridge` is stored via Objective-C
//      associated objects and exposes its own `@Published var active: Bool`.
//      The PipelineViewModel (owned by another agent) calls
//      `settings.setTranslationActive(_:)` whenever it toggles translation
//      via `Pipeline.setTranslationEnabled(_:options:)`.
//
//   2. `effectiveChirpEnabled` in the base class still works the same way
//      (release-locked or dev preference). We add `chirpShouldBeAudible` as
//      the v0.8.0-aware variant: it returns true whenever translation is
//      active OR `chirpLockedInRelease` is true, falling back to the
//      persisted preference otherwise. The UI agent's job is to swap their
//      audio-emission site from `effectiveChirpEnabled` to
//      `chirpShouldBeAudible` when they wire translationActive through.
//
// **Why not just modify `effectiveChirpEnabled`**: doing so would require
// touching `PipelineViewModel.swift`, which is on the no-touch list per the
// integration spec. Adding a parallel, additive method keeps the boundary
// clean and lets the UI agent flip their call site in their own PR.
//
// **R12 enforcement**: `chirpShouldBeAudible` coerces TRUE on translationActive.
// The user has no way to override this from the UI — there is no `@Published`
// setter that turns it off. The only API for changing translationActive is
// `setTranslationActive(_:)`, which is called by the pipeline's enable/disable
// path and reflects the actual runtime state of the translation stage.

/// Bridge object held by AppSettings (via associated-object pattern) to track
/// whether translation is currently active. `ObservableObject` so SwiftUI views
/// that bind to it re-render when the lock toggles.
@MainActor
public final class TranslationActivityBridge: ObservableObject {
    /// True iff the pipeline's translation stage is currently producing output. Set by
    /// `AppSettings.setTranslationActive(_:)` from the UI/orchestrator wiring.
    @Published public internal(set) var active: Bool = false

    public init() {}
}

// Associated-object key for `translationActivity`. Using a static var address is the
// canonical Objective-C runtime pattern; the &-take is the address-of we feed to
// `objc_setAssociatedObject`.
private nonisolated(unsafe) var translationActivityKey: UInt8 = 0

@MainActor
extension AppSettings {

    /// The `TranslationActivityBridge` that backs `isTranslationActive`. Lazily-allocated on
    /// first access; subsequent access returns the same instance so SwiftUI bindings stay
    /// stable. Public so SwiftUI views can `@ObservedObject` the bridge directly if they
    /// want fine-grained reactivity; most callers should use `isTranslationActive` or
    /// `chirpShouldBeAudible` instead.
    public var translationActivity: TranslationActivityBridge {
        if let existing = objc_getAssociatedObject(self, &translationActivityKey) as? TranslationActivityBridge {
            return existing
        }
        let bridge = TranslationActivityBridge()
        objc_setAssociatedObject(self, &translationActivityKey, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return bridge
    }

    /// True iff translation is currently running in the pipeline. Read-only convenience
    /// over the bridge's `active` flag. SwiftUI views that need to react to this should
    /// observe `translationActivity` directly.
    public var isTranslationActive: Bool {
        translationActivity.active
    }

    /// Update the translation-active flag. The pipeline (or the orchestrator on its behalf)
    /// calls this when `Pipeline.setTranslationEnabled(_:options:)` succeeds; it's also called
    /// with `false` when the stage stops. Sets `objectWillChange` to publish to both the
    /// bridge's observers AND any view that observes `AppSettings` directly.
    public func setTranslationActive(_ active: Bool) {
        // Trigger AppSettings's own publish so SwiftUI views observing `settings.objectWillChange`
        // pick up the chirp-lock change. Reading `objectWillChange.send()` is the supported
        // way to notify an ObservableObject when state outside its @Published properties changes.
        objectWillChange.send()
        translationActivity.active = active
    }

    /// v0.8.0-aware chirp policy. Replaces `effectiveChirpEnabled` at call sites that need to
    /// honour the translation lock. Resolution order (first true wins):
    ///
    ///   1. `chirpLockedInRelease` — release builds always emit. R2 mandate.
    ///   2. `isTranslationActive` — voice transformation requires audible disclosure. R12 mandate.
    ///   3. `chirpEnabled` — the persisted dev-build preference.
    ///
    /// The UI agent flips their `playChirp()` gate from `settings.effectiveChirpEnabled` to
    /// `settings.chirpShouldBeAudible` when wiring translation through. Both methods coexist;
    /// `effectiveChirpEnabled` remains for backward compatibility.
    public var chirpShouldBeAudible: Bool {
        if chirpLockedInRelease { return true }
        if isTranslationActive { return true }
        return chirpEnabled
    }
}
