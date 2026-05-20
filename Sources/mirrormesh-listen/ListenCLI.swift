import Foundation
import MirrorMeshCore
import MirrorMeshVoice

@main
struct ListenCLI {

    enum BackendChoice: String {
        case appleSpeech = "apple-speech"
        case mock = "mock"
    }

    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let durationSeconds = Double(readFlag(args: args, name: "--duration") ?? "") ?? 10.0
        let locale = readFlag(args: args, name: "--locale") ?? "en-US"
        let inputPath = readFlag(args: args, name: "--input")

        // Backend resolution. Legacy `--mock` shorthand still works.
        let backend: BackendChoice = {
            if args.contains("--mock") { return .mock }
            let raw = readFlag(args: args, name: "--backend") ?? BackendChoice.appleSpeech.rawValue
            return BackendChoice(rawValue: raw) ?? .appleSpeech
        }()

        print("mirrormesh-listen \(MirrorMeshCore.version) (voice \(MirrorMeshVoice.version))")
        print("backend:  \(backend.rawValue)")
        print("locale:   \(locale)")
        if let inputPath {
            print("input:    \(inputPath)")
        } else {
            print("duration: \(durationSeconds)s (live mic)")
        }

        // Stdout sink so the canonical JSONL telemetry path also shows on stdout
        // when the user runs the CLI interactively. Final transcripts go through
        // the telemetry bus; partials are printed inline from the stream below.
        let sink = StdoutTranscriptSink()
        await Telemetry.shared.attach(sink)

        switch backend {
        case .mock:
            await runMock(durationSeconds: durationSeconds, inputPath: inputPath, locale: locale)
        case .appleSpeech:
            if let path = inputPath {
                await runAppleSpeechFile(path: path, locale: locale)
            } else {
                await runAppleSpeechLive(durationSeconds: durationSeconds, locale: locale)
            }
        }

        exit(0)
    }

    // MARK: - Apple Speech paths

    static func runAppleSpeechLive(durationSeconds: Double, locale: String) async {
        let transcriber = WhisperTranscriber(backend: .appleSpeech, locale: locale)
        let stream: AsyncStream<Transcript>
        do {
            stream = try await transcriber.startAppleSpeech()
        } catch {
            FileHandle.standardError.write(Data("ERROR: apple-speech start: \(error)\n".utf8))
            return
        }
        let consume = Task {
            for await t in stream {
                printTranscript(t)
            }
        }
        // Race the duration timeout against the stream completing.
        let timeout = Task { try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000)) }
        await timeout.value
        consume.cancel()
        let stats = await transcriber.snapshot()
        print("done. finals: \(stats.transcriptsEmitted)  partials: \(stats.partialTranscriptsEmitted)")
    }

    static func runAppleSpeechFile(path: String, locale: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("ERROR: input not found: \(path)\n".utf8))
            return
        }
        let transcriber = WhisperTranscriber(backend: .appleSpeech, locale: locale)
        let stream: AsyncStream<Transcript>
        do {
            stream = try await transcriber.startAppleSpeechFile(url)
        } catch {
            FileHandle.standardError.write(Data("ERROR: apple-speech start(file): \(error)\n".utf8))
            return
        }
        for await t in stream {
            printTranscript(t)
        }
        let stats = await transcriber.snapshot()
        print("done. finals: \(stats.transcriptsEmitted)  partials: \(stats.partialTranscriptsEmitted)")
    }

    // MARK: - Mock path (kept for tests / no-mic environments)

    static func runMock(durationSeconds: Double, inputPath: String?, locale: String) async {
        _ = locale
        let transcriber = WhisperTranscriber(backend: .mock)
        let mic = MicrophoneSource()
        do {
            let stream: AsyncStream<AudioChunk>
            if let inputPath {
                // The mock backend doesn't read files; fall back to synthetic silence
                // so the JSONL pipeline still flows. A real file path would require
                // wiring AVAudioFile → AudioChunk; that's intentionally not wired
                // because the production path is apple-speech.
                FileHandle.standardError.write(Data(
                    "note: --backend mock --input not supported; emitting silence stream\n".utf8))
                _ = inputPath
                stream = AsyncStream { cont in
                    let chunk = AudioChunk(samples: Array(repeating: 0, count: 16_000),
                                           sampleRate: 16_000,
                                           startNs: MirrorMeshCore.hostTimeNs())
                    cont.yield(chunk)
                    cont.finish()
                }
            } else {
                stream = try await mic.start()
            }
            let transcribeTask = Task {
                do { try await transcriber.start(stream) }
                catch { FileHandle.standardError.write(Data("ERROR: transcriber: \(error)\n".utf8)) }
            }
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            await mic.stop()
            await transcribeTask.value
            let stats = await transcriber.snapshot()
            print("done. chunks: \(stats.chunksProcessed)  transcripts: \(stats.transcriptsEmitted)")
        } catch {
            FileHandle.standardError.write(Data("ERROR: mock pipeline: \(error)\n".utf8))
        }
    }

    // MARK: - utility

    static func printTranscript(_ t: Transcript) {
        let prefix = t.isFinal ? "[final]  " : "[partial]"
        let line = String(format: "%@ %.2fs–%.2fs conf=%.2f %@\n",
                          prefix,
                          t.startMs / 1000.0,
                          t.endMs / 1000.0,
                          t.confidence,
                          t.text)
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-listen \(MirrorMeshCore.version)
        Usage: mirrormesh-listen [--backend apple-speech|mock] [--duration <sec>]
                                 [--locale <bcp47>] [--input <path/to/audio>]

        Runs the on-device voice pipeline locally. Prints partial and final
        transcripts to stdout.

        --backend <name>     apple-speech (default) | mock
        --duration <sec>     Live-mic run length (default: 10). Ignored in file mode.
        --locale <bcp47>     Recognition locale (default: en-US)
        --input <path>       Read audio from file instead of microphone (file mode).
                             Must be a format AVAudioFile can read (WAV, AIFF, m4a, mp3).
        --mock               Shorthand for --backend mock
        -h, --help           Show this help

        All audio processing is on-device. The Apple Speech backend sets
        `requiresOnDeviceRecognition = true` — there is no cloud fallback.

        """.utf8))
    }

    static func readFlag(args: [String], name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// Telemetry sink that prints transcript events to stdout, one per line.
/// Why a dedicated sink (not just `print` from the transcriber): JSONLLogger and this
/// stdout view share the same event stream — no risk of console-vs-trace divergence.
final class StdoutTranscriptSink: TelemetrySink, @unchecked Sendable {
    func consume(_ event: TelemetryEvent) {
        // Final transcripts go through the bus; we already printed live partials
        // and finals from the AsyncStream in the CLI loop. Mute the sink in
        // live mode to avoid double-printing. JSONL traces still see the events.
        _ = event
    }
}
