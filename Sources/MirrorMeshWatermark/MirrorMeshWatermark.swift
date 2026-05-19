import Foundation
import MirrorMeshCore
import MirrorMeshRender

public enum MirrorMeshWatermark {
    public static let moduleName = "MirrorMeshWatermark"
    public static let manifestVersion = "1.0"
}

public enum WatermarkError: Error, CustomStringConvertible, Sendable {
    case pixelBufferLockFailed
    case unsupportedPixelFormat(OSType)
    case opacityBelowReleaseFloor(Double)
    case invalidPublicKey
    case invalidSignature
    case manifestSignatureMissing
    case manifestSignatureInvalid
    case manifestDecodingFailed(String)

    public var description: String {
        switch self {
        case .pixelBufferLockFailed: return "Failed to lock CVPixelBuffer base address"
        case .unsupportedPixelFormat(let fmt): return "Unsupported pixel format: 0x\(String(fmt, radix: 16))"
        case .opacityBelowReleaseFloor(let v): return "Opacity \(v) below release floor 0.85"
        case .invalidPublicKey: return "Invalid Ed25519 public key bytes"
        case .invalidSignature: return "Ed25519 signature verification failed"
        case .manifestSignatureMissing: return "Manifest has no signature"
        case .manifestSignatureInvalid: return "Manifest signature verification failed"
        case .manifestDecodingFailed(let m): return "Manifest decoding failed: \(m)"
        }
    }
}
