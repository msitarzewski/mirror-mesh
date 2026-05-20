import Foundation
import CoreVideo
import CoreML
import simd
import MirrorMeshCore
import MirrorMeshWatermark

/// The photorealistic identity-transfer backend (v0.6.0 M56 — FOMM path).
///
/// **Relationship to `FaceReenactor`**: `FaceReenactor` is the stylized 3D head puppet
/// path — pure geometry, ships ready-to-run, no learned weights. `PhotorealBackend`
/// is the optional photorealistic path that requires the user to download FOMM weights
/// themselves and run `models/training/fomm_to_coreml.py` once. Both paths share the
/// `ConsentedIdentityVerifier` gate (R1); a session may run with neither, one, or both
/// loaded, and the operator picks which the pipeline drives.
///
/// **The contract**: this initializer must refuse cleanly when either the identity is
/// invalid or the three `.mlpackage` files are absent. There is no fallback path that
/// secretly succeeds without verified inputs — see R12 ("refuse on sight") and the
/// release plan's "architecturally distinct from a generic catfishing kit" framing.
///
/// **Status**: STUB. The `init` correctly enforces the gates and loads the three
/// `MLModel`s, but `reenact(...)` currently passes the driving frame through unchanged.
/// The full inference graph (kp_source caching, dense-motion + generator wiring,
/// pixel-buffer marshaling) lands in the follow-up commit once a contributor has run
/// the conversion script and verified end-to-end on real weights. The stub exists so
/// pipeline wiring, identity-gate tests, and the resources-missing failure path can
/// all be exercised before any real model is in the loop.
public actor PhotorealBackend {

    /// Errors surfaced specifically by the photorealistic backend's load gate. Distinct from
    /// `ConsentedIdentityError` (which the verifier throws directly) so callers can tell
    /// "verification failed" apart from "you need to download model weights".
    public enum LoadError: Error, CustomStringConvertible, Sendable {
        /// One or more of `keypoint_v1.mlpackage`, `motion_v1.mlpackage`, `generator_v1.mlpackage`
        /// could not be found under `modelsDir`. The associated URL is the directory that was
        /// searched — surfaced so the SwiftUI Identity panel can show a "Download FOMM weights"
        /// CTA pointing at the right location.
        case modelsMissing(URL)
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
            case .modelsMissing(let dir):
                return "PhotorealBackend: FOMM models not found under \(dir.path). " +
                       "Run models/training/fomm_to_coreml.py per models/training/README.md."
            case .identityNotVerified:
                return "PhotorealBackend: identity must be verified and of scheme " +
                       "selfAsSource or consentedThirdParty before loading the photoreal path"
            case .runtimeUnsupported:
                return "PhotorealBackend: runtime version unsupported for these model packages"
            }
        }
    }

    /// The three model file names the backend looks for. Hard-coded because the names are
    /// the script's contract — see `models/training/fomm_to_coreml.py`.
    public static let modelFileNames: [String] = [
        "keypoint_v1.mlpackage",
        "motion_v1.mlpackage",
        "generator_v1.mlpackage",
    ]

    /// The currently loaded identity (header only — the PNG was already consumed by the
    /// verifier during init). The reenact() hot path does not re-verify per-frame; the gate
    /// is at load time and identity rotation happens by tearing the backend down and
    /// constructing a new one.
    public nonisolated let identity: ConsentedIdentity

    private let kpModel: MLModel
    private let motionModel: MLModel
    private let generatorModel: MLModel

    /// Failable initializer. Performs three checks in order, throwing on the first failure:
    ///
    /// 1. `ConsentedIdentityVerifier.verify` — signature, payload hash, scope.
    ///    Throws `ConsentedIdentityError` (passed through unchanged).
    /// 2. Identity `scheme` must be one of the two photoreal-eligible cases.
    ///    Throws `LoadError.identityNotVerified`.
    /// 3. All three `.mlpackage` files must exist under `modelsDir` and be loadable as
    ///    `MLModel`. Throws `LoadError.modelsMissing(modelsDir)`.
    ///
    /// - Parameters:
    ///   - identity: the `ConsentedIdentity` header (typically read via `ConsentedIdentityBundle.read`).
    ///   - pngBytes: the source PNG payload the header's hash binds to.
    ///   - runtimeVersion: the live MirrorMesh runtime (typically `FaceReenactor.runtimeVersion`).
    ///   - modelsDir: directory containing the three .mlpackage files. The conversion script
    ///                writes them to `<repo>/models/` by default.
    public init(
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
        // path; they have no business loading FOMM weights. R1.
        guard identity.scheme == .consentedThirdParty || identity.scheme == .selfAsSource else {
            throw LoadError.identityNotVerified
        }

        // (3) Models present + loadable. Refuse cleanly if not — this is the contract:
        // no path through this initializer secretly succeeds without verified inputs.
        var loaded: [MLModel] = []
        for name in Self.modelFileNames {
            let url = modelsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LoadError.modelsMissing(modelsDir)
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
                    throw LoadError.modelsMissing(modelsDir)
                }
            }
            guard let m = try? MLModel(contentsOf: compiledURL) else {
                throw LoadError.modelsMissing(modelsDir)
            }
            loaded.append(m)
        }

        self.identity = identity
        self.kpModel        = loaded[0]
        self.motionModel    = loaded[1]
        self.generatorModel = loaded[2]

        TelemetryBus.emit(.annotation(
            key: "reenact.photoreal.loaded",
            value: identity.identity_id
        ))
    }

    /// Drive the photoreal puppet with a single driving frame.
    ///
    /// **STUB** (M56 scaffolding): the current implementation returns the driving frame
    /// unchanged. Wiring the three CoreML models into the actual inference graph
    /// (kp_source caching, MLMultiArray marshaling, pixel-format bridging) lands in the
    /// follow-up commit. The stub preserves the contract — caller gets back a valid
    /// `CVPixelBuffer` — so pipeline integration and identity-gate tests can land first.
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
        // TODO(M56-followup): wire kp_source caching + motion + generator into the real
        // inference graph. Driver-frame -> kp_driving (kpModel), then
        // (source, kp_source, kp_driving) -> deformation+occlusion (motionModel),
        // then (source, deformation, occlusion) -> prediction (generatorModel),
        // then prediction -> CVPixelBuffer.
        _ = landmarks
        _ = self.kpModel
        _ = self.motionModel
        _ = self.generatorModel
        return driverImage
    }
}
