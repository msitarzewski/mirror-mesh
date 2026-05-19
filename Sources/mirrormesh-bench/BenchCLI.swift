import Foundation
import MirrorMeshCore
import MirrorMeshOutput
import MirrorMeshVision
import MirrorMeshMediaPipe

struct Scenario: Decodable {
    var name: String
    var mode: String                   // "synthetic" | "live" | "file"
    var width: Int
    var height: Int
    var fps: Int
    var frames: Int
    var show_landmarks: Bool?
    var show_avatar_mask: Bool?
    var record: Bool?
    var solver: String?                // "geometric" | "coreml"; default geometric
    var file: String?                  // path to source video when mode == "file"
    var landmark: String?              // "vision" | "mediapipe"; default vision (or synthetic when mode==synthetic)
    var log_coefficients: Bool?        // per-frame coefficient logging (bench / solver-comparison only)
}

@main
struct BenchCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard let scenarioFlag = args.firstIndex(of: "--scenario"),
              scenarioFlag + 1 < args.count else {
            printUsage()
            exit(2)
        }
        let scenarioPath = args[scenarioFlag + 1]
        let outDir = args.firstIndex(of: "--out")
            .flatMap { i -> String? in i + 1 < args.count ? args[i + 1] : nil }
            ?? "bench/out"

        // Load scenario
        let scenario: Scenario
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: scenarioPath))
            scenario = try JSONDecoder().decode(Scenario.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("ERROR: cannot load scenario \(scenarioPath): \(error)\n".utf8))
            exit(3)
        }

        // Output URLs
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let outDirURL = URL(fileURLWithPath: outDir)
        let jsonlURL = outDirURL.appendingPathComponent("\(scenario.name)_\(stamp).jsonl")
        let manifestURL = outDirURL.appendingPathComponent("\(scenario.name)_\(stamp).manifest.json")
        // Recorder lands next to the manifest with the same base name.
        let recorderURL: URL? = (scenario.record ?? false)
            ? outDirURL.appendingPathComponent("\(scenario.name)_\(stamp).mov")
            : nil

        // Run pipeline
        let mode: PipelineMode = {
            switch scenario.mode {
            case "live":     return .live
            case "file":
                guard let f = scenario.file else {
                    FileHandle.standardError.write(Data(
                        "ERROR: mode=file requires \"file\" field in scenario\n".utf8))
                    exit(3)
                }
                return .file(URL(fileURLWithPath: f))
            default:         return .synthetic
            }
        }()
        let solverKind: PipelineOptions.SolverKind = {
            switch (scenario.solver ?? "geometric").lowercased() {
            case "coreml":    return .coreml
            case "geometric": return .geometric
            default:
                FileHandle.standardError.write(Data(
                    "WARN: unknown solver '\(scenario.solver ?? "")'; using geometric\n".utf8))
                return .geometric
            }
        }()
        // Landmark backend selection: optional override; defaults to Vision (or synthetic in
        // synthetic mode) when omitted. The "mediapipe" option resolves to MediaPipeLandmarkBackend
        // (Vision-fallback stub today; see docs/landmark-comparison.md).
        let landmarkSelection = (scenario.landmark ?? "").lowercased()
        let landmarkBackend: (any LandmarkBackend)?
        let landmarkTag: String?
        switch landmarkSelection {
        case "mediapipe":
            landmarkBackend = MediaPipeLandmarkBackend()
            landmarkTag = MirrorMeshMediaPipe.manifestBackendTag
        case "vision":
            landmarkBackend = VisionLandmarkBackend()
            landmarkTag = "vision"
        case "", "synthetic":
            landmarkBackend = nil
            landmarkTag = nil
        default:
            FileHandle.standardError.write(Data(
                "WARN: unknown landmark '\(landmarkSelection)'; using default for mode\n".utf8))
            landmarkBackend = nil
            landmarkTag = nil
        }

        let opts = PipelineOptions(
            mode: mode,
            captureWidth: scenario.width,
            captureHeight: scenario.height,
            fps: scenario.fps,
            maxFrames: scenario.frames,
            rendererOptions: .init(
                showLandmarks: scenario.show_landmarks ?? true,
                showAvatarMask: scenario.show_avatar_mask ?? true
            ),
            recorderURL: recorderURL,
            solverKind: solverKind,
            landmarkBackend: landmarkBackend,
            landmarkBackendTag: landmarkTag,
            logCoefficients: scenario.log_coefficients ?? false
        )
        let pipeline = Pipeline(options: opts, manifestURL: manifestURL, jsonlURL: jsonlURL)

        print("mirrormesh-bench \(MirrorMeshCore.version)")
        print("scenario:     \(scenario.name)")
        print("mode:         \(scenario.mode)")
        print("solver:       \(solverKind.rawValue)")
        let defaultTag: String = {
            if case .synthetic = mode { return "synthetic" } else { return "vision" }
        }()
        print("landmark:     \(landmarkTag ?? defaultTag)")
        print("resolution:   \(scenario.width)x\(scenario.height)@\(scenario.fps)")
        print("frames:       \(scenario.frames)")
        print("jsonl:        \(jsonlURL.path)")
        print("manifest:     \(manifestURL.path)")
        if let recURL = recorderURL { print("recording:    \(recURL.path)") }
        print("running...")

        do {
            let result = try await pipeline.run()
            print("")
            print("done. \(result.framesProcessed) frames processed")
            print(String(format: "e2e latency  P50: %.2f ms   P95: %.2f ms   P99: %.2f ms",
                          result.endToEndP50Ms, result.endToEndP95Ms, result.endToEndP99Ms))
            print("manifest:     \(result.manifestURL.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: pipeline failed: \(error)\n".utf8))
            exit(4)
        }
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-bench \(MirrorMeshCore.version)
        Usage: mirrormesh-bench --scenario <path-to-scenario.json> [--out <dir>]

        Runs the MirrorMesh pipeline against a scenario file and writes JSONL telemetry
        plus a signed session manifest into the output directory (default bench/out).

        """.utf8))
    }
}
