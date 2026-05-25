import Testing
import Foundation
import CoreVideo
import CoreImage
@testable import MirrorMeshReenact

// Coverage for the face-bbox crop helpers in `PixelBufferConversion`. These
// are the pieces that the 2026-05-20 photoreal failure was missing on the
// driver side — see Tests/MirrorMeshReenactTests/fixtures/lp_diff/README.md
// for the bench evidence and `memory project_photoreal_v2_plan.md` for context.
//
// The math here intentionally mirrors `IdentitySelfCapture.expandedAndSquaredCrop`
// in MirrorMeshAppKit so the *source* path (capture-as-identity) and *driver*
// path (live pipeline) crop the same way. Tests here pin that lockstep so a
// future drift between the two implementations breaks loudly.

@Suite("PixelBufferConversion face-box crop")
struct FaceBoxCropTests {

    @Test func expandedCropExpandsByPaddingFraction() {
        // Vision bbox: centered 50%×50% face, normalized. Using powers-of-2-friendly
        // values (0.25, 0.5) so the Y-flip math (1.0 - 0.25 - 0.5 = 0.25) is exact
        // in IEEE 754 — avoids 1-pixel floating-point drift from .3 + .4 + 1.0 paths.
        let bbox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let imageSize = CGSize(width: 1000, height: 1000)
        let crop = PixelBufferConversion.expandedAndSquaredCrop(
            faceBoundingBoxNorm: bbox,
            imageSize: imageSize,
            paddingFraction: 0.25
        )
        // Pixel-space face rect: x=250, y=250 (after Y-flip), w=500, h=500.
        // Pad ±25% of 500 → ±125 each side. Expected expanded rect: x=125, y=125, side=750.
        #expect(crop.width == 750)
        #expect(crop.height == 750)
        #expect(crop.origin.x == 125)
        #expect(crop.origin.y == 125)
    }

    @Test func expandedCropStaysInsideImageBounds() {
        // Face hugging the top-right corner; the padded square would go off the
        // right/top edges. Crop should slide inward, preserving size.
        let bbox = CGRect(x: 0.7, y: 0.7, width: 0.3, height: 0.3)
        let imageSize = CGSize(width: 1000, height: 1000)
        let crop = PixelBufferConversion.expandedAndSquaredCrop(
            faceBoundingBoxNorm: bbox,
            imageSize: imageSize,
            paddingFraction: 0.25
        )
        #expect(crop.minX >= 0)
        #expect(crop.minY >= 0)
        #expect(crop.maxX <= imageSize.width)
        #expect(crop.maxY <= imageSize.height)
        // Sliding-not-shrinking means width/height stay at the padded side length.
        let padded = 300 + 2 * Int(300 * 0.25)
        #expect(Int(crop.width) == padded)
        #expect(Int(crop.height) == padded)
    }

    @Test func expandedCropShrinksWhenImageIsSmallerThanDesired() {
        // Image smaller than the desired padded square — must fall back to centered max-square.
        let bbox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let imageSize = CGSize(width: 100, height: 200)
        let crop = PixelBufferConversion.expandedAndSquaredCrop(
            faceBoundingBoxNorm: bbox,
            imageSize: imageSize,
            paddingFraction: 0.25
        )
        // Fall-back centered square = min(w, h) = 100.
        #expect(crop.width == 100)
        #expect(crop.height == 100)
        #expect(crop.minX >= 0)
        #expect(crop.minY >= 0)
    }

    @Test func croppedReturnsBufferOfExactRequestedDimensions() throws {
        // Allocate a 256×128 BGRA buffer, crop a 64×64 region, verify the output
        // is exactly 64×64 (not the source's full size).
        let src = try makeTestBuffer(width: 256, height: 128)
        let rect = CGRect(x: 32, y: 16, width: 64, height: 64)
        let cropped = try PixelBufferConversion.cropped(src, to: rect)
        #expect(CVPixelBufferGetWidth(cropped) == 64)
        #expect(CVPixelBufferGetHeight(cropped) == 64)
    }

    @Test func croppedZeroAreaRectThrows() throws {
        let src = try makeTestBuffer(width: 64, height: 64)
        do {
            _ = try PixelBufferConversion.cropped(src, to: CGRect(x: 0, y: 0, width: 0, height: 0))
            Issue.record("expected zero-area crop to throw")
        } catch is PixelBufferConversionError {
            // expected
        }
    }

    // MARK: - Helpers

    private func makeTestBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &out
        )
        guard status == kCVReturnSuccess, let buf = out else {
            throw PixelBufferConversionError.pixelBufferCreateFailed(status)
        }
        return buf
    }
}
