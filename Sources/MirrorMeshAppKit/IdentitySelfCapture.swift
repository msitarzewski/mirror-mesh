import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CryptoKit
import Vision
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshWatermark

/// One-click self-capture identity mint (v1.1.0).
///
/// The auto-provisioned default `.mmid` (see `DefaultIdentityProvider`) ships a 1×1
/// transparent PNG: enough to satisfy the bundle/signature gate, but useless as a
/// LivePortrait source. This helper closes that gap by:
///
///   1. Grabbing the latest `CapturedFrame` from the live camera
///   2. Running Apple Vision (`VNDetectFaceRectanglesRequest`) to find the head
///   3. Expanding the bounding box ~25 % each side so the crop is a head, not a
///      tight face — LivePortrait expects scalp + chin in the 256² source image.
///   4. Center-squaring the expansion and clamping to image bounds
///   5. Lanczos-resampling to exactly 256×256 RGBA PNG bytes
///   6. Minting a fresh `self-as-source` `ConsentedIdentity`, signing canonical(json)
///      || PNG with a new Ed25519 keypair, and writing the bundle to
///      `~/Library/Application Support/MirrorMesh/default.mmid` (overwrite-on-success)
///   7. Returning `(verified ConsentedIdentity, PNG bytes)` so the caller can hot-
///      swap the running pipeline via `Pipeline.setConsentedIdentity(_:pngBytes:)`.
///
/// **R1**: this path mints a `selfAsSource` bundle exclusively. The user IS the
/// subject of their own image; we never call this for `.consentedThirdParty` —
/// that path stays gated behind the `mirrormesh-consent` CLI's `--consent-confirm`
/// literal phrase.
///
/// **R12**: the watermark, visible badge, and audible chirp policies are unchanged
/// by this entry point; we only swap the source image the pipeline reenacts from.
@MainActor
public enum IdentitySelfCapture {

    // MARK: - Errors

    public enum CaptureError: Error, CustomStringConvertible {
        /// No `CapturedFrame` was available (live capture hasn't produced a frame yet
        /// — Mirror or live preview must be running).
        case noFrameAvailable
        /// Vision returned zero face observations on the supplied frame. Surface to UI
        /// so the user knows to face the camera and try again.
        case noFaceDetected
        /// CoreImage / CGImage / NSBitmapImageRep step failed. The associated message
        /// names the stage that broke so we can grep on it during incident triage.
        case imageConversionFailed(String)
        /// Signing or persisting the bundle failed. Wraps the underlying error string.
        case mintFailed(String)

        public var description: String {
            switch self {
            case .noFrameAvailable:
                return "IdentitySelfCapture: no live frame available. Start a session and face the camera."
            case .noFaceDetected:
                return "IdentitySelfCapture: no face detected in the current frame. Face the camera and try again."
            case .imageConversionFailed(let m):
                return "IdentitySelfCapture: image conversion failed (\(m))"
            case .mintFailed(let m):
                return "IdentitySelfCapture: mint failed (\(m))"
            }
        }
    }

    // MARK: - Tunables

    /// Fraction of the Vision bbox to add on each side before center-squaring. 0.25
    /// is the value LivePortrait's reference preprocessing uses for head crops — it
    /// pulls in the hairline and chin without including too much background.
    static let bboxPaddingFraction: CGFloat = 0.25

    /// LivePortrait's source-image resolution. The motion/warp/generator graph is
    /// trained on 256² inputs; anything else burns time on resize and risks aliasing.
    static let outputSize: Int = 256

    /// Default location where the auto-provisioned bundle lives. Mirrors
    /// `DefaultIdentityProvider.bundleURL()` so capture-as-identity *replaces* the
    /// auto-provisioned bundle on disk (and so subsequent launches re-load it).
    ///
    /// `nonisolated` so it's usable as a default parameter expression on
    /// `mintFromFrame`. The underlying FileManager calls are thread-safe; pinning
    /// this to the main actor would cost us nothing but a verbose call site.
    public nonisolated static func defaultBundleURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MirrorMesh", isDirectory: true)
            .appendingPathComponent("default.mmid", isDirectory: true)
    }

    // MARK: - Public API

    /// Mint a fresh self-as-source `.mmid` from the supplied captured frame.
    ///
    /// - Parameters:
    ///   - captured: The latest `CapturedFrame` from `PipelineViewModel.latestCapturedFrame`.
    ///   - displayName: Human-readable name embedded in the bundle JSON. Defaults to
    ///                  `NSFullUserName()` (the macOS account's full name) which is
    ///                  what the operator likely wants. Pass an empty string and we
    ///                  fall back to "Self capture" so the bundle is never anonymous.
    ///   - persistTo: Bundle directory to write. Defaults to `defaultBundleURL()`.
    ///   - runtimeVersion: Scope baseline for verification. Defaults to the running
    ///                     `MirrorMeshCore.version` so the freshly-minted bundle is
    ///                     guaranteed to verify against the current runtime.
    /// - Returns: `(verified ConsentedIdentity, PNG bytes)`. Both are also written to
    ///            `persistTo` on success.
    public static func mintFromFrame(
        _ captured: CapturedFrame,
        displayName: String = NSFullUserName(),
        persistTo url: URL = IdentitySelfCapture.defaultBundleURL(),
        runtimeVersion: String = MirrorMeshCore.version
    ) async throws -> (ConsentedIdentity, Data) {
        // 1) Convert the CVPixelBuffer → CGImage so Vision and CoreImage can chew on it.
        let cgImage = try cgImage(from: captured.pixelBuffer)

        // 2) Run Apple Vision face-rectangle detection. We pick the largest face
        //    (Vision returns observations sorted by confidence, but largest is the
        //    better policy for a self-capture UX — operator's face is usually framed
        //    bigger than any incidental bystander).
        let bbox = try await detectLargestFaceBoundingBox(in: cgImage)

        // 3) Expand by `bboxPaddingFraction`, center-square, clamp to image bounds.
        //    This is the head-crop heuristic LivePortrait expects.
        let cropRect = expandedAndSquaredCrop(
            faceBoundingBox: bbox,
            imageSize: CGSize(width: cgImage.width, height: cgImage.height)
        )

        // 4) Crop + Lanczos-resize to 256×256 → PNG (RGBA8).
        let pngBytes = try cropResizeAndEncodePNG(
            source: cgImage,
            crop: cropRect,
            targetSize: outputSize
        )

        // 5) Mint + persist. The persist path verifies the resulting bundle before
        //    returning so we never hand back an unsigned/invalid pair.
        let safeName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Self capture"
            : displayName
        do {
            return try mintAndPersist(
                pngBytes: pngBytes,
                displayName: safeName,
                bundleURL: url,
                runtimeVersion: runtimeVersion
            )
        } catch {
            throw CaptureError.mintFailed("\(error)")
        }
    }

    // MARK: - Vision

    /// Run `VNDetectFaceRectanglesRequest` and return the largest face's bounding box.
    ///
    /// Vision uses a **normalized, origin-bottom-left** coordinate space (CoreGraphics
    /// convention). We return the bbox unchanged here; the bbox→image-space conversion
    /// is centralized in `expandedAndSquaredCrop` so the math lives in one place.
    private static func detectLargestFaceBoundingBox(in cgImage: CGImage) async throws -> CGRect {
        try await withCheckedThrowingContinuation { cont in
            let request = VNDetectFaceRectanglesRequest { req, err in
                if let err {
                    cont.resume(throwing: CaptureError.imageConversionFailed("Vision: \(err)"))
                    return
                }
                let obs = (req.results as? [VNFaceObservation]) ?? []
                guard !obs.isEmpty else {
                    cont.resume(throwing: CaptureError.noFaceDetected)
                    return
                }
                // Why "largest" not "highest-confidence": for a self-capture UX, the
                // operator's face fills the frame; any bystander is geometrically smaller.
                // Picking by area matches user intent better than picking by confidence.
                let largest = obs.max { lhs, rhs in
                    lhs.boundingBox.width * lhs.boundingBox.height
                        < rhs.boundingBox.width * rhs.boundingBox.height
                }!
                cont.resume(returning: largest.boundingBox)
            }
            // Why .up: CGImage comes out of `cgImage(from:)` already in display
            // orientation (we render through CIContext without applying any transform).
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: CaptureError.imageConversionFailed("Vision handler: \(error)"))
            }
        }
    }

    /// Convert a Vision bbox (normalized, bottom-left) into an image-space pixel rect,
    /// expanded by `bboxPaddingFraction` on each side, then center-squared and clamped
    /// to image bounds.
    ///
    /// Visible to tests so the math can be exercised without spinning up Vision.
    /// `nonisolated` because it's pure CGRect math with no shared state — keeping
    /// it on the main actor would force every test call site to `await`.
    nonisolated static func expandedAndSquaredCrop(
        faceBoundingBox bbox: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let w = imageSize.width
        let h = imageSize.height

        // 1) Vision bbox → pixel rect, flipping Y from bottom-left to top-left so the
        //    output is directly usable with CGImage.cropping(to:) downstream.
        let pixelRect = CGRect(
            x: bbox.origin.x * w,
            y: (1.0 - bbox.origin.y - bbox.height) * h,
            width: bbox.width * w,
            height: bbox.height * h
        )

        // 2) Expand by padding fraction in all four directions.
        let padX = pixelRect.width * bboxPaddingFraction
        let padY = pixelRect.height * bboxPaddingFraction
        var expanded = pixelRect.insetBy(dx: -padX, dy: -padY)

        // 3) Center-square. LivePortrait wants a square head crop; un-squared crops
        //    deform aspect on the 256² resize.
        let side = max(expanded.width, expanded.height)
        let cx = expanded.midX
        let cy = expanded.midY
        expanded = CGRect(
            x: cx - side / 2,
            y: cy - side / 2,
            width: side,
            height: side
        )

        // 4) Clamp to image bounds. If the head is near an edge we slide the square
        //    inward rather than shrinking it — a smaller crop hurts quality more than
        //    a slightly off-center one.
        if expanded.minX < 0 { expanded.origin.x = 0 }
        if expanded.minY < 0 { expanded.origin.y = 0 }
        if expanded.maxX > w { expanded.origin.x = w - expanded.width }
        if expanded.maxY > h { expanded.origin.y = h - expanded.height }
        // If after sliding we're still over-large (the image itself is smaller than
        // the desired crop), shrink to fit. The result is still square because we
        // shrink the leading edge symmetrically.
        if expanded.width > w || expanded.height > h {
            let fit = min(w, h)
            expanded = CGRect(
                x: (w - fit) / 2,
                y: (h - fit) / 2,
                width: fit,
                height: fit
            )
        }

        // Final: integer-align so CGImage cropping is exact-pixel.
        return CGRect(
            x: expanded.origin.x.rounded(.down),
            y: expanded.origin.y.rounded(.down),
            width: expanded.width.rounded(.down),
            height: expanded.height.rounded(.down)
        )
    }

    // MARK: - Image conversion

    /// Convert a `CVPixelBuffer` (any of the formats the capture stack emits — BGRA,
    /// YUV 4:2:0, etc.) into a CGImage usable by Vision and the crop/resize path.
    ///
    /// We funnel through `CIContext` because it's the only path that handles every
    /// pixel format Apple's camera stack hands us without special-casing each one.
    private static func cgImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.imageConversionFailed("CIContext.createCGImage returned nil")
        }
        return cg
    }

    /// Crop `source` to `crop`, Lanczos-resample to `targetSize × targetSize`, and
    /// PNG-encode the result. Lanczos preserves high-frequency detail (hair, eyelashes)
    /// far better than the default bilinear; the downstream LivePortrait warp+generator
    /// graph notices the difference at 256².
    private static func cropResizeAndEncodePNG(
        source: CGImage,
        crop: CGRect,
        targetSize: Int
    ) throws -> Data {
        // 1) Crop.
        guard let cropped = source.cropping(to: crop) else {
            throw CaptureError.imageConversionFailed("CGImage.cropping returned nil for rect \(crop)")
        }

        // 2) Lanczos resize via CoreImage. The Lanczos filter accepts a scale factor;
        //    we pass scale = targetSize / cropWidth and let it figure aspect (the crop
        //    is square by construction).
        let ciCropped = CIImage(cgImage: cropped)
        let scale = CGFloat(targetSize) / CGFloat(cropped.width)
        let resizeFilter = CIFilter.lanczosScaleTransform()
        resizeFilter.inputImage = ciCropped
        resizeFilter.scale = Float(scale)
        resizeFilter.aspectRatio = 1.0
        guard let resized = resizeFilter.outputImage else {
            throw CaptureError.imageConversionFailed("Lanczos filter returned nil output")
        }

        // 3) Render to a CGImage at exactly `targetSize × targetSize`. Forcing the
        //    extent here guards against the half-pixel padding the resize filter
        //    sometimes adds.
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let outRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        guard let resizedCG = ctx.createCGImage(resized, from: outRect) else {
            throw CaptureError.imageConversionFailed("CIContext.createCGImage post-resize returned nil")
        }

        // 4) PNG-encode via NSBitmapImageRep. Same path AppKit uses internally for
        //    "save as PNG" — handles colorspace conversion to sRGB and writes a
        //    standards-compliant 8-bit RGBA file.
        let bitmap = NSBitmapImageRep(cgImage: resizedCG)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.imageConversionFailed("NSBitmapImageRep.representation(.png) returned nil")
        }
        return pngData
    }

    // MARK: - Mint + persist

    /// Same shape as `DefaultIdentityProvider.mintAndPersist`, but parameterized on the
    /// caller-supplied PNG bytes (the head crop, not the 1×1 placeholder) and display
    /// name. Mirrors the CLI's `buildAndWriteBundle` flow.
    private static func mintAndPersist(
        pngBytes: Data,
        displayName: String,
        bundleURL: URL,
        runtimeVersion: String
    ) throws -> (ConsentedIdentity, Data) {
        let pngHash = SHA256.hash(data: pngBytes).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: displayName,
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: "v0.6+",
            issuer_public_key_b64: pubB64
        )

        // Sign canonical(identity-without-signature) || pngBytes — same input the
        // verifier hashes and checks at load time. Identical encoding strategy as
        // `DefaultIdentityProvider.mintAndPersist` and the CLI.
        var clearable = identity
        clearable.signature_b64 = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var message = try enc.encode(clearable)
        message.append(pngBytes)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()

        // Ensure parent exists, then write atomically over any existing bundle.
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // ConsentedIdentityBundle.write overwrites identity.json and source.png in
        // the target dir; the dir itself doesn't need to be cleared first.
        try ConsentedIdentityBundle.write(identity: identity, pngBytes: pngBytes, to: bundleURL)

        // Re-read + verify so we never return an unsigned/invalid pair.
        let (verified, verifiedPng) = try ConsentedIdentityBundle.read(from: bundleURL)
        try ConsentedIdentityVerifier.verify(
            identity: verified,
            pngBytes: verifiedPng,
            runtimeVersion: runtimeVersion
        )
        return (verified, verifiedPng)
    }
}
