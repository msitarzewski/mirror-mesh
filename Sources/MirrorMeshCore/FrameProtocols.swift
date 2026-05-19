import Foundation
import CoreVideo
import simd

/// Common protocol for any frame flowing through the pipeline. Each stage's output type conforms.
public protocol PipelineFrame: Sendable {
    var frameID: FrameID { get }
    var hostTimeNs: UInt64 { get }
}

/// A raw captured camera frame.
///
/// `@unchecked Sendable`: `CVPixelBuffer` is reference-counted and not formally Sendable,
/// but CoreVideo guarantees it's safe to pass across actors when no thread is
/// holding a base-address lock. The pipeline never holds the base address across `await`.
public struct CapturedFrame: PipelineFrame, @unchecked Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int

    public init(frameID: FrameID,
                hostTimeNs: UInt64,
                pixelBuffer: CVPixelBuffer,
                width: Int,
                height: Int) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
    }
}

/// 2D landmark point in normalized image space (origin top-left, both axes [0,1]).
public struct LandmarkPoint: Sendable, Codable, Hashable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
    public var simd: SIMD2<Float> { SIMD2(x, y) }
}

/// Face landmarks for a single frame. The canonical point ordering follows the Apple Vision
/// 76-point set documented in `docs/landmark-schema.md`.
public struct LandmarkFrame: PipelineFrame, Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let points: [LandmarkPoint]
    public let confidence: Float
    public let faceBoundingBoxNorm: CGRect  // normalized [0,1] image space

    public init(frameID: FrameID,
                hostTimeNs: UInt64,
                points: [LandmarkPoint],
                confidence: Float,
                faceBoundingBoxNorm: CGRect) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.points = points
        self.confidence = confidence
        self.faceBoundingBoxNorm = faceBoundingBoxNorm
    }
}

/// ARKit-compatible blendshape keys. The 52-coef set; spelling matches ARKit conventions.
public enum BlendshapeKey: String, Sendable, Codable, CaseIterable, Hashable {
    case eyeBlinkLeft, eyeBlinkRight
    case eyeLookDownLeft, eyeLookDownRight
    case eyeLookInLeft, eyeLookInRight
    case eyeLookOutLeft, eyeLookOutRight
    case eyeLookUpLeft, eyeLookUpRight
    case eyeSquintLeft, eyeSquintRight
    case eyeWideLeft, eyeWideRight
    case jawForward, jawLeft, jawRight, jawOpen
    case mouthClose, mouthFunnel, mouthPucker
    case mouthLeft, mouthRight
    case mouthSmileLeft, mouthSmileRight
    case mouthFrownLeft, mouthFrownRight
    case mouthDimpleLeft, mouthDimpleRight
    case mouthStretchLeft, mouthStretchRight
    case mouthRollLower, mouthRollUpper
    case mouthShrugLower, mouthShrugUpper
    case mouthPressLeft, mouthPressRight
    case mouthLowerDownLeft, mouthLowerDownRight
    case mouthUpperUpLeft, mouthUpperUpRight
    case browDownLeft, browDownRight
    case browInnerUp
    case browOuterUpLeft, browOuterUpRight
    case cheekPuff
    case cheekSquintLeft, cheekSquintRight
    case noseSneerLeft, noseSneerRight
    case tongueOut
}

/// Blendshape coefficients for a single frame. Each value clamped to [0, 1].
public struct BlendshapeFrame: PipelineFrame, Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let coefficients: [BlendshapeKey: Float]

    public init(frameID: FrameID, hostTimeNs: UInt64, coefficients: [BlendshapeKey: Float]) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.coefficients = coefficients
    }

    public func coefficient(_ key: BlendshapeKey) -> Float {
        coefficients[key] ?? 0
    }
}

/// A composited frame produced by the renderer, ready for watermarking + display.
public struct RenderedFrame: PipelineFrame, @unchecked Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int

    public init(frameID: FrameID,
                hostTimeNs: UInt64,
                pixelBuffer: CVPixelBuffer,
                width: Int,
                height: Int) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
    }
}

/// A single transcript segment produced by the voice pipeline (M28).
///
/// Wall-clock relative to the start of the listening session, in milliseconds.
/// Why ms (not ns) on the wire: matches whisper.cpp's native unit, halves JSONL noise.
public struct TranscriptFrame: Sendable, Codable, Hashable {
    public let startMs: Double
    public let endMs: Double
    public let text: String
    public let confidence: Float

    public init(startMs: Double, endMs: Double, text: String, confidence: Float) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }
}

/// A watermarked output frame: rendered frame + signature bytes that bind it to the session.
public struct WatermarkedFrame: PipelineFrame, @unchecked Sendable {
    public let frameID: FrameID
    public let hostTimeNs: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
    public let signature: Data      // Ed25519 over (frameID || hostTimeNs || sha256(pixels))
    public let contentDigest: Data  // sha256 of the watermarked pixels (for the manifest)

    public init(frameID: FrameID,
                hostTimeNs: UInt64,
                pixelBuffer: CVPixelBuffer,
                width: Int,
                height: Int,
                signature: Data,
                contentDigest: Data) {
        self.frameID = frameID
        self.hostTimeNs = hostTimeNs
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
        self.signature = signature
        self.contentDigest = contentDigest
    }
}
