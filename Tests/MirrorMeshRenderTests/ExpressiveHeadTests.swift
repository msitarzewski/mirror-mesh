import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import simd
@testable import MirrorMeshRender
import MirrorMeshCore

// MARK: - Offscreen harness

/// Renders the expressive head into a shared BGRA texture over a flat background and reads the
/// pixels back. Shared by the golden, property, and preview tests below.
struct ExpressiveHeadHarness {
    static let size = 256
    /// Face box that frames the whole head (crown → upper neck) in a square viewport.
    static let portraitBox = CGRect(x: 0.30, y: 0.395, width: 0.40, height: 0.50)
    static let background = MTLClearColor(red: 0.30, green: 0.32, blue: 0.36, alpha: 1)

    let metal: MetalContext
    let head: ExpressiveHeadRenderer

    init() throws {
        metal = try MetalContext()
        head = try ExpressiveHeadRenderer(context: metal)
    }

    struct Image {
        let width: Int
        let height: Int
        var bgra: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (y * width + x) * 4
            return SIMD4(Float(bgra[i + 2]), Float(bgra[i + 1]), Float(bgra[i]), Float(bgra[i + 3]))
        }

        /// Mean luminance over a normalized region (origin top-left).
        func meanLuma(_ r: CGRect) -> Float {
            var sum: Float = 0, n: Float = 0
            for y in Int(r.minY * Double(height))..<Int(r.maxY * Double(height)) {
                for x in Int(r.minX * Double(width))..<Int(r.maxX * Double(width)) {
                    let p = pixel(x, y)
                    sum += 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                    n += 1
                }
            }
            return n > 0 ? sum / n : 0
        }
    }

    func render(_ coefficients: [BlendshapeKey: Float] = [:],
                pose: ExpressiveHeadRenderer.Pose = .init(),
                box: CGRect? = ExpressiveHeadHarness.portraitBox,
                width: Int = ExpressiveHeadHarness.size,
                height: Int = ExpressiveHeadHarness.size) throws -> (Image, MTLCommandBuffer) {
        let bg = Self.background
        let (bytes, cb) = try head.renderOffscreen(context: metal, coefficients: coefficients, pose: pose,
                                                   faceBoundingBox: box, width: width, height: height,
                                                   background: SIMD4(bg.red, bg.green, bg.blue, bg.alpha))
        return (Image(width: width, height: height, bgra: bytes), cb)
    }

    static func writePNG(_ img: Image, to url: URL) throws {
        var rgba = [UInt8](repeating: 255, count: img.bgra.count)
        for i in stride(from: 0, to: img.bgra.count, by: 4) {
            rgba[i] = img.bgra[i + 2]; rgba[i + 1] = img.bgra[i + 1]; rgba[i + 2] = img.bgra[i]
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExpressiveHeadRendererError.pipelineCreationFailed("png encode") }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExpressiveHeadRendererError.pipelineCreationFailed("png finalize")
        }
    }
}

/// Named expressions used by the preview sheet and the golden set.
enum ExpressionPreset: String, CaseIterable {
    case neutral, jawOpen, smile, blink, surprise, angry, pucker, gazeRightUp, smileLeft, tongue, funnel, sneer

    var coefficients: [BlendshapeKey: Float] {
        switch self {
        case .neutral:     return [:]
        case .jawOpen:     return [.jawOpen: 1.0]
        case .smile:       return [.mouthSmileLeft: 1, .mouthSmileRight: 1, .cheekSquintLeft: 0.5, .cheekSquintRight: 0.5]
        case .blink:       return [.eyeBlinkLeft: 1, .eyeBlinkRight: 1]
        case .surprise:    return [.browInnerUp: 1, .browOuterUpLeft: 1, .browOuterUpRight: 1,
                                   .eyeWideLeft: 1, .eyeWideRight: 1, .jawOpen: 0.45]
        case .angry:       return [.browDownLeft: 1, .browDownRight: 1, .mouthFrownLeft: 1, .mouthFrownRight: 1,
                                   .eyeSquintLeft: 0.6, .eyeSquintRight: 0.6, .noseSneerLeft: 0.4, .noseSneerRight: 0.4]
        case .pucker:      return [.mouthPucker: 1]
        case .gazeRightUp: return GazeChannels.encode(horizontal: 0.9, vertical: 0.7)
        case .smileLeft:   return [.mouthSmileLeft: 1, .cheekSquintLeft: 0.6]
        case .tongue:      return [.jawOpen: 0.6, .tongueOut: 1]
        case .funnel:      return [.mouthFunnel: 1, .jawOpen: 0.25]
        case .sneer:       return [.noseSneerLeft: 1, .noseSneerRight: 1, .mouthUpperUpLeft: 0.6, .mouthUpperUpRight: 0.6]
        }
    }
}

@Suite("ExpressiveHead preview")
struct ExpressiveHeadPreviewTests {
    /// Dev loop, not CI: `MIRRORMESH_AVATAR_PREVIEW_DIR=/tmp/x swift test --filter ExpressiveHeadPreview`
    /// writes one PNG per preset plus a few poses so shader changes can be eyeballed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"] != nil))
    func writePreviewSheet() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIRRORMESH_AVATAR_PREVIEW_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let h = try ExpressiveHeadHarness()
        for preset in ExpressionPreset.allCases {
            let (img, _) = try h.render(preset.coefficients, width: 384, height: 384)
            try ExpressiveHeadHarness.writePNG(img, to: dir.appendingPathComponent("\(preset.rawValue).png"))
        }
        let poses: [(String, ExpressiveHeadRenderer.Pose)] = [
            ("pose_yaw", .init(yaw: 0.55)), ("pose_pitch_up", .init(pitch: 0.35)), ("pose_roll", .init(roll: 0.30)),
            ("pose_three_quarter", .init(yaw: -0.65, pitch: 0.12)),
        ]
        for (name, pose) in poses {
            let (img, _) = try h.render([.mouthSmileLeft: 0.5, .mouthSmileRight: 0.5], pose: pose, width: 384, height: 384)
            try ExpressiveHeadHarness.writePNG(img, to: dir.appendingPathComponent("\(name).png"))
        }
    }
}

// MARK: - Pure helpers

@Suite("ExpressiveHead math")
struct ExpressiveHeadMathTests {
    private static let shaderURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MirrorMeshRender/Shaders/ExpressiveHead.metal")

    /// The shader indexes coefficients by hand-written constants; pin every one against the
    /// Swift enum so reordering `BlendshapeKey` can't silently scramble the face.
    @Test func coefficientIndicesMatchSwiftEnum() throws {
        let src = try String(contentsOf: Self.shaderURL, encoding: .utf8)
        let expected: [String: BlendshapeKey] = [
            "EH_EYE_BLINK_L": .eyeBlinkLeft, "EH_EYE_LOOK_DOWN_L": .eyeLookDownLeft,
            "EH_EYE_LOOK_IN_L": .eyeLookInLeft, "EH_EYE_LOOK_OUT_L": .eyeLookOutLeft,
            "EH_EYE_LOOK_UP_L": .eyeLookUpLeft, "EH_EYE_SQUINT_L": .eyeSquintLeft,
            "EH_EYE_WIDE_L": .eyeWideLeft, "EH_JAW_FORWARD": .jawForward, "EH_JAW_LEFT": .jawLeft,
            "EH_JAW_RIGHT": .jawRight, "EH_JAW_OPEN": .jawOpen, "EH_MOUTH_CLOSE": .mouthClose,
            "EH_MOUTH_FUNNEL": .mouthFunnel, "EH_MOUTH_PUCKER": .mouthPucker, "EH_MOUTH_LEFT": .mouthLeft,
            "EH_MOUTH_RIGHT": .mouthRight, "EH_MOUTH_SMILE_L": .mouthSmileLeft,
            "EH_MOUTH_FROWN_L": .mouthFrownLeft, "EH_MOUTH_DIMPLE_L": .mouthDimpleLeft,
            "EH_MOUTH_STRETCH_L": .mouthStretchLeft, "EH_MOUTH_ROLL_LOWER": .mouthRollLower,
            "EH_MOUTH_ROLL_UPPER": .mouthRollUpper, "EH_MOUTH_SHRUG_LOWER": .mouthShrugLower,
            "EH_MOUTH_SHRUG_UPPER": .mouthShrugUpper, "EH_MOUTH_PRESS_L": .mouthPressLeft,
            "EH_MOUTH_LOWER_DOWN_L": .mouthLowerDownLeft, "EH_MOUTH_UPPER_UP_L": .mouthUpperUpLeft,
            "EH_BROW_DOWN_L": .browDownLeft, "EH_BROW_INNER_UP": .browInnerUp,
            "EH_BROW_OUTER_UP_L": .browOuterUpLeft, "EH_CHEEK_PUFF": .cheekPuff,
            "EH_CHEEK_SQUINT_L": .cheekSquintLeft, "EH_NOSE_SNEER_L": .noseSneerLeft,
            "EH_TONGUE_OUT": .tongueOut,
        ]
        let order = ExpressiveHeadRenderer.coefficientOrder
        #expect(order.count == 52)
        var seen = 0
        for line in src.split(separator: "\n") where line.hasPrefix("constant int EH_") {
            let parts = line.replacingOccurrences(of: ";", with: "").split(separator: " ")
            guard parts.count >= 5, let index = Int(parts[4]) else { continue }
            let name = String(parts[2])
            guard let key = expected[name] else {
                Issue.record("shader constant \(name) has no expected key in this test")
                continue
            }
            #expect(order.firstIndex(of: key) == index, "\(name) = \(index) but \(key) is at \(String(describing: order.firstIndex(of: key)))")
            // `_L` constants are read with `+ 1` for the right side.
            if name.hasSuffix("_L"), let right = BlendshapeKey(rawValue: key.rawValue.replacingOccurrences(of: "Left", with: "Right")) {
                #expect(order.firstIndex(of: right) == index + 1, "\(right) must follow \(key)")
            }
            seen += 1
        }
        #expect(seen == expected.count)
    }

    @Test func packCoefficientsIsOrderedClampedAndTotal() {
        let packed = ExpressiveHeadRenderer.packCoefficients([.jawOpen: 0.5, .tongueOut: 2, .eyeBlinkLeft: .nan, .mouthClose: -1])
        #expect(packed.count == 52)
        #expect(packed[17] == 0.5)
        #expect(packed[51] == 1)
        #expect(packed[0] == 0)
        #expect(packed[18] == 0)
        #expect(packed.filter { $0 != 0 }.count == 2)
    }

    private func apply(_ rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(simd_dot(rows.0, v), simd_dot(rows.1, v), simd_dot(rows.2, v))
    }

    @Test func rotationFollowsOperatorConventions() {
        let tol: Float = 1e-5
        let id = ExpressiveHeadRenderer.rotationRows(.init())
        #expect(simd_distance(apply(id, SIMD3(1, 2, 3)), SIMD3(1, 2, 3)) < tol)

        let forward = SIMD3<Float>(0, 0, 1)
        // Positive yaw turns the face toward image-right.
        #expect(apply(ExpressiveHeadRenderer.rotationRows(.init(yaw: 0.5)), forward).x > 0.4)
        // Positive pitch tilts it up.
        #expect(apply(ExpressiveHeadRenderer.rotationRows(.init(pitch: 0.5)), forward).y > 0.4)
        // Positive roll is clockwise on screen: the head's +x axis dips.
        #expect(apply(ExpressiveHeadRenderer.rotationRows(.init(roll: 0.5)), SIMD3(1, 0, 0)).y < -0.4)

        // Orthonormal for an arbitrary pose.
        let r = ExpressiveHeadRenderer.rotationRows(.init(yaw: 0.3, pitch: -0.2, roll: 0.7))
        for row in [r.0, r.1, r.2] { #expect(abs(simd_length(row) - 1) < tol) }
        #expect(abs(simd_dot(r.0, r.1)) < tol && abs(simd_dot(r.1, r.2)) < tol && abs(simd_dot(r.0, r.2)) < tol)
    }

    @Test func layoutAnchorsFaceSpanToTheBoundingBox() throws {
        let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
        let l = try #require(ExpressiveHeadRenderer.layout(faceBoundingBox: box, viewportWidth: 1000,
                                                           viewportHeight: 500, scale: 1))
        // 0.4 × 500 px = 200 px spans `faceSpan` head units.
        #expect(abs(l.unitsPerPixel - ExpressiveHeadRenderer.faceSpan / 200) < 1e-6)
        // The quad is centred on the box horizontally and covers it.
        #expect(abs((l.rectNDC.x + l.rectNDC.z / 2) - 0) < 1e-5)
        let boxTopNDC: Float = 1 - 0.3 * 2, boxBottomNDC: Float = 1 - 0.7 * 2
        #expect(l.rectNDC.y < boxBottomNDC && l.rectNDC.y + l.rectNDC.w > boxTopNDC)
        // Scale shrinks around the same centre.
        let ghost = try #require(ExpressiveHeadRenderer.layout(faceBoundingBox: box, viewportWidth: 1000,
                                                               viewportHeight: 500, scale: 0.5))
        #expect(abs(ghost.rectNDC.z - l.rectNDC.z / 2) < 1e-5)
    }

    @Test func layoutRejectsDegenerateInputs() {
        #expect(ExpressiveHeadRenderer.layout(faceBoundingBox: .zero, viewportWidth: 640, viewportHeight: 360, scale: 1) == nil)
        #expect(ExpressiveHeadRenderer.layout(faceBoundingBox: nil, viewportWidth: 0, viewportHeight: 360, scale: 1) == nil)
        #expect(ExpressiveHeadRenderer.layout(faceBoundingBox: nil, viewportWidth: 640, viewportHeight: 360, scale: 1) != nil)
    }
}

// MARK: - Rendering

@Suite("ExpressiveHead rendering")
struct ExpressiveHeadRenderingTests {
    static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Goldens", isDirectory: true)
    static let recording = ProcessInfo.processInfo.environment["MIRRORMESH_RECORD_GOLDENS"] == "1"

    static func loadPNG(_ url: URL) -> ExpressiveHeadHarness.Image? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bgra = rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            bgra[i] = rgba[i + 2]; bgra[i + 2] = rgba[i]; bgra[i + 3] = 255
        }
        return .init(width: w, height: h, bgra: bgra)
    }

    /// Golden frames for a fixed set of expressions and one pose. Tolerant comparison: GPU
    /// families differ in the last bit of transcendental functions, which moves silhouette pixels.
    /// Re-record after an intentional shader change:
    ///   MIRRORMESH_RECORD_GOLDENS=1 swift test --filter "ExpressiveHead rendering"
    @Test(arguments: ["neutral", "jawOpen", "smile", "blink", "angry", "gazeRightUp", "pose_three_quarter"])
    func matchesGolden(_ name: String) throws {
        let h = try ExpressiveHeadHarness()
        let (img, cb) = name == "pose_three_quarter"
            ? try h.render([.mouthSmileLeft: 0.5, .mouthSmileRight: 0.5], pose: .init(yaw: -0.65, pitch: 0.12))
            : try h.render(ExpressionPreset(rawValue: name)!.coefficients)
        #expect(cb.status == .completed)
        let url = Self.goldenDir.appendingPathComponent("\(name).png")
        if Self.recording {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try ExpressiveHeadHarness.writePNG(img, to: url)
            return
        }
        guard let golden = Self.loadPNG(url) else {
            Issue.record("missing golden \(url.lastPathComponent) — record with MIRRORMESH_RECORD_GOLDENS=1")
            return
        }
        #expect(golden.width == img.width && golden.height == img.height)
        var sum = 0, bad = 0
        for i in stride(from: 0, to: img.bgra.count, by: 4) {
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(img.bgra[i + c]) - Int(golden.bgra[i + c]))
                sum += d
                worst = max(worst, d)
            }
            if worst > 24 { bad += 1 }
        }
        let pixels = img.width * img.height
        let mean = Double(sum) / Double(pixels * 3)
        let badFraction = Double(bad) / Double(pixels)
        #expect(mean < 1.5, "\(name): mean abs diff \(mean)")
        #expect(badFraction < 0.005, "\(name): \(badFraction * 100)% pixels differ by > 24")
    }

    /// Normalized regions for `portraitBox` at 256². Derived from the head-local anatomy:
    /// mouth at y = −0.5, eyes at (±0.30, 0.10).
    static let mouthRegion = CGRect(x: 0.42, y: 0.68, width: 0.16, height: 0.10)
    static let leftEyeRegion = CGRect(x: 0.34, y: 0.47, width: 0.12, height: 0.09)
    static let eyeBand = CGRect(x: 0.25, y: 0.45, width: 0.50, height: 0.13)

    /// Dark-pixel (iris / pupil / mouth interior) count and centroid within a region.
    static func darkPixels(_ img: ExpressiveHeadHarness.Image, in r: CGRect, below luma: Float = 70)
        -> (count: Int, centroid: SIMD2<Float>) {
        var n = 0
        var sum = SIMD2<Float>.zero
        for y in Int(r.minY * Double(img.height))..<Int(r.maxY * Double(img.height)) {
            for x in Int(r.minX * Double(img.width))..<Int(r.maxX * Double(img.width)) {
                let p = img.pixel(x, y)
                if 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z < luma {
                    n += 1
                    sum += SIMD2(Float(x), Float(y))
                }
            }
        }
        return (n, n > 0 ? sum / Float(n) : .zero)
    }

    @Test func headFillsAPlausibleShareOfTheFrame() throws {
        let (img, _) = try ExpressiveHeadHarness().render()
        let bg = ExpressiveHeadHarness.background
        let bgPx = SIMD3<Float>(Float(bg.red), Float(bg.green), Float(bg.blue)) * 255
        var covered = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let p = img.pixel(x, y)
                if simd_length(SIMD3(p.x, p.y, p.z) - bgPx) > 6 { covered += 1 }
            }
        }
        let share = Double(covered) / Double(img.width * img.height)
        #expect(share > 0.20 && share < 0.65, "head covers \(share * 100)%")
    }

    @Test func jawOpenRevealsADarkMouth() throws {
        let h = try ExpressiveHeadHarness()
        let (closed, _) = try h.render()
        let (open, _) = try h.render([.jawOpen: 1])
        #expect(open.meanLuma(Self.mouthRegion) < closed.meanLuma(Self.mouthRegion) - 15)
    }

    /// Pixels with the default iris hue (blue-dominant, not bright) — distinguishes the iris from
    /// the dark lash seam a closed lid still shows.
    static func irisPixels(_ img: ExpressiveHeadHarness.Image, in r: CGRect) -> Int {
        var n = 0
        for y in Int(r.minY * Double(img.height))..<Int(r.maxY * Double(img.height)) {
            for x in Int(r.minX * Double(img.width))..<Int(r.maxX * Double(img.width)) {
                let p = img.pixel(x, y)
                if p.z - p.x > 12 && p.z < 170 { n += 1 }
            }
        }
        return n
    }

    @Test func blinkCoversTheIris() throws {
        let h = try ExpressiveHeadHarness()
        let open = Self.irisPixels(try h.render().0, in: Self.leftEyeRegion)
        let shut = Self.irisPixels(try h.render([.eyeBlinkLeft: 1, .eyeBlinkRight: 1]).0, in: Self.leftEyeRegion)
        #expect(open > 20, "expected a visible iris, got \(open) iris px")
        #expect(shut * 10 < open, "blink left \(shut) of \(open) iris px")
    }

    @Test func irisFollowsGaze() throws {
        let h = try ExpressiveHeadHarness()
        let ahead = Self.darkPixels(try h.render().0, in: Self.leftEyeRegion)
        let right = Self.darkPixels(try h.render(GazeChannels.encode(horizontal: 0.9, vertical: 0)).0, in: Self.leftEyeRegion)
        let up = Self.darkPixels(try h.render(GazeChannels.encode(horizontal: 0, vertical: 0.9)).0, in: Self.leftEyeRegion)
        #expect(right.centroid.x > ahead.centroid.x + 1.5)
        #expect(up.centroid.y < ahead.centroid.y - 1.0)
    }

    @Test func headPoseMovesTheFaceTheRightWay() throws {
        let h = try ExpressiveHeadHarness()
        let ahead = Self.darkPixels(try h.render().0, in: Self.eyeBand)
        let turned = Self.darkPixels(try h.render(pose: .init(yaw: 0.4)).0, in: Self.eyeBand)
        let raised = Self.darkPixels(try h.render(pose: .init(pitch: 0.3)).0, in: Self.eyeBand)
        #expect(turned.centroid.x > ahead.centroid.x + 2)
        #expect(raised.centroid.y < ahead.centroid.y - 1)
    }

    /// Left/right shapes land on mirrored sides: the pixels a left smile changes, mirrored,
    /// overlap the pixels a right smile changes.
    @Test func sidedShapesAreMirrorImages() throws {
        let h = try ExpressiveHeadHarness()
        let (base, _) = try h.render()
        let (left, _) = try h.render([.mouthSmileLeft: 1])
        let (right, _) = try h.render([.mouthSmileRight: 1])
        func changed(_ a: ExpressiveHeadHarness.Image) -> Set<Int> {
            var s = Set<Int>()
            for y in 0..<a.height {
                for x in 0..<a.width where simd_length(a.pixel(x, y) - base.pixel(x, y)) > 10 {
                    s.insert(y * a.width + x)
                }
            }
            return s
        }
        let l = changed(left)
        let mirroredR = Set(changed(right).map { i in (i / base.width) * base.width + (base.width - 1 - i % base.width) })
        let iou = Double(l.intersection(mirroredR).count) / Double(max(l.union(mirroredR).count, 1))
        #expect(!l.isEmpty)
        #expect(iou > 0.5, "mirror IoU \(iou)")
        // And the left smile mostly changes the image-left half.
        let leftHalf = l.filter { $0 % base.width < base.width / 2 }.count
        #expect(Double(leftHalf) / Double(l.count) > 0.7)
    }

    @Test func rendererIntegrationDrawsExpressivePayload() throws {
        let metal = try MetalContext()
        let renderer = try Renderer(context: metal, outputSize: (320, 180),
                                    options: .init(showLandmarks: false, isWireframeStyle: false))
        let pool = PixelBufferPool(width: 320, height: 180)
        let buf = try #require(pool.acquire())
        let captured = CapturedFrame(frameID: FrameIDGenerator.shared.next(), hostTimeNs: MirrorMeshCore.hostTimeNs(),
                                     pixelBuffer: buf, width: 320, height: 180)
        let payload = Renderer.ExpressiveHeadPayload(
            coefficients: [.jawOpen: 0.4],
            pose: .init(yaw: 0.1),
            faceBoundingBoxNorm: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5)
        )
        let out = renderer.render(captured: captured, landmarks: nil, blendshapes: nil, expressiveHead: payload)
        #expect(out != nil)
        #expect(renderer.expressiveHead.options.scale == 1.0)
    }

    /// Realtime budget at the app's capture size with the face filling ~45% of the frame
    /// (a close webcam framing — the expensive case). Generous bound so slower CI GPUs pass;
    /// the measured number is printed for the benchmark record.
    @Test func rendersWithinARealtimeFrameBudget() throws {
        let h = try ExpressiveHeadHarness()
        let box = CGRect(x: 0.38, y: 0.25, width: 0.24, height: 0.45)
        _ = try h.render([.jawOpen: 0.3], box: box, width: 1280, height: 720)  // warm-up
        var times: [Double] = []
        for i in 0..<6 {
            let (_, cb) = try h.render([.jawOpen: Float(i) / 6, .mouthSmileLeft: 0.4], box: box, width: 1280, height: 720)
            times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        let median = times.sorted()[times.count / 2]
        print("[ExpressiveHead] 1280×720 GPU median \(String(format: "%.2f", median)) ms (samples \(times.map { String(format: "%.2f", $0) }))")
        #expect(median < 33, "median GPU time \(median) ms exceeds one 30 fps frame")
    }
}
