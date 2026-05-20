import Foundation
import CoreVideo
import CoreML
import simd
import MirrorMeshCore
import MirrorMeshWatermark

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
/// **Status**: STUB. The `init` correctly enforces the gates and loads all expected
/// `MLModel`s for the chosen `kind`, but `reenact(...)` currently passes the driving
/// frame through unchanged. The full inference graph (cached source-feature volume,
/// motion + warp + generator wiring, pixel-buffer marshaling) lands in
/// M56-photoreal-inference (v1.1 task) once a contributor has run the conversion
/// script and verified end-to-end on real weights. The stub exists so pipeline
/// wiring, identity-gate tests, and the resources-missing failure path can all be
/// exercised before any real model is in the loop.
public actor PhotorealBackend {

    /// Errors surfaced specifically by the photorealistic backend's load gate. Distinct from
    /// `ConsentedIdentityError` (which the verifier throws directly) so callers can tell
    /// "verification failed" apart from "you need to download model weights".
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

    /// Failable initializer. Performs three checks in order, throwing on the first failure:
    ///
    /// 1. `ConsentedIdentityVerifier.verify` — signature, payload hash, scope.
    ///    Throws `ConsentedIdentityError` (passed through unchanged).
    /// 2. Identity `scheme` must be one of the two photoreal-eligible cases.
    ///    Throws `LoadError.identityNotVerified`.
    /// 3. All expected `.mlpackage` files for the selected `kind` must exist under
    ///    `modelsDir` and be loadable as `MLModel`. Throws `LoadError.modelsMissing`.
    ///
    /// - Parameters:
    ///   - kind: which backend to load. Defaults to `.liveportrait` per ADR-0015.
    ///   - identity: the `ConsentedIdentity` header (typically read via `ConsentedIdentityBundle.read`).
    ///   - pngBytes: the source PNG payload the header's hash binds to.
    ///   - runtimeVersion: the live MirrorMesh runtime (typically `FaceReenactor.runtimeVersion`).
    ///   - modelsDir: directory containing the expected .mlpackage files for `kind`. The
    ///                conversion scripts write them to `<repo>/models/` by default.
    public init(
        kind: PhotorealBackendKind = .liveportrait,
        identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String,
        modelsDir: URL
    ) throws {
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
            // .mlpackage requires a compile pass before MLModel can read it. Compile here
            // (cost paid once per launch); a future revision can cache to ~/Library/Caches
            // following Sources/MirrorMeshSolver/CoreMLSolver.swift:97 if we measure it
            // as a startup-time problem.
            let compiledURL: URL
            if url.pathExtension == "mlmodelc" {
                compiledURL = url
            } else {
                do {
                    compiledURL = try MLModel.compileModel(at: url)
                } catch {
                    throw LoadError.modelsMissing(modelsDir, kind)
                }
            }
            guard let m = try? MLModel(contentsOf: compiledURL) else {
                throw LoadError.modelsMissing(modelsDir, kind)
            }
            loaded.append(m)
        }

        self.kind     = kind
        self.identity = identity
        self.models   = loaded

        TelemetryBus.emit(.annotation(
            key: "reenact.photoreal.loaded",
            value: "\(kind.rawValue):\(identity.identity_id)"
        ))
    }

    /// Drive the photoreal puppet with a single driving frame.
    ///
    /// **STUB** (M56 scaffolding): the current implementation returns the driving frame
    /// unchanged regardless of `kind`. Wiring the kind-specific CoreML graphs into the
    /// actual inference path lands in M56-photoreal-inference (v1.1). The stub preserves
    /// the contract — caller gets back a valid `CVPixelBuffer` — so pipeline integration
    /// and identity-gate tests can land first.
    ///
    /// - Parameters:
    ///   - landmarks: the driving frame's landmark vector. Currently unused; documented
    ///                so the public signature is final.
    ///   - driverImage: the driving frame as a `CVPixelBuffer` (the operator's camera).
    /// - Returns: the reenacted frame. Currently == `driverImage` (stub).
    public func reenact(
        landmarks: [SIMD2<Float>],
        driverImage: CVPixelBuffer
    ) async throws -> CVPixelBuffer {
        // TODO(M56-photoreal-inference, v1.1): kind-specific inference graphs.
        //
        // LivePortrait path:
        //   appearance(source) -> feature_3d (cached once per identity)
        //   motion(driving)    -> (pitch, yaw, roll, t, exp, scale, kp_driving)
        //   warp(feature_3d, kp_driving, kp_source) -> (warped_feature, occlusion_map)
        //   generator(warped_feature) -> prediction (RGB)
        //
        // FOMM path:
        //   keypoint(driving) -> kp_driving (and kp_source cached from source frame)
        //   motion(source, kp_source, kp_driving) -> (deformation, occlusion_map)
        //   generator(source, deformation, occlusion_map) -> prediction (RGB)
        //
        // Then prediction -> CVPixelBuffer (with the same IOSurface backing the input,
        // matching pixel format).
        _ = landmarks
        _ = self.models
        _ = self.kind
        return driverImage
    }
}
