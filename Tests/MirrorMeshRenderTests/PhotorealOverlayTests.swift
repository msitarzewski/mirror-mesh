import Testing
import Foundation
import CoreVideo
import CoreGraphics
import Metal
@testable import MirrorMeshRender
import MirrorMeshCore

@Suite("PhotorealOverlay")
struct PhotorealOverlayTests {

    /// Init must succeed against the real MetalContext shader library (which now includes
    /// PhotorealOverlay.metal). If the shader source has a syntax error or either entry-point
    /// name is missing, this throws at init and the test fails loudly — same protection
    /// the other render tests rely on for their pipelines.
    @Test func photorealOverlayLoadsShaderWithoutThrowing() throws {
        let metal = try MetalContext()
        _ = try PhotorealOverlay(context: metal)
    }

    /// Drive a single encode against a real render command encoder with a small synthetic
    /// photoreal texture and a synthetic bbox. We commit + waitUntilCompleted so any GPU
    /// validation error (mis-bound buffer, out-of-range texture index, wrong vertex count)
    /// surfaces as a non-success command-buffer status that we can assert on.
    @Test func encodeDoesNotCrashWithSyntheticInputs() throws {
        let metal = try MetalContext()
        let overlay = try PhotorealOverlay(context: metal)

        // Render target — small BGRA texture, .renderTarget usage so it can be a color attachment.
        let rtDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 64, height: 64,
            mipmapped: false
        )
        rtDesc.usage = [.renderTarget, .shaderRead]
        rtDesc.storageMode = .private
        guard let rt = metal.device.makeTexture(descriptor: rtDesc) else {
            Issue.record("failed to allocate render target")
            return
        }

        // Photoreal "texture" — small BGRA texture seeded with a solid color, .shaderRead usage.
        let photoDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 32, height: 32,
            mipmapped: false
        )
        photoDesc.usage = [.shaderRead]
        photoDesc.storageMode = .shared
        guard let photo = metal.device.makeTexture(descriptor: photoDesc) else {
            Issue.record("failed to allocate photoreal texture")
            return
        }
        // Fill with mid-grey BGRA so the GPU sees actual sampleable bytes. We don't read
        // back the output — this test only proves the encode path doesn't blow up.
        let bytesPerRow = 32 * 4
        let bytes = [UInt8](repeating: 128, count: bytesPerRow * 32)
        bytes.withUnsafeBufferPointer { ptr in
            photo.replace(
                region: MTLRegionMake2D(0, 0, 32, 32),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = rt
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = metal.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpDesc) else {
            Issue.record("failed to create command buffer / encoder")
            return
        }

        // Typical face bbox: roughly centered, ~40% of the frame each side.
        let bbox = CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.55)
        overlay.encode(
            into: enc,
            photorealTexture: photo,
            bboxNorm: bbox,
            viewportWidth: 64,
            viewportHeight: 64,
            opacity: 1.0,
            edgeFeather: 0.10
        )

        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        #expect(cb.error == nil, "command buffer reported an error: \(String(describing: cb.error))")
        #expect(cb.status == .completed, "command buffer status was \(cb.status.rawValue)")
    }

    /// Degenerate bbox = no draw issued. Same render pass, but the encode call should be a
    /// no-op rather than triggering a GPU error. We rely on the command buffer completing
    /// cleanly with the clear color intact.
    @Test func encodeIsNoOpWithDegenerateBbox() throws {
        let metal = try MetalContext()
        let overlay = try PhotorealOverlay(context: metal)

        let rtDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 32, height: 32,
            mipmapped: false
        )
        rtDesc.usage = [.renderTarget, .shaderRead]
        rtDesc.storageMode = .private
        guard let rt = metal.device.makeTexture(descriptor: rtDesc) else {
            Issue.record("failed to allocate render target")
            return
        }
        let photoDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 16, height: 16,
            mipmapped: false
        )
        photoDesc.usage = [.shaderRead]
        photoDesc.storageMode = .shared
        guard let photo = metal.device.makeTexture(descriptor: photoDesc) else {
            Issue.record("failed to allocate photoreal texture")
            return
        }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = rt
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].storeAction = .store
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = metal.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpDesc) else {
            Issue.record("failed to create command buffer / encoder")
            return
        }

        overlay.encode(
            into: enc,
            photorealTexture: photo,
            bboxNorm: .zero,        // degenerate — should short-circuit to no draw
            viewportWidth: 32,
            viewportHeight: 32
        )

        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        #expect(cb.error == nil)
        #expect(cb.status == .completed)
    }

    /// The renderer's `render(...)` path with the new `photoreal:` param should still produce
    /// a non-nil RenderedFrame and keep the existing dimensions. Smokes the wiring between
    /// Renderer and PhotorealOverlay end-to-end via a small synthetic CVPixelBuffer.
    @Test func rendererAcceptsPhotorealComposite() throws {
        let metal = try MetalContext()
        let renderer = try Renderer(context: metal, outputSize: (320, 180))

        let pool = PixelBufferPool(width: 320, height: 180)
        guard let capturedBuf = pool.acquire() else {
            Issue.record("PixelBufferPool failed to allocate captured buffer")
            return
        }
        let captured = CapturedFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            pixelBuffer: capturedBuf,
            width: 320, height: 180
        )

        // Allocate a separate BGRA pixel buffer for the "photoreal" output. 256x256 mirrors
        // the FOMM generator size; the renderer scales it to bbox size via the GPU sampler.
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            256, 256,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let photorealBuf = pbOut else {
            Issue.record("CVPixelBufferCreate failed status=\(status)")
            return
        }

        let composite = Renderer.PhotorealComposite(
            pixelBuffer: photorealBuf,
            bboxNorm: CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.55)
        )

        let out = renderer.render(
            captured: captured,
            landmarks: nil,
            blendshapes: nil,
            stylizedHead: nil,
            photoreal: composite
        )
        #expect(out != nil)
        #expect(out?.width == 320)
        #expect(out?.height == 180)
    }
}
