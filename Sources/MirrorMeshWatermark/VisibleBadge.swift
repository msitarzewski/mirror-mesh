import Foundation
import CoreVideo
import CoreGraphics
import CoreText

public enum BadgePosition: String, Codable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft
}

// CPU-side badge compositor. A Metal compute variant is future work; CPU path lets
// unit-test fixtures run without a Metal device.
public final class VisibleBadge: @unchecked Sendable {
    public static let releaseOpacityFloor: Double = 0.85
    public static let defaultText = "MIRRORMESH • SYNTHETIC"
    public static let defaultWidth = 120
    public static let defaultHeight = 40

    public let text: String
    public let position: BadgePosition
    public let opacity: Double
    public let badgeWidth: Int
    public let badgeHeight: Int

    public init(text: String = VisibleBadge.defaultText,
                position: BadgePosition = .bottomRight,
                opacity: Double = 0.85,
                width: Int = VisibleBadge.defaultWidth,
                height: Int = VisibleBadge.defaultHeight) throws {
        #if !DEBUG
        if opacity < VisibleBadge.releaseOpacityFloor {
            throw WatermarkError.opacityBelowReleaseFloor(opacity)
        }
        #endif
        self.text = text
        self.position = position
        self.opacity = max(0.0, min(1.0, opacity))
        self.badgeWidth = width
        self.badgeHeight = height
    }

    public func apply(to buffer: CVPixelBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw WatermarkError.unsupportedPixelFormat(format)
        }
        let lockResult = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockResult == kCVReturnSuccess else {
            throw WatermarkError.pixelBufferLockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw WatermarkError.pixelBufferLockFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // kCGImageAlphaPremultipliedFirst + ByteOrder32Little == BGRA in memory, matching the pool.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WatermarkError.pixelBufferLockFailed
        }

        let inset = 8
        let rect = badgeRect(in: CGSize(width: width, height: height), inset: CGFloat(inset))
        // Flip vertically so Core Graphics' upward-Y matches the buffer's downward-Y origin.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let drawRect = CGRect(x: rect.origin.x,
                              y: CGFloat(height) - rect.origin.y - rect.size.height,
                              width: rect.size.width,
                              height: rect.size.height)

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: CGFloat(opacity))
        ctx.fill(drawRect)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: CGFloat(opacity))
        ctx.setLineWidth(1)
        ctx.stroke(drawRect.insetBy(dx: 0.5, dy: 0.5))

        drawText(text,
                 in: drawRect.insetBy(dx: 4, dy: 4),
                 context: ctx,
                 height: height)

        ctx.restoreGState()
    }

    private func badgeRect(in size: CGSize, inset: CGFloat) -> CGRect {
        let w = CGFloat(badgeWidth)
        let h = CGFloat(badgeHeight)
        switch position {
        case .bottomRight: return CGRect(x: size.width - w - inset, y: inset, width: w, height: h)
        case .bottomLeft:  return CGRect(x: inset, y: inset, width: w, height: h)
        case .topRight:    return CGRect(x: size.width - w - inset, y: size.height - h - inset, width: w, height: h)
        case .topLeft:     return CGRect(x: inset, y: size.height - h - inset, width: w, height: h)
        }
    }

    private func drawText(_ string: String, in rect: CGRect, context: CGContext, height: Int) {
        let fontSize = max(8.0, min(Double(rect.height) * 0.4, 14.0))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let color = CGColor(red: 1, green: 1, blue: 1, alpha: opacity)
        // Use CoreText keys directly to avoid pulling in AppKit's NSAttributedString.Key shims.
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            string as CFString,
            attrs as CFDictionary
        )
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let textX = rect.origin.x + (rect.width - bounds.width) / 2
        let textY = rect.origin.y + (rect.height - bounds.height) / 2 - bounds.origin.y
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
    }
}
