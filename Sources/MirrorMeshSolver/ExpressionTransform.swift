import Foundation
import MirrorMeshCore

/// Accessibility transforms applied to the solver's ARKit-52 coefficients before the expressive
/// avatar renders them. Pure value-type functions: the same coefficients and settings always give
/// the same output, and nothing is remembered between frames.
///
/// Every active transform is a disclosure: the avatar's expression is no longer exactly what the
/// operator's face did. The pipeline records `manifestTags` and flips the session manifest's
/// sticky `expression_transformed` flag the first time any transform is active (R2).
///
/// Sides follow the solver's image-space convention: `.left` is the image-left side of the face,
/// which is what the operator sees on the left of the preview.
public struct ExpressionTransforms: Sendable, Equatable, Codable {
    public enum Side: String, Sendable, Codable, CaseIterable {
        case left, right
    }

    /// Facial-paralysis compensation. The affected side's paired shapes are driven toward the
    /// unaffected side's, and lateral pull toward the healthy side is attenuated.
    public struct SymmetryAssist: Sendable, Equatable, Codable {
        public var affectedSide: Side
        /// 0 = off, 1 = the affected side mirrors the unaffected side exactly.
        public var strength: Float
        public init(affectedSide: Side, strength: Float) {
            self.affectedSide = affectedSide
            self.strength = strength
        }
    }

    public var symmetry: SymmetryAssist?
    /// Expression amplification for reduced facial mobility. 1 = unchanged, up to 3. Uses a
    /// saturating curve (`1 − (1 − v)^gain`), so small movements grow by ~`gain` and full
    /// expressions stay at 1 instead of clipping.
    public var gain: Float
    /// Eye-contact assist: fraction of gaze deviation removed, 0...1. Blinks are untouched.
    public var eyeContact: Float

    public init(symmetry: SymmetryAssist? = nil, gain: Float = 1, eyeContact: Float = 0) {
        self.symmetry = symmetry
        self.gain = gain
        self.eyeContact = eyeContact
    }

    public static let none = ExpressionTransforms()

    public static let gainRange: ClosedRange<Float> = 1...3

    /// Mirrored left/right pairs. Gaze keys are excluded on purpose: they encode a conjugate
    /// direction, so copying one eye's `eyeLookIn` onto the other would cross the eyes.
    public static let symmetricPairs: [(BlendshapeKey, BlendshapeKey)] = [
        (.eyeBlinkLeft, .eyeBlinkRight), (.eyeSquintLeft, .eyeSquintRight), (.eyeWideLeft, .eyeWideRight),
        (.mouthSmileLeft, .mouthSmileRight), (.mouthFrownLeft, .mouthFrownRight),
        (.mouthDimpleLeft, .mouthDimpleRight), (.mouthStretchLeft, .mouthStretchRight),
        (.mouthPressLeft, .mouthPressRight), (.mouthLowerDownLeft, .mouthLowerDownRight),
        (.mouthUpperUpLeft, .mouthUpperUpRight), (.browDownLeft, .browDownRight),
        (.browOuterUpLeft, .browOuterUpRight), (.cheekSquintLeft, .cheekSquintRight),
        (.noseSneerLeft, .noseSneerRight),
    ]

    /// Lateral pulls that paralysis biases toward the healthy side.
    static let lateralKeys: [BlendshapeKey] = [.mouthLeft, .mouthRight, .jawLeft, .jawRight]

    /// Keys amplification leaves alone: gaze (handled by eye-contact) and blinks (amplifying
    /// resting lid noise would make the avatar squint).
    static let gainExcluded: Set<BlendshapeKey> = Set(GazeChannels.keys + [.eyeBlinkLeft, .eyeBlinkRight])

    public var isActive: Bool {
        (symmetry.map { $0.strength > 0 } ?? false) || abs(gain - 1) > 1e-3 || eyeContact > 0
    }

    /// Stable, human-readable record of what was applied, for the session manifest.
    public var manifestTags: [String] {
        var tags: [String] = []
        if let s = symmetry, s.strength > 0 {
            tags.append(String(format: "symmetry:%@:%.2f", s.affectedSide.rawValue, s.strength))
        }
        if abs(gain - 1) > 1e-3 { tags.append(String(format: "gain:%.2f", gain)) }
        if eyeContact > 0 { tags.append(String(format: "eye_contact:%.2f", eyeContact)) }
        return tags
    }

    /// Symmetry → gain → eye contact. Output is clamped to [0, 1].
    public func apply(_ input: [BlendshapeKey: Float]) -> [BlendshapeKey: Float] {
        guard isActive else { return input }
        var c = input

        if let s = symmetry, s.strength > 0 {
            let k = min(max(s.strength, 0), 1)
            for (left, right) in Self.symmetricPairs {
                let (affected, healthy) = s.affectedSide == .left ? (left, right) : (right, left)
                let a = c[affected] ?? 0, h = c[healthy] ?? 0
                c[affected] = a + (h - a) * k
            }
            for key in Self.lateralKeys {
                if let v = c[key] { c[key] = v * (1 - k) }
            }
        }

        let g = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        if g != 1 {
            for (key, v) in c where !Self.gainExcluded.contains(key) {
                let x = min(max(v, 0), 1)
                c[key] = 1 - pow(1 - x, g)
            }
        }

        if eyeContact > 0 {
            let keep = 1 - min(max(eyeContact, 0), 1)
            for key in GazeChannels.keys {
                if let v = c[key] { c[key] = v * keep }
            }
        }

        for (key, v) in c { c[key] = v.isNaN ? 0 : min(max(v, 0), 1) }
        return c
    }
}
