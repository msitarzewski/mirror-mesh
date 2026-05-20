import Testing
import Foundation
import simd
@testable import MirrorMeshReenact
@testable import MirrorMeshWatermark
import MirrorMeshCore

@Suite("FaceReenactor identity gate")
struct FaceReenactorGateTests {

    @Test func initWithValidIdentitySucceeds() async throws {
        let signed = try TestBundle.makeSigned()
        let reenactor = try FaceReenactor(
            identity: signed.identity,
            pngBytes: signed.png,
            runtimeVersion: "0.6.0"
        )
        let id = await reenactor.currentIdentity
        #expect(id.display_name == signed.identity.display_name)
        #expect(id.scheme == .stylizedNonHuman)
    }

    @Test func initWithTamperedBundleFails() throws {
        var signed = try TestBundle.makeSigned()
        // Mutate PNG bytes after signing — hash check should fire.
        signed.png.append(0x99)
        #expect(throws: ConsentedIdentityError.self) {
            _ = try FaceReenactor(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"
            )
        }
    }

    @Test func initWithTamperedHeaderFails() throws {
        var signed = try TestBundle.makeSigned()
        // Mutate a header field — signature check should fire.
        signed.identity.display_name = "Different Identity"
        #expect(throws: ConsentedIdentityError.self) {
            _ = try FaceReenactor(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"
            )
        }
    }

    @Test func initWithOutOfScopeBundleFails() throws {
        // Bundle declares it requires v0.9+, but we're running 0.6.0.
        let signed = try TestBundle.makeSigned(scope: "v0.9+")
        #expect(throws: ConsentedIdentityError.self) {
            _ = try FaceReenactor(
                identity: signed.identity,
                pngBytes: signed.png,
                runtimeVersion: "0.6.0"
            )
        }
    }

    @Test func setIdentityHotSwapKeepsExistingOnFailure() async throws {
        let original = try TestBundle.makeSigned()
        let reenactor = try FaceReenactor(
            identity: original.identity,
            pngBytes: original.png,
            runtimeVersion: "0.6.0"
        )
        let firstID = await reenactor.currentIdentity.identity_id

        // Attempt swap with tampered bundle — should throw, existing identity unchanged.
        var bad = try TestBundle.makeSigned()
        bad.png.append(0x01)
        await #expect(throws: ConsentedIdentityError.self) {
            try await reenactor.setIdentity(
                bad.identity,
                pngBytes: bad.png,
                runtimeVersion: "0.6.0"
            )
        }
        let stillFirstID = await reenactor.currentIdentity.identity_id
        #expect(stillFirstID == firstID)

        // Successful swap to a fresh bundle.
        let next = try TestBundle.makeSigned()
        try await reenactor.setIdentity(
            next.identity,
            pngBytes: next.png,
            runtimeVersion: "0.6.0"
        )
        let newID = await reenactor.currentIdentity.identity_id
        #expect(newID == next.identity.identity_id)
        #expect(newID != firstID)
    }
}
