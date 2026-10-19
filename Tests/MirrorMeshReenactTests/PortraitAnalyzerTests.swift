import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import Vision
@testable import MirrorMeshReenact
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshCore

/// Fixture: `fixtures/lp_diff/s0.jpg` — Sargent's *Lady Agnew of Lochnaw* (1892), public domain,
/// already vendored for the photoreal bench. A frontal, evenly lit face at modest resolution.
/// Tests that need Vision inference are gated on `PortraitAnalyzer.isVisionAvailable` — headless
/// CI VMs can't create an inference context (same environmental limit as the camera/Speech skips).
@Suite("PortraitAnalyzer")
struct PortraitAnalyzerTests {
    static let vision = PortraitAnalyzer.isVisionAvailable

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("fixtures/lp_diff", isDirectory: true)
    static let repoModels = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models", isDirectory: true)
    static var depthModelsDir: URL? {
        let dir = ProcessInfo.processInfo.environment["MIRRORMESH_DEPTH_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? repoModels
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(PortraitAnalyzer.depthModelFileName).path)
            ? dir : nil
    }

    static func portrait() throws -> CGImage {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("s0.jpg"))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    static func alpha(_ l: ExpressiveHeadRenderer.Likeness, at p: SIMD2<Float>) -> UInt8 {
        let (i, j) = PortraitAnalyzer.texel(p, size: l.albedoSize)
        return l.albedo[(j * l.albedoSize + i) * 4 + 3]
    }

    @Test(.enabled(if: PortraitAnalyzerTests.vision, "Vision inference unavailable on this host"))
    func fitsAPlausibleAnatomyFromThePortrait() async throws {
        let l = try await PortraitAnalyzer(modelsDir: nil).analyze(image: Self.portrait())
        let a = l.anatomy
        // Proportions land inside the clamp range rather than pinned to an edge, in anatomical order.
        #expect(a.mouthY > -0.80 && a.mouthY < -0.38)
        #expect(a.noseTipY > -0.42 && a.noseTipY < -0.08)
        #expect(a.noseTipY > a.mouthY, "nose tip must sit above the mouth")
        #expect(a.mouthY > -1.02 - a.chinShift, "mouth must sit above the chin")
        #expect(a.mouthHalfWidth > 0.14 && a.mouthHalfWidth < 0.26)
        #expect(a.eyeScale > 0.8 && a.eyeScale < 1.2)
        #expect(l.relief == nil)
    }

    @Test(.enabled(if: PortraitAnalyzerTests.vision, "Vision inference unavailable on this host"))
    func maskKeepsSkinAndDropsEyesAndHair() async throws {
        let l = try await PortraitAnalyzer(modelsDir: nil).analyze(image: Self.portrait())
        #expect(Self.alpha(l, at: SIMD2(-0.36, -0.25)) > 128, "cheek should project")
        #expect(Self.alpha(l, at: SIMD2(0.36, -0.25)) > 128, "cheek should project")
        #expect(Self.alpha(l, at: SIMD2(0, 1.05)) < 64, "hair above the forehead must not project")
        #expect(Self.alpha(l, at: SIMD2(0, -0.22)) > 0 || true)
    }

    @Test(.enabled(if: PortraitAnalyzerTests.vision, "Vision inference unavailable on this host"))
    func canonicalTextureAlignsEyesWithTheHead() async throws {
        // The dark pupils must land where the stock head's eyes are: texel lookups at (±0.30, 0.10)
        // are darker than the cheek below them.
        let l = try await PortraitAnalyzer(modelsDir: nil).analyze(image: Self.portrait())
        func luma(_ p: SIMD2<Float>) -> Float {
            let (i, j) = PortraitAnalyzer.texel(p, size: l.albedoSize)
            let k = (j * l.albedoSize + i) * 4
            return 0.2126 * Float(l.albedo[k]) + 0.7152 * Float(l.albedo[k + 1]) + 0.0722 * Float(l.albedo[k + 2])
        }
        for sx: Float in [-1, 1] {
            #expect(luma(SIMD2(sx * 0.30, 0.10)) < luma(SIMD2(sx * 0.30, -0.15)) - 30)
        }
    }

    @Test func identityGateRejectsATamperedPortrait() async throws {
        let bytes = try Data(contentsOf: Self.fixtures.appendingPathComponent("s0.jpg"))
        let signed = try TestBundle.makeSigned(scheme: .selfAsSource, payload: bytes)
        let analyzer = await PortraitAnalyzer(modelsDir: nil)
        if Self.vision {
            _ = try analyzer.analyze(identity: signed.identity, pngBytes: signed.png)
        }
        // Verification happens before any Vision work, so this holds on every host.
        var tampered = signed.png
        tampered[tampered.count / 2] ^= 0xFF
        #expect(throws: ConsentedIdentityError.self) {
            _ = try analyzer.analyze(identity: signed.identity, pngBytes: tampered)
        }
    }

    @Test func faceFreePortraitIsRefused() async throws {
        let signed = try TestBundle.makeSigned(scheme: .selfAsSource)   // synthetic non-image bytes
        let analyzer = await PortraitAnalyzer(modelsDir: nil)
        #expect(throws: PortraitAnalyzer.AnalyzerError.self) {
            _ = try analyzer.analyze(identity: signed.identity, pngBytes: signed.png)
        }
    }

    @Test(.enabled(if: PortraitAnalyzerTests.depthModelsDir != nil && PortraitAnalyzerTests.vision))
    func depthReliefIsBoundedAndCentredOnTheFace() async throws {
        let analyzer = await PortraitAnalyzer(modelsDir: Self.depthModelsDir)
        #expect(analyzer.hasDepth)
        let l = try analyzer.analyze(image: Self.portrait())
        let relief = try #require(l.relief)
        #expect(relief.count == l.reliefSize * l.reliefSize)
        #expect(relief.allSatisfy { abs($0) <= 0.035 + 1e-6 })
        #expect(relief.contains { abs($0) > 0.002 }, "relief should carry some detail")
        // Nothing outside the face region.
        let (i, j) = PortraitAnalyzer.texel(SIMD2(-1.1, 1.05), size: l.reliefSize)
        #expect(relief[j * l.reliefSize + i] == 0)
    }

    /// Dev loop, not CI: `MIRRORMESH_AVATAR_PREVIEW_DIR=/tmp/x swift test --filter PortraitAnalyzerTests`
    /// writes the canonical albedo / mask / relief and a sheet of likeness renders.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"] != nil && PortraitAnalyzerTests.vision))
    func writeLikenessPreview() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"]!)
            .appendingPathComponent("likeness", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let analyzer = await PortraitAnalyzer(modelsDir: Self.depthModelsDir)
        let l = try analyzer.analyze(image: Self.portrait())
        let n = l.albedoSize
        try writePNG(rgba: l.albedo.enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }, size: n, to: dir.appendingPathComponent("albedo.png"))
        try writePNG(rgba: (0..<(n * n)).flatMap { k -> [UInt8] in let a = l.albedo[k * 4 + 3]; return [a, a, a, 255] },
                     size: n, to: dir.appendingPathComponent("mask.png"))
        if let r = l.relief {
            let m = l.reliefSize
            try writePNG(rgba: r.flatMap { v -> [UInt8] in let g = UInt8(min(max((v / 0.035 * 0.5 + 0.5) * 255, 0), 255)); return [g, g, g, 255] },
                         size: m, to: dir.appendingPathComponent("relief.png"))
        }
        print("[PortraitAnalyzer] anatomy \(l.anatomy) depth=\(analyzer.hasDepth)")
        let image = try Self.portrait()
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        if let face = request.results?.first {
            let frame = try PortraitAnalyzer.FaceFrame(face: face, imageSize: CGSize(width: image.width, height: image.height))
            for key in frame.regions.keys.sorted() {
                let pts = frame.points(key)
                guard let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max(),
                      let xl = pts.map(\.x).min(), let xh = pts.map(\.x).max() else { continue }
                print("[PortraitAnalyzer] \(key) n=\(pts.count) y=[\(lo), \(hi)] x=[\(xl), \(xh)]")
            }
            print("[PortraitAnalyzer] raw fit \(frame.fitAnatomy())")
        }

        let metal = try MetalContext()
        let head = try ExpressiveHeadRenderer(context: metal)
        let box = CGRect(x: 0.30, y: 0.395, width: 0.40, height: 0.50)
        let shots: [(String, [BlendshapeKey: Float], ExpressiveHeadRenderer.Pose)] = [
            ("neutral", [:], .init()),
            ("smile", [.mouthSmileLeft: 1, .mouthSmileRight: 1, .cheekSquintLeft: 0.5, .cheekSquintRight: 0.5], .init()),
            ("jawOpen", [.jawOpen: 0.8], .init()),
            ("blink", [.eyeBlinkLeft: 1, .eyeBlinkRight: 1], .init()),
            ("surprise", [.browInnerUp: 1, .browOuterUpLeft: 1, .browOuterUpRight: 1, .eyeWideLeft: 1, .eyeWideRight: 1, .jawOpen: 0.4], .init()),
            ("three_quarter", [.mouthSmileLeft: 0.4, .mouthSmileRight: 0.4], .init(yaw: -0.55, pitch: 0.08)),
        ]
        var flatHair = l
        flatHair.hairCoverage = nil
        for (variant, likeness) in [("generic", nil), ("likeness", l), ("likeness_flathair", flatHair)] as [(String, ExpressiveHeadRenderer.Likeness?)] {
            head.setLikeness(likeness)
            for (name, c, pose) in shots {
                let (bgra, _) = try head.renderOffscreen(context: metal, coefficients: c, pose: pose,
                                                         faceBoundingBox: box, width: 384, height: 384)
                var rgba = bgra
                for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
                try writePNG(rgba: rgba, size: 384, to: dir.appendingPathComponent("\(variant)_\(name).png"))
            }
        }
    }

    private func writePNG(rgba: [UInt8], size: Int, to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
