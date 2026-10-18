import Foundation
import CoreGraphics
import CoreML
import CoreVideo
import ImageIO
import Vision
import simd
import MirrorMeshCore
import MirrorMeshRender
import MirrorMeshWatermark

/// Turns a consented identity's portrait into an `ExpressiveHeadRenderer.Likeness`: the SDF head
/// reshaped to that face's proportions, the de-lit portrait as skin albedo, and (when the depth
/// model is installed) the face's own surface relief.
///
/// Runs once per identity load, off the render path — Vision landmarks + one depth inference +
/// a few CPU passes over a 512² texture, tens of milliseconds.
///
/// **Gate (R1)**: the public entry point verifies the `.mmid` bundle exactly like
/// `FaceReenactor.init` — a likeness can only come from a portrait whose subject signed for it.
///
/// **Canonical texture space**: the portrait is resampled so texel ↔ head-local (x, y) is a fixed
/// map over `window` (eyes always land on the same texels). The renderer's UV rows are therefore
/// constants; only the resampling knows about the original photo's framing.
public final class PortraitAnalyzer: @unchecked Sendable {
    public enum AnalyzerError: Error, CustomStringConvertible, Sendable {
        case imageDecodeFailed
        case noFace
        case landmarksIncomplete

        public var description: String {
            switch self {
            case .imageDecodeFailed:   return "PortraitAnalyzer: identity image could not be decoded"
            case .noFace:              return "PortraitAnalyzer: no face found in the identity portrait"
            case .landmarksIncomplete: return "PortraitAnalyzer: portrait landmarks missing eyes, lips, nose or contour"
            }
        }
    }

    public static let depthModelFileName = "depth_v1.mlpackage"
    public static let textureSize = 512
    public static let reliefSize = 256
    /// Head-local square the canonical textures cover: x ∈ [-1.2, 1.2], y ∈ [-1.25, 1.15].
    static let windowMinX: Float = -1.2
    static let windowMaxY: Float = 1.15
    static let windowSpan: Float = 2.4

    /// Stock head measurements the fit is expressed against (see `ExpressiveHead.metal`).
    static let stockEyeHalfDistance: Float = 0.30
    static let stockEyeY: Float = 0.10
    static let stockBrowY: Float = 0.315
    static let stockChinY: Float = -1.02
    static let stockNoseWidth: Float = 0.316
    static let stockJawHalfWidth: Float = 0.55
    static let stockCheekHalfWidth: Float = 0.67
    static let stockEyeWidth: Float = 0.29

    private let depthModel: MLModel?
    public var hasDepth: Bool { depthModel != nil }

    /// Loads the optional depth model from `modelsDir`. Depth is an enhancement: a missing or
    /// unloadable model leaves `hasDepth == false` and the likeness simply has no relief map.
    public init(modelsDir: URL?) async {
        guard let dir = modelsDir else { depthModel = nil; return }
        let url = dir.appendingPathComponent(Self.depthModelFileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let compiled = try? await MLModel.compileModel(at: url) else {
            depthModel = nil
            return
        }
        depthModel = try? MLModel(contentsOf: compiled)
    }

    /// Verify the bundle (R1), then analyze its portrait.
    public func analyze(identity: ConsentedIdentity,
                        pngBytes: Data,
                        runtimeVersion: String = FaceReenactor.runtimeVersion) throws -> ExpressiveHeadRenderer.Likeness {
        try ConsentedIdentityVerifier.verify(identity: identity, pngBytes: pngBytes, runtimeVersion: runtimeVersion)
        guard let src = CGImageSourceCreateWithData(pngBytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw AnalyzerError.imageDecodeFailed
        }
        return try analyze(image: image)
    }

    // MARK: - Analysis

    func analyze(image: CGImage) throws -> ExpressiveHeadRenderer.Likeness {
        let photo = try RGBAImage(image)
        let face = try Self.detectFace(image)
        let frame = try FaceFrame(face: face, imageSize: CGSize(width: photo.width, height: photo.height))

        let anatomy = frame.fitAnatomy()
        let T = Self.textureSize
        var tex = Self.resample(photo, frame: frame, size: T)

        let skin = Self.medianColor(tex, size: T, patches: [(SIMD2(-0.36, -0.25), 0.07), (SIMD2(0.36, -0.25), 0.07),
                                                            (SIMD2(0, 0.42), 0.06), (SIMD2(0, -0.75), 0.05)])
        // Two passes: a loose mask drives the de-lighting estimate, then the real mask is taken on
        // the de-lit texture so a shadowed cheek still reads as skin.
        let looseMask = Self.skinMask(tex, size: T, skin: skin, frame: frame, lumaWindow: (0.25, 2.0))
        let lip = Self.medianColor(tex, size: T, where: { frame.lipsContain($0) && !frame.innerMouthContains($0) })
            ?? SIMD3(158, 77, 74)
        let iris = Self.irisColor(tex, size: T, frame: frame)
        let hair = Self.medianColor(tex, size: T, where: { p in
            p.y > 0.85 && p.y < 1.10 && abs(p.x) < 0.45
        }, accept: { c in Self.luma(c) < Self.luma(skin) * 0.75 }) ?? SIMD3(26, 15, 10)

        // Hair: person segmentation minus skin and inner-face features → coverage map + shape fit.
        let person = Self.personMask(image)
        let hairCoverage = person.map { Self.hairCoverage(person: $0, frame: frame, skinTex: tex, skin: skin, size: Self.reliefSize) }
        var fitted = anatomy
        if let person { Self.fitHair(&fitted, person: person, frame: frame, coverage: hairCoverage) }
        let hairFromCoverage = hairCoverage.flatMap { cov -> SIMD3<Float>? in
            Self.medianColor(tex, size: T, where: { p in
                let (i, j) = Self.texel(p, size: Self.reliefSize)
                guard i >= 0, j >= 0, i < Self.reliefSize, j < Self.reliefSize else { return false }
                return cov[j * Self.reliefSize + i] > 0.6
            })
        }

        let depthSource = tex   // colours before de-lighting feed the depth model
        Self.delight(&tex, size: T, mask: looseMask, skinLuma: Self.luma(skin))
        let mask = Self.skinMask(tex, size: T, skin: skin, frame: frame)
        for i in 0..<(T * T) { tex[i * 4 + 3] = UInt8(min(max(mask[i] * 255, 0), 255)) }

        var relief: [Float]? = nil
        if let model = depthModel {
            relief = try? Self.relief(from: depthSource, size: T, model: model, outSize: Self.reliefSize)
        }

        let appearance = ExpressiveHeadRenderer.Appearance(
            skin: Self.linear(skin), hair: Self.linear(hairFromCoverage ?? hair), iris: Self.linear(iris), lip: Self.linear(lip)
        )
        let span = Self.windowSpan
        return ExpressiveHeadRenderer.Likeness(
            anatomy: fitted.clamped(),
            appearance: appearance,
            albedo: tex,
            albedoSize: T,
            relief: relief,
            reliefSize: Self.reliefSize,
            uRow: SIMD3(1 / span, 0, -Self.windowMinX / span),
            vRow: SIMD3(0, -1 / span, Self.windowMaxY / span),
            hairCoverage: hairCoverage
        )
    }

    /// Head-local (x, y) at the centre of canonical texel (i, j).
    static func headPoint(_ i: Int, _ j: Int, size: Int) -> SIMD2<Float> {
        let s = windowSpan / Float(size)
        return SIMD2(windowMinX + (Float(i) + 0.5) * s, windowMaxY - (Float(j) + 0.5) * s)
    }

    static func texel(_ p: SIMD2<Float>, size: Int) -> (Int, Int) {
        let s = Float(size) / windowSpan
        return (Int((p.x - windowMinX) * s), Int((windowMaxY - p.y) * s))
    }

    // MARK: Vision

    private static func detectFace(_ image: CGImage) throws -> VNFaceObservation {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let faces = (request.results ?? []).filter { $0.landmarks != nil }
        guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { throw AnalyzerError.noFace }
        return face
    }

    /// The portrait's face expressed in head-local units: a similarity transform that puts the
    /// eye centres on the stock head's (±0.30, 0.10), plus every landmark region mapped through it.
    struct FaceFrame {
        let mid: SIMD2<Float>        // eye midpoint, image px (top-left origin)
        let angle: Float             // eye-line angle in image px
        let scale: Float             // head units per image px
        let regions: [String: [SIMD2<Float>]]   // head-local

        init(face: VNFaceObservation, imageSize: CGSize) throws {
            guard let lm = face.landmarks else { throw AnalyzerError.landmarksIncomplete }
            func px(_ r: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
                (r?.pointsInImage(imageSize: imageSize) ?? []).map {
                    SIMD2(Float($0.x), Float(imageSize.height - $0.y))
                }
            }
            let named: [String: [SIMD2<Float>]] = [
                "leftEye": px(lm.leftEye), "rightEye": px(lm.rightEye),
                "leftPupil": px(lm.leftPupil), "rightPupil": px(lm.rightPupil),
                "leftEyebrow": px(lm.leftEyebrow), "rightEyebrow": px(lm.rightEyebrow),
                "nose": px(lm.nose), "noseCrest": px(lm.noseCrest),
                "outerLips": px(lm.outerLips), "innerLips": px(lm.innerLips),
                "faceContour": px(lm.faceContour),
            ]
            for key in ["leftEye", "rightEye", "outerLips", "nose", "faceContour"] where (named[key] ?? []).count < 3 {
                throw AnalyzerError.landmarksIncomplete
            }
            func centre(_ pts: [SIMD2<Float>]) -> SIMD2<Float> { pts.reduce(.zero, +) / Float(max(pts.count, 1)) }
            var eyes = [named["leftPupil"].flatMap { $0.first } ?? centre(named["leftEye"]!),
                        named["rightPupil"].flatMap { $0.first } ?? centre(named["rightEye"]!)]
            eyes.sort { $0.x < $1.x }
            let d = eyes[1] - eyes[0]
            guard simd_length(d) > 2 else { throw AnalyzerError.landmarksIncomplete }
            mid = (eyes[0] + eyes[1]) / 2
            angle = atan2(d.y, d.x)
            scale = 2 * PortraitAnalyzer.stockEyeHalfDistance / simd_length(d)
            var head: [String: [SIMD2<Float>]] = [:]
            let (m, a, s) = (mid, angle, scale)
            for (k, pts) in named {
                head[k] = pts.map { FaceFrame.toHead($0, mid: m, angle: a, scale: s) }
            }
            regions = head
        }

        static func toHead(_ p: SIMD2<Float>, mid: SIMD2<Float>, angle: Float, scale: Float) -> SIMD2<Float> {
            let v = p - mid
            let c = cos(angle), sn = sin(angle)
            let rx = c * v.x + sn * v.y
            let ry = -sn * v.x + c * v.y
            return SIMD2(scale * rx, PortraitAnalyzer.stockEyeY - scale * ry)
        }

        func toImage(_ h: SIMD2<Float>) -> SIMD2<Float> {
            let rx = h.x / scale
            let ry = (PortraitAnalyzer.stockEyeY - h.y) / scale
            let c = cos(angle), sn = sin(angle)
            return mid + SIMD2(c * rx - sn * ry, sn * rx + c * ry)
        }

        func points(_ key: String) -> [SIMD2<Float>] { regions[key] ?? [] }

        func lipsContain(_ p: SIMD2<Float>) -> Bool { Self.polygon(points("outerLips"), contains: p) }

        /// Within ~0.03 head units of an eyebrow outline: the portrait's own brows are painted on
        /// (the shader moves them with the brow coefficients).
        func browsContain(_ p: SIMD2<Float>) -> Bool {
            for key in ["leftEyebrow", "rightEyebrow"] {
                let pts = points(key)
                if Self.polygon(pts, contains: p) { return true }
                for i in 0..<pts.count {
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    let ab = b - a
                    let t = min(max(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-9), 0), 1)
                    if simd_distance(p, a + ab * t) < 0.03 { return true }
                }
            }
            return false
        }

        /// Inside the inner-lip contour *and* the photo's mouth is actually open (teeth or dark
        /// interior would otherwise be projected onto the avatar's closed lips).
        func innerMouthContains(_ p: SIMD2<Float>) -> Bool {
            let inner = points("innerLips")
            guard inner.count >= 3, let lo = inner.map(\.y).min(), let hi = inner.map(\.y).max(), hi - lo > 0.02
            else { return false }
            return Self.polygon(inner, contains: p)
        }

        static func polygon(_ poly: [SIMD2<Float>], contains p: SIMD2<Float>) -> Bool {
            guard poly.count >= 3 else { return false }
            var inside = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let a = poly[i], b = poly[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            return inside
        }

        /// Contour half-width at height `y` (mean of the outermost points within ±band).
        func contourHalfWidth(at y: Float, band: Float = 0.08) -> Float? {
            let near = points("faceContour").filter { abs($0.y - y) < band }
            guard let lo = near.map(\.x).min(), let hi = near.map(\.x).max(), hi - lo > 0.1 else { return nil }
            return (hi - lo) / 2
        }

        func fitAnatomy() -> ExpressiveHeadRenderer.Anatomy {
            var a = ExpressiveHeadRenderer.Anatomy()
            let outer = points("outerLips"), inner = points("innerLips")
            if let lo = outer.map(\.x).min(), let hi = outer.map(\.x).max(),
               let bottom = outer.map(\.y).min(), let top = outer.map(\.y).max() {
                let line = inner.isEmpty ? (top + bottom) / 2 : inner.map(\.y).reduce(0, +) / Float(inner.count)
                a.mouthHalfWidth = (hi - lo) / 2
                a.mouthY = line
                a.upperLip = max(top - line, 0) / 2
                a.lowerLip = max(line - bottom, 0) / 2
            }
            let crest = points("noseCrest"), nose = points("nose")
            if let tip = crest.map(\.y).min() {
                a.noseTipY = tip
            } else if let bottom = nose.map(\.y).min() {
                a.noseTipY = bottom + 0.08
            }
            if let lo = nose.map(\.x).min(), let hi = nose.map(\.x).max() {
                a.noseWidth = (hi - lo) / PortraitAnalyzer.stockNoseWidth
            }
            if let chin = points("faceContour").map(\.y).min() {
                a.chinShift = PortraitAnalyzer.stockChinY - chin
            }
            if let jaw = contourHalfWidth(at: a.mouthY) { a.jawWidth = jaw / PortraitAnalyzer.stockJawHalfWidth }
            if let cheek = contourHalfWidth(at: a.noseTipY) { a.cheekWidth = cheek / PortraitAnalyzer.stockCheekHalfWidth }
            let brows = points("leftEyebrow") + points("rightEyebrow")
            if !brows.isEmpty {
                a.browLift = brows.map(\.y).reduce(0, +) / Float(brows.count) - PortraitAnalyzer.stockBrowY
            }
            let widths = ["leftEye", "rightEye"].compactMap { k -> Float? in
                let pts = points(k)
                guard let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max() else { return nil }
                return hi - lo
            }
            if !widths.isEmpty {
                a.eyeScale = widths.reduce(0, +) / Float(widths.count) / PortraitAnalyzer.stockEyeWidth
            }
            return a
        }
    }

    // MARK: Pixels

    /// Straight RGBA8 copy of a CGImage in sRGB, top-left origin.
    struct RGBAImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw AnalyzerError.imageDecodeFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = buf
        }

        /// Bilinear sample at image px (top-left origin); nil outside the image.
        func sample(_ p: SIMD2<Float>) -> SIMD3<Float>? {
            let x = p.x - 0.5, y = p.y - 0.5
            guard x >= 0, y >= 0, x < Float(width - 1), y < Float(height - 1) else { return nil }
            let x0 = Int(x), y0 = Int(y)
            let fx = x - Float(x0), fy = y - Float(y0)
            func px(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let k = (j * width + i) * 4
                return SIMD3(Float(pixels[k]), Float(pixels[k + 1]), Float(pixels[k + 2]))
            }
            let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
            let bottom = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// Canonical RGBA8 texture: texel ↔ head-local via `window`, sampled from the photo through
    /// the face frame. Texels that fall outside the photo get alpha 0.
    static func resample(_ photo: RGBAImage, frame: FaceFrame, size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for j in 0..<size {
            for i in 0..<size {
                guard let c = photo.sample(frame.toImage(headPoint(i, j, size: size))) else { continue }
                let k = (j * size + i) * 4
                out[k] = UInt8(c.x.rounded()); out[k + 1] = UInt8(c.y.rounded()); out[k + 2] = UInt8(c.z.rounded())
                out[k + 3] = 255
            }
        }
        return out
    }

    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(c.x / 255, 2.2), pow(c.y / 255, 2.2), pow(c.z / 255, 2.2))
    }

    private static func median(_ values: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !values.isEmpty else { return nil }
        func med(_ xs: [Float]) -> Float { xs.sorted()[xs.count / 2] }
        return SIMD3(med(values.map(\.x)), med(values.map(\.y)), med(values.map(\.z)))
    }

    private static func color(_ tex: [UInt8], _ k: Int) -> SIMD3<Float> {
        SIMD3(Float(tex[k * 4]), Float(tex[k * 4 + 1]), Float(tex[k * 4 + 2]))
    }

    static func medianColor(_ tex: [UInt8], size: Int,
                            patches: [(SIMD2<Float>, Float)]) -> SIMD3<Float> {
        medianColor(tex, size: size, where: { p in patches.contains { simd_distance(p, $0.0) < $0.1 } })
            ?? SIMD3(184, 140, 120)
    }

    static func medianColor(_ tex: [UInt8], size: Int, where inRegion: (SIMD2<Float>) -> Bool,
                            accept: (SIMD3<Float>) -> Bool = { _ in true }) -> SIMD3<Float>? {
        var picked: [SIMD3<Float>] = []
        for j in 0..<size {
            for i in 0..<size where tex[(j * size + i) * 4 + 3] > 0 && inRegion(headPoint(i, j, size: size)) {
                let c = color(tex, j * size + i)
                if accept(c) { picked.append(c) }
            }
        }
        return median(picked)
    }

    /// Iris: the ring between pupil and limbus around each pupil, excluding sclera-bright and
    /// pupil-dark texels.
    static func irisColor(_ tex: [UInt8], size: Int, frame: FaceFrame) -> SIMD3<Float> {
        let pupils = (frame.points("leftPupil") + frame.points("rightPupil"))
        let centres = pupils.isEmpty ? [SIMD2<Float>(-0.30, 0.10), SIMD2<Float>(0.30, 0.10)] : pupils
        return medianColor(tex, size: size, where: { p in
            centres.contains { let d = simd_distance(p, $0); return d > 0.018 && d < 0.05 }
        }, accept: { c in let y = luma(c); return y > 25 && y < 150 }) ?? SIMD3(51, 87, 107)
    }

    /// Per-texel confidence that the photo shows skin or lip here — the projection mask.
    static func skinMask(_ tex: [UInt8], size: Int, skin: SIMD3<Float>, frame: FaceFrame,
                         lumaWindow: (Float, Float) = (0.52, 1.6)) -> [Float] {
        let skinSum = max(skin.x + skin.y + skin.z, 1)
        let skinChroma = SIMD2(skin.x, skin.y) / skinSum
        let skinY = max(luma(skin), 1)
        var mask = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                let k = j * size + i
                guard tex[k * 4 + 3] > 0 else { continue }
                let p = headPoint(i, j, size: size)
                // Face region only: background and shoulders never project.
                let e = simd_length((p - SIMD2(0, -0.22)) / SIMD2(0.80, 1.05))
                let region = 1 - smoothstep(0.85, 1.0, e)
                guard region > 0 else { continue }
                if frame.innerMouthContains(p) { continue }
                if frame.lipsContain(p) || frame.browsContain(p) { mask[k] = region; continue }
                let c = color(tex, k)
                let chroma = SIMD2(c.x, c.y) / max(c.x + c.y + c.z, 1)
                let dc = simd_length(chroma - skinChroma)
                let ratio = luma(c) / skinY
                let likeSkin = exp(-dc * dc / (2 * 0.035 * 0.035))
                    * smoothstep(lumaWindow.0 - 0.10, lumaWindow.0 + 0.10, ratio)
                    * (1 - smoothstep(lumaWindow.1 - 0.15, lumaWindow.1 + 0.15, ratio))
                mask[k] = likeSkin * region
            }
        }
        return mask
    }

    /// Divide out the photo's low-frequency lighting so it doesn't double with the avatar's own.
    /// The low-pass is normalized by the skin mask, so dark hair at the hairline doesn't pull the
    /// estimate down and over-brighten the forehead.
    static func delight(_ tex: inout [UInt8], size: Int, mask: [Float], skinLuma: Float) {
        var y = [Float](repeating: 0, count: size * size)
        var w = [Float](repeating: 0, count: size * size)
        for k in 0..<(size * size) {
            y[k] = luma(color(tex, k)) * mask[k]
            w[k] = mask[k]
        }
        let radius = max(size / 18, 2)
        blur(&y, size: size, radius: radius)
        blur(&w, size: size, radius: radius)
        for k in 0..<(size * size) where tex[k * 4 + 3] > 0 {
            guard w[k] > 0.05 else { continue }
            let low = y[k] / w[k]
            let gain = min(max(pow(skinLuma / max(low, 1), 0.75), 0.6), 1.8)
            for c in 0..<3 {
                tex[k * 4 + c] = UInt8(min(max(Float(tex[k * 4 + c]) * gain, 0), 255).rounded())
            }
        }
    }

    /// Three box passes ≈ Gaussian, separable, edge-clamped.
    static func blur(_ v: inout [Float], size: Int, radius: Int) {
        var tmp = [Float](repeating: 0, count: v.count)
        for _ in 0..<3 {
            for j in 0..<size {
                var acc: Float = 0
                for i in -radius...radius { acc += v[j * size + min(max(i, 0), size - 1)] }
                for i in 0..<size {
                    tmp[j * size + i] = acc / Float(2 * radius + 1)
                    acc += v[j * size + min(i + radius + 1, size - 1)] - v[j * size + max(i - radius, 0)]
                }
            }
            for i in 0..<size {
                var acc: Float = 0
                for j in -radius...radius { acc += tmp[min(max(j, 0), size - 1) * size + i] }
                for j in 0..<size {
                    v[j * size + i] = acc / Float(2 * radius + 1)
                    acc += tmp[min(j + radius + 1, size - 1) * size + i] - tmp[max(j - radius, 0) * size + i]
                }
            }
        }
    }

    // MARK: Hair

    /// Vision person segmentation over the whole portrait, normalized [0, 1], top-left origin.
    struct PersonMask {
        let width: Int
        let height: Int
        let values: [Float]
        let imageSize: SIMD2<Float>

        func value(atImage p: SIMD2<Float>) -> Float {
            let x = Int(p.x / imageSize.x * Float(width)), y = Int(p.y / imageSize.y * Float(height))
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return values[y * width + x]
        }
    }

    static func personMask(_ image: CGImage) -> PersonMask? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil,
              let pb = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { values[y * w + x] = Float(base[y * stride + x]) / 255 } }
        return PersonMask(width: w, height: h, values: values,
                          imageSize: SIMD2(Float(image.width), Float(image.height)))
    }

    /// Hair = the person, minus skin-like pixels, minus the inner face (brows, eyes, nostrils are
    /// dark but not hair), minus the body below the jaw except hair falling at the sides.
    static func hairCoverage(person: PersonMask, frame: FaceFrame, skinTex: [UInt8], skin: SIMD3<Float>,
                             size: Int) -> [Float] {
        let skinY = max(luma(skin), 1)
        let T = textureSize
        var out = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                let p = headPoint(i, j, size: size)
                let inner = simd_length((p - SIMD2(0, -0.22)) / SIMD2(0.58, 0.80))
                guard inner > 0.92 else { continue }
                guard p.y > -0.35 || (abs(p.x) > 0.55 && p.y > -0.95) else { continue }
                let personValue = person.value(atImage: frame.toImage(p))
                guard personValue > 0.3 else { continue }
                let (ti, tj) = texel(p, size: T)
                guard ti >= 0, tj >= 0, ti < T, tj < T else { continue }
                let k = tj * T + ti
                guard skinTex[k * 4 + 3] > 0 else { continue }
                let c = color(skinTex, k)
                // Hair reads darker than skin or off its chroma; skin-like pixels are excluded.
                let darker = 1 - smoothstep(0.55, 0.80, luma(c) / skinY)
                out[j * size + i] = personValue * darker
            }
        }
        return out
    }

    /// Hairline (scan up the midline), fringe (hair below 0.5 on the forehead), crown height and
    /// side width from the person mask, all in head units.
    static func fitHair(_ a: inout ExpressiveHeadRenderer.Anatomy, person: PersonMask, frame: FaceFrame,
                        coverage: [Float]?) {
        func isPerson(_ p: SIMD2<Float>) -> Bool { person.value(atImage: frame.toImage(p)) > 0.5 }
        if let cov = coverage {
            var y: Float = 0.32
            while y < 1.0 {
                let (i, j) = texel(SIMD2(0, y), size: reliefSize)
                if i >= 0, j >= 0, i < reliefSize, j < reliefSize, cov[j * reliefSize + i] > 0.5 { break }
                y += 0.01
            }
            if y < 1.0 {
                a.hairlineY = y
                a.fringe = y < 0.50 ? 1 : 0
            }
        }
        var crown: Float = 0.35
        var y: Float = 0.6
        while y < 1.9 {
            if isPerson(SIMD2(0, y)) || isPerson(SIMD2(-0.15, y)) || isPerson(SIMD2(0.15, y)) { crown = y }
            y += 0.02
        }
        a.hairHeight = (crown - 0.35) / 0.94
        var half: Float = 0
        for yy: Float in [0.30, 0.45, 0.60] {
            var x: Float = 0.5
            while x < 1.4 {
                if isPerson(SIMD2(x, yy)) || isPerson(SIMD2(-x, yy)) { half = max(half, x) }
                x += 0.02
            }
        }
        if half > 0.5 { a.hairWidth = half / 0.87 }
    }

    // MARK: Depth

    /// Depth Anything V2 on the canonical texture (letterboxed into the model's 518×392 input),
    /// normalized within the face, converted to head units and high-passed: the person's relief
    /// on top of the SDF's own shape, clamped so a bad depth frame can only be subtle.
    static func relief(from tex: [UInt8], size: Int, model: MLModel, outSize: Int) throws -> [Float] {
        let inW = 518, inH = 392
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let input = pb else { throw AnalyzerError.imageDecodeFailed }
        let side = inH, offsetX = (inW - inH) / 2
        CVPixelBufferLockBaseAddress(input, [])
        let base = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(input)
        for j in 0..<inH {
            for i in 0..<inW {
                let o = j * stride + i * 4
                let si = i - offsetX
                guard si >= 0, si < side else { base[o] = 0; base[o + 1] = 0; base[o + 2] = 0; base[o + 3] = 255; continue }
                // Bilinear: nearest-neighbour upsampling of the 512² texture aliases into the
                // depth model's input and comes back out as a grid in the relief.
                let fx = (Float(si) + 0.5) * Float(size) / Float(side) - 0.5
                let fy = (Float(j) + 0.5) * Float(size) / Float(side) - 0.5
                let x0 = min(max(Int(fx), 0), size - 2), y0 = min(max(Int(fy), 0), size - 2)
                let ax = min(max(fx - Float(x0), 0), 1), ay = min(max(fy - Float(y0), 0), 1)
                for (c, dst) in [(2, 0), (1, 1), (0, 2)] {
                    func t(_ x: Int, _ y: Int) -> Float { Float(tex[(y * size + x) * 4 + c]) }
                    let v = (t(x0, y0) * (1 - ax) + t(x0 + 1, y0) * ax) * (1 - ay)
                          + (t(x0, y0 + 1) * (1 - ax) + t(x0 + 1, y0 + 1) * ax) * ay
                    base[o + dst] = UInt8(min(max(v.rounded(), 0), 255))
                }
                base[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let depth = out.featureValue(for: "depth")?.imageBufferValue else { throw AnalyzerError.imageDecodeFailed }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let dStride = CVPixelBufferGetBytesPerRow(depth)
        let dBase = CVPixelBufferGetBaseAddress(depth)!
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        func d(_ x: Int, _ y: Int) -> Float {
            let row = dBase.advanced(by: min(max(y, 0), dh - 1) * dStride).assumingMemoryBound(to: Float16.self)
            return Float(row[min(max(x, 0), dw - 1)])
        }

        // Resample the face square to outSize² and collect face-region values for normalization.
        var z = [Float](repeating: 0, count: outSize * outSize)
        var faceValues: [Float] = []
        var faceWeight = [Float](repeating: 0, count: outSize * outSize)
        let sx = Float(dw) / Float(inW), sy = Float(dh) / Float(inH)
        for j in 0..<outSize {
            for i in 0..<outSize {
                let mx = Float(offsetX) + (Float(i) + 0.5) * Float(side) / Float(outSize)
                let my = (Float(j) + 0.5) * Float(side) / Float(outSize)
                let v = d(Int(mx * sx), Int(my * sy))
                z[j * outSize + i] = v
                let p = headPoint(i, j, size: outSize)
                let e = simd_length((p - SIMD2(0, -0.22)) / SIMD2(0.62, 0.85))
                let w = 1 - smoothstep(0.80, 1.0, e)
                faceWeight[j * outSize + i] = w
                if w > 0.99 { faceValues.append(v) }
            }
        }
        guard faceValues.count > 64 else { throw AnalyzerError.noFace }
        faceValues.sort()
        let lo = faceValues[faceValues.count * 2 / 100], hi = faceValues[faceValues.count * 98 / 100]
        guard hi > lo else { throw AnalyzerError.noFace }
        let faceDepth: Float = 0.50   // head units from cheek plane to nose tip, roughly
        for k in 0..<z.count { z[k] = (z[k] - lo) / (hi - lo) * faceDepth }
        // Band-pass: the fine blur removes the backbone's 14-px patch grid (≈9 texels here),
        // the coarse blur removes the overall head shape the SDF already provides.
        var fine = z, coarse = z
        blur(&fine, size: outSize, radius: max(outSize / 85, 2))
        blur(&coarse, size: outSize, radius: max(outSize / 40, 4))
        var relief = [Float](repeating: 0, count: z.count)
        for k in 0..<z.count {
            relief[k] = min(max(fine[k] - coarse[k], -0.035), 0.035) * faceWeight[k]
        }
        return relief
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
