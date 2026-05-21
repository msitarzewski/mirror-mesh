import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import MirrorMeshCore
import MirrorMeshWatermark

/// One-click test-persona identity mint (v1.1.0 follow-on).
///
/// **Why this exists**: the default auto-provisioned `.mmid` (1×1 transparent PNG)
/// and the capture-as-identity flow (the operator's own face) are both *degenerate*
/// visual tests for the photoreal substitution: the first is invisible, the second
/// looks "like you" because it IS you. The operator can't tell whether the
/// LivePortrait substitution is actually wired in, or whether the renderer is just
/// passing the camera frame straight through.
///
/// The Test Persona resolves that: at the press of a button we generate a 256×256
/// PNG of a clearly-stylized face (teal skin, magenta hair) — obviously NOT the
/// operator — mint it as a `self-as-source` `.mmid`, and hot-swap it into the
/// running pipeline. The operator switches to Mirror/Mask and immediately sees a
/// cartoony face moving with their expression. If the rendered face looks like
/// the operator, the substitution chain is broken.
///
/// **R1**: `selfAsSource` is the correct scheme here. The operator is the source
/// of their own consent to use an algorithmically-drawn face as their avatar; no
/// real third party is involved (the image is procedurally generated at runtime
/// with deterministic geometry, not pulled from a dataset). The disclosure text,
/// watermark, visible badge, and audible chirp are unchanged (R12).
///
/// **R6**: the mint+sign+persist sequence intentionally mirrors
/// `IdentitySelfCapture.mintAndPersist` (~30 lines). Lifting it into a shared
/// helper would couple two unrelated mint paths and balloon `IdentitySelfCapture`
/// with a multi-source factory; the cleaner option is to duplicate the
/// boilerplate once, with this note. If a third mint path lands we factor.
@MainActor
public enum TestPersona {

    // MARK: - Errors

    public enum PersonaError: Error, CustomStringConvertible {
        /// CoreGraphics / NSBitmapImageRep step failed while rendering the persona.
        case imageGenerationFailed(String)
        /// Signing or persisting the bundle failed. Wraps the underlying error string.
        case mintFailed(String)

        public var description: String {
            switch self {
            case .imageGenerationFailed(let m):
                return "TestPersona: image generation failed (\(m))"
            case .mintFailed(let m):
                return "TestPersona: mint failed (\(m))"
            }
        }
    }

    // MARK: - Tunables

    /// LivePortrait's source-image resolution. Same as `IdentitySelfCapture.outputSize`:
    /// the motion/warp/generator graph is trained on 256² inputs. The procedural face
    /// is drawn directly at this resolution so we never round-trip through a resize.
    static let outputSize: Int = 256

    /// Default location for the persisted test-persona bundle. Co-located with the
    /// default identity but *under a different filename* so loading the persona does
    /// not destroy the user's self-capture (or the auto-provisioned default). The
    /// dir is created on demand by `mintAndPersist`.
    ///
    /// `nonisolated` so it's usable as a default-parameter expression — same trick
    /// as `IdentitySelfCapture.defaultBundleURL`.
    public nonisolated static func defaultBundleURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MirrorMesh", isDirectory: true)
            .appendingPathComponent("test-persona.mmid", isDirectory: true)
    }

    // MARK: - Public API

    /// Render the procedural test persona to a 256×256 RGBA PNG and return the bytes.
    ///
    /// Visible to tests and to `mintAndPersist`. Drawing is deterministic: the same
    /// call always returns byte-identical PNGs (no random offsets), so the test
    /// fixture and the persisted bundle are reproducible.
    ///
    /// Color palette (chosen for instant "that is not me" visual contrast):
    /// - background: warm cream gradient
    /// - head/skin:  teal (`#3FB5A8`)
    /// - hair:       magenta (`#E94584`)
    /// - eyes:       deep navy (`#0F1A4D`) on white sclera
    /// - mouth:      coral (`#E25C5C`)
    /// - eyebrows:   match-hair magenta
    ///
    /// Landmark geometry is faithful to a human face's keypoint topology — eyes at
    /// ~40 % from top, ~30 % / ~70 % horizontally; nose centered at ~55 %; mouth at
    /// ~75 % — so LivePortrait's `MotionExtractor` can find sensible keypoints when
    /// `PhotorealBackend.prepareSource` runs on the persona.
    public static func generatePNG() -> Data {
        // We funnel everything through a CGContext rather than NSGraphicsContext.current
        // so the render is independent of any active AppKit drawing state. The bitmap
        // is allocated explicitly at 256x256 RGBA premultipliedFirst (BGRA) in sRGB,
        // which is what `NSBitmapImageRep(cgImage:)` round-trips losslessly to PNG.
        let size = outputSize
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGImageByteOrderInfo.order32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            // Returning empty Data on failure keeps the API non-throwing for callers
            // that just want to peek at the bytes; mintAndPersist explicitly checks
            // for empty and surfaces the error case via PersonaError.
            return Data()
        }

        drawPersona(into: ctx, size: CGFloat(size))

        guard let cgImage = ctx.makeImage() else { return Data() }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Generate, mint, sign, and persist the test persona as a self-as-source `.mmid`
    /// bundle. Returns the verified `(ConsentedIdentity, PNG bytes)` pair so the
    /// caller can hot-swap the running pipeline via
    /// `PipelineViewModel.refreshPhotorealIdentity()`.
    ///
    /// `persistTo` defaults to `defaultBundleURL()` — under
    /// `~/Library/Application Support/MirrorMesh/test-persona.mmid`, deliberately a
    /// different filename from `default.mmid` so the user's self-capture is preserved
    /// across persona loads.
    public static func mintAndPersist(
        persistTo url: URL = TestPersona.defaultBundleURL(),
        runtimeVersion: String = MirrorMeshCore.version
    ) async throws -> (ConsentedIdentity, Data) {
        let pngBytes = generatePNG()
        guard !pngBytes.isEmpty else {
            throw PersonaError.imageGenerationFailed("generatePNG returned empty bytes")
        }
        do {
            return try writeAndVerify(
                pngBytes: pngBytes,
                displayName: "Test Persona",
                bundleURL: url,
                runtimeVersion: runtimeVersion
            )
        } catch {
            throw PersonaError.mintFailed("\(error)")
        }
    }

    // MARK: - Drawing

    /// Compose the persona into `ctx`. Pure CoreGraphics — no AppKit drawing context
    /// state is touched. Coordinate space: origin bottom-left (CG default); `size` is
    /// the side length of the square output.
    private static func drawPersona(into ctx: CGContext, size: CGFloat) {
        // Background — warm cream gradient (top→bottom). Subtle so the face pops.
        let bgColors = [
            CGColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 1.0),
            CGColor(red: 0.92, green: 0.86, blue: 0.74, alpha: 1.0),
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: bgColors as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
        } else {
            ctx.setFillColor(CGColor(red: 0.96, green: 0.91, blue: 0.82, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }

        // Color palette. Defined as a single block so palette tweaks live in one place.
        let skin = CGColor(red: 0.247, green: 0.710, blue: 0.659, alpha: 1.0)   // #3FB5A8 teal
        let hair = CGColor(red: 0.914, green: 0.271, blue: 0.518, alpha: 1.0)   // #E94584 magenta
        let eyeWhite = CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1.0)
        let eyeDark  = CGColor(red: 0.059, green: 0.102, blue: 0.302, alpha: 1.0) // #0F1A4D navy
        let mouth = CGColor(red: 0.886, green: 0.361, blue: 0.361, alpha: 1.0)   // #E25C5C coral
        let cheek = CGColor(red: 0.984, green: 0.541, blue: 0.541, alpha: 0.45)  // soft pink, semi-transparent
        let shadow = CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.18)

        // Geometry — fractions of `size`. Mirrors a human-face landmark layout so
        // LivePortrait's MotionExtractor can find sensible keypoints. Comments give
        // the standard reference point (Vision uses normalized bottom-left; this is
        // also bottom-left because we're in CG default coordinates).
        let cx = size * 0.5
        // Head — vertical oval centered horizontally, slightly below center to leave
        // room for hair on top. Width ~70 % of frame, height ~85 %.
        let headWidth: CGFloat = size * 0.70
        let headHeight: CGFloat = size * 0.85
        let headCenterY = size * 0.45
        let headRect = CGRect(
            x: cx - headWidth / 2,
            y: headCenterY - headHeight / 2,
            width: headWidth,
            height: headHeight
        )

        // Drop shadow behind the head for depth.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: shadow)
        ctx.setFillColor(skin)
        ctx.fillEllipse(in: headRect)
        ctx.restoreGState()

        // Hair — a rounded cap covering the top ~38 % of the head. Drawn as a clipped
        // ellipse so the hairline curves over the forehead instead of cutting straight
        // across (which would obscure the eyebrow region and confuse keypoint detection).
        ctx.saveGState()
        let hairClip = CGPath(rect: CGRect(
            x: headRect.minX - 8,
            y: headRect.midY + headRect.height * 0.10,    // hair sits on the upper 40 %
            width: headRect.width + 16,
            height: headRect.height * 0.55
        ), transform: nil)
        ctx.addPath(hairClip)
        ctx.clip()
        let hairOvalRect = CGRect(
            x: headRect.minX - 6,
            y: headRect.midY - headRect.height * 0.05,
            width: headRect.width + 12,
            height: headRect.height * 0.70
        )
        ctx.setFillColor(hair)
        ctx.fillEllipse(in: hairOvalRect)
        ctx.restoreGState()

        // Side bangs / temples — two small triangles framing the cheeks so the head
        // silhouette doesn't look like a bald oval with a beanie on top.
        ctx.setFillColor(hair)
        let bangLeft = CGMutablePath()
        bangLeft.move(to: CGPoint(x: headRect.minX + headRect.width * 0.04, y: headRect.midY + headRect.height * 0.18))
        bangLeft.addLine(to: CGPoint(x: headRect.minX - 4, y: headRect.midY - headRect.height * 0.05))
        bangLeft.addLine(to: CGPoint(x: headRect.minX + headRect.width * 0.10, y: headRect.midY - headRect.height * 0.02))
        bangLeft.closeSubpath()
        ctx.addPath(bangLeft)
        ctx.fillPath()
        let bangRight = CGMutablePath()
        bangRight.move(to: CGPoint(x: headRect.maxX - headRect.width * 0.04, y: headRect.midY + headRect.height * 0.18))
        bangRight.addLine(to: CGPoint(x: headRect.maxX + 4, y: headRect.midY - headRect.height * 0.05))
        bangRight.addLine(to: CGPoint(x: headRect.maxX - headRect.width * 0.10, y: headRect.midY - headRect.height * 0.02))
        bangRight.closeSubpath()
        ctx.addPath(bangRight)
        ctx.fillPath()

        // Eyes — two ovals at ~40 % from the top (= 60 % from bottom in CG coords),
        // at horizontal 30 % and 70 %. White sclera + larger dark iris/pupil so the
        // keypoint detector reads them as eyes.
        let eyeY = size * (1.0 - 0.40)
        let eyeW: CGFloat = size * 0.13
        let eyeH: CGFloat = size * 0.08
        let leftEyeX = size * 0.30
        let rightEyeX = size * 0.70

        for ex in [leftEyeX, rightEyeX] {
            let scleraRect = CGRect(x: ex - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH)
            ctx.setFillColor(eyeWhite)
            ctx.fillEllipse(in: scleraRect)
            // Iris/pupil — centered, ~65 % of eye width
            let irisSide = min(eyeW, eyeH) * 0.95
            let irisRect = CGRect(
                x: ex - irisSide / 2,
                y: eyeY - irisSide / 2,
                width: irisSide,
                height: irisSide
            )
            ctx.setFillColor(eyeDark)
            ctx.fillEllipse(in: irisRect)
            // Catchlight — a tiny white dot in the upper-right of the iris so the eye
            // doesn't look dead. Helps the operator perceive the persona as "alive".
            let highlight = CGRect(
                x: ex + irisSide * 0.10,
                y: eyeY + irisSide * 0.10,
                width: irisSide * 0.18,
                height: irisSide * 0.18
            )
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.fillEllipse(in: highlight)
        }

        // Eyebrows — short magenta bars just above each eye. Slight upward tilt at
        // the outer edge for a friendly, neutral expression (MotionExtractor reads
        // brow position; flat brows still produce reasonable keypoints).
        ctx.setFillColor(hair)
        ctx.setLineWidth(0)
        for (ex, tilt) in [(leftEyeX, -1.0), (rightEyeX, 1.0)] {
            let browW: CGFloat = size * 0.13
            let browH: CGFloat = size * 0.015
            let by = eyeY + eyeH * 0.7 + 4
            let bx = ex - browW / 2
            ctx.saveGState()
            ctx.translateBy(x: ex, y: by)
            ctx.rotate(by: CGFloat(tilt) * 0.10)
            ctx.translateBy(x: -ex, y: -by)
            let path = CGPath(
                roundedRect: CGRect(x: bx, y: by, width: browW, height: browH),
                cornerWidth: browH / 2,
                cornerHeight: browH / 2,
                transform: nil
            )
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Nose — a soft triangle, centered, between eyes and mouth at ~55 % from top
        // (= 45 % from bottom in CG coords). Filled with a slightly-darker skin tone
        // so it has presence without competing with the eyes for attention.
        let noseY = size * (1.0 - 0.55)
        let noseW: CGFloat = size * 0.07
        let noseH: CGFloat = size * 0.10
        let noseTop = CGPoint(x: cx, y: noseY + noseH / 2)
        let noseLeft = CGPoint(x: cx - noseW / 2, y: noseY - noseH / 2)
        let noseRight = CGPoint(x: cx + noseW / 2, y: noseY - noseH / 2)
        let nosePath = CGMutablePath()
        nosePath.move(to: noseTop)
        nosePath.addQuadCurve(to: noseRight, control: CGPoint(x: cx + noseW * 0.6, y: noseY))
        nosePath.addLine(to: noseLeft)
        nosePath.addQuadCurve(to: noseTop, control: CGPoint(x: cx - noseW * 0.6, y: noseY))
        nosePath.closeSubpath()
        ctx.addPath(nosePath)
        ctx.setFillColor(CGColor(red: 0.196, green: 0.620, blue: 0.569, alpha: 1.0)) // teal -10 % brightness
        ctx.fillPath()

        // Mouth — coral-filled curve at ~75 % from top (= 25 % from bottom). Slight
        // smile so the persona reads as friendly. Drawn as a rounded rect rather than
        // a true mouth shape because LivePortrait's reenactment will deform the mouth
        // region; a simpler base shape gives the warp network less prior to fight.
        let mouthY = size * (1.0 - 0.75)
        let mouthW: CGFloat = size * 0.22
        let mouthH: CGFloat = size * 0.04
        let mouthRect = CGRect(
            x: cx - mouthW / 2,
            y: mouthY - mouthH / 2,
            width: mouthW,
            height: mouthH
        )
        ctx.setFillColor(mouth)
        let mouthPath = CGPath(
            roundedRect: mouthRect,
            cornerWidth: mouthH,
            cornerHeight: mouthH,
            transform: nil
        )
        ctx.addPath(mouthPath)
        ctx.fillPath()

        // Cheeks — two small semi-transparent pink dots flanking the nose. Pure
        // visual polish; harmless to landmark detection.
        let cheekY = mouthY + mouthH + size * 0.04
        let cheekSize: CGFloat = size * 0.07
        for ex in [size * 0.27, size * 0.73] {
            let r = CGRect(x: ex - cheekSize / 2, y: cheekY - cheekSize / 2, width: cheekSize, height: cheekSize)
            ctx.setFillColor(cheek)
            ctx.fillEllipse(in: r)
        }
    }

    // MARK: - Mint + persist (mirrors IdentitySelfCapture.mintAndPersist by design)

    /// Sign, persist, and re-verify. Same shape as
    /// `IdentitySelfCapture.mintAndPersist` (private there); duplicated here to keep
    /// the two mint paths decoupled per the note at the top of this file.
    private static func writeAndVerify(
        pngBytes: Data,
        displayName: String,
        bundleURL: URL,
        runtimeVersion: String
    ) throws -> (ConsentedIdentity, Data) {
        let pngHash = SHA256.hash(data: pngBytes).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: displayName,
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: "v0.6+",
            issuer_public_key_b64: pubB64
        )

        // Sign canonical(identity-without-signature) || pngBytes — identical encoding
        // to `DefaultIdentityProvider.mintAndPersist` and the consent CLI.
        var clearable = identity
        clearable.signature_b64 = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var message = try enc.encode(clearable)
        message.append(pngBytes)
        let sig = try key.signature(for: message)
        identity.signature_b64 = sig.base64EncodedString()

        // Ensure parent dir exists, then write atomically. Idempotent overwrite:
        // a second `mintAndPersist(...)` call replaces identity.json + source.png
        // in place — same behavior as IdentitySelfCapture / DefaultIdentityProvider.
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConsentedIdentityBundle.write(identity: identity, pngBytes: pngBytes, to: bundleURL)

        // Re-read + verify so we never hand back an unsigned/invalid pair.
        let (verified, verifiedPng) = try ConsentedIdentityBundle.read(from: bundleURL)
        try ConsentedIdentityVerifier.verify(
            identity: verified,
            pngBytes: verifiedPng,
            runtimeVersion: runtimeVersion
        )
        return (verified, verifiedPng)
    }
}
