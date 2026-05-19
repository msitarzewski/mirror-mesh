import Foundation
import CoreVideo

/// Allocates IOSurface-backed BGRA `CVPixelBuffer`s with consistent attributes so the entire
/// pipeline can share Metal textures without copies.
public final class PixelBufferPool: @unchecked Sendable {
    private var pool: CVPixelBufferPool?
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                poolAttrs as CFDictionary,
                                bufferAttrs as CFDictionary,
                                &p)
        self.pool = p
    }

    public func acquire() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buf: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        return status == kCVReturnSuccess ? buf : nil
    }
}
