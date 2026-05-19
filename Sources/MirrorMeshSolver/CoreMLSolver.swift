import Foundation
import CoreML
import MirrorMeshCore

/// CoreML-backed alternative to `GeometricSolver`. Maps a 76-point landmark vector (152 floats)
/// to a 52-element coefficient vector, then projects it positionally onto `BlendshapeKey.allCases`
/// sorted by rawValue.
///
/// The bundled model `blendshape_solver_v1.mlpackage` is trained by `models/training/blendshape_solver.py`
/// on synthetic geometric-rule data (see provenance sidecar). If the model is absent the solver
/// transparently falls back to `GeometricSolver` and emits a single `.warning` telemetry event.
/// This keeps `--solver coreml` runnable in development environments where the weights have not
/// yet been generated.
///
/// Telemetry: emits `.stageStart` / `.stageEnd` for `StageID.solver` around every `solve(_:)`.
public final class CoreMLSolver: ExpressionSolver, @unchecked Sendable {
    /// Canonical, deterministic mapping from model output index → `BlendshapeKey`. Sorted by
    /// rawValue so it matches the training script's identical sort.
    public static let outputKeyOrder: [BlendshapeKey] = BlendshapeKey.allCases
        .sorted { $0.rawValue < $1.rawValue }

    /// File name (without extension) the solver searches for.
    public static let modelResourceName = "blendshape_solver_v1"

    private let model: MLModel?
    private let fallback: GeometricSolver
    private var smoother: BlendshapeSmoother
    private let inputFeatureName: String
    private let outputFeatureName: String

    public init(searchPaths: [URL] = CoreMLSolver.defaultSearchPaths(),
                smoothingAlpha: Float = 0.5) {
        self.fallback = GeometricSolver(smoothingAlpha: smoothingAlpha)
        self.smoother = BlendshapeSmoother(alpha: smoothingAlpha)

        var loaded: MLModel? = nil
        var inName = "landmarks"
        var outName = "coefficients"
        for url in searchPaths {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // .mlpackage / .mlmodel require a compile pass before MLModel can read them;
            // only .mlmodelc loads directly. Cache the compiled result so the cost is paid once.
            let compiled = Self.ensureCompiled(url: url)
            guard let target = compiled,
                  let m = try? MLModel(contentsOf: target) else { continue }
            loaded = m
            if let firstIn = m.modelDescription.inputDescriptionsByName.keys.first {
                inName = firstIn
            }
            if let firstOut = m.modelDescription.outputDescriptionsByName.keys.first {
                outName = firstOut
            }
            break
        }
        self.model = loaded
        self.inputFeatureName = inName
        self.outputFeatureName = outName

        if loaded == nil {
            TelemetryBus.emit(.warning(
                stage: .solver,
                message: "CoreML model not found; falling back to geometric"
            ))
        } else {
            TelemetryBus.emit(.annotation(key: "solver.coreml.model", value: Self.modelResourceName))
        }
    }

    /// Standard search paths consulted in priority order:
    /// 1. `MIRRORMESH_COREML_MODEL` env var (developer override)
    /// 2. `Bundle.module` — the .mlpackage is shipped as a Swift package resource (see Package.swift)
    /// 3. Current working directory's `models/` folder (where `mirrormesh-bench` is run from)
    public static func defaultSearchPaths() -> [URL] {
        var urls: [URL] = []
        if let envPath = ProcessInfo.processInfo.environment["MIRRORMESH_COREML_MODEL"] {
            urls.append(URL(fileURLWithPath: envPath))
        }
        // Why: Bundle.module is populated when the package declares the .mlpackage as a resource;
        // this is the path used by the .app bundle and any consumer that links MirrorMeshSolver.
        #if SWIFT_PACKAGE
        for ext in ["mlpackage", "mlmodelc", "mlmodel"] {
            if let u = Bundle.module.url(forResource: modelResourceName, withExtension: ext) {
                urls.append(u)
            }
        }
        #endif
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("models/\(modelResourceName).mlpackage"))
        urls.append(cwd.appendingPathComponent("models/\(modelResourceName).mlmodelc"))
        urls.append(cwd.appendingPathComponent("models/\(modelResourceName).mlmodel"))
        return urls
    }

    /// Return a URL that MLModel can load directly. For an `.mlmodelc` that's the input URL;
    /// for `.mlpackage` / `.mlmodel` we compile once and cache the result under a stable per-source
    /// directory in the user's caches folder so the cost is paid at most once per machine.
    private static func ensureCompiled(url: URL) -> URL? {
        if url.pathExtension == "mlmodelc" { return url }
        // Why cache by source path: avoid repeated multi-second compiles in `swift run` flows.
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MirrorMesh/CoreMLCache", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-coreml")
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let stamp = "\(url.path.hashValue)"
        let cached = cacheRoot
            .appendingPathComponent(modelResourceName + "-" + stamp, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + "c", isDirectory: true)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        do {
            let tmp = try MLModel.compileModel(at: url)
            try? FileManager.default.createDirectory(
                at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: tmp, to: cached)
            return cached
        } catch {
            return nil
        }
    }

    public var isUsingFallback: Bool { model == nil }

    public func solve(_ landmarks: LandmarkFrame) -> BlendshapeFrame {
        let start = MirrorMeshCore.hostTimeNs()
        TelemetryBus.emit(.stageStart(stage: .solver, frame: landmarks.frameID, hostTimeNs: start))
        defer {
            let end = MirrorMeshCore.hostTimeNs()
            TelemetryBus.emit(.stageEnd(stage: .solver, frame: landmarks.frameID, hostTimeNs: end))
        }

        guard let model = model else {
            return fallback.solve(landmarks)
        }

        // Sanity-check landmark count; the model was trained on exactly 76 points (152 floats).
        guard landmarks.points.count == 76 else {
            return fallback.solve(landmarks)
        }

        do {
            let mlarray = try MLMultiArray(shape: [1, 152], dataType: .float32)
            for i in 0..<76 {
                mlarray[i * 2] = NSNumber(value: landmarks.points[i].x)
                mlarray[i * 2 + 1] = NSNumber(value: landmarks.points[i].y)
            }
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputFeatureName: MLFeatureValue(multiArray: mlarray)]
            )
            let prediction = try model.prediction(from: input)
            guard let outArray = prediction.featureValue(for: outputFeatureName)?.multiArrayValue else {
                return fallback.solve(landmarks)
            }

            var raw: [BlendshapeKey: Float] = [:]
            raw.reserveCapacity(Self.outputKeyOrder.count)
            let n = min(Self.outputKeyOrder.count, outArray.count)
            for i in 0..<n {
                raw[Self.outputKeyOrder[i]] = clampUnit(outArray[i].floatValue)
            }
            // Backfill any missing keys with zero so downstream sees the full 52-key schema.
            for k in BlendshapeKey.allCases where raw[k] == nil { raw[k] = 0 }

            let smoothed = smoother.smooth(raw)
            var clamped: [BlendshapeKey: Float] = [:]
            clamped.reserveCapacity(smoothed.count)
            for (k, v) in smoothed { clamped[k] = clampUnit(v) }

            return BlendshapeFrame(
                frameID: landmarks.frameID,
                hostTimeNs: landmarks.hostTimeNs,
                coefficients: clamped
            )
        } catch {
            TelemetryBus.emit(.warning(
                stage: .solver,
                message: "CoreML prediction failed (\(error)); falling back to geometric for this frame"
            ))
            return fallback.solve(landmarks)
        }
    }

    @inline(__always)
    private func clampUnit(_ value: Float) -> Float {
        if value.isNaN { return 0 }
        return max(0, min(1, value))
    }
}
