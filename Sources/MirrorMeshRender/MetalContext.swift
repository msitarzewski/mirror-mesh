import Foundation
import Metal
import CoreVideo

public enum MetalContextError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noTextureCache(CVReturn)
    case shaderResourceMissing(String)
    case libraryCompileFailed(String)

    public var description: String {
        switch self {
        case .noDevice:                       return "Metal: no system default MTLDevice"
        case .noCommandQueue:                 return "Metal: failed to create command queue"
        case .noTextureCache(let s):          return "Metal: CVMetalTextureCacheCreate failed (\(s))"
        case .shaderResourceMissing(let n):   return "Metal: shader resource missing: \(n)"
        case .libraryCompileFailed(let msg):  return "Metal: shader library compile failed: \(msg)"
        }
    }
}

/// Owns the Metal device, command queue, runtime-compiled shader library, and a
/// CVMetalTextureCache used by every stage for zero-copy CVPixelBuffer ↔ MTLTexture.
///
/// Single-threaded use by the renderer; CoreVideo/Metal types here are not Sendable.
public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary
    public let textureCache: CVMetalTextureCache

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw MetalContextError.noDevice }
        guard let q = dev.makeCommandQueue() else { throw MetalContextError.noCommandQueue }
        self.device = dev
        self.commandQueue = q

        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cacheOut)
        guard status == kCVReturnSuccess, let cache = cacheOut else {
            throw MetalContextError.noTextureCache(status)
        }
        self.textureCache = cache

        // CommandLineTools-only hosts have no .metallib at build time; compile at runtime
        // from the .metal sources packaged as Bundle.module resources.
        let sources = ["Passthrough", "LandmarkSprite", "AvatarMask", "FaceMesh"]
        var combined = ""
        for name in sources {
            // .copy("Shaders") preserves the subdirectory in the bundle. The earlier .process
            // variant flattened paths but compiled .metal away entirely; .copy keeps the source
            // at the cost of needing the explicit subdir hint here. R14 captures the rule.
            guard let url = Bundle.module.url(
                forResource: name, withExtension: "metal", subdirectory: "Shaders"
            ) else {
                throw MetalContextError.shaderResourceMissing("\(name).metal")
            }
            let src = try String(contentsOf: url, encoding: .utf8)
            combined.append("\n// ===== \(name).metal =====\n")
            combined.append(src)
        }
        let opts = MTLCompileOptions()
        do {
            self.library = try dev.makeLibrary(source: combined, options: opts)
        } catch {
            throw MetalContextError.libraryCompileFailed(String(describing: error))
        }
    }

    /// Wrap a BGRA CVPixelBuffer as a MTLTexture without copying. The returned `CVMetalTexture`
    /// must be retained by the caller for as long as the `MTLTexture` is in flight.
    public func makeTexture(from pixelBuffer: CVPixelBuffer,
                            usage: MTLTextureUsage) -> (CVMetalTexture, MTLTexture)? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            w, h,
            0,
            &cvTex
        )
        guard status == kCVReturnSuccess,
              let cv = cvTex,
              let mtl = CVMetalTextureGetTexture(cv)
        else { return nil }
        _ = usage  // CV-backed textures inherit usage from the IOSurface; flag kept for API symmetry
        return (cv, mtl)
    }
}
