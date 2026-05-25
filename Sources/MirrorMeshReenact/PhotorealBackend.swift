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
/// Both `kp_source` (cached during `prepareSource`) and `kp_driving` (computed per frame)
/// are produced by `transformKeypoint(...)` — the same composition LivePortrait's reference
/// `live_portrait_wrapper.transform_keypoint` applies: rotate the canonical implicit
/// keypoints by the head pose (pitch/yaw/roll), scale, add per-keypoint expression delta,
/// then add translation. Using the composed keypoints (rather than the raw `kp` output)
/// produces noticeably richer reenactment because the warp net then receives a driving
/// signal that encodes pose and expression as well as identity-specific keypoints.
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

    /// Stable indices into the `models` array for FOMM. Order matches
    /// `modelFileNames(for: .fomm)` — `keypoint_v1`, `motion_v1`, `generator_v1`.
    /// FOMM has no separate appearance extractor — the SOURCE image itself is
    /// the appearance feature, and it feeds straight into the generator for
    /// every driving frame (see `models/training/fomm_to_coreml.py`).
    private enum FOMM {
        static let keypoint  = 0
        static let motion    = 1
        static let generator = 2
    }

    /// Number of implicit keypoints emitted by the LivePortrait motion network
    /// (`num_kp` in `liveportrait_to_coreml.HUMAN_256`). Hard-coded because the
    /// upstream architecture is fixed at 21 for the `human` variant.
    private static let lpNumKP = 21

    /// Number of bins per Euler-angle head in the LivePortrait motion network
    /// (`num_bins` in `liveportrait_to_coreml.HUMAN_256`). LivePortrait predicts
    /// pitch/yaw/roll as 66 discrete bins of 3 degrees each, with the bin index
    /// 0 corresponding to -99° and bin 65 corresponding to +99° — the standard
    /// `headpose_pred_to_degree` convention from FOMX/LivePortrait. The exact
    /// per-bin width (3°) and offset (-99°) are baked into `binsToDegree` below.
    private static let lpHeadposeBins = 66

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

    /// The cached source keypoint vector for LivePortrait. Shape `(1, 21, 3)`. Set by
    /// `prepareSource(...)` from the motion extractor running on the source PNG, then
    /// passed through `transformKeypoint(...)` so the cached value is the full world-
    /// space keypoint set (canonical kp rotated by source head-pose, expression-deformed,
    /// translation-shifted, scale-applied). Used as `kp_source` for every warp call.
    private var sourceKP: MLMultiArray?

    /// The cached source RGB image for FOMM. Shape `(1, 3, 256, 256)` float32 in [0, 1].
    /// FOMM has no separate appearance feature volume — the source image is what the
    /// motion + generator networks consume directly for every driving frame. Set by
    /// `prepareSource(...)` exactly once.
    private var sourceImage: MLMultiArray?

    /// The cached source-image keypoint coordinates for FOMM. Shape `(1, num_kp, 2)` —
    /// 2D image-space coordinates of each implicit keypoint. Set by `prepareSource(...)`
    /// from `keypoint_v1` on the source PNG.
    private var sourceKPValue: MLMultiArray?

    /// The cached source-image keypoint local jacobians for FOMM. Shape
    /// `(1, num_kp, 2, 2)` — 2x2 affine transform around each keypoint, used by FOMM's
    /// dense-motion network to compute the optical-flow field. Set alongside
    /// `sourceKPValue` in `prepareSource(...)`.
    private var sourceKPJacobian: MLMultiArray?

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
    ///                conversion scripts write them to `./models/` (relative to the repo root) by default.
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

    /// Run the per-kind source-preparation graph once and cache the result. Called
    /// automatically from `init`. Exposed so a caller that constructs the actor through a
    /// non-standard path (e.g. tests that load a backend without an immediate source) can
    /// prime it explicitly.
    ///
    /// LivePortrait: runs the appearance extractor (caches `feature_3d`) and the motion
    /// extractor (composes pitch/yaw/roll/scale/exp/t/kp into the source's world-space
    /// keypoints via `transformKeypoint` and caches them as `kp_source`).
    ///
    /// FOMM: caches the source-image MLMultiArray itself (FOMM has no separate appearance
    /// extractor — the source image feeds the motion + generator nets every frame) and the
    /// source keypoint detector outputs (`kp_value` + `kp_jacobian`).
    ///
    /// The cache is intentionally final — there is no "swap source" path. Identity rotation
    /// is handled by tearing down the backend and constructing a new one, matching the
    /// `FaceReenactor.setIdentity` model. This keeps the hot path lock-free.
    public func prepareSource(_ pngBytes: Data) async throws {
        let sourceInput = try PixelBufferConversion.makeMLInput(
            fromPNG: pngBytes,
            targetSize: 256,
            ciContext: self.ciContext
        )

        switch kind {
        case .liveportrait:
            try await prepareSourceLivePortrait(sourceInput: sourceInput)
        case .fomm:
            try await prepareSourceFOMM(sourceInput: sourceInput)
        }
    }

    /// LivePortrait source-preparation graph. Runs appearance + motion on the source PNG
    /// and caches `(feature_3d, kp_source)` where `kp_source` is the result of composing
    /// the seven motion outputs via `transformKeypoint` — i.e. the canonical implicit
    /// keypoints rotated by the source's pitch/yaw/roll, expression-deformed, translated,
    /// and scaled into world space.
    private func prepareSourceLivePortrait(sourceInput: MLMultiArray) async throws {
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

        // Motion network on the SAME source PNG. Capture ALL seven outputs (pitch, yaw, roll,
        // t, exp, scale, kp) then compose them via transformKeypoint into world-space keypoints.
        // This replaces the v1.1 minimum-viable shortcut that used `kp` directly — the composed
        // result is what LivePortrait's reference `live_portrait_wrapper.transform_keypoint`
        // produces, and the warp network expects.
        let motionOutputs = try await runMotion(image: sourceInput, stage: "source")
        let kpSourceTransformed = try Self.transformKeypoint(motionOutputs: motionOutputs)

        self.sourceFeature3D = feature3D
        self.sourceKP        = kpSourceTransformed
    }

    /// FOMM source-preparation graph. Caches `(sourceImage, kpValue, kpJacobian)` — the
    /// source image feeds straight into motion + generator every frame, and the keypoint
    /// outputs are reused as `kp_source_*` arguments to the motion network. Distinct from
    /// LivePortrait where the appearance volume is the cached state.
    private func prepareSourceFOMM(sourceInput: MLMultiArray) async throws {
        // FOMM keypoint detector: image (1, 3, 256, 256) -> kp_value (1, K, 2) + kp_jacobian (1, K, 2, 2)
        // Input name is `image` (see fomm_to_coreml.convert_kp); LivePortrait's motion net used
        // `driving_image`. Mismatched names produce a fast, deterministic CoreML error.
        let kpInput = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: sourceInput),
        ])
        let kpOut = try await models[FOMM.keypoint].prediction(from: kpInput, options: MLPredictionOptions())
        guard let kpValue = kpOut.featureValue(for: "kp_value")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_value (source)")
        }
        guard let kpJacobian = kpOut.featureValue(for: "kp_jacobian")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_jacobian (source)")
        }
        // Sanity-check shapes. Default FOMM vox-256 uses num_kp=10; we don't hard-code the
        // count because a contributor running an animal/taichi variant might convert with a
        // different num_kp — we just verify the rank + the leading-1 batch dim.
        let valShape = kpValue.shape.map { $0.intValue }
        guard valShape.count == 3, valShape[0] == 1, valShape[2] == 2 else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_value (source) shape=\(valShape)")
        }
        let jacShape = kpJacobian.shape.map { $0.intValue }
        guard jacShape.count == 4, jacShape[0] == 1,
              jacShape[2] == 2, jacShape[3] == 2,
              jacShape[1] == valShape[1] else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_jacobian (source) shape=\(jacShape)")
        }

        self.sourceImage      = sourceInput
        self.sourceKPValue    = kpValue
        self.sourceKPJacobian = kpJacobian
    }

    /// LivePortrait motion-extractor outputs as a Sendable bundle. We pull them out of the
    /// CoreML `MLFeatureProvider` once at the call site (which is async / actor-isolated) so
    /// the downstream `transformKeypoint` math can run on plain value-typed buffers. The
    /// `Float32` storage decouples the helper from CoreML's MLMultiArray indexing convention.
    ///
    /// `internal` (not `private`) so the `@testable` tests under
    /// `Tests/MirrorMeshReenactTests/PhotorealInferenceTests.swift` can construct sample
    /// motion outputs and exercise `transformKeypoint` directly without needing the four
    /// LP `.mlpackage` files.
    struct MotionOutputs: Sendable {
        /// Pitch logits, shape `(1, 66)`. Convert via `binsToDegree` before composing.
        var pitchBins: [Float32]
        /// Yaw logits, shape `(1, 66)`.
        var yawBins:   [Float32]
        /// Roll logits, shape `(1, 66)`.
        var rollBins:  [Float32]
        /// Translation, shape `(1, 3)`. Broadcast-added to every transformed keypoint.
        var t:         [Float32]
        /// Expression delta, shape `(1, 63)` viewed as `(21, 3)`. Per-keypoint additive.
        var exp:       [Float32]
        /// Scale, shape `(1, 1)` (one scalar). Multiplies rotated keypoints before exp+t.
        var scale:     Float32
        /// Canonical implicit keypoints, shape `(1, 63)` viewed as `(21, 3)`.
        var kp:        [Float32]
    }

    /// Run the LivePortrait motion extractor on an input image and pull all seven outputs
    /// into a `MotionOutputs` value. `stage` is used purely for error messages so a
    /// misconverted model fails with a precise indication of which call site noticed.
    private func runMotion(image: MLMultiArray, stage: String) async throws -> MotionOutputs {
        let motInput = try MLDictionaryFeatureProvider(dictionary: [
            "driving_image": MLFeatureValue(multiArray: image),
        ])
        let motOut = try await models[LP.motion].prediction(from: motInput, options: MLPredictionOptions())

        // Pull each output. The conversion script names them pitch/yaw/roll/t/exp/scale/kp.
        // Any missing output is an inferenceShapeMismatch.
        guard let pitchArr = motOut.featureValue(for: "pitch")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.pitch (\(stage))")
        }
        guard let yawArr = motOut.featureValue(for: "yaw")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.yaw (\(stage))")
        }
        guard let rollArr = motOut.featureValue(for: "roll")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.roll (\(stage))")
        }
        guard let tArr = motOut.featureValue(for: "t")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.t (\(stage))")
        }
        guard let expArr = motOut.featureValue(for: "exp")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.exp (\(stage))")
        }
        guard let scaleArr = motOut.featureValue(for: "scale")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.scale (\(stage))")
        }
        guard let kpArr = motOut.featureValue(for: "kp")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.kp (\(stage))")
        }

        // Copy each array's flat float32 buffer into a Swift [Float32]. CoreML stores these
        // contiguously and we treat them as flat element-order vectors — the structural
        // reshape happens in `transformKeypoint`.
        func flatten(_ a: MLMultiArray, expectedCount: Int, name: String) throws -> [Float32] {
            let count = a.shape.map { $0.intValue }.reduce(1, *)
            guard count == expectedCount else {
                throw LoadError.inferenceShapeMismatch("motion_v1.\(name) (\(stage)) count=\(count) expected=\(expectedCount)")
            }
            let ptr = a.dataPointer.bindMemory(to: Float32.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }

        let K = Self.lpNumKP
        let B = Self.lpHeadposeBins
        let pitch = try flatten(pitchArr,  expectedCount: B,       name: "pitch")
        let yaw   = try flatten(yawArr,    expectedCount: B,       name: "yaw")
        let roll  = try flatten(rollArr,   expectedCount: B,       name: "roll")
        let t     = try flatten(tArr,      expectedCount: 3,       name: "t")
        let exp   = try flatten(expArr,    expectedCount: K * 3,   name: "exp")
        let scale = try flatten(scaleArr,  expectedCount: 1,       name: "scale")
        let kp    = try flatten(kpArr,     expectedCount: K * 3,   name: "kp")
        return MotionOutputs(
            pitchBins: pitch,
            yawBins:   yaw,
            rollBins:  roll,
            t:         t,
            exp:       exp,
            scale:     scale[0],
            kp:        kp
        )
    }

    /// Convert a 66-bin headpose logit vector into a single degree value, matching
    /// LivePortrait's reference `headpose_pred_to_degree`:
    ///
    ///     softmax(bins) -> weighted sum with index [0..65] -> * 3 - 99
    ///
    /// The bin width is 3° and the index-0 bin corresponds to -99°; index 65 to +99°.
    /// We use a numerically-stable softmax (subtract the max before `exp`) so logits in
    /// the +/-50 range (the network's natural output scale) don't overflow `expf`.
    static func binsToDegree(_ bins: [Float32]) -> Float32 {
        var maxVal = bins[0]
        for i in 1..<bins.count {
            if bins[i] > maxVal { maxVal = bins[i] }
        }
        var expSum: Float32 = 0
        var weightedSum: Float32 = 0
        for i in 0..<bins.count {
            let e = expf(bins[i] - maxVal)
            expSum += e
            weightedSum += e * Float32(i)
        }
        let mean = weightedSum / expSum
        return mean * 3.0 - 99.0
    }

    /// Build the 3x3 rotation matrix for intrinsic XYZ Euler angles (pitch around X, yaw
    /// around Y, roll around Z, applied in that order). Composition: `R = Rx * Ry * Rz`.
    /// All angles are radians on entry.
    ///
    /// Layout is row-major as a flat `[Float32]` of length 9, so `M[r*3 + c]` accesses
    /// row `r` column `c`. We return a value-typed array rather than a `simd_float3x3`
    /// because the downstream consumer multiplies it row-wise against `(21, 3)` keypoints
    /// where every row is a 3-vector — a hand-rolled scalar loop is easier to verify and
    /// produces no SIMD-layout surprise (column-major vs row-major).
    static func rotationMatrixXYZ(pitch: Float32, yaw: Float32, roll: Float32) -> [Float32] {
        let cp = cosf(pitch); let sp = sinf(pitch)
        let cy = cosf(yaw);   let sy = sinf(yaw)
        let cr = cosf(roll);  let sr = sinf(roll)

        // Rx (pitch around X):
        //  [ 1   0   0 ]
        //  [ 0  cp -sp ]
        //  [ 0  sp  cp ]
        // Ry (yaw around Y):
        //  [ cy  0  sy ]
        //  [ 0   1   0 ]
        //  [-sy  0  cy ]
        // Rz (roll around Z):
        //  [ cr -sr  0 ]
        //  [ sr  cr  0 ]
        //  [ 0   0   1 ]
        //
        // R = Rx * Ry * Rz, row-major:
        let r00 = cy * cr
        let r01 = -cy * sr
        let r02 = sy
        let r10 = sp * sy * cr + cp * sr
        let r11 = -sp * sy * sr + cp * cr
        let r12 = -sp * cy
        let r20 = -cp * sy * cr + sp * sr
        let r21 = cp * sy * sr + sp * cr
        let r22 = cp * cy
        return [
            r00, r01, r02,
            r10, r11, r12,
            r20, r21, r22,
        ]
    }

    /// Compose the seven motion outputs into a `(1, 21, 3)` world-space keypoint tensor.
    /// Mirrors LivePortrait's `live_portrait_wrapper.transform_keypoint`:
    ///
    ///     kp_t = scale * (kp @ R) + exp + t
    ///
    /// where:
    /// - `R` is the intrinsic-XYZ rotation matrix built from pitch/yaw/roll (degrees,
    ///   recovered from the 66-bin logits via `binsToDegree`),
    /// - `kp` is the implicit canonical keypoint tensor `(21, 3)`,
    /// - `exp` is the per-keypoint expression delta `(21, 3)`,
    /// - `t` is the head translation `(3,)`, broadcast-added to every keypoint,
    /// - `scale` is a scalar multiplier on the rotated keypoints (before adding exp + t,
    ///   per upstream).
    ///
    /// This is the only computation between the motion network and the warp network. It is
    /// CPU-bound, runs in microseconds for 21*3 floats, and has no async surface — pure value
    /// types in, an `MLMultiArray` out.
    static func transformKeypoint(motionOutputs m: MotionOutputs) throws -> MLMultiArray {
        let K = lpNumKP

        // (1) bins -> degrees -> radians
        let pitchDeg = binsToDegree(m.pitchBins)
        let yawDeg   = binsToDegree(m.yawBins)
        let rollDeg  = binsToDegree(m.rollBins)
        let deg2rad: Float32 = .pi / 180.0
        let R = rotationMatrixXYZ(
            pitch: pitchDeg * deg2rad,
            yaw:   yawDeg   * deg2rad,
            roll:  rollDeg  * deg2rad
        )

        // (2) Allocate the (1, K, 3) destination MLMultiArray.
        let shape: [NSNumber] = [1, NSNumber(value: K), 3]
        let out: MLMultiArray
        do {
            out = try MLMultiArray(shape: shape, dataType: .float32)
        } catch {
            throw LoadError.inferenceShapeMismatch("transform_keypoint output alloc failed: \(error)")
        }
        let dst = out.dataPointer.bindMemory(to: Float32.self, capacity: K * 3)

        // (3) For each keypoint k in 0..K, compute:
        //         row_rot = (kp_k * R)   — row-vector right-multiplied by R
        //         out_k   = scale * row_rot + exp_k + t
        //     We index `kp` and `exp` as flat (K, 3) arrays.
        for k in 0..<K {
            let kx = m.kp[k * 3 + 0]
            let ky = m.kp[k * 3 + 1]
            let kz = m.kp[k * 3 + 2]
            // row-vector @ R: out[c] = sum_r kp_r * R[r][c]
            let rx = kx * R[0 * 3 + 0] + ky * R[1 * 3 + 0] + kz * R[2 * 3 + 0]
            let ry = kx * R[0 * 3 + 1] + ky * R[1 * 3 + 1] + kz * R[2 * 3 + 1]
            let rz = kx * R[0 * 3 + 2] + ky * R[1 * 3 + 2] + kz * R[2 * 3 + 2]
            dst[k * 3 + 0] = m.scale * rx + m.exp[k * 3 + 0] + m.t[0]
            dst[k * 3 + 1] = m.scale * ry + m.exp[k * 3 + 1] + m.t[1]
            dst[k * 3 + 2] = m.scale * rz + m.exp[k * 3 + 2] + m.t[2]
        }

        return out
    }

    /// Drive the photoreal puppet with a single driving frame.
    ///
    /// Per-frame cost on M5 Max with ANE (target):
    ///   motion: ~5 ms | warp: ~15 ms | generator: ~20 ms | marshaling: ~1 ms
    ///   ≈ 41 ms / frame total
    ///
    /// - Parameter driver: the live camera frame (any pixel format CIImage can read).
    /// - Parameter tensorDumpDir: optional directory to dump each submodel-boundary
    ///   `MLMultiArray` to (Phase 2 v2 plan tooling). When non-nil, each intermediate
    ///   tensor is written as raw float32 plus a JSON sidecar describing shape + dtype,
    ///   so a Python validator can compare it against the upstream reference. Skipped
    ///   when nil — zero overhead on the hot path.
    /// - Returns: a BGRA `CVPixelBuffer` at 256×256 (downscaled from the generator's native
    ///   512×512 to match the renderer's existing texture pool size). The caller owns the
    ///   returned buffer; the pipeline then routes it through the watermark stage exactly as
    ///   it would the camera passthrough.
    /// - Throws: `LoadError.sourceNotPrepared` if `prepareSource` has not run.
    ///           `LoadError.inferenceShapeMismatch` if a model output disagrees with the
    ///           expected shape contract.
    ///           `PixelBufferConversionError` on marshaling failures.
    public func reenact(
        driver: CVPixelBuffer,
        tensorDumpDir: URL? = nil
    ) async throws -> CVPixelBuffer {
        // (1) Driver frame -> (1, 3, 256, 256) RGB float32 in [0, 1]. The same conversion
        // serves both backends; channel order + normalization match each conversion script.
        let driverInput = try PixelBufferConversion.makeMLInput(
            from: driver,
            targetSize: 256,
            ciContext: self.ciContext
        )
        if let dir = tensorDumpDir {
            try Self.dumpMultiArray(driverInput, name: "driver.input", in: dir)
        }
        switch kind {
        case .liveportrait:
            return try await reenactLivePortrait(driverInput: driverInput, tensorDumpDir: tensorDumpDir)
        case .fomm:
            return try await reenactFOMM(driverInput: driverInput)
        }
    }

    /// Write an `MLMultiArray` to `<dir>/<name>.bin` (raw float32, contiguous, row-major) plus
    /// `<dir>/<name>.json` with `{shape, dtype, count}`. Phase 2 of the v2 plan needs these
    /// dumps to validate MPSGraph submodel ports against the current CoreML implementation
    /// (and against the upstream Python reference): for each submodel rewrite, dump the
    /// Swift CoreML output, dump the MPSGraph candidate, numpy-load both, assert max abs
    /// element-wise difference is below a tolerance. Skips silently if write fails — the
    /// dump path is diagnostic-only, never load-bearing.
    static func dumpMultiArray(_ array: MLMultiArray, name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shape = array.shape.map { $0.intValue }
        let count = shape.reduce(1, *)
        guard array.dataType == .float32 else {
            // For now we only dump float32. Other dtypes would need conversion; tag the
            // sidecar so a Python loader bails loudly instead of misinterpreting bytes.
            let sidecar = """
            {"name":"\(name)","shape":\(shape),"dtype":"\(array.dataType.rawValue)","count":\(count),"error":"non-float32 dtype not dumped"}
            """
            try sidecar.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
            return
        }
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
        let bytes = Data(bytes: ptr, count: count * MemoryLayout<Float32>.stride)
        try bytes.write(to: dir.appendingPathComponent("\(name).bin"))
        let sidecar = """
        {"name":"\(name)","shape":\(shape),"dtype":"float32","count":\(count)}
        """
        try sidecar.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    /// LivePortrait per-frame forward: motion → transform_keypoint → warp → generator.
    /// The cached `feature_3d` and source `kpSource` are reused unchanged for every frame.
    /// When `tensorDumpDir` is non-nil, each submodel boundary's `MLMultiArray` is dumped
    /// for Phase 2 validation diffs against MPSGraph candidate ports.
    private func reenactLivePortrait(
        driverInput: MLMultiArray,
        tensorDumpDir: URL? = nil
    ) async throws -> CVPixelBuffer {
        guard let feature3D = self.sourceFeature3D,
              let kpSource  = self.sourceKP else {
            throw LoadError.sourceNotPrepared
        }
        if let dir = tensorDumpDir {
            // Source tensors are cached per-session — dump them every call so any single
            // bench invocation produces a complete fixture set without needing a separate
            // prepareSource-only mode.
            try Self.dumpMultiArray(feature3D, name: "source.feature_3d", in: dir)
            try Self.dumpMultiArray(kpSource,  name: "source.kp_transformed", in: dir)
        }

        // (2) Motion network -> all seven outputs, composed via transformKeypoint into
        // kp_driving. This is what LivePortrait's reference inference does — the warp net
        // never sees the raw `kp`; it sees the world-space composed kp.
        let motionOutputs = try await runMotion(image: driverInput, stage: "driving")
        let kpDriving = try Self.transformKeypoint(motionOutputs: motionOutputs)
        if let dir = tensorDumpDir {
            try Self.dumpFlatFloats(motionOutputs.pitchBins, shape: [1, motionOutputs.pitchBins.count], name: "motion.driving.pitch", in: dir)
            try Self.dumpFlatFloats(motionOutputs.yawBins,   shape: [1, motionOutputs.yawBins.count],   name: "motion.driving.yaw",   in: dir)
            try Self.dumpFlatFloats(motionOutputs.rollBins,  shape: [1, motionOutputs.rollBins.count],  name: "motion.driving.roll",  in: dir)
            try Self.dumpFlatFloats(motionOutputs.t,         shape: [1, motionOutputs.t.count],         name: "motion.driving.t",     in: dir)
            try Self.dumpFlatFloats(motionOutputs.exp,       shape: [1, motionOutputs.exp.count],       name: "motion.driving.exp",   in: dir)
            try Self.dumpFlatFloats([motionOutputs.scale],   shape: [1, 1],                              name: "motion.driving.scale", in: dir)
            try Self.dumpFlatFloats(motionOutputs.kp,        shape: [1, motionOutputs.kp.count],        name: "motion.driving.kp",    in: dir)
            try Self.dumpMultiArray(kpDriving, name: "motion.driving.kp_transformed", in: dir)
        }

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
        let occlusionMap = warpOut.featureValue(for: "occlusion_map")?.multiArrayValue
        if let dir = tensorDumpDir {
            try Self.dumpMultiArray(warpedFeature, name: "warp.warped_feature", in: dir)
            if let occ = occlusionMap {
                try Self.dumpMultiArray(occ, name: "warp.occlusion_map", in: dir)
            }
        }

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
        if let dir = tensorDumpDir {
            try Self.dumpMultiArray(prediction, name: "generator.prediction", in: dir)
        }

        // (5) MLMultiArray -> CVPixelBuffer (BGRA, 512x512). Keep the generator's native 512
        // resolution: with the v1.1 PhotorealOverlay path the renderer wraps this directly as
        // a Metal texture and the bilinear sampler scales it to face-bbox size, so the extra
        // resolution shows as ~4x perceived sharpness on a typical face crop with zero extra
        // CPU cost (we previously paid for the 512->256 downscale and then re-upscaled on the
        // GPU anyway). Return type and BGRA format are unchanged.
        let outputBuffer = try PixelBufferConversion.makePixelBuffer(
            from: prediction,
            outputSize: 512,
            ciContext: self.ciContext
        )
        return outputBuffer
    }

    /// Same shape as `dumpMultiArray` but for flat `[Float32]` buffers (the motion-extractor
    /// outputs decoded into Swift arrays inside `runMotion`). `shape` is the logical shape
    /// to record in the sidecar.
    static func dumpFlatFloats(_ values: [Float32], shape: [Int], name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = shape.reduce(1, *)
        precondition(count == values.count, "dumpFlatFloats(\(name)): shape \(shape) implies \(count) elements, got \(values.count)")
        try values.withUnsafeBufferPointer { buf in
            let bytes = Data(buffer: buf)
            try bytes.write(to: dir.appendingPathComponent("\(name).bin"))
        }
        let sidecar = """
        {"name":"\(name)","shape":\(shape),"dtype":"float32","count":\(count)}
        """
        try sidecar.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    /// FOMM per-frame forward: keypoint(driver) → motion(source + 4 kps) → generator(source +
    /// deformation + occlusion). FOMM keeps no separate appearance-feature volume; the source
    /// MLMultiArray is fed into both motion and generator every frame, exactly as the upstream
    /// `animate.py` does.
    private func reenactFOMM(driverInput: MLMultiArray) async throws -> CVPixelBuffer {
        guard let sourceImage      = self.sourceImage,
              let sourceKPValue    = self.sourceKPValue,
              let sourceKPJacobian = self.sourceKPJacobian else {
            throw LoadError.sourceNotPrepared
        }

        // (2) Keypoint detector on the driver frame -> kp_driving_value + kp_driving_jacobian.
        // Input name `image` matches the conversion-script contract.
        let kpInput = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: driverInput),
        ])
        let kpOut = try await models[FOMM.keypoint].prediction(from: kpInput, options: MLPredictionOptions())
        guard let kpDrivingValue = kpOut.featureValue(for: "kp_value")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_value (driving)")
        }
        guard let kpDrivingJacobian = kpOut.featureValue(for: "kp_jacobian")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("keypoint_v1.kp_jacobian (driving)")
        }

        // (3) Dense-motion network -> deformation field + occlusion map. Input-name ordering
        // matches `models/training/fomm_to_coreml.convert_motion`.
        let motionInput = try MLDictionaryFeatureProvider(dictionary: [
            "source_image":        MLFeatureValue(multiArray: sourceImage),
            "kp_source_value":     MLFeatureValue(multiArray: sourceKPValue),
            "kp_source_jacobian":  MLFeatureValue(multiArray: sourceKPJacobian),
            "kp_driving_value":    MLFeatureValue(multiArray: kpDrivingValue),
            "kp_driving_jacobian": MLFeatureValue(multiArray: kpDrivingJacobian),
        ])
        let motionOut = try await models[FOMM.motion].prediction(from: motionInput, options: MLPredictionOptions())
        guard let deformation = motionOut.featureValue(for: "deformation")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.deformation (FOMM)")
        }
        guard let occlusionMap = motionOut.featureValue(for: "occlusion_map")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("motion_v1.occlusion_map (FOMM)")
        }

        // (4) Generator: (source, deformation, occlusion) -> prediction (1, 3, 256, 256)
        let genInput = try MLDictionaryFeatureProvider(dictionary: [
            "source_image":  MLFeatureValue(multiArray: sourceImage),
            "deformation":   MLFeatureValue(multiArray: deformation),
            "occlusion_map": MLFeatureValue(multiArray: occlusionMap),
        ])
        let genOut = try await models[FOMM.generator].prediction(from: genInput, options: MLPredictionOptions())
        guard let prediction = genOut.featureValue(for: "prediction")?.multiArrayValue else {
            throw LoadError.inferenceShapeMismatch("generator_v1.prediction (FOMM)")
        }
        let predShape = prediction.shape.map { $0.intValue }
        guard predShape.count == 4, predShape[0] == 1, predShape[1] == 3 else {
            throw LoadError.inferenceShapeMismatch("generator_v1.prediction (FOMM) shape=\(predShape)")
        }

        // (5) MLMultiArray -> CVPixelBuffer. FOMM generator is native 256x256 so no downscale
        // — pass outputSize: 256 to keep the renderer's texture-pool size consistent across
        // backends.
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
