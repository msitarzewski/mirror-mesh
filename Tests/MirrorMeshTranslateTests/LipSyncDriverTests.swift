import Testing
import Foundation
import MirrorMeshCore
import MirrorMeshReenact
@testable import MirrorMeshTranslate

@Suite("LipSyncDriver")
struct LipSyncDriverTests {

    // MARK: - LipSyncCoefficients invariants

    @Test func coefficientsClampInputsToZeroOne() {
        let raw: [StylizedBlendshape: Float] = [
            .jawOpen: 2.5,           // out of range — should clamp to 1
            .mouthPucker: -0.4,      // negative — should clamp to 0
            .mouthWide: 0.55,        // in range — pass through
            .smileL: 0.30,
            .smileR: 0.30,
        ]
        let c = LipSyncCoefficients(values: raw, hostTimeNs: 1_000_000)
        #expect(c.values[.jawOpen] == 1.0)
        #expect(c.values[.mouthPucker] == 0.0)
        #expect(c.values[.mouthWide] == 0.55)
    }

    @Test func coefficientsDropDisallowedKeys() {
        // browUpL is not a mouth-region key — the overlay must drop it.
        let raw: [StylizedBlendshape: Float] = [
            .jawOpen: 0.5,
            .browUpL: 0.9,        // disallowed
            .eyeCloseL: 1.0,      // disallowed
        ]
        let c = LipSyncCoefficients(values: raw, hostTimeNs: 42)
        #expect(c.values[.jawOpen] == 0.5)
        #expect(c.values[.browUpL] == nil)
        #expect(c.values[.eyeCloseL] == nil)
    }

    @Test func restCoefficientsAreAllZero() {
        let c = LipSyncCoefficients.rest(at: 999)
        for k in LipSyncCoefficients.mouthShapeKeys {
            #expect((c.values[k] ?? -1) == 0)
        }
    }

    // MARK: - Vowel-class shaping

    @Test func sustainedOpenAProducesHighJawOpen() {
        let driver = LipSyncDriver(options: LipSyncOptions(
            smoothingMinCutoff: 30.0,    // high cutoff = minimal smoothing, near-passthrough
            smoothingBeta: 0.0
        ))
        var lastJaw: Float = 0
        var t: UInt64 = 0
        for _ in 0..<30 {
            t &+= 16_666_666     // 60 Hz
            let frame = TTSFrame(hostTimeNs: t, amplitude: 0.8, dominantVowel: .openA)
            let overlay = driver.update(frame)
            lastJaw = overlay.values[.jawOpen] ?? 0
        }
        // High jaw, low pucker.
        #expect(lastJaw > 0.5)
        #expect((driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.8, dominantVowel: .openA))
                  .values[.mouthPucker] ?? 0) < 0.10)
    }

    @Test func sustainedRoundUProducesPucker() {
        let driver = LipSyncDriver(options: LipSyncOptions(
            smoothingMinCutoff: 30.0,
            smoothingBeta: 0.0
        ))
        var t: UInt64 = 0
        var lastPucker: Float = 0
        var lastJaw: Float = 0
        for _ in 0..<30 {
            t &+= 16_666_666
            let overlay = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.8, dominantVowel: .roundU))
            lastPucker = overlay.values[.mouthPucker] ?? 0
            lastJaw = overlay.values[.jawOpen] ?? 0
        }
        #expect(lastPucker > 0.5)
        #expect(lastJaw < 0.4)
    }

    @Test func sustainedSpreadEProducesMouthWide() {
        let driver = LipSyncDriver(options: LipSyncOptions(
            smoothingMinCutoff: 30.0,
            smoothingBeta: 0.0
        ))
        var t: UInt64 = 0
        var lastWide: Float = 0
        for _ in 0..<30 {
            t &+= 16_666_666
            let overlay = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.8, dominantVowel: .spreadE))
            lastWide = overlay.values[.mouthWide] ?? 0
        }
        #expect(lastWide > 0.3)
    }

    @Test func silenceDrainsTowardZero() {
        // Prime the driver with sustained vowel energy, then feed silence and verify the
        // smoothing relaxes toward zero.
        let driver = LipSyncDriver(options: LipSyncOptions(
            smoothingMinCutoff: 5.0,
            smoothingBeta: 0.0
        ))
        var t: UInt64 = 0
        for _ in 0..<20 {
            t &+= 16_666_666
            _ = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.9, dominantVowel: .openA))
        }
        for _ in 0..<60 {
            t &+= 16_666_666
            _ = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.0, dominantVowel: .silence))
        }
        let overlay = driver.update(TTSFrame(hostTimeNs: t &+ 16_666_666, amplitude: 0, dominantVowel: .silence))
        let jaw = overlay.values[.jawOpen] ?? 1
        let pucker = overlay.values[.mouthPucker] ?? 1
        #expect(jaw < 0.10)
        #expect(pucker < 0.10)
    }

    @Test func allOutputCoefficientsAreBoundedZeroOne() {
        let driver = LipSyncDriver()
        // Feed wild inputs: amplitudes outside [0,1], rapidly alternating vowels.
        var t: UInt64 = 0
        let inputs: [(Float, VowelClass)] = [
            (10.0, .openA),
            (-1.0, .roundU),
            (0.95, .spreadE),
            (0.0,  .silence),
            (0.5,  .roundO),
        ]
        for (amp, vowel) in inputs {
            t &+= 16_666_666
            let overlay = driver.update(TTSFrame(hostTimeNs: t, amplitude: amp, dominantVowel: vowel))
            for v in overlay.values.values {
                #expect(v >= 0)
                #expect(v <= 1)
            }
        }
    }

    @Test func resetClearsSmoothingState() {
        let driver = LipSyncDriver(options: LipSyncOptions(
            smoothingMinCutoff: 30.0,
            smoothingBeta: 0.0
        ))
        var t: UInt64 = 0
        for _ in 0..<20 {
            t &+= 16_666_666
            _ = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.9, dominantVowel: .openA))
        }
        driver.reset()
        // First frame after reset should equal the target shaping with no smoothing carryover.
        t &+= 16_666_666
        let overlay = driver.update(TTSFrame(hostTimeNs: t, amplitude: 0.4, dominantVowel: .roundU))
        // After reset, the first sample is the input itself — so pucker should be substantial
        // (matching roundU's target) and jaw should be lower than the previous openA-sustained value.
        let pucker = overlay.values[.mouthPucker] ?? 0
        #expect(pucker > 0.15)
    }

    // MARK: - Pure shaping function (no smoothing)

    @Test func vowelShapeTargetsCoverFullVowelSpace() {
        let driver = LipSyncDriver()
        let opens = driver.vowelShapeTargets(vowel: .openA, amplitude: 1)
        let us = driver.vowelShapeTargets(vowel: .roundU, amplitude: 1)
        let es = driver.vowelShapeTargets(vowel: .spreadE, amplitude: 1)
        let silence = driver.vowelShapeTargets(vowel: .silence, amplitude: 1)
        #expect(opens.jawOpen > us.jawOpen)
        #expect(us.mouthPucker > opens.mouthPucker)
        #expect(es.mouthWide > us.mouthWide)
        #expect(silence.jawOpen == 0 && silence.mouthPucker == 0 && silence.mouthWide == 0)
    }

    // MARK: - TranslationStage façade

    @Test func translationStageStartsInactive() async {
        let stage = TranslationStage(options: TranslationStageOptions())
        #expect(await stage.isActive == false)
        let now = MirrorMeshCore.hostTimeNs()
        let overlay = await stage.currentOverlay(at: now)
        // Stale overlay (or rest overlay) — all zeros.
        for v in overlay.values.values { #expect(v == 0) }
    }

    @Test func translationStageStaleOverlayReturnsRest() async {
        let stage = TranslationStage(options: TranslationStageOptions())
        // Ask far in the future — overlay must be the rest pose.
        let farFuture = MirrorMeshCore.hostTimeNs() &+ 10_000_000_000
        let overlay = await stage.currentOverlay(at: farFuture)
        for v in overlay.values.values { #expect(v == 0) }
    }
}
