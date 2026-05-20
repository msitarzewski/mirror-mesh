import Foundation
import simd
import MirrorMeshCore

// =============================================================================
// ReenactFrame.overlayLipSync — mouth-region coefficient merge
// =============================================================================
//
// The v0.8.0 lip-sync overlay is the bridge between the audio-driven mouth
// shape produced by `MirrorMeshTranslate.LipSyncDriver` and the stylized 3D
// head puppet from v0.6.0. The pipeline calls this extension method once per
// frame, after `ReenactStage.apply(_:)` produces the operator-driven frame.
//
// **Contract**:
//   • Replaces ONLY the mouth-region coefficients (the keys listed in
//     `MirrorMeshTranslate.LipSyncCoefficients.mouthShapeKeys`, mirrored here
//     as `mouthShapeKeysForOverlay`). Pose channels (headYaw/Pitch/Roll) and
//     non-mouth blendshapes (brow*, eyeClose*, cheekPuff*, noseSneer) pass
//     through untouched.
//   • Re-deforms the mesh from the merged coefficient set using the model's
//     existing `deform(coefficients:)` and `computeNormals(vertices:)`. This
//     keeps the geometry consistent with the rest of the rig — the same code
//     path that handled the operator-driven solve handles the audio overlay.
//   • Preserves frameID / hostTimeNs / labelTextureIndex / indices so the
//     downstream renderer doesn't notice anything changed structurally.
//
// **Why on `ReenactFrame`, not inside `FaceReenactor`**: the merge is pure —
// no identity gating, no async state. The reenactor's actor isolation exists
// for identity hot-swap; the merge happens on the pipeline's executor and is
// a no-cost extension on a value type.
//
// **Why a mouth-shape allow-list, not a "replace all" merge**: the operator's
// silent face still controls everything above the mouth (brows raised in
// surprise, eyes squinting, head tilted). Replacing only the explicit mouth
// keys is what makes the avatar look like *the operator* speaking a foreign
// language, instead of a generic puppet.

extension ReenactFrame {

    /// Mouth-region keys this overlay touches. Mirrors
    /// `MirrorMeshTranslate.LipSyncCoefficients.mouthShapeKeys` — we duplicate
    /// the constant here so MirrorMeshReenact has no dependency on
    /// MirrorMeshTranslate (the layering goes Reenact → Translate, not back).
    /// If a sixth mouth shape is ever added to the overlay contract, both
    /// sites must update — there's a test that asserts they match.
    public static let mouthShapeKeysForOverlay: Set<StylizedBlendshape> = [
        .jawOpen,
        .mouthPucker,
        .mouthWide,
        .smileL,
        .smileR,
    ]

    /// Produce a new `ReenactFrame` with the mouth-region coefficients replaced
    /// by `overlay.values`, then re-deform the mesh from the merged set.
    ///
    /// - Parameters:
    ///   - overlay: dictionary of mouth-region shapes → coefficient. Keys
    ///     outside `mouthShapeKeysForOverlay` are silently ignored (the
    ///     `LipSyncCoefficients` initializer already filters them out, but
    ///     this extension defends against direct dict construction).
    ///   - model: the `StylizedHeadModel` that produced the original frame.
    ///     Re-using the same model is essential — different models would
    ///     have different blendshape deltas and the merge would silently
    ///     produce wrong geometry. The pipeline holds the model on the
    ///     reenactor and passes it through.
    /// - Returns: a new `ReenactFrame` with merged coefficients, re-deformed
    ///   vertices, and freshly-computed normals. All other fields propagate
    ///   unchanged.
    public func overlayLipSync(_ overlay: [StylizedBlendshape: Float],
                                using model: StylizedHeadModel) -> ReenactFrame {
        var merged = self.coefficients
        for (key, value) in overlay where Self.mouthShapeKeysForOverlay.contains(key) {
            // Clamp to the same range the model's `deform` clamps to. We keep
            // the overlay-side clamp in `LipSyncCoefficients.init` too — defense
            // in depth, and it costs ~5 ns per shape.
            merged[key] = simd_clamp(value, 0.0, 1.0)
        }

        // Re-deform. `deform(coefficients:)` is O(verts × active shapes); active
        // shapes are bounded at 18 so this is sub-millisecond on M-series.
        let newVerts = model.deform(coefficients: merged)
        let newNormals = model.computeNormals(vertices: newVerts)

        return ReenactFrame(
            vertices: newVerts,
            normals: newNormals,
            indices: self.indices,
            coefficients: merged,
            labelTextureIndex: self.labelTextureIndex,
            frameID: self.frameID,
            hostTimeNs: self.hostTimeNs
        )
    }
}
