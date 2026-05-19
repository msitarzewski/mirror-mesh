import Foundation

/// User-selectable rendering style. Determines which view is "hero" (the synthetic output or
/// the raw camera) and which is auxiliary (PIP overlay). The whole point of v0.5.0's
/// presence architecture is to make the synthetic side the main view in `.mirror` and `.mask`.
public enum RenderStyle: String, Codable, Sendable, CaseIterable, Hashable {
    /// Debug / developer view. Camera background + green mesh wireframe + landmark dots overlaid.
    /// Camera dominates; mesh is anchored to the face. The "looks technical" mode.
    case wireframe

    /// Reframed-real view. Clean camera passthrough + visible watermark + signed manifest.
    /// The synthetic-ness comes from the disclosure layer, not from a transformed image.
    /// PIP not needed because the source IS the hero.
    case mirror

    /// Synthetic-as-hero view. Filled stylized face mesh dominates; camera dimmed behind +
    /// shown as a small PIP in the corner so viewers can verify the source.
    /// This is the "I look transformed in realtime" demo.
    case mask

    public var displayName: String {
        switch self {
        case .wireframe: return "Wireframe"
        case .mirror:    return "Mirror"
        case .mask:      return "Mask"
        }
    }

    public var subtitle: String {
        switch self {
        case .wireframe: return "Debug view — mesh + dots over camera"
        case .mirror:    return "Real camera + watermark + signed manifest"
        case .mask:      return "Synthetic mesh hero, source as PIP"
        }
    }

    public var symbolName: String {
        switch self {
        case .wireframe: return "grid"
        case .mirror:    return "person.crop.rectangle"
        case .mask:      return "theatermasks"
        }
    }
}
