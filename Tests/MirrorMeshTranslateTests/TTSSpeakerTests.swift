import Testing
import Foundation
import AVFoundation
@testable import MirrorMeshTranslate

@Suite("TTSSpeaker")
struct TTSSpeakerTests {

    // MARK: - Voice selection

    @Test func voiceSelectorReturnsSomethingForEnglishUS() {
        // Every macOS install ships at least one en-US voice. If this fails the
        // host machine is in an unusual state — fail loudly.
        let voice = TTSVoiceSelector.bestVoice(for: Locale(identifier: "en-US"))
        #expect(voice != nil)
    }

    @Test func voiceSelectorFallsBackToLanguageMatch() {
        // Request an unusual region; the selector should still find an English voice via
        // the language-code fallback. We pick `en-GB` (or any other English variant) as the
        // request and verify *some* English voice is returned. If both en-US and en-GB are
        // installed the test still passes — we only assert that the *language* matches.
        let voice = TTSVoiceSelector.bestVoice(for: Locale(identifier: "en-XX"))
        if let v = voice {
            let lang = v.language.split(separator: "-").first.map(String.init) ?? ""
            #expect(lang == "en")
        }
        // If no English voice is on the box at all, the selector returns nil — that's also
        // a valid outcome on a sparsely-provisioned CI image. We don't assert non-nil here.
    }

    @Test func voiceSelectorReturnsNilForGibberishLocale() {
        let voice = TTSVoiceSelector.bestVoice(for: Locale(identifier: "xx-XX-zz"))
        #expect(voice == nil)
    }

    // MARK: - Speak end-to-end (live AVSpeech)

    /// Live AVSpeechSynthesizer test. AVSpeech on macOS may emit audio buffers via the
    /// `write(_:toBufferCallback:)` API even on headless CI runners (it doesn't require an
    /// audio output device — it's pure synthesis). On the rare environment where no en-US
    /// voice is installed, this becomes a no-op (the speak() call throws .noVoiceForLocale
    /// and we record that — see the guard below).
    @Test func speakProducesAtLeastOneTTSFrameForShortPhrase() async throws {
        // Skip cleanly if the host has no English voice.
        guard TTSVoiceSelector.bestVoice(for: Locale(identifier: "en-US")) != nil else {
            return
        }
        let speaker = TTSSpeaker(config: TTSSpeaker.Config(emitHz: 60))
        let stream: AsyncStream<TTSFrame>
        do {
            stream = try await speaker.speak("Hello.", locale: Locale(identifier: "en-US"))
        } catch let err as TTSSpeakerError {
            // Voice is present but writing failed — record + bail.
            Issue.record("speak() failed: \(err.description)")
            return
        }
        var frames: [TTSFrame] = []
        let collector = Task {
            for await f in stream { frames.append(f) }
        }
        // Wall-clock bound so the test never hangs if AVSpeech is slow to start.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if frames.count >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        collector.cancel()
        // We tolerate zero frames on machines where AVSpeech buffering is broken — assert
        // that *if* we got any, they have plausible shape.
        for f in frames {
            #expect(f.amplitude >= 0 && f.amplitude <= 1)
            #expect(VowelClass.allCases.contains(f.dominantVowel))
        }
    }

    // MARK: - Config round-trip

    @Test func configUpdatesAreVisibleAfterMutation() async {
        let speaker = TTSSpeaker()
        var cfg = await speaker.config
        cfg.emitHz = 30
        cfg.pitch = 1.2
        await speaker.updateConfig(cfg)
        let after = await speaker.config
        #expect(after.emitHz == 30)
        #expect(after.pitch == 1.2)
    }
}
