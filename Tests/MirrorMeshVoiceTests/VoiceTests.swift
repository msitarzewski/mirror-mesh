import Testing
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import MirrorMeshCore
@testable import MirrorMeshVoice

@Suite("MirrorMeshVoice")
struct VoiceTests {

    @Test func microphoneSourceConstructibleWithoutPermission() async {
        // Construction must never touch the audio hardware or request permission.
        // `start()` is the gate; `init` is pure.
        let mic = MicrophoneSource()
        _ = mic
    }

    @Test func audioChunkReportsDurationFromSamples() {
        let chunk = AudioChunk(samples: Array(repeating: Float(0), count: 16_000),
                               sampleRate: 16_000,
                               startNs: 0)
        #expect(abs(chunk.durationSeconds - 1.0) < 1e-6)
    }

    @Test func transcriptFrameRoundTripsThroughJSON() throws {
        let f = TranscriptFrame(startMs: 100, endMs: 1_100, text: "hello", confidence: 0.87)
        let data = try JSONEncoder().encode(f)
        let decoded = try JSONDecoder().decode(TranscriptFrame.self, from: data)
        #expect(decoded == f)
    }

    @Test func transcriptIsHashable() {
        // Sanity: Transcript participates in Hashable so consumers can dedupe.
        let a = Transcript(startMs: 0, endMs: 1000, text: "hi", confidence: 0.9, isFinal: true)
        let b = Transcript(startMs: 0, endMs: 1000, text: "hi", confidence: 0.9, isFinal: true)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func backendCanonicalTagFoldsLegacyAlias() {
        #expect(WhisperTranscriber.Backend.realWhisperCpp.canonicalTag == "apple-speech")
        #expect(WhisperTranscriber.Backend.appleSpeech.canonicalTag == "apple-speech")
        #expect(WhisperTranscriber.Backend.mock.canonicalTag == "mock")
    }

    @Test func appleSpeechBackendStartThrowsWhenLocaleUnsupported() async {
        // Pick a bogus locale — SFSpeechRecognizer(locale:) will return nil for
        // it on any reasonable system, which we surface as .localeUnsupported.
        do {
            _ = try AppleSpeechBackend(localeIdentifier: "zz-ZZ")
            Issue.record("expected localeUnsupported error")
        } catch let e as SpeechRecognitionError {
            switch e {
            case .localeUnsupported, .onDeviceUnavailable:
                // Either is acceptable — the system may construct a recognizer
                // for the bogus locale but lack on-device support; both paths
                // satisfy the safety invariant (no silent cloud fallback).
                break
            default:
                Issue.record("unexpected error: \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mockSpeechBackendEmitsExpectedTranscripts() async throws {
        let backend = MockSpeechBackend(phrases: ["alpha", "bravo", "charlie"])
        let stream = try await backend.start()
        var collected: [Transcript] = []
        for await t in stream {
            collected.append(t)
        }
        #expect(collected.count == 3)
        #expect(collected.first?.text == "alpha")
        #expect(collected.last?.text == "charlie")
        #expect(collected.last?.isFinal == true)
        #expect(collected.dropLast().allSatisfy { !$0.isFinal })
    }

    @Test func whisperTranscriberRejectsChunkStreamForAppleSpeech() async {
        let transcriber = WhisperTranscriber(backend: .appleSpeech)
        let stream = AsyncStream<AudioChunk> { cont in cont.finish() }
        do {
            try await transcriber.start(stream)
            Issue.record("expected appleSpeechRequiresOwnAudio")
        } catch WhisperTranscriber.WhisperError.appleSpeechRequiresOwnAudio {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func whisperTranscriberMockStreamRunsToCompletion() async throws {
        // Re-enabled in v0.7.0: the earlier race was rooted in the legacy
        // TelemetryBus + detached Task drain. The mock path here uses a
        // bounded stream that yields a single chunk and finishes — the
        // transcriber loop terminates deterministically.
        let transcriber = WhisperTranscriber(backend: .mock)
        let sampleRate = 16_000
        var samples = [Float](repeating: 0, count: sampleRate)
        for i in 0..<sampleRate {
            samples[i] = 0.5 * sinf(2 * .pi * 440.0 * Float(i) / Float(sampleRate))
        }
        let chunk = AudioChunk(samples: samples,
                               sampleRate: sampleRate,
                               startNs: MirrorMeshCore.hostTimeNs())
        let stream = AsyncStream<AudioChunk> { cont in
            cont.yield(chunk)
            cont.finish()
        }
        try await transcriber.start(stream)
        let stats = await transcriber.snapshot()
        #expect(stats.chunksProcessed == 1)
        #expect(stats.transcriptsEmitted >= 1)
    }

    @Test func whisperTranscriberMockClassifiesSilence() async throws {
        let transcriber = WhisperTranscriber(backend: .mock)
        let silence = AudioChunk(samples: Array(repeating: 0, count: 16_000),
                                 sampleRate: 16_000,
                                 startNs: MirrorMeshCore.hostTimeNs())
        let stream = AsyncStream<AudioChunk> { cont in
            cont.yield(silence)
            cont.finish()
        }
        try await transcriber.start(stream)
        let stats = await transcriber.snapshot()
        // Silence still emits a "[silence]" transcript — assertion is just that
        // the path didn't drop the chunk.
        #expect(stats.chunksProcessed == 1)
        #expect(stats.transcriptsEmitted == 1)
    }
}

/// Apple Speech integration tests. These touch the real Speech framework and
/// therefore require:
///   - Speech recognition entitlement / Info.plist key in the test host
///   - User authorization (interactive) the first time
///   - An on-device language model installed for `en-US`
///
/// In CI without those prerequisites the tests are marked `.disabled` with a
/// note explaining how to enable them locally. Run with:
///
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter AppleSpeechIntegrationTests
///
/// after granting Speech permission to the test host (Settings → Privacy &
/// Security → Speech Recognition).
@Suite("AppleSpeechIntegration")
struct AppleSpeechIntegrationTests {

    @Test(.disabled("Requires Speech permission + on-device en-US model on the test host"))
    func transcribeSynthesizedPhraseFromFile() async throws {
        #if canImport(AVFoundation)
        // Synthesize a short phrase to a temp .caf via AVSpeechSynthesizer →
        // AVAudioFile, then feed it through AppleSpeechBackend in file mode.
        let phrase = "the quick brown fox jumps over the lazy dog"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm_voice_fixture_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try await SynthesizeFixture.write(phrase: phrase, to: tmpURL)

        let backend = try AppleSpeechBackend(localeIdentifier: "en-US")
        let stream = try await backend.start(fileURL: tmpURL)
        var collected: [Transcript] = []
        for await t in stream {
            collected.append(t)
        }
        #expect(!collected.isEmpty, "expected at least one transcript")
        let finalText = collected.last(where: { $0.isFinal })?.text.lowercased() ?? ""
        // The recognizer's output rarely matches a literal phrase exactly;
        // assert against a couple of stable tokens.
        #expect(finalText.contains("fox") || finalText.contains("dog") || finalText.contains("quick"),
                "final transcript should contain a stable token: '\(finalText)'")
        #endif
    }
}

/// Test-fixture helper. Writes a synthesized utterance to a file using
/// AVSpeechSynthesizer + AVAudioFile (no third-party dependencies).
enum SynthesizeFixture {
    #if canImport(AVFoundation)
    static func write(phrase: String, to url: URL) async throws {
        // AVSpeechSynthesizer.write(_:toBufferCallback:) is the documented
        // path for producing PCM buffers from synthesis. We collect those
        // buffers into an AVAudioFile.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let synth = AVSpeechSynthesizer()
                let utterance = AVSpeechUtterance(string: phrase)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate

                var audioFile: AVAudioFile?
                var writeError: Error?

                synth.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        // End-of-stream sentinel — AVSpeechSynthesizer signals
                        // completion with a zero-length buffer.
                        if let af = audioFile {
                            _ = af
                            cont.resume(returning: ())
                        } else if let writeError {
                            cont.resume(throwing: writeError)
                        } else {
                            cont.resume(throwing: NSError(
                                domain: "SynthesizeFixture", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "no audio produced"]))
                        }
                        return
                    }
                    if audioFile == nil {
                        do {
                            audioFile = try AVAudioFile(forWriting: url,
                                                       settings: pcm.format.settings,
                                                       commonFormat: pcm.format.commonFormat,
                                                       interleaved: pcm.format.isInterleaved)
                        } catch {
                            writeError = error
                            return
                        }
                    }
                    do {
                        try audioFile?.write(from: pcm)
                    } catch {
                        writeError = error
                    }
                }
            }
        }
    }
    #endif
}
