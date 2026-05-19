import Testing
import Foundation
import CoreVideo
@testable import MirrorMeshRender
import MirrorMeshCore

@Suite("MirrorMeshRender")
struct RenderTests {
    @Test func moduleName() {
        #expect(MirrorMeshRender.moduleName == "MirrorMeshRender")
    }

    @Test func rendererProducesFrame() throws {
        let metal = try MetalContext()
        let renderer = try Renderer(context: metal, outputSize: (320, 180))
        let pool = PixelBufferPool(width: 320, height: 180)
        guard let buf = pool.acquire() else {
            Issue.record("PixelBufferPool failed to allocate")
            return
        }
        let captured = CapturedFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            pixelBuffer: buf,
            width: 320, height: 180
        )
        let out = renderer.render(captured: captured, landmarks: nil, blendshapes: nil)
        #expect(out != nil)
        #expect(out?.width == 320)
        #expect(out?.height == 180)
        #expect(out?.frameID == captured.frameID)
    }
}
