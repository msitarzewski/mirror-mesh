import Testing
import Foundation
@testable import MirrorMeshAppKit
import MirrorMeshCore
import MirrorMeshSolver

/// M38: AppSettings must round-trip through UserDefaults across instances.
/// Tests run in isolation via per-test suite names so we don't pollute the host's `ai.mirrormesh`.
@Suite("AppSettingsPersistence")
@MainActor
struct AppSettingsPersistenceTests {

    /// Why: each test allocates a unique suite + removes it on exit so persistence is hermetic.
    private func makeUniqueSuite() -> String {
        "ai.mirrormesh.tests.\(UUID().uuidString)"
    }

    private func wipe(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test func showLandmarksRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.showLandmarks = false
        // Why: didSet writes synchronously, but synchronize() forces the suite to flush so a
        // fresh UserDefaults instance reads the written value deterministically.
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.showLandmarks == false)
    }

    @Test func avatarMaskRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.showAvatarMask = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.showAvatarMask == false)
    }

    @Test func watermarkVisibleRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.watermarkVisible = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.watermarkVisible == false)
    }

    @Test func defaultsApplyWhenNothingPersisted() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let settings = AppSettings(suiteName: suite)
        #expect(settings.showLandmarks == true)
        #expect(settings.showAvatarMask == true)
        #expect(settings.watermarkVisible == true)
        #expect(settings.chirpEnabled == true)
        // v0.7.0 / v0.8.0 "no gating": voice + translation default-on so the full demo flow is
        // active on first launch. Backends fail-soft if permissions / Ollama unavailable.
        #expect(settings.voiceEnabled == true)
        #expect(settings.voiceLocale == "en-US")
        #expect(settings.translationEnabled == true)
        #expect(settings.translationTargetLocale == "es-ES")
        #expect(settings.ollamaModel == "llama3.2:3b")
    }

    @Test func multipleTogglesPersistTogether() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.showLandmarks = false
        first.showAvatarMask = false
        first.watermarkVisible = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.showLandmarks == false)
        #expect(second.showAvatarMask == false)
        #expect(second.watermarkVisible == false)
    }

    // M59: chirp toggle persists across instances same as the others.
    @Test func chirpEnabledRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.chirpEnabled = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.chirpEnabled == false)
    }

    // v0.7.0 — voice toggle + locale persist independently across instances.
    @Test func voiceEnabledRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        #expect(first.voiceEnabled == true)  // v0.7.0 "no gating" default on
        first.voiceEnabled = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.voiceEnabled == false)
    }

    @Test func voiceLocaleRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        #expect(first.voiceLocale == "en-US")  // default
        first.voiceLocale = "ja-JP"
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.voiceLocale == "ja-JP")
    }

    // v0.8.0 — translation toggle + target locale + ollama model persist independently.
    @Test func translationEnabledRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        #expect(first.translationEnabled == true)  // v0.8.0 "no gating" default on
        first.translationEnabled = false
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.translationEnabled == false)
    }

    @Test func translationTargetLocaleRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        #expect(first.translationTargetLocale == "es-ES")
        first.translationTargetLocale = "fr-FR"
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.translationTargetLocale == "fr-FR")
    }

    @Test func ollamaModelRoundTrips() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        #expect(first.ollamaModel == "llama3.2:3b")
        first.ollamaModel = "qwen2.5:3b"
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.ollamaModel == "qwen2.5:3b")
    }

    /// Voice + translation settings round-trip together — covers the "all five at once" case
    /// that the inspectors will actually drive.
    @Test func voiceAndTranslationSettingsPersistTogether() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let first = AppSettings(suiteName: suite)
        first.voiceEnabled = true
        first.voiceLocale = "de-DE"
        first.translationEnabled = true
        first.translationTargetLocale = "ja-JP"
        first.ollamaModel = "gemma2:2b"
        UserDefaults(suiteName: suite)?.synchronize()

        let second = AppSettings(suiteName: suite)
        #expect(second.voiceEnabled == true)
        #expect(second.voiceLocale == "de-DE")
        #expect(second.translationEnabled == true)
        #expect(second.translationTargetLocale == "ja-JP")
        #expect(second.ollamaModel == "gemma2:2b")
    }

    // M59: effectiveChirpEnabled honors the release lock. In DEBUG it follows chirpEnabled.
    // The test runs under DEBUG (swift test always sets DEBUG), so we verify that path; the
    // release-lock branch is exercised via the compile-time `#if` and reviewed by inspection.
    @Test func effectiveChirpFollowsToggleInDebug() async {
        let suite = makeUniqueSuite()
        defer { wipe(suite) }

        let settings = AppSettings(suiteName: suite)
        #expect(settings.chirpLockedInRelease == false)
        settings.chirpEnabled = false
        #expect(settings.effectiveChirpEnabled == false)
        settings.chirpEnabled = true
        #expect(settings.effectiveChirpEnabled == true)
    }
}

/// M59: DisclosureChirp sample synthesis is a pure function — assert the buffer has the
/// expected shape and stays within the documented amplitude. Audio I/O is intentionally
/// not exercised (CI environments may lack an output device).
@Suite("DisclosureChirpSynthesis")
struct DisclosureChirpSynthesisTests {

    @Test func samplesAreBoundedAndShaped() {
        let sampleRate: Float = 48_000
        let count = Int(sampleRate * 0.25)  // 250 ms
        let samples = DisclosureChirp.renderSamples(
            count: count,
            sampleRate: sampleRate,
            f1: 440,
            f2: 659.25,
            peakAmplitude: 0.125
        )
        #expect(samples.count == count)
        // Attack ramp at the very start: first sample must be near zero.
        #expect(abs(samples[0]) < 0.01)
        // Release ramp at the very end: last sample must be near zero (no pop on stop).
        #expect(abs(samples[count - 1]) < 0.01)
        // Bounded by peakAmplitude with a small overshoot allowance for the sine maxima.
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak <= 0.135)
        // The middle of the buffer should have measurable energy (we're synthesizing tones,
        // not silence).
        let mid = samples[count / 2]
        #expect(abs(mid) > 0 || abs(samples[count / 2 + 1]) > 0)
    }

    @Test func zeroLengthIsSafe() {
        let samples = DisclosureChirp.renderSamples(
            count: 0,
            sampleRate: 48_000,
            f1: 440,
            f2: 659.25,
            peakAmplitude: 0.125
        )
        #expect(samples.isEmpty)
    }
}

@Suite("AvatarSettingsPersistence")
@MainActor
struct AvatarSettingsPersistenceTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "ai.mirrormesh.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        body(suite)
    }

    @Test func appDefaultsToExpressiveWithNoTransforms() {
        withSuite { suite in
            let s = AppSettings(suiteName: suite)
            #expect(s.avatarKind == .expressive)
            #expect(!s.expressionTransforms.isActive)
            #expect(s.likenessEnabled)
            s.likenessEnabled = false
            UserDefaults(suiteName: suite)?.synchronize()
            #expect(AppSettings(suiteName: suite).likenessEnabled == false)
        }
    }

    @Test func avatarAndAccessibilitySettingsRoundTrip() {
        withSuite { suite in
            let first = AppSettings(suiteName: suite)
            first.avatarKind = .classic
            first.symmetryAssistEnabled = true
            first.symmetryAffectedSide = .right
            first.symmetryStrength = 0.65
            first.expressionGainEnabled = true
            first.expressionGain = 2.25
            first.eyeContactEnabled = true
            first.eyeContactStrength = 0.4
            UserDefaults(suiteName: suite)?.synchronize()

            let second = AppSettings(suiteName: suite)
            #expect(second.avatarKind == .classic)
            #expect(second.symmetryAssistEnabled)
            #expect(second.symmetryAffectedSide == .right)
            #expect(second.symmetryStrength == 0.65)
            #expect(second.expressionGain == 2.25)
            #expect(second.eyeContactStrength == 0.4)
            #expect(second.expressionTransforms.manifestTags == ["symmetry:right:0.65", "gain:2.25", "eye_contact:0.40"])
        }
    }

    @Test func disabledTogglesKeepTunedStrengthsButApplyNothing() {
        withSuite { suite in
            let s = AppSettings(suiteName: suite)
            s.expressionGain = 2.5
            s.eyeContactStrength = 0.9
            #expect(!s.expressionTransforms.isActive)
            s.expressionGainEnabled = true
            #expect(s.expressionTransforms.gain == 2.5)
            #expect(s.expressionTransforms.eyeContact == 0)
        }
    }
}
