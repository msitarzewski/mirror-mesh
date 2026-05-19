import Foundation
import MirrorMeshCore
import MirrorMeshVoice

@main
struct ListenCLI {

    static let defaultModelDir = "Library/Application Support/MirrorMesh"
    static let defaultModelName = "whisper-tiny.en.bin"
    static let modelDownloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
    // Why hard-coded: ggerganov's tiny.en weights are an immutable release artifact;
    // the sha256 changes only when upstream re-publishes (which would also change the URL).
    static let modelSha256 = "bd577a113a864445d4c299885e0cb97d4ba92b5f"  // see provenance sidecar

    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let modelPath = readFlag(args: args, name: "--model") ?? defaultModelPath()
        let durationSeconds = Double(readFlag(args: args, name: "--duration") ?? "") ?? 10.0
        let backend: WhisperTranscriber.Backend = args.contains("--mock") ? .mock : .realWhisperCpp
        let allowDownload = !args.contains("--no-download")

        print("mirrormesh-listen \(MirrorMeshCore.version) (voice \(MirrorMeshVoice.version))")
        print("model:    \(modelPath)")
        print("backend:  \(backend.rawValue)")
        print("duration: \(durationSeconds)s")

        if backend == .realWhisperCpp {
            await ensureModelPresent(at: modelPath, allowDownload: allowDownload)
            print("note: real whisper.cpp backend is not yet linked in this build.")
            print("      falling back to deterministic mock transcripts.")
            print("      see docs/voice-pipeline.md for status.")
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let transcriber = WhisperTranscriber(modelURL: modelURL, backend: backend)

        // Attach a stdout sink for transcript events.
        let sink = StdoutTranscriptSink()
        await Telemetry.shared.attach(sink)

        let mic = MicrophoneSource()
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await mic.start()
        } catch {
            FileHandle.standardError.write(Data("ERROR: microphone unavailable: \(error)\n".utf8))
            exit(5)
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
        exit(0)
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-listen \(MirrorMeshCore.version)
        Usage: mirrormesh-listen [--model <path>] [--duration <seconds>] [--mock] [--no-download]

        Runs the microphone + Whisper voice path locally. Prints transcripts to stdout.

        --model <path>     Whisper model file (default: ~/\(defaultModelDir)/\(defaultModelName))
        --duration <sec>   Run length in seconds (default: 10)
        --mock             Force the mock backend even when a model is present
        --no-download      Don't prompt to fetch the model if missing
        -h, --help         Show this help

        All audio processing is local. No data leaves the machine.

        """.utf8))
    }

    static func defaultModelPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(defaultModelDir)
                   .appendingPathComponent(defaultModelName)
                   .path
    }

    static func readFlag(args: [String], name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Best-effort: if the model file is missing, point the user at the download URL.
    /// We deliberately do NOT auto-download in this build — the real whisper.cpp link
    /// step that consumes the file isn't shipped yet, and downloading 40 MB just to
    /// have it sit on disk is a waste. When v0.3.x lands the real backend, this
    /// becomes an actual `URLSession` fetch + sha256 verify.
    static func ensureModelPresent(at path: String, allowDownload: Bool) async {
        if FileManager.default.fileExists(atPath: path) { return }
        FileHandle.standardError.write(Data("""
        warning: model not found at \(path)
                 download manually from:
                   \(modelDownloadURL)
                 expected sha256 prefix: \(modelSha256)…
                 see models/whisper-tiny.en.provenance.json

        """.utf8))
        _ = allowDownload  // reserved for future auto-fetch path
    }
}

/// Telemetry sink that prints transcript events to stdout, one per line.
/// Why a dedicated sink (not just `print` from the transcriber): JSONLLogger and this
/// stdout view share the same event stream — no risk of console-vs-trace divergence.
final class StdoutTranscriptSink: TelemetrySink, @unchecked Sendable {
    func consume(_ event: TelemetryEvent) {
        guard case let .transcript(tf) = event else { return }
        let line = String(format: "[%.2fs – %.2fs  conf=%.2f] %@\n",
                          tf.startMs / 1000.0, tf.endMs / 1000.0, tf.confidence, tf.text)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
