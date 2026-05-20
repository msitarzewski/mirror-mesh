import Testing
import Foundation
import simd
@testable import MirrorMeshReenact
@testable import MirrorMeshWatermark
import MirrorMeshCore

@Suite("ReenactStage")
struct ReenactStageTests {

    // Build a 76-point landmark frame with a fixed pose for stage tests.
    private func sampleFrame(frameID: FrameID = FrameID(42), hostTimeNs: UInt64 = 1_000_000) -> LandmarkFrame {
        let pts = StylizedHeadBlendshapeTests.synthesizeLandmarks().map { LandmarkPoint(x: $0.x, y: $0.y) }
        return LandmarkFrame(
            frameID: frameID,
            hostTimeNs: hostTimeNs,
            points: pts,
            confidence: 0.95,
            faceBoundingBoxNorm: CGRect(x: 0.25, y: 0.18, width: 0.5, height: 0.64)
        )
    }

    @Test func passthroughWhenNoIdentityLoaded() async {
        let stage = ReenactStage()
        let result = await stage.apply(sampleFrame())
        #expect(result.frame == nil)
        #expect(result.identityActive == false)
        #expect(result.frameID == FrameID(42))
    }

    @Test func emitsDeformedMeshWhenIdentityLoaded() async throws {
        let stage = ReenactStage()
        let signed = try TestBundle.makeSigned()
        try await stage.setIdentity(signed.identity, pngBytes: signed.png, runtimeVersion: "0.6.0")

        let result = await stage.apply(sampleFrame())
        #expect(result.identityActive == true)
        guard let f = result.frame else {
            Issue.record("expected non-nil ReenactFrame after identity load")
            return
        }
        #expect(f.vertices.count == StylizedHeadModel.expectedVertexCount)
        #expect(f.normals.count == f.vertices.count)
        #expect(f.indices.count % 3 == 0)
        #expect(f.frameID == FrameID(42))
        // Every coefficient is present (the solver writes all keys, even zero).
        for shape in StylizedBlendshape.allCases {
            #expect(f.coefficients[shape] != nil, "missing coefficient for \(shape)")
        }
    }

    @Test func setIdentityRejectsTamperedBundle() async throws {
        let stage = ReenactStage()
        var bad = try TestBundle.makeSigned()
        bad.png.append(0xAB)
        await #expect(throws: ConsentedIdentityError.self) {
            try await stage.setIdentity(bad.identity, pngBytes: bad.png, runtimeVersion: "0.6.0")
        }
        // Stage should still be in pass-through state.
        let result = await stage.apply(sampleFrame())
        #expect(result.frame == nil)
        #expect(result.identityActive == false)
    }

    @Test func clearIdentityReturnsToPassthrough() async throws {
        let stage = ReenactStage()
        let signed = try TestBundle.makeSigned()
        try await stage.setIdentity(signed.identity, pngBytes: signed.png, runtimeVersion: "0.6.0")
        let armed = await stage.apply(sampleFrame())
        #expect(armed.identityActive == true)

        await stage.clearIdentity()
        let disarmed = await stage.apply(sampleFrame())
        #expect(disarmed.identityActive == false)
        #expect(disarmed.frame == nil)
    }

    @Test func multipleFramesAreDeterministic() async throws {
        let stage = ReenactStage()
        let signed = try TestBundle.makeSigned()
        try await stage.setIdentity(signed.identity, pngBytes: signed.png, runtimeVersion: "0.6.0")
        let a = await stage.apply(sampleFrame(frameID: FrameID(1)))
        let b = await stage.apply(sampleFrame(frameID: FrameID(2)))
        guard let fa = a.frame, let fb = b.frame else {
            Issue.record("missing frames")
            return
        }
        // Same landmark input → same coefficients (solver is stateless).
        for shape in StylizedBlendshape.allCases {
            let ca = fa.coefficients[shape] ?? 0
            let cb = fb.coefficients[shape] ?? 0
            #expect(ca == cb, "coefficient \(shape) drifted across identical inputs: \(ca) vs \(cb)")
        }
    }

    @Test func reenactedFrameIsSendable() async throws {
        // Compile-time sanity check: a ReenactedFrame must cross a Task boundary.
        let stage = ReenactStage()
        let signed = try TestBundle.makeSigned()
        try await stage.setIdentity(signed.identity, pngBytes: signed.png, runtimeVersion: "0.6.0")
        let r = await stage.apply(sampleFrame())
        let echoed: ReenactedFrame = await Task.detached(priority: .userInitiated) {
            return r
        }.value
        #expect(echoed.frameID == r.frameID)
    }
}
