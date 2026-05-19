import Foundation
import MirrorMeshCore
import MirrorMeshVision

public enum MirrorMeshSolver {
    public static let moduleName = "MirrorMeshSolver"
}

/// Canonical landmark indices for the 76-point Vision-ordered schema documented in
/// `docs/landmark-schema.md`. Centralised here so the solver, calibrator, and tests agree.
///
/// These are coarse-band assumptions: the solver picks representative points from each band
/// and is robust to small index drift inside a band (e.g. the eye ring is 8 contiguous
/// points; we only rely on top/bottom/left/right extremes).
public enum LandmarkIndex {
    // Face outline / silhouette band: 0..15
    public static let outlineRange: Range<Int> = 0..<16

    // Left eye ring: 16..23 (8 pts) — index 16 leftmost, 20 rightmost, top/bottom on the ring
    public static let leftEyeRange: Range<Int> = 16..<24
    public static let leftEyeLeftCorner = 16
    public static let leftEyeRightCorner = 20
    public static let leftEyeUpper = 18
    public static let leftEyeLower = 22

    // Right eye ring: 24..31
    public static let rightEyeRange: Range<Int> = 24..<32
    public static let rightEyeLeftCorner = 24
    public static let rightEyeRightCorner = 28
    public static let rightEyeUpper = 26
    public static let rightEyeLower = 30

    // Nose bridge / tip: 32..39
    public static let noseRange: Range<Int> = 32..<40
    public static let noseTip = 36

    // Mouth outer ring: 40..55 (16 pts). Distributed roughly clockwise starting at left corner.
    public static let mouthOuterRange: Range<Int> = 40..<56
    public static let mouthLeftCorner = 40
    public static let mouthUpperLip = 44     // top middle of upper lip
    public static let mouthRightCorner = 48
    public static let mouthLowerLip = 52     // bottom middle of lower lip

    // Chin / lower face: 56..63
    public static let chinRange: Range<Int> = 56..<64
    public static let chinTip = 60

    // Inner mouth / brow detail: 64..75 (optional band; treated as best-effort)
    public static let detailRange: Range<Int> = 64..<76
    // Brow rough positions inside the detail band.
    public static let leftBrowInner = 64
    public static let leftBrowOuter = 67
    public static let rightBrowInner = 70
    public static let rightBrowOuter = 73
}
