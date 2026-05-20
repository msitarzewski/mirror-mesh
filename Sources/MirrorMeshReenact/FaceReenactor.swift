import Foundation
import simd
import MirrorMeshCore
import MirrorMeshWatermark

/// Errors surfaced by the face reenactor's identity gate. Distinct from
/// `ConsentedIdentityError` so callers can differentiate "no identity loaded"
/// (`.identityRequired`) from "the identity you gave me failed verification"
/// (the rethrown `ConsentedIdentityError`).
public enum FaceReenactorError: Error, CustomStringConvertible, Sendable {
    case identityRequired
    case landmarkSchemaMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .identityRequired:
            return "FaceReenactor: a verified ConsentedIdentity must be loaded before reenactment"
        case let .landmarkSchemaMismatch(expected, got):
            return "FaceReenactor: expected \(expected)-point landmark frame, got \(got)"
        }
    }
}

/// The actor that drives a stylized-head puppet from a per-frame landmark stream.
///
/// **Gate**: refuses to initialize without a `ConsentedIdentity` that passes
/// `ConsentedIdentityVerifier.verify(...)`. This is the architectural difference between
/// MirrorMesh's reenactment capability and a generic catfishing kit (R1 + the v0.6.0 plan).
///
/// **Why an actor, not a class**: the pipeline runs on a render executor but the SwiftUI
/// settings panel updates the identity from the main thread. Actor isolation lets us mutate
/// `currentIdentity` from any task without retain-cycle hazards.
public actor FaceReenactor {
    /// The runtime version the reenactor was built for. Passed through to the verifier so the
    /// bundle's `scope` is checked against the live binary, not a hard-coded constant.
    public static let runtimeVersion = "0.6.0"

    /// The currently loaded identity (header only — the verifier already consumed the PNG bytes
    /// during the initial verification call). Re-verification on every reenact() call would be
    /// wasteful; the gate is at load-time and revocation is handled by re-loading the bundle.
    public private(set) var currentIdentity: ConsentedIdentity

    /// The deformable stylized head model. Procedural, stateless across calls — safe to share.
    public let model: StylizedHeadModel

    /// Pure-geometry solver. Stateless.
    private let solver: LandmarkSolver

    /// Failable initializer. Verifies the bundle synchronously before accepting it.
    ///
    /// - Parameters:
    ///   - identity: the `ConsentedIdentity` header (typically read via `ConsentedIdentityBundle.read`).
    ///   - pngBytes: the source PNG payload that the header's hash binds to.
    ///   - runtimeVersion: defaults to `FaceReenactor.runtimeVersion`; tests override.
    /// - Throws: `ConsentedIdentityError` if the bundle fails verification.
    public init(
        identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String = FaceReenactor.runtimeVersion
    ) throws {
        // The verifier throws `ConsentedIdentityError` on any failure: bad signature, tampered PNG,
        // out-of-scope bundle, unsupported version. We rethrow as-is so callers see the precise
        // failure (the SwiftUI Identity picker reads `.description` to populate the error toast).
        try ConsentedIdentityVerifier.verify(
            identity: identity,
            pngBytes: pngBytes,
            runtimeVersion: runtimeVersion
        )
        self.currentIdentity = identity
        self.model = StylizedHeadModel()
        self.solver = LandmarkSolver()
    }

    /// Hot-swap the identity at runtime. Used by the Settings panel when the operator picks a
    /// different `.mmid` bundle. Verifies before accepting, leaves the existing identity intact
    /// on failure.
    public func setIdentity(
        _ identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String = FaceReenactor.runtimeVersion
    ) throws {
        try ConsentedIdentityVerifier.verify(
            identity: identity,
            pngBytes: pngBytes,
            runtimeVersion: runtimeVersion
        )
        self.currentIdentity = identity
    }

    /// Drive the puppet with a single frame's landmarks. Deterministic — same input always
    /// produces the same output (the solver is geometric, no learned weights).
    ///
    /// **76-point contract**: the solver expects the canonical Vision 76-point layout
    /// (see `Sources/MirrorMeshVision/SyntheticLandmarkExtractor.swift` and `MeshTopology.Band`).
    /// Fewer points returns a frame with all-zero deformation (effectively the rest pose) so the
    /// renderer can still composite something sane during the first few Vision-warmup frames.
    public func reenact(landmarks: [SIMD2<Float>], frameID: FrameID, hostTimeNs: UInt64) -> ReenactFrame {
        let coefficients = solver.solve(landmarks: landmarks)
        let verts = model.deform(coefficients: coefficients)
        let normals = model.computeNormals(vertices: verts)
        return ReenactFrame(
            vertices: verts,
            normals: normals,
            indices: model.indices,
            coefficients: coefficients,
            labelTextureIndex: 0,
            frameID: frameID,
            hostTimeNs: hostTimeNs
        )
    }

    /// Convenience for `LandmarkFrame` callers (the canonical pipeline shape).
    public func reenact(_ landmarkFrame: LandmarkFrame) -> ReenactFrame {
        let pts = landmarkFrame.points.map { $0.simd }
        return reenact(
            landmarks: pts,
            frameID: landmarkFrame.frameID,
            hostTimeNs: landmarkFrame.hostTimeNs
        )
    }
}
