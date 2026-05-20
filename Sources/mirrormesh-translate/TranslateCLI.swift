import Foundation
import MirrorMeshCore
import MirrorMeshTranslate

@main
struct TranslateCLI {

    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let from = readFlag(args: args, name: "--from") ?? "en-US"
        let to   = readFlag(args: args, name: "--to") ?? "es-ES"
        let text = readFlag(args: args, name: "--text") ?? "Hello, world."
        let model = readFlag(args: args, name: "--model") ?? "llama3.2:3b"
        let baseURLString = readFlag(args: args, name: "--ollama-url") ?? "http://localhost:11434"
        let amplitudeTrace = readFlag(args: args, name: "--amplitude-trace")
        let dryRun = args.contains("--dry-run")
        let silent = args.contains("--silent")

        guard let baseURL = URL(string: baseURLString) else {
            FileHandle.standardError.write(Data("ERROR: invalid --ollama-url: \(baseURLString)\n".utf8))
            exit(2)
        }

        print("mirrormesh-translate \(MirrorMeshCore.version) (translate \(MirrorMeshTranslate.version))")
        print(MirrorMeshTranslate.localOllamaDisclosure)
        print("from:  \(from)")
        print("to:    \(to)")
        print("model: \(model)")
        print("text:  \"\(text)\"")
        if dryRun {
            print("--dry-run: printing prompt only, no translation performed.")
            let promptPreview = OllamaTranslator.translationPrompt(
                text: text,
                source: Locale(identifier: from),
                target: Locale(identifier: to)
            )
            print("--- prompt ---")
            print(promptPreview)
            print("--- end prompt ---")
            exit(0)
        }

        let config = OllamaConfig(baseURL: baseURL, model: model)
        let translator = OllamaTranslator(config: config)

        // Step 1 — translate.
        let translated: String
        do {
            translated = try await translator.translate(
                text,
                from: Locale(identifier: from),
                to: Locale(identifier: to)
            )
        } catch let err as OllamaTranslatorError {
            FileHandle.standardError.write(Data("ERROR: \(err.description)\n".utf8))
            exit(3)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(4)
        }
        print("translation: \"\(translated)\"")

        if silent {
            print("--silent: skipping TTS + lip-sync stages.")
            exit(0)
        }

        // Step 2 — synthesize + lip-sync. We collect amplitude trace to JSONL if requested.
        let speaker = TTSSpeaker()
        let driver = LipSyncDriver()
        let target = Locale(identifier: to)
        let stream: AsyncStream<TTSFrame>
        do {
            stream = try await speaker.speak(translated, locale: target)
        } catch let err as TTSSpeakerError {
            FileHandle.standardError.write(Data("ERROR: \(err.description)\n".utf8))
            exit(6)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(6)
        }

        var traceHandle: FileHandle? = nil
        if let path = amplitudeTrace {
            FileManager.default.createFile(atPath: path, contents: nil)
            traceHandle = FileHandle(forWritingAtPath: path)
            if traceHandle == nil {
                FileHandle.standardError.write(Data("WARN: could not open --amplitude-trace file at \(path)\n".utf8))
            }
        }

        var frameCount = 0
        for await ttsFrame in stream {
            let overlay = driver.update(ttsFrame)
            frameCount += 1

            if let h = traceHandle {
                let line = formatTraceLine(ttsFrame: ttsFrame, overlay: overlay)
                if let data = (line + "\n").data(using: .utf8) {
                    h.write(data)
                }
            }
        }
        try? traceHandle?.close()
        print("done. frames: \(frameCount)\(amplitudeTrace.map { "  trace: \($0)" } ?? "")")
        exit(0)
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-translate \(MirrorMeshCore.version)
        Usage: mirrormesh-translate --from <locale> --to <locale> --text "<utterance>" [options]

        Demonstrates the v0.8.0 translation + TTS + lip-sync pipeline end-to-end
        without the GUI. Talks to a local Ollama instance — start `ollama serve`
        and `ollama pull llama3.2:3b` (or another multilingual model) first.

        Options:
          --from <locale>          Source language locale (default: en-US)
          --to   <locale>          Target language locale (default: es-ES)
          --text "<utterance>"     Input text (default: "Hello, world.")
          --model <id>             Ollama model id (default: llama3.2:3b)
          --ollama-url <url>       Base URL (default: http://localhost:11434)
          --amplitude-trace <path> Write a JSONL trace of {t,amp,vowel,jaw,pucker,wide}
                                   one record per TTS frame to <path>
          --silent                 Translate but skip TTS / lip-sync
          --dry-run                Print the Ollama prompt and exit (no network call)
          -h, --help               Show this help

        All processing is local: Ollama runs on your machine; TTS runs on-device.
        R3 / R4 compliant: no cloud LLM is contacted.

        """.utf8))
    }

    static func readFlag(args: [String], name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func formatTraceLine(ttsFrame: TTSFrame, overlay: LipSyncCoefficients) -> String {
        let jaw    = overlay.values[.jawOpen] ?? 0
        let pucker = overlay.values[.mouthPucker] ?? 0
        let wide   = overlay.values[.mouthWide] ?? 0
        return String(
            format: "{\"t\":%llu,\"amp\":%.4f,\"vowel\":\"%@\",\"jaw\":%.4f,\"pucker\":%.4f,\"wide\":%.4f}",
            ttsFrame.hostTimeNs,
            ttsFrame.amplitude,
            ttsFrame.dominantVowel.rawValue as NSString,
            jaw,
            pucker,
            wide
        )
    }
}
