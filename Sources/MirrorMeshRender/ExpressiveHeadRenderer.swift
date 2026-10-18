import Foundation
import Metal
import CoreGraphics
import simd
import MirrorMeshCore

public enum ExpressiveHeadRendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .missingFunction(let n):        return "ExpressiveHeadRenderer: missing Metal function '\(n)'"
        case .pipelineCreationFailed(let s): return "ExpressiveHeadRenderer: pipeline creation failed (\(s))"
        }
    }
}

/// Draws the SDF head from `ExpressiveHead.metal`: one quad over the head's screen rectangle,
/// raymarched per fragment. Same shape as `PhotorealOverlay` — a single pipeline state built at
/// construction, per-frame uniforms via `setVertexBytes`/`setFragmentBytes`, premultiplied
/// source-over so it layers onto the passthrough.
///
/// Inputs are the solver's ARKit-52 coefficients (not the classic rig's 18 stylized shapes), so
/// everything the solver measures — gaze, squint, press, roll, dimple, tongue — reaches the face.
///
/// Placement: the face bounding box (Vision convention, normalized, origin top-left) maps to the
/// head's brow-to-chin span, `faceSpan` head-local units tall, centred `faceCenterY` below the
/// head origin. The quad extends past the face to cover hair, ears and neck.
public final class ExpressiveHeadRenderer {
    /// Linear-RGB palette. Defaults read as a warm, neutral stylized character.
    public struct Appearance: Sendable, Equatable {
        public var skin: SIMD3<Float>
        public var hair: SIMD3<Float>
        public var iris: SIMD3<Float>
        public var lip: SIMD3<Float>

        public init(skin: SIMD3<Float> = SIMD3(0.72, 0.47, 0.36),
                    hair: SIMD3<Float> = SIMD3(0.10, 0.06, 0.04),
                    iris: SIMD3<Float> = SIMD3(0.20, 0.34, 0.42),
                    lip: SIMD3<Float> = SIMD3(0.62, 0.30, 0.29)) {
            self.skin = skin
            self.hair = hair
            self.iris = iris
            self.lip = lip
        }
    }

    /// Head proportions in head-local units (eye centres fixed at (±0.30, 0.10), so everything
    /// is relative to inter-ocular distance). `neutral` reproduces the stock head; a portrait
    /// fit (`PortraitAnalyzer`) moves these toward one person's face.
    public struct Anatomy: Sendable, Equatable {
        public var browLift: Float = 0
        public var noseTipY: Float = -0.17
        public var noseWidth: Float = 1          // scale on nostril-wing spacing and size
        public var mouthY: Float = -0.50
        public var mouthHalfWidth: Float = 0.185
        public var upperLip: Float = 0.042       // half-thickness
        public var lowerLip: Float = 0.050
        public var chinShift: Float = 0          // + = chin lower, longer face
        public var jawWidth: Float = 1           // scale on jaw / jawline width
        public var cheekWidth: Float = 1         // scale on midface width
        public var eyeScale: Float = 1
        /// Hair: front hairline height, fringe on/off, crown height and width scales.
        public var hairlineY: Float = 0.58
        public var fringe: Float = 1
        public var hairHeight: Float = 1
        public var hairWidth: Float = 1

        public init() {}
        public static let neutral = Anatomy()

        /// Clamp every field to a range the SDF stays well-formed in, so a bad landmark fit
        /// degrades to "a bit off" rather than a broken head.
        public func clamped() -> Anatomy {
            func c(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v.isFinite ? min(max(v, lo), hi) : (lo + hi) / 2 }
            var a = self
            // Ranges cover real proportions (a long midface puts the nose tip ~0.6 inter-ocular
            // distances below the eyes and the mouth ~1.2) while keeping parts from colliding.
            a.browLift = c(browLift, -0.10, 0.10)
            a.noseTipY = c(noseTipY, -0.42, -0.08)
            a.noseWidth = c(noseWidth, 0.75, 1.40)
            a.mouthY = c(max(mouthY, -0.80), -0.80, -0.38)
            a.mouthHalfWidth = c(mouthHalfWidth, 0.14, 0.26)
            a.upperLip = c(upperLip, 0.020, 0.065)
            a.lowerLip = c(lowerLip, 0.025, 0.075)
            a.chinShift = c(chinShift, -0.15, 0.20)
            a.jawWidth = c(jawWidth, 0.80, 1.20)
            a.cheekWidth = c(cheekWidth, 0.85, 1.15)
            a.eyeScale = c(eyeScale, 0.80, 1.20)
            a.hairlineY = c(hairlineY, 0.40, 0.80)
            a.fringe = fringe > 0.5 ? 1 : 0
            a.hairHeight = c(hairHeight, 0.85, 1.30)
            a.hairWidth = c(hairWidth, 0.88, 1.25)
            return a
        }

        var packed: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
            (SIMD4(browLift, noseTipY, noseWidth, mouthY),
             SIMD4(mouthHalfWidth, upperLip, lowerLip, chinShift),
             SIMD4(jawWidth, cheekWidth, eyeScale, 0),
             SIMD4(hairlineY, fringe, hairHeight, hairWidth))
        }
    }

    /// Everything derived from one consented portrait. Built off the render thread by
    /// `PortraitAnalyzer`; handed to `setLikeness(_:)`.
    public struct Likeness: Sendable {
        public var anatomy: Anatomy
        public var appearance: Appearance
        /// Square RGBA8 portrait crop, sRGB-encoded and de-lit. Alpha = how confidently the pixel
        /// is skin or lip (0 for hair, eyes, teeth, background) — the shader's projection mask.
        public var albedo: [UInt8]
        public var albedoSize: Int
        /// Square map of high-passed relief in head units (same UV space as `albedo`), or nil
        /// when no depth model was available.
        public var relief: [Float]?
        public var reliefSize: Int
        /// Square map (same UV space, `reliefSize`²) of how confidently the portrait shows hair —
        /// lets the hair take the portrait's colour where it faces the camera. Nil = procedural.
        public var hairCoverage: [Float]?
        /// Affine map from head-local (x, y, 1) to portrait UV: u = dot(uRow, ·), v = dot(vRow, ·).
        public var uRow: SIMD3<Float>
        public var vRow: SIMD3<Float>
        public var reliefGain: Float

        public init(anatomy: Anatomy, appearance: Appearance, albedo: [UInt8], albedoSize: Int,
                    relief: [Float]?, reliefSize: Int, uRow: SIMD3<Float>, vRow: SIMD3<Float>,
                    reliefGain: Float = 0.6, hairCoverage: [Float]? = nil) {
            self.hairCoverage = hairCoverage
            self.anatomy = anatomy
            self.appearance = appearance
            self.albedo = albedo
            self.albedoSize = albedoSize
            self.relief = relief
            self.reliefSize = reliefSize
            self.uRow = uRow
            self.vRow = vRow
            self.reliefGain = reliefGain
        }
    }

    public struct Options: Sendable {
        public var appearance: Appearance
        /// Camera-space direction toward the key light.
        public var keyLightDir: SIMD3<Float>
        /// Head size relative to the face box. 1 = the avatar's face covers the operator's face.
        public var scale: Float
        public var opacity: Float
        /// Raymarch step budget per pixel. Misses exit early; this only bounds grazing rays.
        public var maxSteps: Int

        public init(appearance: Appearance = .init(),
                    keyLightDir: SIMD3<Float> = simd_normalize(SIMD3(-0.45, 0.55, 0.70)),
                    scale: Float = 1.0,
                    opacity: Float = 1.0,
                    maxSteps: Int = 160) {
            self.appearance = appearance
            self.keyLightDir = keyLightDir
            self.scale = scale
            self.opacity = opacity
            self.maxSteps = maxSteps
        }
    }

    /// Head pose in radians. Unlike the classic rig's matrix order, signs follow the operator:
    /// positive yaw turns the face toward image-right, positive pitch tilts it up, positive roll
    /// tilts it clockwise on screen (image-right side down) — the `LandmarkSolver` conventions.
    public struct Pose: Sendable, Equatable {
        public var yaw: Float
        public var pitch: Float
        public var roll: Float
        public init(yaw: Float = 0, pitch: Float = 0, roll: Float = 0) {
            self.yaw = yaw; self.pitch = pitch; self.roll = roll
        }
    }

    /// Screen placement for one frame. Exposed for tests.
    public struct Layout: Sendable, Equatable {
        public var rectNDC: SIMD4<Float>
        public var localRect: SIMD4<Float>
        public var unitsPerPixel: Float
    }

    /// Head-local span covered by Vision's face box (brows → chin) and where its centre sits.
    public static let faceSpan: Float = 1.45
    public static let faceCenterY: Float = -0.28
    /// Head-local rectangle the quad covers: hair and ears on the sides, neck below.
    public static let localRect = SIMD4<Float>(-1.30, -2.00, 1.30, 1.35)

    /// The order `ExpressiveHead.metal` indexes coefficients in.
    public static let coefficientOrder: [BlendshapeKey] = BlendshapeKey.allCases

    /// Mirrors `ExpressiveHeadUniforms` in ExpressiveHead.metal byte-for-byte (18 × float4).
    private struct Uniforms {
        var rectNDC: SIMD4<Float>
        var localRect: SIMD4<Float>
        var rotRow0: SIMD4<Float>
        var rotRow1: SIMD4<Float>
        var rotRow2: SIMD4<Float>
        var skinColor: SIMD4<Float>
        var hairColor: SIMD4<Float>
        var irisColor: SIMD4<Float>
        var lipColor: SIMD4<Float>
        var keyLightDir: SIMD4<Float>
        var params: SIMD4<Float>
        var anat0: SIMD4<Float>
        var anat1: SIMD4<Float>
        var anat2: SIMD4<Float>
        var anat3: SIMD4<Float>
        var likeness: SIMD4<Float>
        var uvRowU: SIMD4<Float>
        var uvRowV: SIMD4<Float>
    }

    public let pipelineState: MTLRenderPipelineState
    public var options: Options
    /// Current likeness (nil = generic head). Set via `setLikeness(_:)`.
    public private(set) var likeness: Likeness?

    private let device: MTLDevice
    private var albedoTexture: MTLTexture
    private var reliefTexture: MTLTexture

    public init(context: MetalContext, options: Options = .init()) throws {
        guard let vfn = context.library.makeFunction(name: "expressive_head_vertex") else {
            throw ExpressiveHeadRendererError.missingFunction("expressive_head_vertex")
        }
        guard let ffn = context.library.makeFunction(name: "expressive_head_fragment") else {
            throw ExpressiveHeadRendererError.missingFunction("expressive_head_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Premultiplied source-over, same as PhotorealOverlay: the fragment emits (rgb·a, a).
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.pipelineState = try context.device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw ExpressiveHeadRendererError.pipelineCreationFailed(String(describing: error))
        }
        self.options = options
        self.device = context.device
        guard let albedo = Self.makeTexture(device: device, format: .rgba8Unorm, size: 1, bytes: [0, 0, 0, 0], bytesPerPixel: 4),
              let relief = Self.makeTexture(device: device, format: .rg32Float, size: 1, bytes: [Float(0), 0], bytesPerPixel: 8)
        else { throw ExpressiveHeadRendererError.pipelineCreationFailed("placeholder textures") }
        self.albedoTexture = albedo
        self.reliefTexture = relief
    }

    /// Install (or clear) a portrait likeness. Uploads its textures once; per-frame cost after
    /// this is two texture samples per surface evaluation.
    public func setLikeness(_ likeness: Likeness?) {
        guard let l = likeness,
              l.albedoSize > 0, l.albedo.count == l.albedoSize * l.albedoSize * 4,
              let albedo = Self.makeTexture(device: device, format: .rgba8Unorm, size: l.albedoSize,
                                            bytes: l.albedo, bytesPerPixel: 4)
        else {
            self.likeness = nil
            if let a = Self.makeTexture(device: device, format: .rgba8Unorm, size: 1, bytes: [UInt8](repeating: 0, count: 4), bytesPerPixel: 4),
               let r = Self.makeTexture(device: device, format: .rg32Float, size: 1, bytes: [Float(0), 0], bytesPerPixel: 8) {
                albedoTexture = a
                reliefTexture = r
            }
            return
        }
        albedoTexture = albedo
        // Relief (r) and hair coverage (g) share one rg32Float texture in the relief UV space.
        let n = l.reliefSize
        let relief = l.relief.flatMap { $0.count == n * n ? $0 : nil }
        let hair = l.hairCoverage.flatMap { $0.count == n * n ? $0 : nil }
        if n > 0, relief != nil || hair != nil {
            var rg = [Float](repeating: 0, count: n * n * 2)
            for k in 0..<(n * n) {
                rg[k * 2] = relief?[k] ?? 0
                rg[k * 2 + 1] = hair?[k] ?? 0
            }
            if let tex = Self.makeTexture(device: device, format: .rg32Float, size: n, bytes: rg, bytesPerPixel: 8) {
                reliefTexture = tex
            }
        } else if let tex = Self.makeTexture(device: device, format: .rg32Float, size: 1, bytes: [Float(0), 0], bytesPerPixel: 8) {
            reliefTexture = tex
        }
        self.likeness = l
    }

    private static func makeTexture<T>(device: MTLDevice, format: MTLPixelFormat, size: Int,
                                       bytes: [T], bytesPerPixel: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: size * bytesPerPixel)
        }
        return tex
    }

    /// Encode the head into an active render pass. `faceBoundingBox` nil centres a default-sized
    /// head in the viewport (synthetic fixtures without Vision).
    public func encode(
        into encoder: MTLRenderCommandEncoder,
        coefficients: [BlendshapeKey: Float],
        pose: Pose,
        faceBoundingBox: CGRect?,
        viewportWidth: Int,
        viewportHeight: Int
    ) {
        guard let layout = Self.layout(faceBoundingBox: faceBoundingBox,
                                       viewportWidth: viewportWidth,
                                       viewportHeight: viewportHeight,
                                       scale: options.scale) else { return }
        let rows = Self.rotationRows(pose)
        let a = likeness?.appearance ?? options.appearance
        let anatomy = (likeness?.anatomy ?? .neutral).packed
        var uniforms = Uniforms(
            rectNDC: layout.rectNDC,
            localRect: layout.localRect,
            rotRow0: SIMD4(rows.0, 0),
            rotRow1: SIMD4(rows.1, 0),
            rotRow2: SIMD4(rows.2, 0),
            skinColor: SIMD4(a.skin, 1),
            hairColor: SIMD4(a.hair, 1),
            irisColor: SIMD4(a.iris, 1),
            lipColor: SIMD4(a.lip, 1),
            keyLightDir: SIMD4(simd_normalize(options.keyLightDir), 0),
            params: SIMD4(simd_clamp(options.opacity, 0, 1),
                          layout.unitsPerPixel,
                          Float(max(options.maxSteps, 8)),
                          0),
            anat0: anatomy.0,
            anat1: anatomy.1,
            anat2: anatomy.2,
            anat3: anatomy.3,
            likeness: SIMD4(likeness == nil ? 0 : 1,
                            likeness?.relief == nil ? 0 : (likeness?.reliefGain ?? 0),
                            likeness?.hairCoverage == nil ? 0 : 1,
                            0),
            uvRowU: SIMD4(likeness?.uRow ?? .zero, 0),
            uvRowV: SIMD4(likeness?.vRow ?? .zero, 0)
        )
        var packed = Self.packCoefficients(coefficients)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&packed, length: packed.count * MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentTexture(albedoTexture, index: 0)
        encoder.setFragmentTexture(reliefTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Render one frame of the head over a flat background into a CPU-readable BGRA buffer.
    /// Deterministic for a given input on a given GPU — the basis for golden tests, previews,
    /// and re-rendering a recorded coefficient stream.
    public func renderOffscreen(context: MetalContext,
                                coefficients: [BlendshapeKey: Float],
                                pose: Pose = .init(),
                                faceBoundingBox: CGRect?,
                                width: Int,
                                height: Int,
                                background: SIMD4<Double> = SIMD4(0.30, 0.32, 0.36, 1)) throws
        -> (bgra: [UInt8], commandBuffer: MTLCommandBuffer) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = context.device.makeTexture(descriptor: desc) else {
            throw ExpressiveHeadRendererError.pipelineCreationFailed("offscreen target")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: background.x, green: background.y,
                                                            blue: background.z, alpha: background.w)
        guard let cb = context.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            throw ExpressiveHeadRendererError.pipelineCreationFailed("offscreen encoder")
        }
        encode(into: enc, coefficients: coefficients, pose: pose, faceBoundingBox: faceBoundingBox,
               viewportWidth: width, viewportHeight: height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (bytes, cb)
    }

    // MARK: - Pure helpers (unit-tested)

    /// 52 floats in `coefficientOrder`, clamped to [0, 1]; missing keys read as 0.
    public static func packCoefficients(_ c: [BlendshapeKey: Float]) -> [Float] {
        coefficientOrder.map { key in
            let v = c[key] ?? 0
            return v.isNaN ? 0 : simd_clamp(v, 0, 1)
        }
    }

    /// Rows of R = Ry(yaw) · Rx(pitch) · Rz(-roll), mapping head-local into camera space.
    /// +z is toward the viewer and +y up, so a positive Rx tilts the face up and the negated roll
    /// turns a positive (clockwise-on-screen) solver roll into a clockwise rotation.
    public static func rotationRows(_ pose: Pose) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let (cy, sy) = (cos(pose.yaw), sin(pose.yaw))
        let (cp, sp) = (cos(pose.pitch), sin(pose.pitch))
        let (cr, sr) = (cos(-pose.roll), sin(-pose.roll))
        let ry = simd_float3x3(rows: [SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)])
        let rx = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cp, sp), SIMD3(0, -sp, cp)])
        let rz = simd_float3x3(rows: [SIMD3(cr, -sr, 0), SIMD3(sr, cr, 0), SIMD3(0, 0, 1)])
        let m = ry * rx * rz
        // simd matrices are column-major; row i is (col0[i], col1[i], col2[i]).
        let t = m.transpose
        return (t.columns.0, t.columns.1, t.columns.2)
    }

    /// Where the quad lands for this frame, or nil for a degenerate viewport/box.
    public static func layout(faceBoundingBox: CGRect?,
                              viewportWidth: Int,
                              viewportHeight: Int,
                              scale: Float) -> Layout? {
        let w = Float(viewportWidth), h = Float(viewportHeight)
        guard w > 0, h > 0, scale > 0 else { return nil }
        let box = faceBoundingBox ?? CGRect(x: 0.5 - 0.55 * Double(h / w) * 0.5, y: 0.225,
                                            width: 0.55 * Double(h / w), height: 0.55)
        guard box.width > 0, box.height > 0 else { return nil }

        let pixelsPerUnit = Float(box.height) * h * scale / faceSpan
        guard pixelsPerUnit > 0.5 else { return nil }
        let originX = Float(box.midX) * w
        let originY = Float(box.midY) * h + faceCenterY * pixelsPerUnit  // image y grows downward

        let r = localRect
        let left = originX + r.x * pixelsPerUnit
        let right = originX + r.z * pixelsPerUnit
        let top = originY - r.w * pixelsPerUnit
        let bottom = originY - r.y * pixelsPerUnit
        let rectNDC = SIMD4<Float>(left / w * 2 - 1,
                                   1 - bottom / h * 2,
                                   (right - left) / w * 2,
                                   (bottom - top) / h * 2)
        return Layout(rectNDC: rectNDC, localRect: r, unitsPerPixel: 1 / pixelsPerUnit)
    }
}
