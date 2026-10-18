import Testing
import Foundation
@testable import MirrorMeshReenact
import MirrorMeshCore

@Suite("LipSyncARKitBridge")
struct LipSyncARKitBridgeTests {
    private let operatorFace: [BlendshapeKey: Float] = [
        .jawOpen: 0.1, .mouthFunnel: 0.6, .mouthSmileLeft: 0.3,
        .browInnerUp: 0.7, .eyeBlinkLeft: 0.4, .cheekSquintRight: 0.2,
    ]

    @Test func emptyOverlayPassesOperatorFaceThrough() {
        #expect(LipSyncARKitBridge.merge([:], into: operatorFace) == operatorFace)
    }

    @Test func overlayOwnsTheMouthAndLeavesTheRestOfTheFace() {
        let out = LipSyncARKitBridge.merge([.jawOpen: 0.8, .mouthWide: 0.5, .smileR: 0.25], into: operatorFace)
        #expect(out[.jawOpen] == 0.8)
        #expect(out[.mouthStretchLeft] == 0.5)
        #expect(out[.mouthStretchRight] == 0.5)
        #expect(out[.mouthSmileRight] == 0.25)
        // Operator mouth shapes the audio didn't specify are cleared, not mixed in.
        #expect(out[.mouthFunnel] == 0)
        #expect(out[.mouthSmileLeft] == 0)
        // Above the mouth, the operator still drives.
        #expect(out[.browInnerUp] == 0.7)
        #expect(out[.eyeBlinkLeft] == 0.4)
        #expect(out[.cheekSquintRight] == 0.2)
    }

    @Test func nonMouthOverlayShapesAreIgnored() {
        // Same allow-list contract as ReenactFrame.overlayLipSync.
        let out = LipSyncARKitBridge.merge([.browUpL: 1, .eyeCloseL: 1], into: operatorFace)
        #expect(out == operatorFace)
    }

    @Test func everyOverlayShapeHasAnARKitTarget() {
        for shape in ReenactFrame.mouthShapeKeysForOverlay {
            let targets = LipSyncARKitBridge.mapping[shape] ?? []
            #expect(!targets.isEmpty, "no ARKit mapping for \(shape)")
            #expect(targets.allSatisfy { LipSyncARKitBridge.ownedKeys.contains($0) })
        }
    }

    @Test func overlayValuesAreClamped() {
        let out = LipSyncARKitBridge.merge([.jawOpen: 1.4, .mouthPucker: -0.2], into: [:])
        #expect(out[.jawOpen] == 1)
        #expect(out[.mouthPucker] == 0)
    }
}
