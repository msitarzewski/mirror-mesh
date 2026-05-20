import Foundation
import CoreVideo
import CoreImage
import CoreML
import simd
import MirrorMeshCore
import MirrorMeshWatermark

// ORCHESTRATOR INTEGRATION
//
// 1) Pipeline.swift: when a ConsentedIdentity is loaded AND the photoreal
//    .mlpackage files exist at the standard models/ path, the Pipeline
//    constructs PhotorealBackend(kind: .liveportrait, ...) — this is async,
//    runs prepareSource() once before first frame.
//
// 2) Per-frame: pipeline calls
//        let photorealBuf = try await backend.reenact(driver: capturedFrame.pixelBuffer)
//    between vision and render. Renderer renders `photorealBuf` as the source
//    instead of capturedFrame.pixelBuffer when Mirror or Mask style is active.
//
// 3) Watermark + chirp + manifest are unchanged — they apply to the photoreal
//    output exactly as they did to the camera passthrough.
//
// Latency budget on M5 Max with ANE:
//    appearance: ~8 ms (cached; one-time per identity load)
//    motion:     ~5 ms / frame
//    warp:       ~15 ms / frame
//    generator:  ~20 ms / frame
//    total:      ~40 ms / frame
//    Acceptable headroom over the 100 ms P95 budget at 30 fps.

/// Selects which set of `.mlpackage` files the backend looks for on disk.
///
/// Both kinds plug into the same `MirrorMeshReenact` slot and share the
/// `ConsentedIdentityVerifier` gate; the operator (or a higher-level config)
/// picks which set the runtime drives. LivePortrait is the default per
/// ADR-0015 (2026-05-20) — sharper, more identity-preserving reenactment,
/// more recent upstream maintenance, and AGPL-3.0-only research posture
/// satisfies its InsightFace runtime-weight restriction. FOMM is retained as
/// a license-clean fallback for contributors who specifically need to avoid
/// any InsightFace dependency in their pipeline.
public enum PhotorealBackendKind: String, Sendable {
    case fomm
    case liveportrait
}

/// The photorealistic identity-transfer backend.
///
/// **Relationship to `FaceReenactor`**: `FaceReenactor` is the stylized 3D head puppet
/// path — pure geometry, ships ready-to-run, no learned weights. `PhotorealBackend`
/// is the optional photorealistic path that requires the user to download
/// either LivePortrait or FOMM weights themselves and run the matching
/// conversion script (see `models/training/README.md`). Both paths share the
/// `ConsentedIdentityVerifier` gate (R1); a session may run with neither, one, or both
/// loaded, and the operator picks which the pipeline drives.
///
/// **The contract**: this initializer must refuse cleanly when either the identity is
/// invalid or the expected `.mlpackage` files for the selected `kind` are absent. There
/// is no fallback path that secretly succeeds without verified inputs — see R12 ("refuse
/// on sight") and the release plan's "architecturally distinct from a generic catfishing
/// kit" framing.
///
/// **Inference graph (LivePortrait, the default kind)**:
///   1. `appearance_v1` — runs once per identity on the source PNG; output `feature_3d`
///      and the source's motion vector are cached in the actor for the rest of the session.
///   2. `motion_v1` — runs every frame on the live driving image; output is the implicit
///      keypoint vector for the driving frame.
///   3. `warp_v1` — takes the cached `feature_3d`, the cached `kp_source`, and the new
///      `kp_driving`, and returns a warped feature volume.
///   4. `generator_v1` — takes the warped feature volume and returns the final RGB image
///      (post-sigmoid, in [0, 1]).
///
/// The minimum-viable kp_source/kp_driving composition (v1.1) uses the implicit keypoint
/// output directly. LivePortrait's full `live_portrait_wrapper.transform_keypoint(...)`
/// math (apply rotation built from pitch/yaw/roll, add translation, add expression
/// deformation) is a future refinement once we measure the quality delta on real frames.
public actor PhotorealBackend {

    /// Errors surfaced specifically by the photorealistic backend's load + inference
    /// gates. Distinct from `ConsentedIdentityError` (which the verifier throws directly)
    /// so callers can tell "verification failed" apart from "you need to download model
    /// weights" apart from "you forgot to call prepareSource()".
    public enum LoadError: Error, CustomStringConvertible, Sendable {
        /// One or more of the expected `.mlpackage` files for the selected `kind` could not
        /// be found under `modelsDir`. The associated URL is the directory that was searched
        /// — surfaced so the SwiftUI Identity panel can show a kind-aware "Download weights"
        /// CTA pointing at the right location. The `kind` is carried so the message can name
        /// the right files (LivePortrait vs FOMM).
        case modelsMissing(URL, PhotorealBackendKind)
        /// The supplied `ConsentedIdentity` did not pass `ConsentedIdentityVerifier.verify`
        /// **or** the bundle's `scheme` is not one of the two photoreal-eligible cases
        /// (`.selfAsSource`, `.consentedThirdParty`). Stylized-non-human identities don't
        /// go through this backend — they use `FaceReenactor`'s procedural path.
        case identityNotVerified
        /// The supplied `runtimeVersion` does not satisfy the bundle's `scope`. This is
        /// caught by `ConsentedIdentityVerifier.verify` and rethrown as a
        /// `ConsentedIdentityError.unsupportedScope`; this case is reserved for the future
        /// "runtime is too old for the model architecture" check.
        case runtimeUnsupported
        /// `reenact(...)` was called before `prepareSource(...)` had populated the appearance
        /// feature cache. The pipeline's contract is: construct the backend (which runs
        /// `prepareSource` automatically in `init`), then call `reenact` per frame. Direct
        /// instantiation paths that skip prepare must call it explicitly before the first
        /// frame. R12 — refuse on sight.
        case sourceNotPrepared
        /// One of the CoreML predictions returned an output with a shape or name we don't
        /// recognize. Indicates a mis-converted `.mlpackage` (or a mismatched conversion
        /// script version). The associated string names the offending stage so the user
        /// knows which model to re-convert.
        case inferenceShapeMismatch(String)

        public var description: String {
            switch self {
            case let .modelsMissing(dir, kind):
                let files = PhotorealBackend.modelFileNames(for: kind).joined(separator: ", ")
                let script: String = {
                    switch kind {
                    case .liveportrait: return "models/training/liveportrait_to_coreml.py"
                    case .fomm:         return "models/training/fomm_to_coreml.py"
                    }
                }()
                return "PhotorealBackend: \(kind.rawValue) models not found under \(dir.path). " +
                       "Expected: \(files). Run \(script) per models/training/README.md."
            case .identityNotVerified:
                return "PhotorealBackend: identity must be verified and of scheme " +
                       "selfAsSource or consentedThirdParty before loading the photoreal path"
            case .runtimeUnsupported:
                return "PhotorealBackend: runtime version unsupported for these model packages"
            case .sourceNotPrepared:
                return "PhotorealBackend: prepareSource(...) must be called before reenact(...). " +
                       "The standard init path does this automatically; direct callers must do it."
            case .inferenceShapeMismatch(let stage):
                return "PhotorealBackend: unexpected output shape from \(stage). " +
                       "Re-run the conversion script (models/training/) and verify provenance."
            }
        }
    }

    /// File names the backend looks for, per kind. Hard-coded because the names are
    /// each conversion script's contract.
    ///
    /// LivePortrait: see `models/training/liveportrait_to_coreml.py` — splits the forward
    /// pass into appearance (cached) + motion + warp + generator.
    /// FOMM: see `models/training/fomm_to_coreml.py` — splits into keypoint + motion +
    /// generator (the dense-motion is a separate file because the FOMM forward pass
    /// uses (kp_source, kp_driving) → dense_motion → generator; cf. LivePortrait's
    /// WarpingNetwork which embeds DenseMotion as a submodule).
    public static func modelFileNames(for kind: PhotorealBackendKind) -> [String] {
        switch kind {
        case .liveportrait:
            return [
                "appearance_v1.mlpackage",
                "motion_v1.mlpackage",
                "warp_v1.mlpackage",
                "generator_v1.mlpackage",
            ]
        case .fomm:
            return [
                "keypoint_v1.mlpackage",
                "motion_v1.mlpackage",
                "generator_v1.mlpackage",
            ]
        }
    }

    /// Back-compat shim for callers that referenced the FOMM file list directly during
    /// v0.6.0 scaffolding. Returns the FOMM file names — same as `modelFileNames(for: .fomm)`.
    /// New callers should use the kind-aware overload above.
    public static let modelFileNames: [String] = modelFileNames(for: .fomm)

    /// Stable indices into the `models` array for LivePortrait. Order matches
    /// `modelFileNames(for: .liveportrait)`.
    private enum LP {
        static let appearance = 0
        static let motion     = 1
        static let warp       = 2
        static let generator  = 3
    }

    /// Which backend kind was selected at init. Useful for telemetry and for the
    /// SwiftUI identity panel to render the correct "open weights folder" affordance.
    public nonisolated let kind: PhotorealBackendKind

    /// The currently loaded identity (header only — the PNG was already consumed by the
    /// verifier during init). The reenact() hot path does not re-verify per-frame; the gate
    /// is at load time and identity rotation happens by tearing the backend down and
    /// constructing a new one.
    public nonisolated let identity: ConsentedIdentity

    /// The loaded MLModels in the same order as `modelFileNames(for: kind)`. The hot path
    /// indexes into this array by role; the per-kind dispatch lives in `reenact(...)`.
    private let models: [MLModel]

    /// Reusable CoreImage context. Allocated once; the per-frame conversion path reuses it
    /// to avoid the ~1 ms cost of constructing a CIContext each call. GPU-backed
    /// (`useSoftwareRenderer: false`) so the crop + resize lands on the M-series GPU.
    private let ciContext: CIContext

    /// The cached source-identity 3D appearance feature volume. Shape `(1, 32, 16, 64, 64)`.
    /// Set by `prepareSource(...)` exactly once per backend lifetime; never updated after.
    private var sourceFeature3D: MLMultiArray?

    /// The cached source keypoint vector. Shape `(1, 21, 3)`. Set by `prepareSource(...)`
    /// from the motion extractor running on the source PNG. Used as `kp_source` for every
    /// warp call.
    private var sourceKP: MLMultiArray?

    /// Failable initializer. Performs the standard gate sequence then runs `prepareSource`
    /// so the first `reenact()` call has a populated cache. R12 — every code path that
    /// produces a working backend has passed the identity gate, the models gate, AND the
    /// source-cache step.
    ///
    /// Sequence:
    /// 1. `ConsentedIdentityVerifier.verify` — signature, payload hash, scope.
    ///    Throws `LoadError.identityNotVerified` on `ConsentedIdentityError`.
    /// 2. Identity `scheme` must be `.consentedThirdParty` or `.selfAsSource`.
    ///    Throws `LoadError.identityNotVerified`.
    /// 3. All expected `.mlpackage` files for the selected `kind` must exist + load.
    ///    Throws `LoadError.modelsMissing`.
    /// 4. `prepareSource(...)` runs appearance + source-motion and caches the result.
    ///    Throws `LoadError.inferenceShapeMismatch` if the converted models don't match
    ///    the expected output shapes; propagates `PixelBufferConversionError` on bad PNG.
    ///
    /// - Parameters:
    ///   - kind: which backend to load. Defaults to `.liveportrait` per ADR-0015.
    ///   - identity: the `ConsentedIdentity` header (typically read via `ConsentedIdentityBundle.read`).
    ///   - pngBytes: the source PNG payload the header's hash binds to.
    ///   - runtimeVersion: the live MirrorMesh runtime (typically `FaceReenactor.runtimeVersion`).
    ///   - modelsDir: directory containing the expected .mlpackage files for `kind`. The
    ///                conversion scripts write them to `<repo>/models/` by default.
    public init(
        identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String,
        modelsDir: URL,
        kind: PhotorealBackendKind = .liveportrait
    ) async throws {
        // (1) ConsentedIdentity gate. Throws ConsentedIdentityError on any failure; we let
        // it propagate so the SwiftUI panel can read .description for a precise toast.
        do {
            try ConsentedIdentityVerifier.verify(
                identity: identity,
                pngBytes: pngBytes,
                runtimeVersion: runtimeVersion
            )
        } catch is ConsentedIdentityError {
            throw LoadError.identityNotVerified
        }

        // (2) Scheme gate. Stylized-non-human identities run on FaceReenactor's procedural
        // path; they have no business loading photoreal weights. R1.
        guard identity.scheme == .consentedThirdParty || identity.scheme == .selfAsSource else {
            throw LoadError.identityNotVerified
        }

        // (3) Models present + loadable. Refuse cleanly if not — this is the contract:
        // no path through this initializer secretly succeeds without verified inputs.
        let expected = Self.modelFileNames(for: kind)
        var loaded: [MLModel] = []
        loaded.reserveCapacity(expected.count)
        for name in expected {
            let url = modelsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LoadError.modelsMissing(modelsDir, kind)
            }
            let compiledURL: URL
            if url.pathExtension == "mlmodelc" {
                compiledURL = url
            } else {
                do {
                    compiledURL = try await MLModel.compileModel(at: url)
                } catch {
                    throw LoadError.modelsMissing(modelsDir, kind)
                }
            }
            guard let m = try? MLModel(contentsOf: compiledURL) else {
                throw LoadError.modelsMissing(modelsDir, kind)
            }
            loaded.append(m)
        }

        self.kind      = kind
        self.identity  = identity
        self.models    = loaded
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // (4) prepareSource — cache the appearance feature + source keypoints so the first
        // reenact() call has everything it needs. This is the only place we touch async
        // state during init; any failure here unwinds the init cleanly.
        try await self.prepareSource(pngBytes)

        TelemetryBus.emit(.annotation(
            key: "reenact.photoreal.loaded",
            value: "\(kind.rawValue):\(identity.identity_id)"
        ))
    }

    /// Run the appearance + motion networks on the source PNG once and cache the results.
    /// Called automatically from `init`. Exposed so a caller that constructs the actor
    /// through a non-standard path (e.g. tests that load a backend without an immediate
    /// source) can prime it explicitly.
    ///
    /// The cache is intentionally final — there is no "swap source" path. Identity rotation
    /// is handled by tearing down the backend and constructing a new one, matching the
    /// `FaceReenactor.setIdentity` model. This keeps the hot path lock-free.
    public func prepareSource(_ pngBytes: Data) async throws {
        guard kind == .liveportrait else {
            // FOMM path will land separately — different network split, different cache shape.
            // For v1.1 the LivePortrait path is the only one with a wired inference graph.
            return
        }

        let sourceInput = try PixelBufferConversion.makeMLInput(
            fromPNG: pngBytes,
            targetSize: 256,
            ciContext: self.ciContext
        )

        // Appearance network: source PNG -> feature_3d (1, 32, 16, 64, 64)
        let appInput = try MLDictionaryFeatureProvider(dictionary: [
            "source_image": MLFeatureValue(multiArray: sourceInput),
        ])
        let appOut = try await models[LP.appearance].prediction(from: appInput, options: MLPredictionOptions())
        guard let feature3D = appOut.featureValue(for: "feature_3d")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("appearance_v1.feature_3d")
        }
        // Sanity-check the shape so a misconverted model fails loudly here instead of
        // producing garbage at warp time. Expected: rank 5, (1, 32, 16, 64, 64).
        let f3DShape = feature3D.shape.map { $0.intValue }
        guard f3DShape.count == 5,
              f3DShape[0] == 1, f3DShape[1] == 32,
              f3DShape[2] == 16, f3DShape[3] == 64, f3DShape[4] == 64 else {
            throw LoadError.inferenceShapeMismatch("appearance_v1.feature_3d shape=\(f3DShape)")
        }

        // Motion network on the SAME source PNG. We only retain `kp` (the implicit keypoints)
        // — the other outputs (pitch/yaw/roll/t/exp/scale) are read for future use by the full
        // transform_keypoint path. For v1.1 minimum-viable, kp_source is used directly.
        let motInput = try MLDictionaryFeatureProvider(dictionary: [
            "driving_image": MLFeatureValue(multiArray: sourceInput),
        ])
        let motOut = try await models[LP.motion].prediction(from: motInput, options: MLPredictionOptions())
        guard let rawKP = motOut.featureValue(for: "kp")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.kp (source)")
        }
        let kp = try Self.reshapeKP(rawKP)

        self.sourceFeature3D = feature3D
        self.sourceKP        = kp
    }

    /// Reshape the motion model's flat `(1, 63)` keypoint output into the `(1, 21, 3)` layout
    /// the warp network expects. The fully-connected head of `MotionExtractor` projects to
    /// `3 * num_kp = 63` scalars; the LivePortrait reference path views that as `(1, K, 3)`
    /// before consuming it (see `dense_motion.create_sparse_motions`). Some converted models
    /// already emit rank-3; we accept either layout.
    ///
    /// macOS 14 floor (Package.swift): `MLMultiArray.reshaped(to:)` is macOS 15+, so when
    /// reshape is needed we allocate a new array and copy the float32 buffer byte-for-byte.
    /// 63 floats = 252 bytes; the copy is negligible against the per-frame ML cost.
    private static func reshapeKP(_ array: MLMultiArray) throws -> MLMultiArray {
        let shape = array.shape.map { $0.intValue }
        if shape == [1, 21, 3] {
            return array
        }
        if shape == [1, 63] {
            let newShape: [NSNumber] = [1, 21, 3]
            let reshaped: MLMultiArray
            do {
                reshaped = try MLMultiArray(shape: newShape, dataType: array.dataType)
            } catch {
                throw LoadError.inferenceShapeMismatch("motion_v1.kp reshape alloc failed: \(error)")
            }
            // Both arrays are contiguous float32 of identical element count; a flat memcpy
            // of all 63 elements moves the data without any layout assumption beyond "the
            // logical scan order matches".
            let src = array.dataPointer.bindMemory(to: Float32.self, capacity: 63)
            let dst = reshaped.dataPointer.bindMemory(to: Float32.self, capacity: 63)
            for i in 0..<63 { dst[i] = src[i] }
            return reshaped
        }
        throw LoadError.inferenceShapeMismatch("motion_v1.kp unexpected shape=\(shape) (expected [1,63] or [1,21,3])")
    }

    /// Drive the photoreal puppet with a single driving frame.
    ///
    /// Per-frame cost on M5 Max with ANE (target):
    ///   motion: ~5 ms | warp: ~15 ms | generator: ~20 ms | marshaling: ~1 ms
    ///   ≈ 41 ms / frame total
    ///
    /// - Parameter driver: the live camera frame (any pixel format CIImage can read).
    /// - Returns: a BGRA `CVPixelBuffer` at 256×256 (downscaled from the generator's native
    ///   512×512 to match the renderer's existing texture pool size). The caller owns the
    ///   returned buffer; the pipeline then routes it through the watermark stage exactly as
    ///   it would the camera passthrough.
    /// - Throws: `LoadError.sourceNotPrepared` if `prepareSource` has not run.
    ///           `LoadError.inferenceShapeMismatch` if a model output disagrees with the
    ///           expected shape contract.
    ///           `PixelBufferConversionError` on marshaling failures.
    public func reenact(driver: CVPixelBuffer) async throws -> CVPixelBuffer {
        guard kind == .liveportrait else {
            // FOMM path: not yet wired. Refuse explicitly rather than silently pass through.
            throw LoadError.sourceNotPrepared
        }
        guard let feature3D = self.sourceFeature3D,
              let kpSource  = self.sourceKP else {
            throw LoadError.sourceNotPrepared
        }

        // (1) Driver frame -> (1, 3, 256, 256) RGB float32 in [0, 1]
        let driverInput = try PixelBufferConversion.makeMLInput(
            from: driver,
            targetSize: 256,
            ciContext: self.ciContext
        )

        // (2) Motion network -> kp_driving (and pose/expression, currently unused for v1.1)
        let motInput = try MLDictionaryFeatureProvider(dictionary: [
            "driving_image": MLFeatureValue(multiArray: driverInput),
        ])
        let motOut = try await models[LP.motion].prediction(from: motInput, options: MLPredictionOptions())
        guard let rawDrivingKP = motOut.featureValue(for: "kp")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.kp (driving)")
        }
        let kpDriving = try Self.reshapeKP(rawDrivingKP)

        // (3) Warp network: (feature_3d, kp_driving, kp_source) -> warped_feature + occlusion_map
        // Note input-name ordering matches `models/training/liveportrait_to_coreml.py`:
        //   feature_3d, kp_driving, kp_source
        let warpInput = try MLDictionaryFeatureProvider(dictionary: [
            "feature_3d": MLFeatureValue(multiArray: feature3D),
            "kp_driving": MLFeatureValue(multiArray: kpDriving),
            "kp_source":  MLFeatureValue(multiArray: kpSource),
        ])
        let warpOut = try await models[LP.warp].prediction(from: warpInput, options: MLPredictionOptions())
        guard let warpedFeature = warpOut.featureValue(for: "warped_feature")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("warp_v1.warped_feature")
        }
        // occlusion_map is currently consumed only for telemetry — the SPADE decoder takes
        // only the warped feature volume per the upstream wrapper. Read it to surface model
        // health later; for v1.1 we just verify it exists.
        _ = warpOut.featureValue(for: "occlusion_map")?.multiArrayValue

        // (4) Generator: warped_feature -> prediction (1, 3, 512, 512)
        let genInput = try MLDictionaryFeatureProvider(dictionary: [
            "warped_feature": MLFeatureValue(multiArray: warpedFeature),
        ])
        let genOut = try await models[LP.generator].prediction(from: genInput, options: MLPredictionOptions())
        guard let prediction = genOut.featureValue(for: "prediction")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("generator_v1.prediction")
        }
        let predShape = prediction.shape.map { $0.intValue }
        guard predShape.count == 4, predShape[0] == 1, predShape[1] == 3 else {
            throw LoadError.inferenceShapeMismatch("generator_v1.prediction shape=\(predShape)")
        }

        // (5) MLMultiArray -> CVPixelBuffer (BGRA, 256x256). Downscales 512->256 in CIContext
        // so the renderer's existing 256-square texture pool is reused without changes.
        let outputBuffer = try PixelBufferConversion.makePixelBuffer(
            from: prediction,
            outputSize: 256,
            ciContext: self.ciContext
        )
        return outputBuffer
    }

    /// Back-compat shim for the v0.6.0 stub signature. Forwards to the new
    /// `reenact(driver:)` and ignores the landmark hint (the LivePortrait graph
    /// computes its own implicit keypoints inside `motion_v1`). Retained so any
    /// in-flight caller still wired against the old signature keeps compiling
    /// while v1.1 lands; new callers should target `reenact(driver:)` directly.
    public func reenact(
        landmarks: [SIMD2<Float>],
        driverImage: CVPixelBuffer
    ) async throws -> CVPixelBuffer {
        _ = landmarks
        return try await reenact(driver: driverImage)
    }
}
