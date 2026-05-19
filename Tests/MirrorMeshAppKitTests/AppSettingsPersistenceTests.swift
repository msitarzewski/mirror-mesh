import Testing
import Foundation
@testable import MirrorMeshAppKit

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
}
