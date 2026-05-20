import Foundation
import CoreVideo
import CoreImage
import CoreML
import Accelerate

/// Errors surfaced by the CVPixelBuffer <-> MLMultiArray conversion helpers used by the
/// photoreal inference path. Separate from `PhotorealBackend.LoadError` so callers can
/// distinguish "the model gate failed" from "we couldn't marshal the frame in/out of CoreML".
public enum PixelBufferConversionError: Error, CustomStringConvertible, Sendable {
    /// CoreImage / vImage could not produce a temporary buffer for the conversion step.
    case allocationFailed(String)
    /// PNG decode failed — the bytes in the `.mmid` payload do not parse as an image.
    case pngDecodeFailed
    /// The MLMultiArray returned by the generator had a shape we did not expect.
    /// LivePortrait's SPADE decoder is hard-wired to `(1, 3, 512, 512)` at upscale=2;
    /// anything else is either a misconverted model or a future variant we don't yet
    /// support.
    case unexpectedShape(expected: [Int], got: [Int])
    /// `CVPixelBufferCreate` returned a non-success status.
    case pixelBufferCreateFailed(OSStatus)

    public var description: String {
        switch self {
        case .allocationFailed(let where_):    return "PixelBufferConversion: allocation failed in \(where_)"
        case .pngDecodeFailed:                 return "PixelBufferConversion: PNG decode failed"
        case let .unexpectedShape(expected, got):
            return "PixelBufferConversion: expected MLMultiArray shape \(expected), got \(got)"
        case .pixelBufferCreateFailed(let s):  return "PixelBufferConversion: CVPixelBufferCreate failed (status=\(s))"
        }
    }
}

/// Pure, dependency-free helpers that move pixels between the system frame format
/// (`CVPixelBuffer`, IOSurface-backed BGRA) and the format CoreML wants for the
/// LivePortrait graph (`MLMultiArray`, NCHW float32 in [0, 1]).
///
/// The helpers are `Sendable` and free-functions on an `enum` so they cross actor
/// boundaries without ceremony. They run synchronously — the caller schedules them
/// on whichever executor it wants.
public enum PixelBufferConversion {

    // ───────────────────────────────────────────────────────────────────────
    // Forward: CVPixelBuffer -> MLMultiArray (1, 3, H, W) RGB float32 in [0, 1]
    // ───────────────────────────────────────────────────────────────────────

    /// Render a `CVPixelBuffer` (any pixel format CIImage can read) into a `(1, 3, height, width)`
    /// float32 `MLMultiArray` with RGB channel order, square-center-cropped + resized to the
    /// target size, values normalized to [0, 1].
    ///
    /// Why a CoreImage intermediate: the input buffer can be BGRA, NV12, biplanar 420v, etc.
    /// `CIContext.render` collapses every case into a uniform RGBA8 readback. The Accelerate
    /// path then does the channel transpose + normalize in vectorized fp32. Net cost on M5 Max
    /// for a 256x256 readback is ~0.3 ms per frame — comfortable inside the photoreal budget.
    public static func makeMLInput(
        from pixelBuffer: CVPixelBuffer,
        targetSize: Int = 256,
        ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    ) throws -> MLMultiArray {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)

        // Square center-crop -> resize to (targetSize, targetSize). Mirrors LivePortrait's
        // `cropper.py` minimum-viable path; full landmark-driven crop is a future refinement.
        let side = min(srcW, srcH)
        let cropOriginX = (srcW - side) / 2
        let cropOriginY = (srcH - side) / 2
        let cropRect = CGRect(x: cropOriginX, y: cropOriginY, width: side, height: side)

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Translate so the crop rect's origin sits at (0, 0), then crop, then scale.
        ciImage = ciImage
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let scale = CGFloat(targetSize) / CGFloat(side)
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Materialize into a tightly-packed RGBA8 buffer we can index without locking.
        let bytesPerRow = targetSize * 4
        let totalBytes  = bytesPerRow * targetSize
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
        rgba.initialize(repeating: 0, count: totalBytes)
        defer { rgba.deallocate() }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PixelBufferConversionError.allocationFailed("CGColorSpace.sRGB")
        }
        ciContext.render(
            ciImage,
            toBitmap: rgba,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: targetSize, height: targetSize),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // Allocate the destination MLMultiArray. NCHW, float32, contiguous (row-major) layout
        // — the no-strides initializer matches the same layout we wrote above (contiguous
        // along the innermost dim). The init-with-strides overload is gated to macOS 15+ so we
        // rely on the default contiguous layout to keep the package's .macOS(.v14) floor.
        let shape: [NSNumber] = [1, 3, NSNumber(value: targetSize), NSNumber(value: targetSize)]
        let array = try MLMultiArray(shape: shape, dataType: .float32)

        // Channel transpose RGBA8 -> RGB float32, with /255 normalization. Manual loop is the
        // simplest correct path; Accelerate's vImage gets called when we add MJPEG-source paths.
        let dst = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * targetSize * targetSize)
        let plane = targetSize * targetSize
        let inv255: Float32 = 1.0 / 255.0
        for y in 0..<targetSize {
            for x in 0..<targetSize {
                let p = (y * targetSize + x) * 4
                let r = Float32(rgba[p + 0]) * inv255
                let g = Float32(rgba[p + 1]) * inv255
                let b = Float32(rgba[p + 2]) * inv255
                let i = y * targetSize + x
                dst[0 * plane + i] = r
                dst[1 * plane + i] = g
                dst[2 * plane + i] = b
            }
        }
        return array
    }

    /// Decode PNG bytes (the `.mmid` payload) and return a `(1, 3, targetSize, targetSize)` RGB
    /// float32 MLMultiArray in [0, 1]. Used by `PhotorealBackend.prepareSource(...)` to compute
    /// the cached appearance feature volume + source keypoints once per identity load.
    public static func makeMLInput(
        fromPNG pngBytes: Data,
        targetSize: Int = 256,
        ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    ) throws -> MLMultiArray {
        guard let ciImage = CIImage(data: pngBytes) else {
            throw PixelBufferConversionError.pngDecodeFailed
        }
        // Reuse the same path as the CVPixelBuffer flavor: render the PNG into a temporary
        // CVPixelBuffer at native size, then defer to the existing converter.
        let w = Int(ciImage.extent.width)
        let h = Int(ciImage.extent.height)
        guard w > 0 && h > 0 else {
            throw PixelBufferConversionError.pngDecodeFailed
        }

        var tmp: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w, h,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &tmp
        )
        guard status == kCVReturnSuccess, let buf = tmp else {
            throw PixelBufferConversionError.pixelBufferCreateFailed(status)
        }
        // CIImage extent for PNG-decoded sources sometimes has a non-zero origin
        // (rare but possible if metadata applies a transform). Recenter to (0, 0).
        let translated = ciImage.transformed(by: CGAffineTransform(
            translationX: -ciImage.extent.origin.x,
            y: -ciImage.extent.origin.y
        ))
        ciContext.render(translated, to: buf)
        return try makeMLInput(from: buf, targetSize: targetSize, ciContext: ciContext)
    }

    // ───────────────────────────────────────────────────────────────────────
    // Reverse: MLMultiArray (1, 3, H, W) RGB float32 in [0, 1] -> CVPixelBuffer (BGRA)
    // ───────────────────────────────────────────────────────────────────────

    /// Convert an RGB float32 NCHW `MLMultiArray` in [0, 1] back into a `CVPixelBuffer` (BGRA8,
    /// IOSurface-backed, Metal-compatible). Optionally downscale to `outputSize` (defaults to
    /// the source's native H/W). Values outside [0, 1] are clamped.
    ///
    /// The output buffer is freshly allocated per call. If the caller wants to recycle buffers
    /// it should pass a `pool` (the existing `PixelBufferPool` in `MirrorMeshCore`), but for v1
    /// we keep the contract simple: every call returns a new buffer the caller owns.
    public static func makePixelBuffer(
        from array: MLMultiArray,
        outputSize: Int? = nil,
        ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    ) throws -> CVPixelBuffer {
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 4, shape[0] == 1, shape[1] == 3 else {
            throw PixelBufferConversionError.unexpectedShape(
                expected: [1, 3, -1, -1],
                got: shape
            )
        }
        let srcH = shape[2]
        let srcW = shape[3]
        guard srcH > 0, srcW > 0 else {
            throw PixelBufferConversionError.unexpectedShape(expected: [1, 3, -1, -1], got: shape)
        }

        // Pack the model output as RGBA8 in a tightly-packed buffer at source resolution; we'll
        // then either return that directly as a CVPixelBuffer or let CoreImage scale it down.
        let srcBytesPerRow = srcW * 4
        let srcTotal       = srcBytesPerRow * srcH
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: srcTotal)
        rgba.initialize(repeating: 0, count: srcTotal)
        defer { rgba.deallocate() }

        let src   = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * srcH * srcW)
        let plane = srcH * srcW
        for y in 0..<srcH {
            for x in 0..<srcW {
                let i = y * srcW + x
                // Clamp [0, 1] then scale to [0, 255]. Generator emits post-sigmoid values so
                // overshoot is extremely rare in practice, but defensive clamping protects the
                // downstream watermarker from NaN propagation if a model is misconverted.
                let r = max(0.0, min(1.0, src[0 * plane + i]))
                let g = max(0.0, min(1.0, src[1 * plane + i]))
                let b = max(0.0, min(1.0, src[2 * plane + i]))
                let p = (y * srcW + x) * 4
                rgba[p + 0] = UInt8(r * 255.0)
                rgba[p + 1] = UInt8(g * 255.0)
                rgba[p + 2] = UInt8(b * 255.0)
                rgba[p + 3] = 255
            }
        }

        // Wrap the RGBA8 buffer as a CIImage we can render either at native or downscaled size.
        let target = outputSize ?? srcW
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PixelBufferConversionError.allocationFailed("CGColorSpace.sRGB")
        }
        let data = Data(bytes: rgba, count: srcTotal)
        let ci = CIImage(
            bitmapData: data,
            bytesPerRow: srcBytesPerRow,
            size: CGSize(width: srcW, height: srcH),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let scale = CGFloat(target) / CGFloat(srcW)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            target, target,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &out
        )
        guard status == kCVReturnSuccess, let buffer = out else {
            throw PixelBufferConversionError.pixelBufferCreateFailed(status)
        }
        ciContext.render(scaled, to: buffer)
        return buffer
    }
}
