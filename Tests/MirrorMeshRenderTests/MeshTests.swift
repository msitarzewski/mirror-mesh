import Testing
import Foundation
import CoreVideo
import CryptoKit
@testable import MirrorMeshRender
import MirrorMeshCore

@Suite("MirrorMeshRender.Mesh")
struct MeshTests {

    // MARK: - Topology

    @Test func triangleCountIsReasonable() {
        let n = MeshTopology.triangleCount
        #expect(n > 80, "got \(n) triangles, expected > 80")
        #expect(n < 200, "got \(n) triangles, expected < 200")
    }

    @Test func allIndicesInRange() {
        for idx in MeshTopology.indices {
            #expect(idx < 76, "index \(idx) out of [0, 76)")
        }
    }

    @Test func noDegenerateTriangles() {
        let idx = MeshTopology.indices
        #expect(idx.count % 3 == 0)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = idx[t], b = idx[t + 1], c = idx[t + 2]
            #expect(a != b && b != c && a != c,
                    "degenerate triangle at \(t): \(a)/\(b)/\(c)")
        }
    }

    @Test func everyBandIsCovered() {
        // At least one triangle must include a vertex from each band so the topology
        // visibly stitches the whole face rather than just the silhouette.
        let idx = MeshTopology.indices
        var seen: [MeshTopology.Band: Bool] = [:]
        for band in MeshTopology.Band.allCases { seen[band] = false }
        for v in idx {
            for band in MeshTopology.Band.allCases where band.contains(Int(v)) {
                seen[band] = true
            }
        }
        for band in MeshTopology.Band.allCases {
            #expect(seen[band] == true, "band \(band) not covered by any triangle")
        }
    }

    // MARK: - Renderer integration

    @Test func rendererWithMeshProducesFrame() throws {
        let metal = try MetalContext()
        let opts = Renderer.Options(showLandmarks: false,
                                    showAvatarMask: false,
                                    showFaceMesh: true,
                                    meshStyle: .wireframe)
        let renderer = try Renderer(context: metal, outputSize: (320, 180), options: opts)
        let captured = makeBlackFrame(width: 320, height: 180)
        let lm = makeSyntheticLandmarks(seed: 1)
        let out = renderer.render(captured: captured, landmarks: lm, blendshapes: nil)
        #expect(out != nil)
        #expect(out?.width == 320)
        #expect(out?.height == 180)
    }

    @Test func meshChangesContentWhenLandmarksDiffer() throws {
        let metal = try MetalContext()
        let opts = Renderer.Options(showLandmarks: false,
                                    showAvatarMask: false,
                                    showFaceMesh: true,
                                    meshStyle: .filled,
                                    meshColor: SIMD4<Float>(1, 1, 1, 1))
        let renderer = try Renderer(context: metal, outputSize: (160, 120), options: opts)

        let frame = makeBlackFrame(width: 160, height: 120)
        let lmA = makeSyntheticLandmarks(seed: 1)
        let lmB = makeSyntheticLandmarks(seed: 2)

        guard let outA = renderer.render(captured: frame, landmarks: lmA, blendshapes: nil),
              let outB = renderer.render(captured: frame, landmarks: lmB, blendshapes: nil)
        else {
            Issue.record("renderer returned nil")
            return
        }
        let hashA = sha256(outA.pixelBuffer)
        let hashB = sha256(outB.pixelBuffer)
        #expect(hashA != hashB, "expected the mesh pass to alter pixels when landmarks change")
    }

    // MARK: - Helpers

    private func makeBlackFrame(width: Int, height: Int) -> CapturedFrame {
        let pool = PixelBufferPool(width: width, height: height)
        // Why force-unwrap: PixelBufferPool only fails on resource exhaustion in CI; tests
        // assert that doesn't happen on a fresh pool.
        let buf = pool.acquire()!
        return CapturedFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            pixelBuffer: buf,
            width: width,
            height: height
        )
    }

    /// Deterministic synthetic 76-point cloud spread across [0.1, 0.9] in both axes. `seed`
    /// shifts every point slightly so two seeds produce visibly different meshes.
    private func makeSyntheticLandmarks(seed: Int) -> LandmarkFrame {
        var pts: [LandmarkPoint] = []
        pts.reserveCapacity(76)
        let s = Float(seed) * 0.01
        for i in 0..<76 {
            let t = Float(i) / 76.0
            let angle = t * 2 * .pi
            let r: Float = 0.35
            let cx: Float = 0.5 + s
            let cy: Float = 0.5
            let x = cx + r * cos(angle)
            let y = cy + r * sin(angle) + s
            pts.append(LandmarkPoint(x: x, y: y))
        }
        return LandmarkFrame(
            frameID: FrameIDGenerator.shared.next(),
            hostTimeNs: MirrorMeshCore.hostTimeNs(),
            points: pts,
            confidence: 1.0,
            faceBoundingBoxNorm: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
    }

    /// SHA-256 of the BGRA active region, matching `PixelBufferDigest.sha256` semantics.
    private func sha256(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Data() }
        var hasher = SHA256()
        for row in 0..<h {
            let rowPtr = base.advanced(by: row * bpr)
            let buf = UnsafeRawBufferPointer(start: rowPtr, count: w * 4)
            hasher.update(bufferPointer: buf)
        }
        return Data(hasher.finalize())
    }
}
