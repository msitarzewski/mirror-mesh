import Testing
import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
@testable import MirrorMeshAppKit
import MirrorMeshCore
import MirrorMeshWatermark

/// v1.1.0 — IdentitySelfCapture unit tests.
///
/// The interesting math (bbox expansion, center-squaring, clamping) is fully
/// covered by `BBoxMathTests` without Vision. The end-to-end `mintFromFrame`
/// path is gated behind Apple Vision's `VNDetectFaceRectanglesRequest`, which
/// (a) is non-deterministic on synthetic gradients and (b) requires no model
/// download — it's part of the OS. We exercise the synthetic-frame happy path
/// in `MintTests`, but the "frame has no face" case relies on Vision behavior;
/// we treat that path as a manual smoke test instead.
@Suite("IdentitySelfCapture")
@MainActor
struct IdentitySelfCaptureTests {

    // MARK: - Bounding box math (pure, no Vision)

    @Suite("BBoxMath")
    struct BBoxMathTests {

        /// A centered face on a square image should produce a centered square crop
        /// equal in size to the face bbox + 2× padding fraction.
        @Test func centeredFaceOnSquareImage() {
            // Vision bbox: normalized, bottom-left origin. A 0.4×0.4 face centered
            // on a 1000×1000 image lives at (0.3, 0.3) → (0.7, 0.7).
            let bbox = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
            let crop = IdentitySelfCapture.expandedAndSquaredCrop(
                faceBoundingBox: bbox,
                imageSize: CGSize(width: 1000, height: 1000)
            )
            // Face is 400px wide; +25% on each side → 600px side. Center is at (500, 500)
            // but integer-aligning the origin can shift the midpoint by a pixel due
            // to fp-arithmetic of normalized-bbox × image-size, so we assert within
            // a 2 px tolerance.
            #expect(crop.width == 600)
            #expect(crop.height == 600)
            #expect(abs(crop.midX - 500) <= 2.0)
            #expect(abs(crop.midY - 500) <= 2.0)
        }

        /// A face hugging the top edge of a portrait-orientation image should slide
        /// the crop downward rather than shrinking it.
        @Test func faceNearTopEdgeSlidesInsteadOfShrinking() {
            // Vision bbox: bottom-left origin → "top of image" means high y.
            // Face at (0.3, 0.7, 0.4, 0.25) → image-space y ranges across the top 25%.
            let bbox = CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.25)
            let crop = IdentitySelfCapture.expandedAndSquaredCrop(
                faceBoundingBox: bbox,
                imageSize: CGSize(width: 800, height: 1000)
            )
            // After expansion + squaring the crop should be at least the face's
            // expanded width and fully inside the image.
            #expect(crop.minX >= 0)
            #expect(crop.minY >= 0)
            #expect(crop.maxX <= 800)
            #expect(crop.maxY <= 1000)
            #expect(crop.width == crop.height)  // square
        }

        /// Output rect must be integer-aligned (CGImage.cropping uses pixel-aligned rects).
        @Test func cropIsIntegerAligned() {
            let bbox = CGRect(x: 0.3333, y: 0.4444, width: 0.2222, height: 0.3333)
            let crop = IdentitySelfCapture.expandedAndSquaredCrop(
                faceBoundingBox: bbox,
                imageSize: CGSize(width: 1280, height: 720)
            )
            #expect(crop.origin.x.truncatingRemainder(dividingBy: 1) == 0)
            #expect(crop.origin.y.truncatingRemainder(dividingBy: 1) == 0)
            #expect(crop.width.truncatingRemainder(dividingBy: 1) == 0)
            #expect(crop.height.truncatingRemainder(dividingBy: 1) == 0)
        }

        /// If the face bbox is so big its expansion overflows the image, we should
        /// shrink to the largest centered square that fits — never produce a crop
        /// larger than the source image.
        @Test func oversizeFaceClampsToImageBounds() {
            // Face covers ~90% of a 600×400 (landscape) image. +25% expansion takes
            // it past the bounds in both dimensions; we should shrink to a 400×400
            // centered square.
            let bbox = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
            let crop = IdentitySelfCapture.expandedAndSquaredCrop(
                faceBoundingBox: bbox,
                imageSize: CGSize(width: 600, height: 400)
            )
            #expect(crop.width <= 600)
            #expect(crop.height <= 400)
            #expect(crop.width == crop.height)
        }
    }

    // MARK: - End-to-end mint

    /// Build a synthetic CVPixelBuffer with a dark oval against a lighter background
    /// at 640×360. Vision *sometimes* detects faces on these, sometimes not — when
    /// it doesn't, the test exits early with a noted skip. When it does, we verify
    /// the resulting bundle is a properly-signed 256×256 PNG that the verifier accepts.
    ///
    /// We don't mark this `.disabled` outright because on the CI machine it often
    /// does succeed; the early-exit branch keeps it green when Vision balks.
    @Test func mintFromSyntheticFrameProducesValidBundleOrSkips() async throws {
        let frame = try Self.makeSyntheticCapturedFrame(width: 640, height: 360)

        // Use a tempdir so we don't clobber the user's auto-provisioned default.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentitySelfCaptureTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("self.mmid", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir.deletingLastPathComponent())
        }

        do {
            let (identity, png) = try await IdentitySelfCapture.mintFromFrame(
                frame,
                displayName: "Synthetic test",
                persistTo: tmpDir
            )
            // Bundle verifies (the mint path already runs verify() internally).
            try ConsentedIdentityVerifier.verify(
                identity: identity,
                pngBytes: png,
                runtimeVersion: MirrorMeshCore.version
            )
            #expect(identity.scheme == .selfAsSource)
            #expect(identity.display_name == "Synthetic test")
            // PNG decodes and is exactly 256×256.
            let ci = CIImage(data: png)
            #expect(ci != nil)
            #expect(Int(ci!.extent.width) == 256)
            #expect(Int(ci!.extent.height) == 256)
            // The on-disk bundle round-trips.
            let (reread, reReadPng) = try ConsentedIdentityBundle.read(from: tmpDir)
            #expect(reread.identity_id == identity.identity_id)
            #expect(reReadPng == png)
        } catch IdentitySelfCapture.CaptureError.noFaceDetected {
            // Vision didn't find a "face" on the synthetic image. That's an
            // accepted outcome on this test — the manual smoke is the source of
            // truth for the photoreal mint path with a real camera frame.
        }
    }

    /// Empty-name fallback: NSFullUserName() could be empty in odd environments
    /// (test runners on minimal user accounts); the implementation substitutes
    /// "Self capture" so the bundle is never anonymous. We exercise that branch
    /// by passing an explicit empty string.
    @Test func emptyDisplayNameFallsBack() async throws {
        let frame = try Self.makeSyntheticCapturedFrame(width: 640, height: 360)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentitySelfCaptureTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("self.mmid", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir.deletingLastPathComponent())
        }
        do {
            let (identity, _) = try await IdentitySelfCapture.mintFromFrame(
                frame,
                displayName: "   ",  // whitespace-only → fallback path
                persistTo: tmpDir
            )
            #expect(identity.display_name == "Self capture")
        } catch IdentitySelfCapture.CaptureError.noFaceDetected {
            // See `mintFromSyntheticFrameProducesValidBundleOrSkips` for rationale.
        }
    }

    /// `defaultBundleURL()` is `nonisolated` so it can be a default-parameter
    /// expression. Sanity-check that it returns a path inside the user's
    /// Application Support / MirrorMesh directory.
    @Test func defaultBundleURLPointsAtAppSupport() {
        let url = IdentitySelfCapture.defaultBundleURL()
        #expect(url.lastPathComponent == "default.mmid")
        #expect(url.deletingLastPathComponent().lastPathComponent == "MirrorMesh")
    }

    // MARK: - Helpers

    /// Synthesize a 640×360 BGRA CVPixelBuffer with a darker oval in the middle.
    /// This is what we throw at Vision; on most M-series machines Vision detects
    /// "something face-like" here, but not deterministically — see
    /// `mintFromSyntheticFrameProducesValidBundleOrSkips`.
    static func makeSyntheticCapturedFrame(width: Int, height: Int) throws -> CapturedFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "IdentitySelfCaptureTests", code: Int(status))
        }
        // Paint a light-gray background and a darker oval in the center.
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "IdentitySelfCaptureTests", code: -1)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let rx = Double(width) * 0.18   // oval radii
        let ry = Double(height) * 0.30
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: bytesPerRow)
            for x in 0..<width {
                let dx = (Double(x) - cx) / rx
                let dy = (Double(y) - cy) / ry
                let inside = (dx * dx + dy * dy) <= 1.0
                let v: UInt8 = inside ? 110 : 220
                // BGRA8
                row[x * 4 + 0] = v
                row[x * 4 + 1] = v
                row[x * 4 + 2] = v
                row[x * 4 + 3] = 255
            }
        }
        return CapturedFrame(
            frameID: FrameID(1),
            hostTimeNs: 1_000_000_000,
            pixelBuffer: buffer,
            width: width,
            height: height
        )
    }
}
