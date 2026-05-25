import Foundation
import CoreGraphics
import CoreVideo
import MirrorMeshCore
import MirrorMeshReenact
import MirrorMeshWatermark

// =============================================================================
// PhotorealStage — pipeline-side wrapper around `PhotorealBackend`
// =============================================================================
//
// This stage mirrors the shape of `ReenactStage` and `VoiceStage` (final class,
// @unchecked Sendable, serial-queue guarded). The pipeline orchestrator owns
// one instance per `Pipeline.run()` and tears it down alongside the frame
// source. It owns:
//
//   • a `PhotorealBackend?` slot, loaded lazily on `setIdentity`
//   • a serial dispatch queue that guards the slot against concurrent
//     setIdentity / apply / clear traffic
//
// Why a `final class` not an `actor`: `PhotorealBackend` is itself an actor.
// Wrapping it in a second actor would double the hop. The stage owns one
// mutable slot — a serial queue + final class lets the orchestrator drive it
// without an extra await on the slot lookup. Mirrors `ReenactStage`'s pattern
// at Sources/MirrorMeshReenact/ReenactStage.swift:137.
//
// Lifecycle invariants:
//   • `setIdentity` is gated by R1: stylized-non-human schemes are refused
//     before the backend is even constructed. Photoreal == real face only.
//   • A failed `setIdentity` leaves any previously-loaded backend in place
//     (just like `ReenactStage.setIdentity`).
//   • `apply` is the hot path: it MUST swallow `reenact` errors and emit a
//     telemetry warning rather than propagating, so a transient model failure
//     (CoreML output decode hiccup, momentary pixel-format mismatch) cannot
//     kill the pipeline. Returns nil on any failure → caller falls back to
//     the original captured frame.
//   • `apply` returns nil when no identity is loaded — pass-through is the
//     normal state, not an error, just like ReenactStage.

/// Pipeline-side photoreal reenactment stage. Wraps `PhotorealBackend` so the
/// orchestrator doesn't have to know about CoreML, mlpackages, or the
/// identity-load gate.
///
/// **Substitution contract**: `apply(_:)` returns a `CVPixelBuffer` ready to
/// be substituted for the camera frame's pixel buffer (the BGRA face crop the
/// pipeline hands to the renderer). When the stage returns nil, the pipeline
/// keeps the original captured frame.
public final class PhotorealStage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mirrormesh.photoreal.stage")
    private var backend: PhotorealBackend?

    public init() {}

    /// Load and verify an identity bundle. Throws on rejection — the caller
    /// (Pipeline or Settings UI) is responsible for surfacing the error to the
    /// operator. Safe to call repeatedly; each call replaces the previous
    /// backend. On failure, the prior backend (if any) stays loaded.
    ///
    /// R1 gate: stylized-non-human identities are refused immediately — these
    /// belong on `FaceReenactor`'s procedural path, never on a photoreal
    /// generator. The check happens here so a misconfigured Settings panel
    /// can't even attempt to load weights for an animal/cartoon "subject".
    public func setIdentity(
        _ identity: ConsentedIdentity,
        pngBytes: Data,
        modelsDir: URL,
        runtimeVersion: String
    ) async throws {
        // R1 — refuse stylized-non-human at the stage layer. PhotorealBackend
        // also refuses (its scheme gate is identical) but surfacing the refusal
        // here means we never construct the actor and never call the verifier
        // for a scheme that doesn't belong on this path.
        guard identity.scheme == .selfAsSource || identity.scheme == .consentedThirdParty else {
            throw PhotorealBackend.LoadError.identityNotVerified
        }
        // Build the new backend; if init throws, the existing slot is untouched.
        let next = try await PhotorealBackend(
            identity: identity,
            pngBytes: pngBytes,
            runtimeVersion: runtimeVersion,
            modelsDir: modelsDir,
            kind: .liveportrait
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.backend = next
                cont.resume()
            }
        }
    }

    /// Drop any currently-loaded backend. Used by the Settings UI's "Unload"
    /// action and by tests. Idempotent.
    public func clearIdentity() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.backend = nil
                cont.resume()
            }
        }
    }

    /// True iff a verified PhotorealBackend is currently loaded.
    /// `async` because the underlying slot is queue-guarded; the cost is a
    /// queue hop, same shape as `VoiceStage.isActive`.
    public var hasIdentity: Bool {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async {
                    cont.resume(returning: self.backend != nil)
                }
            }
        }
    }

    /// Drive the photoreal backend with one captured frame.
    ///
    /// Returns:
    ///   • a substituted `CVPixelBuffer` when a backend is loaded AND the
    ///     reenact call succeeded — callers replace `captured.pixelBuffer`
    ///     with this and pass the new frame downstream.
    ///   • `nil` when no backend is loaded (pass-through state) OR when the
    ///     backend threw (logged as telemetry warning; caller falls back to
    ///     the original frame).
    ///
    /// `faceBoundingBoxNorm` is the Vision-normalized face bbox for this frame
    /// (origin bottom-left, [0,1] coords — the shape `landmarks.faceBoundingBoxNorm`
    /// emits). When non-nil, the driver pixel buffer is pre-cropped to the
    /// padded-and-squared head region before being handed to the backend; when
    /// nil, the backend's internal center-crop applies — the legacy path,
    /// which works on already-tight inputs but produces incoherent output on
    /// wide camera frames (the 2026-05-20 bug).
    ///
    /// Errors are swallowed by design: a transient model failure must not
    /// kill the live pipeline. Render falls back to the stylized 3D head
    /// for that frame, and the next frame retries.
    public func apply(
        _ captured: CapturedFrame,
        faceBoundingBoxNorm: CGRect? = nil
    ) async -> CVPixelBuffer? {
        let captured_backend: PhotorealBackend? = await withCheckedContinuation {
            (cont: CheckedContinuation<PhotorealBackend?, Never>) in
            queue.async { cont.resume(returning: self.backend) }
        }
        guard let backend = captured_backend else {
            return nil
        }

        // Pre-crop the driver to the head region when we have a face bbox.
        // Without this, PhotorealBackend.reenact's internal center-crop turns
        // a 1280×720 camera frame into a 720×720 square that includes far
        // more shoulders/background than face, and LP's motion extractor
        // produces incoherent keypoints from the resulting low face-coverage
        // input. The bench fixtures (Tests/MirrorMeshReenactTests/fixtures/lp_diff/)
        // show this conclusively — cropped face → coherent reenactment;
        // uncropped portrait → garbled output.
        let driver: CVPixelBuffer
        if let bbox = faceBoundingBoxNorm {
            do {
                let srcW = CGFloat(CVPixelBufferGetWidth(captured.pixelBuffer))
                let srcH = CGFloat(CVPixelBufferGetHeight(captured.pixelBuffer))
                let cropRect = PixelBufferConversion.expandedAndSquaredCrop(
                    faceBoundingBoxNorm: bbox,
                    imageSize: CGSize(width: srcW, height: srcH)
                )
                driver = try PixelBufferConversion.cropped(captured.pixelBuffer, to: cropRect)
            } catch {
                // Crop failed — fall back to the raw frame rather than skip the
                // frame entirely. The backend's center-crop is suboptimal but not
                // worse than dropping a frame. Surface the failure for diagnosis.
                await Telemetry.shared.emit(.warning(
                    stage: .render,
                    message: "photoreal face-crop failed (frame=\(captured.frameID)): \(error); falling back to center-crop"
                ))
                driver = captured.pixelBuffer
            }
        } else {
            driver = captured.pixelBuffer
        }

        do {
            return try await backend.reenact(driver: driver)
        } catch {
            // R12: never silently substitute a buffer the model didn't produce.
            // Surface the failure as telemetry and return nil so the renderer
            // falls back to the stylized path for this frame.
            await Telemetry.shared.emit(.warning(
                stage: .render,
                message: "photoreal reenact failed (frame=\(captured.frameID)): \(error)"
            ))
            return nil
        }
    }
}

// MARK: - CapturedFrame substitution helper

extension CapturedFrame {
    /// Returns a copy of this `CapturedFrame` with `pixelBuffer` swapped for
    /// the supplied buffer. `frameID`, `hostTimeNs`, `width`, and `height`
    /// are preserved unchanged so downstream telemetry / signposts / manifest
    /// accounting still attribute the substituted frame to the original
    /// capture event.
    ///
    /// Used by `Pipeline` to feed a photoreal-reenacted buffer to the
    /// renderer while keeping the frame's lineage intact (R12: the
    /// watermarker still signs whatever we hand it; substituting upstream
    /// of render means the substituted face is the thing that gets signed,
    /// which is exactly the contract — the manifest binds to the rendered
    /// output, not the raw camera bytes).
    public func with(pixelBuffer newBuffer: CVPixelBuffer) -> CapturedFrame {
        CapturedFrame(
            frameID: self.frameID,
            hostTimeNs: self.hostTimeNs,
            pixelBuffer: newBuffer,
            width: self.width,
            height: self.height
        )
    }
}
