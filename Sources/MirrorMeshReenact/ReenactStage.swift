import Foundation
import simd
import MirrorMeshCore
import MirrorMeshWatermark

// ─────────────────────────────────────────────────────────────────────────────
// ORCHESTRATOR INTEGRATION POINTS
// ─────────────────────────────────────────────────────────────────────────────
//
// This module (`MirrorMeshReenact`) is built as a standalone library so the
// reenactment surface can be tested in isolation. To wire it into the live
// pipeline three edits are required by the orchestrator:
//
// 1) Package.swift — add the library + its dependencies + test target.
//    Insert under the existing library list:
//
//        .library(name: "MirrorMeshReenact", targets: ["MirrorMeshReenact"]),
//
//    Under `targets:`, add:
//
//        .target(
//            name: "MirrorMeshReenact",
//            dependencies: [
//                "MirrorMeshCore",
//                "MirrorMeshWatermark",   // ConsentedIdentityVerifier gate
//                "MirrorMeshVision",      // LandmarkFrame import (transitively MirrorMeshCore)
//            ],
//            path: "Sources/MirrorMeshReenact"
//        ),
//        .testTarget(
//            name: "MirrorMeshReenactTests",
//            dependencies: ["MirrorMeshReenact", "MirrorMeshWatermark", "MirrorMeshCore"],
//            path: "Tests/MirrorMeshReenactTests"
//        ),
//
//    Then add MirrorMeshReenact as a dependency of MirrorMeshOutput so the
//    Pipeline actor can `import MirrorMeshReenact`:
//
//        .target(
//            name: "MirrorMeshOutput",
//            dependencies: [
//                "MirrorMeshCore",
//                "MirrorMeshRender",
//                "MirrorMeshWatermark",
//                "MirrorMeshRecorder",
//                "MirrorMeshVirtualCamera",
//                "MirrorMeshReenact",          // ← add
//            ],
//            ...
//
//    No Package.swift edit is needed for the Metal shader; it lives under
//    Sources/MirrorMeshRender/Shaders and is already covered by the existing
//    `.copy("Shaders")` rule on MirrorMeshRender (R14).
//
// 2) Sources/MirrorMeshRender/MetalContext.swift — extend the shader source list
//    so the runtime compiles the new file alongside the existing ones:
//
//        let sources = ["Passthrough", "LandmarkSprite", "AvatarMask", "FaceMesh", "StylizedHead"]
//
//    This is the only edit required to MirrorMeshRender; the renderer class
//    `StylizedHeadRenderer` lives alongside the other renderers and is wired
//    in by the integrator when they decide where (in `Renderer.swift`) the
//    stylized head should composite.
//
// 3) Sources/MirrorMeshOutput/Pipeline.swift — instantiate the stage and call it
//    between the solver and the renderer. Suggested diff:
//
//        import MirrorMeshReenact
//
//        // In PipelineOptions, optional identity bundle:
//        public var consentedIdentity: ConsentedIdentity? = nil
//        public var consentedIdentityPNG: Data? = nil
//
//        // In Pipeline.run(), after `let solver` is built:
//        let reenactStage = ReenactStage()
//        if let id = options.consentedIdentity, let png = options.consentedIdentityPNG {
//            do {
//                try await reenactStage.setIdentity(id, pngBytes: png)
//            } catch {
//                // R12: failure to verify is a load-time refusal; the pipeline
//                // continues without a reenactor (Mirror style falls back to
//                // existing mesh overlay) and emits a clear telemetry warning.
//                await Telemetry.shared.emit(.warning(
//                    stage: .solver,
//                    message: "Identity bundle rejected: \(error)"
//                ))
//            }
//        }
//
//        // In the per-frame loop, between solver and render:
//        var reenacted: ReenactedFrame? = nil
//        if let lf = landmarks {
//            reenacted = await reenactStage.apply(lf)
//        }
//
//        // Then pass `reenacted` to the renderer (Renderer.render gains an
//        // optional `reenacted: ReenactedFrame?` parameter; the renderer's
//        // StylizedHeadRenderer.encode(...) is no-op when nil so the existing
//        // pipeline behavior is preserved).
//
// 4) (Optional UX hook) Sources/MirrorMeshAppKit — owned by the Identity-UX
//    agent. The .mmid picker calls `Pipeline.setConsentedIdentity(id, png)`
//    via a new public method (analogous to `setRendererOptions`) so the
//    Settings panel can hot-swap identities. Not added here; left as a stub.
//
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps a `ReenactFrame` with pipeline-frame metadata so it can be passed alongside
/// `LandmarkFrame` / `BlendshapeFrame` in the orchestrator without leaking the reenactor's
/// internal types into MirrorMeshOutput. `Sendable` because all fields are value-typed.
public struct ReenactedFrame: Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    /// `nil` when the stage runs pass-through (no identity loaded). Renderer treats nil as
    /// "skip the stylized head pass" — the existing landmark/mesh overlays still render.
    public let frame: ReenactFrame?
    /// True if the stage actively produced a reenactment. Surfaced so telemetry / UI can show
    /// "Identity: loaded, reenactment ON" vs. "Identity: none, reenactment OFF".
    public let identityActive: Bool

    public init(frameID: FrameID, hostTimeNs: UInt64, frame: ReenactFrame?, identityActive: Bool) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.frame = frame
        self.identityActive = identityActive
    }
}

/// Pipeline stage that owns a (lazy) `FaceReenactor` and produces `ReenactedFrame`s. Pass-through
/// until an identity is loaded; verifies-then-loads on `setIdentity`.
///
/// **Why a `final class` not an `actor` at this layer**: the work this stage does is the
/// `FaceReenactor.reenact` call, which is already actor-isolated. Wrapping it in a second actor
/// would double the hop. The stage owns mutable state (`reenactor`), so we use a serial dispatch
/// queue to guard `setIdentity` vs. `apply` racing — equivalent to actor isolation but with one
/// fewer await on the fast path. Marked `@unchecked Sendable` for the same reason `Renderer` is.
public final class ReenactStage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mirrormesh.reenact.stage")
    private var reenactor: FaceReenactor?

    public init() {}

    /// Load and verify an identity bundle. Throws `ConsentedIdentityError` on rejection — the
    /// caller (Pipeline or Settings UI) is responsible for surfacing the error to the operator.
    /// Safe to call repeatedly; each call replaces the previous identity.
    public func setIdentity(
        _ identity: ConsentedIdentity,
        pngBytes: Data,
        runtimeVersion: String = FaceReenactor.runtimeVersion
    ) async throws {
        // Build the new actor first; if it throws, the existing reenactor stays in place.
        let next = try FaceReenactor(
            identity: identity,
            pngBytes: pngBytes,
            runtimeVersion: runtimeVersion
        )
        // Replace the slot under queue isolation. `withCheckedContinuation` keeps the swap
        // visible to any concurrent `apply()` call without sprinkling locks.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.reenactor = next
                cont.resume()
            }
        }
    }

    /// Drop any currently-loaded identity. Used by the Settings UI's "Unload" action and by tests.
    public func clearIdentity() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.reenactor = nil
                cont.resume()
            }
        }
    }

    /// True if a verified identity is currently loaded.
    public var hasIdentity: Bool {
        queue.sync { reenactor != nil }
    }

    /// v0.8.0 lip-sync overlay support: surface the current reenactor's `StylizedHeadModel` so the
    /// orchestrator can re-deform the mesh after merging mouth-region overlay coefficients.
    /// Returns nil when no identity is loaded (pass-through state). The model itself is a value-
    /// typed read on a `Sendable` immutable object — safe to hand across actor boundaries.
    public func currentModel() async -> StylizedHeadModel? {
        let captured: FaceReenactor? = queue.sync { reenactor }
        guard let actor = captured else { return nil }
        return await actor.model
    }

    /// Apply the stage to a single landmark frame. Pass-through (returns a `ReenactedFrame` with
    /// `frame: nil`) when no identity is loaded — does NOT throw. The pipeline contract is that
    /// missing-identity is a normal state (Mirror style still works), not an error.
    public func apply(_ landmarkFrame: LandmarkFrame) async -> ReenactedFrame {
        let captured: FaceReenactor? = queue.sync { reenactor }
        guard let actor = captured else {
            return ReenactedFrame(
                frameID: landmarkFrame.frameID,
                hostTimeNs: landmarkFrame.hostTimeNs,
                frame: nil,
                identityActive: false
            )
        }
        let f = await actor.reenact(landmarkFrame)
        return ReenactedFrame(
            frameID: landmarkFrame.frameID,
            hostTimeNs: landmarkFrame.hostTimeNs,
            frame: f,
            identityActive: true
        )
    }
}

// MARK: - LandmarkFrame import

// `LandmarkFrame` lives in MirrorMeshCore; this re-export keeps consumers from needing to
// import both modules when they only want the stage's surface.
@_exported import struct MirrorMeshCore.LandmarkFrame
